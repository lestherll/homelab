# Metal³ — investigation

**Status: research, not a decision. 2026-08-31.** Nothing built, nothing depends
on this. Written to re-open the question `docs/adr/0001-single-model-talos-fleet.md`
§7 closed in one paragraph, after a lot of effort had gone into building machine
provisioning by hand (`docs/fleet/headless-ubuntu.md`,
`docs/fleet/headless-talos-install.md`). The fair question behind it: **is that
hand-built path work that an existing project would simply do for us?**

**Answer: not this project, and not for a reason that effort or cleverness
fixes.** Metal³ is gated on hardware this fleet does not have, and its OS
delivery model is one Talos does not implement. Both are stated in primary
sources and confirmed in code below. §7 also corrects the ADR in Metal³'s
favour on a point the ADR got wrong, and §9 names the two pieces that *are*
worth stealing.

---

## 1. What Metal³ is

> "The Metal³ project (pronounced: 'Metal Kubed') provides components for bare
> metal host management with Kubernetes. You can enrol your bare metal machines,
> provision operating system images, and then, if you like, deploy Kubernetes
> clusters to them."

Four components, and the docs are explicit that **"There is no requirement to use
all of them"** — which matters for §9.

| Component | What it is |
| --- | --- |
| **Ironic** | OpenStack's bare-metal service, run standalone. Talks IPMI/Redfish to a BMC; writes OS images to disk via a ramdisk (IPA). The engine. |
| **BMO** (Bare Metal Operator) | The Kubernetes controller exposing Ironic as the `BareMetalHost` CRD. The API. |
| **CAPM3** | Cluster API infrastructure provider. Turns CAPI `Machine`s into `BareMetalHost`s. |
| **IPAM** | IP address manager for the hosts it provisions. |

Maturity is genuinely good, and better than the ADR assumed: **CNCF Sandbox
2020-09-08, Incubating 2025-08-14**, 57 contributing organisations led by Ericsson
and Red Hat, adopters including Fujitsu, IKEA and SUSE. CAPM3 tracks CAPI's
release cycle and supports the two most recent minor releases (v1.13/v1.12 at
time of writing). This is not a project that will evaporate.

Note *who* those adopters are. Every one of them is a shop that buys
enterprise servers by the rack, and it shows in the requirements.

## 2. The requirement that decides it

Metal³'s own requirements list, first bullet:

> "Server(s) with **baseboard management capabilities** (i.e. Redfish, iDRAC,
> IPMI, etc.). For development you can use virtual machines with Sushy-tools."

Supported hardware, first sentence:

> "Metal3 supports many vendors and models of **enterprise-grade hardware with a
> *BMC*** ([Baseboard Management Controller][bmc]) that supports one of the remote
> management protocols described in this document."

And the design doc explaining the mechanism:

> "Ironic is largely designed around the ability to issue commands to a remote
> Baseboard Management Controller (BMC) in order to control the desired next boot
> device and the system power state."

**The fleet in `target-architecture.md` is three consumer mini-PCs. They have no
BMC.** The ADR already knew this; what follows is the part it did not verify.

## 3. It is not a soft requirement — checked in code

The interesting question is whether the BMC requirement is documentation or
enforcement. It is enforcement, at the BMO layer, before Ironic is ever reached.

A `BareMetalHost` created with no `bmc` block is legal, and goes nowhere:

> "Hosts created without BMC details will be left in the `unmanaged` state until
> the details are provided." … "**Unmanaged hosts cannot be provisioned and
> their power state is undefined.**"

> "An `unmanaged` host is missing both the BMC address and credentials secret
> name, and does not have any information to access the BMC for registration."

The design proposal that introduced the state says plainly what it is for — a
placeholder for credentials arriving *later*, not a mode of operation:

> "**As a precursor to being able to provision hosts without their BMC
> credentials**, we want to be able to define hosts without BMC credentials so
> that the credentials can be added at a later time."

And the set of BMC address schemes BMO will accept is a closed list, registered
in `pkg/hardwareutils/bmc/`:

```
ipmi          libvirt(→ipmi)   redfish        idrac-redfish   ilo5-redfish
redfish-virtualmedia   idrac-virtualmedia   ilo5-virtualmedia   redfish-uefihttp
```

There is no `manual`, no `fake`, no `agent`, no `none`. **Every reachable driver
speaks IPMI or Redfish to something.**

## 4. Correcting the survey

`fleet-control-plane-survey.md` §4 says:

> "Ironic has a `manual-management` hardware type using the agent power
> interface… But the support is *experimental and only works in a limited
> scenario*."

That is true of **Ironic** and false of **Metal³**. `manual-management` is an
Ironic hardware type; BMO never exposes it, because the only way BMO addresses a
node is through one of the nine schemes above. You cannot reach it through a
`BareMetalHost` at all.

So the survey's conclusion — *"it is not that Metal3 cannot run without a BMC,
it is that Metal3-without-a-BMC gives up remote power and recovery"* — is
generous. The sharper statement: **Metal³ without a BMC does not run.** The
verdict is unchanged; the reason is harder than the one on file, and should be,
because "experimental, use with care" invites a weekend of trying and this does
not.

## 5. The escape hatches, and why each one closes

Four features look like they might route around the BMC. Checked individually:

| Feature | What it does | Why it does not help |
| --- | --- | --- |
| `unmanaged` state | Host known, no BMC | Cannot leave `unmanaged`; never reaches `available`, so nothing can provision it |
| `externallyProvisioned: true` | Adopt a host installed by someone else | Still takes a `bmc.address` in every documented example; permits only power on/off, reboot, live updates — all of which need the BMC. And **"changing the `externallyProvisioned` field back to `false` is currently not supported"** |
| `detached` annotation | Stop managing a host | Removes it *from* Ironic. It is the exit, not an entry |
| `live-iso` | Boot an ISO instead of writing a disk | **"this feature is designed to work with virtual media"** — i.e. it needs a *better* BMC than IPMI, not none |

The pattern is consistent: every hatch assumes the BMC exists and you are
choosing not to use one of its functions.

## 6. The second blocker: Talos does not speak Metal³'s OS delivery

This one is independent of the BMC and would still bite on hardware that had one.
It is also, as far as I can find, undocumented anywhere — searching for a
Talos + Metal³ integration returns nothing on either project.

Metal³ delivers per-machine configuration exactly one way:

> "It is recommended to use UserData or NetworkData together with a first-boot
> configuration software such as **cloud-init, Glean or Ignition**."

> "User and network data are passed to the instance via a so called **config
> drive**, which is a small additional disk partition created on the root device
> during provisioning."

Talos runs none of those three. Its `metal` platform reads a machine config from
exactly two places, and this is the whole list
(`internal/app/machined/pkg/runtime/v1alpha1/platform/metal/metal.go`):

1. `talos.config=<URL>` — a kernel argument, fetched over the network.
2. `talos.config=metal-iso` — a volume labelled **`metal-iso`** containing
   **`config.yaml`** (`constants.MetalConfigISOLabel`, `constants.ConfigFilename`).

An Ironic config drive is neither. And there is **no user-settable kernel-argument
field on `BareMetalHost`** to supply route 1 — the only `ExtraKernelParams` in the
BMO API is on `PreprovisioningImageStatus`, describing the IPA deploy ramdisk, set
by a controller, not by the user, and not applied to the installed OS.

So on a hypothetical BMC-equipped fleet, Metal³ could write a Talos image to disk
and would then have **no way to configure it**. The machine boots into maintenance
mode and waits — which is precisely where `headless-talos-install.md` already
gets to, for free.

> **Worth flagging upstream-shaped, not verified:** the gap is one label and one
> filename wide. If Ironic could be told to build the config drive with volume
> label `metal-iso` and `config.yaml` at its root, Talos would read it as-is. That
> is a small change in an unfamiliar codebase to serve one distribution, so treat
> it as an observation about *why* the gap exists, not a plan.

There is a related signal here. **Sidero Metal — Sidero Labs' own CAPI bare-metal
provider, the Talos-native equivalent of Metal³ — is discontinued:** *"Sidero Labs
is no longer actively developing Sidero Metal… For an alternative, please see Omni
and the Bare-Metal Infrastructure Provider."* The vendor's replacement, the Omni
bare-metal infra provider, PXE-boots machines and then drives power **over IPMI**,
having used an on-machine agent to configure the IPMI credentials. Even the
Talos-native answer to this problem assumes a BMC.

## 7. Where the ADR was wrong in Metal³'s favour

§7 gives a second reason for rejection:

> "It also needs a management cluster to run in, which is a bootstrap
> circularity."

**That objection does not survive contact with the docs.** Metal³ implements CAPI's
`clusterctl move`:

> "CAPI Pivoting feature is a process of moving the provider components and
> declared Cluster API resources from a source management cluster to a target
> management cluster."

You bootstrap on a throwaway `kind` cluster — *"A kind cluster is enough for
bootstrapping"* — and pivot the controllers onto the fleet they manage. They even
solved the hard part, which is that the Ironic endpoint has to survive the move:
a keepalived container holds the provisioning IP so *"once moving is done and the
management cluster is taken down, target cluster controlplane can re-claim the
Ironic endpoint IP."*

This is exactly the two-stage trust chain `fleet-control-plane-survey.md` §3 found
in Oxide, and exactly the trade this repo already accepts one layer up with
`flux bootstrap`. **The cost is another cold-start procedure, not a pet machine.**

So of the ADR's three reasons — no BMC, bootstrap circularity, too much machinery
for three machines — the middle one should be struck. The first is now stronger
than stated, and it is sufficient on its own.

## 8. If you wanted to do it anyway: the Redfish shim

For completeness, because "buy a smart plug" is already the plan and this is the
version of that plan which reaches Metal³. Metal³ names the mechanism itself:
sushy-tools, *"a test and emulation toolkit for Redfish"*, which the requirements
list recommends for development VMs. Its dynamic emulator has libvirt, OpenStack
and Ironic backends behind a driver interface — so a **smart-plug backend is a
supported extension point**, not a fork.

The interface is 8 abstract methods (`sushy_tools/emulator/resources/systems/base.py`):

```
driver   systems   uuid   name
get_power_state   set_power_state          ← a smart plug answers these
get_boot_device   set_boot_device          ← a smart plug cannot answer these
```

Power maps cleanly onto a plug. Boot device does not, and would have to be a
polite lie: accept the write, report what was asked, change nothing. The
precondition for that lie being safe is that the machine's own BIOS boot order is
permanently *PXE first, disk second*, and that Ironic's per-MAC iPXE config is
what actually decides between "boot the deploy ramdisk" and "fall through to
local disk". Existing reference driver `fakedriver.py` is 257 lines, so the shim
itself is an afternoon.

**That last paragraph is a hypothesis, not a verified finding** — I did not test
whether Ironic's `pxe` boot interface tolerates a boot-device override that
silently no-ops. It is the first thing to check if this is ever attempted.

And it changes nothing, because §6 still applies: the shim gets you a powered,
imaged machine that Metal³ cannot configure. **You would build and operate a fake
BMC in order to arrive at maintenance mode**, which is where a plain iPXE boot
already arrives.

Two further costs, for the record. Ironic wants **"a separate provisioning
network… The most important factor is that this network does not have a second
DHCP server attached"** — the design in `target-architecture.md` §4 is one bridged
LAN with the household's DHCP on it, so this means a VLAN or a second NIC per
machine. And the runtime is `ironic` + `httpd` + `ipa-downloader` + optionally
`dnsmasq`, `keepalived` and `ironic-log-watch`, on the host network of the control
plane, against a capacity budget (§10) that is already ~16Gi of 45Gi.

## 9. What is actually worth taking

Two things, neither of which requires adopting Metal³.

1. **The `BareMetalHost` shape as a model, not a dependency.** A machine as a
   declarative Kubernetes object — inventory, desired power state, desired image,
   observed hardware — is the right shape, and it is what
   `fleet-provisioning-design-notes.md` §8's Terraform node list is reaching for
   in a weaker form. Steal the shape.
2. **Inspection as a first-class artifact.** Metal³'s `HardwareData` (CPUs, RAM,
   disks, NICs, MACs) is written by the machine about itself on enrolment. The
   hand-built path currently has no equivalent — `target-architecture.md` §9.1
   step 7 is *"tag its disks in Longhorn"*, done by hand, and §10 says of the
   capacity budget *"verify before committing"*. Both are inspection gaps.

The judgement in `fleet-control-plane-survey.md` §7 stands unchanged, and this
investigation strengthens it: **a smart plug per machine is still the cheapest
item on the list, and Tinkerbell is still the project to reach for** when
"reinstall a machine I can't reach" becomes routine — it is CRDs, its BMC
component (Rufio) is optional by design, and it does not care what the OS is.

## 10. Verdict

**Do not adopt Metal³, and do not revisit it on machine count.** The ADR's
*"revisit at ~10 machines"* is the wrong trigger — ten mini-PCs are as
un-provisionable as three. Both real blockers are properties of the *hardware and
the OS*, not the fleet size:

- **Revisit if the fleet gains machines with a real BMC** (Redfish preferably,
  with virtual media). That is a hardware-refresh trigger, matching the survey's
  recommendation for Harvester, not a headcount one.
- **And only then if Talos config delivery has been solved** — by Talos gaining a
  config-drive source, by Metal³ gaining per-host kernel arguments, or by
  accepting a two-step flow where Metal³ images the machine and something else
  (Terraform, as today) applies the config to maintenance mode.

Until both hold, the hand-built path in `docs/fleet/` is not duplicated effort.
It is the cheaper answer, and the research above is the evidence for saying so
rather than assuming it.

---

## Sources

Primary (read at source; `metal3.io` itself is unreachable from this environment,
so the docs repo was cloned and read directly):

- [metal3-io/metal3-docs](https://github.com/metal3-io/metal3-docs) — user guide
  (`introduction`, `project-overview`, `bmo/supported_hardware`,
  `bmo/state_machine`, `bmo/externally_provisioned`, `bmo/detached_annotation`,
  `bmo/live-iso`, `bmo/instance_customization`, `ironic/ironic_installation`,
  `irso/install-basics`, `capm3/pivoting`, `version_support`) and design docs
  (`baremetal-operator/how-ironic-works`, `baremetal-operator/unmanaged-state`)
- [metal3-io/baremetal-operator](https://github.com/metal3-io/baremetal-operator) —
  `pkg/hardwareutils/bmc/` registered drivers, `apis/metal3.io/v1alpha1/`
- [metal3-io/cluster-api-provider-metal3](https://github.com/metal3-io/cluster-api-provider-metal3) — `docs/architecture.md`
- [siderolabs/talos](https://github.com/siderolabs/talos) —
  `internal/app/machined/pkg/runtime/v1alpha1/platform/metal/metal.go`,
  `pkg/machinery/constants/constants.go`
- [siderolabs/sidero](https://github.com/siderolabs/sidero) — README, discontinuation notice
- [openstack/sushy-tools](https://github.com/openstack/sushy-tools) — `sushy_tools/emulator/resources/systems/`

Secondary:

- [Metal3.io becomes a CNCF incubating project](https://www.cncf.io/blog/2025/08/27/metal3-io-becomes-a-cncf-incubating-project/)
- [Metal3 at KubeCon + CloudNativeCon Europe 2026](https://www.cncf.io/blog/2026/03/23/metal3-at-kubecon-cloudnativecon-europe-2026-meet-the-cncfs-freshly-incubated-bare-metal-project/)
- [siderolabs/omni-infra-provider-bare-metal](https://github.com/siderolabs/omni-infra-provider-bare-metal)
- [Virtual Redfish BMC — sushy-tools](https://docs.openstack.org/sushy-tools/latest/user/dynamic-emulator.html)

[bmc]: https://en.wikipedia.org/wiki/Intelligent_Platform_Management_Interface#Baseboard_management_controller
