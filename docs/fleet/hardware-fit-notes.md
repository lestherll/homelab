# The actual machines, and what they invalidate

**Status: research/measurement, 2026-08-31. Nothing built.** Written after the
operator named the hardware, which turns several open questions in
`docs/adr/0001-single-model-talos-fleet.md` and `docs/fleet/target-architecture.md`
from *assumptions* into *facts*. Three of those facts are unwelcome, and one of
them is a genuine asset that the design has no slot for.

It also closes the one action item left by `docs/fleet/tinkerbell-investigation.md`
— *"check whether the mini-PCs have Intel vPro/AMT"* — **negative, on both
machines, at the chipset level.**

---

## 1. The fleet, as measured

Neither machine is a mini-PC, which is what the ADR and the survey both assumed
throughout. One is a laptop and one is a small-form-factor business desktop.

| | **Machine 1** — `homelab-01` | **Machine 2** — `homelab-worker-0` |
| --- | --- | --- |
| Model | Dell Inspiron 5770 (17.3" laptop) | Lenovo ThinkCentre M710e SFF |
| CPU | 8th-gen Core U-series, 4 cores / 8 threads | **i3-7100, 2 cores / 4 threads** |
| RAM | 15 GiB | **3.2 GiB** |
| Chipset | mobile (consumer) | **Intel B250** |
| Disks | 128G SSD (`LITEON CV8-8E128`) + **931G 5400rpm 2.5" HDD** (`ST1000LM035`) | **one** — 477G SSD (`MTFDDAK512MAY`) |
| Free bays | none (both occupied) | 3.5" + 2.5" + M.2 all free |
| NIC | Gigabit Ethernet | Realtek PCIe GbE (`enp1s0`) |
| Firmware | — | UEFI, **Secure Boot enabled** |
| Out-of-band mgmt | **none** | **none** |
| Role today | Ubuntu + libvirt + the Talos VM | Ubuntu 26.04.1, awaiting the Talos wipe |

Machine 2's row is measured, not inferred — `headless-talos-install.md` §0 read
it over SSH on 2026-08-29. Machine 1's disks come from
`docs/storage-tiering-notes.md`; its CPU/RAM are as `target-architecture.md` §10
records them. The model names are the operator's, and they are consistent with
everything measured: a `ST1000LM035` is a 2.5" laptop drive, which is why
machine 1's "bulk" tier is 5400rpm in the first place.

**There is no machine 3.** D20 needs three for etcd quorum.

## 2. AMT: closed, negative

`tinkerbell-investigation.md` §2 flagged that Rufio supports Intel AMT natively
and that vPro machines would get remote power and boot control for free. Worth
ten minutes with a spec sheet, it said. Here is the result:

- **Machine 2 is B250.** In Intel's 200-series, **only Q270 supports vPro**;
  Q250 and B250 do not. AMT is not a firmware option that can be switched on —
  the chipset does not have the capability.
- **Machine 1 is a consumer Inspiron on an 8th-gen U-series part.** Dell's
  consumer line does not ship vPro; that is the Latitude/Precision differentiator.

So **no machine in this fleet has out-of-band management, and none can acquire
it**. Every "if the hardware has a BMC" branch in the Metal³ and Tinkerbell notes
is now dead for the current fleet, and the Metal³ verdict is confirmed at the
part-number level rather than by inference: its revisit trigger (a hardware
refresh bringing a real BMC) has not been met and will not be by these two.

## 3. The smart plug does not work on machine 1

This one matters more than it looks, because it contradicts the single most
confident recommendation in the whole survey.

`fleet-control-plane-survey.md` §7, item 1:

> "**Buy a smart plug per machine, before anything else.** It is plane 1, it is
> the only plane that needs hardware, it costs about £15 a machine… It is also
> the difference between 'machine 2 is wedged' being a walk and being a curl."

**Machine 1 is a laptop with a battery.** Cutting mains power does not power-cycle
it; it switches it to battery. A smart plug on machine 1 is a charger switch, not
a power switch. And even once a battery is flat, laptops generally lack the
*"restore power state after AC loss"* firmware setting that desktops have — worth
confirming in machine 1's BIOS rather than assuming either way, but the default
expectation is that it will not auto-power-on.

Machine 2, being a desktop, has no such problem: a smart plug plus the BIOS
"After Power Loss → Power On" setting gives real remote power for about £15,
exactly as the survey says.

**So plane 1 is buyable for half this fleet and not the other half**, and the
half it fails on is the half currently running everything. That is not a reason
to skip the plug for machine 2; it is a reason to stop describing remote power as
a solved £15 problem for the fleet as a whole.

### 3.1 The compensation: machine 1 has a UPS

The same battery that defeats the smart plug is a genuine asset the design has
nowhere to record. `target-architecture.md` §8's failure matrix ends with:

> "**The power circuit dies** → **everything is down** → cold start, §9"

For machine 1 that is simply not true — it rides out a mains cut for as long as
its battery holds, which on a 17" laptop idling is a meaningful window. A fleet
where one node survives a power cut is a *better* position than the matrix
describes, and it is the one node holding the only HDD.

Two consequences worth carrying into the design rather than discovering later:

- **An orderly shutdown becomes possible.** Machine 1 can, in principle, notice
  mains loss and act on it. Talos has no `upsd`, so this is not free, but it is
  the difference between an etcd snapshot on the way down and a hard stop.
- **It argues against treating machine 1 as interchangeable cattle.** D20's
  invariant is that machines are cattle; this machine is measurably not — most
  RAM, only HDD, only battery. See §6.

## 4. The capacity budget is wrong, and by a lot

`target-architecture.md` §10 is explicit that it was guessing:

> "Assumes three machines broadly like machine 1 (8 cores, 15Gi) — **verify
> before committing**"

Verified. It does not hold.

| | §10 assumed | Actual |
| --- | --- | --- |
| Machine 1 | 8 threads / 15Gi | 8 threads / 15Gi ✓ |
| Machine 2 | 8 threads / 15Gi | **4 threads / 3.2Gi** |
| Machine 3 | 8 threads / 15Gi | does not exist |
| **Fleet RAM** | **45Gi** | **18.2Gi** across two machines |

The budget concluded *"~16Gi of 45Gi"* for the platform and *"~25Gi left for
applications"*. Against 18.2Gi there is no such headroom.

**And the per-machine floor is the harder number.** D20 makes every machine a
control plane *and* a Longhorn node. Taking §10's own per-machine figures and
dividing by three:

| Per-machine daemon | ~RAM |
| --- | --- |
| Talos + kubelet | ~1.0Gi |
| etcd | ~0.5Gi |
| Cilium | ~0.4Gi |
| Longhorn instance manager | ~1.0Gi |
| **Floor, before any workload** | **~2.9Gi** |

**Machine 2 has 3.2Gi.** It would spend ~90% of its memory being a member of the
cluster, leaving ~0.3Gi to do anything. It cannot be a D20 node as designed. This
is the concrete version of what `multi-node-ha-design-notes.md` §3.1 already
called *"marginal for a control-plane node"* and what `headless-talos-install.md`
§4 repeats — both were right, and neither had the arithmetic.

**The fix is cheap and is the highest-leverage purchase in the whole D20 plan.**
The M710e takes 2 × DDR4 non-ECC UDIMMs to **32GB**. Going to 16GB or 32GB costs
less than a single smart plug per machine and moves machine 2 from "cannot
participate" to "comfortable". Nothing else on any list in this repo buys as much.

## 5. Storage: the tiers cannot exist on machine 2

`target-architecture.md` §5 maps SSD → Longhorn `fast`, HDD → Longhorn `bulk`, per
machine. **Machine 2 has one disk.** So:

- Machine 2 can host `fast` and `scratch`. It cannot host `bulk` at all.
- `bulk` is specified at **2 replicas** (§5.1). Two replicas require two machines
  with an HDD. **The fleet has one HDD**, in machine 1. As things stand `bulk`
  can only ever be 1 replica, which is not what §5.1 decided.
- The `bulk` tier is where `ObjectStorage` lives (SeaweedFS) and where
  VictoriaMetrics' PVC lives. Both would be unreplicated.

**Also cheap to fix, and machine 2 has the room**: its 3.5" bay, 2.5" bay and M.2
slot are all free. A 3.5" HDD in the M710e restores the two-tier model there.

One caveat to record before it becomes a surprise: machine 1's `bulk` disk is a
**5400rpm 2.5" laptop drive**, while a 3.5" desktop drive in machine 2 would be
7200rpm. Longhorn would replicate `bulk` across disks of materially different
throughput, and a replicated volume runs at the pace of the slowest replica it
must acknowledge. §10's warning that *"Longhorn replica placement wants comparable
disk sizes"* understates it — comparable *speed* matters at least as much here.

## 6. The fleet is heterogeneous, and D20 assumes it is not

Every design document on this branch is written for interchangeable machines:
`allowSchedulingOnControlPlanes: true` on all three, identical roles, topology
labels so replicas spread evenly, *"machines are cattle"* as invariant 8's
justification. The measured fleet is not that:

| | Machine 1 | Machine 2 |
| --- | --- | --- |
| RAM | 15Gi | 3.2Gi (until upgraded) |
| Bulk storage | 931G HDD | none (until added) |
| Survives mains loss | **yes** (battery) | no |
| Remote power via plug | **no** (battery) | yes |
| Form factor | laptop | SFF desktop |

The two machines are close to opposites on every row that matters. Nothing in
D20 currently expresses that, and the honest reading is that **machine 1 is the
outlier and machine 2 is the template**. A third machine should therefore look
like the ThinkCentre, not like the laptop: SFF desktops are the sane cattle unit,
they take a smart plug, they have drive bays, and a matched pair plus a third
gives the uniform fleet the design already assumes.

This also settles a smaller question by itself. `multi-node-ha-design-notes.md`
already says machine 2 joins as a **worker** until machine 3 exists, because two
control planes tolerate exactly as many failures as one. That was argued from
etcd; the hardware now agrees for a second, independent reason — at 3.2Gi machine 2
cannot afford to be a control plane anyway. **The two arguments converge on the
same plan, which is a good sign it is the right one.**

## 7. What to buy, cheapest first

1. **RAM for machine 2** — 2 × DDR4-2400 non-ECC UDIMM, to 16GB or 32GB. The
   single highest-leverage item in D20 (§4). Do this before anything else.
2. **A 3.5" HDD for machine 2**, if `bulk` is to be replicated at all (§5). The
   bay is free.
3. **A smart plug for machine 2 only**, if remote power is wanted later. It does
   not work on machine 1 (§3), so buy one, not "one per machine".
4. **Machine 3, matched to machine 2**, when quorum is wanted. An SFF desktop of
   the same class, ideally with a **Q-series chipset** so the fleet finally gains
   out-of-band management and the Metal³/Tinkerbell BMC branches reopen (§2).

Note what is *not* on this list: nothing software. Every constraint found here is
answered by parts, and mostly by cheap ones.

## 8. What this does not change

- **The USB-install decision stands**, and is reinforced. Both machines install
  from a stick; machine 2's route is already written up in
  `headless-talos-install.md`, Secure Boot caveat included.
- **The Metal³ verdict stands**, now confirmed at the chipset level rather than
  by assumption (§2).
- **The Tinkerbell timing stands** — its value is the netboot layer, which is
  deferred, and its one open action item is closed negative here.
- **Machine 2's cluster join is still blocked** on the bridged-network + VIP
  rebuild of machine 1, per `headless-talos-install.md` §10. Nothing here unblocks
  it; the RAM upgrade is worth doing before that rebuild lands, not after, since
  the rebuild is the moment machine 2's role gets fixed in a config.

---

## Sources

Measured, in this repo:

- `docs/fleet/headless-talos-install.md` §0 — machine 2, read over SSH 2026-08-29
- `docs/storage-tiering-notes.md` — machine 1's two disks, by model
- `docs/fleet/target-architecture.md` §5, §8, §10 — the assumptions tested here
- `docs/fleet/multi-node-ha-design-notes.md` §3.1 — the prior "marginal" judgement

Vendor / third-party specifications:

- [Intel B250 chipset — product specifications](https://www.intel.com/content/www/us/en/products/sku/98086/intel-b250-chipset/specifications.html)
- [Q270/Q250 chipset brief](https://www.intel.com/content/www/us/en/chipsets/business-chipsets/q270-q250-chipset-brief.html) — vPro is Q270-only in the 200 series
- [Puget Systems — Z270, H270, Q270, Q250, B250: what is the difference](https://www.pugetsystems.com/labs/articles/z270-h270-q270-q250-b250-what-is-the-difference-876/)
- [Lenovo PSREF — ThinkCentre M710e SFF](https://psref.lenovo.com/Detail/ThinkCentre/ThinkCentre_M710e_SFF) — B250, 2 DIMM slots, 32GB max
- [Crucial — ThinkCentre M710e SFF upgrades](https://www.crucial.com/compatible-upgrade-for/lenovo/thinkcentre-m710e-sff)
- [Dell — Inspiron 17 5770 setup and specifications](https://www.dell.com/support/manuals/en-us/inspiron-17-5770-laptop%20%20/inspiron-5770-setupandspecifications/memory) — 2 SODIMM slots, 32GB max, 2.5" bay + M.2
