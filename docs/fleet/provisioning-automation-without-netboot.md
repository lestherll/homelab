# Fleet automation with manual install accepted — what is left, and is it worth it

**Status: recommendation, 2026-09-01. Nothing built.** Answers: *given manual Talos
installation and NFD for hardware inventory, what is left to automate in the Fleet
layer — or is automating it useless?*

**Not useless. Close to the opposite.** `target-architecture.md` §9.1 describes
joining a machine in nine steps. **Netboot is step 2.** The other eight are where
the value is, most of them are already built, and none of them are made redundant
by installing from a USB stick.

The framing worth replacing: *"provisioning = getting the OS onto the disk."* In a
Talos fleet that is the smallest and rarest part. Provisioning is mostly
**machine config**, and machine config is where the recurring work lives.

---

## 1. The nine steps, and who does them

From `target-architecture.md` §9.1, annotated with what is actually automatable
today:

| # | Step | Who | Status |
| --- | --- | --- | --- |
| 1 | rack, cable, power | human | manual forever |
| 2 | **power on → boot Talos** | netboot, or **USB** | **the deferred one** |
| 3 | machine sits in maintenance mode, API on `:50000` | automatic | — |
| 4 | render machine config: role, disks, `certSANs`, CA + join token, endpoint | Terraform | **already built** |
| 5 | apply it; Talos installs to disk, reboots, joins | Terraform | **already built** |
| 6 | kubelet registers; DaemonSets land | Kubernetes | automatic |
| 7 | **tag its disks in Longhorn** — SSD ▸ `fast`, HDD ▸ `bulk` | human today | **automatable now** (§3.2) |
| 8 | **label it** `topology.kubernetes.io/zone=machine-N` | human today | **automatable now** (§3.2) |
| 9 | replicas begin scheduling | Kubernetes | automatic |

Steps 4 and 5 already exist: `terraform/modules/talos-cluster/talos.tf` carries
`talos_machine_configuration_apply` and `talos_machine_bootstrap`. Under D20 the
libvirt half of that module (`domain.tf`, `volumes.tf`) retires and **this half is
exactly what is kept** — ADR §7's *"Terraform keeps the `siderolabs/talos`
provider only… it owns machine configs, PKI generation and bootstrap."*

So accepting a manual step 2 leaves **one** genuinely manual pair — steps 7 and 8
— and `target-architecture.md` already flags step 7 as *"the only genuinely manual
one, and the one to automate first… a mistagged disk puts `fast` replicas on the
HDD, silently."*

## 2. Rare versus recurring — the actual argument

**A machine is installed once. Its config changes many times.**

Every one of these is a machine-config operation, not a reinstall: adding a
`certSAN`, adding a system extension, changing a disk selector, changing kernel
args, promoting a worker, upgrading Talos, upgrading Kubernetes. Under D20 they
are also how the **one rebuild** in §4.1 is executed and, later, how it is
avoided.

Automating step 2 automates the **rare** thing. Automating steps 4–5 and 7–8
automates the **recurring** thing. The recurring one is already most of the way
built, and it is the one that pays every week rather than once per machine.

This extends past joining. Talos and Kubernetes upgrades are API operations
(`talosctl upgrade`, `talosctl upgrade-k8s`) — no reinstall, no netboot, no
console. If you later want them git-driven rather than hand-run, `tuppr`
(`tuppr.home-operations.com/v1alpha1`) is a small in-cluster controller that
takes upgrade plans as CRDs and health-gates the rollout. Worth knowing exists;
not worth adopting before there are three machines to roll across.

## 3. What to build, in order

### 3.1 The node list, feeding config generation

The gap in steps 4–5 is not capability, it is **shape**: the module provisions
one node. It needs to iterate a list.

- A git-tracked YAML node list — hostname, MAC, address, role, install-disk
  selector, disk roles — exactly as `inventory-and-provisioning-approach.md` §3
  specifies.
- `for_each` over it, so machines 2 and 3 are entries rather than new modules.
  ADR §1 already notes this is what one endpoint buys: *"with one endpoint,
  `for_each` over a real node list works, there are no provider aliases."*

**This is the highest-value item**, because it is what makes "add a machine" a
data change, and it is required whether step 2 is a USB stick or an iPXE boot.

### 3.2 NFD rules that close steps 7 and 8

Verified mechanism, both halves:

- **NFD can write annotations, not just labels** — `Rule` in NFD's
  `api/nfd/v1alpha1/types.go` carries `Labels`, `LabelsTemplate` **and
  `Annotations`**.
- **Longhorn consumes exactly that** — with the *Create Default Disk on Labeled
  Nodes* setting on, a node labelled `node.longhorn.io/create-default-disk: config`
  has its `node.longhorn.io/default-disks-config` annotation parsed as JSON, and
  that JSON carries `path`, `allowScheduling`, `storageReserved` **and `tags`**.

So a `NodeFeatureRule` in git can do step 7. Two rules are enough, keyed on the
`rotational` flag NFD discovers per block device:

| Rule matches | Emits |
| --- | --- |
| node **has** a rotational disk | disks-config JSON with both a `fast`-tagged and a `bulk`-tagged entry, plus `topology.kubernetes.io/zone` |
| node has **no** rotational disk | disks-config JSON with the `fast` entry only |

The second row is not hypothetical — it is machine 2 as it stands today, which
has a single SSD (`hardware-fit-notes.md` §5). **The fleet's heterogeneity is
discovered rather than hand-encoded**, which is the whole point.

> **Two honest limits.** Longhorn's disks-config annotation *"only takes effect
> when there are no existing disks or tags on the node"* — it is a day-one
> mechanism, not a reconciler, so it fixes joining rather than drift. And the disk
> **paths** in that JSON come from the Talos machine config, not from discovery;
> NFD decides *which* config a node gets, not what the paths are.

### 3.3 A reproducible image, so the stick's contents are declarative

Inserting a USB stick is manual. **What is on it does not have to be.** The image
is built from a schematic — `ghcr.io/siderolabs/imager` locally, per
`talos-without-omni.md` — so the extension set is a file in git and the artifact
is reproducible.

This is not optional under D20 regardless: §4.1 requires the Longhorn extensions
(`siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`) and the Tailscale
extension baked into the installed image. **A hand-downloaded ISO from the
factory would silently miss them**, and that costs the one rebuild twice.

## 4. Why none of this is throwaway

Netboot, when it arrives, replaces **step 2 and nothing else**:

```
  with USB                          with netboot later
  ─────────────────────             ─────────────────────
  1 rack + power        human       1 rack + power        human
  2 boot from stick     HUMAN  ──▶  2 boot from Smee      Tinkerbell
  3 maintenance mode    auto        3 maintenance mode    auto
  4 render config       Terraform   4 render config       Terraform   ← same
  5 apply + join        Terraform   5 apply + join        Terraform   ← same
  6 kubelet registers   auto        6 kubelet registers   auto
  7 tag disks           NFD rule    7 tag disks           NFD rule    ← same
  8 label node          NFD rule    8 label node          NFD rule    ← same
  9 schedule            auto        9 schedule            auto
```

Everything built here survives verbatim, and the node list of §3.1 maps onto
Tinkerbell's `Hardware` object field-for-field
(`tinkerbell-investigation.md` §9). **Arriving at netboot late costs nothing.**

## 5. What stays manual, and what would change it

| Still manual | What would fix it |
| --- | --- |
| Rack, cable, plug in | nothing, ever |
| First boot of a brand-new machine | netboot (deferred by choice) |
| Re-imaging a machine you cannot reach | netboot **and** remote power |
| Power-cycling a wedged machine | a smart plug + Rufio's `rpc` provider (`smart-plug-power-control.md`) — and never for machine 1, which is a laptop |

Note the last two need *both* halves. That is the honest reason netboot alone was
never the trigger: `tinkerbell-investigation.md` §7 makes the same point from the
other direction.

## 6. Limits worth stating

- **Terraform is push-reconciled, not continuously reconciled.** Nothing watches
  machine config and corrects drift — that is what Omni sells, and D20 declined
  it. `terraform apply` is the reconcile, and it is deliberate
  (`inventory-and-provisioning-approach.md` §3 makes the same point about
  `tailscale-acl/`).
- **NFD only sees machines that have joined.** Steps 7–8 are automatable; steps
  1–3 are not, by construction.
- **Machine-config changes that touch bootstrap manifests still need a rebuild**,
  automated or not — AGENT.md's standing caveat. Automation makes the rebuild
  cheap to execute, not unnecessary.

## 7. The answer, in one line

**Automate steps 4–5 and 7–8 now; they are the recurring work, they are most of
the way built, and they are untouched by whether step 2 is a USB stick or a PXE
boot.** Netboot is a convenience on the rarest step in the sequence, which is
exactly why deferring it was the right call.

---

## Related

- `docs/fleet/inventory-and-provisioning-approach.md` — the layer split this
  refines; §3's node list is §3.1 here
- `docs/fleet/target-architecture.md` §9.1 — the nine steps, and §4.1's rebuild
- `docs/adr/0001-single-model-talos-fleet.md` §1, §7 — one endpoint, `for_each`,
  and what Terraform owns
- `docs/fleet/tinkerbell-investigation.md` §9 — where the node list goes later
- `docs/fleet/smart-plug-power-control.md` — the remote-power half
- `docs/fleet/talos-without-omni.md` — building the image locally
