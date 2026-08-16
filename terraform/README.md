# terraform/ — VM and cluster lifecycle

Terraform owns the layer between the metal and the cluster: the libvirt domain
and volumes, the Talos machine config, and bootstrap. It owns nothing above
that line and nothing below it.

| Layer | Owner | Scope |
|---|---|---|
| Bare metal | **Ansible** | packages, hypervisor, network, disks, host observability, watchdog |
| VM + cluster lifecycle | **Terraform** | libvirt domain/volumes, Talos machine config, bootstrap |
| Cluster state | **Flux** | everything under `infrastructure/` |

Design rationale lives in `docs/talos-terraform-migration-notes.md`. This file
is the operating manual.

## Why Flux bootstrap is not here

Terraform stops at a running, empty Kubernetes cluster. `flux bootstrap` is a
separate, explicit step.

The security argument for folding it in does not hold either way — Terraform
never owns the age key, it would only read through it — so this is a
separation-of-concerns choice: Terraform owns *infrastructure* lifecycle, Flux
owns *cluster* lifecycle, and blurring them blurs exactly the boundary this
setup exists to make legible. The two-step form is also easy to collapse into
one later; the collapsed form is harder to split.

## Secrets

The Talos PKI is generated **out of band** and stored SOPS-encrypted, rather
than by a `talos_machine_secrets` resource.

Terraform has no state encryption at any version — state confidentiality is a
property of the backend, not the CLI, and 1.10's ephemeral *values* are a
different feature. Had Terraform generated the PKI, `terraform.tfstate` would
be the only copy of the cluster's root CA keys: a second root secret sitting
beside the age key, which D12 says should not exist.

Generating it out of band inverts that. The encrypted file is authoritative and
anything in state is a derived copy, so losing or leaking state is a rotation
job rather than a loss of the cluster. On top of that, the rendered machine
config and the kubeconfig are produced by **ephemeral** resources and passed
through **write-only** (`_wo`) arguments, so they never reach state at all.

This is why Terraform proper is viable here and OpenTofu's state encryption
isn't needed.

## First run

```bash
# 1. Host prep — hypervisor packages, libvirt network, storage pools.
sudo ansible-playbook -i ansible/inventory/hosts.ini \
  ansible/playbooks/converge.yml --tags host_prereqs,bulk_storage,cli_tools

# 2. Stage the Talos disk image. The qemu-guest-agent schematic is pinned as
#    the script's default; pass a different ID only to change the extension set.
terraform/scripts/stage-talos-image.sh v1.13.8

# 3. Generate the cluster PKI. ONCE per cluster — re-running mints a new PKI,
#    which orphans a running cluster rather than repairing it.
terraform/scripts/gen-talos-secrets.sh homelab

# 4. Apply.
cd terraform/clusters/homelab
export TF_VAR_machine_secrets="$(sops --decrypt --output-type json machine-secrets.sops.json)"
terraform init
terraform apply

# 5. Kubeconfig and talosconfig come from talosctl, not Terraform — they are
#    ephemeral in the module by design, and talosctl is what you would reach
#    for in a recovery anyway.
talosctl --nodes 10.10.0.10 kubeconfig
```

## Destroy and recreate

`terraform destroy && terraform apply` producing a clean cluster in minutes is
the point, not a side effect. It turns "does the platform bootstrap from
zero?" from an unanswerable question into a routine test — which matters for a
platform whose remaining roadmap is more kinds and more data services, and
whose known cold-apply bugs (the `seaweedfs-runtime` Kustomization split) were
found by accident rather than by testing.

It also keeps the tier-1 recovery path rehearsed continuously rather than
annually. Prefer it over libvirt snapshots for that reason: a snapshot is a
second mechanism that is not the one you would use in an emergency.

**The data disks are `prevent_destroy`.** A blanket `terraform destroy` will
therefore *fail* rather than silently take the platform's data with it. To
rebuild the node, target the domain:

```bash
terraform destroy -target=libvirt_domain.node
terraform apply
```

Genuinely retiring a cluster means deleting the `prevent_destroy` block in a
commit — deliberate and reviewable, which is the intent.

## Storage

The cluster knows disk **roles**, never disk **paths**.

| Layer | Vocabulary |
|---|---|
| Ansible (host) | `/`, `/mnt/storage` — which image file lives on which physical disk |
| Terraform | three virtual disks, each stamped with a stable serial |
| Talos machine config | a CEL selector per disk → `/var/mnt/fast`, `/var/mnt/bulk` |
| Cluster (Flux) | two provisioners rooted at `/var/mnt/*` |
| App author | `size` and `tier` |

Hardware appears only in the first row. The join is the disk **serial**, set on
the domain in `domain.tf` and matched by CEL in `talos.tf` — not `vdb`/`vdc`
enumeration order, which would break the first time a disk is added.

### The one hard safety rule

> **Never write into k3s's data paths.** Not `/var/lib/rancher/k3s/storage`,
> not `/mnt/storage/k8s-volumes`.

k3s is *stopped, not destroyed* across this migration, and `systemctl start
k3s` is the fallback for every failure in the plan. Writing a VM image into
those trees destroys that fallback silently, with no error at the time. Every
other mistake here is recoverable; this one is not.

The libvirt pools are placed accordingly (`/var/lib/libvirt/images` and
`/mnt/storage/libvirt-images`), and the HDD pool is defined by the
`bulk_storage` Ansible role specifically so that it sits behind that role's
mount assert — an unmounted `/mnt/storage` at image-creation time would put the
bulk image on the SSD.

### Sparse images

All three volumes are raw, which on ext4 means sparse: they consume only
written blocks while keeping raw's performance profile (qcow2's write
amplification would land directly on CNPG's WAL fsyncs).

That is load-bearing given `/` has ~61G free, but it is also the familiar
thin-provisioning hazard one layer down — three sparse images can collectively
overcommit `/`, and host `df` will under-report the commitment. It needs the
same treatment as the local-path no-quota trap: application-level bounds inside
the cluster, plus a host-level alert on `/` free space. The guest will keep
writing happily until the host filesystem fills underneath it.

## Debugging a node with no shell

Talos has no SSH and no shell, so inspecting a volume is a debug pod rather
than `sudo ls`. `debug-pod.yaml` in this directory is that pod, kept in the
repo rather than reinvented under pressure:

```bash
kubectl apply -f terraform/debug-pod.yaml
kubectl -n node-debug exec -it node-debug -- sh   # /host-fast, /host-bulk
kubectl delete -f terraform/debug-pod.yaml
```

The namespace it ships with is load-bearing: Talos enforces the Pod Security
`baseline` profile by default and baseline forbids `hostPath` outright, so a
debug pod in `default` is **rejected**, not warned. Only a namespace labelled
`enforce: privileged` can mount host paths.

## Known gaps

- **No serial console on the domain.** The provider marks
  `consoles.source.pty.path` as required, but libvirt assigns that path at
  start — there is no correct value to write. Use `virsh console <name>` out of
  band. Revisit if a later provider release relaxes it.
- **Provider cadence.** `dmacvicar/libvirt` 0.9.x is a rewrite being actively
  debugged (0.9.0 → 0.9.1 took twelve months; six releases landed Jan–May
  2026). Pinned hard, and every 0.8.x example uses block syntax that no longer
  parses.
