# Global Earthquake Monitoring System - SRE Technical Challenge

A resilient, cloud-native system that ingests, stores, and serves global earthquake
data from the USGS on AWS. Built with Terraform, ECS Fargate, Lambda, RDS PostgreSQL,
and CloudFront, the goal is a production-grade deployment - complete with SLOs,
alarms, an on-call runbook, and architecture decision records (ADRs).

## Status

Work in progress. Documentation and infrastructure-as-code land commit by commit as
the build progresses.

## Layout

- `docs/` - architecture, SLOs, runbook, ADRs
- `infra/` - Terraform IaC
- `app/` - application services
- `ingestion/` - USGS data ingestion pipeline
