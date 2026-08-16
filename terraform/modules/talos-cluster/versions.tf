# Provider pins, per the repo's pinning convention (AGENT.md): explicit
# versions with a note on when and against what they were last re-verified.
#
# dmacvicar/libvirt 0.9.8 (2026-05-31), re-verified against upstream release
# history 2026-08-16. 0.9.0 was a full rewrite onto the Terraform Plugin
# Framework that maps HCL ~1:1 onto libvirt XML — every example written for
# 0.8.x is actively misleading, not merely dated. Read the cadence honestly:
# 0.9.0 → 0.9.1 took twelve months, then six releases landed Jan–May 2026.
# That is a rewrite being actively debugged, which argues for a hard pin.
#
# siderolabs/talos 0.11.0 (2026-04-27), the stable line and where ephemeral
# resources landed. The 0.12 series is alpha-only (six alphas, 2026-05 to
# 2026-06) and introduces a new talos_machine/talos_cluster resource model;
# it looks cleaner, but migrating a platform should not also be the thing that
# shakes out an alpha resource model. Evaluate it separately, after cutover.
terraform {
  # 1.11+ is a hard floor, not a preference: the write-only attributes this
  # module relies on to keep the Talos PKI out of state (the *_wo arguments in
  # talos.tf) do not exist before it.
  required_version = ">= 1.11"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }
}
