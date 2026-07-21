# Deployment evidence - demo environment (us-east-2)

Captured 2026-07-21 during the first end-to-end deployment. Account id redacted as
`<account-id>` throughout. Live URL at capture time: `https://d2x4syxdyv4q8c.cloudfront.net`.

## Functional smoke (through CloudFront, after seed + backfill)

```
GET /api/meta/freshness
{"last_ingest":"2026-07-21T09:16:55.868024+00:00","latest_event":"2026-07-21T09:07:44.780000+00:00","age_seconds":53,"stale":false}

GET /api/quakes/recent          -> count: 27 (magnitude > 4.0, last 24 h), newest: M4.6 "84 km SW of Puerto Madero, Mexico"
GET /api/quakes/weekly-averages -> average_per_day: 306.43, daily counts [206, 345, 358, 334, 307, 297, 230, 68]
GET /api/quakes/top?days=30&limit=5
  M7.5 20 km ESE of Yumare, Venezuela
  M7.3 58 km WSW of Puerto Madero, Mexico
  M7.2 21 km ENE of San Felipe, Venezuela
  M6.9 33 km ENE of Noda, Japan
  M6.5 34 km WSW of Sarangani, Philippines

GET /            -> HTTP 200 (SPA served from S3 via OAC)
GET http://<alb-dns>/api/meta/freshness (direct, bypassing CloudFront) -> connection blocked
  (security group admits only the CloudFront origin-facing prefix list; the listener
   default is 403 unless the distribution's secret origin header is present)
```

The 30-day backfill ran automatically on the ingestion Lambda's first scheduled
invocation; a manual re-invoke afterwards reported `{"status":"ok","mode":"incremental","upserted":11}`.

## Ingestion pipeline

- EventBridge rate(5 minutes) -> Lambda -> USGS FDSN API -> idempotent upsert (PostgreSQL).
- Custom metrics under namespace `TCGL01`: `EventsUpserted`, `IngestionFreshnessSeconds`, `IngestionSuccess`.
- Freshness at capture: 53 s. SLO: <= 10 min, 99% of the time.

## Alarm lifecycle (the outage window was real and the alarms told the truth)

During initial bring-up the Lambda package had a host-platform packaging defect and the
SPA bucket was briefly empty. The alarm set behaved exactly as designed:

| Alarm | During the window | After recovery |
|---|---|---|
| tcgl01-ingestion-failures | ALARM (Lambda errors, 2 consecutive cycles) | OK (self-cleared) |
| tcgl01-data-freshness | ALARM (metric missing = breaching by design) | OK (self-cleared) |
| tcgl01-api-tasks-below-desired | ALARM (Container Insights lag at bring-up) | OK (self-cleared) |
| tcgl01-canary-failing | ALARM | OK after canary fix (below) |
| availability-fast-burn, latency-p95, rds-cpu, rds-storage | OK throughout | OK |

## Black-box canary vs the WAF (found by monitoring, fixed in the client)

The Synthetics canary initially failed every run with a `200 text/html` response on an
API path. Root cause chain, in diagnosis order:

1. Node's `https` client sends no `User-Agent` header by default.
2. The WAF's `AWSManagedRulesCommonRuleSet` includes `NoUserAgent_HEADER` and blocked
   the canary's requests (403) - the firewall working as configured.
3. CloudFront's SPA error rewrite (403 -> `/index.html`, HTTP 200) masked the block as
   an apparently successful HTML response, which even made the `/` check pass falsely.

Fixes: the canary now identifies itself (`tcgl01-heartbeat/1.0`), edge error-page
caching is disabled (`error_caching_min_ttl = 0` - cached error pages otherwise mask
API recovery for up to 5 minutes per edge location), and the canary resource carries a
code-hash tag because the Terraform provider does not diff canary zip contents (without
it, script changes deploy silently as no-ops). First run after the fix: PASSED.

## Rollback drill (deployment circuit breaker)

A task definition revision pointing at a nonexistent image tag (`:broken-drill`) was
deployed on purpose. Observed sequence from the service events:

```
(service tcgl01-api) has started 1 tasks ...            # new tasks try to start
(service tcgl01-api) stopped 2 pending tasks.           # image pull fails, breaker counting
(service tcgl01-api) (deployment ecs-svc/7566...) deployment failed: tasks failed to start.
(service tcgl01-api) rolling back to deployment ecs-svc/9404...
(service tcgl01-api) has started 1 tasks ... registered 1 targets ...   # rollback converges
```

Uptime probe during the whole drill: `GET /api/meta/freshness` every 30 seconds -
**24/24 responses HTTP 200 across ~12 minutes**. `deployment_minimum_healthy_percent = 100`
kept the previous tasks serving while the broken deployment failed and rolled back;
users never saw the failed deploy.

Measured reference: the circuit breaker declared failure and began rollback ~12 minutes
after the broken deployment started (2-task service, image-pull failure mode).

## Timing note

The first full `terraform apply` was interrupted by the workstation sleeping mid-run,
which invalidates that run's wall-clock numbers (the RDS waiter accumulated sleep time
and had to be untainted after verifying the instance was healthy). A clean-room timing
run (destroy + fresh apply) is the pre-review rehearsal step; per-resource timings will
be recorded there.
