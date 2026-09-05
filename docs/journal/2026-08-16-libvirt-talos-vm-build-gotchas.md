# Building the Talos-on-libvirt Terraform module: four silent failure modes

**Date:** 2026-08-16 · **Tags:** terraform, libvirt, talos, kvm

**Problem:** `terraform/modules/talos-cluster/` had to drive a Talos VM under
libvirt from scratch. Four of the failures hit during that build gave no
usable error at the point they occurred — each is recorded because the fix is
one line once you know the cause, and none of the four are discoverable from
Talos or libvirt docs alone.

**Findings:**
- **Libvirt network subnet must avoid the Kubernetes service CIDR.** The
  obvious choice, `10.100.0.0/24`, sits inside the default service CIDR
  `10.96.0.0/12`. Nothing errors at any layer: the VM boots, gets an address,
  serves the Talos API — and etcd then hangs forever on "Waiting for etcd
  spec" with no stated cause anywhere except `talosctl dmesg | grep
  diagnostic`. Fixed by moving to `10.10.0.0/24`. The single most expensive
  and least discoverable failure of the build.
- **A missing `machine.certSANs` entry fails as a hang, not an error.** The
  apid certificate covers only what it's told plus loopback, so every
  authenticated call fails with "certificate is valid for 127.0.0.1" —
  and `talos_machine_bootstrap` retries a condition that can never clear, so
  the visible symptom is an apply that never completes rather than one that
  errors. `certSANs` needs to be generous from the first apply: VIP/address,
  every node's LAN address, tailnet names, `localhost`.
- **Talos v1.13 moved hostname into its own `HostnameConfig` document, and a
  patch merges into it rather than replacing it** — so the generated `auto:
  stable` survives and collides with an explicit static hostname. `auto: off`
  is what actually works; `$patch: replace`, `auto: ""` and `auto: null` each
  fail differently. The old v1alpha1 `machine.network.hostname` field still
  exists and is still documented, which is what makes this easy to get wrong.
- **A disk survives reorder only if selected by serial, not by device name.**
  libvirt can stamp a `<serial>` on each virtual disk; Talos's `UserVolumeConfig`
  selects by CEL expression against that serial rather than `vdb`/`vdc`
  enumeration order. Verified end-to-end including a destroy/recreate where
  `vdb`/`vdc` were reassigned from scratch — the CEL match still landed the
  right backing file on `/var/mnt/fast` and `/var/mnt/bulk`. Selecting by
  device name instead would silently swap tiers on a disk being added or
  reordered.

**Why:** none of these surface as a compile-time or plan-time error — each
is a runtime hang or a silent semantic mismatch discoverable only by reading
node-side diagnostics (`talosctl dmesg`, `talosctl get disks`) rather than
Terraform's own output.

**Ref:** `terraform/modules/talos-cluster/`, `docs/journal/2026-08-16-talos-terraform-migration.md`
