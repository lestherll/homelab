terraform {
  required_version = ">= 1.11"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }

  # Local state, deliberately — same reasoning as clusters/homelab/. State
  # holds only derived material, because the Talos PKI is generated out of
  # band and SOPS-encrypted, so losing this file costs a re-apply rather than
  # the cluster.
  #
  # terraform-on-bare-metal.md §8 adds the constraint that matters now that
  # libvirt is gone and this CAN run from the Mac: local-on-the-Mac is
  # defensible; an S3 backend on the cluster's own SeaweedFS is not.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# No libvirt provider, and so no local socket — which is what makes this
# runnable from the Mac. AGENT.md's "terraform cannot run from the Mac" is
# true of clusters/homelab/ and false here.

variable "machine_secrets" {
  description = "Talos PKI, supplied from SOPS. See terraform/README.md."
  type        = any
  sensitive   = true
}

variable "google_operator_email" {
  description = <<-EOT
    Google account allowed to authenticate via OIDC. Not a credential — an
    allow-list entry; RBAC still gates what it can do. Supplied via
    TF_VAR_google_operator_email, same out-of-band pattern as machine_secrets.
  EOT
  type        = string
  sensitive   = true
}

variable "tailscale_authkey" {
  description = <<-EOT
    Reusable, `tag:talos`-tagged Tailscale auth key for the nodes' tailscale
    extension. Supplied via TF_VAR_tailscale_authkey from
    tailscale-authkey.sops.yaml — see terraform/README.md.
  EOT
  type        = string
  sensitive   = true
}

variable "dial_over_lan" {
  description = <<-EOT
    Nodes Terraform must reach by LAN address rather than tailnet name — a
    machine in maintenance mode has no tailnet identity yet.

      terraform apply -var 'dial_over_lan=["homelab-worker-1"]'

    Per node rather than global on purpose: joining a machine is the mixed
    case, and a global switch would make adding one a LAN-only operation.
  EOT
  type        = list(string)
  default     = []
}

module "cluster" {
  source = "../../modules/talos-metal"

  cluster_name = "homelab-metal"

  # Talos v1.13.8 pairs with Kubernetes 1.36.2 — its DefaultKubernetesVersion
  # at that tag. Must stay in step with talos_version in
  # ansible/roles/cli_tools/vars/main.yml.
  talos_version      = "v1.13.8"
  kubernetes_version = "v1.36.2"

  # Schematic 708747e3… — minted and read back 2026-09-03 from exactly this
  # customization, whose content hash IS the ID, so it is re-mintable rather
  # than an opaque handle:
  #
  #   customization:
  #     systemExtensions:
  #       officialExtensions:
  #         - siderolabs/iscsi-tools
  #         - siderolabs/tailscale
  #         - siderolabs/util-linux-tools
  #
  # Two changes from its predecessor 3cbae7e7…, and BOTH need the same
  # `talosctl upgrade` to land — apply-config never re-runs the installer:
  #
  #   + siderolabs/tailscale, which is what makes `talosctl` reachable off-LAN
  #     (docs/fleet/talosctl-off-lan.md). siderolabs/tailscale is v1.98.9 at
  #     v1.13.8, matching the operator's client version elsewhere in the repo.
  #
  #   - the leftover `talos.config=http://192.168.0.44:8080/config.yaml` kernel
  #     argument from machine 2's original unattended install. It is consulted
  #     only when STATE holds no config — which is exactly what a `talosctl
  #     reset` produces, so it was dormant rather than inert. Measured
  #     2026-09-02: with STATE wiped the node fetched from that URL and did NOT
  #     fall back to maintenance mode when the fetch failed, leaving a node with
  #     no API at all. `talosctl upgrade` rewrites kernel arguments, so this is
  #     the change that is finally rid of it; do not carry it onto machine 1.
  install_image = "factory.talos.dev/installer/708747e350d604ae9e57227d8dcf274091453ddb1097b765d4ea8884f1992c1f:v1.13.8"

  # THE NODE INVENTORY, and the only place hardware appears.
  #
  # Stage 2 of docs/fleet/inventory-and-provisioning-approach.md: a
  # hand-written YAML list in git, consumed by Terraform. Data rather than HCL
  # so something else can consume it later — it maps onto Tinkerbell's
  # `Hardware` object field-for-field, so this fleet can be adopted into netboot
  # without reinstalling anything (tinkerbell-investigation.md §9).
  #
  # Disks, install target and zone are all per node in that file. They used to
  # be module-wide, which quietly assumed every machine looked like machine 2 —
  # the assumption hardware-fit-notes.md §6 records as false.
  nodes = yamldecode(file("${path.root}/../../../fleet/nodes.yaml"))

  # Machine 2 alone for now. Machine 1 joins as a WORKER once cabled (Talos has
  # no 802.11 support at all), and HA still waits for a third machine.
  cluster_endpoint_ip = "192.168.0.221"
  gateway             = "192.168.0.1"

  # The tailnet, which is how `talosctl` and `terraform` both reach this node
  # from off-LAN.
  #
  # Deliberately a DOMAIN and not an address. Every node's certSAN, MagicDNS
  # name and Terraform dial target is derived as `<hostname>.<tailnet_domain>`,
  # so nothing here is re-edited when the LAN is renumbered. Not a secret: the
  # tailnet name is already in git in ansible/inventory/hosts.ini.
  tailnet_domain    = "tailf4742d.ts.net"
  tailscale_authkey = var.tailscale_authkey

  # Machine 1's future WIRED address is deliberately absent: it is not yet
  # known, because enp2s0 has never held a lease. Adding it later regenerates
  # the affected leaf certificates in seconds with no reboot.
  #
  # The nodes' tailnet names are absent for a different reason — talos.tf adds
  # them automatically from tailnet_domain, and repeating one here would be the
  # kind of duplicate that survives a rename.
  extra_cert_sans = []

  dial_over_lan         = var.dial_over_lan
  machine_secrets       = var.machine_secrets
  google_operator_email = var.google_operator_email
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "node_ips" {
  value = module.cluster.node_ips
}

output "talos_endpoints" {
  description = "What `talosctl config endpoint` should name — see docs/fleet/talosctl-off-lan.md."
  value       = module.cluster.talos_endpoints
}
