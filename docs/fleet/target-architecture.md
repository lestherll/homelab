# Target architecture

**Status: design, 2026-08-30.** The end state D20 is aiming at. Not built.
Implements `docs/adr/0001-single-model-talos-fleet.md`; read that for *why*, this
for *what*.

> **Scope, in the layers of `docs/fleet/golden-architecture.md`:** this document
> is the detailed build-out of the **Fleet** and **Infrastructure** layers. The
> Platform API layer is out of scope here — what D20 does to it is priced
> separately in `platform-api-under-d20.md`, and the fact that it needs a
> separate, short document is the point.
>
> Section headings name the layer they belong to. This replaces an earlier
> `L0`–`L6` notation that was never defined, skipped `L5`, and collided with OSI
> layer names. One `L2` survives, in §4, where it genuinely means OSI — a VIP is
> an L2 address. That is the only remaining L-number in this file.

Three decisions fix the shape, and everything below follows from them:

| Decision | Value | Consequence |
| --- | --- | --- |
| Fleet size | **3 machines** | etcd quorum of 3; one node may fail |
| Goal | **Real HA** — survive a node dying, no downtime | forces replica counts, PDBs, anti-affinity, and rules out some things below |
| Prod / non-prod | **One cluster; non-prod nested as KubeVirt VMs** | separate API server and PKI without spending a machine |

---

## 1. The picture

### Physical

```
        ┌──────────── one LAN, one switch ────────────┐
        │                                              │
   ┌────┴─────┐        ┌──────────┐        ┌──────────┐│
   │ machine 1│        │ machine 2│        │ machine 3││
   │  Talos   │        │  Talos   │        │  Talos   ││
   │ SSD + HDD│        │ SSD + HDD│        │ SSD + HDD││
   └────┬─────┘        └────┬─────┘        └────┬─────┘│
        │  smart plug       │  smart plug       │  smart plug
        └───────────────────┴───────────────────┴───────┘
                            │
                    ┌───────┴────────┐
                    │  VIP (apiserver)│  floats between the three
                    └────────────────┘
```

Every machine is identical in role: control plane **and** workload
(`allowSchedulingOnControlPlanes: true`). Three machines is the minimum for etcd
quorum, and dedicating one to control-plane-only would waste a third of a small
fleet.

### Logical

```
                    ┌──────────────────────────┐
   you / CI ───────▶│   Kubernetes API (VIP)   │  the only endpoint
                    └────────────┬─────────────┘
                                 │
     ┌───────────────────────────┼───────────────────────────┐
     │                           │                           │
┌────┴─────┐              ┌──────┴──────┐            ┌───────┴───────┐
│  Flux    │              │  Platform   │            │   KubeVirt    │
│ reconcile│              │  API (kro)  │            │               │
│ from git │              │ App/DB/OS   │            │ non-prod Talos│
└──────────┘              └─────────────┘            │  cluster (VM) │
                                                     └───────────────┘
                                 │
                    ┌────────────┴─────────────┐
                    │  Longhorn (replicated)   │
                    │  scratch / fast / bulk   │
                    └──────────────────────────┘
```

### Storage

```
per machine:   SSD ──▶ Longhorn disk, tag "fast"
               HDD ──▶ Longhorn disk, tag "bulk"
               SSD ──▶ local-path dir  (scratch only)

class            backing        replicas   why
─────────────────────────────────────────────────────────────────────
scratch          local-path     n/a        disposable, node-local is correct
fast             Longhorn/SSD   3          survives a node, rebuilds fast
bulk             Longhorn/HDD   2          see §5 — the one deliberate trade
fast-unreplicated Longhorn/SSD  1          PLATFORM-INTERNAL, see §5.2
```

---

## 2. Machines and boot (Fleet)

- **Power:** a smart plug per machine, exposed to whatever provisioning tool is
  in use. Consumer mini-PCs have no BMC; this is the substitute, and it is the
  cheapest item in the design. Without it "machine 2 is wedged" is a walk.
- **Boot:** netboot from a Talos Image Factory schematic over iPXE, with DHCP
  `next-server`. Start there; adopt Tinkerbell (without its BMC component
  Rufio) only if reinstalls become routine.
- **Image:** built locally with `ghcr.io/siderolabs/imager`, not fetched from
  `factory.talos.dev` — same code, no hosted dependency, and it removes the last
  external requirement for a cold rebuild. See `talos-without-omni.md`.
- **Schematic contents:** `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`
  (Longhorn), the Tailscale extension, `qemu-guest-agent` is dropped — there is
  no hypervisor left.

## 3. OS and cluster (Fleet → Infrastructure)

- Talos on bare metal, MPL-2.0, no SSH and no shell. Machines are cattle.
- **3 control planes**, etcd quorum 3, `allowSchedulingOnControlPlanes: true`.
- **Talos VIP** for the API server — a shared L2 address that moves on failure.
  This is what makes "no downtime" true for the control plane, and it is why
  bridged networking is a prerequisite rather than a nicety.
- **`certSANs` enumerated generously** on day one: the VIP, every machine's LAN
  address, the LAN range, tailnet names, `localhost`. Anything omitted is a
  future rebuild.
- **`cluster.discovery.enabled: false`.** Nothing on one LAN needs it, and its
  self-hosting escape hatch is BUSL with no use grant.
- **Node names assigned, never hardcoded.** `talos-cp-01` currently appears as a
  literal in three places; none of them may survive.
- **Topology labels per machine** (`topology.kubernetes.io/zone=machine-N`) so
  Longhorn and pod anti-affinity have a failure domain to spread across. Without
  these, "3 replicas" can legally mean 3 copies on one machine.

## 4. Network (Infrastructure)

- **Bridged**, so nodes and KubeVirt VMs sit directly on the LAN.
- **Cilium as the only CNI** — **changed 2026-09-01**, replacing "chaining over
  Flannel, as today". `cluster.network.cni.name: none` and
  `cluster.proxy.disabled: true` retire Flannel and kube-proxy together, with
  `kubeProxyReplacement: true` and `autoDirectNodeRoutes: true` — the latter
  valid precisely because this section makes the fleet L2-adjacent on one
  bridged LAN. `allow-node-to-pods.yaml` and `cni-configuration.yaml` are
  **deleted**: both are chaining artefacts, and probes stop arriving as `world`
  once Cilium owns the bridge. Rides §4.1's one rebuild — these are bootstrap
  manifests and do not retrofit. Reasoning, costs and the enforcement re-test in
  `docs/fleet/cilium-only-networking.md`.
- **Tailscale for all external access**, with one change forced by HA: app
  exposures move from per-Ingress proxies to a **`ProxyGroup`** with replicas, so
  a proxy is not a single point of failure.
  > **This breaks every `Application`'s NetworkPolicy**, which matches on
  > `parent-resource-type=ingress`. Proxy pods in a ProxyGroup relabel to
  > `parent-resource-type=proxygroup` and the rule matches nothing. AGENT.md
  > already warns about this; under an HA goal it stops being hypothetical.
  > **The RGD change and the ProxyGroup migration are one change.**
- **Per-cluster Tailscale tags**: `tag:k8s-<cluster>` owned by
  `tag:k8s-operator-<cluster>`, set before the first proxy device exists — tags
  are immutable afterwards, and recreating an exposure burns its certificate.

## 5. Storage (Infrastructure)

Longhorn, chosen because Ceph cannot consume a formatted path. Disk tags map the
existing two-disk layout onto one install: SSD tagged `fast`, HDD tagged `bulk`.

### 5.1 The tiers

`scratch` stays on local-path — disposable, `Delete` reclaim, node-local is
correct and cheaper, and it keeps a known-good fallback in place.

`fast` is 3 replicas. `bulk` is **2**, and this is the one place the HA goal is
deliberately traded: three-way replication on a 5400rpm disk triples every write
on the tier where seeks cost most. Two replicas still survives one node with no
downtime; what it gives up is headroom to lose a second disk while degraded.
Stated here so it is a decision rather than an oversight.

### 5.2 Do not replicate twice — and the class that follows

CNPG, SeaweedFS and Longhorn all replicate. **CNPG replication buys
*availability*; Longhorn replication buys *durability*.** They are not
substitutes, and running both is nine copies of Postgres.

- **`Database` replicates at the app layer.** CNPG at 3 instances, each on a
  volume with **one** Longhorn replica. A node loss kills one Postgres instance;
  CNPG promotes a standby in seconds and rebuilds the lost member. Longhorn
  replicating underneath would add cost and no availability.
- **`ObjectStorage` replicates at the storage layer.** One SeaweedFS volume
  server on a `bulk` volume with 2 replicas, rather than SeaweedFS's own
  `replication` setting. A minute of gateway restart is acceptable for object
  storage, and this avoids operating a second replication system.

That first bullet needs a `fast-unreplicated` class. **It is platform-internal,
not a fourth public tier** — a `Database` user's guarantee is still "durable";
the durability just comes from CNPG rather than from Longhorn. It must not appear
in `Application.spec.persistence.tier`.

### 5.3 What HA costs the Application API

`Application` today is `replicas: 1` with a `ReadWriteOnce` PVC. Under HA:

- **Stateless apps** can go to `replicas: 2+` with pod anti-affinity across
  machines and a PodDisruptionBudget. This is the normal case and it works.
- **Apps with `persistence`** cannot. RWO means one node, so a second replica
  cannot mount the volume. They stay at `replicas: 1` with
  `strategy: Recreate`, and their HA is "reschedules onto a surviving node in
  under a minute", not "no downtime".

> **The API must make this explicit rather than let it fail at runtime:**
> `replicas > 1` and `persistence` are mutually exclusive, rejected at admission.
> The alternative — RWX via Longhorn's NFS share-manager — is a second storage
> mode and a new failure surface for a case no app here has.

## 6. Non-prod (Infrastructure)

A single-node Talos cluster running as a KubeVirt VM on the fleet.

```
   prod cluster (3 machines, bare metal)
   └── KubeVirt VirtualMachine "nonprod-cp-01"
       └── Talos, single node, own PKI, own Flux bootstrap
           └── its own tag:k8s-nonprod Tailscale exposure
```

Why this and not namespaces: a genuinely separate API server and PKI, so a bad
CRD, operator upgrade or RBAC change cannot reach prod — which is the entire
point of a non-prod cluster. Why this and not a physical machine: it costs ~4Gi
instead of a third of the fleet, and it exercises the KubeVirt path D20 already
commits to.

Constraints that come with it:

- **Non-prod is not HA and should not be.** One node, no quorum, and if its host
  machine reboots it goes with it. That is correct for what it is.
- **It must be resource-capped**, or a non-prod runaway becomes a prod incident.
  This is the one place the isolation is genuinely weaker than two physical
  clusters.
- Its disks are Longhorn volumes from prod, so its data survives its host dying
  even though the VM does not.
- Everything in ADR §6 becomes real here: `externalLabels: {cluster: …}`, a
  cluster-qualified OIDC audience, `postBuild.substituteFrom`, and the
  auto-suffixed `Application` host.

## 7. What each tool owns

```
BEFORE                              AFTER
─────────────────────────────       ─────────────────────────────
Ansible   → the metal               ✗ retired
Terraform → libvirt domains         Terraform → machine configs + bootstrap
Talos     → k8s nodes in VMs        Talos     → k8s nodes on metal
Flux      → cluster state           Flux      → cluster state + VMs
```

- **Ansible retires.** `host_prereqs`, `bulk_storage` and `cli_tools` build a
  hypervisor that no longer exists — and the `sudo-rs`/`become` problem retires
  with them, by removing its subject. `cli_tools` may deserve a home elsewhere.
- **Terraform keeps the `siderolabs/talos` provider only.** No libvirt provider,
  no provider aliases, no `qemu+ssh://`, and LES-158 dissolves rather than being
  solved. It owns machine configs, PKI generation and bootstrap — nothing else.
- **Flux owns everything above the machine**, including KubeVirt VMs.
- **`tailscale-acl/` is unchanged in role** — still the fourth control plane,
  still git-owned, now with per-cluster tags.

## 8. Failure matrix — what "real HA" actually means

| Failure | Effect | Recovery |
| --- | --- | --- |
| One machine dies | VIP moves; etcd holds 2/3; Longhorn serves surviving replicas; CNPG promotes a standby; stateless pods reschedule | automatic, seconds |
| One disk dies | Longhorn rebuilds the replica onto a surviving node | automatic |
| Stateful `Application` node dies | pod reschedules, volume reattaches | automatic, under a minute — **not zero** |
| Non-prod's host dies | non-prod is down; data survives | manual restart |
| **Two machines die** | **etcd loses quorum — cluster is down** | manual, from an etcd snapshot |
| **The switch dies** | **everything is down** | replace the switch |
| **The power circuit dies** | **everything is down** | cold start, §9 |

The last three are the honest part. **On three machines in one room, the switch
and the power circuit are more likely to fail than a node**, and no amount of
replica count helps. HA here buys: survive a dead machine, and make OS upgrades
and reboots routine instead of outages. That second one is the real day-to-day
payoff.

## 9. Cold start order

Written down because it is the procedure nobody rehearses:

```
 1. Power on machines            (smart plugs)
 2. Netboot Talos                (schematic served locally)
 3. terraform apply              machine configs + bootstrap → etcd, apiserver, VIP
 4. flux bootstrap               → infrastructure/ reconciles
 5. Longhorn comes up            volumes reattach from replicas on disk
 6. CNPG / SeaweedFS recover     from their volumes
 7. KubeVirt starts non-prod
```

**What "no external service" means, precisely.** The **machine → OS → cluster**
path needs nothing outside this room: Terraform's PKI comes from SOPS, the OS
image is built locally by `imager`, and the joining node finds the cluster at the
VIP written into its own config. No `factory.talos.dev`, no
`discovery.talos.dev`, no Omni — the three Sidero-hosted services that would
otherwise sit in the critical path, two of which are in it today.

It does **not** mean the whole platform is offline-capable. Once the API server
is up, Flux still pulls container images from ghcr.io / quay.io / docker.io, and
tailnet access still depends on Tailscale's control plane. The boundary is
deliberate: **you can always get to a working, reachable cluster**, and what runs
on it is a separate problem with its own answer (a pull-through cache, if it ever
matters). The point of the invariant is that a rebuild — which usually happens on
a bad day — never blocks on someone else's uptime.

## 9.1 Joining a machine

The same steps whether it is machine 2 or machine 6.

```
 1. rack, cable, smart plug
 2. power on ──▶ PXE/iPXE ──▶ Talos kernel+initramfs from the local schematic
 3. Talos boots into MAINTENANCE MODE
        no config, no cluster, an API on :50000, waiting
 4. add the machine to Terraform's node list ──▶ terraform apply
        renders a machine config: role, disk selectors, certSANs,
        cluster CA + join token (from SOPS), endpoint = the VIP
        applies it to the maintenance-mode API
 5. Talos installs to disk, reboots, joins
 6. kubelet registers ──▶ Cilium and Longhorn DaemonSets land
 7. tag its disks in Longhorn: SSD ▸ fast, HDD ▸ bulk
 8. label it: topology.kubernetes.io/zone=machine-N
 9. replicas begin scheduling onto it
```

Three things worth understanding about that sequence:

- **Netbooting gets a machine an OS, not cluster membership.** A box that PXE
  boots on this LAN sits in maintenance mode doing nothing until someone applies
  a config to it. That gap is the security boundary, and it is why nothing here
  auto-enrols.
- **This is why disabling discovery is safe.** The joining node does not need to
  *find* the cluster — its config already contains the endpoint (the VIP), the
  cluster CA and a join token. Discovery exists for members finding each other
  across networks, which is not this.
- **Machine 4 and beyond join as workers, not control planes.** Three etcd
  members tolerate one failure; four also tolerate only one, while adding a
  member that must agree. Grow the control plane 3 → 5, never 3 → 4.

Step 7 is the only genuinely manual one, and it is the one to automate first if
the fleet ever grows — a mistagged disk puts `fast` replicas on the HDD, silently.

> **There is now a mechanism for it, and for step 8**, needing no netboot and no
> new component: NFD rules can write **annotations** as well as labels, and
> Longhorn parses a `node.longhorn.io/default-disks-config` annotation — including
> per-disk `tags` — on nodes labelled `node.longhorn.io/create-default-disk: config`.
> Keyed on the `rotational` flag NFD discovers, one rule covers machines with both
> tiers and another covers SSD-only machines. See
> `docs/fleet/provisioning-automation-without-netboot.md` §3.2, including the
> limit that Longhorn applies the annotation only while the node has no disks yet.

## 10. Rough capacity budget

Assumes three machines broadly like machine 1 (8 cores, 15Gi) — **verify before
committing**, because Longhorn replica placement wants comparable disk sizes.

> **Verified, and it does not hold** — `docs/fleet/hardware-fit-notes.md`.
> Machine 2 is a ThinkCentre M710e with **3.2Gi and one disk**, not 15Gi and two.
> Fleet RAM is 18.2Gi across two machines, not 45Gi across three, and the
> ~2.9Gi per-machine floor (Talos+kubelet, etcd, Cilium, Longhorn) consumes ~90%
> of machine 2 before any workload. The `bulk` tier cannot reach its 2 replicas
> either: the fleet contains exactly one HDD. Both are fixed by parts — RAM and a
> 3.5" drive, into bays that are already free — not by redesign.

| | RAM |
| --- | --- |
| Talos + kubelet (×3) | ~3Gi |
| etcd (×3) | ~1.5Gi |
| Cilium (×3) | ~1.2Gi |
| Longhorn instance managers (×3) | ~3Gi |
| kube-prometheus-stack | ~3Gi |
| CNPG, 3 instances | ~1.5Gi |
| SeaweedFS | ~1.5Gi |
| Tailscale ProxyGroup, kro, metrics-server, Flux | ~1.5Gi |
| **Platform subtotal** | **~16Gi of 45Gi** |
| Non-prod Talos VM | ~4Gi |
| **Left for applications** | **~25Gi** |

Longhorn and etcd are the new costs — roughly 4.5Gi that the current design does
not pay. That is the price of HA, stated in the unit that actually runs out.

## 11. Invariants

Rules that must hold. Each one is cheap to keep and expensive to retrofit.

1. **The cluster endpoint is a name, never an address**, and `certSANs` is
   generous on day one.
2. **No hardcoded node names**, anywhere.
3. **Storage classes name guarantees, not implementations.** `scratch`/`fast`/
   `bulk` are a public contract; how they are backed is not. This is
   `golden-architecture.md` §3's invariant — *a layer's contract is expressed in
   terms that do not name the layer below* — stated for storage, and it is the
   exemplar that document cites.
4. **Replicate at exactly one layer per workload**, and write down which.
5. **`replicas > 1` and `persistence` are mutually exclusive** in the
   `Application` API, enforced at admission.
6. **Every cluster-varying value is a substitution variable**, never a literal in
   the shared tree.
7. **A cold start requires no external service** on the machine → OS → cluster
   path. Workloads pulling images is a separate concern; getting to a reachable
   API server is not.
8. **Machines have no interactive access.** No SSH, no shell — the precondition
   for a scheduler being allowed to pick the machine.

## 12. Accepted limits

- Two machine failures, the switch, or the power circuit take everything down.
- Non-prod isolation is weaker than two physical clusters, bounded by resource
  caps rather than by hardware.
- Prometheus stays single-instance; the alerting path is not itself HA.
- Stateful applications get fast rescheduling, not zero-downtime failover.
- `bulk` is 2 replicas, not 3 — see §5.1.
