# 005. CloudFront and edge WAF, opt-in and off by default

## Context

The stated region constraint is us-east-2. AWS requires CLOUDFRONT-scope WAF Web ACLs to be created in
us-east-1 regardless of where the distribution or its origins actually live, so any edge WAF at all
means a second region touches the account. There is also no custom domain for this project, which
affects how HTTPS gets served at all.

## Options considered

- **A. WAF REGIONAL scope, attached directly to the ALB.** Stays entirely in us-east-2; no CloudFront
  needed at all.
- **B. CloudFront plus WAF CLOUDFRONT-scope, hardcoded on.**
- **C. CloudFront plus WAF CLOUDFRONT-scope, behind a boolean toggle (`enable_waf`), default off.**

## Decision

C.

## Why

CloudFront earns its place independent of the WAF question: it is what makes a bare HTTPS URL possible
with no ACM certificate and no domain to own (the CloudFront default certificate covers `*.cloudfront.net`
for free), and it is the single origin serving both the SPA and the API under one host. Once CloudFront
is in the picture, the WAF question becomes "is a us-east-1 footprint acceptable" - and that answer
genuinely varies by target account policy, so it should not be a silent default either way. The toggle
keeps the stack's baseline posture at zero us-east-1 resources - nothing declared, nothing planned,
nothing billed - while still letting an environment where the footprint is fine turn on AWS managed rule
sets plus a per-IP rate limit. The demo environment runs with it on specifically so the WAF path gets
exercised with real evidence rather than left as an unverified toggle - see
`docs/evidence/deployment-smoke.md` for the incident that exercise actually found. Whichever way the
toggle is set, the ALB's origin-pinning ([ADR 006](006-origin-pinning-secret-header.md)) is the control
that is always on; losing the WAF's managed rule sets and rate limiting with the toggle off is a real,
accepted trade-off, not a gap missed by accident.

One more trade-off rides along with CloudFront, separate from the WAF question: the CloudFront-to-ALB
hop is plain HTTP (`origin_protocol_policy = "http-only"`), because the ALB has no certificate.
Viewer-to-CloudFront stays HTTPS regardless of the WAF toggle. Acceptable for a build with no domain,
where that hop never leaves AWS's own network - a production build with a real domain would put an ACM
certificate on the ALB and move this to HTTPS end to end.

## Revisit when

The target account has a standing domain and ACM certificate available (changes the HTTP-origin
trade-off), or a client's own policy fixes the WAF answer either way, removing the need for a toggle at
all.
