# 006. Origin pinning: secret header plus ALB default-403

## Context

The ALB security group admits inbound traffic only from AWS's CloudFront managed prefix list
(`com.amazonaws.global.cloudfront.origin-facing`). That list is not scoped to this distribution - it is
shared by every CloudFront distribution in every AWS account. On its own, the rule proves "came through
some CloudFront edge," not "came through mine."

## Options considered

- **A. Security group only** (the prefix list), and accept the shared-list residual.
- **B. Security group plus a secret shared only between this distribution and this ALB, enforced at the
  listener.**

## Decision

B.

## Why

The residual in A is real and cheap to close, so leaving it open would be the actual mistake here.
CloudFront attaches a random, Terraform-generated value (`random_password.origin_verify`, 32
characters, never a Terraform output, live only in state) as a custom header on every request it sends
to the ALB origin. The ALB's `:80` listener no longer forwards by default at all - its default action is
a flat `403` - and a single listener rule at priority 1 forwards only when the `X-Origin-Verify` header
matches. Anything reaching the ALB directly, even from a genuine CloudFront edge IP, gets the same `403`
the security group would have returned if the IP check alone had failed. Verified directly at deploy
time: a request to the ALB's own DNS name, bypassing CloudFront entirely, is connection-blocked before
the header check is even reached.

## Revisit when

The ALB gets a real certificate and moves to HTTPS end to end - the header check still applies
unchanged, but it is worth confirming at that point that the header itself is never written to plaintext
access logs (access logging is off today; turning it on later needs this checked first).
