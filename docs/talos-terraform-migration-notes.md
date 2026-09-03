# Talos + Terraform: why the platform is shaped this way

**Executed 2026-08-16.** This document used to be the full viability
assessment and build diary for moving off bare-metal Ansible/k3s onto a
Terraform-provisioned Talos VM — options weighed, questions tracked to
resolution, an hour-by-hour execution log. That process is finished and the
outcome is simply how the platform works now, so this page keeps only the
rationale that still explains a real decision. The build-time gotchas and the
decision trail live in the journal: `docs/journal/2026-08-16-talos-terraform-migration.md`
and `docs/journal/2026-08-16-libvirt-talos-vm-build-gotchas.md`. The
operating manual is `terraform/README.md`; the executed cutover procedure is
`docs/talos-cutover-runbook.md`.

## Why a hypervisor layer instead of bare-metal Talos

Ubuntu stays on the metal as a hypervisor; Terraform provisions one Talos VM
under libvirt. The alternative — re-imaging the host straight to bare-metal
Talos — was rejected because it is one irreversible cutover with no fallback
machine. Keeping Ubuntu underneath means the Talos VM is built *beside* a
still-running system: if a rehearsal fails, nothing is lost. `terraform
destroy && terraform apply` also turns "does the platform bootstrap from
zero" from an unrehearsable question into a routine test, which is the
bigger long-term payoff — see `terraform/README.md` for the ownership
boundary this produces (Ansible owns the metal, Terraform owns the VM and
cluster lifecycle, Flux owns everything under `infrastructure/`).

The tradeoff accepted knowingly: `/sys/class/powercap` does not exist inside
a KVM guest, so RAPL power metrics are unavailable to an in-cluster
node-exporter and the power dashboards in `infrastructure/observability/` are
dark. Reconnecting them needs a node-exporter running on the host itself
(tracked as LES-97), not a cluster-side config change.

## Storage: the cluster knows disk *roles*, never disk *paths*

This is the principle behind `infrastructure/storage/`'s three classes
(`scratch`/`fast`/`bulk`, detailed in `docs/storage-tiering-notes.md`) and it
is still load-bearing:

| Layer | What it knows | Vocabulary |
|---|---|---|
| Ansible (host) | that an SSD and an HDD exist, and which image file lives on which | `/`, `/mnt/storage` |
| Terraform | virtual disks, each stamped with a stable serial | `system`, `fast`, `bulk` |
| Talos machine config | a CEL selector per disk → `/var/mnt/fast`, `/var/mnt/bulk` | disk serials |
| Cluster (Flux) | provisioners rooted at `/var/mnt/*` | StorageClass names |
| App author | "1Gi of fast storage at /app/data" | `size`, `tier` |

Hardware appears only in the first row. Two things follow from it, both still
true today:

- **Disks are matched by serial, not by device name.** `vdb`/`vdc` enumeration
  order is not stable across a disk being added or reordered; a libvirt
  `<serial>` plus a Talos CEL selector survives it. Verified end-to-end
  including a destroy/recreate — see the journal entry above.
- **No StorageClass is default.** A PVC naming none stays `Pending` — loud and
  immediate — instead of silently landing on the wrong tier. The cost is one
  explicit `storageClassName` on every PVC the repo manages; all of them
  already are.

## `Application.spec.persistence` is a PVC, not a host path

The platform API's one hardware leak was `rgd-application.yaml`'s
`persistence.hostPath`, which required an app author to type a path under a
specific user's home directory on the specific host. It is now:

```yaml
persistence:
  size: 1Gi              # default "1Gi"
  tier: fast              # enum fast|bulk, default "fast"
  mountPath: /app/data    # default, unchanged
```

This mirrors the existing `size: small|medium` idiom used elsewhere in the
API, so it adds no new concept for an app author while deleting the only
field that required knowing anything about the machine — which is also what
makes an app's `deploy/` directory portable to a future non-prod cluster
unchanged.

## Secrets stay out of Terraform state

The Talos PKI is generated out of band (`talosctl gen secrets`) and
SOPS-encrypted rather than produced by a `talos_machine_secrets` resource.
Terraform has no state encryption at any version, so if Terraform generated
the PKI, `terraform.tfstate` would be the only copy of the cluster's root CA
— a second root secret sitting beside the age key, which D12 says should not
exist. Generating it out of band and feeding it through the provider's
ephemeral resources and write-only arguments means state holds no
authoritative key material; a real `terraform plan` prints them as
`(write-only attribute)`. Full detail in `terraform/README.md`.

---

# Alternative A — bare-metal Talos (kept in full; not covered by this page's cleanup)

**`docs/adr/0001-single-model-talos-fleet.md` cites this section by name** as
the bare-metal plan it revives: *"a second machine arrives... recorded as
Alternative A in `docs/talos-terraform-migration-notes.md` and never
eliminated, only deprioritised... This decision is the scheduled re-pricing,
and it concludes that Alternative A now wins."* That ADR still reads
"DRAFT," but the bare-metal build it describes is **already under way**
(`clusters/homelab-metal/` is real — see `AGENT.md`'s Description). So this
section isn't a dead rejected-alternative record any more — it's the closest
written account of the plan actually being built. Kept verbatim rather than
trimmed for that reason, and out of scope for this doc's cleanup pass; it
gets reconciled with the in-progress build together with the ADR, separately.

The coupling audit, mapping table and forced `infrastructure/` changes below
were accurate for the (superseded, not built) plan to re-image the host
straight to bare-metal Talos, skipping the hypervisor layer. Two things in it
are historical rather than planned: the cutover runbook's dump/restore steps
(the actual migration was greenfield — nothing on the old cluster was worth
carrying) and its framing of verified dumps as the safety net (the fallback
that was actually used is `systemctl start k3s`, described above). Read them
as a record of the bare-metal plan, not as instructions — except insofar as
D20 revives it.

## What moves where (Ansible → Talos/Terraform mapping)

| Today (Ansible on Ubuntu) | Under Talos + Terraform |
|---|---|
| `k3s_server` role (get.k3s.io installer, `config.yaml`, kubeconfig copy) | `siderolabs/talos` TF provider: `talos_machine_secrets` → `talos_machine_configuration` → `talos_machine_configuration_apply` → `talos_machine_bootstrap` → `talos_cluster_kubeconfig`. `tls-san` → `cluster.apiServer.certSANs` (include the tailscale IP). `disable: [traefik, servicelb]` is a no-op — Talos ships vanilla k8s, neither exists. No k3s token exists to migrate (installer-generated, never in inventory). |
| `host_prereqs` sysctl (`net.ipv4.ip_forward`) | `machine.sysctls`. Trivial. |
| `host_prereqs` ufw (9100/6443 scoped to tailscale0, 22 open, FORWARD=ACCEPT) | Dies. No host firewall on Talos. Accepted delta: API server and node-exporter ports exposed on the domestic LAN. The SSH rule vanishes with sshd itself. |
| `host_prereqs` RAPL udev rule + `rapl` group GID 600 | **Not expressible** (no custom udev rules, no group management, no arbitrary file writes). Replacement: a small privileged DaemonSet that only chgrp/chmods `/sys/class/powercap/**/energy_uj` (mounts nothing else, no hostPID, busybox image, re-applies on a short loop for late-appearing zones). The pod half (`securityContext.supplementalGroups: [600]` on node-exporter) is unchanged. `runAsUser: 0` on node-exporter stays rejected — on Talos, mounting host `/` exposes the STATE partition (machine config = cluster CA), arguably worse than `/etc/shadow` + age key today. |
| `bulk_storage` (mount assert + mkdir) | `UserVolumeConfig` mounts the HDD under `/var/mnt/<name>` (Talos mounts user volumes there, not `/mnt/storage`). The assert becomes unnecessary — the mount is declarative. The `local-path-bulk` nodePathMap path must follow. |
| `cli_tools` (age, flux, sops, helm, kubectl-cnpg, awscli on the host) | Whole role vanishes — Talos has no shell or package manager. Re-home to the operator workstation (mise/nix, or a slimmed Ansible kept *only* for workstation tooling), plus `talosctl`. |
| `heartbeat_watchdog` (systemd timer + curl + ntfy, on-host by design) | Not expressible on Talos (no file writes, no user systemd). Replacement: in-cluster CronJob that curls `alertmanager.tailf4742d.ts.net/-/healthy` and pings an external dead-man's switch (healthchecks.io-style) only on success; the external service pages ntfy when pings stop. Ping URL in SOPS. |
| Host tailscaled (preinstalled, untouched by Ansible, but load-bearing: tls-san, API-over-tailnet, watchdog's MagicDNS) | Siderolabs Tailscale **system extension** via Image Factory schematic; auth key as a TF-managed secret. In-cluster tailscale-operator is untouched. |
| Flux bootstrap (one-off CLI, committed gotk manifests) | `flux_bootstrap_git` in Terraform + pre-seeding the `sops-age` Secret, keeping "one bootstrap process, one key". The deploy key is read via a SOPS TF data source, so the chain still terminates at the one age key (D12). |
| ansible.cfg / become / sudo-rs workaround | Vanishes with Ansible-on-host entirely. |

## Forced changes in `infrastructure/`

1. **Own SSD provisioner.** k3s ships the `rancher.io/local-path` provisioner;
   Talos ships nothing, but `local-path` (3 observability PVCs) and
   `local-path-retain` (CNPG, SeaweedFS filer; provisioner field immutable on
   the class) both name it. Copy the proven bulk-provisioner pattern (raw
   Deployment + ConfigMap + RBAC) for an instance named `rancher.io/local-path`,
   path on the SSD/EPHEMERAL. Cannot merge while k3s is live — two same-named
   provisioners would race the same PVCs. Merges with the migration PR on
   cutover day. The namespace needs `pod-security.kubernetes.io/enforce:
   privileged` — Talos enforces `baseline`, baseline forbids `hostPath`, and
   every one of these provisioners works by launching a helper pod that
   bind-mounts the node path.
2. **`local-path-bulk` nodePathMap** → the new `/var/mnt/...` path. Also
   replace `DEFAULT_PATH_FOR_NON_LISTED_NODES` with the explicit node name —
   harmless while every cluster is single-node, load-bearing the day one grows.
3. **Add `metrics-server` HelmRelease.** Talos doesn't bundle it. This is a
   three-part change: the HelmRelease itself, plus
   `machine.kubelet.extraArgs.rotate-server-certificates: true` (a Terraform
   change — a Talos kubelet self-signs its serving certificate otherwise) and
   `kubelet-serving-cert-approver` vendored alongside it (kube-controller-manager
   deliberately does not auto-approve `kubernetes.io/kubelet-serving` CSRs, so
   without it the CSR sits Pending and the symptom is identical to doing
   nothing). `--kubelet-insecure-tls` was rejected as a one-line alternative:
   defensible on one machine, wrong the day a second one arrives and nobody
   remembers it's set.
4. **Observability HelmRelease cleanup.** Drop the k3s one-process
   metricRelabelings workaround (it matched `(apiserver|etcd)_.*` on
   `__name__` alone, safe only because k3s guaranteed a duplicate under
   `job="apiserver"` — on Talos there's no duplicate, so the same rule would
   silently eat genuine kubelet series); disable `kubeEtcd`/
   `kubeControllerManager`/`kubeScheduler` monitors (Talos serves these with
   its own PKI); keep node-exporter's `hostNetwork: true` (turning it off
   would move the netdev/netclass collectors into the pod's network namespace
   and report the wrong interfaces).
5. **Watchdog CronJob + SOPS secret** replacing the systemd timer.
6. **`Application` RGD `persistence`** — replace the hostPath field with a
   PVC (`size`/`tier`/`mountPath`), since a per-user home directory path
   cannot be satisfied on a machine with no home directories. Named casualty:
   the host-side CLI workflow for personal-finance-dashboard dies; that CLI
   moves into a container. This is the API's first breaking change.
7. **RAPL DaemonSet** (item 3 in the mapping table above).
8. **GitHub-OIDC apiserver args** re-express as `cluster.apiServer.extraArgs`
   when D16 is built.

## Terraform shape

```
terraform/
  modules/talos-cluster/     # secrets, machine config, apply, bootstrap,
                             # kubeconfig, flux bootstrap, sops-age
  clusters/homelab/          # the current laptop, re-imaged — cluster #1
  clusters/homelab-nonprod/  # placeholder until hardware arrives — cluster #2
```

When machine #2 arrives: fill in `clusters/homelab-nonprod/`, one
`terraform apply`, one `clusters/homelab-nonprod/` Flux dir. Set
`allowSchedulingOnControlPlanes: true` (single-CP clusters). tfstate contains
the Talos PKI and the git deploy key → local state with an encrypted backup
stored alongside the age key; record it as a second root secret next to
D12's one.

## Honest cost sheet

- One risky cutover with no fallback machine — mitigated only by a VM
  rehearsal and verified dumps.
- Backups remain unbuilt (LES-68). Hand migration moves the data once; the
  *next* rebuild kills it again.
- Two clusters later = two platform stacks (observability, operators).
- Host-coupled workflows die: the finance-app host CLI, host-side `aws`
  testing, SSH-into-the-server anything.
- LAN-exposed API/metrics ports replace the ufw tailnet-only posture.
- etcd/scheduler/controller-manager metrics remain absent.
- tfstate is a second root secret unless Talos secrets are later derived
  rather than generated.

## Coupling audit summary

- Storage classes: `infrastructure/storage/` — `local-path` is k3s's (not in
  repo); `local-path-retain` and `local-path-bulk` are repo-defined; bulk
  config in `bulk-provisioner-config.yaml` pins `/mnt/storage/k8s-volumes`
  for `DEFAULT_PATH_FOR_NON_LISTED_NODES`.
- PVC consumers: observability (Prometheus 10Gi, Alertmanager 1Gi, Grafana
  1Gi — all `local-path`), VictoriaMetrics 2Gi (`local-path-bulk`), SeaweedFS
  volume 5Gi (`local-path-bulk`) + filer 1Gi (`local-path-retain`), CNPG
  1Gi/5Gi (`local-path-retain`).
- Raw hostPath: `platform-api/rgd-application.yaml` `persistence.hostPath`
  (`type: Directory`) — only known consumer: personal-finance-dashboard.
- Tailscale exposures (4): grafana, alertmanager Ingresses; one per
  `Application` instance. No `loadBalancerClass: tailscale` Services.
- Secrets: `ntfy_topic` (ansible), `operator-oauth`, grafana-admin (SOPS/age);
  `sops-age` Secret is created out-of-band and must be pre-seeded on the new
  cluster before the `infrastructure` Kustomization can decrypt.
- Flux: `clusters/homelab/flux-system/` + `infrastructure.yaml` and
  `infrastructure-seaweedfs-runtime.yaml` Kustomizations; tracks `main`.
- k3s-only config surface: `ansible/roles/k3s_server/templates/config.yaml.j2`
  (`disable: [traefik, servicelb]`, `node-ip`, `tls-san`) — nothing else; no
  registries.yaml, no apiserver args, no CNI config anywhere.
