# Incident response (blameless)

The runbook covers the mechanics - which alarm means what, what to check, how to roll back. This
document covers the practice around it: how an incident is classified, who does what, and how the team
learns from it without blaming anyone. The two are one system: detection and response are automated and
documented so that the human energy goes where it actually matters, into understanding and preventing
recurrence.

## Why blameless

An incident is treated as a failure of the system - the architecture, the tooling, the process, the
defaults - never of a person. When something breaks the question is always "what about the way we built
this let it happen, and what do we change so it cannot happen the same way again," never "who did it."

This is not a courtesy, it is what makes the postmortem accurate. Engineers who fear being blamed hide
the messy details, round off the timeline, and stop at the first plausible cause. Engineers who know the
review is blameless report the near-misses, admit what they did not understand, and dig until they reach
the systemic cause. Psychological safety is the precondition for a true root cause, so it is the first
rule, not a soft one.

## Lifecycle

Detection and response are already built; the last step, learning, is the one that needs a stated
process.

1. **Detect** - automated, no human polling. Eight CloudWatch alarms and the Synthetics canary publish
   to one SNS topic; `ok_actions` mirror `alarm_actions` so a recovery pages as loudly as the original
   alert. Nobody watches a dashboard waiting for trouble.
2. **Classify** - the responder assigns a severity (below) from user impact and error-budget risk.
3. **Respond** - `docs/runbook.md` is the first-response reference, alarm by alarm: first checks, likely
   causes, and the real incident each alarm has already caught. Mitigation paths - circuit-breaker
   rollback, `force-new-deployment`, the graceful-degradation behavior that keeps reads serving while
   ingestion is down - are documented there and in `docs/resilience.md`.
4. **Recover** - confirm the SLI is back inside its objective and the alarm has cleared (the mirrored
   `ok_action` makes that explicit).
5. **Learn** - for qualifying incidents, a blameless postmortem (below).

## Severity

Severity is set by what the user experiences and how fast the error budget is burning, not by how
alarming the graph looks.

| Sev | Definition | Example here | Response |
|---|---|---|---|
| **SEV1** | User-facing outage, or the availability SLO actively burning fast | Canary down; `tcgl01-availability-fast-burn` firing; the API returning 5xx broadly | Page now, all hands, postmortem required |
| **SEV2** | Degraded but serving - user-visible, SLO at risk but not breached | Data stale (`tcgl01-data-freshness`), p95 over budget, a single-AZ or single-task loss | Page, mitigate promptly, postmortem required |
| **SEV3** | No user impact yet - a trend that will become SEV2/1 if ignored | `tcgl01-rds-storage-low`, CPU-credit balance trending down | Handle in hours, postmortem optional |

## Roles

Honest about scale: on this project today one on-call engineer wears every hat, and that is fine for the
size. The roles are named so the split is clear the moment the team grows past one, not so a demo can
pretend to have a NOC:

- **Incident commander** - owns the incident, decides, keeps the timeline. Not necessarily the person
  typing the fix.
- **Operations** - drives the actual mitigation (the runbook hands-on work).
- **Communications** - keeps stakeholders informed on status and expected recovery.

At SEV1 with more than one responder, these separate so the commander is not also head-down in a
terminal. Below that, one person holds them all.

## The blameless postmortem

Written for every SEV1 and SEV2, and for any month the error budget is breached. It contains:

- **Summary** - what happened, in two or three sentences.
- **Impact** - who or what was affected, for how long, measured against the SLO (minutes of budget
  spent), not guessed.
- **Timeline** - detection, key decisions, mitigation, recovery, in UTC.
- **Contributing causes** - deliberately plural. Real incidents rarely have one cause; they have
  several system behaviors that lined up. Each is described as a property of the system, not an act of a
  person: "the deploy proceeded before the image existed," never "so-and-so forgot to push it."
- **What went well, what was missing** - the detection and response worked or did not; say which.
- **Action items** - concrete, owned, and tracked to done. A postmortem with no shipped action items
  did not prevent anything.

### Tie to the error budget

A breached availability SLO is itself a postmortem trigger, and it activates the burn policy in
`docs/slo.md`: feature deploys freeze, reliability work takes priority, and normal cadence resumes only
once the trailing-month budget recovers. The error budget is what turns "we should be more reliable"
from an opinion into a decision the whole team already agreed to.

## Worked example: a real blameless postmortem

Not hypothetical - this happened during bring-up and is the template for how one reads. Full technical
detail in `docs/evidence/deployment-smoke.md` and [ADR 011](adr/011-canary-and-alb-metrics-as-slis.md).

**Summary.** The Synthetics canary reported a failure on every run while the response it received was a
clean `HTTP 200 text/html`. The check looked like it was passing at a glance; it was not.

**Impact.** Caught during initial deployment, before any real traffic, so zero user-facing budget was
spent. The value was in what it exposed: a way for a blocked request to be reported as a success.

**Timeline.** Canary went red; the 200 was not trusted; the canary's own run artifacts and the WAF's
sampled requests were pulled rather than assuming the API was fine; root cause reached three layers
down.

**Contributing causes (systemic, no person named).**
1. Node's `https` client sends no default `User-Agent` header.
2. The managed WAF rule set blocks requests with no `User-Agent`.
3. CloudFront's SPA error-page rewrite turned the resulting 403 into a cached 200, masking the block as
   a healthy response.

No single one of these is a mistake by anyone; three reasonable system behaviors interacted into a
false negative.

**What went well.** The dual black-box / white-box SLI design (ADR 011) held: the white-box ALB metric
stayed correctly clean throughout, because a request blocked at the edge never reaches the ALB to
generate a 5xx. That disagreement between the two signals was the diagnostic clue, not a flaw.

**Action items (all shipped).** The canary now sends a real `User-Agent`; `error_caching_min_ttl` was
set to 0 so an edge error can never be cached as a success ([ADR 012](adr/012-disable-edge-error-caching.md));
both are recorded as decisions, not buried in a commit.

**The blameless point.** Every fix targeted the system - a missing header, a caching default, the
observability design - and the incident made the architecture stronger. At no point was the useful
question "who misconfigured the canary." That is the practice, on a real incident, not a slogan.
