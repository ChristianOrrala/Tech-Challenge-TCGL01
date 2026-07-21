# 012. Edge error-page caching disabled

## Context

CloudFront's `custom_error_response` rewrites both 403 and 404 responses to `/index.html` with a 200
status. The SPA has no router - these rewrites instead cover S3+OAC key-miss behavior and hard
refreshes of the single page, so a mistyped or stale path still lands on the app instead of a raw XML
error. That rewrite has its own cache TTL, separate from the cache behavior applied to ordinary
successful responses.

## Options considered

- **A. Leave `error_caching_min_ttl` at CloudFront's default** (5 minutes), same as any other cached
  response.
- **B. Set `error_caching_min_ttl = 0`** on both `custom_error_response` blocks.

## Decision

B.

## Why

The same incident behind [ADR 011](011-canary-and-alb-metrics-as-slis.md) exposed this one directly.
Once the canary's actual failure (a WAF block on the API path) got rewritten to a cached 200 by the
error-response behavior, that cached 200 would have kept being served to every subsequent request at
that edge location for up to 5 minutes, even after the underlying cause was fixed - a recovered API
would still look broken, or a broken API would still look recovered, purely because of what happened to
be cached at the edge. For a path whose whole job is reflecting the live state of the API - the SPA's
own error handling, the freshness banner, the canary's probe - a 5-minute cache on the error response
itself is a correctness bug, not a performance optimization worth keeping.

## Revisit when

Traffic volume makes the origin-request rate from uncached error responses worth worrying about -
unlikely at this project's scale, but the trade-off would need revisiting before raising the TTL back
up.
