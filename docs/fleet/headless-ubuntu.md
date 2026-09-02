# Headless Ubuntu Server Install — Lenovo Desktop, via Mac

This builds a custom Ubuntu Server USB that installs itself with **zero keyboard/monitor interaction**: plug it in, power on, walk away, come back to an SSH-ready server.

If the target machine's internal disk is **new and blank**, you can usually skip the BIOS step entirely — a blank disk has no EFI system partition and no boot entry, so the USB is the only bootable device the firmware can find. The BIOS trip in Step 7 exists for machines that already have an OS installed.

**How it works:** instead of just flashing the stock ISO (which still asks "Continue with autoinstall? yes/no" and needs someone to sit there), we bake your answers (`autoinstall.yaml`) directly into a custom ISO using a small Docker tool. That custom ISO is what you flash and boot from.

**What you'll need**
- Your Mac, with [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed (free)
- A USB flash drive, 4 GB or larger
- An Ethernet cable (wired networking works out of the box; Wi-Fi needs extra config this guide skips)
- The Lenovo, with the new SSD installed — ideally with **no other drives** connected, so there's no ambiguity about which disk gets wiped
- A monitor + keyboard for the Lenovo — only if you need the BIOS step in Step 7 (see above; on a blank internal disk you probably don't)

---

## Step 1 — Download Ubuntu Server 26.04.1 LTS

26.04.1 LTS "Resolute Raccoon" is the current LTS, released April 2026, with the longest support runway.

```bash
mkdir -p ~/ubuntu-autoinstall && cd ~/ubuntu-autoinstall
curl -LO https://releases.ubuntu.com/resolute/ubuntu-26.04.1-live-server-amd64.iso
curl -LO https://releases.ubuntu.com/resolute/SHA256SUMS
grep 'ubuntu-26.04.1-live-server-amd64.iso' SHA256SUMS | shasum -a 256 -c
```

That last line should print `ubuntu-26.04.1-live-server-amd64.iso: OK`. Don't skip it — a corrupt 3 GB download surfaces later as a baffling mid-install failure rather than as an obvious download error.

> **Heads-up on 26.04:** it ships Rust rewrites of coreutils and `sudo` (`sudo-rs`). Most things are unaffected, but Ansible's `become` password prompt does not match `sudo-rs`'s output — see the note in this repo's [AGENT.md](../../AGENT.md) and the comment block in [ansible.cfg](../../ansible.cfg). If you'll manage this box with Ansible, wrap playbook runs in a top-level `sudo` rather than using `-K`.

---

## Step 2 — Get an SSH key ready

You'll log into the finished server over SSH using a key, not a password (much safer for anything sitting on your network unattended). If you don't already have one:

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
cat ~/.ssh/id_ed25519.pub
```

Copy that output — the whole `ssh-ed25519 AAAA...` line. You'll paste it into the config in Step 4.

---

## Step 3 — Generate a login password hash

Even though SSH will use your key, the account still needs a password hash set (useful as a fallback if you ever plug in a monitor/keyboard directly). **macOS's built-in `openssl` can't produce the SHA-512 hash Ubuntu wants** — it's LibreSSL under the hood and is missing the `-6` option. Since you already need Docker for Step 5, just use it here too:

```bash
docker run --rm -it ubuntu:26.04 bash -c \
  "apt-get update -qq >/dev/null && apt-get install -y -qq openssl >/dev/null && openssl passwd -6"
```

It'll prompt you to type a password twice, then print something like:

```
$6$SX8O9xVd1d/WX2hm$vh9RI2WCnh1BKwmHU2QHX5/ZMwH45zLpVe5v7EykPvjtiNGeYqje9GH2l/dZruVP0kYyPecJRGz1XfY
```

Copy that whole string. A valid SHA-512 crypt hash is 106 characters: `$6$`, up to 16 salt characters, `$`, then an 86-character digest.

**Expect `debconf` warnings** — "unable to initialize frontend: Dialog", "Can't locate Term/ReadLine.pm". That's `apt-get` complaining it has no interactive UI in a minimal image. It falls back to the Teletype frontend and succeeds; the warnings mean nothing. `DEBIAN_FRONTEND=noninteractive` silences them.

**To keep the hash out of your scrollback and clipboard**, redirect it to a file instead — openssl writes its prompt to the terminal, not stdout, so only the hash lands in the file:

```bash
docker run --rm -it \
  --mount type=bind,source="$HOME/ubuntu-autoinstall",target=/data \
  ubuntu:26.04 bash -c \
  'apt-get update -qq >/dev/null && apt-get install -y -qq openssl >/dev/null && openssl passwd -6 > /data/.pwhash'
```

---

## Step 4 — Write `autoinstall.yaml`

Create this file in the same folder as the ISO (`~/ubuntu-autoinstall/autoinstall.yaml`). Edit the marked fields:

```yaml
version: 1

# --- Locale / keyboard — adjust if you're not in the UK ---
locale: en_GB.UTF-8
keyboard:
  layout: gb

# --- Network: DHCP on whichever wired interface comes up ---
network:
  version: 2
  ethernets:
    alleths:
      match:
        name: "en*"
      dhcp4: true

# --- Storage: wipe the disk and use it all, no LVM ---
storage:
  layout:
    name: direct

# --- Your user account — EDIT hostname, username, password ---
identity:
  hostname: homeserver
  username: CHANGE_ME
  password: "CHANGE_ME_paste_the_$6$_hash_from_step_3"

# --- SSH: install it, key-based login only ---
ssh:
  install-server: true
  allow-pw: false
  authorized-keys:
    - "CHANGE_ME_paste_your_ssh-ed25519_public_key_from_step_2"
    - "CHANGE_ME_paste_a_SECOND_key_-_see_the_note_below"

# --- Make the machine Ansible-ready at install time ---
late-commands:
  - printf 'CHANGE_ME_username ALL=(ALL) NOPASSWD:ALL\n' > /target/etc/sudoers.d/90-ansible
  - chmod 0440 /target/etc/sudoers.d/90-ansible
  - curtin in-target -- visudo -cf /etc/sudoers.d/90-ansible

# --- A few useful extras ---
packages:
  - vim
  - curl
  - htop
  - net-tools
  - avahi-daemon

# --- Fully patch it on first install ---
updates: all

# --- EDIT if you're not in the UK ---
timezone: Europe/London

# --- Power off instead of rebooting when finished ---
# Without this, the machine reboots straight back into the USB
# installer (since it's still plugged in) and loops. Powering off
# gives you a clean point to pull the USB before turning it back on.
shutdown: poweroff
```

A few notes on choices made here:
- The directives sit at the **top level**, with no wrapping `autoinstall:` key. That's the correct form for a config placed at the root of the install media, which is what Step 5 does. (The cloud-init delivery method in the Appendix needs the wrapper — that difference is the single most common way this goes wrong.)
- `allow-pw: false` means password logins over SSH are blocked — only your key works. Console login (if you ever attach a monitor) still uses the password.
- **Two keys, not one.** With `allow-pw: false` and a machine that may have no video output, a single authorized key is one lost laptop away from a box you cannot get into at all. Put your Mac's key *and* your existing server's key in there. It costs a line, and it is also what lets either machine act as the Ansible control node later without extra setup.
- **`late-commands` is what makes Ansible work on this box.** `identity:` creates an account with *password* sudo, and Ubuntu 26.04's `sudo-rs` breaks Ansible's password prompt detection outright (see the note in Step 1) — so a machine installed without this needs the drop-in planted by hand before any playbook can run against it. `curtin in-target -- visudo -cf` validates it: a malformed sudoers file makes `sudo` refuse to run at all, and failing the install loudly beats finding that out later with no console.
- `direct` storage layout uses the entire disk with plain partitions (no LVM). Simple and fine for a home server; say if you want LVM instead and I'll adjust it.
- `avahi-daemon` is what makes `homeserver.local` resolvable from your Mac. Ubuntu Server doesn't ship mDNS by default, and without it finding the box means digging through your router — see Step 9.
- `updates: all` pulls the full update set during the install rather than just security fixes. It's the main reason install time varies.

---

## Step 5 — Build the zero-touch ISO

This is the part a plain `dd`/Etcher flash of the stock ISO can't do on its own: getting `autoinstall` onto the kernel boot line automatically, with no one there to type it. We use a small purpose-built Docker image ([`boxcutter/ubuntu-autoinstall`](https://hub.docker.com/r/boxcutter/ubuntu-autoinstall)) that does this correctly for current Ubuntu ISOs, which changed their internal layout from older versions and no longer work with the classic manual `xorriso` recipes floating around online.

From `~/ubuntu-autoinstall` (with the ISO and your `autoinstall.yaml` both sitting in it):

```bash
docker run -it --rm \
  --mount type=bind,source="$(pwd)",target=/data \
  docker.io/boxcutter/ubuntu-autoinstall \
    --source ubuntu-26.04.1-live-server-amd64.iso \
    --autoinstall autoinstall.yaml \
    --config-root \
    --destination ubuntu-26.04.1-autoinstall.iso
```

`--config-root` copies your config to the root of the install media and rewrites the boot entry so it launches straight into autoinstall with no prompts — this is Canonical's documented recommended method for current releases, and the image's own default mode. You should end up with `ubuntu-26.04.1-autoinstall.iso` in the same folder.

### Apple Silicon notes (verified on an M4)

The build image is **amd64-only**, so an arm64 Mac needs emulation. Two things follow:

- **You don't need Docker Desktop.** `colima` plus the `docker` CLI (both via Homebrew) do the job. Start it with Rosetta so it can run amd64 images:
  ```bash
  colima start --vm-type=vz --vz-rosetta
  ```
  On startup it should report `linux/amd64` among its supported platforms. Without `--vz-rosetta` you get an aarch64-only VM and the build image won't run at all.
- **Add `--platform linux/amd64`** to the `docker run` above.

**Check the host directory is writable from inside a container before building** — colima mounts `$HOME` read-only in some configurations, and you'd only find out when the build failed at the final write:

```bash
docker run --rm --mount type=bind,source="$HOME/ubuntu-autoinstall",target=/data \
  ubuntu:26.04 sh -c 'touch /data/.writetest && echo WRITABLE || echo READ-ONLY'
rm -f ~/ubuntu-autoinstall/.writetest
```

---

## Step 5b — Verify the ISO before you flash

Don't take "Built:" at face value. A build that silently didn't apply the config produces a perfectly bootable ISO that drops you at the interactive installer — which, on a headless machine, looks exactly like a hang.

**`hdiutil` cannot mount these ISOs** (`attach failed - no mountable file systems`) — that's normal for Ubuntu's hybrid images and is not a sign of a bad build. Read the ISO directly instead:

```bash
docker run --rm --mount type=bind,source="$HOME/ubuntu-autoinstall",target=/data ubuntu:26.04 bash -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq libarchive-tools >/dev/null 2>&1
ISO=/data/ubuntu-26.04.1-autoinstall.iso
bsdtar tf "$ISO" | grep -x "autoinstall.yaml" && echo "  config at ISO root: PRESENT"
bsdtar xOf "$ISO" boot/grub/grub.cfg | grep -E "linux.*vmlinuz"
'
```

You want two things: `autoinstall.yaml` present at the ISO root, and a kernel line reading `linux /casper/vmlinuz autoinstall ---`. That `autoinstall` argument is what removes the "Continue with autoinstall?" prompt.

**Rebuilding is not reproducible.** The same config built twice yields a different SHA-256, because the ISO embeds build timestamps. So the readback check in Step 6 must compare against the hash of *the exact file you flashed*, not a later rebuild.

It's also worth validating the YAML itself first — a syntax error otherwise surfaces as a failed install at the target machine:

```bash
docker run --rm --mount type=bind,source="$HOME/ubuntu-autoinstall",target=/data ubuntu:26.04 bash -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq python3-yaml >/dev/null 2>&1
python3 -c "import yaml; d=yaml.safe_load(open(\"/data/autoinstall.yaml\")); print(\"parses OK:\", \", \".join(d.keys()))"
'
```

---

## Step 6 — Flash the custom ISO to USB

Either [balenaEtcher](https://etcher.balena.io/) (`brew install --cask balena-etcher`) or `dd`. Etcher is safer if you're unsure of the device; `dd` needs no install.

**Whichever you use, flash `ubuntu-26.04.1-autoinstall.iso` — the custom one you built, not the original download.**

### With `dd`

First identify the stick and confirm you have the right device — this is the step where a mistake wipes your Mac:

```bash
diskutil list external
diskutil info /dev/diskN | grep -E "Device / Media Name|Disk Size|Device Location|Removable"
```

You want `Device Location: External` and `Removable Media: Yes`, with a name and size you recognise. Then:

```bash
diskutil unmountDisk /dev/diskN
sudo dd if=/Users/YOU/ubuntu-autoinstall/ubuntu-26.04.1-autoinstall.iso of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

Four things that bite here:

- **Use an absolute path, not `~`.** zsh does not expand `~` after `=` in an argument like `if=~/foo` (that only happens in real variable assignments), so `dd` fails with `No such file or directory`. Harmless — it fails before opening the disk — but confusing.
- **`rdiskN`, not `diskN`,** for the output. The raw device is roughly 10× faster. The `r` is not a typo.
- **macOS `dd` has no `status=progress`** — that's GNU `dd`. Press **Ctrl+T** for a one-line status. Expect no output at all until it finishes.
- **`Resource busy`** means macOS re-mounted the stick; run `diskutil unmountDisk` again.

### Verify the write

Compare the partition layout — you should see the ISO's three partitions, and any previous partitions gone:

```bash
diskutil list /dev/diskN
```

For a byte-level check, read back exactly as many bytes as the ISO has and compare hashes:

```bash
shasum -a 256 /Users/YOU/ubuntu-autoinstall/ubuntu-26.04.1-autoinstall.iso
stat -f%z /Users/YOU/ubuntu-autoinstall/ubuntu-26.04.1-autoinstall.iso   # byte count
sudo head -c <byte-count> /dev/rdiskN | shasum -a 256                    # must match
```

---

## Step 7 — BIOS setup (often unnecessary)

**Skip this if the internal disk is new and blank** — there is no boot entry on it to compete with the USB, so the firmware will boot the USB on its own. Try Step 8 first; come back here only if nothing happens.

Do this with a monitor and keyboard attached — it's the only manual step in the whole process, and only needed once.

1. Power on and tap **F1** repeatedly to enter BIOS/UEFI setup (the standard key on Lenovo ThinkCentre/IdeaCentre-era business desktops; if that doesn't catch it, try F2 or Delete — it varies a bit by board age)
2. Find the boot order / **Startup** settings
3. Move USB storage to the **top** of the boot priority, above the internal SSD
4. Secure Boot can stay **on** — Ubuntu boots under it via a signed shim, and remastering the ISO doesn't modify anything Secure Boot actually verifies. Turn it off only if the machine refuses to boot the USB, bearing in mind that's a lasting change on a box that will sit unattended
5. Save and exit (usually **F10**)

Setting USB above the SSD means a USB drive plugged in at power-on boots the installer, and an empty port falls through to the SSD. That's what lets this whole install run on a power-button press, with no boot-menu key to hit.

One caveat: on UEFI, installing Ubuntu writes its own `ubuntu` entry into the firmware's NVRAM boot list, and firmware commonly places that at the top. So the priority you set here isn't guaranteed to survive the install. It doesn't affect this run, but if you ever reuse this USB on the same machine, check the boot order again first.

---

## Step 8 — Run the install

1. Insert the flashed USB
2. Plug in the Ethernet cable
3. Power on

That's it. It boots straight into the installer, wipes the SSD, partitions it, installs Ubuntu, creates your user, installs and enables SSH with your key, applies updates, and — because of `shutdown: poweroff` — powers itself off when done. Expect somewhere between 5 and 20 minutes depending on network speed and how many updates there are to pull.

**The GRUB menu waits 30 seconds before booting** (`set timeout=30` in the ISO's `grub.cfg`). That pause is normal, not a hang.

### Running it with no monitor at all

`shutdown: poweroff` is what makes this viable: it turns "finished" into a signal you can observe from across the room. Three checkpoints, in order:

1. **A DHCP lease appears** a minute or two in — the live installer brings networking up early. Check your router's client list, or `arp -a` from your Mac. This confirms it booted and reached the network.
2. **The machine powers itself off.** That is success, and it is unambiguous.
3. **SSH answers** once you pull the USB and power back on.

The failure mode is distinguishable: on error, subiquity stops on an error screen and **does not** power off. So a machine still running after ~30 minutes has failed, and one that has switched itself off has not. To read *why* it failed, you need a display.

Once the power light goes off:
1. Remove the USB drive
2. Power the machine back on — it now boots the installed OS from the SSD

---

## Step 9 — Find it and log in

Because `avahi-daemon` is in the package list, the hostname should just resolve from your Mac:

```bash
ssh CHANGE_ME@homeserver.local
```

using the username and hostname from your `autoinstall.yaml`. It'll authenticate with your SSH key automatically.

If `.local` doesn't resolve (avahi takes a moment on first boot, and some networks block mDNS), fall back to finding the IP:

- Check your router's admin page for connected devices / DHCP leases — look for the hostname you set (`homeserver` in the example above)
- If that's awkward, from your Mac: `arp -a` after the server's had a minute to come up, and cross-reference against devices you recognize

Then `ssh CHANGE_ME@192.168.x.x`.

**Tip:** worth setting a static DHCP reservation on your router for this machine's MAC address (printed on a sticker on the case, or visible in the router's client list) so the IP doesn't shift later.

---

## Troubleshooting

- **It boots into the normal interactive installer menu instead of going straight to autoinstall.** The `--config-root` step likely didn't take — double check you flashed the *generated* ISO (`ubuntu-26.04.1-autoinstall.iso`), not the original download. You can confirm by highlighting the boot entry and pressing `e` — you should see `autoinstall` in the kernel command line.
- **Nothing shows up on the network afterward.** Give it a couple of extra minutes on first boot. If it's still not there, attach a monitor once to see if it's actually up and check `ip a` for an address — this also tells you if DHCP simply isn't handing out a lease.
- **SSH connection is refused.** Check the public key you pasted into `authorized-keys` is the complete, unwrapped single line (no line breaks) — a truncated key is the most common cause.
- **Nothing happens at all — no disk activity, no DHCP lease, machine just sits there.** It isn't booting the USB. Do the BIOS step (Step 7); on a machine with an existing OS on its internal disk, the USB needs to be explicitly ahead of it in the boot order.
- **Worried about the wrong disk getting wiped.** If there's any chance more than one drive is connected, physically disconnect everything except the new SSD before running the install — much safer than trying to target a specific disk in the config.

---

## Appendix: skipping Docker (one manual keypress instead)

If you'd rather not install Docker, there's a lighter-weight method that needs exactly one keypress at install time instead of being fully hands-off:

1. Flash the **unmodified** Ubuntu Server ISO to your main USB with Etcher.
2. Format a *second*, small USB stick as FAT (MS-DOS) via Disk Utility on your Mac, and name the volume **CIDATA** (must be that name).
3. Copy a `user-data` file and an empty `meta-data` file to the root of that CIDATA stick.

   **`user-data` is not the same file as Step 4's `autoinstall.yaml`.** Delivered this way it's read by cloud-init, which requires both a `#cloud-config` header *and* every directive indented one level under a top-level `autoinstall:` key:

   ```yaml
   #cloud-config
   autoinstall:
     version: 1
     locale: en_GB.UTF-8
     keyboard:
       layout: gb
     # ...and so on — the entire body of Step 4's file,
     # indented by two spaces under `autoinstall:`
   ```

   Get this wrong and it fails quietly in a confusing way: cloud-init treats keys like `packages:` and `locale:` as its own config modules, the installer finds no autoinstall config at all, and you land in the fully interactive installer rather than the one-keypress flow.
4. Plug in **both** USB sticks, boot from the installer USB. Ubuntu's installer auto-detects the CIDATA volume and uses it, but will still show:
   ```
   Continue with autoinstall? (yes|no)
   ```
   Type `yes` and press Enter once — everything after that runs unattended.

This avoids Docker and ISO remastering entirely, at the cost of that one keypress.
