# Headless Talos install — `homelab-worker-0`, driven from a Mac

Installing Talos Linux v1.13.8 on a Lenovo ThinkCentre that has **no video
output**, from an Apple Silicon Mac, wiping the Ubuntu 26.04.1 currently on it.

The end state is deliberately short of a cluster member: the machine boots
Talos **from its own SSD into maintenance mode**, holding no cluster identity,
reachable on the LAN, waiting for a config. Joining it to the cluster is
**blocked on a prerequisite that has not been built yet**;
[§10](#10-joining-the-cluster) covers what that is, and the procedure for the
day it clears.

Style and intent follow [headless-ubuntu.md](headless-ubuntu.md): every claim
below was checked rather than recalled, and the failure modes that misreport
their cause get their own call-outs. What is *not* verified is labelled as such.

---

## 0. What was measured on this machine

Read over SSH on **2026-08-29**, before anything was changed. Re-check anything
that matters to you; a stale fact here is worse than no fact.

| | |
|---|---|
| Host / address | `homelab-worker-0` at `192.168.0.220`, key access as `lestherll` |
| OS | Ubuntu 26.04.1 LTS, kernel 7.0.0-30-generic |
| CPU / RAM | i3-7100 (4 threads), **3.2 GiB** total, 2.7 GiB available |
| Disk | **one** — `/dev/sda`, 476.9 G, model `MTFDDAK512MAY-1A`; `sda1` = 1 G ESP, `sda2` = 475.9 G root |
| Firmware | **UEFI**, `/sys/firmware/efi` present |
| NIC | `enp1s0`, MAC `f4:93:9f:f2:59:82`, Realtek PCIe GBE, DHCP from `192.168.0.1` |
| Already installed | `kexec` (`/usr/sbin/kexec`), `efibootmgr`, `curl`, `zstd` |
| Also running | **Tailscale**, `100.117.211.109` — a second reachability path today, gone after the wipe |

Two findings dominate everything that follows.

**Secure Boot is enabled.** `mokutil --sb-state` reports `SecureBoot enabled`,
the `SecureBoot` EFI variable reads `1`, and the kernel is in lockdown
`[integrity]`. This blocks both routes into Talos — see [§1](#1-the-one-step-that-genuinely-needs-a-display).

**`sudo` needs a password.** `sudo -n true` returns *"interactive
authentication is required"* — the same fact recorded in
[multi-node-ha-design-notes.md §2.3](multi-node-ha-design-notes.md). So every
privileged command here must be run through `ssh -t` with the password typed by
hand. Nothing in this guide can be scripted end to end over `ssh -o BatchMode=yes`.

The current firmware boot list, worth having written down before it is destroyed:

```
BootCurrent: 0000
Timeout: 1 seconds
BootOrder: 0000,000A,000B,0006,0001,0007
Boot0000* Ubuntu                     HD(1,GPT,318ab9da-24c9-4335-b282-535c4dc24fdd,...)/\EFI\UBUNTU\SHIMX64.EFI
Boot0001* Windows Boot Manager
Boot0006* Generic Usb Device
Boot0007* CD/DVD Device
Boot000A* UEFI: PXE IPv4 Realtek PCIe GBE Family Controller
Boot000B* UEFI: PXE IPv6 Realtek PCIe GBE Family Controller
```

`Boot0006` — a **persistent** USB entry that exists with no USB plugged in — is
what makes the USB route in [§5](#5-route-b--usb-stick-fallback) work without a
second firmware trip.

---

## 1. The one step that genuinely needs a display

Secure Boot has to be turned off in firmware, and there is no way to do that
from the running OS. It closes both doors at once:

- **It blocks `kexec`.** Ubuntu's kernel enters lockdown *integrity* mode when
  Secure Boot is on, and lockdown disables the `kexec_load()` syscall. Talos's
  `vmlinuz-amd64` is not signed by any key in this machine's db or MOK, so
  `kexec -s` (the file-based syscall, which checks signatures) fails too.
- **It blocks booting Talos at all.** The released `metal-amd64.iso` is the
  non-SecureBoot profile — unsigned bootloader. Firmware refuses it. So does a
  Talos install written to the SSD. Signed alternatives exist from the Talos
  Image Factory, but they are signed by SideroLabs' key, whose enrolment is
  another firmware-screen trip. There is no way around this one.

> **The `kexec_load_disabled` sysctl will lie to you.**
> `/proc/sys/kernel/kexec_load_disabled` reads `0` on this machine — the value
> that means "kexec is permitted". It is permitted *by that knob*; lockdown
> vetoes it separately and later. `kexec -l` then fails with a bare
> `Operation not permitted`, naming neither Secure Boot nor lockdown.
> **`cat /sys/kernel/security/lockdown` is the check that tells the truth** — a
> bracketed `[integrity]` or `[confidentiality]` means kexec is off the table.

`mokutil --disable-validation` is a dead end worth naming so nobody spends an
evening on it. It would lift the *kernel's* lockdown (shim would report Secure
Boot as off) but leaves firmware Secure Boot on — so `kexec` would start
working and the installed Talos still would not boot. It also requires driving
the blue MOK Manager screen, which is the very thing being avoided.

### Doing the firmware trip

Borrow a monitor for five minutes if you possibly can. **Change one thing:
Secure Boot → Disabled.** Leave boot order alone; [§4](#4-route-a--kexec-preferred)
and [§5](#5-route-b--usb-stick-fallback) both set the boot device from the OS.
While you are in there it is also worth **disabling network/PXE boot** — see the
note at the end of [§8](#8-installing-to-the-ssd) for why those two entries
cost you a stall later.

On a ThinkCentre of this generation the setup key is **F1**, tapped from the
moment of power-on; `Timeout: 1 seconds` above means the window is short.
**F12** gives a one-time boot menu. The rest of the menu layout is
model-and-BIOS-version specific and is *not* something this guide can verify for
you.

### Attempting it blind

It is retryable, which is the saving grace: **Ubuntu boots either way**, so a
failed attempt costs a reboot and nothing else, and the outcome is checkable
over SSH:

```bash
ssh lestherll@192.168.0.220 'mokutil --sb-state; cat /sys/kernel/security/lockdown'
```

You want `SecureBoot disabled` and `[none] integrity confidentiality`. Until
you see both, nothing else in this guide will work.

The only live feedback you have while blind is the **Num Lock LED**. On a USB
keyboard the LED is host-driven — the firmware or kernel sends the report — so a
toggle proves that *something* is powered up and servicing keystrokes. That is
genuinely useful: it separates "sitting at a menu waiting for me" from "hung
before input" or "not powered". It does **not** tell you which screen you are
on, and it keeps working under Ubuntu and under Talos, so it can never confirm
which stage you reached. Only the network can do that ([§6](#6-verifying-blind)).

---

## 2. Mac-side preparation

**You do not need Docker or colima for any of this.** The Ubuntu guide needed a
container to produce a SHA-512 crypt hash and to remaster an ISO; neither
applies here. macOS `shasum` and `dd` cover everything. Keep colima for the one
optional case in [§5](#5-route-b--usb-stick-fallback) — and note that it *is*
correctly configured for amd64: `docker run --platform linux/amd64 alpine
uname -m` returned `x86_64` on 2026-08-29, so the running VM has Rosetta
(`colima start --vm-type=vz --vz-rosetta`).

### 2.1 talosctl, pinned

The version is not a choice. `ansible/roles/cli_tools/vars/main.yml` pins
`talos_version: "1.13.8"`, with the comment explaining that the client and the
node are one version rather than two. Homebrew would give you whatever is
current, so fetch the release asset directly:

```bash
mkdir -p ~/talos-worker0 && cd ~/talos-worker0
curl -LO https://github.com/siderolabs/talos/releases/download/v1.13.8/talosctl-darwin-arm64
shasum -a 256 talosctl-darwin-arm64
# expect: ede53ce2c8508fe3a95b80a3039ad8a07940a8d6a611d6a49d0154edfca766b8
chmod +x talosctl-darwin-arm64
sudo mv talosctl-darwin-arm64 /usr/local/bin/talosctl
talosctl version --client   # expect v1.13.8
```

macOS will quarantine the download; if Gatekeeper blocks it,
`xattr -d com.apple.quarantine /usr/local/bin/talosctl`.

### 2.2 The boot assets

Checksums below are from the release's own `sha256sum.txt`, read 2026-08-29.
Fetch only what your route needs.

| Asset | Size | SHA-256 | Needed by |
|---|---|---|---|
| `vmlinuz-amd64` | 19 MiB | `15b3590feed7a0c876dcffaa884522f31e172e4f07529731eca71713d0581ecd` | Route A |
| `initramfs-amd64.xz` | 82 MiB | `4013e4dbd27cede30749ed68d774566952f48f8ad3d9172115b969177cf48fad` | Route A |
| `metal-amd64.iso` | 320 MiB | `138138bb8a8b52cea250d53120b708dafc29a70ce2f7145789d9a05cf40bb2d9` | Route B |

All from `https://github.com/siderolabs/talos/releases/download/v1.13.8/`.

> **Correct for this guide, wrong for the fleet.** Stock release assets carry no
> system extensions, which is fine here — the end state is a machine in
> maintenance mode holding nothing. The moment this machine is meant to *join*
> ([§10](#10-joining-the-cluster)) the image has to come from an Image Factory
> schematic instead, because ADR §8.1 puts `siderolabs/iscsi-tools` and
> `siderolabs/util-linux-tools` (Longhorn) plus the Tailscale extension in it.
> Extensions can be added later in place — `talosctl upgrade --image
> factory.talos.dev/installer/<schematic>:v1.13.8` — so this is a "do it in the
> right order", not a "do it or rebuild". See
> [install-media-and-reprovisioning-notes.md](install-media-and-reprovisioning-notes.md).

### 2.3 Generate the throwaway config now, not later

Do this before touching the machine, so a `talosconfig` exists on disk from the
start — several `talosctl` invocations are happier with one present even when
using `--insecure`.

**No SOPS and no age key are needed anywhere in this guide.** That is not a
workaround; it follows from the scope. Nothing here joins a cluster, so nothing
here needs the real Talos PKI. The config generated below is a *fresh,
disposable* PKI whose only job is to carry `machine.install` to the node, and
[§9](#9-back-to-maintenance-mode--the-actual-end-state) destroys it again.

```bash
cd ~/talos-worker0
talosctl gen config homelab-worker-0-standalone https://192.168.0.220:6443 \
  --output-types controlplane,talosconfig \
  --output . \
  --install-disk /dev/sda \
  --install-image ghcr.io/siderolabs/installer:v1.13.8 \
  --with-docs=false --with-examples=false \
  --config-patch '{"machine":{"network":{"hostname":"homelab-worker-0"}}}'
```

Three of those arguments carry real weight:

- **`--install-image` must be pinned.** Its default is
  `ghcr.io/siderolabs/installer:latest` — verified in the v1.13.8 CLI
  reference. Left alone it would install whatever is current, quietly breaking
  the repo's pinning convention on the one artefact that ends up on the disk.
- **`--install-disk /dev/sda`** happens to be the default too, but state it.
  Confirm against reality in [§7](#7-confirming-you-are-about-to-wipe-the-right-disk)
  before applying.

  **Under Route B, replace it with a selector.** `/dev/sda` is positional, and
  Route B attaches a USB stick — a second block device, whose enumeration order
  against the SATA controller is not guaranteed. Add this patch and drop the
  flag, so the install targets the disk by identity rather than by position:

  ```
  --config-patch '{"machine":{"install":{"diskSelector":{"match":"disk.model == '\''MTFDDAK512MAY-1A'\''"}}}}'
  ```

  This is also what the rest of the repo does — `talos.tf`'s `UserVolumeConfig`
  blocks select by `disk.serial` under the heading *"the cluster knows disk
  ROLES, never disk PATHS"*. Route A has genuinely one disk and the flag is
  safe there; Route B is the fallback you reach for when the evening is already
  going badly, which is the worst moment to be relying on enumeration order.
- **`controlplane`, not `worker` — and this one is a trap.** A worker's `apid`
  does not have the Talos CA key; it obtains its serving certificate from
  `trustd` on a control-plane node (`generateWorker()` in
  `internal/app/machined/pkg/controllers/secrets/api.go` builds a trustd client
  to do it). Apply a worker config here, where no control plane is reachable,
  and after the install reboot **`apid` never gets a certificate and the node is
  unreachable by `talosctl` — permanently, and with no console to tell you
  why.** A control-plane config self-issues from the CA key it carries, so the
  node stays reachable. Nothing about this is visible in the config you
  generate; it only shows up as silence after the reboot.

  Do **not** run `talosctl bootstrap` at any point. There is no cluster here.
  Without bootstrap, `etcd` simply waits and the apiserver never starts; the
  node boots, is reachable, and does nothing else — which is exactly what is
  wanted for the few minutes before [§9](#9-back-to-maintenance-mode--the-actual-end-state).

Point the config at the node:

```bash
export TALOSCONFIG=~/talos-worker0/talosconfig
talosctl config endpoint 192.168.0.220
talosctl config node 192.168.0.220
```

### 2.4 Pre-flight the things that only fail later

The install pulls its installer image from the internet, during the one window
where you cannot read logs ([§6](#6-verifying-blind)). Check reachability while
you still have a shell:

```bash
ssh lestherll@192.168.0.220 'curl -sS -o /dev/null -w "%{http_code}\n" https://ghcr.io/v2/'
```

`401` is the success case here — the registry answering and demanding auth.
A hang or a DNS error is the thing to fix now, not after the disk is gone.

### 2.5 Before the wipe

- Copy anything off the machine you care about. There is no dump phase in this
  guide, deliberately, on the same reasoning as
  [talos-cutover-runbook.md](../talos-cutover-runbook.md).
- Note the MAC, `f4:93:9f:f2:59:82`. It is the constant across the wipe and how
  you will find the machine afterwards.
- If the router hands out `192.168.0.220` as a dynamic lease, **make it a
  reservation now**. Talos will present the same MAC, so a reservation makes the
  post-wipe address predictable instead of something you have to hunt for.
- Remove `homelab-worker-0` from the Tailscale admin console once you commit.
  The wipe takes the node key with it, and the device otherwise sits in the
  tailnet as a permanently-offline ghost.

---

## 3. Choosing a route

Both need Secure Boot already off.

| | Route A — kexec | Route B — USB |
|---|---|---|
| Physical trips | **none** | one (plug the stick in) |
| Reversible before install | **yes** — power-cycle returns you to Ubuntu untouched | yes, same |
| Extra hardware | none | the USB stick |
| Fails if | kexec is blocked, or the NIC does not survive the jump | the firmware will not boot the stick |

**Take Route A.** It needs no physical access at all and leaves the disk
completely untouched until you deliberately apply a config, so the whole thing
up to that point is a rehearsal you can abort with the power switch. Route B is
the fallback for when kexec will not go.

> **Route A is available exactly once.** It works because Ubuntu is still running
> and can jump to a new kernel. After the wipe there is no Ubuntu, so any *future*
> re-provision of this machine is Route B or a netboot mechanism — which is the
> question ADR §8.4 settles, and it settles it as "USB, and rarely". Rarely,
> because once Talos is on the disk, config changes, version upgrades, extension
> changes and even wiping the node back to maintenance mode are all API calls.
> [install-media-and-reprovisioning-notes.md](install-media-and-reprovisioning-notes.md) §1
> has the table.

---

## 4. Route A — kexec (preferred)

`kexec` boots a new kernel from the running one, without going through firmware.
Talos comes up **in RAM**, in maintenance mode; `/dev/sda` is not touched and is
no longer mounted by anything.

The kernel command line is not guesswork — it is what the Talos Image Factory
serves for this exact version and platform, read from
`https://pxe.factory.talos.dev/pxe/<bare-schematic>/v1.13.8/metal-amd64` on
2026-08-29:

```
talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on
consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1
module.sig_enforce=1 proc_mem.force_override=never
```

Fetch the assets onto the target and verify them there:

```bash
ssh lestherll@192.168.0.220 '
set -e
cd /home/lestherll
curl -LO https://github.com/siderolabs/talos/releases/download/v1.13.8/vmlinuz-amd64
curl -LO https://github.com/siderolabs/talos/releases/download/v1.13.8/initramfs-amd64.xz
sha256sum vmlinuz-amd64 initramfs-amd64.xz
'
```

Compare against the table in [§2.2](#22-the-boot-assets). A truncated
`initramfs` produces a kernel panic on a screen you cannot see, which is
indistinguishable from every other way this can fail — so check it here.

Then load and jump. `sudo` will prompt, so this needs `-t`:

```bash
ssh -t lestherll@192.168.0.220 '
sudo kexec -l /home/lestherll/vmlinuz-amd64 \
  --initrd=/home/lestherll/initramfs-amd64.xz \
  --command-line="talos.platform=metal console=tty0 init_on_alloc=1 slab_nomerge pti=on consoleblank=0 nvme_core.io_timeout=4294967295 printk.devkmsg=on selinux=1 module.sig_enforce=1 proc_mem.force_override=never"
'
```

**Absolute paths, not `~`** — and for the same reason `dd` needs one in
[§5.1](#51-flash-the-iso). A shell expands `~` at the start of a word, but
`--initrd=~/initramfs-amd64.xz` is not the start of a word, so the tilde stays
literal and `kexec` fails with `No such file or directory`. Loud rather than
silent, but it wastes a round trip.

If that returns cleanly, the hard part is over — the kernel is staged in memory
and lockdown did not veto it. Now trigger it:

```bash
ssh -t lestherll@192.168.0.220 'sudo systemctl kexec'
```

Your SSH session drops. That is the expected and only signal.

`systemctl kexec` rather than `kexec -e` on purpose: it runs the normal
shutdown, unmounting filesystems, before jumping. `kexec -e` jumps immediately
and leaves the Ubuntu filesystem dirty. It does not matter for a disk about to
be wiped — but it matters a great deal if you are doing a rehearsal run and
intend to power-cycle back into Ubuntu.

Then go to [§6](#6-verifying-blind).

### What can go wrong here

- **`kexec -l` fails with `Operation not permitted`.** Lockdown. Secure Boot is
  still on — go back to [§1](#1-the-one-step-that-genuinely-needs-a-display) and
  re-check `cat /sys/kernel/security/lockdown`.
- **The machine goes quiet and never comes back.** kexec skips firmware
  re-initialisation, so a device left in an odd state by Ubuntu can fail to come
  up under the new kernel. On this machine the one that matters is the Realtek
  NIC: if it does not initialise, Talos is running perfectly and is completely
  unreachable, with no symptom other than silence. **A cold power-cycle is the
  fix** — firmware re-POSTs everything, and since nothing was written to disk
  you land back in Ubuntu with nothing lost. If it happens twice, switch to
  Route B, which boots through firmware and does not have this failure mode.
- **RAM.** Talos runs its root filesystem from memory. 3.2 GiB is comfortable
  for maintenance mode, but it is the same 3.2 GiB that
  [multi-node-ha-design-notes.md §3.1](multi-node-ha-design-notes.md) calls
  marginal for a control-plane node later.

---

## 5. Route B — USB stick (fallback)

### 5.1 Flash the ISO

The Talos metal ISO is a hybrid image; `dd` is all it needs, and no remastering
step exists here — unlike the Ubuntu install, Talos takes its config over the
network afterwards rather than baked into the media. (It *can* be baked in;
[§5.3](#53-optional--unattended-install-config-on-a-second-stick) covers that,
and explains why it is not the default.)

For a machine that will join the cluster, take the ISO from the Image Factory
schematic rather than the release — `https://factory.talos.dev/image/<schematic>/v1.13.8/metal-amd64.iso`
— per the call-out in [§2.2](#22-the-boot-assets).

```bash
cd ~/talos-worker0
curl -LO https://github.com/siderolabs/talos/releases/download/v1.13.8/metal-amd64.iso
shasum -a 256 metal-amd64.iso
# expect: 138138bb8a8b52cea250d53120b708dafc29a70ce2f7145789d9a05cf40bb2d9
```

**Re-identify the stick every time.** `/dev/disk4` is where the Kingston
DataTraveler landed previously; with the stick unplugged on 2026-08-29
`diskutil list external` returned nothing at all, and the node number moves with
what else is attached. This is the step where a mistake wipes the wrong machine:

```bash
diskutil list external
diskutil info /dev/diskN | grep -E "Device / Media Name|Disk Size|Device Location|Removable"
```

Want `Device Location: External`, `Removable Media: Yes`, and a name and size
you recognise as the Kingston. Then:

```bash
diskutil unmountDisk /dev/diskN
sudo dd if=/Users/lestherll/talos-worker0/metal-amd64.iso of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

The same four `dd` traps from [headless-ubuntu.md](headless-ubuntu.md) apply
unchanged: absolute path (zsh will not expand `~` after `if=`), `rdiskN` not
`diskN`, no `status=progress` on macOS (Ctrl-T for a status line), and
`Resource busy` means macOS remounted it — unmount again.

### 5.2 Boot it without a firmware trip

Plug the stick in, then use the persistent `Boot0006 Generic Usb Device` entry
from [§0](#0-what-was-measured-on-this-machine) as a **one-shot** boot target:

```bash
ssh -t lestherll@192.168.0.220 'sudo efibootmgr -n 0006 && sudo efibootmgr | head -3'
ssh -t lestherll@192.168.0.220 'sudo systemctl reboot'
```

`BootNext` is consumed by a single boot attempt, which makes this self-recovering
in a specific and useful way: **if the USB does not boot, the firmware falls
straight through to Ubuntu.** So SSH answering again a couple of minutes later
is not ambiguity — it is a definite report that the stick was not booted. Check
the stick, or check that Secure Boot really is off.

Verify `Boot0006` still exists before relying on it; firmware occasionally
regenerates removable-media entries.

> **`BootNext` covers the boot you asked for, not the one after it.** It is
> consumed by a single boot attempt, so the *post-install* reboot falls back to
> `BootOrder` — which on this machine is `0000,000A,000B,0006,...`, i.e. a
> dangling Ubuntu entry, two PXE timeouts, and then the USB stick you are still
> holding in the slot. With the stick in, that boots the installer again. It does
> **not** reinstall (see the footnote at the end of [§8](#8-installing-to-the-ssd)),
> but it is why [§9](#9-back-to-maintenance-mode--the-actual-end-state) ends with
> "pull the USB first".

### 5.3 Optional — unattended install, config on a second stick

The Ubuntu install on this machine was zero-touch: an `autoinstall.yaml` baked
into the ISO, plug in, power on, walk away. Talos has an equivalent, and it is
worth knowing about even if you do not use it here.

`talos.config=metal-iso` makes Talos *"load the machine configuration from any
block device with a filesystem label of `metal-iso`"*, reading `config.yaml` at
that filesystem's root. Both the label and the path are hardcoded in Talos today.
The kernel argument is set on the image through the Image Factory schematic's
`customization.extraKernelArgs`. So:

- **stick 1** — the ISO, built from a schematic carrying
  `talos.config=metal-iso`
- **stick 2** — any small volume labelled `metal-iso`, holding `config.yaml`

Plug both in, boot, and the machine installs itself with no `apply-config` and no
network dependency beyond the installer image pull.

**Why this guide still defaults to [§8](#8-installing-to-the-ssd)'s
`apply-config`.** Three reasons, in order:

- The config on stick 2 is real PKI on a physical object. That beats putting it
  on the wire, but it has to be destroyed afterwards like everything else in
  [§9](#9-back-to-maintenance-mode--the-actual-end-state).
- **macOS uppercases FAT volume labels.** `diskutil eraseVolume FAT32 metal-iso`
  stores `METAL-ISO`, and Talos matches the label literally; whether that match is
  case-sensitive is **not verified**. The failure is benign and legible — config
  not found, machine sits in maintenance mode, fall back to `apply-config` — but
  it is one more thing to get wrong blind.
- It attaches a **third** block device. `--install-disk /dev/sda` is already
  wrong under Route B; with two sticks the `diskSelector` patch from
  [§2.3](#23-generate-the-throwaway-config-now-not-later) is the only safe form.

**Not an option: `talos.config.inline`.** It takes a zstd-compressed,
base64-encoded config directly on the kernel command line, but that line is
capped at 4096 bytes and the docs scope it to "small configuration documents". A
control-plane config carrying PKI is not one.

---

## 6. Verifying blind

Nothing here needs a screen. The signals, in the order they become available:

**1 — ARP / DHCP.** Talos brings networking up early and presents the same MAC.

```bash
arp -an | grep -i 'f4:93:9f:f2:59:82'
```

Confirms the machine is powered, booted far enough to run a network stack, and
on the LAN. Says nothing about *what* booted.

**2 — the port pair. This is the discriminator.** Talos has no SSH; `apid`
listens on TCP **50000** (`ApidPort` in `pkg/machinery/constants/constants.go`).
Ubuntu is the exact inverse.

```bash
nc -z -G 3 192.168.0.220 22    && echo "22 open — still Ubuntu"
nc -z -G 3 192.168.0.220 50000 && echo "50000 open — Talos apid"
```

| 22 | 50000 | Meaning |
|---|---|---|
| open | closed | Ubuntu. The jump did not happen, or fell back. |
| closed | **open** | **Talos, maintenance mode. Success.** |
| closed | closed | Something non-Ubuntu booted but `apid` is not serving. Give it two minutes; after that treat it as failed. |
| open | open | Not a state this machine produces — check you are talking to the right host. |

**3 — talosctl answers.** The proof, not just an inference:

```bash
talosctl --nodes 192.168.0.220 --insecure version
talosctl --nodes 192.168.0.220 --insecure get disks
```

`version` should report the node at **v1.13.8**, matching the client. `get
disks` should list one disk, `sda`, `MTFDDAK512MAY-1A`, ~477 GB.

**4 — Num Lock.** Only useful in the case the network cannot reach: no ARP
entry at all. Press Num Lock and watch the LED. It toggling means the machine is
powered and *something* is servicing the keyboard — firmware menu, a booted
kernel, anything. It not toggling means nothing is: no power, or a hang before
input handling. It cannot tell you which stage you are at, and it works
identically under firmware, Ubuntu and Talos.

### The blind spot, stated plainly

**A machine sitting at a firmware screen and a machine that is dead look
identical from the network.** Neither answers ARP, ping, 22 or 50000. If you
have no ARP entry after three minutes, Num Lock is the only remaining bit of
information you have, and it distinguishes only "alive at a prompt" from "not".

### A correction to the design note

[multi-node-ha-design-notes.md §3.1](multi-node-ha-design-notes.md) states that
`talosctl dmesg | logs | services | get | support` "all still work, including in
maintenance mode". Checked against the v1.13 CLI reference at the v1.13.8 tag:
**only seven commands accept `--insecure`** — `apply-config`, `get`, `meta`,
`reset`, `version`, `wipe disk`, and `image cache-create`. `dmesg`, `logs`,
`services` and `support` do not, and in maintenance mode there is no client
certificate to authenticate with, so they are unavailable.

The practical consequence is narrower than it sounds but sharp: **`get` covers
most inspection, but you cannot read kernel or service logs from a node in
maintenance mode.** That matters exactly once, in [§8](#8-installing-to-the-ssd).

---

## 7. Confirming you are about to wipe the right disk

Everything up to here is reversible with a power switch. This is the line.

```bash
talosctl --nodes 192.168.0.220 --insecure get disks
```

There is one disk **in this machine** and the model string is distinctive, so
the confirmation is unusually strong: **`sda`, `MTFDDAK512MAY-1A`, ~477 GB.**

**Under Route A that is the whole story. Under Route B it is not** — the USB
stick you booted from is a disk too, and it will appear here. So a second entry
is expected on Route B and alarming on Route A, and the check to make is not
"how many entries" but "does the entry I am about to install to carry the model
string above". The config in [§2.3](#23-generate-the-throwaway-config-now-not-later)
names `/dev/sda` positionally and will take whatever is at that name, which is
why §2.3 swaps the flag for a model-matched `diskSelector` on Route B. If you
see a second entry on Route A, stop and work out where it came from before going
further.

---

## 8. Installing to the SSD

```bash
talosctl --nodes 192.168.0.220 --insecure apply-config \
  --file ~/talos-worker0/controlplane.yaml
```

The node validates the config, writes it, runs the install sequence — pulling
`ghcr.io/siderolabs/installer:v1.13.8`, wiping `/dev/sda`, writing the Talos
partitions and a UEFI boot entry — and reboots into it.

> **This is the one genuinely blind window in the whole procedure.**
> The node is in maintenance mode throughout the install, so per
> [§6](#6-verifying-blind) `dmesg` and `logs` are unavailable, and there is no
> console. If the installer image cannot be pulled, or the disk write fails, you
> get **no error and no reboot** — just a node that stays in maintenance mode
> indefinitely. That is why [§2.4](#24-pre-flight-the-things-that-only-fail-later)
> checks registry reachability beforehand: it is the failure this window hides.

What to watch, from the Mac:

```bash
# port 50000 drops (reboot), then returns a few minutes later
while true; do
  nc -z -G 2 192.168.0.220 50000 && echo "$(date +%T) up" || echo "$(date +%T) down"
  sleep 5
done
```

Expect: up → down (install finished, rebooting) → up. The drive activity LED is
a corroborating signal during the write if you can see the case.

**Ten minutes with no drop means the install did not start.** At that point you
have exhausted the blind options and need a display to read the reason.

Once it is back, you have authentication and the diagnostics open up:

```bash
export TALOSCONFIG=~/talos-worker0/talosconfig
talosctl version                  # node no longer says "maintenance"
talosctl dmesg | tail -50         # works now — you have a client cert
talosctl get disks
```

The node will be visibly unhappy — `kubelet` looping, no apiserver — because it
is a control-plane node for a cluster that was never bootstrapped. That is
expected and about to be thrown away.

> **A boot-order footnote — revised 2026-08-30, because the original was
> optimistic.** The install destroys the partition `Boot0000` pointed at, so that
> entry becomes dangling; the firmware then walks `000A, 000B` — the two PXE
> entries — before anything else. With no PXE server on the LAN each times out,
> which can add 30–60 seconds to every boot and, on some firmware, drops to a
> network-boot prompt instead of falling through. Disabling network boot during
> the [§1](#1-the-one-step-that-genuinely-needs-a-display) firmware trip prevents
> that for free.
>
> What this footnote *used* to say — *"Talos adds its own entry during the install
> and firmware usually places new entries first, so this often resolves itself"* —
> is not safe to lean on. Talos 1.11 briefly created its UEFI entry **and** moved
> it to the front; that broke some systems and was changed, so current Talos
> **creates the entry only if it does not already exist and does not modify the
> boot order at all.** What actually makes the machine boot afterwards is the
> fallback path: Talos writes `EFI/BOOT/BOOTX64.EFI` on the ESP, and firmware
> discovers it. That is the normal layout and the normal behaviour — but it is
> **not verified on this machine**, and on a box with no video an unbootable NVRAM
> state is the worst outcome in this guide.
>
> Two mitigations, both cheap. Pre-empt from Ubuntu before the wipe with
> `sudo efibootmgr -o 0000,0006` so the PXE timeouts are out of the path. And do
> not throw the stick away: media that boots is the recovery path for exactly this
> failure, since a netbooted or ISO-booted Talos reaches maintenance mode without
> touching the disk entry at all.

---

## 9. Back to maintenance mode — the actual end state

The throwaway control-plane identity has done its job. Wipe it, keeping the
boot assets, so the machine comes back up **from its own disk, in maintenance
mode, holding nothing**:

```bash
talosctl --nodes 192.168.0.220 reset \
  --system-labels-to-wipe STATE,EPHEMERAL \
  --graceful=false \
  --reboot
```

- `--system-labels-to-wipe STATE,EPHEMERAL` wipes the config and the ephemeral
  data while leaving the boot partitions intact — that is the difference between
  "returns to maintenance mode" and "unbootable brick". The default
  `--wipe-mode all` would take the boot partitions too.
- `--graceful=false` is required. Graceful reset tries to cordon the node and
  leave etcd; there is no cluster, so it would fail.

Verify, back to `--insecure` because there is no identity any more:

```bash
unset TALOSCONFIG
nc -z -G 3 192.168.0.220 22    || echo "22 closed — no Ubuntu"
nc -z -G 3 192.168.0.220 50000 && echo "50000 open"
talosctl --nodes 192.168.0.220 --insecure version   # v1.13.8, maintenance mode
talosctl --nodes 192.168.0.220 --insecure get disks
```

**Then power-cycle it once and re-run those checks.** This is the step that
actually proves the goal: it confirms Talos is booting *from the SSD* rather
than from RAM (Route A) or the stick (Route B). Pull the USB first if you took
Route B — and note *why* that matters, because the obvious fear is the wrong one:
leaving it in does **not** cause a reinstall loop. Talos booted from media on a
machine that already has Talos installed adopts that disk as its system disk and
assumes it is installed. The real damage is quieter — the node then runs the
*stick's* kernel with the *disk's* state, so its version is decoupled from what
is on disk and `talosctl upgrade` stops meaning what you think it means. Without this power-cycle you have verified nothing about persistence —
under Route A in particular, a machine that never had anything written to disk
passes every check above right up until it is restarted.

Finally, destroy the throwaway PKI. It is disposable but it is real:

```bash
rm -P ~/talos-worker0/controlplane.yaml ~/talos-worker0/talosconfig
```

---

## 10. Joining the cluster

Not today, and not because of anything above. The blocker is on the cluster's
side and is a design decision rather than a gap.

### 10.1 The prerequisite

[multi-node-ha-design-notes.md §2.1](multi-node-ha-design-notes.md) records it:
the control plane is `10.10.0.10` on a `forward mode='nat'` libvirt network,
host-only and unroutable from the LAN — the property that keeps machine 1's
`ufw` rules meaningful. A Talos node on `192.168.0.0/24` cannot reach it, so
there is nothing on the wire to join.

That changes with the **bridged-network + VIP rebuild** in §4 of that note. It
is a single, deliberate rebuild of machine 1 — Talos bootstrap manifests do not
retrofit a running cluster (AGENT.md; `talos.tf:200`) — and everything the
rebuild is needed for has to land inside it. Two things about it govern
everything below:

- **The endpoint changes.** `https://10.10.0.10:6443` becomes a VIP on
  `192.168.0.0/24`. The address is still an open question in §7 of that note;
  it must be settled before a worker config can be generated, because the
  endpoint is baked into that config.
- **This machine joins as a *worker*.** Per §1 of the design note, two
  control-plane nodes tolerate exactly as many failures as one while doubling
  the ways to lose quorum. Worker until a third machine exists, then all three
  are promoted together — and Talos has no in-place promotion, so this node gets
  wiped and rejoined at that point. That is cheap, and the reason to make node
  addition repeatable rather than perfect.

### 10.1.1 Decide the Tailscale extension before this install, not after

A second prerequisite, added 2026-08-30, and it is a *timing* constraint rather
than a blocker.

Once this machine is a cluster node, the only ways to reach it with `talosctl`
are the LAN, or a shell on machine 1 first — because unlike the VM it has no
Ubuntu host underneath it carrying a tailnet identity.
`terraform/scripts/stage-talos-image.sh` rejects the Tailscale system extension
for the VM on exactly that reasoning — *"Tailscale stays on the host"* — and
that reasoning has no equivalent here. **This machine is the one that forces the
decision.**
[fleet-provisioning-design-notes.md §6](fleet-provisioning-design-notes.md)
makes the case and recommends taking it.

Why it lands here rather than later: **Talos system extensions change only at
install or upgrade, never by machine config alone.** If the extension is wanted,
`--install-image` in [§10.3](#103-generating-the-worker-config) must be the
factory image (`factory.talos.dev/installer/<schematic-id>:v1.13.8`) rather than
the plain `ghcr.io/siderolabs/installer:v1.13.8` — and the node needs an
`ExtensionServiceConfig` carrying `TS_AUTHKEY`, plus **its tailnet address in
`machine.certSANs`** alongside `192.168.0.220`, or every authenticated
`talosctl` call fails exactly as `talos.tf:122` describes.

Decide it wrong and the cost is one more reinstall of this machine. That is not
expensive — but it is avoidable, and knowing that is the entire point of writing
it down before §10.3 rather than after.

Until the rebuild, the right thing to do with this machine is exactly what
[§9](#9-back-to-maintenance-mode--the-actual-end-state) leaves it doing: sitting
in maintenance mode, reachable, costing nothing.

### 10.2 Getting the real PKI — and where that work happens

A node joins by being handed a config generated from the **cluster's own Talos
secrets**. Those live SOPS-encrypted at
`terraform/clusters/homelab/talos-secrets.sops.yaml` — the second copy of the
PKI in talosctl's spelling, which exists precisely for this kind of out-of-band
work (see the comment in `.sops.yaml`).

**Do this on machine 1, not the Mac.** `sops` and the age key are there; the Mac
has neither. Copying the age key over would spread D12's single root key onto a
second device to save one SSH hop, which is a bad trade. Following AGENT.md's
recipe:

```bash
# on machine 1
sops --decrypt terraform/clusters/homelab/talos-secrets.sops.yaml > /tmp/secrets.yaml
```

Shred `/tmp/secrets.yaml` when finished. Everything in §10.3 runs in the window
it exists.

You also want a `talosconfig` for the *real* cluster, which the same recipe
produces — and note it is a different file from the disposable one in
[§2.3](#23-generate-the-throwaway-config-now-not-later), which by then should
already be gone.

### 10.3 Generating the worker config

```bash
# on machine 1, with /tmp/secrets.yaml present
talosctl gen config homelab https://<VIP>:6443 \
  --with-secrets /tmp/secrets.yaml \
  --output-types worker \
  --output /tmp/worker0.yaml \
  --install-disk /dev/sda \
  --install-image ghcr.io/siderolabs/installer:v1.13.8 \
  --kubernetes-version 1.36.2 \
  --with-docs=false --with-examples=false \
  --config-patch '{"machine":{"certSANs":["192.168.0.220"],"kubelet":{"extraArgs":{"rotate-server-certificates":"true"}},"network":{"hostname":"talos-worker-01"}}}'
```

The cluster name `homelab`, `--kubernetes-version 1.36.2` and the pinned
installer all come from `terraform/clusters/homelab/main.tf` and
`ansible/roles/cli_tools/vars/main.yml`. They are not defaults to accept — a
worker on a different Kubernetes minor is a slow-burning problem.

If [§10.1.1](#1011-decide-the-tailscale-extension-before-this-install-not-after)
went the other way, `--install-image` here is the factory image instead, and
`certSANs` gains this node's tailnet address. Both are install-time choices —
this command is the last point at which changing them is free.

> **`talosctl gen config` renders upstream defaults, not this cluster's
> machine config.** The secrets file gives the node its *identity*; it does not
> carry the per-machine settings `terraform/modules/talos-cluster/` patches in.
> Cluster-level settings arrive from the control plane, but **machine-level ones
> do not, and their absence is silent.** Two are load-bearing here, which is why
> the `--config-patch` above sets both:
>
> - **`machine.certSANs`.** Talos issues the `apid` certificate covering only
>   what it is told, plus loopback. Omit this and the cert carries `DNS:<hostname>,
>   IP:127.0.0.1`, so every authenticated `talosctl` call to the node fails with
>   *"certificate is valid for 127.0.0.1, not 192.168.0.220"*. The verbatim
>   warning is at `talos.tf:122`, where it was learned the hard way — the
>   equivalent failure made `talos_machine_bootstrap` **hang rather than error**.
> - **`machine.kubelet.extraArgs.rotate-server-certificates`.** Without it the
>   kubelet on this node serves a self-signed certificate on `:10250`,
>   metrics-server's scrape fails x509 validation, and `kubectl top node
>   talos-worker-01` returns *"metrics not available"* — with the reason visible
>   **only in the metrics-server log**. The other half, the
>   `kubelet-serving-cert-approver` in `infrastructure/metrics-server/`, is
>   already deployed cluster-wide, so this flag is the only missing piece. Both
>   halves or neither (`talos.tf:133`).
>
> If a third machine ever follows, this hand-patched config is the argument for
> doing §4.2 of the design note properly — parameterising the Terraform module
> over a node list — rather than repeating this by hand.

### 10.4 Applying it

The node is in maintenance mode, so this is the same insecure call as
[§8](#8-installing-to-the-ssd) — no client certificate needed, because it has no
identity yet:

```bash
talosctl --nodes 192.168.0.220 --insecure apply-config --file /tmp/worker0.yaml
```

**Do not run `talosctl bootstrap`.** It initialises etcd and is a control-plane
operation; running it against a worker, or a second time against this cluster,
is not something you want to discover the consequences of.

The node installs, reboots, and this time the reboot is not blind: a worker's
`apid` gets its serving certificate from `trustd` on the control plane
([§2.3](#23-generate-the-throwaway-config-now-not-later)), which now exists and
is reachable. That is the same mechanism that would have left the node
permanently silent had a worker config been applied during the install phase —
the trap disappears the moment there is a control plane on the same network.

### 10.5 Verifying the join

From machine 1, with the real `talosconfig`:

```bash
talosctl --nodes 192.168.0.220 version          # authenticated now, not --insecure
talosctl --nodes 192.168.0.220 dmesg | tail -50 # available now, unlike maintenance mode
kubectl get nodes -o wide                       # talos-worker-01 → Ready
kubectl get csr                                 # kubelet-serving CSRs Approved,Issued
kubectl -n kube-system get pods -o wide --field-selector spec.nodeName=talos-worker-01
kubectl top node talos-worker-01                # proves the rotate-server-certificates half
```

`kubectl get csr` is worth its line: a `kubernetes.io/kubelet-serving` CSR stuck
`Pending` means the approver is not doing its job, and the symptom downstream is
identical to never having set the kubelet flag at all.

### 10.6 What breaks the first time a workload lands there

Adding a node changes scheduling for the whole cluster, and four of this
platform's assumptions are single-node ones.

- **PVCs will fail on the new node, and that is the good outcome.** All three
  provisioners in `infrastructure/storage/provisioners.yaml` carry a
  `nodePathMap` naming exactly one node, `talos-cp-01`, with no
  `DEFAULT_PATH_FOR_NON_LISTED_NODES`. A pod with a PVC scheduled onto
  `talos-worker-01` gets no path and provisioning fails rather than silently
  writing to the wrong disk. The `fast` and `bulk` entries cannot simply be
  extended to the new node either — it has **one** disk and no `/var/mnt/bulk`
  ([design note §2.4](multi-node-ha-design-notes.md)). Decide deliberately:
  keep stateful workloads pinned to `talos-cp-01`, or give the new node its own
  node-restricted class.
- **`allowSchedulingOnControlPlanes` is still `true`** (`talos.tf:187`), set as
  a single-node accommodation. It stays harmless but stops being *right* the
  moment a real worker exists — revisit it in the same change.
- **Cilium and pod age.** AGENT.md's rule applies per node: a pod that predates
  the Cilium agent on its node is unmanaged by it — still running, still
  reachable, simply not subject to `NetworkPolicy`, with nothing on the pod
  saying so. On a freshly joined node the DaemonSet and the first workloads race.
  Check `kubectl exec -n kube-system ds/cilium -- cilium endpoint list` on the
  new node before believing any policy applies there.
- **PodSecurity is `baseline` cluster-wide.** The `storage` and `observability`
  namespaces already carry the `privileged` enforce label, so node-exporter and
  the provisioner helper pods will schedule on the new node fine. Anything else
  needing `hostPath` or `hostNetwork` will not, and per AGENT.md the failure
  misreports itself as a HelmRelease timing out on a DaemonSet with no pod to
  inspect.

### 10.7 Reaching it day to day

Once joined there is nothing special about this node: `talosctl --nodes
192.168.0.220` with the cluster talosconfig, and `kubectl` as usual. There is no
SSH and no shell, so `talosctl dmesg | logs | services | get | support` are the
whole diagnostic surface — and now that the node has an identity, all of them
work, which was not true in maintenance mode
([§6](#a-correction-to-the-design-note)).

**"As usual" assumes you are on the LAN, or on machine 1.** Worth being explicit
about, because it is the assumption that decides whether
[§10.1.1](#1011-decide-the-tailscale-extension-before-this-install-not-after)
was worth taking:

- **`kubectl` from anywhere** already works over the tailnet, through the
  `kube-apiserver-ci` `ProxyGroup` and a Google-issued OIDC token (LES-104).
  But that proxy runs *inside* the cluster, so it is unavailable in exactly the
  situations you want it — which makes `talosctl` the break-glass path rather
  than a parallel convenience.
- **`talosctl` from anywhere** is the part that does not exist by default.
  Without the extension, reaching this node means SSH to machine 1 first — so
  the bare-metal node's only diagnostic path runs through the *other* machine,
  and "machine 1 is down" is a case you actively want `talosctl` for.
- **One reachable node is enough for the whole cluster.** `talosctl --endpoints
  <reachable node> --nodes <target>` proxies through apid on the endpoint, so
  this is not a per-node cost. The catch is the same one as everywhere else in
  this guide: the target's apid certificate must cover the address you name in
  `--nodes`.

The one case none of that covers is unchanged from
[design note §3.1](multi-node-ha-design-notes.md): **a node that will not boot,
or has no network, needs a physical display.** Everything in this guide reduces
how often that happens; nothing eliminates it.

---

## Troubleshooting

- **`kexec -l` says `Operation not permitted`.** Lockdown, i.e. Secure Boot is
  still on. `cat /sys/kernel/security/lockdown` — not the
  `kexec_load_disabled` sysctl, which reads `0` regardless
  ([§1](#1-the-one-step-that-genuinely-needs-a-display)).
- **Ubuntu comes back after a `BootNext` reboot.** The USB was not booted. Under
  Route B this is a definite answer, not an ambiguous one. Secure Boot still on,
  a bad flash, or `Boot0006` no longer present.
- **ARP entry appears, nothing on 22 or 50000.** Something non-Ubuntu is up but
  `apid` is not serving. Wait two minutes; then assume the kernel panicked or
  the boot stalled. Under Route A, power-cycle back into Ubuntu — the disk is
  untouched.
- **No ARP entry at all.** Either at a firmware screen or dead; the network
  cannot tell you which. Num Lock is the only discriminator, and it only
  distinguishes alive-at-a-prompt from not
  ([§6](#the-blind-spot-stated-plainly)).
- **`apply-config` succeeded, node never rebooted.** The install did not start
  or did not finish, most likely the installer image pull. There is no way to
  read the reason without a display ([§8](#8-installing-to-the-ssd)).
- **Node unreachable by `talosctl` after the install reboot, forever.** You
  applied `worker.yaml`. Its `apid` is waiting on a `trustd` that does not
  exist, so it has no serving certificate and never will
  ([§2.3](#23-generate-the-throwaway-config-now-not-later)). Recovery is a
  reinstall via Route A or B — the disk state is irrelevant once you boot from
  RAM or USB again.
- **Boots got slow after the install.** Stale PXE entries timing out
  ([§8](#8-installing-to-the-ssd)).
- **`talosctl` complains about a missing config while using `--insecure`.**
  Point it at the generated one: `export TALOSCONFIG=~/talos-worker0/talosconfig`.
  This is why [§2.3](#23-generate-the-throwaway-config-now-not-later) generates
  it before anything else.
