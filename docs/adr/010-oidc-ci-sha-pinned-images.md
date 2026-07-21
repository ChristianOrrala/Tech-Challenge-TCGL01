# 010. OIDC CI with sha-pinned images; local builds are break-glass only

## Context

GitHub Actions needs AWS credentials to deploy. The traditional approach - a long-lived IAM user's
access keys, stored as a repository secret - is a standing credential that outlives any single workflow
run and has to be rotated by hand.

## Options considered

- **A. Long-lived IAM user access keys** as GitHub secrets.
- **B. GitHub's OIDC provider, federated to an IAM role** via `sts:AssumeRoleWithWebIdentity` - no
  stored AWS credentials at all, a fresh short-lived token per run.

## Decision

B, with the deploy role's trust policy pinned to this exact repository and branch, and every deployed
image tagged with the triggering commit's short sha rather than left floating on `:latest`.

## Why

A only gets worse over time - the keys sit in GitHub as a standing secret, valid until someone
remembers to rotate them, and a leak anywhere is a leak of real, reusable credentials. B has nothing to
leak between runs. Setting this up surfaced something worth recording on its own: GitHub now issues
OIDC subject claims in an id-embedded form (`repo:owner@<id>/repo@<id>:ref:...`), not only the
classic name-based `repo:owner/repo:ref:...` form most documentation still shows. The trust policy
accepts both, but the id-embedded value is the one that actually matters - it survives a repository
rename and cannot be reclaimed by someone else later registering the old name, which the name-based
form alone cannot promise. Sha-pinning images (in the deploy workflow's `docker push`, and in local
`make plan`, which injects `git rev-parse --short HEAD`) means the running task definition always names
an exact, traceable build, and `:latest` stays a convenience tag, never something anything actually
depends on. Local `terraform apply` and `make image` remain fully functional - a live technical-review
deploy has to work from any laptop, in any account, independent of whether CI is reachable - but the
deploy role additionally denies modifying its own policies or trust relationship, so even a fully
compromised CI run cannot widen its own access.

## Revisit when

Multiple environments (staging, production) need different deploy roles or different trust scopes per
branch. The current trust policy is deliberately single-repo, single-branch, and would need a matrix,
not just a wider pin.
