# 002. RDS PostgreSQL over DynamoDB

## Context

Earthquake data needs three read shapes: a time-and-magnitude-filtered scan (recent events), a 7-day
group-by-day aggregate (weekly averages), and a top-N-by-magnitude over a rolling window (top quakes).
None of these are single-key lookups.

## Options considered

- **A. DynamoDB.** Single-digit-millisecond key/value access, no capacity to manage.
- **B. RDS PostgreSQL, Multi-AZ.**

## Decision

B.

## Why

Every one of the three read endpoints is a query DynamoDB does not answer natively without extra
machinery - a GSI per access pattern at best, a second system (Athena, or a stream into something
queryable) at worst. "Top 5 by magnitude in the last 30 days" and "average count per day over 7 days"
are each one SQL statement against a couple of indexes (`idx_eq_time`, `idx_eq_mag_time`) in Postgres.
The dataset is also small - a few hundred events a day worldwide above the magnitude floor this project
cares about - and read-light, so DynamoDB's scaling story buys nothing a project this size needs, while
Postgres's relational query surface buys real simplicity everywhere that matters here.

## Revisit when

An access pattern shows up that is genuinely single-key at high, spiky volume (for example, "fetch one
event by id" as the dominant traffic shape) and the relational queries above stop being the majority of
what the system does.
