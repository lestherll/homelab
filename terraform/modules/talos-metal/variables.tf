variable "cluster_name" {
  description = "Talos cluster name."
  type        = string
}

variable "cluster_endpoint_ip" {
  description = <<-EOT
    Address the Kubernetes API is reached on, and the node Terraform talks to.

    Single control plane, so this is that node's address rather than a VIP.
    Adding a VIP later does NOT require a rebuild: it is a certSANs entry plus
    a network patch, and certSANs regenerate the affected leaf certificates in
    seconds — see machine-2-first-build-plan.md §4.4, which corrects an earlier
    claim that this was rebuild-only.
  EOT
  type        = string
}

variable "nodes" {
  description = <<-EOT
    The node list — the item provisioning-automation-without-netboot.md §3.1
    calls the highest-value piece of the whole design.

    Keyed by hostname. `mac` is what the machine config's interface selector
    matches on: never the interface NAME, because an interfaces entry naming a
    device that does not exist is ignored SILENTLY, and the failure mode is a
    node that quietly stays on DHCP.

    `machine_type` is `controlplane` or `worker`. Exactly one node bootstraps
    the cluster, and only ever once — see talos.tf.
  EOT
  type = map(object({
    ip           = string
    mac          = string
    machine_type = string
  }))

  validation {
    condition     = length([for k, v in var.nodes : k if v.machine_type == "controlplane"]) == 1
    error_message = "Exactly one controlplane node. Two control planes tolerate as many failures as one while adding a member that must agree (multi-node-ha-design-notes.md §1); HA waits for a third machine."
  }

  validation {
    condition     = alltrue([for k, v in var.nodes : contains(["controlplane", "worker"], v.machine_type)])
    error_message = "machine_type must be controlplane or worker."
  }
}

variable "gateway" {
  description = "Default gateway on the wired LAN."
  type        = string
}

variable "cidr_prefix" {
  description = "Prefix length for node addresses."
  type        = number
  default     = 24
}

variable "nameservers" {
  description = "Upstream DNS."
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

variable "talos_version" {
  description = "Talos version, e.g. v1.13.8."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version Talos renders control-plane manifests for."
  type        = string
}

variable "install_image" {
  description = <<-EOT
    Image Factory installer reference, including the schematic ID.

    The schematic carries siderolabs/iscsi-tools and siderolabs/util-linux-tools,
    which Longhorn needs to attach volumes at all (ADR 0001 §8.1).

    Read terraform-on-bare-metal.md §3's second rule before changing this: the
    installed image changes by `talosctl upgrade`, NEVER by apply-config.
    Applying a config to an already-installed node does not re-run the
    installer, so a node whose installed image lacks the extensions keeps the
    wrong image SILENTLY.
  EOT
  type        = string
}

variable "extra_cert_sans" {
  description = <<-EOT
    Additional certSANs beyond each node's own address and loopback.

    Be generous: talos.tf in the sibling module records what a MISSING certSAN
    costs — talos_machine_bootstrap HANGS rather than errors, because the
    provider retries a failure that can never clear. Cheap to add, and not
    rebuild-only.
  EOT
  type        = list(string)
  default     = []
}

variable "machine_secrets" {
  description = "Talos PKI, supplied from SOPS. Never a talos_machine_secrets resource — see talos.tf."
  type        = any
  sensitive   = true
}

variable "longhorn_disks" {
  description = <<-EOT
    Longhorn disks to declare on each node, as the node.longhorn.io
    default-disks-config annotation.

    machine-2-first-build-plan.md §4.1: machine 2 has ONE SSD, and `fast` and
    `bulk` are public API (rgd-database.yaml hardcodes `fast`;
    rgd-application.yaml enumerates both). So both tags live on the one disk.
    An SSD over-delivers on `bulk`'s guarantee rather than under-delivering,
    and classes name guarantees rather than devices (golden-architecture.md §3).

    THESE MUST BE RIGHT AT FIRST REGISTRATION. The annotation "only takes
    effect when there are no existing disks or tags on the node", so a mistake
    here is the Longhorn UI forever, or another rebuild. Setting it from the
    machine config — rather than by annotating the Node afterwards — is what
    guarantees it is present before Longhorn ever sees the node.
  EOT
  type = list(object({
    path            = string
    allowScheduling = bool
    tags            = list(string)
  }))
}

variable "google_operator_email" {
  description = <<-EOT
    Google account allowed to authenticate to the cluster via OIDC.

    NOT a credential — an allow-list entry checked by claimValidationRules;
    RBAC (infrastructure/human-auth/) still gates everything it can do. Kept
    out of git because it is PII, not because it is secret, and supplied via
    TF_VAR_google_operator_email.

    NOTE the inconsistency this inherits from the VM module, worth resolving
    rather than copying forever: infrastructure/human-auth/rbac.yaml already
    commits the same address in plain text, because a RoleBinding subject
    cannot be a variable. So the value is in git regardless, and the only thing
    this pattern buys today is that it is in ONE place instead of two.
  EOT
  type        = string
  sensitive   = true
}
