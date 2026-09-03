# `talosctl` off-LAN

**Status: built in the repo, not yet on the node (2026-09-03).** Every
declarative half of this has landed — schematic, `ExtensionServiceConfig`,
certSANs, ACL tag and grant. The two halves that cannot be committed are the
auth key and the `talosctl upgrade`; §5 is that runbook. Until it runs, the node
is still LAN-only and this document describes intent rather than fact.

`kubectl` already worked off-LAN before this, via `svc:kube-apiserver-metal` and
Google OIDC. This is the other half, and it is the half that matters more:
`talosctl` is the **only** way into a node with no shell and no SSH, and the
`kubectl` path runs *inside the cluster it proxies to*, so it is unavailable in
exactly the situations you want it — a wedged apiserver, a bad Flux change, a
rebuild.

> **The break-glass path for remote `kubectl` is remote `talosctl`.**
> — [fleet-provisioning-design-notes.md §6.1](fleet-provisioning-design-notes.md)

## 1. Where things stood

| | |
| --- | --- |
| Node | `homelab-worker-0`, `192.168.0.221`, Talos v1.13.8 |
| Talos API | `192.168.0.221:50000` — **LAN only** |
| Old schematic | `3cbae7e7…` — `iscsi-tools`, `util-linux-tools`, and a leftover `talos.config=` kernel argument |

Nothing bridged `192.168.0.0/24` to the tailnet. The only subnet route on the
tailnet is `homelab -> 10.10.0.0/24`, which belongs to machine 1 — off, and
about to be wiped. The node was not a tailnet device itself: the schematic
omitted `siderolabs/tailscale`, a decision
[headless-talos-install.md §10.1.1](headless-talos-install.md) deliberately left
open until the node that forces it existed.

## 2. The decision: Tailscale on the node, not a subnet router

[fleet-provisioning-design-notes.md §6.4](fleet-provisioning-design-notes.md)
lays out three options and recommends this one. Both rejected options fail the
same way:

| | Survives machine 1 being down |
|---|---|
| SSH to machine 1, run `talosctl` there | **no** |
| Machine 1 advertises `192.168.0.0/24` as a subnet router | **no** |
| **Tailscale system extension on the node** | **yes** |

A subnet router routes the bare-metal node's *only* diagnostic path through a
different machine, and "machine 1 is down" is a case you actively want
`talosctl` for. It also dies with machine 1, which is imminent.

The rationale that previously blocked this — `stage-talos-image.sh`'s *"Tailscale
stays on the host, which keeps one tailnet identity and dissolves the certSANs
chicken-and-egg"* — is **host-shaped, and a bare-metal node has no host.**

## 3. Addresses, and why almost none appear

The obvious way to build this is to pin the node's tailnet IP. Don't: a `100.x`
address is stable *per device*, and a device is exactly the thing being replaced
when a node is rebuilt or reset.

Everything here is derived from one variable instead:

```
tailnet_domain = "tailf4742d.ts.net"          # clusters/homelab-metal/main.tf
       ↓
local.tailnet_names[k] = "<hostname>.<tailnet_domain>"
       ↓
  ├── machine.certSANs           ← what TLS is verified against
  ├── TS_HOSTNAME                ← what the node asks Tailscale to call it
  └── output "talos_endpoints"   ← what `talosctl config endpoint` is set to
```

`<hostname>` is `each.key` of the `nodes` map, which is also what `HostnameConfig`
sets — so the MagicDNS name is not a prediction about what Tailscale will pick,
it is the value handed to it. Adding machine 1 to the `nodes` map gets it a
certSAN, a MagicDNS name and an endpoint with no further edit.

The ACL destination is a **tag**, `tag:talos`, for the same reason — see §4.

### What still has to be a raw address, and why

Three places, all of them **before tailscaled exists**, so no tailnet name can
work there:

- `cluster_endpoint_ip` / `cluster_endpoint` — baked into every machine config
  and used by the kubelet at boot, when the node's resolver is
  `machine.network.nameservers` and `tailscale0` does not yet exist.
- `nodes[].ip` — the static address the interface is configured *with*. This is
  set by us, not by DHCP, so it does not drift; the renumbering risk is a new
  router or a new LAN, not a moving lease.
- `terraform_data.maintenance_ready` and `talos_machine_configuration_apply` —
  Terraform talks to a node in **maintenance mode**, which is before it has a
  config at all, let alone a tailnet identity. Terraform stays on the LAN by
  necessity; that is a different job from day-to-day `talosctl`.

So: **the bootstrap path is LAN, the access path is tailnet.** Conflating them
is what produces a chicken-and-egg.

## 4. What landed

1. **New schematic `708747e350d604ae9e57227d8dcf274091453ddb1097b765d4ea8884f1992c1f`**
   — minted and read back 2026-09-03. The ID is a content hash of the
   customization, so it is re-mintable rather than an opaque handle:

   ```yaml
   customization:
     systemExtensions:
       officialExtensions:
         - siderolabs/iscsi-tools
         - siderolabs/tailscale
         - siderolabs/util-linux-tools
   ```

   `siderolabs/tailscale` resolves to `ghcr.io/siderolabs/tailscale:1.98.9` at
   v1.13.8. The leftover `talos.config=http://192.168.0.44:8080/config.yaml`
   kernel argument is **gone** — see the trap in §6.

2. **`ExtensionServiceConfig`** in `terraform/modules/talos-metal/talos.tf`, as
   its own `v1alpha1` document (verified accepted by `talosctl gen config`
   v1.13.8):

   ```yaml
   apiVersion: v1alpha1
   kind: ExtensionServiceConfig
   name: tailscale
   environment:
     - TS_AUTHKEY=…                              # from SOPS, never in tfstate
     - TS_HOSTNAME=homelab-worker-0
     - TS_AUTH_ONCE=true
     - TS_ACCEPT_DNS=false
     - TS_EXTRA_ARGS=--advertise-tags=tag:talos
   ```

3. **certSANs** gain `<hostname>.<tailnet_domain>` automatically. Verified
   against v1.13.8 that Talos **appends** list values across config patches, so
   this coexists with `127.0.0.1`/`localhost` from `common_patches` rather than
   replacing them.

4. **ACL** — `tag:talos` in `tagOwners`, one grant
   (`autogroup:member` → `tag:talos` on `tcp:50000`), and two test cases whose
   deny half is the load-bearing one.

5. **`.sops.yaml`** rule for `tailscale-authkey.sops.yaml`, and a
   `clusters/homelab-metal` first-run section in `terraform/README.md`.

### The three env vars that are not obvious

All three verified against containerboot v1.98.9 rather than assumed.

- **`TS_USERSPACE` is not set here, and must not be.** The Talos extension
  already pins it `false` in its own service definition. containerboot's own
  default is `true`, and in userspace mode there is no kernel `tailscale0`
  interface — inbound `:50000` would never reach `apid`, so the node would
  appear on the tailnet and refuse every connection.
- **`TS_AUTH_ONCE=true`.** containerboot's default is `false`, meaning it runs
  `tailscale up --authkey` on **every** service start — and Talos restarts the
  service on every boot. The default quietly makes each reboot depend on a key
  Tailscale caps at 90 days.
- **`TS_ACCEPT_DNS=false`.** This is already containerboot's behaviour when the
  variable is unset (`AcceptDNS` is a `*bool`; nil renders `--accept-dns=false`),
  but that is upstream's default rather than ours, and the consequence of it
  flipping is a single control plane's resolver silently becoming MagicDNS.
  `machine.network.nameservers` is meant to be the only thing that decides that.

## 5. Runbook — the half that is not committable

Order matters. Steps 1–2 are on the LAN; step 5 is the first thing that proves
the change.

1. **Mint a reusable, `tag:talos`-tagged auth key** and SOPS it — command in
   `terraform/README.md`. A key *without* the tag produces a node that joins as
   a user-owned device, matches no grant, and reads as "Tailscale is broken".

2. **Merge this branch**, so the ACL applies. `.github/workflows/tailscale-acl.yml`
   runs on push to `main` touching `tailscale-acl/`; PRs run the same policy in
   `test` mode. `tag:talos` must exist in `tagOwners` **before** the key is used,
   or minting a tagged key is rejected.

3. **`terraform apply`** from `clusters/homelab-metal` with all three
   `TF_VAR_`s exported. This lands the `ExtensionServiceConfig` and the certSAN.
   It does **not** install the extension — see step 4 — so at this point the
   config names a service that does not exist and nothing starts. That is
   expected and quiet.

4. **`talosctl upgrade`** — the step that actually installs the extension:

   ```bash
   talosctl --nodes 192.168.0.221 \
     upgrade --image factory.talos.dev/installer/708747e350d604ae9e57227d8dcf274091453ddb1097b765d4ea8884f1992c1f:v1.13.8
   ```

   A reboot, not a reinstall. It carries kernel arguments — which is what drops
   the `talos.config=` leftover. **Single control plane: this is a full API
   outage for its duration.**

5. **Point the client at the name, not the address:**

   ```bash
   talosctl config endpoint homelab-worker-0.tailf4742d.ts.net
   talosctl config node     homelab-worker-0.tailf4742d.ts.net
   ```

   `terraform output talos_endpoints` prints exactly these.

6. **Mint a scoped client config per device**, rather than copying the admin one:

   ```bash
   talosctl config new ~/laptop-talosconfig --roles os:reader --crt-ttl 720h
   ```

   Reachability is device-independent (the grant is `autogroup:member`);
   credentials are not. Talos has **no CRL**, so revoking a device's access means
   waiting out the TTL or rotating the cluster PKI — which is the entire argument
   for a short one.

## 6. Traps, all measured on this machine

- **The port list is the security boundary, and now it is the *only* boundary.**
  Verified 2026-09-03: `192.168.0.221:9100` is **open and unauthenticated** —
  node-exporter runs `hostNetwork` in a privileged namespace. With a subnet
  route there were two things to withhold; a tailnet device has only the port
  list. Granting `["*"]` instead of `tcp:50000` publishes the host's full metric
  set to every tailnet device. The `tests` block denies `:9100`, `:10256`,
  `:6443`, `:2379`, `:10250` and `:22` so a widening cannot pass silently.

- **`talos.config=` is dormant, not inert.** It is consulted only when STATE
  holds no config — which is precisely what `talosctl reset` produces. Wiping
  STATE *activates* it, and when the fetch fails the node does **not** fall back
  to maintenance mode; it sits with no API at all. The new schematic is finally
  rid of it, and only because `talosctl upgrade` rewrites kernel arguments.

- **`machine.files` are written at boot, not on apply.** Adding one to a running
  node leaves the path absent until a reboot. This took the apiserver down for
  several minutes during the OIDC change, because it was already pointed at a
  file that did not exist yet. Single control plane: that window is a full API
  outage, so sequence it deliberately.

- **A schematic change is not a `terraform apply`.** `apply-config` never
  re-runs the installer. Terraform reports success, `talosctl get machineconfig`
  shows the new image, and the node keeps the old one — silently. Step 4 is not
  optional.

## 7. Done when

`talosctl --nodes homelab-worker-0.tailf4742d.ts.net version` works from a
device that is **not** on the LAN, and `:9100` on that node stays unreachable
from the tailnet.

## 8. Deliberately not done

- **Break-glass `kubectl` straight at the node.** With the node on the tailnet,
  `kubectl --server=https://homelab-worker-0.tailf4742d.ts.net:6443` would be an
  apiserver path that does not depend on an in-cluster proxy — which is
  [§6.1](fleet-provisioning-design-notes.md)'s actual complaint. It needs exactly
  two things: `cluster.apiServer.certSANs` naming the tailnet name (nothing sets
  it today, and [§6.5](fleet-provisioning-design-notes.md) notes the comment in
  `variables.tf` claiming otherwise is wrong), and `tcp:6443` added to the grant.
  Left out because it widens the port list this change exists to keep narrow, and
  that is a decision worth taking on its own.

- **Retiring `talos-cp-01`.** The named host, the `10.10.0.0/24` autoApprover,
  its grant and its two tests are marked superseded in `policy.hujson` but not
  deleted — machine 1 still exists. Delete them in the change that wipes it.

- **The VM cluster.** `terraform/modules/talos-cluster/` and
  `stage-talos-image.sh` still say Tailscale stays on the host.
  [§6.4](fleet-provisioning-design-notes.md) argues that once this is taken for
  metal it should be taken for the VM too, or the fleet has two remote-access
  stories. Machine 1 is about to be wiped and rejoined as a metal worker, so the
  VM module is on its way out regardless; doing this to it would be work on a
  path being removed.
