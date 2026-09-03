# Provider pins, per the repo's pinning convention (AGENT.md).
#
# NOTE what is absent: dmacvicar/libvirt. That is the whole point of this
# module. On bare metal there is no hardware to simulate, so the libvirt half
# of modules/talos-cluster/ (domain.tf, volumes.tf, stage-talos-image.sh) has
# no counterpart here — see docs/fleet/terraform-on-bare-metal.md §1.
#
# This module deliberately does NOT replace modules/talos-cluster/. Both exist
# until cutover (machine-2-first-build-plan.md §6), because keeping the VM
# cluster applyable is what makes the rollback free.
#
# siderolabs/talos 0.11.0 (2026-04-27), the stable line and where ephemeral
# resources landed. Same pin and same reasoning as modules/talos-cluster/;
# re-verified 2026-09-02.
terraform {
  # 1.11+ is a hard floor, not a preference: the write-only attributes that
  # keep the Talos PKI out of state (the *_wo arguments in talos.tf) do not
  # exist before it.
  required_version = ">= 1.11"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    # Runs scripts/discover-maintenance-node.sh, which finds a machine sitting
    # in maintenance mode by MAC. Only ever invoked for nodes named in
    # var.dial_over_lan, so an ordinary plan does not shell out at all.
    # 2.3.5 (2025-02-20), re-verified 2026-09-03.
    external = {
      source  = "hashicorp/external"
      version = "2.3.5"
    }
  }
}
