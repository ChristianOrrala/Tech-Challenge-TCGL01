# Shared, non-secret Terraform variables for the demo environment.
#
# Committed on purpose: BOTH local runners (make.ps1 / Makefile) and the
# GitHub Actions deploy workflow read this file, so a toggle added here is
# picked up by every path with no drift. This is the single source of truth
# for the demo environment's non-secret configuration.
#
# What does NOT belong here: secrets and per-user values (alert_email -> local
# demo.tfvars / CI secret) and dynamic values (image_tag -> git sha), all
# passed separately on the command line.
enable_waf        = false
enable_cicd       = true
api_desired_count = 2
