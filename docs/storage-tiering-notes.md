# Storage tiering notes

Why this host has two storage tiers, what belongs on each, and what is still
outstanding. Written 2026-08-11 after a root-filesystem audit.

## The hardware asymmetry

The host has two disks, and they are not interchangeable:

| Device | Model | Size | Rotational | Mount |
|---|---|---|---|---|
| `sdb` | LITEON CV8-8E128 | 119G | no (SSD) | `/` (108G LVM), `/boot`, swap |
| `sda` | ST1000LM035-1RK1 | 931G | **yes, 5400rpm** | `/mnt/storage` (ext4, by UUID in fstab) |

The obvious reading of "root is filling up, there's a 931G disk sitting empty"
is *move state to the big disk*. That reading is half wrong: `/mnt/storage` is a
5400rpm 2.5" laptop drive. Bulk sequential data belongs there. Anything
latency-bound does not, and moving it there would trade a disk-space problem for
a much less legible performance one.

## What was actually on root

Measured 2026-08-11 with root at 48G/108G used. Kubernetes was not the problem:

| Path | Size | Notes |
|---|---|---|
| `/usr/share/ollama` + `/usr/local/lib/ollama` | 17.5G | models (13G) + runtime libs (4.5G) |
| `/var/lib/rancher/k3s/agent` | 13G | containerd image/snapshot store |
| `/home/lestherll` | 9.5G | incl. 4.4G legacy podman storage in `.local/share/containers` |
| `/var/lib/rancher/k3s/storage` | **1.9G** | *every* PV on the cluster |
| `/var/log` | 320M | 202M of it journal |

The thing this document is about — Kubernetes persistent volumes — was 1.9G, or
4% of what was used. **Tiering is about future headroom, not about reclaiming
space today.** The immediate space is in ollama, containerd, and podman, none of
which this repo manages.

Acting on that took root from 48G to 39G the same day: `k3s crictl rmi --prune`
recovered ~6G of unreferenced containerd layers (live images went 3.4G → 2.0G,
40 tags → 25), and a `podman system reset` recovered the 4.4G legacy stack —
images *and* the four volumes of the pre-k3s podman monitoring setup, which are
gone for good. Ollama's 17.5G was left alone deliberately; it is out of scope for
this repo and is now ~46% of everything on the SSD.

Re-audited 2026-08-13: root still 39G/106G, so nothing had crept back. containerd
sat at 6.3G against 2.1G of live images across 29 tags — the prune held, and the
regrowth predicted below is slow, not immediate. Ollama remains the single
largest consumer at 45%. Note the audit ran unprivileged (`sudo` on this host
needs interactive auth, so `du` cannot descend into `/var/lib/rancher`); the
root-only remainder came from kubelet's stats API instead, via
`kubectl get --raw /api/v1/nodes/homelab/proxy/stats/summary`.

Two findings worth recording separately:

- **containerd's 13G is mostly garbage that will never be collected.** kubelet
  reports 3.4G of live images across 40 tags; the rest is unreferenced layers
  and snapshots. Image GC is threshold-driven (`imageGCHighThresholdPercent`,
  default 85%) and root sits at 48%, so it never fires. It will keep growing
  until it crosses 85% of a 108G disk — i.e. it self-corrects only at ~92G.
- **local-path enforces no quota whatsoever.** A PV is a plain hostPath
  directory, so `df` inside every pod reports the *root filesystem*, not the
  claim. Prometheus believes it has a 10Gi volume; nothing stopped it consuming
  every free byte on the SSD. The `resources.requests.storage` field on these
  PVCs is documentation, not a limit. This is why `retentionSize` was added to
  the Prometheus spec — for local-path volumes, application-level limits are the
  only real ones.

## The tiers

| Class | Backing | Reclaim | For |
|---|---|---|---|
| `local-path` (default) | SSD | Delete | regenerable/disposable state |
| `local-path-retain` | SSD | Retain | D4-durable state that is latency-bound |
| `local-path-bulk` | **HDD** `/mnt/storage/k8s-volumes` | Retain | D4-durable state that is large and sequential |

Placement rules, in the order they actually get argued about:

- **Postgres (CNPG) stays on the SSD.** WAL fsyncs are latency-bound; a 5400rpm
  drive is the wrong home regardless of database size.
- **Prometheus stays on the SSD.** Constant writes plus block compaction. It is
  also explicitly *disposable* per CONCEPT.md §D4 — there is nothing to protect,
  so paying a performance cost to relocate it buys nothing. Bound its size with
  `retentionSize` instead.
- **SeaweedFS volume data belongs on the HDD.** Large, sequential, and the one
  component on the platform designed to grow without bound. This is the
  motivating case for the tier.
- **The SeaweedFS filer does not.** It looks like it should move with the volume
  data it indexes, but it's a leveldb metadata store: small (340K against the
  volume's 468K when the two were split) and random-access, paying its latency
  on every object lookup. Opposite access pattern, opposite tier. The split is
  the useful precedent here — "which component" is the wrong granularity for
  this decision, "which access pattern" is the right one.
- **Grafana and Alertmanager are 1Gi each and not worth moving.**

## Mechanism: a second provisioner, not a reconfigured one

The obvious implementation — repoint the existing provisioner at `/mnt/storage`
— does not survive. The `local-path-config` ConfigMap in `kube-system` carries
`objectset.rio.cattle.io/owner-name: local-storage`: it is a k3s *packaged
addon*, re-applied from `/var/lib/rancher/k3s/server/manifests/` on every k3s
start. Hand edits revert silently at the next restart, and on this host k3s
restarts more often than you'd think (see AGENT.md on Wi-Fi carrier loss).

The supported way to own it is `--disable local-storage` in the k3s config plus
managing the provisioner ourselves. That was rejected: it needs a k3s restart,
it deletes the addon's objects — including the cluster's *default* StorageClass
— in a window before Flux recreates them, and it makes every future k3s upgrade
our problem.

Instead, `infrastructure/storage/` runs a **second** local-path-provisioner
instance in its own `storage-bulk` namespace, distinguished only by
`--provisioner-name homelab.local/local-path-bulk`. Each provisioner claims only
the StorageClasses whose `provisioner:` field matches its own name, so the two
coexist without contention. k3s's addon is untouched; `local-path` and
`local-path-retain` behave exactly as before. Cost is one extra ~10Mi pod.

The `bulk_storage` Ansible role creates `/mnt/storage/k8s-volumes` and — more
importantly — **asserts the disk is mounted**. Without that guard, an unmounted
`/mnt/storage` turns the bulk tier into a directory on the SSD, silently doing
the exact opposite of what the tier is for.

## Runbook: moving a StatefulSet's PVC between tiers

Executed 2026-08-11 for `mount0-seaweed-volume-0` (SSD → bulk). Kept because
this is the generic procedure for *any* operator-managed StatefulSet volume, and
two steps in it are not obvious.

A StatefulSet's `volumeClaimTemplates` are immutable, so changing
`storageClassName` in the Seaweed CR does not roll the volume — the claim has to
be recreated by hand. Because local-path volumes are plain host directories, the
copy is a host-level `rsync`, not an in-cluster Job.

```sh
# 1. Suspend BEFORE merging the class change: applied against a live
#    StatefulSet, the new storageClassName is rejected as an immutable-field
#    update and the Kustomization goes NotReady.
flux suspend kustomization infrastructure-seaweedfs-runtime
# ... merge the class change ...

# 2. Drop the StatefulSet and release the old claim. The PV is Retain, so the
#    old data directory persists untouched.
kubectl delete sts seaweed-volume -n seaweedfs --cascade=foreground
kubectl delete pvc mount0-seaweed-volume-0 -n seaweedfs

# 3. Let the operator rebuild against the new class. The claim is
#    WaitForFirstConsumer, so it only binds once the pod schedules — the pod
#    has to come up (empty) before the destination directory exists at all.
flux resume kustomization infrastructure-seaweedfs-runtime

# 4. Now stop it again for the copy. Suspending Flux is NOT enough: the
#    seaweedfs-operator owns the replica count and reconciles the StatefulSet
#    straight back to the CR's volume.replicas. The operator has to come down
#    too, or `scale --replicas=0` silently reverts within seconds.
kubectl scale deploy seaweedfs-operator -n seaweedfs --replicas=0
kubectl scale sts seaweed-volume -n seaweedfs --replicas=0
kubectl wait --for=delete pod/seaweed-volume-0 -n seaweedfs --timeout=90s

# 5. Mirror old -> new (exact paths from `kubectl get pv`). --delete makes this
#    a directory-level restore, overwriting the vol_dir.uuid the empty server
#    wrote at startup, so the volume server comes back as the same store and
#    re-registers its volumes with the master.
sudo rsync -a --delete \
  /var/lib/rancher/k3s/storage/<old-pv>_seaweedfs_mount0-seaweed-volume-0/ \
  /mnt/storage/k8s-volumes/<new-pv>_seaweedfs_mount0-seaweed-volume-0/

# 6. Back up, operator last.
kubectl scale sts seaweed-volume -n seaweedfs --replicas=1
kubectl scale deploy seaweedfs-operator -n seaweedfs --replicas=1
```

**Verify by reading an object's bytes, not by listing.** Filer metadata lives on
a different volume from the object data, so a bucket lists its contents
perfectly while every read fails — listing proves nothing about whether the copy
worked. Fetch a known file through the filer and check its content.

Note the volume server's readiness probe is `periodSeconds: 90`, so the pod sits
at `0/1` for up to a minute and a half after each restart with nothing wrong.

If the objects don't come back, bounce `seaweed-master-0`: the master rebuilds
topology from volume-server heartbeats, and it has been hearing "empty" for the
duration of the migration.

**Confirmed after the move:** the master reported `Max: 8900` writable slots,
up from the SSD-derived figure — SeaweedFS sizes slots from the backing
filesystem's free space, so relocating a volume silently changes what
`volumeSizeLimitMB` computes against. Worth re-reading that comment in
`seaweed-cluster.yaml` whenever a volume moves.

## Resolved, kept for the reusable lessons

- **The pre-migration SeaweedFS PV — reclaimed 2026-08-13.**
  `pvc-aa811e20-74b5-427f-8c39-7f97ca70518c`, the `Released`/`Retain` rollback
  holding ~468K of pre-move volume data on the SSD, was dropped two days after
  the move once the bulk tier had proven itself. Both deletions were needed: the
  PV object, then the directory by hand.

  The check that justified dropping it is the reusable part, and it is not "the
  pods are `Running`" — a volume server comes up healthy against an empty store.
  Read the master's `/dir/status` instead and confirm two numbers: `Max: 8900`,
  which is HDD-derived and so proves the server is sized against the bulk tier
  rather than the SSD, and 14 registered volumes, which proves the copied store
  re-registered rather than starting fresh. Both together say the rsync landed.

- **One orphaned PV — resolved 2026-08-11.** `pvc-9da4a7e4-…`
  (`fastapi-echo/fastapi-echo-db-1`) was `Released` with `Retain` and stranded.
  Worth remembering as a class of problem: `Retain` means a deleted PVC leaves
  both a `Released` PV object *and* its directory behind, and nothing ever
  reclaims either. Every `local-path-retain` and `local-path-bulk` volume will
  do this. Deleting the PV object does not delete the data.

**Still open:** no backup target. 870G of empty spinning disk is the natural
home for the off-host backup CONCEPT.md C9/S4 flags as deferred — not
designed, not built, tracked as LES-68. Note that an on-host backup on a
second disk protects against disk failure and fat-fingering, not against
losing the machine.
