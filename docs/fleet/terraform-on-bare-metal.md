# Terraform on bare metal — the handoff at maintenance mode

**Status: recommendation, 2026-09-02. Nothing built.** Answers: *under D20, how
does Terraform take over once a machine is sitting in Talos maintenance mode —
and what closes the gaps that libvirt used to close for free?*

**The design was never in doubt.** `target-architecture.md` §9.1,
`provisioning-automation-without-netboot.md` §1, `fleet-provisioning-design-notes.md`
and `metal3-investigation.md` all already say the same thing: the machine reaches
maintenance mode by whatever means, and Terraform applies the config to it. This
note is about the **four things that sentence assumes and nothing states**, three
of which were silently provided by libvirt.

It also records a **blocker found while writing it** (§0), which is not a gap in
the design so much as a gap in the hardware.

---

## 0. Machine 1 is on Wi-Fi, and Talos has no Wi-Fi

Measured over SSH 2026-09-02, and it invalidates a row in
`hardware-fit-notes.md` §1:

```
enp2s0   54:bf:64:10:ee:0d   NO-CARRIER, state DOWN     <- Ethernet, unplugged
wlp3s0   90:32:4b:67:b4:c7   UP, 192.168.0.52/24        <- where the platform lives
default via 192.168.0.1 dev wlp3s0
```

**Every address this repo records for machine 1 is a Wi-Fi lease.** The platform,
the Tailscale subnet router, the SSH path in AGENT.md's fallback tunnel — all of
it runs over `wlp3s0`.

**Talos omits all 802.11 support from its kernel.** This is deliberate and not a
missing extension: `siderolabs/talos#11185` is the open feature request to add
wireless as an extension, i.e. it does not exist. The QCA9377 in this machine is
not a driver problem to solve, it is a device Talos cannot see.

So **machine 1 must be cabled to Ethernet before D20 can begin**, and three
things follow:

- **Its address changes.** `192.168.0.52` belongs to `wlp3s0`'s MAC. On `enp2s0`
  the machine is a new DHCP client with a different MAC and a different lease.
  Every `192.168.0.52` in this repo is wrong for the post-D20 machine.
- **The link is 100 Mbit, not gigabit.** The NIC is a *Realtek RTL810xE PCI
  Express **Fast** Ethernet controller* — `hardware-fit-notes.md` §1 records
  "Gigabit Ethernet" for this machine and that is wrong. Longhorn replicates over
  this link, and its own best-practices doc puts latency ahead of IOPS for volume
  stability. A 100 Mbit link between replicas is a real constraint on the ADR's
  storage decision, not a footnote.
- **Bridging and the L2 VIP were never going to work over Wi-Fi anyway.**
  `multi-node-ha-design-notes.md` §3 establishes that Talos's VIP forces bridged
  L2. A wireless link cannot bridge in the required direction, so the plan
  depended on the cable without saying so.

The cheapest fix is a cable. If the machine cannot be cabled where it lives, a
USB gigabit adapter is the next option and it must be one Talos has a driver for
— which is a schematic decision, made before the install, not after.

> **This does not block the rest of this note**, and — since
> `machine-2-first-build-plan.md` — it no longer blocks starting D20 either.
> Building the new cluster on machine 2 first puts the cable on machine 1's
> *join*, not on the critical path. Everything below is addressing agnostic.

## 1. What Terraform owns, precisely

The libvirt half of `terraform/modules/talos-cluster/` (`domain.tf`,
`volumes.tf`, `scripts/stage-talos-image.sh`) was the hardware simulator. Bare
metal deletes the simulator and keeps the compiler:

| | Owner |
| --- | --- |
| Power, boot media, getting to maintenance mode | out of band — USB/kexec today, Smee later |
| **Machine config: render, patch, apply** | **Terraform** |
| **Cluster bootstrap (once, one node, ever)** | **Terraform** |
| **The Cilium seed that makes nodes Ready** (§5) | **Terraform** |
| Everything after that | Flux |

The ephemeral + write-only design in `talos.tf` — which keeps the Talos PKI out
of state — has no libvirt content and carries over untouched. **Do not reopen
it.** It is the reason D12's single root key survives the move.

Three things get *better* on metal, worth stating because the move is usually
described as a loss:

- `UserVolumeConfig`'s `disk.serial` selectors start matching real hardware
  serials instead of serials Terraform itself invented for virtio volumes.
- With libvirt gone Terraform needs no local socket, so it **can** run from the
  Mac. AGENT.md's claim that it cannot becomes false on cutover.
- `talos_machine_configuration_apply` takes an `on_destroy` block
  (`reset`/`graceful`/`reboot`). Setting `reset = true` makes `terraform destroy`
  return the machine to maintenance mode — which restores the rehearsal property
  the VM had and that bare metal otherwise loses. Note its caveat: a change to
  `on_destroy` must be applied *before* the destroy that relies on it.

## 2. Gap one — the address, and why the answer is not DHCP

`variables.tf`'s `node_mac` description states the mechanism this rests on
today: the libvirt DHCP reservation *"is what answers for the node in maintenance
mode before any machine config exists."* That reservation is a libvirt object
created by Ansible. **On the LAN nothing replaces it**, and Terraform cannot
apply a config to an address it has to guess.

**Recommendation: skip DHCP for the maintenance window entirely.** Talos accepts
the standard `ip=` kernel parameter, and the reference describes exactly this
use: *"useful in the environments where DHCP doesn't provide IP addresses or when
default DNS and NTP servers should be overridden **before loading machine
configuration**."*

```
ip=<client-ip>:<server-ip>:<gw-ip>:<netmask>:<hostname>:<device>:<autoconf>:<dns0-ip>:<dns1-ip>:<ntp0-ip>
```

For machine 1, once cabled, one argument on the kexec command line:

```
ip=192.168.0.52::192.168.0.1:24:talos-cp-01:enx54bf6410ee0d:off:1.1.1.1:9.9.9.9
```

Two details make this the robust form rather than merely a working one:

- `<netmask>` accepts a prefix count (`24`) as well as dotted-quad.
- `<device>` accepts the `enx<MAC>` form. That keys the argument to the MAC
  rather than to `eth0` surviving as a name — the same reason `talos.tf:167`
  already refuses to select interfaces by name, where the failure mode is
  *"a node that quietly stays on DHCP."*

**Why this beats a router reservation.** The address Terraform applies to is the
address the operator typed on the kernel command line one step earlier. There is
no lease, no reservation, no second system holding a copy of the value, and
nothing that can drift between installs. It also agrees with the machine config
by construction — `talos.tf` already sets the same address statically — which is
what the Talos documentation tells you to ensure when using `ip=`.

> **The `.220` → `.221` move has a cause, and it is not a mystery.**
> `machine-2-talos-install-record.md` §4 records the address changing on the wipe.
> `talosctl docs --config` on v1.13.8 shows `DHCPv4Config.clientIdentifier` with
> values `none|mac|duid`, *"Defaults to 'mac' if not set."* Ubuntu's
> systemd-networkd defaults to a DUID-based RFC 4361 identifier. The router
> therefore saw **two different clients on one MAC** and issued a second lease.
>
> The useful consequence: a MAC-keyed reservation *would* hold for Talos, so that
> option is not broken. It is simply a second place to keep the value correct,
> and `ip=` needs none.

## 3. Gap two — "maintenance mode" is two states

A node in **RAM** maintenance mode (kexec or ISO, disk untouched) that receives a
config **installs to disk and reboots**. A node in **disk** maintenance mode
(`headless-talos-install.md` §9's wiped end state) that receives the same config
**reconfigures**. Same `talos_machine_configuration_apply`, materially different
consequence, and `--insecure` plus an open `:50000` cannot tell them apart.
Machine 2 is in the second state right now, so this is not hypothetical.

**Most of this dissolves on inspection.** Maintenance mode is entered on first
install and on deliberate reset, and nowhere else. Every *recurring* config change
— a `certSAN`, an extension, a disk selector, a Kubernetes bump — is applied to a
running, configured node over authenticated apid, by the same resource, with no
maintenance mode involved. `provisioning-automation-without-netboot.md` §2 is the
argument for why that is the case that matters; this is the same point from the
other side.

Two things to do, both cheap:

1. **Add `talos.halt_if_installed=1` to the install-media command line.** Talos
   *"will pause the boot sequence and keeps printing a message until the boot
   timeout is reached if it detects that it is already installed"* — which is
   precisely the guard against booting media at a machine that is already a
   cluster member. It costs one kernel argument and is native.
2. **Adopt the rule: the installed image changes by upgrade, never by
   apply-config.** Applying a config to a disk-maintenance node does not re-run
   the installer, so a node whose installed image lacks the Longhorn extensions
   keeps the wrong image *silently*. Changing it is `machine.install.image` plus
   `talosctl upgrade`. This is the failure that would cost the ADR's one rebuild
   twice.

## 4. Gap three — nothing replaces the ordering edge

`talos.tf:386` carries `depends_on = [libvirt_domain.node]`, commented *"The
domain has to be running and in maintenance mode before config can land."* On
metal there is no resource to depend on, and no doc says what then guarantees
ordering.

The direct replacement, and it reads the same:

```hcl
resource "terraform_data" "maintenance_ready" {
  for_each = var.nodes

  provisioner "local-exec" {
    command = <<-EOT
      for i in $(seq 60); do
        nc -z -w2 ${each.value.ip} 50000 && exit 0
        sleep 5
      done
      echo "not in maintenance mode at ${each.value.ip}:50000 after 5m" >&2
      exit 1
    EOT
  }
}
```

Then `depends_on = [terraform_data.maintenance_ready]` on the apply, and an
explicit `timeouts.create` on the resource itself — the provider supports
`create`/`update`/`delete` timeouts.

**This is motivated by the repo's own history, not by taste.** `talos.tf:122`
records that a `certSANs` mistake made `talos_machine_bootstrap` **hang rather
than error**, *"because the provider keeps retrying a failure that can never
clear."* A blind wait is the shape of failure this module has already paid for
once. Six lines that fail fast with the address in the message is the fix for the
whole class.

## 5. Gap four — Cilium-only makes the cluster unable to bootstrap itself

`cilium-only-networking.md` recommends `cluster.network.cni.name: none` and
`cluster.proxy.disabled: true`, covers the machine-config change and correctly
notes KubePrism already solves Cilium's path to the API server. **It does not
cover what happens between `terraform apply` finishing and Flux existing.**

With no CNI:

- The node is **NotReady**. Nodes go Ready only once a CNI is up.
- Talos does not wait patiently. Bootstrap stalls in the high teens of its phase
  sequence and **the node reboots to retry every 10 minutes**. There is no
  leisurely window between `terraform apply` and `flux bootstrap`.
- **Flux cannot fix it.** Flux's controllers are ordinary pods needing pod
  networking, so Flux cannot install the CNI that Flux needs in order to run.
  This is circular, and it is new — with Flannel, Talos rendered the CNI itself.

**The answer is `cluster.inlineManifests`** (confirmed present in the v1.13.8
schema alongside `extraManifests`), which Talos applies during bootstrap — inside
Terraform's window. Sidero's own Cilium guide gives the constraint: put the inline
manifest on control-plane machine configs only, and keep them identical.

One property makes this clean rather than a layering mess: **Talos only creates
missing resources from inline manifests — it never updates or deletes them.**
That is AGENT.md's bootstrap-manifest gotcha, and here it works in our favour: the
inline manifest is a one-shot seed, and the Flux `HelmRelease` owns Cilium
thereafter with no contest over ownership.

**Seed the minimum.** The inline manifest needs to do one thing: make nodes Ready
so Flux can start. Let the `HelmRelease` carry the real configuration —
`kubeProxyReplacement`, policy settings, `autoDirectNodeRoutes`. A minimal seed
does not need to stay in sync with the chart; a full one would, and would rot.

Two consequences worth stating rather than absorbing:

- **Terraform's boundary moves.** "Terraform stops at an empty cluster" becomes
  "stops at a cluster with a CNI". This should be the *only* exception — still no
  `kubernetes` provider, still no `helm` provider, still nothing else from
  `infrastructure/` pulled down into Terraform.
- **It is a boundary leak, in a new direction.** In `golden-architecture.md` §5's
  terms this is **Infrastructure → Fleet**, and every leak currently in that table
  points the other way. §7's rule says a change that forces the neighbouring layer
  to change gets recorded with its direction rather than absorbed quietly, so it
  belongs in that table.

## 6. The resulting shape

Everything above collapses to one kernel command line and one Terraform graph:

```
 boot (kexec or USB), cmdline:
     ip=<addr>::<gw>:24:<hostname>:enx<mac>:off:<dns0>:<dns1>
     talos.halt_if_installed=1
     — and deliberately NO talos.config=, because Terraform is the config source

 terraform apply:
     terraform_data.maintenance_ready   poll :50000, fail fast with the address
       └─▶ talos_machine_configuration_apply   per node, for_each the node list
             └─▶ talos_machine_bootstrap       exactly one node, exactly once
                   └─▶ inlineManifests seed Cilium ──▶ nodes Ready

 flux bootstrap:
     infrastructure/ reconciles, HelmRelease adopts Cilium
```

**Dropping `talos.config=` is a simplification, not a regression.** Machine 2
needed it because it was installing itself with no cluster to belong to, and
`headless-talos-install.md` §9 then wiped the resulting identity straight back
off. Machine 1 has a real config waiting in Terraform, so kexec plain →
maintenance mode → `terraform apply` does the install *and* the join in one step.
Fewer moving parts than machine 2's route, not more.

> **Related trap, and it is machine 2's to carry.** That machine's installed
> bootloader carries `talos.config=http://192.168.0.44:8080/config.yaml` through
> to disk. The argument is consulted only when `STATE` holds no config — which is
> exactly the maintenance-mode state Terraform means to apply into. A wiped
> machine 2 will try to fetch a config from a laptop. Harmless while nothing is
> served there; a genuine race if `serve.sh` is up for some other machine's
> install. **Do not carry the argument into machine 1's installed image.**

## 7. What this changes elsewhere

| File | Change |
| --- | --- |
| `hardware-fit-notes.md` §1 | Machine 1's NIC row: not Gigabit, and not in use — see §0 |
| `cilium-only-networking.md` | Gains the bootstrap circularity of §5 |
| `headless-talos-install.md` | `ip=` and `talos.halt_if_installed` belong on its command lines; its §10.2 claim about the Mac is wrong |
| `install-media-and-reprovisioning-notes.md` | Mac is `192.168.0.44`, not `.48` |
| `multi-node-ha-design-notes.md` §7 | The endpoint/VIP address must be chosen on the **cabled** interface's subnet |
| `AGENT.md` | Terraform-cannot-run-from-the-Mac becomes false on cutover |
| `terraform/modules/talos-cluster/` | `domain.tf`, `volumes.tf`, `stage-talos-image.sh` delete; node list, preflight, `inlineManifests` arrive |

## 8. What this does not address

- **The order of the build.** This note describes the handoff for *a* machine.
  Which machine goes first, and why it should be machine 2, is
  `machine-2-first-build-plan.md`.
- **The node list itself.** `provisioning-automation-without-netboot.md` §3.1
  calls it the highest-value item and specifies its shape; this note assumes it
  and does not design it.
- **The endpoint / VIP address**, still open in `multi-node-ha-design-notes.md`
  §7. §0 constrains it — it must live on the wired subnet — but does not choose it.
- **`terraform.tfstate`'s home.** It exists only on the machine being wiped, so
  archiving it off-box is a prerequisite. The mitigating property is that state
  holds only derived material by design and the apply is idempotent, so losing it
  costs a re-apply rather than a cluster. That makes local-on-the-Mac defensible.
  What is not defensible is an S3 backend on the cluster's own SeaweedFS.
- **Machine 1's Wi-Fi dependents.** The Tailscale subnet router and the SSH
  fallback tunnel both ride `wlp3s0` today and both need re-homing regardless.

---

## Related

- `target-architecture.md` §9.1 — the nine-step join this note fills in
- `provisioning-automation-without-netboot.md` §1–§3 — steps 4/5 as "already
  built", and the node list this assumes
- `fleet-provisioning-design-notes.md` — the `metal` backend, which *"creates no
  infrastructure"*
- `cilium-only-networking.md` — the CNI decision §5 completes
- `headless-talos-install.md` — how a machine reaches maintenance mode
- `hardware-fit-notes.md` — the fleet as measured; §0 corrects its NIC row
- `golden-architecture.md` §5, §7 — where §5's leak gets recorded
- `machine-2-first-build-plan.md` — the order this handoff is executed in
