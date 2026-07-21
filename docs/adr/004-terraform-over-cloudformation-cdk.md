# 004. Terraform over CloudFormation/CDK

## Context

The challenge leaves IaC tooling to the candidate. All three realistic options are AWS-native or
AWS-first, and the build runs under a short deadline with a live technical-review deploy to follow.

## Options considered

- **A. CloudFormation, or CDK on top of it.**
- **B. Terraform, S3 remote state.**

## Decision

B.

## Why

Terraform is the tool I work in at production depth - state, module boundaries, provider aliasing (used
here for the us-east-1 WAF exception), the plan/apply workflow. A take-home under a deadline is not
where to be even slightly slower in an unfamiliar tool. Terraform is also cloud-agnostic by
construction, which keeps every module's account and region assumptions explicit rather than implicit,
and its data-source pattern - availability zones, the CloudFront managed prefix list, the managed cache
and origin-request policies, all looked up by name instead of hardcoded - is what makes this stack
deployable into a fresh account with zero manual ID substitution.

## Revisit when

The target organization already runs a standing CloudFormation or CDK estate, where Terraform would be
the operational outlier - a different state backend, different drift detection, different CI tooling
than everything else in the account.
