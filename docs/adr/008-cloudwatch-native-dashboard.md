# 008. CloudWatch-native platform dashboard over an in-app view

## Context

The three product views in the SPA (recent, weekly, top) are what the challenge doc asks for. Separately,
an operator needs a view of the platform itself: request rate, error rate, latency, task and database
health, ingestion health, alarm state.

## Options considered

- **A. A fourth, operator-facing view built into the React SPA**, backed by some new metrics-serving
  endpoint.
- **B. A Terraform-defined CloudWatch dashboard**, no application code involved.

## Decision

B.

## Why

The metrics an operator needs already exist as CloudWatch metrics the moment the underlying resources
exist - ALB, ECS, RDS, Lambda, and Synthetics all publish natively. A dashboard here is configuration,
not a feature to build, test, and keep in sync with the app. Option A would mean writing and
maintaining a second API surface whose entire job is re-exposing data CloudWatch already has, for a
challenge that explicitly said the app itself is not the point. The dashboard (`tcgl01-platform`) is
defined entirely in `infra/modules/observability/dashboard.tf`, versioned with everything else, and
reproducible in any account the stack deploys into.

## Revisit when

Non-engineers need this view - a CloudWatch dashboard requires AWS console access. At that point a
lightweight, separate status-page-style read replica of the key metrics is the right next step, not
folding platform monitoring into the product SPA.
