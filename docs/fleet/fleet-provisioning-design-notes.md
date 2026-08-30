# Fleet provisioning design notes

**Status:** design only. Nothing here is built. Written 2026-08-30, after
`homelab-worker-0` arrived on the LAN and the question became not *what should
this one machine run* but *what shape lets any number of machines be added
without re-deciding each time*.

Deliberately **not** referenced from `CONCEPT.md`. It proposes changes to
`ansible/` and `terraform/` but supersedes no decision; D18 in particular stands
— see [§1.1](#11-what-was-decided-and-what-was-not).

---

## 1. The goal, and the constraint that shapes it

Four things are wanted, in this order:

1. **Adding a machine should be cheap and repeatable** — a group membership or a
   node-list entry, not a design conversation.
2. **Ansible should run remotely**, from a control node, rather than on the
   managed host itself.
3. **`talosctl` and `kubectl` should reach every node from that same control
   node**, as the normal path rather than as a thing you SSH somewhere to do.
   [§6](#6-reaching-the-fleet-talosctl-and-kubectl) is the whole of this, and it
   is the goal with the least existing machinery behind it.
4. **A new machine may be either bare-metal Talos or an Ubuntu hypervisor
   running a Talos VM.** Both must stay first-class; neither is the exception.

### 1.1 What was decided, and what was not

Bare-metal-Talos-everywhere was considered and **rejected**, on 2026-08-30, on
grounds that are not technical:

- The project is **educational**. A hypervisor layer under the cluster is part
  of what it exists to teach, and flattening it removes the lesson along with
  the layer.
- Machine 1's Ubuntu is wanted as a **general-purpose environment** in its own
  right, independent of the cluster.
- Flexibility on the Ansible side is wanted, not minimised.

So **D18 stands unchanged**: Ubuntu stays on machine 1's metal as a hypervisor.
Its "reverses if" clause — *a second machine arrives and the hypervisor/cluster
split stops paying for itself* — was examined when the second machine arrived
and **did not fire**.

The consequence, accepted deliberately: **the fleet runs two provisioning
models, permanently.** That is the thing this note has to make maintainable
rather than eliminate. [§7](#7-the-invariant) is the rule that does it.

### 1.2 What is already true and does not need building

Verified 2026-08-30 from the Mac:

- The Mac (`lesthers-mba`, `100.102.71.10`) and machine 1 (`homelab`,
  `100.121.11.84`) are both on the tailnet, and machine 1's `:22` answers from
  the Mac. **Remote Ansible needs no new networking — for machine 1.** It says
  nothing about a machine that does not yet run Tailscale; that is
  [§4.1](#41-getting-a-new-ubuntu-machine-onto-the-tailnet).
- `homelab-worker-0` is on the tailnet too (`100.117.211.109`) — until the wipe
  in [headless-talos-install.md](headless-talos-install.md) takes its node key.
  Do not carry this fact forward past the install; it is evidence with an expiry
  date.
- **Remote `kubectl` is already built, and this note originally read as though
  it were not.** `infrastructure/tailscale-runtime/`'s `kube-apiserver-ci`
  `ProxyGroup`, `infrastructure/human-auth/rbac.yaml` and the
  `autogroup:member` → `svc:kube-apiserver-ci` grant in
  `tailscale-acl/policy.hujson` together give the operator `kubectl` from the
  Mac over the tailnet against a Google-issued OIDC token (LES-104). Half of
  goal 3 is therefore done — with one large caveat that
  [§6.1](#61-what-kubectl-over-the-tailnet-does-not-cover) exists for.

---

## 2. The blocker: `become` over SSH

This gates everything else and has to be settled first.

`ansible.cfg` currently sets `become_flags = -H -n`, and the comment block
explains the mechanism: run `sudo -v` in the same terminal to cache a sudo
timestamp, then `-n` consumes it non-interactively, so no prompt is emitted for
Ansible's regex to misparse.

**That ticket is per-tty.** It exists only because the control node and the
managed node are the same machine, in the same terminal. Over SSH there is no
persistent terminal to cache one in — verified 2026-08-29 in
[multi-node-ha-design-notes.md §2.3](multi-node-ha-design-notes.md), where
`sudo -n true` on `homelab-worker-0` returned *"interactive authentication is
required"*.

So `connection=local` is not merely convenient here. **It is load-bearing for
privilege escalation**, and removing it breaks `become` until something replaces
the mechanism.

### 2.1 Password-based become is not the replacement

**Verified 2026-08-30** — this section previously reasoned from the documented
mechanism and flagged itself as untested. It is now tested, and the result
confirms the conclusion while correcting the reasoning.

Ansible detects sudo's prompt by matching a marker it passes to `sudo -p`;
sudo-rs *wraps* that marker inside its own `[sudo: ...] Password:` format
instead of replacing it, and Ansible matches with `startswith()`, so a string
beginning `[sudo:` can never match. Observed on machine 1:

```
$ echo 'wrong' | sudo -S -v
[sudo: authenticate] Password:

$ ANSIBLE_BECOME_FLAGS='-H -S' ansible ... -m ping -K
Timed out waiting for become success or become password prompt.
>>> [sudo: [sudo via ansible, key=...] password:] Password:
```

Prompt detection is required by **every** password-based path, so
`--ask-become-pass`, `-K` and a vaulted `ansible_become_password` all fail the
same way.

**Two corrections to what `ansible.cfg` used to claim**, both checked against
upstream on 2026-08-30:

- [ansible#85837](https://github.com/ansible/ansible/issues/85837) is **closed
  completed**, not open — PR #86175 (`639bab6`, 2026-04-27) adds a
  `check_password_prompt()` override that retries against the wrapped form.
- [sudo-rs#1461](https://github.com/trifectatechfoundation/sudo-rs/issues/1461)
  is **open**, not "closed wontfix". The wrapping is deliberate: sudo-rs will
  not hide PAM's prompt, because PAM may be asking for a PIN or a TOTP code.

**The fix is unreleased** — `devel` only, absent from `v2.21.3` and
`stable-2.21`, with no 2.22 tag. It merged one day before `v2.21.0rc1` was cut,
after `stable-2.21` had branched. So no released `ansible-core` can do this
today.

Two things would both have to be true and neither is: sudo needs `-S` or a TTY
(**`-S` does work** on sudo-rs 0.2.13 — an earlier "a terminal is required"
result was `-S` failing to reach sudo, because `-e ansible_become_flags` did not
apply where `ANSIBLE_BECOME_FLAGS` did), **and** Ansible must parse the wrapped
prompt.

**So NOPASSWD is required rather than preferred — for now.** When 2.22 ships it
becomes a fleet-design choice instead (a human typing a password per run is
wrong for a fleet and impossible unattended), so the decision survives the
upgrade and only its justification changes. That is worth writing down, because
a justification that expires quietly is how a correct decision comes to look
arbitrary later.

**Adjacent gap:** `ansible-core` is pinned nowhere, while collections are pinned
in `ansible/requirements.yml`. Since 2.22 changes sudo-rs behaviour, a recorded
minimum version belongs alongside those pins.

### 2.2 The two options that work

- **NOPASSWD sudoers for the operator on each managed host.** No prompt is ever
  emitted, so the bug cannot trigger. Already anticipated in §2.3 of the
  multi-node note, which correctly calls it *"a security-posture decision, not a
  Tailscale- or HA-specific one."*
- **Connect as `root` with a dedicated key**, dropping `become` entirely.

**Recommended: NOPASSWD**, because it keeps a named human identity rather than
collapsing every action to `root`. Both are equivalent to unattended root
access — but so is the SSH key that is already there, so the marginal exposure
is small and the honest comparison is against the key, not against nothing.

### 2.3 Plant it at install time, not with a bootstrap playbook

A brand-new machine has no sudoers drop-in, and the playbook that would install
one needs privilege escalation to do it — which is the thing that does not work
yet.

The clean cut is that **the OS install is the bootstrap mechanism.**
[headless-ubuntu.md](headless-ubuntu.md)'s `autoinstall.yaml` already plants
the operator's SSH key via `ssh.authorized-keys`; the sudoers drop-in belongs in
the same file. Then every Ubuntu machine arrives Ansible-ready and there is no
step that needs the broken interactive path.

`identity:` cannot do it — that key only creates the account, which gets
*password* sudo. The hook that can is `late-commands`, which runs in the
installer environment with the new system mounted at `/target`:

```yaml
late-commands:
  - printf 'lestherll ALL=(ALL) NOPASSWD:ALL\n' > /target/etc/sudoers.d/90-ansible
  - chmod 0440 /target/etc/sudoers.d/90-ansible
  - curtin in-target -- visudo -cf /etc/sudoers.d/90-ansible
```

**The `visudo -cf` line is not tidiness.** A malformed drop-in makes `sudo`
refuse to run at all, and these machines have `allow-pw: false` and, in
`homelab-worker-0`'s case, no video output — so the validation failing the
install loudly is strictly better than discovering it later with no way in.

This is the single change that does the most for "adding a machine is cheap."

### 2.3.1 Machine 1 is the exception, and the ordering is a trap

Machine 1 was installed before any of this and will not be reinstalled, so the
install-time mechanism does not reach it. Its drop-in has to be planted by hand,
exactly once — **and it must happen while `ansible_connection=local` is still in
place**, because that local path is the only working escalation route on this
host today ([§2](#2-the-blocker-become-over-ssh)).

Remove `connection=local` first and the machine that runs the platform is the
one machine you can no longer configure. So M1 in
[§8](#8-sequencing) splits this into two steps rather than one: the
`autoinstall.yaml` edit for future machines, and a one-off
`sudo tee /etc/sudoers.d/90-ansible` on machine 1 before the inventory moves.

### 2.4 What survives in `ansible.cfg`

Keep `become_flags = -H -n`, both flags. `-n` is the load-bearing one: with
NOPASSWD in place it changes no outcome, but it makes a *missing* sudoers
drop-in fail fast instead of hanging on a prompt nobody will answer — which is
the failure mode most likely to appear when a new machine is added and the
install-time step was missed.

`-H` is not load-bearing and should be kept anyway. Dropping it changes `$HOME`
for the escalated user; nothing here obviously depends on that, which is exactly
why it should not ride along inside a commit about connectivity. Change one
thing.

What goes away is the `sudo -v` ritual and the top-level `sudo ansible-playbook`
wrapper documented in AGENT.md and in `converge.yml`'s header. Both stop being
correct once the connection is remote, and leaving them documented would be
worse than not documenting them.

---

## 3. Inventory: group by capability, never by machine

`hosts.ini` today is one host with everything in `[homelab:vars]`:

```ini
[homelab]
homelab-01 ansible_connection=local ansible_host=127.0.0.1
```

The problem is not the single entry — it is that **machine-1 facts sit at group
scope**. `tailscale_ip`, `libvirt_domain_name` and `alertmanager_healthy_url`
describe one machine while being inherited by everything that joins the group.
A second host inherits nonsense the moment it appears.

### 3.1 Proposed shape

```
[ubuntu_hosts]      every Ansible-managed box
[hypervisors]       runs libvirt and hosts Talos VMs
[bulk_hosts]        a hypervisor that also has a second, slow disk
[operator_hosts]    gets kubectl / talosctl / flux / helm / sops
[monitors]          runs the heartbeat and disk-space watchdogs
```

Machine 1 is in all five. That is fine and expected — the point is that its
memberships now *describe its capabilities* rather than being implied by it
being the only host.

Variable placement follows from that:

| Variable | Today | Belongs in |
|---|---|---|
| `homelab_operator_user` | `[homelab:vars]` | `group_vars/all` (host-overridable) |
| `alertmanager_healthy_url` | `[homelab:vars]` | `group_vars/all` — one Alertmanager |
| `disk_space_warn_threshold_percent` | `[homelab:vars]` | `group_vars/all` |
| `ntfy_topic` (SOPS) | `group_vars/homelab/` | `group_vars/all/` — fleet-wide |
| `tailscale_ip`, `tailscale_interface` | `[homelab:vars]` | `host_vars/` — or better, derived from facts |
| `libvirt_domain_name` | `[homelab:vars]` | `host_vars/` — see below |

`tailscale_ip` is worth deriving from `ansible_facts` on the `tailscale0`
interface rather than pinning: a hardcoded per-host address is exactly the kind
of fact that goes stale silently.

Moving `ntfy_topic` has a documentation coupling worth landing in the same
commit: AGENT.md pins all three encrypted copies of that value **by path**, and
`ansible/inventory/group_vars/homelab/ntfy_topic.sops.yaml` is one of the three.
A rename that leaves that note stale turns the repo's own "rotation means
editing all three" instruction into a wrong one.

`libvirt_domain_name` is a **deliberate duplicate** of `cluster_name` in
`terraform/clusters/homelab/main.tf`, and its inline comment says so. Moving it
to `host_vars` keeps the duplication but makes it per-hypervisor, which is
correct once more than one exists. The coupling stays worth an explicit comment
wherever it lands.

### 3.2 Bare-metal Talos machines are not in this inventory

They are not Ansible-managed and must not appear here, not even as an
unplaybooked group for documentation's sake. They belong to Terraform's node
list ([§5](#5-terraform-one-node-list-two-backends)).

**One source of truth per plane** is what stops a two-model fleet from becoming
confusing. The moment a machine is listed in both places, "which one is right"
becomes a question someone has to answer during an incident.

---

## 4. Roles: `host_prereqs` is already the hypervisor role

Read through on 2026-08-30, and this is the finding that changes the plan.
`host_prereqs` is not a generic host-preparation role with some libvirt in it.
Its tasks are, in order: `net.ipv4.ip_forward` (for the VM's NAT egress),
hypervisor packages, `libvirtd`, the operator into the `libvirt` group, the
Talos libvirt network, the SSD libvirt pool, and ufw rules for forwarded traffic
and for DHCP/DNS from the Talos VM network.

**The only task in it that applies to a machine with no VMs is "Allow SSH on all
interfaces."**

`bulk_storage` is the same story and is easy to misread from its name: its five
tasks are the mount assert plus *defining the HDD-backed libvirt pool*. It is
not a storage role — it is the hypervisor's second pool. Its
`bulk_storage_libvirt_pool_path` default gives it away.

So the restructuring is not "extract libvirt from `host_prereqs`":

| New role | Source | Applied to |
|---|---|---|
| `base` (**new**, thin) | the one ufw/SSH task, plus packages, sshd, the sudoers drop-in | `[ubuntu_hosts]` |
| `hypervisor` | `host_prereqs`, renamed — essentially unchanged | `[hypervisors]` |
| `bulk_storage` | unchanged | `[bulk_hosts]` |
| `cli_tools` | unchanged | `[operator_hosts]` |
| `heartbeat_watchdog` | unchanged | `[monitors]` |

Two consequences worth recording:

- **`bulk_storage`'s mount assert stops being a hardware assumption and becomes
  a group-membership question.** AGENT.md calls it *"the only hardware
  assertion left anywhere in the design"*; under this shape the assertion stays
  (it is still the thing stopping a pool being created on the SSD) but the
  decision about *which machines have a bulk disk* moves into the inventory,
  where it is visible.
- **`community.libvirt` needs `python3-libvirt` on the managed host**, because
  `virt_net`/`virt_pool` execute there. `host_prereqs` installs it today, which
  worked invisibly while control node and target were the same box. Over SSH
  the ordering becomes real: the `hypervisor` role must install that dependency
  before its own libvirt tasks run, on every hypervisor.

`converge.yml` becomes one play per group instead of one play with four ordered
roles. Its header comment — which currently documents the `sudo`-wrapped
invocation — needs rewriting at the same time ([§2.4](#24-what-survives-in-ansiblecfg)).

### 4.1 Getting a new Ubuntu machine onto the tailnet

This is a gap inherited from the multi-node note rather than created here, and
it has to be closed before "adding a machine is cheap" is true.

[multi-node §4.1](multi-node-ha-design-notes.md) concludes *"no `tailscale` role
is required"* — but that conclusion rests entirely on its §3.1 premise that
machines 2+ run bare-metal Talos and are therefore not Ansible-managed at all.
[§1.1](#11-what-was-decided-and-what-was-not) of this note **reverses that
premise** and keeps Ubuntu hypervisors first-class. The conclusion does not
survive the reversal.

So `base` installs and authenticates Tailscale, and that pulls in a **tailnet
auth key** — the first secret `ansible/` would carry that is not `ntfy_topic`,
and a fourth SOPS-encrypted file to keep track of.

**The trap is in the ACL, not the role.** A machine joined with a *tagged* auth
key has no user owner, so it is not in `autogroup:self` — `policy.hujson` says
this in as many words in the comment above the grant. Neither the
`{"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]}` grant
nor the `ssh` block covers it, so SSH from the Mac fails with nothing anywhere
naming the reason. Two ways out:

- **Join untagged**, as one of the operator's own devices. It lands in
  `autogroup:self` and everything works with no policy change — at the cost of
  being a user-owned device subject to key expiry, which has to be disabled per
  device in the admin console (off-repo state, which is the thing
  `tailscale-acl/` exists to avoid).
- **Mint a `tag:homelab-node`**, with `tagOwners`, a grant and an `ssh` rule.
  That is a commit in this repo — **once**, not per machine, provided the tag is
  minted generically rather than per host.

Recommended: the tag. It is one commit, it keeps the fleet's reachability
described in git like everything else, and it avoids per-device console state.
But note honestly that until it lands,
[§8](#8-sequencing)'s *"adding a machine is: install it, put it in a group,
run"* is not yet true.

---

## 5. Terraform: one node list, two backends

This is what makes "bare metal or VM" a per-node property rather than a fork in
the design.

`terraform/modules/talos-cluster/` today builds exactly one libvirt domain with
`machine_type = "controlplane"`, a single hardcoded DHCP reservation, and an
unconditional `talosctl bootstrap` ([multi-node note
§2.2](multi-node-ha-design-notes.md)). §4.2 of that note already calls for
parameterising it over a node list; this adds one field to that work.

Each node declares its backend:

- **`libvirt`** — the module creates the domain and its volumes, on a named
  hypervisor. Remote hypervisors via provider aliases with
  `uri = "qemu+ssh://lestherll@<host>/system"`; the current
  `uri = "qemu:///system"` becomes the local alias rather than the only mode.

  Two things that fail late if not planned for. `terraform-provider-libvirt`
  connects with **Go's SSH client, not OpenSSH** — it does not read
  `~/.ssh/config`, so the URI itself must carry `?sshauth=agent` or an explicit
  `keyfile=`. And `terraform/scripts/stage-talos-image.sh` hardcodes
  `VIRSH="virsh -c qemu:///system"`: its *pool* is already a parameter, its
  *connection* is not, so image staging silently keeps targeting machine 1 no
  matter which hypervisor the node is declared on. Both are small; both are
  invisible until a second hypervisor exists.
- **`metal`** — the module creates *no* infrastructure. The machine already
  exists, sitting in maintenance mode at a known address, put there by
  [headless-talos-install.md](headless-talos-install.md).

Both paths converge on the same `talos_machine_configuration_apply`, with
`machine_type` per node and `bootstrap` run exactly once for the cluster.

**The storage design ports across unchanged, which is the part that could have
been expensive and isn't.** `talos.tf`'s `UserVolumeConfig` blocks select disks
by `disk.serial`, not by device enumeration, and mount at `/var/mnt/<name>` —
with the rationale stated inline: *"that path is identical on every node by
construction — which is what lets the storage classes stop caring which machine
they are on."* A real disk serial works exactly as a virtio one does.

The inline caveat there is the trap to carry into the node list: *"a node whose
config omits a volume would silently get a directory on its system disk, so the
volume must be declared for every node in the class."* `homelab-worker-0` has
one disk and can have no `bulk` volume, so it must be excluded from that class
deliberately rather than by omission. The matching cluster-side fact:
`infrastructure/storage/provisioners.yaml` pins all three `nodePathMap`s to
`talos-cp-01` with no default path, so a PVC landing on an unlisted node fails
rather than writing to the wrong disk.

---

## 6. Reaching the fleet: `talosctl` and `kubectl`

Goal 3, and the part of this design with the least existing machinery behind it.
It is also where the two-model fleet stops being free: machine 1's Talos VM and
a bare-metal Talos node are reached by *different* mechanisms today, and only
one of them exists.

### 6.1 What `kubectl` over the tailnet does not cover

Per [§1.2](#12-what-is-already-true-and-does-not-need-building) this path is
built and works. Its limit is structural: **the proxy runs inside the cluster it
proxies to.** So it is unavailable in precisely the situations `kubectl` is
wanted for — a wedged apiserver, a bad Flux change, and the bridged rebuild
itself, during which there is no cluster at all. AGENT.md already records the
milder version of this: `kube-apiserver-ci-0` treats a failed watch as fatal and
dies whenever the apiserver restarts.

That makes the break-glass path a hard requirement rather than a nicety, and
today it is: SSH to machine 1, then `talosctl`. Which means:

> **The break-glass path for remote `kubectl` is remote `talosctl` — and remote
> `talosctl` does not exist.**

That is the dependency this note previously did not draw, and it is what decides
the shape of the rest of this section.

### 6.2 Why remote `talosctl` does not work today

`terraform/modules/talos-cluster/talos.tf` sets `endpoints = [var.node_ip]` and
`machine.certSANs = [var.node_ip]`, and `var.node_ip` is `10.10.0.10` — the
host-only NAT address from [multi-node §2.1](multi-node-ha-design-notes.md).
Nothing off machine 1 can reach it, and the apid certificate names nothing else.
AGENT.md's `talosctl` recipe is written for a shell on machine 1 for exactly
this reason.

The bridged rebuild moves the nodes onto `192.168.0.0/24`, which makes them
LAN-reachable — necessary, and not sufficient, since a control node is not
always on the LAN.

### 6.3 The mechanism that makes this cheap

Worth stating before the options, because it changes their cost: **`talosctl`
proxies through an endpoint.** `talosctl --endpoints <any reachable node>
--nodes <any node>` has apid on the endpoint forward to the target, so *one*
reachable node is enough for the whole cluster — not N.

Two conditions attach. The endpoint must reach the target's `:50000`, which is
free once bridged; and the target's apid certificate must cover the address
named in `--nodes`, which is the `machine.certSANs` trap at `talos.tf:122`
appearing in a new place.

### 6.4 The three options

| | Survives machine 1 being down | Cost |
|---|---|---|
| **(a)** SSH to machine 1, run `talosctl` there | **no** | none |
| **(b)** Machine 1 advertises `192.168.0.0/24` as a subnet router | **no** | ACL + role work |
| **(c)** Tailscale system extension on each Talos node | **yes** | schematic + auth key + certSANs |

(a) is the status quo. It is not merely inelegant: it routes the *bare-metal
node's* only diagnostic path through the other machine, and "machine 1 is down"
is a case you actively want `talosctl` for.

(b) needs `--advertise-routes` on machine 1, an `autoApprovers.routes` block —
`policy.hujson` has only `services` today — and a grant with
`dst: ["192.168.0.0/24"]`, because `autogroup:self` is *device*-scoped and does
not cover subnet-route destinations. It shares (a)'s single point of failure for
one machine's worth of work.

**(c) is the recommendation**, and it forces a decision the repo has so far
deferred rather than made. `terraform/scripts/stage-talos-image.sh` rejects the
Tailscale extension in a comment: *"Tailscale stays on the host, which keeps one
tailnet identity and dissolves the certSANs chicken-and-egg."* That rationale is
**host-shaped, and a bare-metal node has no host** — so `homelab-worker-0` is
the machine that invalidates it. Once it is taken for the bare-metal node it
should be taken for the VM in the same change, or the fleet has two different
remote-access stories, which is exactly what
[§7](#7-the-invariant) exists to prevent.

What (c) actually costs, none of it hidden:

- **A new Image Factory schematic**, adding `siderolabs/tailscale` to the
  existing `siderolabs/qemu-guest-agent`. The installer image becomes
  `factory.talos.dev/installer/<schematic-id>:v1.13.8`, pinned and re-mintable
  the same way `stage-talos-image.sh` already documents.
- **An `ExtensionServiceConfig` carrying `TS_AUTHKEY`** — a machine-config
  secret, so it belongs with the Terraform-side PKI, not in Flux.
- **The tag and grant work from [§4.1](#41-getting-a-new-ubuntu-machine-onto-the-tailnet)**,
  reused rather than duplicated.
- **The node's tailnet address in `machine.certSANs`.** Omit it and every
  authenticated call fails with the verbatim error already documented at
  `talos.tf:122` — and, if it happens during bootstrap, hangs rather than errors.

**The timing constraint is the sharp part.** System extensions change only at
install or upgrade, never by config alone. So this has to be settled *before*
[headless-talos-install.md §10.4](headless-talos-install.md) applies a worker
config, not after — otherwise the node is reinstalled a third time to add it.

### 6.4.1 Reachability is device-independent; credentials are not

The goal is `talosctl` from **any** tailnet device, not from one blessed
laptop — and option (c) delivers only half of that, in a way worth stating
because the two halves look symmetric and are not.

**Reachability: solved, for every device at once.** The ACL grant is written
`autogroup:member` → the node's tag on `tcp:50000`, so it covers every device
the operator owns, present and future, with no per-device change.

**Credentials: not solved by any of the three options.** `apid` authenticates
with mutual TLS against the Talos PKI. There is no OIDC path, so nothing here
resembles the `kubectl` story — where the proxy is `noauth`, identity comes from
a Google token, and a new device needs a kubeconfig containing nothing secret.
A device without a talosconfig holding a client certificate and private key
cannot talk to a node however reachable it is.

Copying the admin `talosconfig` to each device is the obvious move and the wrong
one: a long-lived `os:admin` credential replicated onto every phone and laptop.
The mechanism Talos provides instead is `talosctl config new`, which mints a
scoped, expiring client config — `--roles` (default `[os:admin]`) and
`--crt-ttl` (default `8760h`), both verified against v1.13.8:

```
talosctl config new ~/laptop-talosconfig --roles os:reader --crt-ttl 720h
```

**And the honest asymmetry to record:** remote `talosctl` is *more* expensive to
keep safe than remote `kubectl`, which is the opposite of where intuition
points. Revoking a human's `kubectl` is an RBAC or Google-account change.
Talos has no CRL, so revoking a device's `talosctl` means waiting out the TTL or
rotating the cluster PKI — which is the real argument for short TTLs.

### 6.5 The apiserver certificate, which breaks in the same rebuild

`terraform/modules/talos-cluster/variables.tf` describes `node_ip` as *"baked
into the apiserver certificate via certSANs"*. That is not what
`machine.certSANs` does — it covers apid, trustd and the kubelet. The apiserver
certificate covers `10.10.0.10` today only because it is the *cluster endpoint*.

After the VIP rebuild the endpoint becomes the VIP, so the **individual node
addresses stop being covered**, and `kubectl --server=https://192.168.0.x:6443`
fails x509 validation. That is the break-glass path from
[§6.1](#61-what-kubectl-over-the-tailnet-does-not-cover) breaking silently,
inside the one rebuild that is supposed to contain everything.

Fix in the same change: set `cluster.apiServer.certSANs` **explicitly** to the
VIP, every node address, and any tailnet name the apiserver may be reached by.
Nothing sets it today, and the comment in `variables.tf` should be corrected so
the next reader does not conclude it is already handled.

---

## 7. The invariant

One rule, and a two-model fleet stays coherent:

> **Ansible owns Ubuntu metal. Talos machine config owns everything Kubernetes.
> A machine lives in exactly one of those worlds — except a hypervisor, which
> lives in Ansible's world and *hosts* something in Talos's.**

Corollaries, each of which is a thing that would otherwise get decided
ad hoc later:

- A bare-metal Talos machine is **never** in the Ansible inventory.
- A machine's Ansible group memberships describe **capabilities**, never
  identity. "Is this the box with the second disk" is a group; "is this
  `homelab-01`" is not.
- No Kubernetes-shaped fact enters `ansible/`. This is D18's original point and
  it is unaffected by any of the above — Talos enforces it regardless of whether
  Talos is on metal or in a domain.

AGENT.md's *"`ansible/` — **the metal only**"* survives intact; it pluralises to
*the Ubuntu metal*.

---

## 8. Sequencing

Grouped into four milestones. **M1 and M2 are independent of the
bridged-network rebuild** in [multi-node-ha-design-notes.md](multi-node-ha-design-notes.md)
and can land at any time; M3 is the rebuild and everything that must ride inside
it; M4 is the payoff.

### M1 — Ansible works remotely

Nothing else in this note works until `become` works over SSH.

1. **`autoinstall.yaml` gains `late-commands`** for the NOPASSWD drop-in
   ([§2.3](#23-plant-it-at-install-time-not-with-a-bootstrap-playbook)), and a
   second `authorized-keys` entry so a lost key is not a dead machine.
2. **Plant the drop-in on machine 1 by hand**, while `connection=local` still
   works ([§2.3.1](#231-machine-1-is-the-exception-and-the-ordering-is-a-trap)).
   Ordering matters: this is the step whose omission locks you out.
3. **Inventory restructure, and machine 1 reached over SSH** like every other
   host ([§3](#3-inventory-group-by-capability-never-by-machine)); AGENT.md's
   `ntfy_topic` paths and its `sudo ansible-playbook` recipe update in the same
   commit. Verify the repo's normal way: re-run the same `--tags` and confirm
   `changed=0` in the recap before believing it.
4. **Split `host_prereqs` into `base` + `hypervisor`**
   ([§4](#4-roles-host_prereqs-is-already-the-hypervisor-role)). Same
   idempotency check — this one is a rename plus a small extraction, so a
   non-zero `changed` count is a real signal, not noise.

### M2 — the fleet is reachable

Everything here is policy and packaging; none of it touches the cluster.

5. **`tag:homelab-node`, its grant and its `ssh` rule** in
   `tailscale-acl/policy.hujson`, plus Tailscale in the `base` role and its
   auth key as a fourth SOPS file
   ([§4.1](#41-getting-a-new-ubuntu-machine-onto-the-tailnet)).
6. **Mint the Tailscale + qemu-guest-agent Image Factory schematic** and pin it
   ([§6.4](#64-the-three-options)). Minting is free and reversible; it is
   deliberately ahead of M3 so the rebuild does not wait on it.
7. **Terraform node list with two backends**
   ([§5](#5-terraform-one-node-list-two-backends)), still at N=1, with the
   `qemu+ssh` and `stage-talos-image.sh` connection fixes.

### M3 — the one rebuild

Per [multi-node §3](multi-node-ha-design-notes.md), Talos bootstrap manifests do
not retrofit. Everything that needs a rebuild lands here or waits for the next
one.

8. **Bridged network + VIP**, with `cluster.apiServer.certSANs` set explicitly
   to the VIP and every node address
   ([§6.5](#65-the-apiserver-certificate-which-breaks-in-the-same-rebuild)), the
   Tailscale extension installed and each node's tailnet address in
   `machine.certSANs` ([§6.4](#64-the-three-options)), the `talos.tf:200`
   kube-proxy bind re-justified, and `machine.network.ingressFirewall` replacing
   the protection NAT was providing.
9. **Verify remote `talosctl` from the Mac** against machine 1's node before
   touching machine 2. This is the acceptance test for goal 3, and the point of
   no return for `homelab-worker-0`'s install.

### M4 — add machines

10. **Join `homelab-worker-0` as a worker**
    ([headless-talos-install.md §10](headless-talos-install.md)), with the
    factory installer image from step 6 rather than the plain one.
11. **Then add machines.** By this point adding one is: install it, put it in a
    group or in the node list, run.

---

## 9. What this does not address

- **The bridged-network rebuild is still required** before any Talos machine
  outside machine 1 can join the cluster. Nothing here changes that; see §2.1
  and §4 of the multi-node note.
- **HA still needs three machines** (etcd quorum, §1 of that note). This makes
  adding the third cheap; it does not make two sufficient.
- **Stateful workloads still do not fail over.** Node-pinned hostPath PVs are
  unaffected by any of this.
- **There are still no backups.** Audited 2026-08-29 and unchanged. Independent
  of this work and higher-value than it.
- **The tailnet is still one dependency under everything.** Goal 3's answer is
  Tailscale in all three of its forms — the operator's device, the `base` role,
  and a Talos system extension. A control-plane outage is now survivable from
  the Mac; a *tailnet* outage is not, and the remaining fallback is the LAN,
  which means physical presence. That is an acceptable trade for a homelab and
  should be a stated one rather than a discovered one.
- **The control node is the Mac** — settled 2026-08-30, and no longer open.
  The decisive check is that **nothing in `ansible/` runs on the control node**
  (no `delegate_to`, `local_action` or `connection: local` anywhere), so it
  needs only Ansible, `sops` and the age key, and does not need to be Linux.
  `cli_tools` being Linux-only does not bear on this — that role provisions
  *managed hosts*, not the controller. The resulting split: **Mac** for git,
  `kubectl`, ACL changes, schematic minting, Ansible and the bare-metal install;
  **machine 1** for Terraform and `talosctl`, which need the libvirt socket and
  the cluster PKI. Note this is a preference, not a necessity — both machines'
  Ansible is equally affected by §2.1.

  On the age key: D12 asks for *"an encrypted copy in two physically separate
  locations plus a password manager"*, so a second copy is the stated minimum
  and today's single copy is the deviation. A working key on the Mac is not
  that backup, though — the backup remains unbuilt and belongs elsewhere.

  **Setting the Mac up, done 2026-08-30.** `ansible-core` via `uv tool`;
  collections into the checkout rather than the shared path (`collections_path`
  in `ansible.cfg`, gitignored) so `requirements.yml`'s pins actually bind; and
  one pinned, checksum-verified `sops` binary matching `cli_tools`'
  `sops_version`, so control node and managed hosts stay on one version.
  **`age` is not needed** — `community.sops` shells out to `sops`, and `sops`
  links the age library rather than calling the CLI (verified by decrypting with
  `age` off `PATH`).

  > **The age key path is a per-machine fact, and the error does not say so.**
  > Nothing in the repo configures it — deliberately, since where a control node
  > keeps its key belongs to that machine, like `~/.ssh`. sops looks in
  > `<os.UserConfigDir()>/sops/age/keys.txt`, which is Go's: `$XDG_CONFIG_HOME`
  > when set, `~/.config` on Linux otherwise, `~/Library/Application Support` on
  > macOS. `SOPS_AGE_KEY_FILE` overrides it anywhere that rule is unclear.
  >
  > Placing the key where sops already looks — rather than exporting the
  > override — is what keeps a control node **zero-configuration**, which is the
  > property this section depends on when it claims the choice of control node
  > is reversible. It also means one file serves both the vars plugin and bare
  > `sops` for editing secrets.
  >
  > When it is wrong the failure reads *"no master key was able to decrypt the
  > file"*, naming neither the path searched nor the one you used — it looks
  > like a wrong key and is a missing file. Cost about ten minutes on
  > 2026-08-30 against a key whose public half provably matched `.sops.yaml`.

  What [§3](#3-inventory-group-by-capability-never-by-machine) buys is that the
  choice stays *reversible*: with no `connection=local` special case, either
  machine works, and machine 1 running playbooks against itself over SSH is the
  same code path as anything else.
