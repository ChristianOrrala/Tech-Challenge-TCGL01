# 007. Rolling deploys with circuit breaker, over blue/green

## Context

ECS Fargate supports two native rollout strategies: rolling updates (replace tasks in place, batch by
batch) natively, and blue/green (a full parallel task set, then a traffic cutover) via CodeDeploy. The
deploy story also has to survive a broken image being pushed - a scenario this project deliberately
drilled, not just designed for.

## Options considered

- **A. CodeDeploy blue/green.** A second target group, traffic shifting (linear or canary), automatic
  rollback wired to CloudWatch alarms.
- **B. Native ECS rolling deploy** with `deployment_circuit_breaker` (`enable` + `rollback`) and
  `deployment_minimum_healthy_percent = 100`.

## Decision

B.

## Why

The circuit breaker gets the property that actually matters here - a bad deployment rolls itself back
with no human in the loop - without a second target group, a CodeDeploy application and deployment
group, or extra alarms wired specifically for deployment gating. `minimum_healthy_percent = 100` means
the old, good tasks are never scaled down until new tasks are confirmed healthy, so capacity never dips
during a rollout. This is not a theoretical property: the rollback drill
(`docs/evidence/deployment-smoke.md`) deployed a task definition pointing at a nonexistent image tag on
purpose, and the circuit breaker detected the failed deployment and rolled back on its own, while an
uptime probe hitting the API every 30 seconds recorded 24 out of 24 successful responses across the
roughly 12 minutes the drill took. Blue/green would add finer-grained traffic-percentage canarying,
which this project's release cadence does not need.

## Revisit when

Releases need traffic-percentage canarying (ship to 10% of traffic before 100%) or a stronger
zero-capacity-dip guarantee even during the health-check grace period - both genuine advantages of
CodeDeploy blue/green over the rolling strategy used here.
