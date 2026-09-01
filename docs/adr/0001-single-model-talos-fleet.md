# Draft — D20: Single-model fleet, Talos on the metal

**Status: DRAFT.** Not accepted, not built, nothing depends on it.

This repo records decisions as `D`-numbers in `CONCEPT.md` §11, with long-form
rationale in a `docs/*-design-notes.md` beside them (D18 → `talos-terraform-migration-notes.md`,
D15 → `self-service-platform-design-notes.md`). This file is staged outside that
structure deliberately: if accepted, the **Decision** section below becomes D20 in
`CONCEPT.md` and the rest becomes `docs/fleet/single-model-fleet-design-notes.md`.
Delete this file at that point rather than leaving a third copy.

---

## TL;DR

**The problem.** Every machine is its own control plane, so adding machine 2
means adding a second everything.

```
TODAY

  ┌─ machine 1 ───────┐  ┌─ machine 2 ───────┐  ┌─ machine 3 ───────┐
  │ Ubuntu + Ansible  │  │ Ubuntu + Ansible  │  │ Ubuntu + Ansible  │
  │ libvirtd          │  │ libvirtd          │  │ libvirtd          │
  │   └ Talos VM      │  │   └ Talos VM      │  │   └ Talos VM      │
  └───────────────────┘  └───────────────────┘  └───────────────────┘
            ▲                     ▲                      ▲
            └──── you talk to each one separately ───────┘
```

**The change.** Talos goes on the bare metal. Kubernetes becomes the one control
plane. Virtualisation moves from *under* the cluster to *inside* it.

```
D20

                     ┌──────────────────┐
    you ────────────▶│  Kubernetes API  │   the only endpoint
                     └────────┬─────────┘
          ┌──────────────────┼──────────────────┐
     ┌────┴────┐        ┌────┴────┐        ┌────┴────┐
     │  Talos  │        │  Talos  │        │  Talos  │
     │ on metal│        │ on metal│        │ on metal│
     └─────────┘        └─────────┘        └─────────┘

  need a full OS?  →  a KubeVirt VM inside the cluster, scheduled like a pod
```

The same change in layering notation is in the Decision section below.

**Where this decision sits.** The system is three layers, described in
`docs/fleet/golden-architecture.md`:

```
  PLATFORM API     Database · ObjectStorage · Application    ← the product
  INFRASTRUCTURE   Cilium · storage · Tailscale · CNPG · …
  FLEET            machines · power · boot · OS · config
```

**D20 is a Fleet and Infrastructure decision.** Its whole justification is that
the Platform API — the layer the project exists to produce — barely notices. That
is the test §10 applies. D18 passed the same test for a change one layer
higher (k3s → Talos, entirely inside Infrastructure); D20 is the deeper case. Do not
confuse these with D1's "Layer 0/1/2", which is the *thickness* of the Platform
API layer and sits inside the top box.

**The plan.**

```
NOW ──────────────────────────────────────────────────────▶ N=3

 [1] THE ONE REBUILD (§4.1)   spend it at N=1, while data is expendable
     ├ bridged network + VIP
     ├ generous certSANs            baked into certs — unchangeable later
     ├ Longhorn extensions          iscsi-tools, util-linux-tools
     ├ Tailscale extension
     ├ discovery service OFF        unchosen default, worst licence in the stack
     └ per-cluster Tailscale tags   immutable once a proxy device exists

 [2] STORAGE (§5, §8.1)       adopt Longhorn now, at replicas: 1
     └ looks pointless. Makes N=1→N=3 a number, not a data migration.

 [3] MULTI-CLUSTER PREP (§6)  all free today, expensive later
     ├ Prometheus externalLabels: cluster
     ├ cluster-qualified OIDC audience
     ├ postBuild substitution
     └ auto-suffix the Application host

 [4] MACHINE 2 & 3 ARRIVE     netboot → join → done
```

Why [1] is one batch rather than four changes: every item is something that gets
*baked in* — a certificate, a device tag, an installer image. Cheap now, a
rebuild later. So they are spent together, once.

**What is settled, and what is not.**

| Question | Answer |
| --- | --- |
| Replicated storage | **Longhorn** (§8.1). Ceph cannot consume a formatted path, so adopting it means evacuating both disks first |
| Per-cluster Tailscale tags | **Yes**, one Helm value (§8.2) — but the *operator* tag must split too, or the control is decorative |
| Omni | **Not needed** (§8.3, `talos-without-omni.md`). Licensing is fine; the gap it fills is empty at N=3 |
| Multi-arch | **Already true** (§8.6). Every image in the tree is amd64 + arm64 |
| Netboot mechanism | **Staged** (§8.4). USB now; plain iPXE when netboot is wanted; Tinkerbell (Smee + `Hardware`) when a hand-maintained iPXE config is the thing going wrong |
| Remote power | **Open, and now a hardware question** (§8.4). No machine has a BMC or AMT, and a smart plug cannot power-cycle machine 1 — it is a laptop |
| Ansible for non-cluster machines | Open (§8.5). A judgement call, not a research question |

**Two alternatives worth holding in mind** (§7, `fleet-control-plane-survey.md`):

- **Incus** gives one API over N machines for far less work. Rejected because it
  fixes the hypervisor layer and leaves Ubuntu beneath it — two control planes,
  not one. It does mean §1 is an argument *against libvirt*, not *for*
  Kubernetes; the argument for Kubernetes is §10's.
- **Harvester is this design, already shipped** — same Kubernetes + KubeVirt +
  Longhorn stack. It needs 32 GB and this host has 15Gi, so building it by hand
  is the only way to get the architecture onto this machine. Re-check it at a
  hardware refresh, not at machine 3.

**The strongest signal that this is drawn in the right place:** `infrastructure/`
does not change. Not one file. See §10.

---

## D20 — Single-model fleet: Talos on the metal, virtualisation above the cluster

**Decision.** Every machine in the fleet runs Talos on bare metal. Kubernetes
becomes the fleet's single control plane. Anything needing a full mutable OS
runs as a KubeVirt VM *inside* the cluster rather than as a hypervisor *beneath*
it. Ansible retires from cluster infrastructure entirely.

The layering, in D18's own notation — before:

```
Ansible   → configure a mutable physical machine
Terraform → declare infrastructure objects (libvirt domain, per hypervisor)
Talos     → provide immutable Kubernetes nodes
Flux      → reconcile Kubernetes state
```

after:

```
(netboot) → a powered-on machine self-installs Talos
Terraform → declare cluster shape, against ONE endpoint
Talos     → provide immutable Kubernetes nodes, on the metal
Flux      → reconcile Kubernetes state, including KubeVirt VMs
```

The same thing in the named layers of `docs/fleet/golden-architecture.md`, which
is what makes the scope of this decision legible — **two layers move, one does
not**:

```
                  BEFORE                      AFTER
  ─────────────────────────────────────────────────────────────────
  PLATFORM API    kro RGDs                    kro RGDs
                  (spec surface nearly unchanged — §10)

  INFRASTRUCTURE  Flux over a VM's cluster    Flux over the fleet's
                                              cluster, + KubeVirt

  FLEET           Ansible builds hypervisors  netboot/USB + Terraform
                  Terraform per libvirtd      against ONE endpoint
```

**This is not a reversal of D18 — it is D18's recorded reversal trigger firing.**
D18 says: *"Reverses if: a second machine arrives and the hypervisor/cluster split
stops paying for itself relative to just running Talos on bare metal again —
recorded as Alternative A in `docs/talos-terraform-migration-notes.md` and never
eliminated, only deprioritised."* Machine 2 is arriving. This decision is the
scheduled re-pricing, and it concludes that Alternative A now wins.

D3's trigger fires at the same time: *"Reverses if: a second machine arrives and
a dedicated non-production cluster becomes affordable."*

---

## 1. Reasoning: what a cloud actually is

The property the current design lacks is not Terraform-shaped. It is that
**a cloud has one control plane owning the whole fleet.** `ec2.amazonaws.com`
provisions instance 1 and instance 10,000 through one endpoint, and the caller
never names a physical host.

Today each hypervisor runs its own `libvirtd`, authoritative only over itself.
N machines means N control planes, which is the single root cause of:

- static `provider "libvirt"` blocks per hypervisor — Terraform cannot generate
  provider configurations from a list, so the fleet cannot be data
- `qemu+ssh://` connection management, agent auth, and the `?sshauth=agent`
  trap (Go's SSH client does not read `~/.ssh/config`)
- `stage-talos-image.sh` needing a per-hypervisor connection (LES-138)
- Ansible existing at all, to build hypervisors
- the two-model fleet invariant in `docs/fleet/fleet-provisioning-design-notes.md` §7

Under this decision the apiserver is the one endpoint. Adding a hypervisor
becomes joining a node. A VM becomes a scheduled object whose placement nobody
specifies. Every item above dissolves rather than being solved.

**LES-158 dissolves specifically.** "Where does Terraform run and where does its
state live" is a question about addressing N libvirt sockets. With one endpoint,
`for_each` over a real node list works, there are no provider aliases, and state
stops being a per-hypervisor concern.

## 2. The criterion this is optimising for

Stated explicitly because it drove the shape: **no further migrations.** Not
"good architecture" — a testable property. Migrations are forced by five things,
and only five:

1. a model that cannot express what is later needed
2. an identity baked into something that outlives it
3. a dependency that dies or changes terms
4. a layering inversion found late
5. state that cannot move

This decision addresses (1) and (4). Sections 4 and 5 address (2) and (5), which
are the ones that actually bite. (3) is handled by §6's separation of reachability
from provisioning.

## 3. What retires

- **`ansible/` for cluster infrastructure.** Talos has no SSH and no config
  management; the machine config *is* the declaration. `host_prereqs`,
  `bulk_storage` and `cli_tools` exist to build a hypervisor that no longer
  exists. Note this also retires the entire `sudo-rs`/`become` problem recorded
  in `ansible.cfg` — not by fixing it, by removing its subject.
- **The two-model fleet.** One model. §7's invariant becomes unnecessary rather
  than satisfied.
- **The libvirt provider, `stage-talos-image.sh`, provider aliases, LES-158.**
- **`heartbeat_watchdog`'s host-side role**, in its current form — though the
  concern it covers (sparse images overcommitting the host filesystem, LES-102)
  disappears with the images themselves.

Ansible may survive for machines that are *not* cluster nodes — a NAS, a router.
That is a separate question and this decision does not answer it.

## 4. What must be true at N=1, or it becomes a migration

Two groups. Both are cheap now and expensive-to-impossible later, which is the
whole point of recording them here rather than discovering them.

### 4.1 The one rebuild

The bridged-network + VIP work (LES-151) is currently framed as an HA
prerequisite. Reframe it: **it is the last rebuild, and it should be spent at
N=1**, where a rebuild is `terraform destroy && apply` on a cluster whose data is
expendable. At N=3 with real workloads it is a maintenance window with a restore
plan.

Everything that must ride inside it:

- bridged networking + the VIP
- **generous `certSANs`** — see §4.2
- the CSI driver's Talos extensions in the machine config — resolved to
  `siderolabs/iscsi-tools` + `siderolabs/util-linux-tools` for Longhorn (§8.1).
  Bake them even if Longhorn is installed later; an unused extension costs
  nothing and a missing one costs this rebuild twice.
- the Tailscale extension (LES-145)
- `allowSchedulingOnControlPlanes` decided properly (LES-155)
- **`cluster.discovery.enabled: false`** — from
  `docs/fleet/talos-without-omni.md` §2.2. The cluster runs Talos's default
  today, which means the service registry is on and talking to
  `discovery.talos.dev`; nobody chose that. It buys nothing on one LAN, and its
  self-hosting escape hatch is BUSL with **no** use grant — a worse licence than
  Omni's. Machine-config change, so it lands in a rebuild, not in place.
- **Cilium as the only CNI** — `cluster.network.cni.name: none` and
  `cluster.proxy.disabled: true`, retiring Flannel *and* kube-proxy. Both are
  Talos **bootstrap manifests**, so this is the same "does not retrofit" class as
  the discovery item above: it lands on a rebuild or as manual DaemonSet surgery.
  It is a net deletion — `cni-configuration.yaml`, `allow-node-to-pods.yaml` and
  `talos.tf`'s kube-proxy metrics workaround all go with it, and the pod network
  does not renumber. The cost is losing Flannel as a working-without-policy
  fallback. Full accounting in `docs/fleet/cilium-only-networking.md`.
- **cluster-qualified Tailscale tags** — promoted here from §6/§8.2, because a
  `ProxyGroup`'s tags *"cannot be changed once a device has been created"* and
  retagging an exposure burns its cached certificate. `tag:k8s-<cluster>` owned
  by `tag:k8s-operator-<cluster>`, plus a cluster-qualified
  `svc:kube-apiserver-ci`. Not a rebuild item strictly — but the same
  identity-baked-in failure, and cheapest at the same moment.

Miss one and the rebuild is spent without buying the property.

### 4.2 Identity: the rule

> **The cluster endpoint is a name, never an address. `certSANs` enumerates every
> address the cluster could plausibly ever answer on — the VIP, the LAN range,
> tailnet names, `localhost` — generously, on day one.**

`terraform/modules/talos-cluster/talos.tf` currently sets
`certSANs = [var.node_ip]` with `node_ip = "10.10.0.10"`. **Anything embedded in
a certificate is a future rebuild**, because Talos's PKI cannot be re-issued
without one. certSANs are free; being stingy is what converts "I changed my LAN
subnet" into a cluster rebuild.

The same failure in milder form: `talos-cp-01` appears as a literal in
`infrastructure/storage/provisioners.yaml` (three times) and
`terraform/debug-pod.yaml`. Node names should be assigned, not hardcoded into
things that reference them.

## 5. Storage is where this is won or lost

**The highest migration risk in the entire design, because it is the only layer
holding data.** Everything else is rebuildable from git.

`infrastructure/storage/provisioners.yaml` pins all three classes to node
`talos-cp-01` by name. Its own inline comment concedes the problem: *"Harmless
while every cluster here is single-node; load-bearing the day one grows."* The
consequences, stated plainly:

- a PVC is welded to one physical machine; its pod can schedule nowhere else
- if that machine dies, the data is on a disk in a dead box
- replacing machine 1's hardware is a **data migration**, not a node replacement
- draining machine 1 downs every stateful workload

**The move that avoids the migration: adopt replicated storage now, at N=1, with
`replicas: 1`.**

That looks pointless and is not. It means the day machine 2 arrives, the change
is a number in a StorageClass — not a data evacuation. Operator installed, CSI
extensions already in the machine config, classes already pointing at it, every
PVC already a real volume rather than a directory. Going to `replicas: 3` is a
reconcile — see §8.1 for the one place that is imprecise: new volumes take the
count from the StorageClass, existing ones need a per-volume bump.

Defer it and you are moving live data between storage implementations on a
cluster you are simultaneously converting to HA. That is precisely the migration
this decision exists to avoid, at the worst possible moment.

**What survives either way:** the class names. `scratch`/`fast`/`bulk` are named
for guarantees, not implementations — already deliberate per AGENT.md. Every
consumer keeps working. The interface is terminal; only the backing is not.

**Nuance:** `scratch` probably should *not* be replicated — disposable, `Delete`
reclaim, node-local is correct and cheaper. The likely end state is mixed:
local-path for `scratch`, replicated for `fast` and `bulk`. That also keeps a
known-good fallback in place.

**Resolved (2026-08-30): Longhorn**, on the disqualifying ground that Rook/Ceph
cannot consume a formatted path — adopting it would mean evacuating `/var/mnt/fast`
and `/var/mnt/bulk` *before* the replicated store exists to receive the data.
Full reasoning, the Talos extensions it drags into §4.1, and what it means for
`bulk` over a 5400rpm HDD: §8.1.

## 6. Multi-cluster: four things, all cheap at N=1

More clusters are expected (D3's trigger, §0). An audit of what actually breaks
found the skeleton already correct — `clusters/homelab/` is Flux's standard
layout, `terraform/clusters/homelab/` mirrors it, the module is already
parameterised (`variables.tf` says *"so homelab and homelab-nonprod can sit on
different versions"*), `infrastructure/` contains no cluster name anywhere, and
`platform.homelab` is an API group rather than a cluster name.

What is missing is that **nothing in the shared tree can vary per cluster.** Four
items, ordered by cost-if-deferred:

1. **Prometheus `externalLabels: {cluster: ...}` — do this today.** There are
   none today. Two clusters remote-writing to one VictoriaMetrics merge silently,
   with no way to separate them afterward because attribution was never written.
   Given VictoriaMetrics exists specifically to hold *years* of power history,
   this is the one item on the list that damages something unreconstructable.
   Harmless at N=1 and makes existing history attributable.

2. **Cluster-qualified OIDC audience.** `talos.tf` hardcodes `homelab-k8s`, and
   its own comment states both halves of the trap: a deliberately-chosen audience
   is *"a scoping control"*, and changing it *"means changing register.yml in
   every app repo at the same time."* Two clusters sharing one audience means a
   token minted for staging is replayable against prod — destroying the exact
   property the custom audience exists to provide. Cost scales with app-repo
   count, so it only gets worse.

3. **`postBuild.substituteFrom` on the existing Kustomizations**, with
   `cluster_name` as the first variable. Every variance needed is a *scalar* —
   hostnames, node names, audience, external labels — not a structural
   difference, and substitution is the right tool for scalars. Preferred over
   restructuring into `base/` + overlays, which is a large diff across a tree
   full of carefully-written comments. Overlays earn their complexity only when
   clusters need different resource *sets*; they can be added later on top of
   substitution.

4. **Auto-suffix the `Application` RGD's `host`.** `rgd-application.yaml`
   takes *"Tailscale hostname, without the tailnet suffix"*. The same app on two
   clusters collides — and this one is in the **public API**, so fixing it later
   is a contract change rippling into app repos. Having the platform append the
   cluster name changes what users get without changing what they write; it is
   invisible at N=1.

Also colliding, and **not** lower stakes: `svc:kube-apiserver-ci` is a bare VIP
service name in `autoApprovers` and two grants, and the proxy tag `tag:k8s` spans
every cluster. Both are now resolved in §8.2 and promoted into §4.1 — a
`ProxyGroup`'s tags are immutable after its device exists, which makes this an
identity item rather than a fifth entry on this list.

Colliding at genuinely lower stakes: `grafana` and `alertmanager` are bare tailnet
hostnames. Given AGENT.md's record of Tailscale exposures being cert-fragile,
two devices contending for one hostname is a worse version of a known failure.
`app-registrar` binds `gha:lestherll` with no cluster dimension, so every app
repo can register on every cluster — possibly desirable, currently accidental.

## 7. Rejected alternatives

**Keep the hypervisor model, make Terraform remote (LES-158).** Solves the
addressing symptom and none of the cause. Still N control planes, still Ansible,
still a two-model fleet, still per-host provider blocks. It is the correct
*incremental* answer and the wrong *terminal* one — which is exactly why LES-158
should be closed by this decision rather than completed.

**Cluster API + Metal3/Ironic.** The industry answer, and genuinely dynamic bare
metal — but Metal3 drives power and boot through a BMC, which consumer mini-PCs
do not have. It also needs a management cluster to run in, which is a bootstrap
circularity, and it is a great deal of machinery for three machines. Revisit at
~10 machines; the all-Talos base makes adopting it easy later.

> **Superseded in its details by `docs/fleet/metal3-investigation.md`.** Two of
> those three reasons need correcting. The BMC one is *stronger* than stated —
> BMO's driver list is closed, so Metal3 without a BMC does not run at all —
> and it is joined by a second blocker this paragraph missed: Metal3 configures
> machines through a cloud-init/Ignition config drive, which Talos does not read.
> The bootstrap circularity, however, is **wrong**: Metal3 implements
> `clusterctl move`, so it pivots onto the fleet it manages. And the revisit
> trigger should be a hardware refresh that brings a real BMC, **not** ~10
> machines — ten mini-PCs are as un-provisionable as three.

**Omni (Sidero Labs).** The Talos-native fleet manager: token-based machine
registration, SideroLink WireGuard mesh, cluster templates, a Terraform provider.
Closest thing to the described target, and worth a real look. Not chosen for the
draft because it introduces a control plane to depend on — which, after the
verification in §8.3, is now the *only* surviving reason. Both things this
paragraph flagged as unverified came back favourable: BUSL 1.1's Additional Use
Grant explicitly permits *"personal use in a home lab environment"*, and
self-hosting works. It just has to run somewhere that is not the cluster it
manages, which on three machines means holding one out and giving back §9's
"machines stop being pets" on day one.

**Sidero Metal.** Self-hosted and open source, but my understanding is Sidero
Labs shifted focus to Omni and Metal may be in maintenance. Verify current status
before building on it.

**Incus.** Added 2026-08-30 after the survey in
`docs/fleet/fleet-control-plane-survey.md`, because it was missing and it is the
cheapest thing that satisfies §1. N servers share one Raft-replicated database
behind one REST API served by any member, with automatic placement by default —
so "one endpoint, caller names no host" is reachable by replacing `libvirtd`,
without moving Kubernetes underneath the machines. Most of §1's five bullets
dissolve with it. Rejected because it fixes the hypervisor layer and leaves the
Ansible-built base OS beneath it: §3's retirement never happens, the two-model
fleet survives, and Flux still cannot see a machine. That is two control planes
instead of one. **Worth stating plainly what this makes §1:** an argument against
libvirt, not an argument for Kubernetes. The argument for Kubernetes is §10's —
`infrastructure/` does not change, so the bet stays contained.

**Harvester.** Immutable OS + Kubernetes + KubeVirt + Longhorn + Prometheus,
presenting *"Kubernetes API as a unified automation language across container and
VM workloads"* — which is this decision's "after" diagram, shipped. Rejected on
hardware, not on design: 32 GB memory is its *development* minimum against a host
with 15Gi total, and it wants 5,000+ random IOPS per disk against a 5400rpm
`bulk` tier. Two things follow, and the second matters more. Building this by
hand is not reinvention — it is the only way to get the architecture onto this
machine. And the re-evaluation trigger is a **hardware refresh, not a machine
count**, because Harvester would collapse this whole decision into an install.

**Tinkerbell + Cluster API.** Investigated 2026-08-31 and rejected as a pairing,
which is the interesting part: *bare* Tinkerbell passes both tests Metal3 failed
(boot control is opt-in, and `Hardware.spec…osie.kernelParams` is an arbitrary
kernel command line, which is exactly the `talos.config=` channel Talos needs).
**Adding Cluster API breaks it again.** CAPT expects the provisioned OS to run
cloud-init with an EC2 metadata datasource, publishes Ubuntu images, and mentions
Talos nowhere — so it reimports the blocker that disqualified Metal3, to manage
one cluster Terraform already manages. Adopt Tinkerbell, if at all, as Smee plus
the `Hardware` CRD. Full analysis in `docs/fleet/tinkerbell-investigation.md`.

## 8. Open questions

Four of the six were resolved on 2026-08-30 against the live chart values, the
registries and the vendors' own licence text. Each is marked with what it now
forces; two of the resolutions move an item *out* of this section and into §4,
which is the useful half of the exercise.

### 8.1 Storage implementation — **RESOLVED: Longhorn.**

Rook/Ceph is eliminated by its own prerequisites, not by weighing it. Rook needs
*"raw devices (no partitions or formatted filesystems)"*, raw partitions, LVM
logical volumes or block-mode PVs. It cannot take a directory. `/var/mnt/fast`
and `/var/mnt/bulk` are formatted and currently hold every local-path PV in the
cluster, so adopting Ceph at N=1 means **evacuating both disks before Ceph can be
installed** — the data migration §5 exists to avoid, merely rescheduled to a
worse moment (before the replicated store exists to receive the data). Longhorn
takes a *path*, so it installs alongside the existing local-path classes and PVCs
move one at a time with a known-good fallback still mounted. That decides it; the
rest is confirmation.

Confirming, in descending order of weight:

- Longhorn's disk tags plus a StorageClass `diskSelector` reproduce the
  `fast`/`bulk` split inside **one** install, on the two disks that already
  exist. Ceph would express the same thing as CRUSH device classes and a pool
  per tier — equivalent, but a second thing to be fluent in.
- Ceph genuinely wants three nodes. Running it at N=1 means one mon and failure
  domain `osd`, and the move to N=3 is a CRUSH rule change on top of the replica
  bump. Longhorn's N=1 story (`numberOfReplicas: 1`) is a documented,
  unremarkable configuration.

**What it costs, and all of it lands in §4.1's rebuild:**

- Two Talos system extensions, `siderolabs/iscsi-tools` (iscsid/iscsiadm, which
  is how Longhorn attaches volumes at all) and `siderolabs/util-linux-tools`
  (`fstrim`).
- `pod-security.kubernetes.io/enforce: privileged` on `longhorn-system` — a
  third namespace joining `storage` and `observability` on that list. Expect the
  same misreported failure AGENT.md records for `storage`: not at deploy, at the
  first PVC.
- A kubelet `extraMount` for the data path. Longhorn ≥1.10 defaults it to
  `/var/mnt/longhorn`, which fits this repo's existing `/var/mnt/*` convention
  rather than fighting it.
- Stay on the **v1 data engine**. v2 wants `vm.nr_hugepages: 1024` plus the
  `nvme_tcp` and `vfio_pci` modules, which is a poor trade on a 12GiB guest.

**This makes Q4 downstream of this question rather than independent.** Both are
*system extensions*, so they are an Image Factory schematic, so they are the
installer image — which is the artifact a netboot mechanism serves. Bake both
extensions at N=1 **even if Longhorn is installed later**: an unused extension
costs nothing, and a missing one costs the rebuild §4.1 is trying to spend only
once.

**One correction to §5.** *"Going to `replicas: 3` is a reconcile"* is right for
new volumes and slightly wrong for existing ones. `numberOfReplicas` is a
StorageClass parameter, and existing Longhorn `Volume` objects keep the count
they were created with — raising them is a per-volume edit of
`Volume.spec.numberOfReplicas`, online and supported, but N edits and a rebuild
of each volume rather than one number. §5's argument survives intact; the
accurate phrasing is *"a reconcile for new volumes and a per-volume bump for old
ones"*, which is still reconfiguration rather than migration, and that is the
whole property being bought.

**§5's `scratch` nuance stands and gets sharper.** Replicating the 5400rpm HDD is
where the economics actually hurt: every write becomes three, on the tier where
seeks are most expensive, over a network block device that is latency-sensitive
by construction. Recommended end state — `scratch` stays local-path, `fast` goes
to three replicas, and **`bulk`'s replica count is a measurement at N=3, not an
assumption now**. Adopting Longhorn for `bulk` at `replicas: 1` still buys the
property §5 wants (a real volume, not a hostPath welded to `talos-cp-01`) without
committing to paying for replication over spinning rust.

### 8.2 Per-cluster Tailscale tag — **RESOLVED: yes, and it is a §4 item, not a §6 one.**

Verified against chart 1.98.9's own `values.yaml`:

- `proxyConfig.defaultTags: "tag:k8s"` is a plain Helm value, documented as a
  comma-separated string. A per-cluster proxy tag is one line in
  `infrastructure/tailscale-operator/helmrelease.yaml`. The hostname-prefix
  fallback this question worried about is not needed — delete that half.
- **The operator tag has to be split too, or the control is decorative.**
  `operatorConfig.defaultTags` is already set here to `tag:k8s-operator`, and
  `policy.hujson` reads `"tag:k8s": ["tag:k8s-operator"]`. Leave the operator tag
  shared across clusters and *both* operators own *both* proxy tags — the staging
  operator can tag a device `tag:k8s-prod`, and every rule written against
  `tag:k8s-prod` admits it. A per-cluster proxy tag is only a scoping control
  when its owner is also per-cluster: `tag:k8s-operator-<cluster>` owning
  `tag:k8s-<cluster>`.

**The trap, and the reason this is promoted into §4.1.** The `ProxyGroup` CRD
states it outright: *"Tags cannot be changed once a ProxyGroup device has been
created."* Retagging is delete-and-recreate — and AGENT.md already records what
recreating a Tailscale exposure costs, because the state Secret caching the
issued certificate dies with it, forcing a fresh Let's Encrypt order per
exposure with the failed-authorization limit waiting if several go wrong inside
an hour. The same applies more loosely to Ingress/Service proxies: changing
`defaultTags` affects devices created *after* the change, and existing proxies
keep their tags until something recreates them. So this is §2's failure mode (2),
an identity baked into something that outlives it, and it must be set on day one
alongside `certSANs` rather than retrofitted.

**One collision §6 missed, on the same axis.** `svc:kube-apiserver-ci` is a bare
VIP service name, appearing in `autoApprovers` and in two grants. Two clusters
both want it and there is one name — and the autoApprover is scoped by name
specifically so that a wildcard cannot be claimed by any `tag:k8s` proxy, so
widening it to `svc:*` is not the fix. Cluster-qualify the service name in the
same change as the tags.

### 8.3 Omni licensing and self-hosting — **RESOLVED: licensed, viable, still not chosen.**

Both halves verified; §7's conclusion survives but only one of its two reasons
does.

**Licensing: dismissed as an objection.** Omni is BUSL 1.1 — source-available,
not open source — with an Additional Use Grant reading *"You may make
non-production use of the Licensed Work, including testing and evaluation of the
Licensed Work itself, or personal use in a home lab environment."* Change Date
2030-08-04, Change License MPL 2.0. Self-hosting *this* homelab is explicitly
granted at no cost. The pricing page's *"Self-hosted Omni requires an Enterprise
license"* is the commercial case and does not contradict this — but it does mean
the supported path and the licensed-for-free path are not the same path.

Read the grant's exclusion before leaning on it: *"Use of the Licensed Work to
host, run, test, or support any environment on which Customer's own development,
operations, or business depends is not non-production use."* A single-user
homelab is squarely inside the home-lab clause today. It is still a licence whose
terms get re-read the day the platform stops being a hobby, which is a §2
failure-mode (3) exposure — a dependency that changes terms — rather than a
problem now.

For completeness, the SaaS alternative is cheaper than self-hosting's operational
cost: Hobby, $10/month, 10 nodes maximum, 1 user, non-commercial, community
support. That ceiling is comfortably above this fleet.

**Self-hosting: viable, and not small.** It needs an external auth provider
(Auth0, OIDC or SAML — exactly one enabled, plus an initial admin user), three
DNS names with TLS (UI/gRPC/Talos API, the Kubernetes API proxy, and SideroLink),
a WireGuard advertised address that must be an **IP and not a name**, and a
container runtime to run on.

**That last requirement is the whole objection.** It has to run somewhere that is
not the cluster it manages, or the bootstrap circularity §7 rejected Metal3 for
returns unchanged — and on a three-machine fleet, holding one machine out means
handing back §9's "machines stop being pets" the same day it is bought. So §7's
*"introduces a control plane to depend on"* stands as the sole remaining reason,
and it is sufficient.

**A separate audit closes this question in the other direction.**
`docs/fleet/talos-without-omni.md` maps Omni's capabilities against what is
already built here and finds the gap empty at N=3 on one LAN — Omni's value
concentrates in multi-site machines behind NAT and a team-facing RBAC/UI layer,
neither of which exists. It also finds that the vendor dependency actually worth
acting on is not Omni but the unchosen default in §2.2 above.

**One qualification, from `docs/fleet/fleet-control-plane-survey.md` §3.** That
circularity is not actually a law. Oxide runs its entire control plane on the
rack it manages and resolves the cold start with a two-stage trust chain — a
minimal bootstrap agent brings up the control plane on the hardware it will then
own. This repo already accepts that trade one layer up: Flux reconciles the
cluster it runs in, and `flux bootstrap` is the documented cold start. So the
real cost of self-hosted Omni is *another cold-start procedure*, not a pet
machine. Still a cost, and still not worth paying at N=3 — but the objection is
smaller than stated above, and it should not be the reason this gets dismissed
without a second look at the ~10-machine trigger. Recommendation unchanged: revisit Omni alongside
Metal3/Ironic at the ~10-machine trigger §7 already names, and keep the all-Talos
base that makes either adoptable then.

### 8.4 Netboot mechanism — **RESOLVED: staged.** Power stays open.

Unchanged in stakes: a Talos machine joined by config is identical regardless of
how the config arrived, so the mechanism stays swappable. What §8.1 adds is that
the *artifact* it serves is an Image Factory schematic carrying the Longhorn
extensions, so the schematic must be settled before the first machine netboots
even though the serving mechanism need not be.

`docs/fleet/fleet-control-plane-survey.md` §4 narrows the field to two, differing
by appetite rather than correctness: schematic + iPXE + DHCP `next-server` (no
new control plane, sufficient at N=3), or Tinkerbell with its BMC component
Rufio left out (hardware, templates and workflows as CRDs, so it joins Flux
rather than displacing it). It also flags the cheapest item on either list, which
is not software: a smart plug per machine is a power interface for consumer
hardware that has no BMC, and MAAS's webhook power driver is the existing proof
that the pattern works.

**Resolved 2026-08-31, into three stages rather than one choice** — see
`docs/fleet/inventory-and-provisioning-approach.md`:

1. **USB install, now.** Netboot is deferred; machines 1–3 are installed from a
   stick per `docs/fleet/headless-talos-install.md`. At N=2 this is not a
   compromise, it is the cheaper correct answer.
2. **Plain iPXE + DHCP `next-server`, when netboot is wanted.** Unchanged from
   the option above; the artifact is still §8.1's schematic.
3. **Tinkerbell as Smee + the `Hardware` CRD, when a hand-maintained iPXE config
   becomes the thing going wrong.** Not the workflow engine — Talos installs
   itself — and not with Cluster API (§7). `Hardware` objects describe machines
   that already exist, so a fleet installed from USB adopts into Tinkerbell later
   without reinstalling anything: arriving late costs nothing.

**The power half of this question stays open, and is now a hardware question
rather than a software one.** Two corrections to the paragraph above, both from
`docs/fleet/hardware-fit-notes.md`: no machine in this fleet has a BMC *or* Intel
AMT (machine 2 is a B250 board; only Q270 carries vPro in that generation), and
**a smart plug does not power-cycle machine 1, which is a laptop** — it cuts the
charger, not the power. So "a smart plug per machine" is wrong for half this
fleet. Buy one for machine 2; machine 1 needs different hardware or nothing.

**For machines 2 and later the software half is already solved**, which was not
clear when this was written: Rufio ships bmclib's `rpc` (HMAC-signed webhook) and
`homeassistant` providers, and a power-only BMC task is a supported shape, so an
ordinary smart plug is drivable from inside Tinkerbell with a small shim and no
BMC emulation. That makes remote power a ~£30 purchase plus a hundred lines,
rather than the hardware-refresh-or-nothing this paragraph implied. Still
deferred, not solved — but deferred by choice now. See
`docs/fleet/smart-plug-power-control.md`.

### 8.5 Does Ansible survive for non-cluster machines? — **STILL OPEN**, but narrower.

Unchanged, and genuinely a judgement call rather than a research question: it
depends on whether a NAS or router ever exists here, which nothing in this repo
currently answers. §3's position — that this decision does not answer it — is
still the right one.

**Narrowed 2026-08-31.** One motive for keeping Ansible was that something has to
know what the machines *are*. For machines that are cluster members that is now
answered without it — Node Feature Discovery reports hardware as node labels,
reconciled, including the DMI identity and the rotational/non-rotational flag
that the Longhorn disk tagging needs
(`docs/fleet/inventory-and-provisioning-approach.md` §2). So this question
shrinks to genuinely non-cluster machines, where the answer may simply be a
git-tracked list rather than a configuration-management system.

### 8.6 Multi-arch discipline — **RESOLVED: already true. The work is a check, not a retrofit.**

Every image this tree deploys was audited on 2026-08-30, at the pinned chart
versions and the appVersions they resolve to. **All of them publish
`linux/amd64` and `linux/arm64`**, most considerably wider:

| Image | Platforms |
| --- | --- |
| `rancher/local-path-provisioner:v0.0.37` | amd64, arm/v7, arm64, ppc64le, riscv64, s390x |
| `rancher/mirrored-library-busybox:1.37.0` | amd64, arm/v5, arm/v6, arm/v7, arm64/v8, s390x |
| `ghcr.io/alex1989hu/kubelet-serving-cert-approver:0.11.0` | amd64, arm64 |
| `chrislusf/seaweedfs:4.41` | 386, amd64, arm/v7, arm64 |
| `busybox:1.37` (`terraform/debug-pod.yaml`) | 386, amd64, arm/v5, arm/v6, arm/v7, arm64/v8, ppc64le, riscv64, s390x |
| `quay.io/cilium/{cilium,operator-generic,cilium-envoy}:v1.20.0` | amd64, arm64 |
| `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0` | amd64, arm64 |
| `ghcr.io/cloudnative-pg/postgresql` (the `Database` image) | amd64, arm64 |
| `quay.io/prometheus/prometheus:v3.12.0-distroless` | amd64, arm/v7, arm64, ppc64le, riscv64, s390x |
| `quay.io/prometheus/alertmanager:v0.32.1` | amd64, arm/v7, arm64, ppc64le, s390x |
| `quay.io/prometheus/node-exporter:v1.11.1` | amd64, arm/v7, arm64, ppc64le |
| `quay.io/prometheus-operator/{prometheus-operator,prometheus-config-reloader}:v0.91.0` | amd64, arm/v7, arm64, ppc64le, s390x |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.0` | amd64, arm, arm64, ppc64le, s390x |
| `grafana/grafana:13.0.1-security-01` | amd64, arm/v7, arm64 |
| `quay.io/kiwigrid/k8s-sidecar:2.7.3` | amd64, arm/v7, arm64 |
| `registry.k8s.io/metrics-server/metrics-server:v0.8.1` | amd64, arm, arm64, ppc64le, s390x |
| `victoriametrics/victoria-metrics:v1.149.0` | 386, amd64, arm/v7, arm64, ppc64le |
| `chrislusf/seaweedfs-operator:1.0.34` | amd64, arm/v7, arm64 |
| `registry.k8s.io/kro/kro:v0.9.3` | amd64, arm64 |
| `tailscale/{k8s-operator,tailscale,k8s-proxy}:v1.98.9` | 386, amd64, arm/v7, arm64 |

So there is nothing to retrofit, and the "cheap to maintain from the start"
framing is right: the cost is a check at bump time, not a project.

Two things the audit turned up that are worth keeping:

- **kro's image moved registries.** Chart 0.9.3 renders
  `registry.k8s.io/kro/kro:v0.9.3`; `ghcr.io/kro-run/kro/controller` — the
  obvious place to look — stops at 0.4.1. Not an arch finding, but exactly the
  kind of stale assumption an audit exists to catch.
- **The one image at real risk is not in the table.** `rgd-application.yaml`
  takes `image: string | required=true` from an app repo, and nothing on the
  platform constrains its architecture. On a mixed-arch fleet the failure is a
  pod scheduling onto arm64 and crash-looping with `exec format error` — an app
  author's image, an operator's incident. Nothing in `infrastructure/` sets
  `kubernetes.io/arch` anywhere today. If mixed-arch ever becomes real, the cheap
  guard is a `nodeAffinity` on `kubernetes.io/arch` rendered by the Application
  RGD, defaulting to `amd64` and overridable — additive, invisible at N=1, and
  the same shape of fix as §6 item 4.

## 9. Costs, stated plainly

- **Machines stop being pets.** No SSH, no Ubuntu userland, no "just install one
  thing on box 2". Anything needing a real OS becomes a KubeVirt VM. This is a
  constraint to accept deliberately, not discover.
- **KubeVirt is new operational surface** — a VM layer to run, upgrade and debug,
  where today libvirt is boring and well-understood.
- **Replicated storage costs capacity and write throughput**, on a fleet where
  one tier is a 5400rpm disk.
- **Talos is single-vendor.** Mitigated by it being the existing dependency, not
  a new one — this decision deepens that bet rather than placing it. **And the
  bet is narrower than this line implies:** Talos Linux is MPL-2.0, so the
  exposure is to a vendor's roadmap and support, not to a licence — if Sidero
  disappeared the code is forkable. That is a different failure mode from Omni's
  BUSL, and only one of the two is recoverable by forking. What is *not* covered
  by the licence is the two hosted services already in the critical path
  (`factory.talos.dev`, `discovery.talos.dev`); see
  `docs/fleet/talos-without-omni.md`.
- **The one rebuild is real work**, and must land everything in §4.1 at once.
- **The fleet this is designed for does not exist yet, and the machines that do
  are mismatched.** Measured 2026-08-31 in `docs/fleet/hardware-fit-notes.md`:
  machine 2 has **3.2Gi and one disk**, not the 15Gi and two that §10's capacity
  table assumed, so fleet RAM is **18.2Gi across two machines rather than 45Gi
  across three**. The ~2.9Gi per-machine floor for Talos, etcd, Cilium and
  Longhorn takes roughly 90% of machine 2 as it stands, and the fleet holds
  exactly one HDD, so `bulk` cannot reach the two replicas §5 specifies. None of
  this is a design fault and all of it is answered by parts rather than
  redesign — but it is a cost, it is in the unit that actually runs out, and the
  RAM should land *before* the §4.1 rebuild, since that rebuild fixes machine 2's
  role in a config.

## 10. The layer-boundary test, which is the strongest evidence for it

**Corrected 2026-08-30.** This originally read *"`infrastructure/` is untouched.
Not one file."* False — six files change, one of them the public API. The claim
that survives is narrower and still the strong one: **the API's spec surface is
nearly untouched; its implementation is not.** An app author sees one visible
change and one semantic one; the cost lands on the platform owner, which is where
an abstraction is supposed to put it. Detail, and the three breakages to remember,
in `docs/fleet/platform-api-under-d20.md` (parked — not scheduled).

What genuinely does not move: the three tier names, because `scratch`/`fast`/
`bulk` describe guarantees rather than implementations. Nor the `Bucket`/
`clusterRef` shape, the per-consumer S3 identity model, the `NetworkPolicy`
identity model, the telemetry, or kro itself — none of which contain the concept
of a node. And storage classes key on disk *roles* via `disk.serial`, never
paths — `talos.tf`'s own comment notes a real disk serial works exactly as a
virtio one does. Flux does not know it is running on a VM today and would not
notice it had stopped.

D18 made the same argument about the k3s→Talos cutover being invisible to app
authors, and called that *"the strongest available evidence the self-service
abstraction (D15) was drawn in the right place."* The same test passes again
here, one layer deeper — with the correction above, which is that it passes on
the *contract*, not on the file count.

**This section has now made the same argument twice without naming what it is
arguing about, so:** it is the **layer-boundary test** from
`docs/fleet/golden-architecture.md`. A change at one layer is sound if the layer
above it does not have to change. D18 passed it for Infrastructure → Platform
API; D20 passes it again for Fleet → Infrastructure → Platform API.

**And it has since passed a third time, more cleanly than either.** The four
Fleet-layer investigations of 2026-08-31 — Metal3, Tinkerbell, Tinkerbell +
Cluster API, and the fleet's real hardware — resolved without changing a single
file in `infrastructure/` or `platform-api/`. Three whole provisioning systems
were evaluated and rejected, and nothing above the Fleet layer could observe the
exercise. That is what the boundary is for.

**One caveat, recorded rather than smoothed over.** The hardware investigation
did leak upward, and by two layers at once: the fleet holds one HDD, so `bulk`
cannot reach the replica count §5 specifies, which is a *durability promise made
to app authors* determined by a hardware fact that skipped Infrastructure
entirely. `golden-architecture.md` §5 records it as the sharpest known leak in
the design. A two-layer jump is the failure mode this architecture is least
protected against, and nothing before now would have caught it.

**Reverses if:** the fleet stays at one or two machines indefinitely, at which
point the hypervisor model's familiarity outweighs a control plane it never grows
into — or KubeVirt's operational cost exceeds what the retired Ansible surface
was costing.
