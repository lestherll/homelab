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

## Outstanding

- **SeaweedFS volume migration is staged, not executed.** The class change is in
  git; the PVC still has to be recreated by hand, because a StatefulSet's
  `volumeClaimTemplates` are immutable — the operator cannot roll this for us.
  The runbook is below.

### Runbook: moving `mount0-seaweed-volume-0` to the bulk tier

Only ~468K of data at the time of writing, and the source PV is `Retain`, so a
botched run loses nothing — the old directory stays until it is deliberately
removed. Because local-path volumes are plain host directories, the copy is a
host-level `cp`, not an in-cluster Job.

```sh
# 1. Stop Flux fighting the scale-down. Do this BEFORE merging the class
#    change: applied against a live StatefulSet, the new storageClassName is
#    rejected as an immutable-field update and the Kustomization goes NotReady.
flux suspend kustomization infrastructure-seaweedfs-runtime

# 2. Drop the StatefulSet (PVC survives; volumeClaimTemplates are immutable,
#    so the operator cannot update it in place).
kubectl delete sts seaweed-volume -n seaweedfs --cascade=foreground

# 3. Release the old claim. The PV is Retain — the data directory persists.
kubectl delete pvc mount0-seaweed-volume-0 -n seaweedfs

# 4. Let the operator rebuild against local-path-bulk, then stop it again so
#    the copy lands underneath a process that isn't writing.
flux resume kustomization infrastructure-seaweedfs-runtime
kubectl scale sts seaweed-volume -n seaweedfs --replicas=0

# 5. Copy old -> new on the host (paths from `kubectl get pv`).
sudo cp -a /var/lib/rancher/k3s/storage/<old-pv>_seaweedfs_mount0-seaweed-volume-0/. \
           /mnt/storage/k8s-volumes/<new-pv>_seaweedfs_mount0-seaweed-volume-0/

# 6. Back up, and verify the bucket still lists its objects.
kubectl scale sts seaweed-volume -n seaweedfs --replicas=1
```

Only once the bucket reads correctly: delete the old PV object and `rm -rf` its
directory.

- **One orphaned PV — resolved 2026-08-11.** `pvc-9da4a7e4-…`
  (`fastapi-echo/fastapi-echo-db-1`) was `Released` with `Retain` and stranded.
  Worth remembering as a class of problem: `Retain` means a deleted PVC leaves
  both a `Released` PV object *and* its directory behind, and nothing ever
  reclaims either. Every `local-path-retain` and `local-path-bulk` volume will
  do this. Deleting the PV object does not delete the data.
- **No backup target.** 870G of empty spinning disk is the natural home for the
  off-host backup CONCEPT.md C9/S4 flags as deferred. Not designed, not built.
  Note that an on-host backup on a second disk protects against disk failure and
  fat-fingering, not against losing the machine.
