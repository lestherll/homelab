# kro operational gotchas found building the platform API RGDs

**Date:** 2026-08-10 · **Tags:** kro, kubernetes, platform-engineering

**Problem:** building the `Database`/`ObjectStorage`/`Application` RGDs on
kro v0.9.3 surfaced several behaviors that are either undocumented or easy to
misread from the docs, most of them findable only by spiking against a live
cluster rather than by reading.

**Findings:**
- **`rbac.mode: unrestricted` (the chart default) grants kro cluster-wide
  access to everything.** Use `rbac.mode: aggregation` instead, and grant
  every kind an RGD renders — including the RGD's own generated instance
  CRDs — through a ClusterRole labelled
  `rbac.kro.run/aggregate-to-controller: "true"`
  (`infrastructure/platform-api/rbac-kro-aggregate.yaml`). Missing a kind
  here fails at reconcile time with a permission error, not at apply time.
- **kro's own `Ready` condition means "the graph rendered," not "the
  attachment refs resolved" or "the workload is healthy."** An instance with
  a typo'd or cross-namespace ref still shows `Ready: True`. A custom status
  field (e.g. `attachmentsResolved`) is required, and it must **not** be
  named `ready` — that name is silently shadowed by kro's own condition in
  every default `kubectl get` table view.
- **`additionalPrinterColumns` can only be set correctly at CRD create
  time.** `config.allowCRDDeletion: false` (the default) means deleting an
  RGD does not delete the CRD it generated — recreating the RGD *adopts* the
  existing CRD, and printer-column changes on an adopted CRD are silently
  ignored. Fixing them later means deleting the CRD outright, which deletes
  every instance of that type in the cluster. Get printer columns right on
  the very first create.
- **An attachment whose `ref` matches nothing still renders its child
  resources**, with an empty/zero-count payload — the render is not blocked.
  The workload then fails downstream (e.g. `CreateContainerConfigError` on a
  Secret that doesn't exist) rather than the instance failing to reconcile.
  "The instance reconciled" and "the workload can start" are separate
  questions; surface unresolved refs in status, don't rely on kro blocking.
- **Teardown order is instances → RGD → CRD, never RGD-first.** Deleting the
  RGD removes the controller for its generated kind while existing instances
  still carry `kro.run/finalizer`; with no controller left to clear it, the
  instances become undeletable and both the CRD delete and the namespace
  delete hang behind them. Recovery needs a manual
  `kubectl patch ... -p '{"metadata":{"finalizers":null}}'` per orphaned
  instance.
- **A defaulted sub-field defeats `has()` on the parent block.** kro emits
  `"default": {}` on a custom-type field whenever *any* of its sub-fields has
  a default, so the API server materializes the block on every instance that
  omits it and `has(schema.spec.<block>)` is always true. Gate optional
  blocks on a specific leaf field that itself carries no default, never on
  the parent — this bug shipped silently in a prior revision (every app was
  getting a phantom 1Gi PVC) because `has()` looked like it should work.

**Why:** none of these are wrong per se, they're just non-obvious enough
that each would otherwise be found expensively — Finding on printer columns
in particular only surfaces when trying to fix a cosmetic detail on a type
that already has real instances, which is exactly when deleting the CRD is
unacceptable.

**Ref:** `infrastructure/platform-api/`, `docs/self-service-platform-design-notes.md`
