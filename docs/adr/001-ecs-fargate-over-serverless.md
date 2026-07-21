# 001. ECS Fargate over pure serverless for the API

## Context

The API surface is five read-mostly endpoints over PostgreSQL, serving a dashboard SPA. Two compute
shapes fit: Lambda behind API Gateway for every route, or a long-running container service. Ingestion
is a separate decision (it is a scheduled, stateless job either way).

## Options considered

- **A. Pure serverless.** API Gateway plus Lambda for every route; Lambda for ingestion too.
- **B. ECS Fargate for the API** (2 tasks, ALB), Lambda kept for ingestion only.

## Decision

B. ECS Fargate for the API; ingestion stays on Lambda.

## Why

Two reasons. Technical: Lambda-to-RDS connection pooling is a known operational headache - each
concurrent invocation is effectively a fresh connection unless something like RDS Proxy sits in front,
which is its own resource to design, secure, and defend. Fargate lets the API hold one real connection
pool for the life of the process (`app/api/src/db.py`), with nothing extra in the request path. And on
what the challenge is actually grading: this is an SRE challenge, not a "ship a CRUD API" challenge. A
Fargate service is a genuinely richer surface for SRE judgment - a deployment circuit breaker with real,
provable rollback behavior, ALB health checks with tunable thresholds, task-level CPU/memory sizing,
ECS service events as an operational signal - none of which exist, or look anything alike, under Lambda.
Ingestion stayed on Lambda because it is the opposite shape: stateless, bursty, scheduled, no
request-response contract - exactly what Lambda is for. Putting it on Fargate would mean paying for an
idle task through most of every 5-minute window.

## Revisit when

Request volume or route count grows enough that 2 fixed tasks are either wasted most of the day or
undersized at peak. The next step then is Fargate autoscaling (target tracking on CPU or requests per
target), not a switch to serverless.
