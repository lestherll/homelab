# Longhorn cutover broke two assumptions local-path had been quietly holding up

**Date:** 2026-09-03 · **Tags:** storage, longhorn, platform-api, seaweedfs

**Problem:** two things local-path-provisioner's behavior had been masking,
both predicted in advance in `docs/fleet/platform-api-migration-impact.md` and both
confirmed live when `fast`/`bulk` moved onto Longhorn for the D20 metal build.

**Finding:**
- A persistent `Application`'s rollout (`replicas: 1`, RWO, default
  `RollingUpdate`) only worked because a local-path PV's node affinity welded
  the pod to the same machine it started on — a single-node accident, not a
  guarantee. Longhorn removes that welding: the replacement schedules
  elsewhere, surge creates it before deleting the old, and the rollout stalls
  on Multi-Attach with nothing on the `Application` naming the cause.
- SeaweedFS's `volumeSizeLimitMB: 100` sizes writable slots off the backing
  filesystem's free space, not the PVC request — its own comment assumed
  ~100 GiB free (the whole `bulk` disk under local-path). Under a real 5Gi
  PVC that arithmetic gives ~50 slots instead of ~1000, surfacing as `"No
  writable volumes and no free volumes left"`, a 500 from the S3 API that
  doesn't read as a capacity problem.

**Decision:** `rgd-application.yaml`'s Deployment strategy is now
`Recreate`, applied unconditionally rather than only when persistence is set
(an `Application` can gain persistence later, and a strategy that silently
becomes wrong on an unrelated edit is worse than a moment of downtime on
every rollout). SeaweedFS's volume PVC was raised from 5Gi to 20Gi in the
same change.

**Why:** both fixes had to land *with* the Longhorn cutover, not as a
follow-up — the failure modes give no signal pointing at the real cause
(a stalled rollout names nothing; the S3 500 looks like a capacity problem).

**Validation:** `rgd-application.yaml` and `seaweed-cluster.yaml` both carry
comments recording the reasoning at the point of change.

**Ref:** `docs/fleet/platform-api-migration-impact.md` (the impact note this
confirmed), commit `f107227` ("Build the D20 cluster on machine 2, and move
fast/bulk onto Longhorn")
