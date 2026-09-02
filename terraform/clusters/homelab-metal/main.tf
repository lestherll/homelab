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

module "cluster" {
  source = "../../modules/talos-metal"

  cluster_name = "homelab-metal"

  # Talos v1.13.8 pairs with Kubernetes 1.36.2 — its DefaultKubernetesVersion
  # at that tag. Must stay in step with talos_version in
  # ansible/roles/cli_tools/vars/main.yml.
  talos_version      = "v1.13.8"
  kubernetes_version = "v1.36.2"

  # Schematic 3cbae7e7… carries siderolabs/iscsi-tools and
  # siderolabs/util-linux-tools. It ALSO carries a leftover
  # `talos.config=http://192.168.0.44:8080/config.yaml` kernel argument from
  # machine 2's original unattended install. That argument is consulted only
  # when STATE holds no config — which is exactly what a `talosctl reset`
  # produces, so it is dormant rather than inert. Measured 2026-09-02: with
  # STATE wiped the node fetches from that URL and will NOT fall back to
  # maintenance mode when the fetch fails. Drop it with `talosctl upgrade`,
  # which rewrites kernel arguments; do not carry it onto machine 1.
  install_image = "factory.talos.dev/installer/3cbae7e742190fc042097d7e9828d973b2392e81338085441aa7a7087e3d83b5:v1.13.8"

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

  # Machine 1's future WIRED address is deliberately absent: it is not yet
  # known, because enp2s0 has never held a lease. Adding it later regenerates
  # the affected leaf certificates in seconds with no reboot.
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

  machine_secrets = var.machine_secrets
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "node_ips" {
  value = module.cluster.node_ips
}
