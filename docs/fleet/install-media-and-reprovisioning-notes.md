# Install media and re-provisioning — how Talos gets onto a machine, and how often

Resolves [ADR 0001](../adr/0001-single-model-talos-fleet.md) §8.4 (netboot
mechanism). Written 2026-08-30, against the live LAN and the vendors' own docs;
every claim below was checked rather than recalled, and the ones that were not
are labelled.

The short version: **§8.4 was asking the wrong question first.** It compared
serving mechanisms (iPXE vs Tinkerbell) before establishing how often a machine
actually needs one. It needs one on first install and almost never again, which
makes the mechanism a much smaller decision than the survey's framing implied —
and makes a USB stick the right answer for machines 1 and 2.

---

## 0. What was measured

| | |
|---|---|
| LAN | `192.168.0.0/24`; the router at `192.168.0.1` is the only DHCP server |
| Mac (operator, never a node) | `192.168.0.44`, **on Wi-Fi `en0`** — no built-in Ethernet, macOS 26.5.2, no dnsmasq installed |
| Machine 2 | wired `192.168.0.220`, MAC `f4:93:9f:f2:59:82`, UEFI, Secure Boot **on**, **no video output**, persistent `Boot0006 Generic Usb Device` entry plus two PXE entries |
| Machine 1 | the live cluster (Ubuntu + libvirt), so it cannot serve its own re-provision |

Two of those decide most of what follows. The operator is on Wi-Fi, so anything
depending on DHCP-adjacent broadcast traffic crossing the AP bridge is a risk
rather than a given. And machine 2 has no display, so **every failure mode has to
be legible over the network or it is not legible at all**.

---

## 1. The reframing: media is a bootstrap, not an operating mechanism

Terraform's `talos_machine_configuration_apply` talks to `apid` on port 50000.
That port exists only once Talos is running. So boot media exists to get Talos
onto a machine that does not have it — and after that, `terraform apply` really
is the interface.

| Change | Mechanism | Media? |
|---|---|---|
| Any machine-config field — network, sysctls, kubelet, `certSANs`, user volumes, VIP | `talos_machine_configuration_apply` | no |
| Talos version | `talosctl upgrade` (A/B slots, in place) | no |
| Kubernetes version | `talosctl upgrade-k8s` | no |
| **Add or remove a system extension** | `talosctl upgrade --image factory.talos.dev/installer/<schematic>:<version>` | **no** |
| Return a node to a clean, unconfigured state | `talosctl reset` | no |
| Rotate the cluster CA | documented multi-step bundle procedure | no, but it is a procedure |
| **Change the install disk** | not applicable — see §2 | **yes** |
| Bare metal → Talos, first time | — | **yes** |
| Disk or machine replacement; a node that will not boot | — | **yes** |

Apply modes are `auto`, `no-reboot`, `reboot`, `staged` and `try`, with a
whitelist of fields that avoid a reboot and everything else taking one. **The
worst case for a configuration change is a reboot, not a reinstall.**

`talosctl reset` is what collapses most of what would otherwise be called
"reinstall". [headless-talos-install.md](headless-talos-install.md) §9 already
uses it: `--system-labels-to-wipe STATE,EPHEMERAL` destroys identity and data,
leaves the boot partitions, and the node returns to maintenance mode ready for a
different config. Moving a node from cluster A to cluster B is an API call.

> **The one place "just apply it" silently does nothing is already recorded in
> AGENT.md.** Talos bootstrap manifests — kube-proxy, CoreDNS, flannel — re-render
> on a machine-config change and are never pushed onto an object that already
> exists. Terraform reports success, `talosctl get manifest` shows the new render,
> and the live object sits at its original generation. It is the exception worth
> remembering precisely because it looks like it applied.

---

## 2. What still needs media

Three cases, and they are all either once-per-machine or hardware events:

1. **First install.** No Talos, no API, nothing to apply to.
2. **Changing the install disk.** This one is a genuine trap: the installer only
   runs when no existing installation is found, so editing
   `machine.install.diskSelector` on an installed node *does nothing* — the node
   keeps its old disk and never reports a problem. Relocating an install means
   wiping first (`talosctl wipe disk`, or booting media), not applying a config.
3. **Hardware.** A replaced disk, a replaced machine, or a node that will not
   boot at all.

(2) is the reason [headless-talos-install.md](headless-talos-install.md) §2.3
pins the install target by `disk.model` rather than by `/dev/sda`: the selector
you install with is the one you keep.

---

## 3. The delivery options, and the verdict

The brief was: **the router stays the only thing handing out addresses.** All
four options below honour that; they differ in whether anything else on the LAN
answers DHCP at all.

| | What runs where | Verdict |
|---|---|---|
| **A — USB media** | nothing; the stick carries everything | **chosen for machines 1–2** |
| **B — iPXE stick + HTTP on the Mac** | a static file server on the Mac | designed (§5), deferred |
| **C — dnsmasq proxyDHCP on the Mac** | a root daemon on UDP 67/69/4011 | rejected here, kept as fallback |
| **D — router DHCP options 66/67** | the router | rejected outright |

**D is rejected on principle, not capability.** Even where a consumer router
exposes `next-server`/boot-file fields, it is untracked state in a device outside
git, it applies to every PXE-capable thing on the LAN at once, and it dies with
the router. That is ADR §2's failure modes (2) and (3) in one setting.

**C is the textbook "cannot touch the router" answer and is still wrong here.**
`dhcp-range=192.168.0.0,proxy` plus `port=0` leases nothing and serves no DNS; it
only adds boot options alongside the router's own offer, which satisfies the
brief literally. It loses on four stacked risks, none of them fatal alone: the
Mac is on Wi-Fi, so the PXE ROM's broadcast and the proxy's reply must cross the
AP bridge; dnsmasq's proxy mode plus UEFI has a long history of simply not
answering, and the Realtek ROM's port-4011 behaviour here is unverified; macOS 26
wants root on 67/69 and a Local Network permission grant; and **the failure mode
is a silent fallthrough on a machine with no video.** Keep it documented as the
fallback for a machine whose firmware refuses to boot USB.

**A wins for two machines because §1 is true.** The value of B over A is entirely
in the *second* install, and §1 says there mostly is not one:

| | A — USB media | B — iPXE stick + HTTP |
|---|---|---|
| First install | works, one physical touch | works, one physical touch |
| Needs anything running on the Mac | **no — fully offline** | yes, at boot time |
| Change Talos version or schematic | re-flash 320 MiB, per machine | edit one text file |
| Re-provision later | walk to the machine | create a file, power-cycle |
| Stick can stay in permanently | **no** (§6) | yes — the 404 gate falls through to disk |
| Moving parts | a stick | iPXE + a file server + intent files |

At N=2 the row that looked decisive — re-provision later — is a cost paid
approximately never, and two of the three cases in §2 have you standing at the
machine with a screwdriver anyway.

---

## 4. The chosen arrangement — USB, in two variants

Both start from an **Image Factory schematic**, not a GitHub release asset. §8.1
put `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` in the machine's
image, and the Tailscale extension joins them; a stock release ISO has none of
them. Commit the schematic YAML *and* the ID the factory returns for it — the ID
is content-addressable, so it is a checksum of the choice, not a name for it.

`target-architecture.md` §2 wants the image built locally with
`ghcr.io/siderolabs/imager` rather than fetched from `factory.talos.dev`, to keep
a cold rebuild free of hosted services. That is the terminal state and it does
not change anything here: `imager` consumes the same customization block, so the
schematic YAML is the portable artifact either way. Use the factory for machines
1–2; move the build local when the cold-start invariant is being enforced for
real.

### 4.1 Variant 1 — media boots, config arrives over the API

This is [headless-talos-install.md](headless-talos-install.md) Route B unchanged,
with the ISO coming from the schematic. Nothing on the media names a disk, so
**nothing is touched until you deliberately apply a config** — the whole thing up
to `apply-config` is a rehearsal you can abort with the power switch.

Prefer this for machine 2. It is loop-free by construction and every failure has
a place to report itself.

### 4.2 Variant 2 — fully unattended, the true equivalent of the Ubuntu autoinstall

Verified: `talos.config=metal-iso` makes Talos *"load the machine configuration
from any block device with a filesystem label of `metal-iso`"*, reading
`config.yaml` at that filesystem's root. Both the label and the path are
hardcoded in Talos today (there is an open upstream issue asking for them to be
configurable). The kernel argument goes into the image through the schematic's
`customization.extraKernelArgs`, which is a first-class Image Factory field.

So: stick 1 is the Talos ISO built from a schematic carrying
`talos.config=metal-iso`; stick 2 is a small volume labelled `metal-iso` holding
`config.yaml`. Plug both in, power on, walk away. No `apply-config`, no HTTP
server, no network dependency at all beyond the installer image pull.

Three things to know before choosing it over §4.1:

- **The config on that stick is real PKI.** That is better than the alternatives
  that put it on the wire, but the stick becomes a secret-bearing object —
  `rm -P` it afterwards, the way §9 disposes of the throwaway config.
- **macOS uppercases FAT volume labels.** `diskutil eraseVolume FAT32 metal-iso`
  stores `METAL-ISO`, and Talos matches the label literally. Whether that match
  is case-sensitive is **not verified here**. The good news is that the failure
  is benign and legible: the config is not found, the machine sits in maintenance
  mode, and you fall back to §4.1's `apply-config`.
- **A third block device is attached during the install**, on top of Route B's
  second one. `machine.install.diskSelector` matching on `disk.model` stops being
  a nicety and becomes the thing that prevents installing onto a USB stick.

**Rejected: `talos.config.inline`.** It exists, and it takes a zstd-compressed,
base64-encoded config directly on the kernel command line — but that line is
limited to 4096 bytes and the docs say it suits "small configuration documents".
A control-plane config carrying PKI is not one.

---

## 5. The iPXE arrangement, for when it earns its place

Recorded in full because it is the thing to reach for when re-provisioning stops
being rare — a third machine, a rebuild being rehearsed repeatedly, or the day
walking to a box is genuinely inconvenient. It needs **no DHCP participation at
all**, which is what makes it preferable to option C.

```
 router 192.168.0.1 ──── DHCP (unchanged; add reservations)
        │
        │   ┌─ Mac 192.168.0.44 (operator only) ────────────────┐
        │   │  python3 -m http.server 8080                      │
        │   │    /boot/<mac>.ipxe   ← intent file (may be absent)│
        │   │    /assets/<schematic>/<version>/{vmlinuz,initramfs}│
        │   └────────────────────────────────────────────────────┘
        │                    ▲ HTTP (unicast; Wi-Fi is fine)
  ┌─ machine ──────────────┐ │
  │ USB stick (permanent)  │ │
  │  /EFI/BOOT/BOOTX64.EFI │─┘  iPXE → dhcp (from router) → chain
  │  /EFI/BOOT/autoexec.ipxe│    404 ⇒ exit ⇒ firmware boots the SSD
  │ SSD: Talos             │
  └────────────────────────┘
```

**No iPXE build is required.** A prebuilt `ipxe.efi` from `boot.ipxe.org` copied
to `/EFI/BOOT/BOOTX64.EFI` on a FAT32 stick will load `autoexec.ipxe` from the
directory it was itself loaded from, so the script is editable with a text
editor. (That mechanism works only when iPXE is loaded *from a filesystem* — an
iPXE chainloaded over the network needs an embedded script or a DHCP-supplied
one, which is one more reason the stick beats the PXE ROM here.)

```
#!ipxe
dhcp || goto local
chain --autofree http://192.168.0.44:8080/boot/${mac:hexhyp}.ipxe || goto local
:local
exit 1
```

**The per-MAC file is the safety gate and the point of the design.** Absent ⇒ 404
⇒ `exit` ⇒ firmware falls through to the SSD. A power cut, or a reboot while the
Mac happens to be serving, boots the installed node normally. Intent is a file
you create, not a state the network is in — which is what makes the stick safe to
leave in the machine permanently.

Build the boot script by rewriting the factory's own rather than retyping a
kernel command line:

```bash
curl -sS https://pxe.factory.talos.dev/pxe/<schematic>/<version>/metal-amd64 \
  | sed "s#https://[a-z.]*factory.talos.dev/image/#http://192.168.0.44:8080/assets/#" \
  > boot/f4-93-9f-f2-59-82.ipxe
```

then fetch those same two assets once and pin their SHA-256, as
[headless-talos-install.md](headless-talos-install.md) §2.2 does for the release
assets. Serving them locally also **removes the iPXE-HTTPS question entirely**:
prebuilt iPXE ships with `DOWNLOAD_PROTO_HTTPS` undefined, and depending on the
factory being reachable at boot is a dependency this does not need.

Two things this arrangement bakes in, both of which need saying out loud. The
Mac's address ends up inside the stick, so `192.168.0.44` needs a router
reservation or it is ADR §4.2's failure in miniature (iPXE has no mDNS, so
`.local` is not an escape). And the provisioner is a laptop on Wi-Fi, so the
fleet still cannot re-provision itself — that, not machine count, is the trigger
for moving this onto something always-on or adopting Tinkerbell.

---

## 6. Traps, all verified

**The media has to come out — but not for the reason you would expect.** There is
no reinstall loop: booting installed media on a machine that already has Talos on
its disk makes Talos adopt that disk as the system disk and assume it is
installed. What you get instead is quieter and worse — the node runs the
*stick's* kernel with the *disk's* state, so its Talos version is decoupled from
what is on disk and upgrades stop meaning what you think they mean.

**Boot order needs deciding before the wipe, because afterwards there is no
screen.** Talos 1.11 briefly created its UEFI entry *and* moved it to the front;
that caused problems on some systems and was changed, so **current Talos creates
the entry only if it does not exist and does not modify the boot order**. Three
consequences for machine 2:

- `Boot0000` (Ubuntu) becomes dangling the moment the install runs, and `0006`
  (USB) sits in `BootOrder` after the two PXE entries — so a post-install reboot
  with the stick still in walks straight back into the installer.
- The disk path after the install therefore leans on Talos writing the fallback
  `EFI/BOOT/BOOTX64.EFI` and the firmware discovering it. That is the normal
  layout and the normal firmware behaviour, but it is **not verified on this
  machine**, and it is the single scariest unknown in the whole procedure.
- §5.2's `efibootmgr -n 0006` one-shot is right and should stay. What it does
  *not* do is protect the reboot *after* the install — `BootNext` is consumed by
  the first boot attempt.

**Secure Boot is unchanged and non-negotiable.** iPXE is unsigned, and so is the
metal profile; both routes need it off. The signed alternative (a SecureBoot
schematic and a UKI) costs a MOK enrolment trip at the same firmware screen you
are trying to visit once, which is not a trade worth making here.

**The artifact question is settled independently of the delivery question.** §8.1
fixed the schematic; nothing in this note changes it, and nothing in it depends
on which mechanism serves it. That is §8.4's own claim about swappability, and
it is the reason this decision is not blocking machine 2.

---

## 7. What this corrects elsewhere

- **ADR §4.1's extension argument.** It says bake `iscsi-tools` and
  `util-linux-tools` now because "a missing one costs this rebuild twice."
  Adding an extension later is an in-place upgrade to a new schematic's installer
  image — a reboot, not a rebuild. Still worth baking, for one fewer operation
  later; the stated reason was wrong.
- **ADR §4.2's central example.** *"Anything embedded in a certificate is a future
  rebuild"* is not true of `certSANs`, which regenerate the affected leaf
  certificates in seconds with no reboot. The rule survives applied to the right
  nouns — the cluster CA, `cluster.id`/`cluster.secret`, and the Tailscale
  `ProxyGroup` tags, which are immutable once a device exists and burn a
  certificate to change. Being generous with `certSANs` stays good hygiene rather
  than rebuild-avoidance.
- **ADR §4.1's framing of "the one rebuild" more broadly.** It is partly an
  artifact of *today's* architecture: bridged networking is a rebuild now because
  the NIC is a libvirt domain resource Terraform must destroy and recreate. Under
  D20 there is no domain, and it is a machine-config change with a reboot.
- **`headless-talos-install.md` §2.2** fetches boot assets from the GitHub
  release. Correct when written, superseded by §8.1: once extensions are
  required, the ISO comes from the schematic.
- **`fleet-control-plane-survey.md` §4 and §7.3, and `target-architecture.md`
  §2** all assume netboot is where a machine's OS comes from. That stays true as
  the *target*; it is not how machines 1 and 2 get built.

> **Where this argument is picked up.**
> `provisioning-automation-without-netboot.md` §2 reaches the same rare-versus-recurring
> split independently and asks the next question: given manual install is accepted, what
> is worth automating. Its answer — the node list, NFD rules, a reproducible image — is
> the build order this page's verdict feeds into. Read that one for *what to build*; this
> one for *how often media is needed at all*.

## 8. Still open

- Whether this machine's firmware boots a FAT32 stick presenting only the
  fallback path, and whether it discovers Talos's fallback entry after the
  install. `Boot0006` says the first is likely; neither is proven. **Prove the
  first while Ubuntu is still there to report what happened.**
- Whether the `metal-iso` label match is case-sensitive (§4.2). Benign either
  way, one test to settle.
- The smart plug. Nothing in this note changes the survey's judgement that it is
  the cheapest item in the design — but §1 does deflate what it buys. Remote
  power matters for a *wedged* machine, which is a fault, not for re-provisioning,
  which turns out to be an API call.
