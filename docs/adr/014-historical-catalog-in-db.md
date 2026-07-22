# 014. Historical catalog served from our database; on-demand hydration deferred

## Context

The product needs a browsable historical catalog - a primary table with pagination, sorting, and
filters - not just the three fixed panels. The database only seeded 30 days on first boot, so "history"
raises the question of where deeper data comes from when a reader asks for it. The tempting answer is
hydration in the request path: if a page of results is not in our database, the API fetches it from
USGS right then, stores it, and returns it.

## Options considered

- **A. Synchronous on-demand hydration.** API cache-misses fall through to USGS inside the request.
- **B. Asynchronous hydration.** A request that hits a coverage gap enqueues a backfill job and returns
  immediately with explicit coverage metadata; the UI shows the gap filling.
- **C. Serve only our own database, and widen it deliberately:** the existing 5-minute ingest keeps
  accumulating everything forward; a one-off deep-seed run backfills 10 years of M >= 4.0 in one
  idempotent pass (~120 month-sized USGS queries, well under the API's 20k-per-query cap).

## Decision

C now, B as the documented production evolution. A is rejected outright.

## Why

A puts a third party on our latency and availability budget. This system's resilience posture -
required by the brief - is that ingestion is decoupled: if USGS is slow or down, the API keeps serving
everything it has, degraded only in freshness. Synchronous hydration reverses that: a reader paging
into an uncovered year makes our p95 inherit USGS timeouts, our error rate inherit their rate limiting,
and a popular gap becomes a self-inflicted thundering herd against an upstream we do not control. It
converts a read-only endpoint into one with write side effects, and it couples user-facing SLOs to a
dependency our error budget cannot buy back.

C keeps the read path pure - PostgreSQL answers every request from local data with keyset pagination -
and moves all upstream traffic to the same place it already lives: the ingestion Lambda, off the
request path, observable through the same alarms. The coverage boundary is explicit instead of implicit:
the API reports what the catalog actually covers (all magnitudes since first boot, M >= 4.0 for a
decade), which is honest and cheap. Scale is a non-issue at this shape: ~200k rows for the deep seed,
covered by the existing (magnitude, occurred_at) and (occurred_at) indexes.

B is the right shape when the product truly needs arbitrary-depth, all-magnitude history: coverage
tracking per window, a queue, a worker budgeted against USGS limits, and UI for "requested - filling".
That is real machinery with its own failure modes and belongs behind a product requirement, not built
speculatively into a system whose brief says not to overcomplicate the application.

## Revisit when

A reader needs sub-M4.0 events older than first boot, or windows beyond the seeded decade - that is
the trigger to build B (gap-driven asynchronous backfill with coverage metadata), not to widen A-style
shortcuts.
