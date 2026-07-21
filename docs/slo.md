# Service Level Objectives

## SLIs and SLOs

| SLI | Measurement | SLO |
|-----|-------------|-----|
| API availability (black-box) | CloudWatch Synthetics canary against the live URL, 5-minute cadence | 99.9% monthly (budget 43.2 min/month, ~10 min/week) |
| API availability (white-box) | `1 - (ALB target 5xx / requests)` | Same target; complementary view, not a second objective |
| API latency | ALB `TargetResponseTime`, p95 | < 300 ms |
| Data freshness | Age of the last successful ingest, from `/api/meta/freshness` | <= 10 min, 99% of the time |

Two SLIs, three rows: availability is measured two ways on purpose (see "Measurement-point honesty"
below) but there is one availability objective, not two.

## Error budget math

A 99.9% monthly objective allows 0.1% downtime:

```
30 days x 24 h x 60 min = 43,200 min/month
0.1% of 43,200            = 43.2 min/month
43.2 min / (30/7 weeks)   = ~10 min/week
```

## Burn policy

On budget exhaustion: feature deploys freeze, reliability work takes priority over new work, and normal
cadence resumes only once the trailing-month budget has recovered. This is a policy statement, not
something Terraform enforces - there is no automated deploy gate tied to budget consumption today (see
"Revisit" below).

## Fast-burn alarm

`tcgl01-availability-fast-burn` fires when the trailing 1-hour white-box availability drops below 99%.
The metric is a metric-math expression, not a raw CloudWatch metric:

```
m1 = sum(HTTPCode_Target_5XX_Count), 1h
m2 = sum(RequestCount), 1h
e1 = IF(m2 > 0, 1 - m1/m2, 1)     # a quiet hour with zero requests reads as fully available, not NaN
```

A 1-hour window at a 1% error threshold is a 10x burn rate against the 99.9% objective's 0.1%
long-run allowed error rate: sustaining it continuously would exhaust the entire monthly 43.2-minute
budget in about 3 days, which is the point of a fast-burn alarm - it pages long before the monthly SLO
is actually violated, while there is still time to react. Multi-window burn-rate alerting (pairing this
fast window with a slower, higher-confidence one to cut false pages) is documented here as a known next
step, not implemented - one alarm, one window, today.

## Internal indicators, deliberately not SLOs

Alarmed, but not promised to a user, and not in the table above:

- **Ingestion run success** (`tcgl01-ingestion-failures`, Lambda errors on 2 consecutive 5-minute
  periods). A failed ingestion run degrades freshness; it does not, by itself, take the API down. It is
  a leading indicator for the freshness SLO, not an availability signal.
- **RDS CPU** (`tcgl01-rds-cpu-high`, > 80% for 2 consecutive periods) and **RDS free storage**
  (`tcgl01-rds-storage-low`, < 2 GB) - capacity headroom, not user-facing outcomes. A user only feels
  these once they are severe enough to slow queries (which the latency SLO would catch) or exhaust
  storage entirely (which would surface as write failures / 503s, caught by the availability SLIs).
  Alarming on the leading indicator is what gives time to act before either of those happen.
- **ECS running task count vs desired** (`tcgl01-api-tasks-below-desired`, < 2 for 2 consecutive
  periods). With 2 desired tasks, one task down still leaves the service fully routable - the ALB
  simply stops sending traffic to the unhealthy target. This alarm is a redundancy/capacity signal
  (the service is one more failure away from real impact), not proof that a user was affected; if both
  tasks are down, that shows up directly in the availability SLIs anyway.

The pattern across all three: alarm on the thing that predicts user impact, promise the SLO on the
thing users actually experience. Conflating the two either pages too early on non-issues or, worse,
under-reports real degradation as "the alarm didn't fire so nothing happened."

## RPO / RTO

RPO is approximately 5 minutes, from RDS's continuous transaction-log-based point-in-time recovery
(7-day backup retention). RTO is approximately 1-2 minutes, AWS's documented typical range for Multi-AZ
synchronous failover. Both are the platform's advertised figures for this configuration, not numbers
measured by a failover drill in this project - the one recovery behavior actually drilled and evidenced
here is the ECS deployment circuit breaker (`docs/runbook.md`, `docs/evidence/deployment-smoke.md`), not
an AZ failure.

## Measurement-point honesty

**ALB vs edge.** The white-box SLI is computed entirely from ALB request accounting - it only knows
about requests that reached the ALB. A block at the edge (WAF, a CloudFront misconfiguration, a DNS
problem) never generates an ALB request at all, so it never generates a 5xx either; the white-box metric
would read as 100% available throughout. This is not a hypothetical: during bring-up, the WAF blocked
every request the Synthetics canary made (no `User-Agent` header, caught by
`AWSManagedRulesCommonRuleSet`), and the white-box metric stayed clean for the entire incident, because
none of those requests ever got past the edge. The canary - hitting the real CloudFront URL, the same
path a user takes - failed every run. That divergence is exactly why both SLIs exist; see
[ADR 011](adr/011-canary-and-alb-metrics-as-slis.md) for the full incident and
`docs/evidence/deployment-smoke.md` for the raw sequence.

**The freshness metric is not a live gauge.** `IngestionFreshnessSeconds`, the custom CloudWatch metric,
is published as a fixed `0.0` on every successful run - it records "ingestion just succeeded," not a
continuously aging value. The `tcgl01-data-freshness` alarm (`evaluation_periods = 1`,
`treat_missing_data = "breaching"`) only ever actually breaches when the metric is missing for a single
5-minute evaluation period - not when some computed staleness value crosses 900 seconds; a successful
run publishes `0.0`, which never exceeds the 900-second threshold on value alone. The *real*, live
freshness computation is `/api/meta/freshness`, queried fresh from the database on every request
(`now() - max(ingested_at)`); that is what the SPA's banner and the Synthetics canary both read, and
what the 99% / <=10 min objective in the table above is actually about. The alarm and the endpoint agree
on the same 900-second (15-minute) threshold for "stale," which is deliberately a wider margin than the
10-minute SLO - the alarm and the user-facing banner should not fire on every brief, sub-SLO wobble, only
on genuine staleness.

**The weekly-averages endpoint divides by 7, not by the number of rows it returns.** `GROUP BY
date_trunc('day', occurred_at)` over `occurred_at >= now() - interval '7 days'` produces up to **8**
calendar-date buckets, not 7 - `now()` is a moving instant, not midnight, so both the oldest and the
newest bucket in the window are partial days, and a partial day at each end of a 168-hour window can
land on 8 distinct calendar dates. The response's `average_per_day` is `sum(daily counts) / 7.0`
regardless of how many buckets came back, because the window is 168 hours (7 days) wide by construction
- dividing by the bucket count would inflate the average using date-label boundaries that have nothing
to do with the actual span of data. Captured live: the deployment smoke test returned 8 daily counts
(`[206, 345, 358, 334, 307, 297, 230, 68]`, summing to 2145) and `average_per_day: 306.43` -
`2145 / 7 = 306.4285...`, confirming the endpoint uses the window length, not the row count, as its
denominator.

## Revisit when

Multi-window burn-rate alerting (a slow, high-confidence window alongside the current fast one) and an
automated deploy-freeze tied to budget consumption are both open next steps, not implemented today - the
burn policy above is enforced by discipline, not tooling.
