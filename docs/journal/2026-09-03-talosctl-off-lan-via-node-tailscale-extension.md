# Remote `talosctl` by putting Tailscale on the node, not a subnet router

**Date:** 2026-09-03 · **Tags:** talos, terraform, tailscale, fleet

**Problem:** `kubectl` worked off-LAN; `talosctl` did not. `talosctl` is the
only way into a node with no shell and no SSH, so LAN-only is a real constraint
during an incident — and the `kubectl` path runs *inside the cluster it proxies
to*, so it is unavailable in exactly the situations `talosctl` is wanted for.

**Context:** `homelab-worker-0` on `192.168.0.221`, Talos v1.13.8, schematic
`3cbae7e7…` (`iscsi-tools`, `util-linux-tools`). Not a tailnet device. The only
subnet route on the tailnet, `homelab -> 10.10.0.0/24`, belongs to machine 1 —
off, and about to be wiped.

**Decision:** option (c) of `fleet-provisioning-design-notes.md` §6.4 — the
`siderolabs/tailscale` system extension on the node itself. New schematic
`708747e350d604ae9e57227d8dcf274091453ddb1097b765d4ea8884f1992c1f`, an
`ExtensionServiceConfig` rendered by `terraform/modules/talos-metal/`, a derived
tailnet certSAN per node, and a `tag:talos` grant on `tcp:50000`.

**Alternatives considered:**
- SSH to machine 1 and run `talosctl` there — routes the bare-metal node's only
  diagnostic path through a different machine.
- Machine 1 advertises `192.168.0.0/24` as a subnet router — same single point
  of failure, and it dies with machine 1.

**Why derived addresses rather than pinned ones:** one variable,
`tailnet_domain`, feeds certSANs, `TS_HOSTNAME` and the `talos_endpoints`
output as `<hostname>.<tailnet_domain>`. A `100.x` address is stable per
*device*, and a device is exactly what gets replaced on a rebuild or reset. The
ACL destination is a **tag** for the same reason — the VM's `talos-cp-01:
10.10.0.10` `hosts` pin has to be re-edited every time that address moves. The
bootstrap path (cluster endpoint, interface address, Terraform's apply target)
stays on the LAN by necessity: it all runs before tailscaled exists.

**Findings, all verified rather than assumed:**
- **Talos APPENDS list values across config patches.** Confirmed with `talosctl
  gen config` v1.13.8: three patches setting `machine.certSANs` produced the
  union, not the last one. The existing `common_patches` / per-node split was
  silently depending on this.
- **`TS_USERSPACE` is already `false`** in the extension's own service
  definition. containerboot's default is `true`, and userspace mode has no
  kernel `tailscale0` — inbound `:50000` would never reach `apid`, so the node
  would appear on the tailnet and refuse every connection.
- **`TS_AUTH_ONCE` defaults to `false`** (containerboot v1.98.9,
  `settings.go`), meaning `tailscale up --authkey` runs on every service start —
  and Talos restarts the service every boot. Left alone, each reboot depends on
  a key Tailscale caps at 90 days. Set to `true`.
- **`TS_ACCEPT_DNS` unset already renders `--accept-dns=false`** (`AcceptDNS` is
  a `*bool`). Set explicitly anyway: the consequence of upstream flipping it is
  a single control plane's resolver silently becoming MagicDNS.

**Security impact:** a tailnet device has no subnet route to withhold, so the
port list is now the *only* boundary. `:9100` on the node is unauthenticated
node-exporter (HTTP 200, measured). The grant is `tcp:50000` alone, and the
`tests` block denies `:9100`, `:10256`, `:6443`, `:2379`, `:10250` and `:22` so
a widening to `["*"]` cannot pass silently. Reachability is device-independent
(`autogroup:member`); credentials are not — `apid` is mutual TLS with **no
CRL**, so second devices get `talosctl config new --roles os:reader --crt-ttl
720h` rather than a copy of the admin config.

**Validation:** schematic minted and read back from the Image Factory;
`siderolabs/tailscale` confirmed present for v1.13.8 (`ghcr.io/siderolabs/
tailscale:1.98.9`); the `ExtensionServiceConfig` document and the certSAN
append verified against `talosctl gen config` v1.13.8; `terraform validate`
clean; `policy.hujson` parses and its tag/grant/tests land as intended. **Not
yet validated on the node** — that needs the auth key and the `talosctl
upgrade`.

**Follow-up:**
- Mint the reusable `tag:talos` auth key, `terraform apply`, then `talosctl
  upgrade` — the extension does **not** install on apply-config. Runbook in
  `docs/fleet/talosctl-off-lan.md` §5.
- The upgrade also finally drops the dormant
  `talos.config=http://192.168.0.44:8080/config.yaml` kernel argument, which
  `talosctl reset` would otherwise activate into a node with no API at all.
- Break-glass `kubectl` at `:6443` on the node needs
  `cluster.apiServer.certSANs` plus one grant; deliberately left out.
- Delete `talos-cp-01`, its autoApprover, grant and tests when machine 1 is
  wiped — marked superseded in `policy.hujson`, not removed.

**Ref:** `docs/fleet/talosctl-off-lan.md`;
`docs/fleet/fleet-provisioning-design-notes.md` §6.4
