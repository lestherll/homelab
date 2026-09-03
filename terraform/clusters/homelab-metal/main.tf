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

  # Machine 2 alone. Machine 1 joins as a WORKER once cabled (Talos has no
  # 802.11 support at all), and HA still waits for a third machine.
  cluster_endpoint_ip = "192.168.0.221"
  gateway             = "192.168.0.1"

  nodes = {
    "homelab-worker-0" = {
      ip           = "192.168.0.221"
      mac          = "f4:93:9f:f2:59:82"
      machine_type = "controlplane"
    }
  }

  # The tailnet, which is how `talosctl` reaches this node from off-LAN.
  #
  # This is deliberately a DOMAIN and not an address. Every node's certSAN and
  # MagicDNS name is derived as `<hostname>.<tailnet_domain>`, so nothing here
  # has to be re-edited when the LAN is renumbered — the failure mode the old
  # `talos-cp-01: 10.10.0.10` pin in tailscale-acl/policy.hujson has. Not a
  # secret: the tailnet name is already in git in ansible/inventory/hosts.ini.
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

  # ONE disk carrying BOTH tags — not two disks, and that correction was
  # measured rather than reasoned.
  #
  # machine-2-first-build-plan.md §4.1 says "create both Longhorn disks on that
  # SSD, tagged fast and bulk". Longhorn REFUSES that. It keys disks by
  # filesystem ID, and two paths on one filesystem collide:
  #
  #   Failed to create disk from annotation ... error="the disk
  #   /var/lib/longhorn-bulk is the samefile system with /var/lib/longhorn,
  #   diskID 080400000000"
  #
  # The failure is quiet in the way that matters: the annotation is rejected
  # WHOLESALE, so the node registers with `disks: {}` and no tags at all, and
  # nothing on the Longhorn node object says why. Only longhorn-manager's log
  # names it. A `fast` PVC would then sit Pending with no schedulable disk.
  #
  # One disk with both tags keeps §4.1's actual intent intact: `fast` and `bulk`
  # are public API (rgd-database.yaml hardcodes `fast`, rgd-application.yaml
  # enumerates both), both must resolve from day one, and an SSD
  # over-delivers on `bulk`'s guarantee rather than under-delivering. Classes
  # name guarantees, not devices (golden-architecture.md §3).
  #
  # The migration story is unchanged and is why this is not a compromise: when
  # machine 1 joins with a real spinning disk, tag its HDD `bulk` and DROP
  # `bulk` from this tag list. Longhorn moves bulk replicas by tag, with no
  # Platform API change and no PVC rewrite.
  longhorn_disks = [
    { path = "/var/lib/longhorn", allowScheduling = true, tags = ["fast", "bulk"] },
  ]

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
