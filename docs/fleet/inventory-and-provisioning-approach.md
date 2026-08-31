# Inventory, discovery and provisioning — the recommended approach

**Status: recommendation, 2026-08-31. Nothing built.** Answers "what should we
actually do now?" given everything the preceding investigations established:
Metal³ is out (`metal3-investigation.md`), Tinkerbell is right but its value is
the netboot layer and netboot is deferred (`tinkerbell-investigation.md`), the
fleet is two mismatched machines with no BMC and no path to one
(`hardware-fit-notes.md`), and the first machines are being installed from USB.

**The recommendation in one line: deploy Node Feature Discovery now to get real,
reconciled inventory of cluster members; keep a small hand-written node list in
git for machines that aren't members yet; and leave provisioning where D20
already puts it — Terraform's `siderolabs/talos` provider — until netboot is
worth building.**

---

## 1. The constraint that shapes the whole answer

GitOps means a controller continuously reconciles declared state against
observed state. **A machine that is not yet running Kubernetes has no controller
watching it.** That is not a tooling gap; it is why Metal³ and Tinkerbell both
need something *outside* the target cluster (Ironic, or Smee) to act on bare
metal at all, and why both were found to cost more than they return here.

So the three wants do not have one answer — they split by whether the machine is
a cluster member yet:

| Want | Before the machine joins | After it joins |
| --- | --- | --- |
| **Provisioning** | USB install + Terraform-applied config | Flux, already |
| **Inventory** | hand-written list in git | **NFD — real, reconciled** |
| **Discovery** | not possible without netboot | **NFD — automatic** |

The right move is to take the whole right-hand column now, because it is cheap
and genuinely GitOps, and to stop trying to make the left-hand column something
it cannot be at N=2 with no BMC.

## 2. Stage 1 — Node Feature Discovery, deployable today

[NFD](https://github.com/kubernetes-sigs/node-feature-discovery) is a
kubernetes-sigs project: `nfd-worker` runs as a DaemonSet, reads the hardware,
and writes `NodeFeature` custom resources; `nfd-master` watches those and labels
the `Node`. Refreshed on an interval (~60s default), so it is *reconciled*, not a
one-off scrape.

**This is the piece that has been missing, and it needs nothing from D20.** It is
a HelmRelease in `infrastructure/`, exactly like `metrics-server/` — no new
control plane, no bootstrap circularity, no netboot, and it works on the
single-node cluster that exists today.

### 2.1 What it actually gives you

Verified by reading the sources, not the marketing page:

- **Machine identity** — the `system` source reads `/sys/devices/virtual/dmi/id`:
  `sys_vendor`, `product_name`, `product_family`, `product_sku`,
  `product_version`, `board_vendor`, `board_name`, `board_version`,
  `board_asset_tag`, `chassis_vendor`, `chassis_type`, `chassis_asset_tag`,
  `chassis_version`, `bios_vendor`, `bios_version`, `bios_date`.
  > That is `LENOVO` / `ThinkCentre M710e` / `B250` discovered rather than typed.
  > **Serial numbers and `product_uuid` are deliberately excluded** — they need
  > root — so this is identity, not asset-tracking.
- **Storage** — the `storage` source reads `/sys/block/<dev>/queue` for
  `rotational`, `dax`, `zoned`, `nr_zones`. **`rotational` is exactly the
  SSD-vs-HDD discriminator** the design keeps needing.
- **CPU, memory, PCI, network, kernel** — the rest of the standard sources.

### 2.2 Why this is the GitOps answer and not just a labeller

`NodeFeatureRule` is a CRD. You commit a rule — *"a node whose storage reports
`rotational=1` gets `homelab.io/bulk-capable=true`"* — Flux applies it,
`nfd-master` reconciles the label onto every node it matches, including machines
that do not exist yet. **Declared hardware policy in git, reconciled by a
controller.** That is the real thing, not a cron job.

Two concrete gaps it closes immediately:

- **`target-architecture.md` §9.1 step 7** — *"tag its disks in Longhorn: SSD ▸
  fast, HDD ▸ bulk"* — is called out there as *"the only genuinely manual one, and
  the one to automate first… a mistagged disk puts `fast` replicas on the HDD,
  silently."* NFD discovers `rotational` per device. This is the automation that
  step is asking for, and it exists today.
- **`target-architecture.md` §10's capacity table** — *"verify before
  committing"* — stops being a hand-audit. `hardware-fit-notes.md` had to
  reconstruct it from three documents; NFD makes it `kubectl get nodes -L`.

### 2.3 What it costs, honestly

- **It needs a `privileged` namespace.** `nfd-worker` hostPath-mounts `/sys`,
  `/boot`, `/lib`, `/usr/lib`, `/etc/os-release` and `/proc/swaps`. Talos enforces
  `baseline`, and as `infrastructure/storage/namespace.yaml` already records,
  *"baseline forbids hostPath volumes outright."* So its namespace joins `storage`
  and `observability` on the privileged list. That is a real security cost and
  should be a deliberate call, not a surprise.
- **Footprint is small but not free**: `nfd-master` requests 100m/128Mi,
  `nfd-worker` 5m/64Mi per node. Fine — but **the chart's default *limits* are
  absurd for this fleet** (master 4Gi, worker 512Mi, gc 1Gi). Pin them down, in
  the repo's existing style of patching upstream defaults with a comment saying
  why. On a 3.2Gi machine 2 an unbounded master would be the whole node.
- **Talos rough edges.** NFD runs on Talos, but kernel-module discovery reads
  `/host-lib/modules`, which Talos does not lay out like a conventional distro,
  and there is a known upstream issue about network-attribute error logs on Talos
  (kubernetes-sigs/node-feature-discovery#1842). Expect noise in the worker log
  and disable the sources you do not use. **Verify on machine 1 before relying on
  any specific label** — the sources that matter here (`system`, `storage`, `cpu`,
  `memory`, `pci`) read `/sys`, which Talos does provide.
- **It only knows about nodes.** NFD is not a fleet inventory; it cannot see a
  machine that has not joined. That is §3.

## 3. Stage 2 — the pre-cluster node list

For machines that are not cluster members, there is no controller, so the honest
answer is a **small hand-written YAML list in git**, consumed by Terraform to
render machine configs. Per machine: hostname, MAC, LAN address, role
(controlplane/worker), install disk selector, disk roles.

Two reasons to write it as a *data file* rather than as Terraform resource blocks:

1. It is the thing D20 §7 already needs — *"Terraform keeps the `siderolabs/talos`
   provider only… It owns machine configs, PKI generation and bootstrap"* — and
   `fleet-provisioning-design-notes.md` §8 already reaches for a "node list".
   Making it data rather than HCL is what lets the same file feed something else
   later.
2. **It maps onto Tinkerbell's `Hardware` object field-for-field** when netboot
   arrives. `tinkerbell-investigation.md` §9 established that *"`Hardware` objects
   describe machines that already exist, so a fleet installed from USB can be
   adopted into Tinkerbell later without reinstalling anything."* Writing this
   list now is not throwaway work; it is the same data, one schema migration
   short of being reconciled.

**Do not** install Tinkerbell's CRDs now to hold this data. A CRD with no
controller behind it is inert data wearing a costume, and at two machines the
confusion outweighs the head start.

Be clear-eyed about what this stage is: **declarative and version-controlled, but
push-reconciled by `terraform apply`, not by a controller.** That is a real
distinction and this repo already lives with it — `tailscale-acl/` is the same
shape, and AGENT.md flags it as "the one path here that writes to live
infrastructure without going through Flux."

## 4. Stage 3 — Tinkerbell, when netboot is worth it

Already decided in `tinkerbell-investigation.md` §9 and unchanged here. Adopt it
as **Smee + the `Hardware` CRD** — not the workflow engine (Talos installs
itself), and not with Cluster API (CAPT hard-requires cloud-init and has no Talos
support). The trigger is *"per-machine boot config in git, and machines that enrol
themselves"*, not machine count, and not remote power — which this fleet cannot
have anyway.

At that point stage 2's YAML becomes `Hardware` objects, stage 1's NFD keeps
doing what it does for joined nodes, and the two halves of the inventory finally
meet.

## 5. Sequencing, against the blockers that already exist

```
NOW      ┌─ NFD HelmRelease ──────────────── independent of everything below
         │  inventory + discovery for machine 1 today, machine 2 when it joins
         │
THEN     ├─ RAM into machine 2 ───────────── hardware-fit-notes.md §4/§7
         │  before the rebuild, because the rebuild fixes its role in a config
         │
         ├─ node list in git ─────────────── §3; needed by the rebuild anyway
         │
         ├─ bridged network + VIP rebuild ── multi-node-ha-design-notes.md §4
         │  machine 1, single deliberate rebuild; unblocks machine 2's join
         │
         ├─ machine 2 joins as a WORKER ──── headless-talos-install.md §10
         │  (etcd says so, and 3.2Gi said so too — until the RAM lands)
         │
LATER    ├─ machine 3, matched to machine 2  ideally a Q-series chipset
         └─ Tinkerbell + netboot ─────────── §4, when reinstalls get routine
```

**The first line is the point of this note.** NFD depends on nothing else here,
costs one HelmRelease, and turns "I should really write down what these machines
are" into something the cluster maintains for you. Everything below it is already
scheduled work.

## 6. What this deliberately does not do

- **No remote power.** Not buildable for machine 1 (laptop battery), not wanted,
  and out of scope. `hardware-fit-notes.md` §3.
- **No BMC-based anything.** No machine has one and none can gain one.
- **No Cluster API.** One prod cluster and one nested non-prod cluster do not
  justify a management-cluster-plus-four-controllers apparatus, and the Talos
  bootstrap path through CAPT does not exist.
- **No auto-enrolment of bare machines.** It requires netboot. A machine that
  boots on this LAN should *not* silently become a cluster member anyway —
  `target-architecture.md` §9.1 calls that gap "the security boundary".
- **No serial-number asset tracking.** NFD excludes serials by design (§2.1).

---

## Sources

- [kubernetes-sigs/node-feature-discovery](https://github.com/kubernetes-sigs/node-feature-discovery) —
  `source/system/system.go` (DMI attribute list), `source/storage/storage.go`
  (`rotational`), `deployment/helm/node-feature-discovery/` (requests, limits,
  worker hostPath mounts)
- [NFD — CRDs (`NodeFeature`, `NodeFeatureRule`)](https://kubernetes-sigs.github.io/node-feature-discovery/master/usage/custom-resources.html)
- [NFD issue #1842 — network attribute errors on Talos](https://github.com/kubernetes-sigs/node-feature-discovery/issues/1842)
- In-repo: `docs/fleet/metal3-investigation.md`,
  `docs/fleet/tinkerbell-investigation.md`, `docs/fleet/hardware-fit-notes.md`,
  `docs/fleet/target-architecture.md` §9.1/§10,
  `docs/fleet/multi-node-ha-design-notes.md`,
  `docs/fleet/headless-talos-install.md` §10,
  `infrastructure/storage/namespace.yaml` (the baseline/hostPath precedent)
