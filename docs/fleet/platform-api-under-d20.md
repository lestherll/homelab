# Platform API under D20 — impact note

**Status: parked, 2026-08-30.** Not scheduled, nothing to do yet. Recorded only
so the findings survive to the day the fleet actually changes. Companion to
`docs/adr/0001-single-model-talos-fleet.md`.

**The correction that matters.** ADR §10 originally claimed *"`infrastructure/`
is untouched. Not one file."* False. Six files change. The true claim is
narrower and still strong:

> **The API's spec surface is nearly untouched; its implementation is not.**

App authors see **one visible change** — `Application.spec.host` gains a cluster
suffix (§6 item 4) — and **one semantic change** — `persistence.size` stops being
documentation and becomes a real limit, because a Longhorn PVC is a real block
device where a hostPath directory was not. Everything else they write is
identical. `scratch`/`fast`/`bulk` survive untouched, because they name
guarantees rather than implementations.

## Three breakages to remember

1. **A persistent `Application` stops rolling out.** `replicas: 1` +
   `ReadWriteOnce` + default `RollingUpdate`. This works today only because
   there is one node (RWO means one *node*, not one pod), and survives
   multi-node local-path only because the PV's node affinity forces the
   replacement onto the same machine. **Longhorn breaks it** by removing that
   welding: the replacement schedules elsewhere, surge creates it before
   deleting the old, and the rollout stalls on Multi-Attach with nothing on the
   `Application` naming the cause. Fix: `strategy: Recreate` when persistence is
   set, landing *with* the Longhorn cutover.

2. **"These PVCs have no quota" inverts, and SeaweedFS depends on the old
   behaviour.** `seaweed-cluster.yaml`'s `volumeSizeLimitMB: 100` sizes writable
   slots off the backing filesystem's free space — its own comment says that is
   ~100 GiB, not the 5Gi PVC request. Under Longhorn the arithmetic runs against
   5Gi: ~50 slots instead of ~1000. Failure mode is the one that comment exists
   to prevent and that was root-caused live once already: `"No writable volumes
   and no free volumes left"`, a 500 from the S3 API that does not read as a
   capacity problem. **Resize the PVC in the same change, not as a follow-up.**

3. **Do not replicate twice.** CNPG, SeaweedFS and Longhorn all replicate;
   enabling all three is 9 copies of Postgres on a 5400rpm disk. CNPG
   replication buys *availability*, Longhorn buys *durability* — not
   substitutes. So: `Database` replicates at the app layer, `ObjectStorage` at
   the storage layer, `scratch` stays local-path.

## Files that change, when the time comes

`storage/provisioners.yaml` (deleted → Longhorn), `rgd-application.yaml`
(Recreate, host suffix, arch affinity), `rgd-database.yaml` (HA option),
`seaweedfs-runtime/seaweed-cluster.yaml` (PVC size, replication),
`tailscale-operator/helmrelease.yaml` (per-cluster tag),
`observability/helmrelease.yaml` (externalLabels).

`rgd-application.yaml` is the expensive one — it is the public API, so its
changes ripple into app repos and should land in one revision, before app repos
multiply.

## Also worth knowing

- **Verify, don't assume:** the per-`Application` `NetworkPolicy` keys on
  Tailscale `parent-resource` labels, which is topology-independent in
  principle — but AGENT.md records that Cilium's CNI chaining has traps, and
  cross-node identity is where they would surface.
- **What D20 unlocks**, stated once so it is not forgotten: `Database` can offer
  real HA (`rgd-database.yaml`'s *"No HA… consistent with D3"* is a hardware
  constraint wearing a decision's clothes), draining a node stops being an
  outage, and a `VirtualMachine` kind becomes expressible.
