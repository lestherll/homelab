# Credential granularity sized by blast radius, not by resource type

**Date:** 2026-08-01 · **Tags:** security, credential-design, iam

**Decision:** granularity follows blast radius, not a uniform default.
- Build runner, coding environment → per-project (executes/holds
  credentials for arbitrary repo-supplied code).
- Deployer → per-environment (dev/prod genuinely differ; per-project adds
  machinery without reducing real blast radius).
- Image puller → per-namespace (falls out of Kubernetes for free).
- Reconciler → single, cluster-wide (needs to see everything by definition;
  splitting it is theatre).
- Backup agent → single, append-only (scope the target, not the identity —
  write-only so a compromise can't destroy history).

**Why:** answers the "too much machinery" objection directly — fine-grained
scoping is paid for only in the two places (build, coding env) where it
actually reduces blast radius, nowhere else.

**Ref:** `CONCEPT.md` D11
