# Terraform was the last LAN-bound control plane

**Date:** 2026-09-03 · **Tags:** terraform, talos, tailscale, remote-access

**Problem:** `talosctl` and `kubectl` both became network-independent the same
day, but `terraform apply` still could not run from off the LAN — the module
addressed nodes by their static `192.168.0.221`, which has no route from
anywhere else. Merging a Terraform change and being unable to apply it is the
symptom.

**Why it was missed:** it was noticed and then filed as an aside rather than as
a defect, on the reasoning that Terraform also drives maintenance-mode
bootstrap and therefore "genuinely needs the LAN". That conflates two jobs:
**building** a node that has no identity yet, and **updating** one that is
already running. Only the first needs the LAN. The platform's whole point is
remote access, so a control plane that only works from the house is a defect,
not a footnote.

**Finding — the same endpoint/node split, in the provider's spelling:**

| | dialled by | MagicDNS name? |
|---|---|---|
| `endpoint` | the operator's machine | **yes** |
| `node` | apid, **on the node** | **no** (`machine.network.nameservers` has no `.ts.net`) |

`talos_machine_configuration_apply` and `talos_machine_bootstrap` each take
both. `client_configuration` carries only certificates — it is *not* what
decides the dial target, which is why setting `endpoints` on
`talos_client_configuration` alone would have changed nothing.

**Decision:** `endpoint` defaults to `<hostname>.<tailnet_domain>`;
`var.dial_over_lan` forces LAN addresses for the two maintenance-mode cases,
both of which are hands-on anyway:
- a first build (no extension, no auth key, maintenance mode)
- a rebuild after `terraform destroy` — `on_destroy` resets the node, which
  wipes `/var/lib/tailscale` along with STATE, so it leaves the tailnet

**The asymmetry worth recording:** `talosctl` needs no equivalent flag, because
a talosconfig takes a **list** of endpoints and the client fails over between
them. Verified 2026-09-03 from off-LAN, in both orders:

- unreachable endpoint + working endpoint → works
- **entirely unresolvable** endpoint + working endpoint → works

So `talosctl config endpoint <tailnet-name> <lan-ip>` covers every state — LAN,
remote, and mid-build — with no decision to make. The provider's `endpoint` is
a single string, so there the choice has to be explicit. Two tools, same
concept, different ergonomics; worth knowing before assuming the Terraform side
should "just work" the way the CLI does.

**Validation:** `terraform plan` from off-LAN — `endpoint "192.168.0.221" ->
"homelab-worker-0.tailf4742d.ts.net"` on both resources, in-place, no
replacement. `terraform validate` clean.

**Follow-up:** LES-177 loses its "Terraform's reach is LAN-bound" scope; what
remains there is how a node gets its LAN address at all, which is the
headless-recovery question and unaffected by this.

**Ref:** LES-177; `terraform/README.md` — "Applying from off the LAN"
