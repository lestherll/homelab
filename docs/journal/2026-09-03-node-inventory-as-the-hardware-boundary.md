# The node inventory, and hardware stopping at one file

**Date:** 2026-09-03 · **Tags:** terraform, fleet, talos, longhorn, gitops

**Problem:** adding a second machine was not really automated, and the reason
was not effort — it was that three hardware facts were **module-wide**: the
Longhorn disk list, the kubelet's bind mounts, and (by omission) the install
target. Every node therefore got machine 2's layout.
`hardware-fit-notes.md` §6 had already named this — *"the fleet is
heterogeneous, and D20 assumes it is not"* — and machine 1 (laptop, 931G HDD,
battery) versus machine 2 (SFF desktop, one SSD) are near-opposites on every row
that matters.

**Finding, by planning a hypothetical second node rather than reasoning:**
1. `dial_over_lan` was a **bool**, so joining a machine forced the whole fleet
   onto LAN dialling — making "add a node" a LAN-only operation, moments after
   #95 made everything else remote.
2. `longhorn_disks` sat in `common_patches`, so machine 1 could not have had
   `bulk` on its HDD while machine 2 dropped it — the exact migration the
   comments promised.
3. `machine.install.disk`/`diskSelector` was **never set at all**. Machine 2
   happened to be `/dev/sda`.

**Decision:** build Stage 2 of `inventory-and-provisioning-approach.md` — which
was already the recommended design, just unbuilt. `fleet/nodes.yaml` holds role,
zone, MAC, address, install disk selector and Longhorn disks per node; the
module consumes it via `yamldecode`.

**Why YAML and not HCL** (from that note, unchanged): so something else can
consume it later. It maps onto Tinkerbell's `Hardware` field-for-field, so a
USB-installed fleet can be adopted into netboot without reinstalling. And
deliberately **not** a CRD — nothing reconciles a machine that has not joined,
so a CRD with no controller is inert data wearing a costume.

**The install target is a SELECTOR, and the reason is measurable.** `talosctl
get disks` on machine 2:

```
sda  512 GB  sata   MTFDDAK512MAY-1A     <- the real disk
sdb  2.1 GB  iscsi  VIRTUAL-DISK         <- Longhorn's own, appears at RUNTIME
```

A path or a "first disk" rule eventually installs to Longhorn's own volume.
`{size: ">= 256GB", type: ssd}` says what is meant and carries to any machine.
Both fields verified against v1.13.8.

**What is now derived rather than configured,** per node, from one block:
certSANs, MagicDNS name, Terraform's dial target, ACL membership (via
`tag:talos`), Longhorn disk tags, kubelet bind mounts, zone label.

**Validation:** plan with a hypothetical heterogeneous second node — one SSD +
one HDD, different selector — gives `2 to add, 2 to change, 0 to destroy`, with
the existing node dialled at its tailnet name and the new one at
`192.168.0.222`. That mixed case is the thing a boolean could not express.

**Still not automated,** and now the only remaining gap: Terraform cannot reach
a maintenance-mode node at a DHCP address, because `maintenance_ready` probes
the node's *target* static address. Machine 2 was worked around by hand
(`headless-talos-install.md` §8 applies the first config at the DHCP address).
The fix is a **DHCP reservation** — which is LES-177 option (c), so that issue
turns out to be a prerequisite for step 4–5 automation and not only a
portability nicety.

**Ref:** LES-177; `docs/fleet/inventory-and-provisioning-approach.md` §3
