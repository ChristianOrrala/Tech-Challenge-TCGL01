# 013. Managed master password and a secret-out-of-state posture

## Context

An RDS instance needs a master credential. Anywhere that credential's value gets typed, generated, or
stored by hand is a place it can leak - into Terraform state, into a chat log, into a `.tfvars` file
committed by accident.

## Options considered

- **A. Generate a password** (`random_password`), pass it into `aws_db_instance` as a plain argument.
- **B. `manage_master_user_password = true`.** No password argument anywhere; RDS creates and owns a
  Secrets Manager secret for it.

## Decision

B.

## Why

Option A puts the plaintext password into Terraform state - a well-known place secrets end up
unintentionally, and this project's state already lives in S3 specifically so it never has to touch the
repository. Option B removes the value from state entirely: it is never generated, never seen, never
passed anywhere in HCL. What both the API task and the ingestion Lambda actually receive is a Secrets
Manager ARN - resolved into a container-injected secret at task start for the API, through its
execution role, and fetched with `boto3` at invocation for the Lambda, through its own role. The
credential's plaintext exists only inside AWS's own secret store and briefly in each consumer's memory.
This is one instance of a rule applied everywhere in this stack: nothing sensitive lives in code, and
the one place state itself could leak something is closed by keeping the S3 state bucket private,
versioned, and outside version control - `backend.hcl` and any real `.tfvars` file are gitignored,
populated only from environment variables or copied and edited locally.

## Revisit when

A secret needs application-level rotation logic beyond what RDS's own managed rotation provides. Today
neither consumer reads a specific secret version - both fetch current on every cold start or invocation,
which is enough at this project's scale.
