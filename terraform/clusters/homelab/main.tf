terraform {
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

  # Local state, deliberately. The usual reason to want a remote backend here
  # is state confidentiality, and that problem is solved upstream instead: the
  # Talos PKI is generated out of band and SOPS-encrypted, so this file holds
  # only derived material. See terraform/modules/talos-cluster/talos.tf.
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "libvirt" {
  # System URI, not session: the storage pools and the network are system-wide
  # objects created by Ansible. Requires the invoking user to be in the libvirt
  # group, which host_prereqs arranges.
  uri = "qemu:///system"
}

variable "machine_secrets" {
  description = "Talos PKI, supplied from SOPS. See terraform/README.md."
  type        = any
  sensitive   = true
}

module "cluster" {
  source = "../../modules/talos-cluster"

  cluster_name  = "homelab"
  node_hostname = "talos-cp-01"

  # Talos v1.13.8 (2026-08-04) pairs with Kubernetes 1.36.2 — its
  # DefaultKubernetesVersion at that tag. Re-verified 2026-08-16. Must stay in
  # step with talos_version in ansible/roles/cli_tools/vars/main.yml.
  talos_version      = "v1.13.8"
  kubernetes_version = "v1.36.2"

  # The node gets the machine. 12Gi of the host's 15Gi, leaving ~3Gi for Ubuntu,
  # libvirt and qemu's own per-VM overhead — RAM here is spent, not shared, so
  # this is the number that decides how much the cluster can actually hold.
  # vcpus can exceed nothing useful: 8 is every core, and oversubscribing a
  # single-guest host buys nothing.
  vcpus      = 8
  memory_mib = 12288

  # Pool names come from Ansible: host_prereqs owns the SSD pool, bulk_storage
  # owns the HDD pool (behind its mount assert).
  system_pool = "homelab-ssd"
  fast_pool   = "homelab-ssd"
  bulk_pool   = "homelab-bulk"

  system_disk_gib = 20
  fast_disk_gib   = 20
  bulk_disk_gib   = 100

  # Must match the DHCP reservation in host_prereqs' libvirt network template.
  network_name = "talos"
  node_ip      = "10.10.0.10"
  node_gateway = "10.10.0.1"
  node_mac     = "52:54:00:7a:10:5e"

  machine_secrets = var.machine_secrets
  base_image_path = "/var/lib/libvirt/images/talos-v1.13.8-nocloud-amd64.raw"
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "node_ip" {
  value = module.cluster.node_ip
}
