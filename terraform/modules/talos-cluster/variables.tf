variable "cluster_name" {
  description = "Talos cluster name. Also the prefix for every libvirt object this module creates."
  type        = string
}

variable "node_hostname" {
  description = "Hostname of the single control-plane node."
  type        = string
}

# --- Versions -------------------------------------------------------------
# Kept as variables rather than hardcoded so homelab and homelab-nonprod can
# sit on different versions during an upgrade rehearsal — which is much of the
# point of having a non-prod cluster at all.

variable "talos_version" {
  description = "Talos version, e.g. v1.13.8. Must match the talosctl pinned in ansible/roles/cli_tools/vars/main.yml."
  type        = string
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version, e.g. v1.36.2. Talos has a default per release
    (DefaultKubernetesVersion in pkg/machinery/constants); pinning it here
    makes the coupling visible instead of letting a Talos bump silently move
    Kubernetes too.
  EOT
  type        = string
}

# --- Machine sizing -------------------------------------------------------

variable "vcpus" {
  description = "vCPUs for the node."
  type        = number
  default     = 4
}

variable "memory_mib" {
  description = <<-EOT
    RAM for the node, in MiB. The host has 15Gi total and cannot overcommit it
    meaningfully, so this is spent, not shared — leave enough for the host's
    own userland and qemu's per-VM overhead before spending the rest here.
  EOT
  type        = number
  default     = 4096
}

# --- Storage --------------------------------------------------------------
# One disposable system disk, plus one persistent data disk per service class
# the platform offers. Two classes today (`fast`, `bulk`), so three disks. A
# third class later is a fourth disk and no redesign.
#
# Two independent reasons force data off the system disk, neither about
# hardware: (1) `terraform destroy` of the VM must not destroy data, which is
# what makes the VM a rehearsal of the bare-metal rebuild rather than a
# liability; (2) blast radius — a runaway PVC fills its own volume instead of
# the whole node.

variable "system_pool" {
  description = "libvirt pool for the disposable system disk. SSD-backed (host_prereqs)."
  type        = string
}

variable "fast_pool" {
  description = "libvirt pool for the durable low-latency data disk. SSD-backed (host_prereqs)."
  type        = string
}

variable "bulk_pool" {
  description = <<-EOT
    libvirt pool for the durable high-capacity data disk. HDD-backed, and
    defined by the bulk_storage Ansible role rather than host_prereqs so that
    it sits behind that role's /mnt/storage mount assert — an unmounted disk at
    image-creation time would silently put this volume on the SSD.
  EOT
  type        = string
}

variable "system_disk_gib" {
  description = <<-EOT
    System disk size. Sparse: qemu-img raw on ext4 consumes only written
    blocks, so the declared size is a ceiling rather than a reservation.
    That is load-bearing here, not an optimisation — / is a 128G SSD carrying
    both the system and fast images. It is also the familiar
    thin-provisioning hazard: three sparse images can collectively overcommit
    /, and host df will under-report the commitment. Needs a host-level alert
    on / free space; the guest will keep writing happily until / fills under it.
  EOT
  type        = number
  default     = 20
}

variable "fast_disk_gib" {
  description = "Durable low-latency data disk size (the `fast` StorageClass)."
  type        = number
  default     = 20
}

variable "bulk_disk_gib" {
  description = "Durable high-capacity data disk size (the `bulk` StorageClass). The HDD has 870G free."
  type        = number
  default     = 100
}

# --- Networking -----------------------------------------------------------

variable "network_name" {
  description = "libvirt network to attach to. NAT + DHCP reservation, defined by host_prereqs."
  type        = string
}

variable "node_ip" {
  description = <<-EOT
    Static address of the node. Known before bootstrap on purpose: it is both
    the cluster endpoint and the machine.certSANs entry, and a DHCP-assigned
    address would make that a chicken-and-egg problem.

    Precisely, because the distinction bites the moment a VIP exists:
    machine.certSANs covers apid/trustd/the kubelet, NOT the apiserver. The
    apiserver's certificate covers this address only because it happens to be
    cluster_endpoint. Once the endpoint becomes a VIP, individual node
    addresses stop being covered and kubectl aimed straight at a node fails
    x509 — so a multi-node build must set cluster.apiServer.certSANs
    explicitly. See docs/fleet/fleet-provisioning-design-notes.md §6.5.
  EOT
  type        = string
}

variable "node_gateway" {
  description = "Default gateway — the host side of the libvirt NAT network."
  type        = string
}

variable "node_cidr_prefix" {
  description = "Prefix length for node_ip."
  type        = number
  default     = 24
}

variable "node_mac" {
  description = "Fixed MAC. Must match the DHCP reservation in the libvirt network, which is what answers for the node in maintenance mode before any machine config exists."
  type        = string
}

variable "nameservers" {
  description = "Resolvers for the node."
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

# --- Secrets --------------------------------------------------------------

variable "machine_secrets" {
  description = <<-EOT
    The Talos PKI, generated OUT OF BAND with `talosctl gen secrets` and stored
    SOPS-encrypted in this repo — not generated by Terraform.

    This is what keeps Terraform's lack of state encryption from mattering.
    The age-encrypted file is authoritative; anything the state file holds is a
    derived copy, so losing or leaking tfstate does not make it a second root
    secret and the trust chain still terminates at the one age key.

    Shape matches the provider's machine_secrets schema, NOT talosctl's
    on-disk format — the two disagree on several key names. scripts/
    gen-talos-secrets.sh does the translation; see its comment.
  EOT
  type        = any
  sensitive   = true
}

variable "google_operator_email" {
  description = <<-EOT
    Google account allowed to authenticate to the cluster via OIDC, checked by
    an AuthenticationConfiguration claimValidationRules expression. Not a
    credential — RBAC still gates everything a matched identity can do. Kept
    out of state the same way machine_secrets is not: this is PII rather than
    a secret, but it is the value most likely to need rotating later, so it is
    templated into the rendered config rather than committed.
  EOT
  type        = string
  sensitive   = true
}

variable "base_image_path" {
  description = <<-EOT
    Absolute path to the decompressed Talos disk image on the host, staged by
    scripts/stage-talos-image.sh. Staged outside Terraform because the Image
    Factory serves .raw.xz and libvirt_volume's create.content.url has no
    decompression step.
  EOT
  type        = string
}
