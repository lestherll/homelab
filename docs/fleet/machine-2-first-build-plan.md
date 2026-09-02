# Build the new cluster on machine 2 first

**Status: plan, 2026-09-02. Nothing built.** Answers: *given that D20 wipes the
only working machine, is there an order that de-risks it?*

**Yes. Build the new bare-metal cluster on machine 2 (`homelab-worker-0`) as a
single control-plane node, with the real PKI, while machine 1 keeps serving the
live platform. Join machine 1 later, as a worker, once it is cabled.**

This is a sequencing decision, not a design change. Every design decision it
executes is already made elsewhere — Talos on metal (ADR 0001), Cilium-only
(`cilium-only-networking.md`), Longhorn (`platform-api-under-d20.md`), Terraform
at maintenance mode (`terraform-on-bare-metal.md`). What changes is the order,
and the order is worth a document because it changes the risk profile more than
any of the individual decisions do.

---

## 1. Why this order

**It converts the plan's single largest risk into a non-risk.** ADR §4.1 exists
entirely because a set of settings are rebuild-only — `ingressFirewall`,
`certSANs`, the CNI, `VolumeConfig`'s EPHEMERAL cap, Longhorn's first-boot
`default-disks-config` annotation. The anxiety is not that they are hard; it is
that there is **one** rebuild in which to get them all right, on the machine that
serves everything. On machine 2 there are as many rebuilds as you want, on a
machine holding nothing.

The rest, in descending order of value:

- **The live platform never stops.** The current plan wipes machine 1 and has no
  rollback. Here the rollback is *"do not cut over"*, and it costs nothing.
- **It removes the Ethernet cable from the critical path.** Machine 1 runs on
  Wi-Fi and Talos has no Wi-Fi (`terraform-on-bare-metal.md` §0), so it cannot be
  a Talos node until it is cabled. Machine 2 is already cabled, and gigabit.
  That blocker stops blocking the *start* and blocks only machine 1's *join*.
- **Machine 2 is already most of the way there** — in maintenance mode, with
  `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` loaded, and its
  install procedure proven on the hardware (`machine-2-talos-install-record.md`).
- **It answers two open questions on the real thing**: Longhorn on Talos 1.13.8,
  which is off the vendor's verified matrix, and whether the
  `default-disks-config` annotation works when the path is a mount
  (longhorn#8040).
- **It agrees with `hardware-fit-notes.md` §6**, which concluded *"machine 1 is
  the outlier and machine 2 is the template."* Building the new fleet on the
  template is the consistent choice.

## 2. What it does not test

Stated plainly, so a green run is not over-read. This exercises the **software
chain** end to end and almost none of the **fleet topology**:

| Tested | Not tested |
| --- | --- |
| Terraform at maintenance mode, all four gaps | Multi-node anything |
| Cilium-only, including the `inlineManifests` seed | The L2 VIP, and the bridging it forces |
| Longhorn on 1.13.8, disk tags from machine config | Cross-node replication |
| `flux bootstrap` → `infrastructure/` → kro RGDs | `bulk` on a spinning disk |
| The platform API answering on a rebuilt cluster | Machine 1's join, and its 100 Mbit link |

Machine 1's join stays genuinely untested until it happens.

## 3. The memory budget — measured, and it does not fit as-is

Read off the live cluster 2026-09-02:

| | |
| --- | --- |
| Platform actual usage | **6287 Mi** (55% of the 12 GiB VM; requests 4604 Mi) |
| Machine 2 total | ~7372 Mi (7.2 GiB) |
| Longhorn instance manager, new | ~1000 Mi |
| Cilium replacing Flannel, net | ~350 Mi |
| **Like-for-like requirement** | **~7.6 Gi against 7.2 Gi** |

**So a like-for-like lift does not fit.** It fits with room if staged:

1. **Platform only** — kube-system ~1900, Cilium ~400, Longhorn ~1000,
   flux-system 442, kro 118, tailscale 316, metrics-server 91, cnpg 35 ≈
   **4.3 Gi**, leaving ~2.9 Gi.
2. **Observability, sized down.** It is 1485 Mi today and nearly all of that is
   Prometheus. Cut retention and set `resources` for this cluster rather than
   lifting the current values. Note `retentionSize` is the only real cap —
   `docs/storage-tiering-notes.md` and AGENT.md both record that these PVCs
   have no quota.
3. **Apps last.** `fastapi-echo` (206 Mi) and `personal-finance-dashboard`
   (71 Mi) are the least interesting part of the exercise, and they self-register
   from their own repos anyway (D16).

This is the constraint most likely to be discovered late and misread as a bug, so
size step 2 before starting rather than after Prometheus is OOMKilled.

## 4. Decisions this forces

### 4.1 `bulk` and `fast` both live on the one SSD

`fast` and `bulk` are **public API** — `rgd-database.yaml:96` hardcodes `fast`,
`rgd-application.yaml:172` enumerates both, and `victoria-metrics` and
`seaweedfs-runtime` name `bulk` directly. Machine 2 has one disk.

**Create both Longhorn disks on that SSD, tagged `fast` and `bulk`.** The class
contract then holds from day one, and it is honest in the way that matters:
`golden-architecture.md` §3 says classes name **guarantees**, not devices, and an
SSD *over-delivers* on `bulk`'s guarantee rather than under-delivering. When
machine 1 joins, tag its HDD `bulk` and Longhorn migrates replicas by disk tag —
no Platform API change, no PVC rewrite.

That is the tiering design working as designed, and it is a better demonstration
of the invariant than the two-disk case would be.

> Both tags must be set **at first registration**. The
> `node.longhorn.io/default-disks-config` annotation *"only takes effect when
> there are no existing disks or tags on the node"*, so getting this wrong means
> the UI forever — or, on machine 2, another rebuild. That is exactly the class of
> mistake this plan makes cheap.

### 4.2 A separate Flux entrypoint

Flux's entrypoint is `clusters/homelab/`. Bootstrapping a second cluster against
the same path makes both clusters reconcile the same manifests and contend for
the same tailnet hostnames — the apiserver `ProxyGroup` especially, where
recreating an exposure burns a Let's Encrypt certificate (AGENT.md).

**Use `clusters/homelab-metal/` and distinct tailnet hostnames until cutover**,
then retire the old entrypoint. Cheap now, unpleasant to unpick later.

### 4.3 Machine 1 joins as a worker

Two control planes tolerate exactly as many failures as one, while adding a
member that must agree (`multi-node-ha-design-notes.md` §1). So machine 1 joins
as a **worker**, and HA still waits for machine 3.

**Note the inversion this creates**: the *smaller* machine (7.2 GiB) becomes the
sole control plane and the *larger* one (15 GiB) a worker. Every fleet doc
currently assumes the opposite. It is fine — a control plane's floor is ~4 GiB
and machine 2 clears it — but it is the reverse of what the docs read like, and
it should be revisited when machine 3 arrives rather than inherited silently.

### 4.4 `certSANs` — generous is good hygiene, not a deadline

Enumerate what you know at build time:

- machine 2's address
- **machine 1's future *wired* address** — not its current Wi-Fi lease
- `localhost`, `127.0.0.1`
- tailnet names

> **This is NOT rebuild-only, and an earlier draft of this section said it was.**
> `install-media-and-reprovisioning-notes.md` §7 already recorded the correction:
> *"Anything embedded in a certificate is a future rebuild" is not true of
> `certSANs`, which regenerate the affected leaf certificates in seconds with no
> reboot.* The apiserver is a Talos **static pod**, not a bootstrap manifest, so
> `cluster.apiServer.certSANs` lands on an ordinary apply — `talos.tf` says the
> same thing about the `apiServer` block beside it.
>
> **The practical consequence: the VIP address does not have to be chosen now.**
> It can be added to `certSANs` on the day a VIP is actually wanted, which is the
> day a third machine arrives. Do not let an open question in
> `multi-node-ha-design-notes.md` §7 hold up this build.

Being generous is still worth doing — it saves an operation later, and
`talos.tf:122` records what a *missing* `certSAN` costs at bootstrap time
(`talos_machine_bootstrap` **hangs rather than errors**). But it is hygiene, not
a decision that has to be right the first time.

## 5. The sequence

```
 0  talosctl gen secrets  ──▶ SOPS-encrypt as the REAL cluster PKI
       endpoint-independent: gen secrets emits no addresses
       no VIP decision needed — see §4.4

 1  POWER ON machine 2, confirm maintenance mode on :50000
       no reinstall — see §5.1. It already boots Talos v1.13.8 from its
       own SSD with the Longhorn extensions loaded.

 2  terraform apply   node list of ONE, machine_type=controlplane
       preflight → config apply → bootstrap → inlineManifests seed Cilium
       ──▶ node Ready

 3  flux bootstrap  clusters/homelab-metal/
       ──▶ infrastructure/ reconciles: Longhorn, storage classes, CNPG,
           SeaweedFS, kro, tailscale operator, observability (sized down)

 4  platform API smoke test
       scripts/platform-render preview, then a real Database + ObjectStorage
       + Application instance. This is the actual acceptance criterion.

 5  cable machine 1, wipe it, join as a WORKER
       tag its HDD `bulk`; Longhorn migrates bulk replicas onto it

 6  cut over  ──▶ retire clusters/homelab/, the VM, and the Ansible roles
```

### 5.1 Do not reinstall machine 2 — apply to it as it stands

An earlier draft of this plan opened with *"reinstall machine 2 from a clean
schematic"*, to drop the leftover `talos.config=` kernel argument and add an
`ip=` static address. **That is the wrong call, and the reason is that the
machine has already changed underneath the advice.**

- **There is nothing left to kexec *from*.** Machine 2 ran Ubuntu when
  `machine-2-talos-install-record.md` was written; it now runs Talos. Route A is
  a one-time trick — the record says so: *"it is available exactly once, while
  Ubuntu is still there to jump from."* A reinstall now means Route B: flashing
  the ISO (built, **never flashed**), physically inserting it in a headless
  machine, and a firmware boot-order trip.
- **The installed image is already correct.** Schematic `3cbae7e7…` carries
  `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools`, which is what
  Longhorn needs.
- **The leftover `talos.config=` is inert.** It is consulted only when `STATE`
  holds no config. Terraform's apply puts one there, and it never fires again.
  The only exposure is the window before that apply, and only if something is
  serving on the Mac — so simply do not run `serve.sh` during the build.

So: power it on, apply the real config to the maintenance-mode API, and let
`machine.install` do the rest. If the schematic ever needs to change — adding the
Tailscale extension, for instance — that is `talosctl upgrade --image
factory.talos.dev/installer/<schematic>:<version>`, a reboot rather than a
reinstall, and it takes the kernel arguments with it.

**The consequence for addressing:** with no reinstall there is no chance to set an
`ip=` kernel argument on this machine, so its maintenance-mode address comes from
DHCP as it does today. That is fine — Terraform's machine config sets the address
statically from the first apply onward. Only the maintenance window depends on
DHCP, and the machine is findable by MAC (`f4:93:9f:f2:59:82`) if the lease has
moved. `terraform-on-bare-metal.md` §2's `ip=` recommendation still stands for
**machine 1**, which does get a fresh install.

**Steps 0–4 are reversible at zero cost.** The live platform is untouched
throughout; abandoning the exercise means powering machine 2 off. The first
irreversible act is step 5.

## 5.2 Manual prerequisites

Everything else in this plan is automatable. These are not:

| # | Thing | Why it needs hands |
| --- | --- | --- |
| 1 | **Power machine 2 on** | Verified 2026-09-02: it is **off** — a full `/24` sweep from machine 1 finds no ARP entry for `f4:93:9f:f2:59:82`. It is headless, has no BMC and no AMT (`hardware-fit-notes.md` §2), and the smart plug §7 recommends has not been bought. Someone presses the button. **This is the only hard blocker on starting.** |
| 2 | **Flux bootstrap credentials** | A GitHub token with write access to this repo. `flux bootstrap` is not a Terraform step and never has been. |
| 3 | **The age key, into the new cluster** | Flux decrypts `*.sops.yaml` with a `sops-age` Secret in `flux-system`. It is created by hand once per cluster, and the new cluster is a new cluster. |
| 4 | **New tailnet hostnames** | Chosen, not derived — §4.2. Two clusters must not contend for one hostname; recreating a Tailscale exposure burns a Let's Encrypt certificate (AGENT.md). |

And two that are not needed to *start*, but are needed before step 5:

| 5 | **An Ethernet cable for machine 1** | Talos has no Wi-Fi (`terraform-on-bare-metal.md` §0). |
| 6 | **Archive `terraform.tfstate` off machine 1** | It exists only there and step 5 wipes the machine. Cheap to do now, so do it now. |

> **On picking the node's address.** The DHCP pool on this LAN is unknown —
> observed leases run from `.44` to `.221`, which suggests a wide one. Two
> options, neither of which requires *configuring* the router: use whatever
> address DHCP gives machine 2 and have Terraform set that same address
> statically, or spend thirty read-only seconds reading the router's DHCP range
> and pick something outside it. The second is cleaner and worth the thirty
> seconds; the first is not wrong.

## 6. What stays running on machine 1 until step 6

Do not decommission these early — they are what makes the rollback free:

- the libvirt VM and the whole current cluster
- the Tailscale subnet router advertising `10.10.0.0/24`
- `heartbeat-watchdog` and `disk-space-watchdog`
- Terraform's state for the VM cluster, which exists **only** on this machine and
  must be archived off-box before step 5 regardless

The new cluster's Terraform state is separate from the old one. Keep both until
cutover completes.

## 7. What this changes elsewhere

| File | Change |
| --- | --- |
| ADR 0001 §4.1 | "One rebuild" is no longer the frame — there is one rebuild *of machine 1*, and unlimited rehearsals before it |
| `terraform-on-bare-metal.md` §0 | The Wi-Fi blocker no longer blocks starting, only machine 1's join |
| `multi-node-ha-design-notes.md` | Machine 2 as first control plane inverts its machine-1-first assumption |
| `hardware-fit-notes.md` §7 | Machine 3 is the top spend; the cable is now second, not blocking |
| `clusters/` | Gains `homelab-metal/` |

---

## Related

- `terraform-on-bare-metal.md` — the Terraform handoff this plan executes, and
  the Wi-Fi finding in its §0
- `cilium-only-networking.md` §5.1 — the seed step 2 depends on
- `platform-api-under-d20.md` — the three breakages that must land with Longhorn
- `hardware-fit-notes.md` — the fleet as measured
- `machine-2-talos-install-record.md` — how this machine was installed, and what
  to do differently (the leftover `talos.config=`)
- `docs/talos-cutover-runbook.md` — the k3s→Talos rehearsal; step 6 is its
  successor
