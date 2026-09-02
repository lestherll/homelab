# Multi-node / HA design notes

**Status:** design only. Nothing here is built. Written 2026-08-29, when a
second machine (`homelab-worker-0`, Ubuntu 26.04.1, one 476.9 G SSD) joined the
LAN with no role yet and the stated aim became *make adding machines easy, so
HA is available once a third machine exists*.

This note exists to answer one question before any code moves: what has to
change so that machine 3 can be added **without a second rebuild**. The
sequencing at the end is the load-bearing part.

---

## 1. The constraint that dominates everything

etcd quorum is `floor(N/2)+1`:

| etcd members | Quorum | Host failures tolerated |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | **0** |
| 3 | 2 | 1 |

Two control planes tolerate exactly as many failures as one, while doubling the
surface that can cause one. **Two control-plane nodes is a strictly worse
configuration than the single node running today** — not a step toward HA but a
step away from it.

Nor can three VMs across two hosts help: two members land on one machine, and
losing that machine loses quorum. Control-plane HA needs **three physical
machines**. There is no arrangement of two that gets there.

The practical consequence, which drives §5: while only two machines exist,
machine 2 must join as a **worker**. It becomes a control-plane node only when
machine 3 arrives, and both are promoted together.

---

## 2. What blocks node addition today

### 2.1 The control plane is unreachable from anywhere but its own host

`ansible/roles/host_prereqs/templates/libvirt-network-talos.xml.j2` defines the
Talos network as `forward mode='nat'`, with the rationale stated inline:

> the VM reaches the internet through the host (it must, to pull container
> images) but is not addressable from the LAN. This is what keeps the host's
> ufw rules meaningful, which bridged networking would not.

So `10.10.0.10` lives on a host-only bridge. A Talos node on any other machine —
VM or bare metal — cannot reach it. This is the design working as intended, not
a gap.

### 2.2 Terraform models exactly one node

`terraform/modules/talos-cluster/` builds one libvirt domain with
`machine_type = "controlplane"` (`talos.tf:365`), and the libvirt network
template carries a single hardcoded DHCP reservation for `talos_cp_mac`. There
is no node list, no worker path, and `talosctl bootstrap` is unconditional.

### 2.3 Ansible cannot reach a second machine

The inventory is one host, `ansible_connection=local`, `127.0.0.1`.
`ansible.cfg` sets `become_flags = -H -n`, which works only because a sudo
ticket can be cached in the same terminal — see the sudo-rs comment block
there. Over SSH there is no terminal in which to pre-cache one; verified
2026-08-29 that `sudo -n true` on `homelab-worker-0` returns *"interactive
authentication is required"*.

**Superseded in scope by §3.1, then un-superseded:** this note assumed machines
2+ would all be bare-metal Talos, making the blocker theoretical. That premise
was reversed on 2026-08-30 — see
[fleet-provisioning-design-notes.md §1.1](fleet-provisioning-design-notes.md),
which keeps Ubuntu hypervisors first-class. **The blocker is live again**, and
so is the `tailscale` role this note's §4 says is unnecessary; both are resolved
in that note (§2.3 and §4.1 respectively) rather than here.

The observation this section got right and should keep: a `NOPASSWD` sudoers
entry for the operator on each managed machine means no prompt is ever emitted,
so the sudo-rs regex bug cannot trigger. It is a security-posture decision, not
a Tailscale- or HA-specific one.

### 2.4 Storage is node-pinned by construction

The three classes are `local-path-provisioner` over hostPath. A PV binds to the
node that created it and the pod can never move. Adding nodes does not make a
stateful workload survivable; it only adds places where its data *isn't*.

Machine 2 also has **one 476.9 G SSD and no second disk**, so the `bulk` tier
cannot exist there without new hardware or a node-restricted class.

---

## 3. Target architecture

**Bridged L2, with a Talos virtual IP as the cluster endpoint.**

The VIP choice is what forces the network choice, so it is worth stating
plainly. Talos's built-in VIP works by control-plane nodes contesting a shared
address through etcd elections and announcing it with gratuitous ARP. That
requires **all control-plane nodes in a single broadcast domain**. Two things
follow:

- **KubeSpan is not a path to HA here.** It meshes nodes at L3 over WireGuard,
  which cannot carry an L2 VIP. Using it would mean giving up the built-in VIP
  and running an external load balancer for the API endpoint — more moving
  parts, and one of them outside this repo's control.
- **Bridging is not one option among several.** It is the prerequisite for the
  HA endpoint mechanism Talos gives us for free.

So: Talos nodes get addresses on the existing LAN (`192.168.0.0/24`), and the
cluster endpoint becomes a VIP on that subnet rather than `10.10.0.10`.

### 3.1 Machines 2+ run Talos on bare metal, not nested

Decided 2026-08-29 on hardware grounds, not preference. `homelab-worker-0`
measured: **3.2 GiB RAM**, i3-7100 (2c/4t), one 476.9 G SSD, and **`/dev/kvm`
absent with zero CPUs reporting `vmx`** — VT-x is disabled in firmware. Two
independent blockers to nesting:

- Without KVM, QEMU falls back to full emulation. Unusable for a cluster node,
  and re-enabling VT-x needs a BIOS trip.
- 3.2 GiB leaves roughly 2.5 GiB for a guest after Ubuntu, below Talos's
  practical floor. Machine 1's VM is allocated 12 GiB for comparison.

**What this costs.** Talos has no SSH or shell either way — that is not the
difference. What bare metal removes is the *layer underneath*: `virsh console`
when a node won't boot, disk snapshots, and destroy/recreate via Terraform.
`talosctl dmesg | logs | services | get | support` all still work — **but not
all of them in maintenance mode.** Corrected 2026-08-30 against the v1.13.8 CLI
reference: only seven commands accept `--insecure`, and `dmesg`, `logs`,
`services` and `support` are not among them, so a node with no identity yet
cannot be asked for logs at all. See
[headless-talos-install.md §6](headless-talos-install.md). That narrows what
"covers most debugging" means precisely where it matters most — during an
install. The uncovered case is narrow and sharp: **a node that won't boot or has
no network needs a physical display.** Keep a monitor or HDMI adapter available;
it is the cheapest insurance here.

**What this buys — and the part of it that did not survive.** Bare-metal Talos
needs *no Ansible at all*, so the blockers in §2.3 were argued to be moot: they
exist only if new machines run Ubuntu, and this note assumed none would.

**That argument was overturned on 2026-08-30.** Ubuntu hypervisors were kept
first-class for reasons that are educational rather than technical
([fleet note §1.1](fleet-provisioning-design-notes.md)), so `ansible/` does
become fleet management after all, and every blocker in §2.3 has to be paid.
What remains true is narrower: *this particular machine*, `homelab-worker-0`,
runs bare-metal Talos and needs no Ansible — a per-machine fact, not a fleet-wide
simplification.

**A consequence for HA.** 3.2 GiB is fine for a worker and marginal for a
control-plane node — etcd plus apiserver wants ~4 GiB. Since HA needs three
control planes, either this machine gets more RAM (DDR4 for a ThinkCentre
M710-class box is cheap and is the highest-leverage spend in this plan) or HA
waits for two further machines rather than one.

### What bridging invalidates

Four things rest on the VM being unroutable, and all four must be revisited in
the same change rather than discovered later. Items 3 and 4 were added
2026-08-30; the original two were not wrong, they were incomplete:

1. **`terraform/modules/talos-cluster/talos.tf:200`** binds kube-proxy's metrics
   to `0.0.0.0`, justified verbatim as *"Safe on this topology — 10.10.0.10 is a
   host-only libvirt network reachable from the host and the pod network, not
   from the LAN."* Once bridged, that sentence is false. kube-proxy metrics,
   kubelet `:10250` and the apiserver become LAN-reachable.
2. **The host firewall model** in `host_prereqs` is deliberately thin because
   *"the host firewall is not what protects them"* — true only while the VM is
   unroutable. Real rules have to replace the protection NAT was providing, and
   they cannot be ufw rules: once the node is on `192.168.0.0/24` it is not
   *behind* machine 1 at all, so nothing on machine 1 is in the path. The
   replacement mechanism is Talos's own `machine.network.ingressFirewall`
   (`NetworkRuleConfig`, `defaultAction: block`), which nothing in the repo
   sets today. Naming the mechanism matters more than the rules: "real rules
   have to replace it" is the kind of item that gets deferred because it has no
   obvious home.
3. **The apiserver certificate.** `talos.tf` sets only `machine.certSANs`, which
   covers apid, trustd and the kubelet — not the apiserver. The apiserver
   certificate covers `10.10.0.10` today purely because it is the cluster
   endpoint. Once the endpoint becomes the VIP, **the individual node addresses
   stop being covered** and `kubectl` aimed straight at a node fails x509 — i.e.
   the break-glass path breaks inside the rebuild that was meant to be complete.
   `cluster.apiServer.certSANs` has to be set explicitly, with the VIP and every
   node address. Detail in
   [fleet-provisioning-design-notes.md §6.5](fleet-provisioning-design-notes.md).
4. **Remote access to the cluster is fate-shared with the cluster.** The
   `kube-apiserver-ci` `ProxyGroup` that serves `kubectl` over the tailnet runs
   *inside* the cluster, so during this rebuild there is no `kubectl` path from
   anywhere but machine 1's own shell. Plan the rebuild as an on-machine-1
   operation, and treat remote `talosctl`
   ([fleet note §6](fleet-provisioning-design-notes.md)) as the thing that makes
   the *next* rebuild survivable rather than this one.

### The rebuild constraint

Per the caveat at `talos.tf:200`, Talos **bootstrap manifests do not retrofit a
running cluster**. Network renumbering, cert SANs and the kube-proxy bind all
reach the cluster on a rebuild, not on `terraform apply`. Plan for exactly one
rebuild, and get everything into it — which is the whole reason this note exists
before any code moves.

---

## 4. What has to change, in dependency order

1. **`host_prereqs` network template** — NAT → bridge for machine 1's Talos VM,
   and the ufw rework that compensates. This is the only `ansible/` change the
   plan needs: per §3.1 nothing in `ansible/` reaches machines 2+, and no
   `tailscale` role is required. (Were a future machine to run Ubuntu, §2.3
   applies — and note a `tailscale` role would not belong in `cli_tools`, whose
   entire shape is pinned checksum-verified binaries.)
2. **`terraform/modules/talos-cluster/`** — take a node list rather than
   implying one node; per-node MAC/address; `controlplane` vs `worker` machine
   types; bootstrap exactly once; VIP in the machine config; VIP and every node
   address in the apiserver cert SANs.
3. **`talos.tf:200`** — re-justify or re-scope the kube-proxy metrics bind, and
   add `machine.network.ingressFirewall` as the replacement for what NAT was
   doing. kube-proxy metrics, kubelet `:10250`, apid `:50000` and the apiserver
   all become LAN-reachable in the same change.
4. **Storage** — decide whether stateful workloads replicate at the app layer
   (CNPG replicas, SeaweedFS replication) or whether replicated block storage
   arrives. Until then, node-pinned PVs are the honest description.

---

## 5. Sequencing

**Now, with two machines:**

- Do the bridged-network + VIP rebuild **once**, with `talos-cluster`
  parameterised for N nodes even while N=1. This is the only step that costs a
  rebuild, so everything the rebuild is needed for must land in it.
- Install Talos on machine 2 from USB and join it as a **worker**. Never as a
  second control plane (§1). No Ubuntu, no Ansible, no libvirt on that box —
  the Ubuntu install currently on it is discarded.
- Source a monitor or HDMI adapter first (§3.1). A bare-metal node that fails
  to boot has no other diagnostic path.

**When machine 3 arrives:**

- Confirm machine 2 has the RAM to be a control plane (§3.1 — 3.2 GiB is
  marginal; upgrade it, or make machine 3 and a fourth the control planes).
- Rebuild machine 2 as a control-plane node and add machine 3 as one, giving
  three etcd members in one step. Talos has no in-place worker→control-plane
  promotion; that node gets wiped and rejoined, which is cheap precisely
  because this work made node addition repeatable.
- Set `allowSchedulingOnControlPlanes` deliberately at that point. It is `true`
  today (`talos.tf:187`) as a single-node accommodation, and stays harmless but
  stops being *right* once real workers exist.

---

## 6. What this still does not give you

Worth recording so "we have HA" is never claimed further than it goes:

- **Stateful workloads do not fail over.** Node-pinned hostPath PVs mean
  Postgres, SeaweedFS and Prometheus go Pending rather than moving. Prometheus
  cannot fail over at all — one TSDB, one PVC.
- **One switch, one power feed, one ISP.** Homelab HA usually dies here first.
- **There are no backups.** Audited 2026-08-29: no CNPG `backup`/Barman stanza
  anywhere, nothing in `infrastructure/postgres/`. `fast` and `bulk` are
  `Retain`, which survives an accidental PVC delete but not the disk, the host,
  or a bad rebuild.

That last point deserves weight in the ordering. The failures a single-user
homelab actually meets are disk failure, power loss, a bad Flux change, and
rebuilds. HA addresses none of them well; backup and restore speed addresses all
of them. The Talos cutover deliberately skipped its dump phase because nothing
was worth carrying, and `talos-cutover-runbook.md` is kept as a rebuild
rehearsal — fast, confident rebuilds are already this platform's availability
story. HA is worth building because it is wanted, not because it is the highest
available return.

---

## 7. Open questions

- **Node addressing on the LAN** — DHCP reservations on the router, or static
  addresses in the machine config? Static is more self-contained; reservations
  keep one source of truth off-repo. *Note (2026-08-30): the install-media
  arrangement does not force either — the router stays the only DHCP server in
  every option considered in
  [install-media-and-reprovisioning-notes.md](install-media-and-reprovisioning-notes.md)
  §3. It does add one reservation that is not a node: if the iPXE arrangement is
  ever adopted, the operator Mac's address ends up inside the boot script and has
  to stop moving.*
- **Which VIP address**, and is it inside or outside the router's DHCP pool?
- **Does machine 1 stay a hypervisor?** Settled for machines 2+ (§3.1): they run
  Talos on bare metal. Machine 1 keeps its Ubuntu/libvirt layer because the
  storage tiering and watchdogs live there; the fleet is therefore
  deliberately two provisioning models, not one.
- **`10.10.0.10` appears in operator muscle memory and in `AGENT.md`'s talosctl
  recipe.** Renumbering means updating those.
