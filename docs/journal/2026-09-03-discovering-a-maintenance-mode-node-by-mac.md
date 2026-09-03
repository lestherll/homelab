# Finding a machine before it has the address you gave it

**Date:** 2026-09-03 · **Tags:** terraform, talos, fleet, provisioning

**Problem:** Terraform has to talk to a node *before* that node has the address
the inventory assigns it. `terraform_data.maintenance_ready` polled the node's
**target** static address, so a fresh machine timed out after five minutes with
"is it powered on and in maintenance mode?" — when it was powered on, in
maintenance mode, and simply somewhere else. Machine 2 was worked around by
hand (`headless-talos-install.md` §8 applies the first config at the DHCP
address). This was the last gap in automating steps 4–5 of
`provisioning-automation-without-netboot.md` §1.

**Finding:** verified against the v1.14 docs — *"Talos Linux runs by default a
DHCP client on all physical network interfaces."* So the machine always has an
address; it is just not predictable. That reframes the problem from "give it a
known address" to "find it".

**Options, and why a reservation lost:**
- **DHCP reservation** — works, zero hardware, but lives in router NVRAM: not
  diffable, not reviewable, not restorable, and gone on a new router. That is
  the same objection LES-177 raises about the whole addressing model.
- **Own DHCP server** — version-controlled, but you must disable the router's
  (the homelab becomes the house's DHCP) or add VLANs, which is the only option
  that costs hardware.
- **`ip=` kernel argument in boot media** — verified supported (v1.13.8
  `ParseCmdlineNetwork` parses `ip=`; full field list in `cmdline.go`), and the
  best end state, but it only pays off when you are building media anyway.
- **Discovery** — chosen. Nothing outside git, no hardware, works on any
  network, and needs no new boot media.

**Decision:** `terraform/scripts/discover-maintenance-node.sh`, wired through a
`data "external"` gated on `var.dial_over_lan`, so an ordinary plan never shells
out.

**ARP rather than a port sweep**, deliberately: ARP maps MAC to address
*directly*, which is exactly the lookup the inventory gives us. A `:50000` sweep
finds every Talos node and then needs a second step to tell them apart — and
that second step would be `talosctl --insecure`, which only works on an
unconfigured node anyway.

**The bug that would have been silent:** macOS `arp` prints `0:11:22:...` where
the inventory writes `00:11:22:...`. Comparing raw strings never matches, and
the failure presents as "machine not found" — indistinguishable from a machine
that is off. Hence the octet-normalising comparison, tested both ways.

**Validation** (on-LAN, against the real node):
- correct MAC, deliberately wrong expected address → ARP sweep found
  `192.168.0.221` in ~5s
- same with the MAC upper-cased, as a router UI prints it → found
- unknown MAC → clean failure in 5s, message naming the likely cause
- ordinary `terraform plan` → no `data.external` read at all
- `-var 'dial_over_lan=["homelab-worker-0"]'` → discovery reads, endpoint
  resolves to the LAN address

**Not yet exercised:** an actual machine in maintenance mode, since there is not
one. The fast path and the ARP path are both proven against a configured node,
which shares the mechanism.

**Follow-up:** `ip=` in boot media (LES-177) remains the better end state and
makes the ARP path a fallback rather than the norm. Its one open question is
that `ip=`'s device field is an interface *name* resolved by
`linkNameResolver`, while the inventory identifies interfaces by MAC — fine on
a single-NIC machine, unsettled on machine 1, which has wired and wireless.

**Ref:** LES-177; `terraform/README.md` — "Adding a machine"
