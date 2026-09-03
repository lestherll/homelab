# Installing Tailscale silently moved the node's Kubernetes identity onto the tailnet

**Date:** 2026-09-03 · **Tags:** talos, tailscale, networking, etcd

**Problem:** after the reboot that installed the `siderolabs/tailscale`
extension, `kubectl get node -o wide` reported `INTERNAL-IP 100.105.86.101`.
Earlier the same day it was `192.168.0.221`. Nothing was configured to change
it, and nothing reported that it had.

**Finding:** with `machine.kubelet.nodeIP` unset, Talos deduces `validSubnets`
from the service CIDRs, which comes out as "any address of the right family".
The kubelet then picks by sort order, and `100.105.86.101/32` sorts ahead of
`192.168.0.221/24`. Adding a second address to the node was enough to move it.

It carried more than the node object: node-exporter's Endpoint moved with it,
and etcd was already advertising `https://100.105.86.101:2380` as its peer URL.

**Why it matters** — nothing was broken at the time, and that is the point:
- The node's cluster identity became dependent on tailscaled, and therefore on
  an auth key Tailscale caps at 90 days.
- Once machine 1 joins, Longhorn replica sync and etcd peer traffic between two
  machines on the same switch would run through WireGuard. Silently.
- It was a boot race, not a setting — which address won depended on whether
  tailscaled came up before the kubelet registered. So it would not necessarily
  reproduce, which is worse than a deterministic fault.

**The trap that nearly shipped:** the obvious fix is to exclude the tailnet
range. `net.FilterIPs` — called by BOTH `machine.kubelet.nodeIP.validSubnets`
and `cluster.etcd.advertisedSubnets` — starts from an **empty** set: a positive
CIDR adds, a negative one subtracts. A negatives-only list therefore matches
**nothing**. The kubelet then logs `no suitable node IP found` and sets no
`--node-ip` at all — a log line, not an error, on a single control plane.
Simulated against the node's real address list:
`["!100.64.0.0/10", "!fd7a:115c:a1e0::/48"]` → `[]`.

**Decision:** positive base, then subtract, on both fields:

```
["0.0.0.0/0", "!100.64.0.0/10"]     → ['192.168.0.221']
```

**Why no LAN subnet appears:** the first draft pinned `192.168.0.0/24`, which
would have hardcoded the house LAN into the machine config — the operator
caught it, and it is the better design by a distance. `0.0.0.0/0` means
"whatever IPv4 this machine has on whatever network it is plugged into", so a
new router, a new subnet or a house move needs no edit here. Pod/service CIDRs
and VIPs need no entry either: Talos always excludes them
(`nodeip_config.go`), and etcd's candidate list is already the no-k8s one.

**The inversion worth remembering:** the tailnet IP is the *stable* address —
it follows the machine to any network — and the LAN IP is the volatile one.
Intuition says the opposite. That is precisely why the tailnet address should be
what the *operator* dials, and must not be what the *cluster* uses internally.

**Validation:** `net.FilterIPs` ported to Python and run against the node's
actual addresses (`10.244.0.88`, `100.105.86.101`, `192.168.0.221`,
`fd7a:115c:a1e0::a72b:5666`), including Talos's automatic pod/service-CIDR
exclusions — both fields yield `['192.168.0.221']`. `terraform plan`: one
in-place update, no replacement.

**Follow-up:** applying this restarts etcd, which on a single control plane is a
brief apiserver outage. Doing it with ONE member is deliberate — renegotiating a
peer URL with quorum to preserve is strictly harder. The larger question of how
a node gets its LAN address at all is LES-177.

**Ref:** LES-177; `docs/fleet/talosctl-off-lan.md`
