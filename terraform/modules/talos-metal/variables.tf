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
    which Longhorn needs to attach volumes at all (ADR 0001 §8.1), plus
    siderolabs/tailscale, which is what puts each node on the tailnet in its own
    right (docs/fleet/talosctl-off-lan.md).

    The tailscale extension is NOT interchangeable with the rest of this
    module's settings: system extensions change only at install or upgrade, so
    var.tailnet_domain and var.tailscale_authkey below are inert on a node whose
    installed image predates this schematic — the ExtensionServiceConfig lands,
    names a service that does not exist, and nothing starts.

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
    Additional certSANs beyond each node's own address, its tailnet name and
    loopback.

    Be generous: talos.tf in the sibling module records what a MISSING certSAN
    costs — talos_machine_bootstrap HANGS rather than errors, because the
    provider retries a failure that can never clear. Cheap to add, and not
    rebuild-only.

    Each node's `<hostname>.<tailnet_domain>` is added automatically by talos.tf
    and does NOT belong here. What does belong here is anything not derivable:
    a future VIP, or a node's 100.x tailnet address if you ever want to dial one
    by IP rather than by name.
  EOT
  type        = list(string)
  default     = []
}

variable "tailnet_domain" {
  description = <<-EOT
    The tailnet's MagicDNS domain, e.g. `tailf4742d.ts.net`.

    This is what makes `talosctl` work off-LAN without pinning a single raw
    address anywhere: each node's certSAN becomes `<hostname>.<tailnet_domain>`,
    which is stable by construction — it is derived from the Talos hostname,
    which this module also sets. A LAN address can be renumbered by a new
    router; a MagicDNS name cannot.

    Set to "" to build a cluster with no tailnet identity at all, which also
    skips the ExtensionServiceConfig below. Not the intended mode — see
    docs/fleet/talosctl-off-lan.md — but a cluster that has not been given an
    auth key yet should fail on the auth key, not on a half-configured service.

    NOT a secret: it is already in git in a dozen places (ansible/inventory/
    hosts.ini, most of docs/), and knowing a tailnet's name grants nothing.
  EOT
  type        = string
  default     = ""
}

variable "tailscale_authkey" {
  description = <<-EOT
    Tailscale auth key for the nodes' `siderolabs/tailscale` extension.

    Supplied out of band via TF_VAR_tailscale_authkey, the same pattern as
    machine_secrets — it reaches the provider only through the ephemeral
    machine configuration, so it is never written to tfstate.

    Mint it **tagged** (`tag:talos`, matching var.tailscale_tags) and
    **reusable**: one key configures every node in var.nodes. Tailscale caps
    key lifetime at 90 days, so this WILL expire. That is survivable rather
    than fatal because talos.tf sets TS_AUTH_ONCE=true: a node that has already
    joined keeps its tailnet identity in /var/lib/tailscale across reboots and
    never re-reads the key. An expired key only bites a node being built or
    `reset` — which is exactly when you would be minting one anyway.

    Required when tailnet_domain is set. There is no default: a silently
    tailnet-less node is the failure this whole change exists to remove.
  EOT
  type        = string
  default     = ""
  sensitive   = true

  # Cross-variable validation, which needs Terraform 1.9+ — versions.tf already
  # floors at 1.11. Without this the failure is the quiet one: the node builds,
  # certSANs name a tailnet address it never obtains, and nothing says why until
  # someone tries `talosctl` from off-LAN weeks later.
  validation {
    condition     = var.tailnet_domain == "" || var.tailscale_authkey != ""
    error_message = "tailnet_domain is set, so tailscale_authkey must be too — export TF_VAR_tailscale_authkey (see terraform/README.md)."
  }
}

variable "tailscale_tags" {
  description = <<-EOT
    ACL tags each node advertises, as `--advertise-tags`.

    This is the destination the tailnet policy grants on. A TAG rather than an
    address is the point: `tailscale-acl/policy.hujson` names `tag:talos` and
    keeps working when a node is renumbered, renamed or replaced, whereas its
    old `hosts` entry for the VM pinned `10.10.0.10` and has to be re-edited
    every time that address moves.

    The auth key must be authorised for these tags, and `tagOwners` in
    policy.hujson must list an owner who may mint them.
  EOT
  type        = list(string)
  default     = ["tag:talos"]

  validation {
    condition     = alltrue([for t in var.tailscale_tags : startswith(t, "tag:")])
    error_message = "Tailscale tags must be written in full, as tag:<name>."
  }
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
