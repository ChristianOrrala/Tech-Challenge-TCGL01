# 003. ALB as the single API front door, no API Gateway

## Context

An ECS service needs a load balancer to be reachable at all, so an ALB exists in this stack regardless
of anything else. The open question is whether to also put API Gateway in front of it.

## Options considered

- **A. API Gateway** (REST or HTTP API), in front of the ALB via a VPC Link, for usage plans, per-route
  auth, or request/response transformation.
- **B. ALB only.**

## Decision

B.

## Why

This API needs none of what API Gateway adds: no API keys or usage plans, no per-route authorizer, no
payload transformation. Adding it anyway means a second managed service, a second place a request can
fail, and a second thing to explain during an incident, for zero incremental capability. The ALB is
already the natural place to enforce origin pinning ([ADR 006](006-origin-pinning-secret-header.md)),
since it is the one component that terminates CloudFront's forwarded request before ECS ever sees it -
adding a layer in between would just be another hop to reason about during that check.

## Revisit when

The API needs authentication or authorization enforced per route, request throttling per API key, or a
contract validated at the edge rather than in the app - all things API Gateway does well and this
project does not need today.
