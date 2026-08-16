# Handoff — Talos migration, after phases 0–3

Working file, not repo content. Durable knowledge lives in
`docs/talos-terraform-migration-notes.md` (design + forced-changes list) and
`terraform/README.md` (operating manual). Delete when stale.

## State as of 2026-08-16

A single-node **Talos cluster is running** at `10.10.0.10`, built entirely by
`terraform apply`. **k3s is still `active` and untouched** — that is the
fallback and it must stay that way until cutover.

- Talos v1.13.8 / Kubernetes v1.36.2, node `talos-cp-01`, Ready.
- Cluster is still empty beyond its own control plane. Flux has **not** been
  pointed at it.
- Both data tiers mounted: `u-fast` → `/var/mnt/fast` (`/dev/vdb1`),
  `u-bulk` → `/var/mnt/bulk` (`/dev/vdc1`), matched by disk **serial**.

Phase 3 is **written but not run**. Everything below is manifest work validated
by `kubectl kustomize` + `helm template` + `terraform validate`; none of it has
reconciled against a live cluster, because none of it can until cutover.

## Branch state

**PRs #37–#40 are merged to `main`** (via #42), so `ansible/`, `terraform/`,
`docs/` and `AGENT.md` are all on the trunk. `terraform/` is live on main;
the cutover is not.

Worth knowing how that went, because the same shape will recur: the stack was
merged bottom-up but its base branch had *already* merged to main and was not
deleted, so GitHub never retargeted, and all four PRs landed on
`docs/reclaim-seaweedfs-rollback-pv` instead of the trunk. It looked merged and
was not. #42 was the follow-up that actually reached main. If you stack again,
check `git log origin/main..<branch>` rather than the PR list.

**`feat/talos-cutover-infra` is the only branch left**, rebased onto main:

```
main
 └─ feat/talos-cutover-infra   infrastructure/, terraform/, docs/, CONCEPT.md
```

It **must not merge until cutover day** — it repoints the live bulk tier at
guest-only paths, installs a second metrics-server APIService, and breaks
`Application.persistence`. That is the whole reason it is a separate branch.

`feat/talos-terraform-migration` is the original unsplit branch and is now
redundant — safe to delete.

## Getting access (the scratchpad copies are gone)

Group membership needs a fresh login; until then prefix libvirt commands with
`sg libvirt -c "..."`.

```bash
sops --decrypt terraform/clusters/homelab/talos-secrets.sops.yaml > /tmp/ts.yaml
mkdir -p /tmp/talos && (cd /tmp/talos && talosctl gen config homelab https://10.10.0.10:6443 --with-secrets /tmp/ts.yaml -o .)
talosctl --talosconfig /tmp/talos/talosconfig -n 10.10.0.10 -e 10.10.0.10 kubeconfig /tmp/kubeconfig
```

Terraform needs the PKI in the *other* format:

```bash
cd terraform/clusters/homelab
export TF_VAR_machine_secrets="$(sops --decrypt --output-type json machine-secrets.sops.json)"
```

`kubectl` against **k3s** needs `KUBECONFIG=~/.kube/config` explicitly — the
default picks up `/etc/rancher/k3s/k3s.yaml`, which is `0600 root`.

## What Phase 3 built (branch `feat/talos-cutover-infra`)

**LES-94 — storage.** Three provisioner instances in one `storage` namespace,
classes renamed to state the guarantee, **no default class**:

| Class | Provisioner | Path | Reclaim |
|---|---|---|---|
| `scratch` | `homelab.local/scratch` | `/var/lib/local-path-provisioner` (system disk) | Delete |
| `fast` | `homelab.local/fast` | `/var/mnt/fast` (20 GiB) | Retain |
| `bulk` | `homelab.local/bulk` | `/var/mnt/bulk` (100 GiB) | Retain |

Consumers repointed: CNPG and the SeaweedFS filer → `fast`; SeaweedFS volume
data and VictoriaMetrics → `bulk`; Alertmanager and Grafana → `scratch`.

**Prometheus went to `fast`, not the mechanical `scratch`** — an 8GiB
`retentionSize` does not belong on a 20 GiB system disk shared with etcd and
containerd layers, and a fixed-size volume bounds a cardinality spike that the
old unbounded hostPath could not. This was a judgement call, not the rename
table; revisit it if the `fast` tier gets crowded.

**LES-95 — metrics-server.** Plus two prerequisites the issue did not list:
`rotate-server-certificates` on the kubelet (a **Terraform** change) and a
vendored `kubelet-serving-cert-approver` v0.11.0. A Talos kubelet self-signs;
without both halves the scrape fails x509 and `kubectl top` just says "metrics
not available".

**Observability cleanup.** k3s `(apiserver|etcd)_.*` drop removed;
etcd/controller-manager/scheduler monitors disabled; `hostNetwork` reconsidered
and deliberately kept.

**`Application.persistence` → PVC.** `hostPath` replaced by `size`/`tier`.
First breaking change to the platform API.

## Next task: LES-96, the cutover

Prerequisites are now written. What remains before the cutover runbook in
`docs/talos-terraform-migration-notes.md` can be followed:

- **The watchdog** (forced change #5) — CronJob + SOPS secret replacing the
  systemd timer. The only forced change still unbuilt that is not deferred.
- **Land the PR stack.** All five, in order.
- **Dump and verify** Postgres + bucket data. The runbook is explicit that the
  verified dumps *are* the safety net, since there is no second machine.

## Outstanding smaller items

- **Ansible idempotency re-run not done.** The pool-autostart fix landed after
  the pools were created by hand, so `changed=0` is unconfirmed and pools will
  not autostart across a host reboot until this runs:
  `sudo ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/converge.yml --tags host_prereqs,bulk_storage,cli_tools`
  (needs a TTY — sudo is not passwordless here.)
- **Domain autostart declared but unproven** — needs a host reboot.
- **Tailscale operator behind NAT unverified** (LES-89) — check at cutover.
- **LES-102** — sparse images can overcommit the host disk with no warning.
- **LES-97** — node-exporter relocation, deferred by decision; power metrics
  will be dark after cutover, which is accepted, not a bug to chase. The
  `supplementalGroups: [600]` key is kept in the HelmRelease for its return —
  do not "clean it up".
- **personal-finance-dashboard's own repo** must drop `persistence.hostPath`
  or its `Application` stops reconciling after cutover. Its host-side CLI dies
  with it, as planned.
- **Re-measure Prometheus after cutover.** Both `retention: 15d` and
  `retentionSize: 8GiB` were sized against a k3s TSDB whose series count was
  dominated by the duplication that no longer happens.

## Traps that cost time — do not rediscover

- **The VM subnet must miss the Kubernetes service CIDR.** `10.100.0.0/24` sits
  inside `10.96.0.0/12`. Symptom is etcd stuck on "Waiting for etcd spec" with
  no stated cause; the reason appears only in
  `talosctl dmesg | grep diagnostic`. Now `10.10.0.0/24`.
- **libvirt provider 0.9.x uses nested attributes, not blocks.** Every 0.8.x
  example fails to parse.
- **`machine.certSANs` omission fails as a hang, not an error** — the bootstrap
  resource retries a condition that can never clear.
- **Talos enforces PodSecurity `baseline`**, which forbids `hostPath` outright.
  This bites the storage provisioners, whose helper pods bind-mount the node
  path — hence `enforce: privileged` on the `storage` namespace. It fails at
  first PVC, not at deploy. Debug pods need the same treatment; see
  `terraform/debug-pod.yaml`.
- **`terraform destroy` refuses outright** while the data volumes exist. Rebuild
  with `-target=module.cluster.libvirt_domain.node -target=module.cluster.libvirt_volume.system`.
- **Never write into k3s's data paths** (`/var/lib/rancher/k3s/storage`,
  `/mnt/storage/k8s-volumes`). Only mistake here that fails silently and
  permanently. `bulk_storage` still creates the latter on purpose — it holds
  k3s's bulk PV data, which is the fallback.
