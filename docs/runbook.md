# Runbook

## Deploy

### CI path (primary)

`deploy.yml` runs on every push to `main` that touches anything outside `docs/**` and `**.md`
(documentation-only pushes are intentionally excluded - see the header comment in the workflow), and on
manual `workflow_dispatch`. It is gated on the repository **variable** `DEPLOY_ENABLED` being exactly
`"true"`; unset or anything else, the job is skipped before it even checks out the repo.

Repository configuration it depends on, by exact name:

| Name | Kind | Purpose |
|------|------|---------|
| `AWS_DEPLOY_ROLE_ARN` | secret | OIDC role the workflow assumes via `sts:AssumeRoleWithWebIdentity` |
| `TF_STATE_BUCKET` | secret | S3 bucket backing Terraform remote state |
| `ALERT_EMAIL` | secret | SNS subscription email for the alarm topic |
| `DEPLOY_ENABLED` | variable | must be `"true"` or the job is skipped entirely |

What the job does, in order: assumes `AWS_DEPLOY_ROLE_ARN` (region `us-east-2`, account id masked in
logs); vendors `psycopg[binary]` for `manylinux2014_x86_64` / Python 3.12 into `ingestion/build/` and
copies in `handler.py` (identical to `make package-ingestion`, so CI and local produce the same
artifact); `terraform init` against the S3 backend using `TF_STATE_BUCKET`; logs in to ECR and builds
and pushes the API image under two tags, `:latest` and `:<short-sha>`; `terraform apply -auto-approve`
pinned to `image_tag=<short-sha>`, `enable_waf=true`, and `alert_email` from the secret; builds the SPA
(`npm ci && npm run build`) and syncs `app/web/dist` to the SPA bucket with `--delete`; invalidates the
CloudFront distribution (`/*`). Every AWS output the workflow reads comes from `terraform output -raw
<name>` against one named, non-sensitive output at a time - never a plain `terraform output` dump,
which would print every output including ones only marked sensitive at the root.

### Local path (break-glass)

For when CI is unavailable, or for the live technical-review deploy into an account CI has no access
to. All `make` targets assume a POSIX shell - **on Windows, run `make` from Git Bash**, not PowerShell
or cmd (the Makefile's own header comment says this; several recipes use shell constructs PowerShell
does not support).

| Target | Does |
|---|---|
| `make bootstrap STATE_BUCKET=<name>` | Creates, versions, and locks down (all public access blocked) the S3 state bucket |
| `make init` | `terraform init -backend-config=envs/demo/backend.hcl` |
| `make plan` | `terraform plan`, `image_tag` pinned to `git rev-parse --short HEAD` automatically |
| `make apply` | Applies the plan `make plan` produced |
| `make destroy` | `terraform destroy -var-file=envs/demo/demo.tfvars` |
| `make image` | Local Docker build/push to ECR, tagged `:latest` and `:<short-sha>` - needs Docker Desktop running |
| `make seed` | Invokes the ingestion Lambda once, on demand |
| `make package-ingestion` | Vendors `psycopg[binary]` for the Lambda runtime; not run automatically - `terraform plan`/`apply` reads whatever is already in `ingestion/build/` |

## Rollback

### Automatic - ECS deployment circuit breaker

`deployment_circuit_breaker { enable = true, rollback = true }`, with
`deployment_minimum_healthy_percent = 100` and `deployment_maximum_percent = 200`. A new deployment that
cannot reach a healthy steady state rolls itself back with no human action required, and the old,
healthy tasks are never scaled down until the new ones prove healthy - capacity never dips during a
rollout.

Proven, not just configured: a task definition revision pointing at a nonexistent image tag
(`:broken-drill`) was deployed on purpose. Observed service events:

```
(service tcgl01-api) has started 1 tasks ...
(service tcgl01-api) stopped 2 pending tasks.
(service tcgl01-api) (deployment ecs-svc/...) deployment failed: tasks failed to start.
(service tcgl01-api) rolling back to deployment ecs-svc/...
(service tcgl01-api) has started 1 tasks ... registered 1 targets ...
```

An uptime probe (`GET /api/meta/freshness` every 30 seconds) recorded **24/24** HTTP 200 responses
across the roughly 12 minutes the drill took - the circuit breaker declared failure and began rolling
back about 12 minutes after the broken deployment started. Full transcript:
`docs/evidence/deployment-smoke.md`.

### Manual rollback

The circuit breaker only helps if the bad revision fails its health checks. A revision that starts and
passes `/health` but is functionally wrong (a real application bug, not a crash) needs a deliberate
rollback:

```
terraform -chdir=infra apply -var-file=envs/demo/demo.tfvars \
  -var "image_tag=<previous-known-good-short-sha>" \
  -var "enable_waf=true" \
  -var "alert_email=<email>"
```

This is the state-consistent way to roll back - it moves the running task definition and Terraform
state together. For a faster, break-glass fix that bypasses Terraform (state will drift until the next
apply reconciles it, so follow up with the command above once things are stable):

```
aws ecs update-service --cluster tcgl01 --service tcgl01-api \
  --task-definition tcgl01-api:<previous-revision-number> --region us-east-2
```

Or, if the issue was a transient bad task rather than a bad image (nothing to roll back to, just needs a
clean restart):

```
aws ecs update-service --cluster tcgl01 --service tcgl01-api \
  --force-new-deployment --region us-east-2
```

## Alarm-by-alarm response

All 8 alarms notify the same SNS topic (`tcgl01-alerts`), with `ok_actions` mirroring `alarm_actions` on
every one - recovery pages just as visibly as the original alarm.

### `tcgl01-availability-fast-burn`

**Meaning:** white-box composite `1 - (ALB 5xx / requests)` dropped below 99% over the trailing hour.
**First checks:** the platform dashboard's "ALB Requests & 5xx Errors" and "Availability" widgets; ECS
service events for a recent or in-progress deployment; whether `tcgl01-canary-failing` is also alarming.
**Likely causes:** a bad deploy (check `tcgl01-api-tasks-below-desired` and ECS events together); a
database outage or exhausted connection pool (every `/api/*` route turns a `psycopg.Error` into a
uniform 503 - `docs/resilience.md`); a genuine bug at volume. This alarm is white-box only - if the
canary is *not* also alarming, the problem is on requests that already reached the ALB, not at the
edge; if it *is*, start there instead, since the underlying cause is usually upstream.

### `tcgl01-latency-p95`

**Meaning:** ALB `TargetResponseTime` p95 exceeded 300 ms for 3 consecutive 5-minute periods.
**First checks:** the RDS CPU/connections dashboard widgets; ECS CPU/memory widgets (each task is sized
at 256 CPU units / 512 MB, deliberately small); whether a task recently started (a brand-new task's
connection pool is empty - the first requests it serves pay a pool-fill cost; see `docs/resilience.md`).
**Likely causes:** RDS under query pressure, or `db.t4g.micro` CPU-credit exhaustion under sustained
(not just peak) load; a cold task absorbing traffic right after a deploy or a crash-replace; a query
pattern not covered by the existing indexes.

### `tcgl01-data-freshness`

**Meaning:** the `IngestionFreshnessSeconds` custom metric went missing for one 5-minute evaluation
period (`treat_missing_data = "breaching"` - silence pages, by design). This is a liveness signal for
the pipeline, not a live staleness gauge - see `docs/slo.md` for why.
**First checks:** `tcgl01-ingestion-failures` (the two usually fire together); CloudWatch Logs
`/aws/lambda/tcgl01-ingestion` for the most recent invocations; whether the EventBridge schedule rule is
still enabled.
**Likely causes:** the Lambda crash-looping or timing out (120 s function timeout; each USGS fetch has
its own 30 s request timeout); the USGS API unreachable or its response shape changed (`transform()`
defensively drops individual malformed features, but a total fetch failure raises and fails the whole
run); an IAM or Secrets Manager permission break.

### `tcgl01-ingestion-failures`

**Meaning:** the Lambda's `Errors` metric was >= 1 on 2 consecutive 5-minute periods.
**First checks:** read the actual exception in `/aws/lambda/tcgl01-ingestion`, not just the metric.
**Likely causes, roughly in checking order:** a USGS API outage or non-200 response; a database
connectivity problem (NAT gateway health, security-group rule, or the database mid-failover); a Secrets
Manager permission or throttling issue; a code regression in a recent ingestion change.

### `tcgl01-api-tasks-below-desired`

**Meaning:** fewer than 2 running tasks for 2 consecutive 5-minute periods
(`treat_missing_data = "breaching"` - no data reads as zero tasks).
**First checks:** the ECS service's **Events** tab first - it narrates exactly what is happening (image
pull failures, health-check failures, a circuit-breaker rollback already in progress); then target group
health status.
**Likely causes:** a bad image tag or pull failure; an out-of-memory kill (512 MB is tight under load);
`/health` failing for an application-process reason (it never touches the database, so a failure here is
not a data-layer problem); a deployment actively mid-rollback - this alarm and an in-progress rollback
can legitimately co-occur, check ECS events before assuming a second, unrelated problem.

### `tcgl01-rds-cpu-high`

**Meaning:** RDS `CPUUtilization` above 80% for 2 consecutive 5-minute periods.
**First checks:** the CPU widget's shape (spike vs. sustained); the connections widget; recent ALB
request volume.
**Likely causes:** a genuine traffic or query-volume increase; `db.t4g.micro` CPU-credit exhaustion
under sustained load (burstable instances degrade differently from fixed-performance ones - worth
distinguishing when reading the graph); a missing or unused index on a new access pattern.

### `tcgl01-rds-storage-low`

**Meaning:** `FreeStorageSpace` below 2 GB.
**First checks:** the trend, not just the current value.
**Likely causes, and the real gap to know about:** there is no data-retention or purge job in this
build - the `earthquakes` table grows without bound, and RDS storage autoscaling is not configured
(`allocated_storage = 20`, no `max_allocated_storage`). In this project, unbounded growth is a more
likely trigger than a traffic spike. Immediate relief:
`aws rds modify-db-instance --db-instance-identifier tcgl01-db --allocated-storage <n> --apply-immediately`;
the durable fix is raising `allocated_storage` in Terraform and re-applying. A retention job was
explicitly scoped out of this build - see `docs/resilience.md`.

### `tcgl01-canary-failing`

**Meaning:** Synthetics `SuccessPercent` below 100% for 2 consecutive 5-minute periods
(`treat_missing_data = "breaching"`).
**First checks: do not trust a 200 status code alone.** The one real incident this alarm caught looked,
at a glance, like a passing `200 text/html` response. What actually happened, worth re-reading before
assuming a new incident is different: the canary's Node `https` client sends no default `User-Agent`;
the WAF's `AWSManagedRulesCommonRuleSet` includes a `NoUserAgent_HEADER` rule and blocked every canary
request with a 403; CloudFront's own SPA error rewrite (403 -> `/index.html`, HTTP 200) turned that
block into what looked like a normal HTML page. The standing fixes (the canary identifies itself with a
real `User-Agent`; edge error-page caching is disabled so a stale cached rewrite can't mask a recovery
for up to 5 minutes) don't retire the general lesson: check the canary's actual run artifacts
(screenshots/HAR/logs in its S3 artifacts bucket, or its log group) and check WAF sampled requests for
blocks, before concluding the API itself is down.
**Likely causes:** a genuine API or SPA outage (the other alarms should agree); a WAF rule blocking
legitimate traffic (check sampled requests if `enable_waf = true`); a CloudFront or DNS problem upstream
of both origins.

## Fresh-account deployment guide

Target: clean clone to a live URL in under 45 minutes, with only the prerequisites below.

**Prerequisites:** AWS credentials for the target account active locally
(`aws sts get-caller-identity` succeeds); Terraform >= 1.11 (required for S3 native locking via
`use_lockfile`); Git Bash if on Windows; Docker Desktop, only if using the local `make image` path
instead of CI; Node 22, only if building the SPA locally instead of through CI; Python 3.12, always -
local `plan`/`apply` reads whatever `make package-ingestion` last vendored into `ingestion/build/`,
regardless of whether CI also packages it; `gh` authenticated, only needed for the CI-takeover step.

1. Clone the repository.
2. `make bootstrap STATE_BUCKET=<globally-unique-name>` - creates the state bucket. Not idempotent:
   re-running against a bucket that already exists fails on the create-bucket call, which is expected.
3. Copy `infra/envs/demo/backend.hcl.example` to `infra/envs/demo/backend.hcl` (gitignored) and fill in
   the real bucket name. Copy `infra/envs/demo/demo.tfvars.example` to `infra/envs/demo/demo.tfvars`
   (gitignored) and fill in a real alert email; leave or flip `enable_waf` (guidance below).
4. `make init`.
5. `make package-ingestion` - required before `plan`/`apply` even locally: the archive data source reads
   whatever is already in `ingestion/build/`.
6. `make plan` then `make apply`.

**The first-image chicken-and-egg.** The ECS task definition names
`<ecr_repo_url>:<image_tag>`. On a truly fresh account, neither the ECR repository nor any image under
that tag exists before the first apply - and that first apply is what creates the ECR repository.
Expect the first apply to finish with the ECS service unable to start any task (0 running,
`tcgl01-api-tasks-below-desired` alarming - correct behavior for a service with no prior successful
deployment to roll back to). Resolve it by pushing an image under that exact tag right after: `make
image` locally, or let the CI takeover below push it. If the image arrives while that first deployment
is still retrying, the service converges on its own. But the deployment circuit breaker's patience is
finite (roughly ten failed task launches at this desired count): leave the gap long enough and the
service events read `deployment failed: tasks failed to start`, it stops trying (0 running, 0 pending),
and re-running `terraform apply` will **not** revive it - the task definition is unchanged, so there is
no diff to act on. Kick it explicitly instead:

```
aws ecs update-service --cluster tcgl01 --service tcgl01-api --force-new-deployment
```

Observed for real in a redeploy rehearsal: a ~40-minute gap between the apply and the first image push
outlasted the breaker; one forced deployment later, the service was steady in under three minutes.

**CI takeover.** Once the first apply has produced a `deploy_role_arn` output, hand deploys to GitHub
Actions:

```
terraform -chdir=infra output -raw deploy_role_arn | gh secret set AWS_DEPLOY_ROLE_ARN --repo <owner>/<repo>
echo -n "<state-bucket-name>" | gh secret set TF_STATE_BUCKET --repo <owner>/<repo>
echo -n "<alert-email>" | gh secret set ALERT_EMAIL --repo <owner>/<repo>
gh variable set DEPLOY_ENABLED --body true --repo <owner>/<repo>
```

Then trigger `deploy.yml` (`workflow_dispatch`, or a push to `main` outside `docs/**`/`**.md`). Two
things to know before this works on a fork: the OIDC trust policy in `infra/modules/cicd/main.tf` is
pinned to a specific `owner/repo` (the `repo` variable passed from `infra/main.tf`'s `module "cicd"`
block) - a fork needs that value changed to its own `owner/repo` and re-applied before GitHub's OIDC
token is accepted at all. And `DEPLOY_ENABLED` is a repository **variable**, not a secret, specifically
so nothing sensitive is required just to gate whether the job runs - deliberate, so a fork (or this repo
before the controller is ready) attempts zero runs, red or green, until someone flips it on purpose.

**`enable_waf` guidance.** Leave it `false` (the default) for a first deploy into an unfamiliar or
locked-down account - it keeps the apply single-region and the permission/resource surface smaller
while the rest of the stack is being proven. Flip it to `true` (as the demo environment does) once the
base stack is healthy and the added us-east-1 WAF footprint is acceptable for that account.

**Timing.** RDS (Multi-AZ) and CloudFront are the two slow resources, roughly 15-20 minutes each;
Terraform parallelizes independent resources by default, so they run concurrently rather than back to
back. The one full apply timed during this project's own build was contaminated by the workstation
sleeping mid-run (the RDS waiter accumulated the sleep time; the instance was confirmed healthy and
untainted afterward), so that run's wall-clock number is not a valid reference for the 45-minute target
- a clean-room timing rehearsal (destroy, then a fresh timed apply) is the honest way to get one.

## Teardown

```
make destroy
```

`force_destroy = true` on both S3 buckets (the SPA bucket and the canary-artifacts bucket) and
`force_delete = true` on the ECR repository mean `terraform destroy` never gets stuck on "bucket not
empty" or "repository has images," with no manual emptying step first. That is a deliberate demo-only
convenience, and a trade-off worth naming honestly: in a production environment, the same settings would
let `terraform destroy` silently delete real data - deployed assets, canary run history, image
history - with no confirmation beyond Terraform's own destroy prompt. This project accepts that because
the environment exists to be stood up and torn down repeatedly; it is not the right default for a
bucket holding anything anyone would miss.

`make destroy` does **not** clean up the state bucket itself - `make bootstrap` created it outside
Terraform's own management, since it has to exist before `terraform init` can use it as a backend.
Decommissioning an account fully means emptying it (every version, since versioning is on) and deleting
it by hand afterward.

## Cost

Roughly **3-5 USD/day** for the demo configuration (`enable_waf = true`, `db.t4g.micro` Multi-AZ, 2
Fargate tasks at 0.25 vCPU / 0.5 GB, one NAT gateway). Composition, from published us-east-2 on-demand
pricing rather than a measured invoice:

| Component | Approx. |
|---|---|
| NAT gateway (hourly + data processing) | largest fixed cost, ~1.00-1.50 USD/day |
| RDS `db.t4g.micro`, Multi-AZ (2x instance-hours) | ~1.00-1.50 USD/day |
| ALB (hourly + LCU) | ~0.50-0.75 USD/day |
| Fargate, 2 tasks x 0.25 vCPU / 0.5 GB | well under 0.50 USD/day |
| WAF (`enable_waf=true`): base + managed rule groups + requests | ~0.20-0.30 USD/day |
| CloudFront, S3, Lambda, CloudWatch, Synthetics | a few cents each, low volume |

With `enable_waf = false`, drop the WAF row. This is sizing intuition, not a bill.
