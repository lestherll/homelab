# Tinkerbell (and Tinkerbell + Cluster API) — investigation

**Status: research, not a decision. 2026-08-31.** Nothing built, nothing depends
on this. Companion to `docs/fleet/metal3-investigation.md`, and it reuses that
note's two tests, because they turned out to be the ones that decide everything:

1. **Does it work without a BMC?** Consumer mini-PCs do not have one.
2. **Can it deliver a Talos machine config?** Metal³ died on this, not on the BMC.

This one is different from the Metal³ note in an important way. Metal³ was
rejected in `docs/adr/0001-single-model-talos-fleet.md` §7 and this investigation
confirmed the rejection. Tinkerbell is **recommended** —
`fleet-control-plane-survey.md` §4 calls it the project that *"makes plane 1
optional by design"* and §7 says to reach for it when reinstalls become routine.
So this is testing a recommendation the repo already holds, which is the more
useful thing to pressure-test.

**Result: it passes both tests** — the only system surveyed here that does. But
§5 finds that passing them makes most of Tinkerbell unnecessary, §6 finds that
adding Cluster API **re-breaks test 2 for exactly the reason Metal³ broke**, and
§7 finds the survey's trigger for adopting it is not one Tinkerbell can satisfy.

> ### Scope, set by the operator after this was researched
>
> **Remote power is not wanted, and netboot is deferred — the first three
> machines will be installed from a USB flash drive.** That decision is upstream
> of everything below and it collapses the recommendation, so it is stated here
> rather than buried in §9:
>
> - Test 1 (§2) stops mattering. It asks whether Tinkerbell can work without
>   remote power. If remote power is not wanted, the question is moot, and the
>   AMT note in §2 is a *nice-to-know*, not a purchase to make.
> - **The value Tinkerbell would add (§5) is the PXE layer itself** — Smee,
>   ProxyDHCP and per-machine boot config. Deferring netboot defers all of it.
> - Auto-discovery goes with it: the Agent that self-registers `Hardware` objects
>   runs inside a netbooted install environment. **No PXE, no auto-discovery.**
>
> **So Tinkerbell has nothing to contribute to machines 1–3, and the USB install
> already documented in `headless-talos-install.md` is the right path for them.**
> The analysis below is kept because it is the answer to "when netboot arrives,
> what should serve it" — a question that becomes live at machine 4, or at the
> first rebuild. Read §5, §6 and §9 with that timing in mind.

---

## 1. What it is now

Worth restating, because Tinkerbell consolidated: the components the survey lists
as separate projects now live in one repo (`tinkerbell/tinkerbell`) behind one
Helm chart and one binary.

| Component | Role |
| --- | --- |
| **Smee** | DHCP / ProxyDHCP + iPXE + HTTP artifact serving. The boot half. |
| **Tink** (Server/Controller/Agent) | Workflow engine — `Hardware`, `Template`, `Workflow` CRDs, executed by an Agent running in the install environment. |
| **Tootles** | Metadata service (EC2-compatible). |
| **Rufio** | BMC interaction. Still optional. |
| **Secondstar** | Serial-over-SSH. |
| **HookOS / CaptainOS** | The in-memory install environments (OSIE) the Agent runs inside. |

Its own summary: *"Tinkerbell is a bare metal provisioning engine. It supports
network and ISO booting and BMC interactions as well as a metadata service and a
workflow engine for provisioning."* Features advertised on the front page include
*"DHCP with Host reservation or ProxyDHCP"*, *"Third-party DHCP server
integration"*, *"Auto-discovery of Hardware"* and *"BMC support via Redfish, IPMI,
IntelAMT, and more"*.

**Governance is the one place it is weaker than Metal³, and it is worth saying
plainly.** Tinkerbell was accepted to CNCF at **Sandbox on 2020-11-10 and is still
Sandbox** — roughly six years without promotion. Metal³ entered at Sandbox two
months earlier and reached **Incubating in August 2025**. CNCF's own metrics put
Tinkerbell's health score at 74 ("Healthy") but show contributors down ~9% and
contributing organisations down ~3% year over year. That is not a reason to
reject it; it is a reason not to describe it as the safer bet. On the axis the
survey cared about — *does it need a BMC* — it is still the better fit. On
project trajectory, it is the worse one.

## 2. Test 1 — the BMC: passes

Three independent mechanisms, each verified in the repo rather than the marketing
page.

**Boot control is opt-in.** A `Workflow`'s `spec.bootOptions.bootMode` is
`omitempty` with an `IsZero()` check (`api/v1alpha1/tinkerbell/workflow.go`), and
the three modes that exist — `netboot`, `isoboot`, `customboot` — *all* work by
having the Tink Controller create a `job.bmc.tinkerbell.org` (power off → set
one-time boot device → power on). Omit `bootOptions` and **no BMC job is
created**. Tinkerbell then does nothing to power the machine; you press the button
or switch the plug, the machine PXE-boots because its BIOS says to, and Smee
answers. That is the BMC-less path, and it is a supported configuration rather
than a hack.

**DHCP coexists with the household router.** This is the requirement that made
Metal³ expensive — Ironic wants a dedicated provisioning network and *"the most
important factor is that this network does not have a second DHCP server
attached."* Tinkerbell has four DHCP modes, two of which exist precisely for this:

> "**Proxy DHCP** … In this mode Tinkerbell does NOT provide IP addresses to
> clients, it only provides next boot information. A DHCP server on the network
> must be configured to provide IP addresses to clients."

> "**Auto Proxy DHCP** … provide next boot information to clients **without
> requiring a pre-existing Hardware object**."

> "When a DHCP server exists on the network, Tinkerbell should be set to run
> `proxy` or `auto-proxy` mode."

`target-architecture.md` §4 is one bridged LAN with the household's DHCP on it.
Proxy mode is designed for exactly that. **No VLAN, no second NIC, no provisioning
network.** This is the single biggest practical difference between the two
projects for this fleet.

**Inventory does not require a BMC either.** Auto-discovery creates `Hardware`
objects from machines that announce themselves: *"The Agent sends its attributes
(serial numbers, MAC addresses, etc.) to the Tink server… If no Hardware object
exists, Tink server creates a new Hardware object."* The inventory doc documents
both an out-of-band (BMC) and an in-band collection path — `pciDevices`, for
instance, is in-band only. So the `HardwareData`-shaped inventory gap named in
`metal3-investigation.md` §9 is fillable here without a BMC.

**One actionable hardware note.** Rufio's provider list
(`api/v1alpha2/tinkerbell/bmc/provider.go`) is `ipmitool`, `asrockrack`, `gofish`
(Redfish), **`IntelAMT`**, `dell`, `supermicro`, `openbmc`. Metal³ removed its AMT
support years ago; Tinkerbell kept it. **If the mini-PCs are Intel vPro machines,
they already have out-of-band power and boot control and none of the smart-plug
discussion applies to them.** That is worth ten minutes with a spec sheet before
buying anything — it is the cheapest possible outcome of this whole line of
research, and neither the ADR nor the survey considered it.

> **Checked, and the answer is no** — `docs/fleet/hardware-fit-notes.md` §2. The
> ThinkCentre M710e is an **Intel B250** board, and in the 200-series only Q270
> carries vPro; the Dell is a consumer Inspiron. Neither machine has AMT and
> neither can gain it. The branch stays open only for a future machine bought
> with a Q-series chipset.

## 3. Test 2 — Talos config delivery: passes, decisively

This is the test Metal³ failed. Metal³ has exactly one config channel — a
cloud-init/Ignition config drive — and Talos reads neither.

Tinkerbell's `Hardware` CRD carries the netboot configuration directly
(`api/v1alpha1/tinkerbell/hardware.go`):

```go
type OSIE struct {
    BaseURL string
    Kernel  string
    Initrd  string
    // KernelParams, when defined, overrides the default kernel parameters passed
    // to the kernel command line when launching the OSIE. Typically they will be
    // in the format "key=value" … but they can be any string.
    KernelParams []string
}

type IPXE struct {
    URL      string
    Contents string   // an arbitrary iPXE script, inline
    Binary   string
}
```

**`KernelParams` is an arbitrary string list on the kernel command line, and
`IPXE.Contents` is a whole iPXE script.** Talos's supported config source on the
metal platform is `talos.config=<URL>` — a kernel argument. The two meet exactly.
A `Hardware` object pointing `osie.kernel`/`osie.initrd` at a Talos netboot
kernel with `kernelParams: ["talos.config=http://…/${mac}.yaml", …]` boots a Talos
machine that configures itself.

No workaround, no upstream change, no fork. **The mechanism Metal³ is missing is a
first-class field here.**

## 4. Cold start: better than Metal³'s answer

`metal3-investigation.md` §7 struck the ADR's "bootstrap circularity" objection
because Metal³ can pivot with `clusterctl move`. Tinkerbell's answer is simpler
and does not involve CAPI at all:

> "Tinkerbell can be built with a few embedded services. This is useful when **a
> single binary with no external dependencies** is desired: Kubernetes API server
> … Kubernetes controller manager … ETCD."

`make build GO_TAGS=embedded` produces one binary that carries its own apiserver
and etcd. So Tinkerbell can run on the Mac control node to build the fleet from
nothing, and in-cluster afterwards, with the same CRDs either way. That directly
serves `target-architecture.md`'s invariant 7 (*"a cold start requires no external
service on the machine → OS → cluster path"*) — the cold-start tool is a binary on
a laptop, not a service that must already be up.

It also names the trap: **run Tinkerbell only in-cluster and you have built a
circularity** — the machines cannot netboot until the cluster they form is
running. The embedded binary is the documented escape, and it should be part of
the §9 cold-start procedure rather than an afterthought.

## 5. The surprise: passing test 2 makes most of Tinkerbell unnecessary

Follow §3 through and notice what is no longer in the path.

Tinkerbell's normal flow is: netboot the machine into **HookOS**, where the
**Tink Agent** runs a **Workflow** of container actions that stream an OS image to
disk and write config files into it. That whole apparatus exists because
conventional distributions cannot install themselves.

**Talos can.** Its netboot kernel + initramfs come up, fetch `talos.config`, and
install to disk unaided. So for this fleet, HookOS is not needed (`optional.hookos.enabled:
false`), CaptainOS is not needed (and wants a `ImageVolume` feature gate that is
only on by default in Kubernetes 1.35+), the Tink Agent is not needed, and
`Template`/`Workflow` have nothing to do. Tootles is not needed, because Talos
does not read EC2 metadata.

What remains is **Smee plus the `Hardware` CRD**: an iPXE/ProxyDHCP server whose
per-machine boot configuration is declarative Kubernetes objects, reconciled by
Flux out of this repo.

That is a fair description of value, and it should be stated at that size rather
than inflated. Against `target-architecture.md` §2's current plan — *"netboot from
a Talos Image Factory schematic over iPXE, with DHCP `next-server`"* — Tinkerbell
buys three things:

- per-machine boot config as git-managed CRDs instead of a hand-maintained DHCP/iPXE
  config, which is the same argument that put everything else here in Flux;
- auto-discovery, so a new machine appears in the API as an object rather than as
  a MAC address someone has to notice (§9.1's manual steps, and §10's
  "verify before committing" capacity numbers);
- ProxyDHCP, so none of that fights the household router.

It does not buy remote power, and it does not buy the OS install, because Talos
does that itself.

## 6. Tinkerbell + Cluster API — this is where it breaks

The most interesting finding, and it inverts the intuition that adding CAPI makes
this *more* capable.

`cluster-api-provider-tinkerbell` (CAPT) is real and actively maintained — last
commit 2026-07-30, used by AWS's EKS Anywhere for bare metal. But:

> "**CAPT expects the provisioned OS to use [cloud-init](https://cloud-init.io/)
> with an EC2-compatible metadata datasource.** The provisioning template must
> write two configuration files so that cloud-init discovers the Tinkerbell
> metadata service … Without them, cloud-init will not contact the Tinkerbell
> metadata service and bootstrap data (kubeadm join tokens, etc.) will not be
> applied to the machine."

The controller agrees (`controller/machine/tinkerbellmachine.go`):

```go
// We need a bootstrap cloud config secret to bootstrap the node so we can't proceed without it.
// Typically, this is something akin to cloud-init user-data.
bootstrapCloudConfig, err := scope.getReadyBootstrapCloudConfig(machine)
```

Its published images are Ubuntu 18.04 and 20.04. **A search of the CAPT repository
returns zero occurrences of "Talos".**

So the CAPI layer is *where the cloud-init assumption lives*. Bare Tinkerbell is
OS-agnostic — it hands a machine a kernel command line and gets out of the way.
CAPT is not: it assumes cloud-init reading kubeadm join data from Tootles, which
is precisely the model that made Metal³ unusable here.

Sidero's bootstrap and control-plane providers for Talos (CABPT/CACPPT) exist and
would generate the right machine configs, but CAPT is not wired to consume them —
it wants a "bootstrap cloud config" and writes it as cloud-init files inside an
image it streamed to disk. Pairing them is not configuration; it is
writing an integration. This is the same conclusion the Metal³ note reached from
the other direction, and the same one Sidero Labs' own discontinuation of Sidero
Metal points at.

**And the second objection is one D20 already made.** Cluster API manages *fleets
of clusters*. `target-architecture.md` is one prod cluster plus one nested non-prod
cluster, and §7 gives Terraform's `siderolabs/talos` provider the job of machine
configs and bootstrap. CAPI would replace a provider block that works with a
management-cluster-plus-four-controllers apparatus, to manage one cluster, while
losing Talos support in the process. **Tinkerbell + CAPI is the one combination in
this whole investigation that is worse than either half.**

Adopt Tinkerbell, if at all, as Smee + `Hardware` — not as a CAPI infrastructure
provider.

## 7. Correcting the survey's trigger

`fleet-control-plane-survey.md` §7 says:

> "Netboot: start with the schematic and iPXE. Reach for Tinkerbell only when
> *'reinstall a machine I can't reach'* becomes recurring."

**Tinkerbell without a BMC cannot reinstall a machine you can't reach either.** It
can change what that machine boots *the next time it boots*, which is genuinely
useful, but something still has to power-cycle it. With no BMC that something is a
human or a smart plug — and Rufio speaks Redfish/IPMI/AMT, not smart plugs, so the
plug stays outside Tinkerbell's control loop exactly as it does today.

The trigger should therefore be split, because it is really two capabilities:

- **"I want per-machine boot config in git, and machines to enrol themselves."**
  Tinkerbell delivers this now, with no BMC. This is the real reason to adopt it.
- **"I want to power-cycle and reinstall without walking over."** Needs
  out-of-band hardware first: AMT if the machines have vPro (free, check §2), a
  smart plug otherwise (outside Tinkerbell), or a real BMC (a hardware refresh,
  which is also the Metal³ trigger).

## 8. Costs and frictions, for the record

- **Smee needs L2 adjacency to the machines** — DHCP, proxy mode included. In
  Kubernetes that means `hostNetwork` or a LoadBalancer IP on the LAN. This repo
  has **no bare-metal load balancer**; the chart's default `lbClass` is
  `kube-vip.io/kube-vip-class`, and D20 uses the Talos VIP for the apiserver only.
  So adopting Tinkerbell means either `hostNetwork` on the Smee pod or introducing
  an L2 LB. Not hard, but it is a new component, and the note about the Talos VIP
  and bridged networking in `multi-node-ha-design-notes.md` is the context.
- **HookOS is enabled by default** in the chart and downloads both architectures
  and both kernel versions to a PVC. For the §5 shape it should be off.
- **PodSecurity.** `hostNetwork` needs `pod-security.kubernetes.io/enforce:
  privileged` on its namespace, per AGENT.md's standing note about Talos enforcing
  `baseline`. Whichever namespace Tinkerbell lands in joins `storage` and
  `observability` on that list.
- **Sandbox governance**, per §1.

## 9. Verdict

**Not now, and not for machines 1–3.** With netboot deferred and remote power
unwanted, every capability Tinkerbell would add is deferred with them (see the
scope box above). Install the first three machines from USB per
`headless-talos-install.md`, and apply their configs the way D20 §9.1 already
describes. Nothing in this note is a reason to change that.

**When netboot does arrive, Tinkerbell is the right project to serve it, and the
survey was right to name it.** The corrections are to what it is for and in what
shape:

- **Adopt it as Smee + `Hardware` CRDs**, replacing the hand-maintained iPXE/DHCP
  half of `target-architecture.md` §2. Not as a workflow engine — Talos installs
  itself — and not as a CAPI provider.
- **Do not pair it with Cluster API.** CAPT hard-requires cloud-init and has no
  Talos support; it reintroduces the exact blocker that disqualified Metal³, to
  manage a single cluster that Terraform already manages.
- **Check whether the mini-PCs have Intel vPro/AMT before buying smart plugs.**
  Rufio supports AMT natively. If they do, remote power and boot control are free
  and already integrated.
- **Keep the embedded single-binary mode in the cold-start procedure** (§9 of
  `target-architecture.md`), so provisioning never depends on the cluster being up.

The ordering this implies is USB now, plain iPXE when netboot is wanted, and
Tinkerbell when a hand-maintained iPXE config becomes the thing going wrong —
because §5's honest accounting is that Tinkerbell's win is declarative inventory
and boot config, not a new capability. Nothing is lost by arriving at it late:
`Hardware` objects describe machines that already exist, so a fleet installed from
USB can be adopted into Tinkerbell later without reinstalling anything.

---

## Sources

Primary (repositories cloned and read directly; `tinkerbell.org` is unreachable
from this environment):

- [tinkerbell/tinkerbell](https://github.com/tinkerbell/tinkerbell) — `README.md`;
  `docs/technical/` (`DHCP_BOOT_MODES.md`, `BOOT_MODES.md`, `AUTO_DISCOVERY.md`,
  `AUTO_ENROLLMENT.md`, `HARDWARE_INVENTORY.md`, `EMBEDDED.md`, `CAPTAINOS.md`);
  `api/v1alpha1/tinkerbell/hardware.go`, `api/v1alpha1/tinkerbell/workflow.go`,
  `api/v1alpha2/tinkerbell/bmc/provider.go`; `helm/tinkerbell/values.yaml`
- [tinkerbell/cluster-api-provider-tinkerbell](https://github.com/tinkerbell/cluster-api-provider-tinkerbell) —
  `README.md`, `docs/QUICK-START.md`, `controller/machine/tinkerbellmachine.go`,
  `controller/machine/template.go`, `templates/cluster-template.yaml`
- [siderolabs/talos](https://github.com/siderolabs/talos) — metal platform config
  sources (see `metal3-investigation.md` for the specific files)

Secondary:

- [Tinkerbell | CNCF](https://www.cncf.io/projects/tinkerbell/) — Sandbox since
  2020-11-10; health and contributor metrics
- [Metal3.io becomes a CNCF incubating project](https://www.cncf.io/blog/2025/08/27/metal3-io-becomes-a-cncf-incubating-project/) — for the maturity comparison
- [EKS Anywhere — Tinkerbell concepts](https://anywhere.eks.amazonaws.com/docs/getting-started/baremetal/tinkerbell-overview/) — CAPT's production user
