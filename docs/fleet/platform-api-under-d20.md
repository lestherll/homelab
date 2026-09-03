# Platform API under D20 — impact note

**Status: resolved, 2026-09-04.** Written 2026-08-30 to record findings ahead
of the fleet actually changing; the Longhorn cutover has since landed and all
three breakages below are fixed in the live manifests — see the note under
each. Kept as the accounting of what one layer's migration cost the layer
above it (`docs/fleet/golden-architecture.md` §4.2/§5 cites this document by
name). Companion to `docs/adr/0001-single-model-talos-fleet.md`.

**The correction that matters.** ADR §10 originally claimed *"`infrastructure/`
is untouched. Not one file."* False. Six files change. The true claim is
narrower and still strong:

> **The API's spec surface is nearly untouched; its implementation is not.**

That sentence is the **Infrastructure → Platform API boundary**, priced. In the
layering of `docs/fleet/golden-architecture.md`, this whole document is the
record of what one layer's migration costs the layer above it — and every item
below is either a leak across that boundary (§5 there) or proof there isn't one.

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
   `Application` naming the cause. Fix: `strategy: Recreate`, landing *with* the
   Longhorn cutover.
   **Resolved** — `rgd-application.yaml`'s Deployment template sets
   `strategy: type: Recreate` unconditionally (not only when persistence is
   set — an `Application` can gain persistence later, and a strategy that
   silently becomes wrong on an unrelated edit is the worse failure).

2. **"These PVCs have no quota" inverts, and SeaweedFS depends on the old
   behaviour.** `seaweed-cluster.yaml`'s `volumeSizeLimitMB: 100` sizes writable
   slots off the backing filesystem's free space — its own comment says that is
   ~100 GiB, not the 5Gi PVC request. Under Longhorn the arithmetic runs against
   5Gi: ~50 slots instead of ~1000. Failure mode is the one that comment exists
   to prevent and that was root-caused live once already: `"No writable volumes
   and no free volumes left"`, a 500 from the S3 API that does not read as a
   capacity problem. **Resize the PVC in the same change, not as a follow-up.**
   **Resolved** — `seaweed-cluster.yaml`'s volume PVC is `20Gi` (up from the
   5Gi this note was written against), landed with the Longhorn cutover.

3. **Do not replicate twice.** CNPG, SeaweedFS and Longhorn all replicate;
   enabling all three is 9 copies of Postgres on a 5400rpm disk. CNPG
   replication buys *availability*, Longhorn buys *durability* — not
   substitutes. So: `Database` replicates at the app layer, `ObjectStorage` at
   the storage layer, `scratch` stays local-path.
   **In effect** — this is a standing rule now that Longhorn is live, not a
   one-time fix; no `Database` instance runs CNPG replicas on a `bulk`/`fast`
   PV, and it stays that way by convention rather than by anything enforced.

## Files that change, when the time comes

Two of six have landed: `rgd-application.yaml` (Recreate — the host-suffix and
arch-affinity parts have not) and `seaweedfs-runtime/seaweed-cluster.yaml`
(PVC size). `storage/provisioners.yaml` (still there — `scratch` keeps its
local-path instance, only `fast`/`bulk`'s provisioners left it),
`rgd-database.yaml` (HA option), `tailscale-operator/helmrelease.yaml`
(per-cluster tag) and `observability/helmrelease.yaml` (externalLabels) are
still ahead — they're multi-cluster/N=3 prep, not Longhorn-cutover items, so
they wait on machine 1's rebuild rather than on anything above.

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
