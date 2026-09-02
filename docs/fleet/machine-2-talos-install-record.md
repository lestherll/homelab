# Machine 2 — Talos install, as actually executed

**Status: EXECUTED 2026-09-02.** `homelab-worker-0` runs Talos v1.13.8 on its own
SSD, holding a disposable identity, reachable on the LAN, not a member of any
cluster. This is the record of what was done and what it corrected; the
procedure it *departs from* is [headless-talos-install.md](headless-talos-install.md),
and the decision it implements is [ADR 0001](../adr/0001-single-model-talos-fleet.md) §8.4.

Every claim below was verified against the live machine. Anything not verified
is labelled.

---

## 1. The route taken, which the runbook does not describe

The runbook offers Route A (kexec, config applied afterwards over the API) and
Route B (USB media). What was executed is **Route A carrying its own config** —
kexec with `talos.config=<URL>` on the kernel command line, the config served
over plain HTTP from the operator Mac.

That combination is the true analogue of the Ubuntu autoinstall: one command,
walk away, no `apply-config` step, and **no USB media at all**. It exists because
kexec lets the operator set the entire kernel command line, so the unattended
hook that [install-media-and-reprovisioning-notes.md](install-media-and-reprovisioning-notes.md)
§4.2 reaches a `metal-iso` volume for is available without any volume.

Why it beat the two-stick arrangement here, all four reasons decided on the night:

- **The Ubuntu autoinstall stick survived.** It was the only spare media, and
  flashing it would have destroyed the artifact that built machines 1 and 2.
- **No firmware boot-order gamble on the way in.** `BootNext`, the two PXE
  entries and `Boot0006` were all irrelevant to the install itself.
- **The failure mode is benign.** §4's Realtek risk — NIC not re-initialising
  after kexec — means Talos never reaches the Mac, so it never fetches a config
  and never installs. Nothing written, power-cycle back into Ubuntu.
- **It is available exactly once**, while Ubuntu is still there to jump from.

The cost is that the config crosses the LAN unauthenticated. Acceptable here
because the PKI was disposable by construction (§4 below), and the window was
about four minutes. **It would not be acceptable for a config carrying the real
cluster PKI**, which is the case §10.3 will be in — that one wants the
`metal-iso` stick, or `apply-config` over the API.

---

## 2. Artifacts, and their checksums

Image Factory schematic — commit this, not just its ID; the ID is a checksum of
the choice, not a name for it:

```yaml
customization:
  extraKernelArgs:
    - talos.config=http://192.168.0.44:8080/config.yaml
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

```
schematic  3cbae7e742190fc042097d7e9828d973b2392e81338085441aa7a7087e3d83b5
kernel-amd64       15b3590feed7a0c876dcffaa884522f31e172e4f07529731eca71713d0581ecd
initramfs-amd64.xz e934d6cbde0076b4b2b1f48320ba729b231a215851b68072b67bd71e5b390e91
metal-amd64.iso    9d5217e101d99fbe6dc46d208439fd4b237a0dc130a2fa9a9da6eb131e96c509
```

The ISO was built and verified but **not flashed** — it is the recovery path if
NVRAM ever ends up wrong, since media that boots reaches maintenance mode
without touching the disk's boot entry.

The Tailscale extension is deliberately **absent**. That decision
([headless-talos-install.md §10.1.1](headless-talos-install.md)) is still open,
and §7 of the install-media notes is right that it is now an in-place
`talosctl upgrade --image`, not a rebuild — so installing without it cost
nothing.

---

## 3. Verification, in the order it was taken

Each of these was checked *before* the irreversible step, which is the only
reason the install was a non-event.

| Check | Result |
| --- | --- |
| Secure Boot / lockdown | `SecureBoot=0`, `SetupMode=1`, lockdown `[none]` — kexec not vetoed |
| Disk model vs installer selector | `MTFDDAK512MAY-1A`, matches the config |
| Boot assets on the target | sha256 identical to the Mac's copies |
| Config fetch **from machine 2** | correct sha256 over the real URL |
| Config schema | `talosctl validate --mode metal` on the served bytes |

The post-install state:

```
SystemDisk   sda
hostname     homelab-worker-0
extensions   iscsi-tools v0.2.0, util-linux-tools 2.42.2, schematic 3cbae7e7…
sda1 EFI vfat 2.2G   sda2 META   sda3 STATE xfs   sda4 EPHEMERAL xfs 510G
```

An `--insecure` call is refused with `certificate required`, which is how you
tell an installed node from one in maintenance mode.

**The firmware found the bootloader on its own.** The running kernel started at
01:48:35Z, about two minutes *after* the kexec, and its install sequence ran
`0 phase(s)` — i.e. this is the boot *after* the install, reached through
firmware. That resolves what §6 of the install-media notes calls "the single
scariest unknown in the whole procedure": Talos writes the fallback
`EFI/BOOT/BOOTX64.EFI` and this machine's firmware discovers it, with no
`efibootmgr` intervention. **Not yet proven under a cold power-cycle**, only a
warm reboot.

---

## 4. What this corrects elsewhere

Five places the docs were out of step with the machine, each of which would have
cost time. Note they are not all the same kind of thing: three are facts that were
simply wrong, one is a value that **moved** (the address), and one is hardware
that **changed** (the RAM was upgraded, so the old figure was correct when
written).

> **All of these have since been applied in place (2026-09-02), along with a
> sixth found afterwards** — `headless-talos-install.md` §10.2's claim that the
> Mac has neither `sops` nor the age key, which is false: both are on the Mac at
> `~/Library/Application Support/sops/age/keys.txt`, verified by decrypting both
> Talos secrets files. This section is kept as the record of what the run found,
> not as a list of outstanding work.

- **The operator Mac is `192.168.0.44`, not `192.168.0.48`.**
  [install-media-and-reprovisioning-notes.md](install-media-and-reprovisioning-notes.md) §0
  records `.48`. That address is baked into the kernel command line, so the
  error would have presented as a machine with no video sitting silently in
  maintenance mode. **It is a DHCP lease and still has no reservation** — §5 of
  that note already flags this as the thing that must stop moving.
- **`machine.install.diskSelector` takes `model:`, not `match:`.**
  [headless-talos-install.md §2.3](headless-talos-install.md) gives a `match:`
  CEL expression; that form belongs to `UserVolumeConfig` and `talosctl gen
  config` rejects it outright on v1.13.8.
- **`machine.network.hostname` no longer exists.** It is a separate
  `HostnameConfig` document, and `talosctl gen config` already emits one
  (`auto: stable`) — so it must be *edited*, not appended, or validation fails
  with `duplicate document`.
- **Machine 2 now has 7.2 GiB of RAM** — not a mismeasurement, an **upgrade**
  fitted after the 2026-08-29 survey.
  [headless-talos-install.md §0](headless-talos-install.md) records 3.2.
  [multi-node-ha-design-notes.md §3.1](multi-node-ha-design-notes.md) calls
  3.2 GiB "marginal" for a control-plane node; at 7.2 GiB that concern largely
  goes away.
- **The node's address changed on the wipe: `.220` → `.221`.** Ubuntu's lease
  did not carry over, because Talos presents a different DHCP client identifier
  on the same MAC. [§2.5](headless-talos-install.md) says to make `.220` a
  reservation *before* the wipe; it was not done, and this is the cost. Every
  reference to `192.168.0.220` in this repo is now wrong for this machine.

One thing that is **not** a correction but is worth knowing: the installed
bootloader carries the `talos.config=http://192.168.0.44:8080/config.yaml`
argument through to disk. Harmless while `STATE` holds a config, since that
argument is only consulted when none exists — but a node whose `STATE` is wiped
will try to fetch from the Mac on boot.

---

## 5. Still open

- **The DHCP reservation.** Pick an address for `f4:93:9f:f2:59:82` and reserve
  it. Everything downstream — `certSANs`, the worker config, this repo's prose —
  bakes it in.
- **Cold power-cycle**, to prove persistence through a full POST rather than a
  warm reboot.
- **Joining the cluster is still blocked, and now measured.** Machine 2's only
  off-link route is a default via `192.168.0.1`; it has **no route to
  `10.10.0.0/24`** and cannot reach the control plane at `10.10.0.10`, which
  lives on machine 1's host-only libvirt NAT. From a tailnet device `:50000` is
  open and `:6443` is not, per the ACL grant. Both nodes run v1.13.8 SHA
  `3de49322`, so version parity is not a blocker — the network and the undecided
  VIP ([multi-node-ha-design-notes.md §7](multi-node-ha-design-notes.md)) are.
- **The disposable PKI in `~/talos-worker0/` is still live**, because it is
  currently the only way to talk to this node. [§9](headless-talos-install.md)'s
  disposal step is outstanding until the node is reset.
