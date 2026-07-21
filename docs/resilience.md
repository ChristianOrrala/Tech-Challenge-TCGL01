# Resilience

## Failure modes

| Failure | Effect | Mitigation |
|---|---|---|
| **USGS API down or unreachable** | The ingestion Lambda run fails; `IngestionSuccess` publishes `0.0`; no new rows are written that cycle | Existing rows keep serving every read endpoint unchanged - there is no outage on the read path. `/api/meta/freshness`'s `age_seconds` climbs cycle over cycle and flips `stale: true` past 900 s; the SPA banner turns amber ("Serving cached data - source feed unreachable or stale"); `tcgl01-ingestion-failures` pages after 2 consecutive failed cycles (~10 min), `tcgl01-data-freshness` pages if the metric stops arriving entirely |
| **AZ loss** | One availability zone's resources become unreachable | RDS Multi-AZ fails over to the synchronous standby automatically (AWS's documented typical range: 1-2 min). The ECS service runs 2 tasks across the 2 private subnets, one per AZ, so the surviving AZ keeps serving through the ALB. **Residual gap, stated plainly:** there is one NAT gateway, not one per AZ (`docs/architecture.md`); if the AZ lost is the one holding the NAT gateway, the surviving-AZ task and the ingestion Lambda both lose internet egress even though the task itself is healthy - a real, accepted trade-off for a demo build, not something this project claims to have solved |
| **ECS task crash (steady state)** | A single task exits or stops passing health checks outside of an active deployment | The ALB health check (15 s interval, 3 consecutive failures to eject, ~45 s) stops routing to it; the ECS service scheduler launches a replacement to restore `desired_count`. This is ordinary steady-state self-healing, not the deployment circuit breaker - the breaker is scoped to deployments (see the next row). `tcgl01-api-tasks-below-desired` pages if replacement can't keep pace |
| **Bad deploy (new image or task definition regresses)** | New tasks fail to start or fail health checks during a rollout | The deployment circuit breaker (`enable = true`, `rollback = true`) plus `deployment_minimum_healthy_percent = 100` roll the deployment back automatically, with the old tasks never scaled down until new ones prove healthy. **Proven, not just configured:** a task definition pointing at a nonexistent image tag was deployed on purpose; the breaker detected the failure and rolled back on its own, and an uptime probe every 30 s recorded 24/24 successful responses across the ~12-minute drill. Full transcript in `docs/evidence/deployment-smoke.md` |
| **Database outage or unreachable** | Every `/api/*` route's `psycopg` call raises | `database_error_handler` catches any `psycopg.Error` and returns one uniform `503 {"error": "database unavailable"}` - callers get a clean, consistent signal rather than a raw stack trace or a hung connection. `/health` is deliberately never touching the database (a liveness probe, not a readiness probe over the data layer), so ECS and the ALB keep the containers marked healthy and traffic-eligible through the outage - a DB blip degrades to targeted 503s on data endpoints instead of compounding into the whole service being pulled from rotation |
| **Edge error-page caching (a fixed class of bug, not a live failure mode)** | A transient edge error response, once rewritten to a 200 by the SPA error-page behavior, could be cached and re-served at that edge location for up to 5 minutes after the real cause cleared - masking both a real outage as "fine" and a real recovery as "still broken" | `error_caching_min_ttl = 0` on both `custom_error_response` blocks. Found via the canary/WAF incident (`docs/evidence/deployment-smoke.md`, [ADR 012](adr/012-disable-edge-error-caching.md)), not anticipated in advance |

## Graceful degradation: freshness as the product SLI, decoupled from availability

The system treats "is the API up" and "is the data current" as two independent, separately observable
properties, on purpose. An ingestion failure - USGS down, a Lambda bug, a schedule misfire - never takes
the API down; the existing rows in PostgreSQL keep answering every read exactly as before. What changes
is freshness, and that change is surfaced honestly rather than hidden: `/api/meta/freshness` returns an
explicit `stale` boolean and an `age_seconds` value computed fresh on every request, and the SPA's
`FreshnessBanner` is the one component whose whole job is to make that degradation visible - amber the
moment the freshness check itself fails or reports stale data, green only once it succeeds and the feed
is current.

The alternative - folding data currency into a single "is it working" signal - is what makes staleness
incidents invisible: a service that returns 200s for hours off of an hour-old dataset looks identical to
one serving live data unless something is specifically watching the data's age. Separating the two SLIs
means a real ingestion outage shows up as a visible, honest amber banner and a paged alarm, while the
API's own availability SLO stays accurate to what it actually measures - whether requests succeed, not
whether the answer happens to be a minute old.

## Toil reduction

- **Managed master password.** `manage_master_user_password = true` on the RDS instance - no password
  is generated, typed, or stored by hand anywhere in this project. AWS creates it, owns its lifecycle,
  and can rotate it; the plaintext exists only in AWS's own Secrets Manager, never in Terraform HCL or
  state.
- **The RDS-managed secret is consumed directly, with no manual distribution step.** The API task
  resolves it as a container-injected secret at start time, through its execution role; the ingestion
  Lambda fetches it with `boto3` at invocation, through its own role. Neither path requires a human to
  copy, paste, or rotate a credential by hand.
- **CI-owned builds.** GitHub Actions, authenticated via OIDC with no long-lived AWS keys, is the
  primary path to a deployed change - build, push, apply, SPA sync, cache invalidation, all in one
  workflow run. A human only touches Docker or `terraform apply` locally for break-glass, not as the
  normal way to ship.
- **Self-healing alarms.** Every one of the 8 alarms sends both `alarm_actions` and `ok_actions` to the
  same SNS topic, so a recovery is exactly as visible as the original page - nobody has to manually
  re-check whether an alarm actually cleared. `treat_missing_data` is set per alarm to the semantics
  that alarm actually needs, not one blanket default: `breaching` where silence is itself the problem
  (`tcgl01-data-freshness`, `tcgl01-api-tasks-below-desired`, `tcgl01-canary-failing`) and
  `notBreaching` where silence just means low traffic on a quiet demo account
  (`tcgl01-availability-fast-burn`, `tcgl01-latency-p95`, `tcgl01-ingestion-failures`,
  `tcgl01-rds-cpu-high`, `tcgl01-rds-storage-low`).
- **Account-agnostic infrastructure.** Availability zones, the CloudFront managed prefix list, and the
  CloudFront cache/origin-request policies are all resolved through Terraform data sources by name, not
  hardcoded IDs. A fresh account or a different region needs zero manual ID substitution to deploy this
  stack - `docs/runbook.md`'s fresh-account guide is a real, exercised path, not an aspiration.

## Known, accepted gaps

Named once here rather than glossed over: a single NAT gateway (not one per AZ); no data-retention or
purge job on the `earthquakes` table, and no RDS storage autoscaling configured to absorb that
unbounded growth automatically; no failover drill actually run against RDS (the RPO/RTO figures in
`docs/slo.md` are the platform's documented figures for this configuration, not numbers this project
measured itself, unlike the deployment circuit-breaker drill, which was). Each is a real trade-off made
under a challenge deadline, not an oversight discovered after the fact.
