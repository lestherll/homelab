# Promoted Database/ObjectStorage/Application to typed API at 1 instance each, skipping the 3-instance rule

**Date:** 2026-08-10 · **Tags:** platform-engineering, kro, kubernetes

**Problem:** D1's promotion rule (3 hand-built instances before a typed API)
guards against guessing an abstraction's shape too early — but waiting costs
real time before self-service exists at all.

**Decision:** promote `Database`/`ObjectStorage`/`Application` to layer 2 via
kro `ResourceGraphDefinition`s at one hand-built instance each.

**Why:** a kro RGD doesn't fail the way D1's rule protects against — it's
cheap to revise in place, and an additive schema change re-reconciles every
existing instance untouched (confirmed live: added fields to `Application`'s
schema, running instance unaffected). Moves the risk from "wrong
abstraction, expensive to fix" to "kro's own API is v1alpha1" — real, but
smaller.

**Validation:** `fastapi-echo` (Database) and `personal-finance-dashboard`
(Application + ObjectStorage) both live and serving.

**Follow-up:** sharing proof (2nd Application on same ObjectStorage),
reclaim check, breaking-schema-change negative test — named in design, not
yet run. Tracked in Linear.

**Ref:** `CONCEPT.md` D15, `docs/self-service-platform-design-notes.md`
