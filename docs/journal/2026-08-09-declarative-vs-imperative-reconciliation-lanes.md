# Two reconciliation lanes: commit-triggered vs. API-triggered, both converge to git

**Date:** 2026-08-09 · **Tags:** gitops, architecture, incident-response

**Problem:** pure GitOps (commit is the only trigger) can't meet
session-oriented or time-critical operations' latency needs — a reconciler
poll/webhook cycle isn't request-latency-zero.

**Decision:** two lanes.
- Declarative (default): deployments, databases, promotions — commit is the
  only way to change these.
- Imperative (first-class, not an escape hatch): session lifecycle,
  break-glass incident fixes — triggered by direct API call, must converge
  back to git as a record within a bounded window (target <5 min).

**Break-glass procedure:** suspend reconciler watch on the resource → apply
direct fix → commit the fix so git matches reality → resume reconciliation.
Same shape as `flux suspend`/`resume`.

**Why:** forcing session-oriented resources through commit-and-reconcile
optimizes for the wrong thing. Comparable dev-platform systems split the
same way for the same reason.

**Alternatives considered:**
- Keep everything declarative, rely on short reconcile interval — rejected,
  treats a structural mismatch as a tuning problem and leaves break-glass
  with no defined procedure at all.

**Security impact:** break-glass is, by construction, the one place state
can diverge from git without review. Mitigation is bounded + logged +
mandatory closing commit, not that the risk disappears.

**Ref:** `CONCEPT.md` D14
