# 009. Idempotent upsert keyed on the USGS event id

## Context

The first pass at this treated ingested earthquake data as append-only: a new event arrives, gets a
row, and nothing about it ever changes again. That model turned out to be wrong. USGS routinely revises
an event's properties - most often magnitude, sometimes location - in the hours after it happens, as
more seismic stations report in, while keeping the same event id throughout.

## Options considered

- **A. Append-only inserts.** One row per fetch per event; treat a later revision as new information
  without touching the original row.
- **B. Upsert on `event_id`**, always reflecting USGS's current view of that event.

## Decision

B.

## Why

Once it was clear USGS revises events, "immutable source data" was the wrong mental model, not just an
implementation detail - the row for a given `event_id` should represent USGS's current, best-known
values, not whatever was first fetched. `event_id` is the table's primary key, and the write is a plain
`INSERT ... ON CONFLICT (event_id) DO UPDATE`. This also makes the ingestion Lambda's own overlap
behavior safe for free: every incremental run re-fetches the trailing 2 hours on top of whatever the
5-minute schedule already covered, and re-applying an unchanged event is a no-op - no deduplication
logic to get wrong, no risk of duplicate rows from a retried or overlapping run.

## Revisit when

A second data source is added with a different identity scheme - no natural stable id, or ids that could
collide across sources. At that point the primary key needs to be source-qualified; the upsert pattern
itself does not need to change.
