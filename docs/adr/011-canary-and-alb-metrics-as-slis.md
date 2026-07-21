# 011. Black-box canary and white-box ALB metrics as complementary availability SLIs

## Context

"Is the API available" can be measured from at least two vantage points: from outside the system,
exercising the exact path a real user takes, or from inside, off the ALB's own request accounting.

## Options considered

- **A. White-box only.** `1 - (ALB 5xx / requests)` as the sole availability SLI.
- **B. Both.** A Synthetics canary hitting the live CloudFront URL every 5 minutes, alongside the same
  white-box ALB metric.

## Decision

B.

## Why

The two views can disagree, and this project has direct proof they did. During bring-up, the Synthetics
canary failed every run - not because the API was down, but because the WAF's
`AWSManagedRulesCommonRuleSet` blocked the canary's requests for carrying no `User-Agent` header, and
CloudFront's SPA error rewrite (403 turned into a 200 HTML page) made the block look like a successful
response at a glance. Through the entire incident, the white-box ALB metric would have read as fully
healthy, because a WAF block never reaches the ALB at all - there is no 5xx to count for a request that
never arrived. A real user hitting that same edge path would have seen exactly what the canary saw: a
broken experience the origin-side metric had no way to detect. That is the whole argument for keeping
both - white-box tells you about the service once a request reaches it, black-box tells you whether a
request gets there in the first place, and an edge-layer problem (WAF, CloudFront configuration, DNS)
only shows up in the second one. Full incident sequence:
`docs/evidence/deployment-smoke.md`.

## Revisit when

The canary and the white-box metric diverge in the other direction often enough to be noisy - canary
flakiness unrelated to real availability. At that point the canary's own success criteria need
revisiting, not the decision to run one at all.
