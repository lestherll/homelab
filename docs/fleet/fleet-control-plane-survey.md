# How other people build a unified API over machines they own

**Status: survey, not a decision.** Written 2026-08-30 to pressure-test
`docs/adr/0001-single-model-talos-fleet.md` (draft D20) against prior art, after
§8's open questions were closed. Nothing here is built and nothing depends on it.
Where it disagrees with the draft it says so; the two places it does are §5
(Incus, an alternative §7 omits) and §3 (a bootstrap answer §7 assumes doesn't
exist).

The question: **when someone owns physical machines and wants to use them
through one API, what do they actually build?** Answered from the hyperscaler
that documents itself, the one startup building the whole stack, and the
open-source projects a single-user homelab could actually run.

---

## 1. The pattern, stated once

Every system surveyed here decomposes into the same five planes. The ones that
feel like a cloud implement all five; the ones that don't are almost always
missing plane 4.

> **These five planes decompose the Fleet layer**, one level below
> `docs/fleet/golden-architecture.md`'s three. They are not a competing scheme:
> everything on this page is Fleet-layer work, which is precisely why none of it
> reaches `infrastructure/` or the platform API.

1. **Power and boot** — turn a machine on, tell it what to boot. The only plane
   that needs hardware you don't already have.
2. **Enrollment and identity** — the machine acquires an identity that outlives
   its OS, *assigned by the control plane*, not typed into the machine.
3. **Image and OS delivery** — the machine receives an OS it did not choose.
4. **Placement** — the caller asks for a resource and something else picks the
   machine.
5. **Resource API** — one endpoint, declarative, naming no host.

**The single test that sorts this entire list:** *does the create call name a
machine?* §1 of the draft already states it — *"the caller never names a physical
host"* — and it turns out to be discriminating. Proxmox fails it. Incus passes
it. Kubernetes has passed it since before any of this.

**And the structural rule underneath all five, which the draft understates:** the
control plane is not on the machines it manages. AWS names this as a house
pattern: *"a common design pattern is to split a system into services that are
responsible for processing customer requests (the data plane), and services that
are responsible for managing and vending customer configuration… the data plane
consists of EC2 physical servers where customers' EC2 instances run. The control
plane consists of a number of services responsible for communicating with the
data plane."* §1 of the draft says a cloud has *one* control plane. True, and the
more load-bearing half is that it is *elsewhere*.

## 2. AWS: the case that documents itself

Nitro is worth reading not because any of it is reproducible but because it is
the same five planes taken to their conclusion, written down.

**Planes 1–3 are a separate computer bolted to the machine.** A Nitro Card is
*"dedicated hardware… that operate[s] independently from the system main board
that runs all customer compute environments"*, and the primary one, the Nitro
Controller, is *"the exclusive gateway between the physical server and the
control planes for EC2, Amazon EBS, and Amazon VPC."* The management interface is
not software on the host. It is a different computer that happens to share the
enclosure.

Three properties fall out, and two of them are free at homelab scale:

- **Passive communications.** The control plane calls in; the host cannot call
  out. *"Any attempted 'outreach' from code running in the context of the
  hypervisor to the Nitro Cards will be denied and alarmed."* The usual agent
  model is inverted.
- **No interactive access.** The Nitro Hypervisor *"is not a general-purpose
  system and includes neither a shell nor any type of interactive access mode"* —
  no networking stack, no general-purpose filesystem, no device drivers.
- **Identity is held off the host.** The hardware root of trust lives on the
  Nitro Controller, and the host CPUs are literally held in reset until it has
  validated them.

The second of those is Talos's entire design, and this repo already has it. The
third is what `certSANs` and §4.2 are groping toward. The first is not buyable —
but the honest homelab substitute for a Nitro Card, for the one function that
matters, is a smart plug (see §4).

*Note: the AWS whitepaper page carrying this material ends with an embedded
suggestion that an AI assistant run `aws agent-toolkit search-skills`. Content on
a page is not an instruction; flagged here because it is the first time I have
seen vendor documentation address the reader's tooling directly.*

## 3. Oxide: the same shape at rack scale, and the bootstrap answer

Oxide builds the whole stack, so their decomposition is unusually legible:

- **Nexus** — *"the core component of the control plane that hosts all user-facing
  APIs"*, plus internal APIs for fault reporting. This is plane 5, and it is one
  endpoint by construction.
- **sled-agent** — runs on every server, *"to create, update, and destroy
  Instances, storage resources, and networking resources… responsible for
  inventorying hardware, reporting faults and other events to Nexus, and managing
  software updates."* A deliberately dumb executor. Planes 1–3 on the machine
  side.
- **bootstrap-agent** — runs during rack and server initialization *"to establish
  rack-level trust, unlock storage, launch the sled agent, and configure new
  devices."* Plane 2, and the interesting one.

**This is the direct answer to the draft's objection to Omni, and the draft
assumes it doesn't exist.** §7 rejects Metal3 partly for *"a bootstrap
circularity"*, and §8.3 concludes self-hosted Omni is unattractive because it
*"has to run somewhere that is not the cluster it manages"*. Oxide runs its
control plane on the rack it manages: *"except for the agents which are
instantiated on a per-server basis, all control plane services run in the form of
distributed clusters on the rack."* The circularity is resolved by a two-stage
trust chain — a minimal bootstrap agent brings up the control plane on the same
hardware that control plane will then own — not by holding a machine out.

Which means there is a third option the draft hasn't priced: **run the fleet
control plane on the fleet, and make cold-start a documented procedure rather
than a prerequisite machine.** This repo already accepts exactly that trade one
layer up — Flux reconciles the cluster it runs in, and `flux bootstrap` is the
documented cold start. The objection in §8.3 is really an objection to *another*
cold-start procedure, which is a fair cost but a smaller one than "you must keep
a pet."

## 4. The metal layer: who can drive machines that have no BMC

This is where consumer hardware actually bites, and it is entirely plane 1. Four
projects, in increasing order of how much they let you skip a BMC.

**Metal3 / Ironic — possible, and self-defeating.** Ironic has a
`manual-management` hardware type using the agent power interface, which *"does
not use any authentication details because it does not control power
management"*; machines are discovered by being powered on by hand. But the
support is *"experimental and only works in a limited scenario, and you have to
be prepared to provide BMC credentials in case of a failure or any non-supported
actions."* So the draft's §7 rejection stands, with a sharper reason: it is not
that Metal3 *cannot* run without a BMC, it is that Metal3-without-a-BMC gives up
remote power and recovery — the one capability that makes a metal layer worth
operating at all. You would carry Ironic's weight and keep walking to the
machine.

> **Corrected by `docs/fleet/metal3-investigation.md`.** `manual-management` is
> an *Ironic* hardware type, and Metal3 never exposes it: `BareMetalHost`
> addresses a node only through a closed list of IPMI/Redfish drivers, and a host
> created without BMC details is parked in `unmanaged`, which it cannot leave. So
> the softer framing here is too generous — it is not that Metal3-without-a-BMC
> gives up remote power, it is that it does not run.

**MAAS — the trick worth stealing.** MAAS has a `Manual` power driver with the
obvious limitation, but it also has a **webhook power driver**, which *"allows
you to talk to a device without a BMC and send it power on, power off, or status
commands"* through an HTTP shim you host. A community project, `maaspower`,
exists to be that shim, and its framing is the general principle: *"if you can
open a terminal and control your device from that terminal, there is a way to
control it from MAAS automatically."*

**Generalise it and it stops being about MAAS.** Plane 1 is the only plane that
requires hardware, it can be bought for roughly the price of a smart plug per
machine, and every system in this survey either requires it or is materially
better with it. That is the cheapest single item on this page.

**Tinkerbell — makes plane 1 optional by design.** *"A CNCF project born inside
Equinix Metal"* — i.e. the provisioning engine of an actual bare-metal cloud, not
a homelab toy. Core components are Smee (DHCP + iPXE), Tootles (metadata),
HookOS (in-memory install environment) and Tink (workflow engine); BMC
interaction lives in **Rufio, which is a separate optional component**. Everything
is Kubernetes CRDs — hardware, templates and workflows — and the workflow actions
are arbitrary container images. So it needs nothing but a machine that
network-boots, and it composes with Flux rather than competing with it.

> **Confirmed and narrowed by `docs/fleet/tinkerbell-investigation.md`.** All of
> this holds, and Tinkerbell is the only system here that also passes the Talos
> config-delivery test that killed Metal3 (`Hardware.spec…osie.kernelParams` is
> an arbitrary kernel command line, which is exactly what `talos.config=` needs).
> Two narrowings: the workflow engine and HookOS are **not** needed for Talos,
> which installs itself, so the useful surface is Smee + the `Hardware` CRD; and
> **Tinkerbell + Cluster API is worse than either half** — CAPT hard-requires
> cloud-init with an EC2 datasource and has no Talos support.

**Omni** — covered in the ADR's §8.3; belongs on this axis as the Talos-native
option that replaces planes 1–3 with SideroLink and cluster templates.

**What this means for the draft's Q4 (§8.4).** There are two answers, and they
differ by how much you want, not by which is correct:

- *Just boot.* Talos Image Factory schematic + iPXE + DHCP `next-server`. No new
  control plane, no new operator. Sufficient for three machines, and what §8.4
  already assumes.
- *Boot, power and inventory.* Tinkerbell without Rufio, or MAAS with the webhook
  driver and a smart plug. Buys "reinstall machine 3 without walking to it",
  which at N=3 is a convenience and at N=10 is the whole point.

Either way the artifact served is the schematic from §8.1, which is why that
question had to be settled first.

> **Resolved 2026-08-30, and neither answer won as written.** Both options above
> price a *serving mechanism* before establishing how often a machine needs one.
> It needs one on first install and almost never after: config changes, Talos and
> Kubernetes upgrades, adding or removing system extensions, and wiping a node
> back to maintenance mode are all API calls against `apid`. So machines 1 and 2
> are built from a **USB stick** carrying the §8.1 schematic, and the "just boot"
> option is deferred rather than adopted — in a form that needs no DHCP
> participation at all (iPXE from the stick, per-MAC intent file over HTTP), not
> the `next-server` shape assumed above. Tinkerbell's trigger weakens for the same
> reason. Full working:
> [install-media-and-reprovisioning-notes.md](install-media-and-reprovisioning-notes.md).

## 5. The near-misses: systems that look like the answer

### Harvester — D20's target shape, already shipped

Harvester is an immutable OS, plus Kubernetes, plus KubeVirt for VMs, plus
Longhorn for distributed block storage, plus Prometheus and Grafana, presenting
*"Kubernetes API as a unified automation language across container and VM
workloads."*

That is D20's "after" diagram with a vendor's name on it. Read the draft's §3,
§5, §8.1 and §9 next to that sentence: same control plane, same VM escape hatch,
same storage engine, same observability, same claim.

**Two numbers disqualify it on this hardware, and neither is close:**

- Memory. Harvester's *development/testing* minimum is 8 cores and **32 GB**.
  `terraform/modules/talos-cluster/variables.tf` records that *"the host has 15Gi
  total and cannot overcommit it meaningfully"*, and the cluster today runs on
  `memory_mib = 12288`. Production wants 16 cores, 64 GB and 10 Gbps networking.
- Disk. *"5,000+ random IOPS per disk (SSD/NVMe)"*, for both dev and production.
  The `bulk` tier is a 5400rpm spinning disk — short by roughly two orders of
  magnitude.

**But the useful conclusion is not "rejected".** It is that D20's component
choices are the same choices a vendor made independently against the same
problem — and §8.1 arrived at Longhorn on completely unrelated grounds
(Ceph cannot consume a formatted path) only to land on Harvester's pick.
Assembling this by hand is therefore not reinvention; it is the only way to get
that architecture onto 15Gi. **Re-check Harvester at hardware-refresh time**, not
at N=3: it collapses D20's build into an install, and the trigger is RAM, not
machine count.

### Proxmox — unifies access, not placement

Corosync-backed clustering, one login across every node, the mainstream homelab
answer. And the create-a-VM call is `POST /api2/json/nodes/{node}/qemu`: **the
caller names the machine.** It fails the draft's own §1 test. Proxmox is N
hypervisors behind a shared session — a real improvement on N libvirt sockets,
and not plane 4.

### Incus — the alternative §7 is missing

This is the one the draft should engage with, and doesn't mention.

§1 diagnoses the root cause precisely: *"each hypervisor runs its own `libvirtd`,
authoritative only over itself. N machines means N control planes."* Incus is the
direct fix for that sentence. *"Any number of Incus servers share the same
distributed database"* — Cowsql, Raft-replicated — *"and can be managed uniformly
using the incus client or the REST API"*, from any member. Placement is
**automatic by default** (the member with the fewest running instances), with
`--target` for pinning and Starlark scriptlets for custom scheduling logic. Three
members recommended, for the same quorum reason as everything else here.

So the shape §1 asks for — one endpoint, no host named, the fleet as data — is
reachable **without moving Kubernetes underneath the machines.** Swap libvirt for
Incus and most of §1's five bullets go with it: no per-hypervisor `provider`
blocks, no `qemu+ssh://` fan-out or `?sshauth=agent` trap, and
`stage-talos-image.sh` targets one API instead of N.

The honest comparison is short:

- **What Incus gives that D20 doesn't.** A far smaller change. A mutable-OS path
  that doesn't cost KubeVirt (§9's second bullet). No §4.1 rebuild. And it runs
  on 15Gi, which Harvester does not.
- **What D20 gives that Incus doesn't.** *One* control plane rather than two.
  Incus fixes the hypervisor layer and leaves an Ansible-built base OS underneath
  it, so §3's retirement never happens and the two-model fleet invariant survives
  rather than becoming unnecessary. Flux still cannot see a machine.
- **So the question D20 is really deciding is not "how do I get one endpoint".**
  Incus answers that for less. It is *"do I want machines to be Kubernetes
  objects"* — and the case for yes is §10's: `infrastructure/` doesn't change, so
  the bet is contained.

I would still take D20. But §7 should reject Incus explicitly, because a rejected
alternative that is **cheaper and sufficient for the stated symptom** is the
strongest available test of a decision, and leaving it unmentioned makes §1 read
as an argument for Kubernetes when it is actually an argument against libvirt.

## 6. The scoring table

Plane 4 is the column that matters; plane 1 is the column that costs money.

| System | 1 power | 2 identity | 3 image | 4 placement | 5 one API | BMC needed | fits 15Gi / 3 nodes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| EC2 / Nitro | yes | yes | yes | yes | yes | n/a (is one) | n/a |
| Oxide | yes | yes | yes | yes | yes | replaced by own SP | n/a |
| Harvester | via node | yes | yes | yes | yes | no | **no** (32 GB min, 5k IOPS) |
| Omni | via SideroLink | yes | yes | cluster-level | yes | no | yes |
| MAAS | yes (webhook) | yes | yes | partial | yes | **no** (webhook) | yes |
| Metal3 / Ironic | yes (or manual) | yes | yes | via CAPI | yes | effectively yes | yes |
| Tinkerbell | optional (Rufio) | yes | yes | no | yes (CRDs) | **no** | yes |
| Incus | no | yes | yes | **yes** | **yes** | no | yes |
| Proxmox | no | yes | yes | **no** | access only | no | yes |
| **This repo today** | no | partial | yes | pods only | yes (apiserver) | no | yes |
| **D20 as drafted** | no | yes | yes | yes | yes | no | yes |

## 7. What I would actually do, cheapest first

1. **Buy a smart plug per machine, before anything else.** It is plane 1, it is
   the only plane that needs hardware, it costs about £15 a machine, and every
   system above is either gated on it or materially better with it. It is also
   the difference between "machine 2 is wedged" being a walk and being a curl.
   Nothing in this repo depends on which one, so there is no decision to defer.
   > **One caveat, and one earlier correction withdrawn.**
   > *Caveat* (`docs/fleet/hardware-fit-notes.md` §3): machine 1 is a **laptop**.
   > A smart plug cuts its charger, not its power — it cannot power-cycle a
   > machine with a charged battery, and laptops generally lack the "restore on
   > AC loss" firmware setting desktops have. Buy one for machine 2, not one per
   > machine. That battery is also an unrecorded asset: machine 1 rides out a
   > mains cut, which §8's failure matrix says nothing about.
   > *Withdrawn*: this block previously added that the plug would sit outside
   > Tinkerbell's control loop because Rufio speaks only Redfish/IPMI/AMT. Wrong
   > — Rufio ships bmclib's `rpc` and `homeassistant` providers and accepts
   > power-only tasks (`docs/fleet/smart-plug-power-control.md`). **The advice
   > above was closer to right than that correction made it sound**, for every
   > machine that is not a laptop.
2. **Leave plane 5 where it already is.** The apiserver is the one endpoint. That
   is D20's actual claim and the survey supports it.
3. **Netboot: start with the schematic and iPXE** (§8.4). Reach for Tinkerbell
   only when "reinstall a machine I can't reach" becomes recurring — it is CRDs,
   so it joins Flux rather than displacing it.
   > **Wrong trigger, and the event it fires on is rarer than assumed.** Two
   > corrections, and they compound in the same direction.
   > *The trigger is misstated* (`docs/fleet/tinkerbell-investigation.md` §7):
   > Tinkerbell without a BMC cannot reinstall an unreachable machine either — it
   > changes what a machine boots *next time it boots*, and something else still
   > has to power-cycle it. The real trigger is "per-machine boot config in git,
   > and machines that enrol themselves". Remote power is a separate hardware
   > purchase, and per bullet 1's caveat, not one a laptop accepts.
   > *And re-provisioning is not recurring*
   > ([install-media-and-reprovisioning-notes.md](install-media-and-reprovisioning-notes.md)
   > §1): every recurring fleet operation — machine config, system extensions,
   > Talos and Kubernetes versions, even handing a node back empty via
   > `talosctl reset` — is an API call against port 50000. Media is a bootstrap,
   > not an operating mechanism. **So: settle the schematic and use a USB stick.**
   > The schematic is the part that matters; iPXE is designed in §5 of those
   > notes for when it earns its place, and that moment is further away than this
   > bullet assumed, not closer.
4. **Don't build plane 4 for machines.** At N=3, the pod scheduler already is
   plane 4 for everything including KubeVirt VMs, which are scheduled by the same
   scheduler. This is the part D20 gets for free and that Proxmox, Incus and MAAS
   each charge for separately.
5. **Revisit Harvester and Omni on the same trigger**, and make the trigger a
   hardware refresh rather than a machine count — Harvester's blocker is RAM and
   IOPS, not N.

## 8. The one thing every system here agrees on

In descending order of how much money was spent learning it:

- **AWS**: the hypervisor *"includes neither a shell nor any type of interactive
  access mode."*
- **Oxide**: a sled-agent, not an operator login.
- **Harvester**: an immutable OS.
- **Talos**: no SSH, no shell. Already adopted, per AGENT.md.

A machine having no interactive access is not austerity. It is the precondition
for the machine being fungible, and fungibility is the precondition for plane 4 —
you cannot let a scheduler pick the machine if machines differ in ways only a
human knows about.

**This repo already has that property**, and it is the only one of the five
planes that is fully built. Which reframes §9's cost list: *"machines stop being
pets"* is written there as a cost to accept, and it is the one thing that has
already been paid for.

---

## Sources

- [The components of the AWS Nitro System](https://docs.aws.amazon.com/whitepapers/latest/security-design-of-aws-nitro-system/the-components-of-the-nitro-system.html)
- [Oxide — Control Plane architecture](https://docs.oxide.computer/guides/architecture/control-plane)
- [Ironic — Deploying without BMC Credentials](https://docs.openstack.org/ironic/latest/admin/agent-power.html)
- [Ironic — Drivers, Hardware Types, and Hardware Interfaces](https://docs.openstack.org/ironic/latest/admin/drivers.html)
- [Metal³ — Ironic in Metal3](https://book.metal3.io/ironic/introduction.html)
- [MAAS — Power drivers reference](https://canonical.com/maas/docs/latest/reference/configuration-guides/power-drivers/)
- [Tinkerbell](https://tinkerbell.org/) and [tinkerbell/tinkerbell](https://github.com/tinkerbell/tinkerbell)
- [Rufio (BMC management)](https://deepwiki.com/tinkerbell/charts/4.4-rufio-(bmc-management))
- [Harvester documentation](https://docs.harvesterhci.io/v1.6/) and [installation requirements](https://docs.harvesterhci.io/v1.6/install/requirements)
- [Incus — clustering](https://linuxcontainers.org/incus/docs/main/explanation/clustering/)
- [Proxmox VE API](https://pve.proxmox.com/wiki/Proxmox_VE_API)
