# Two more gotchas from the platform-API build: Flux prune timing, CEL struct strictness

**Date:** 2026-08-11 · **Tags:** flux, gitops, kro, kubernetes

**Problem:** two failures during the `fastapi-echo`/SeaweedFS migrations that
each cost real time and are worth not rediscovering.

**Findings:**
- **`kustomize.toolkit.fluxcd.io/prune: disabled`, applied imperatively to a
  live object, does not stop Flux from pruning it.** Flux's garbage
  collector evaluates prune-exclusion from the manifest it last *applied*,
  not from the object's current live state — so annotating a live object by
  hand and then removing it from git still gets it deleted on the next
  reconcile. Correct procedure for adopting a hand-written object into a
  typed instance of the same name: the annotation must be **in the
  manifest** and land via a normal Flux apply first (one PR), and only then
  can the manifest be swapped for the typed instance (a second PR). An
  imperative annotation is not a substitute for a declarative one here, even
  though the annotation *is* imperative-lane friendly in other contexts —
  this is the one place it doesn't stand in.
- **Optional-typed fields in a kro CEL ternary need `dyn(...)` on both
  branches, or the RGD fails to compile.** kro's static type checker
  validates literal map/list expressions against the real target Kubernetes
  struct, not just the branches of the ternary in isolation. `has(...) ? {
  ... } : null` on an object field fails because CEL can't unify a struct
  type with `null`; the same problem recurs on **list** fields too (e.g.
  `volumeMounts`), because even an all-string map literal gets unified
  against the real struct (which has non-string fields like `readOnly
  bool`), so an empty-list fallback branch doesn't save it. Fix: wrap both
  ternary branches in `dyn(...)` to resolve the result type to `dyn`.
  Neither failure is exotic once you've seen it, but both surface as a
  cryptic compile error on a field with no obvious connection to the one
  actually being added.

**Why:** the Flux one matters because "annotate it and then merge the
removal" looks safe and isn't — the failure is a real data loss (a live CNPG
cluster got rebuilt from scratch) rather than a reconcile error. The CEL one
matters because it recurs: any future optional object or list field on an
RGD schema hits the same unification rule.

**Ref:** `docs/self-service-platform-design-notes.md`, `infrastructure/platform-api/`
