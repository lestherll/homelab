# The Talos half on bare metal: preflight, machine config, apply, bootstrap.
#
# The PKI design is carried over from modules/talos-cluster/ UNCHANGED, and
# terraform-on-bare-metal.md §1 is explicit that it must not be reopened:
# secrets are generated out of band and SOPS-encrypted (that file is
# authoritative), they enter as a variable rather than a talos_machine_secrets
# resource, the rendered config is EPHEMERAL so it is never persisted, and it
# reaches the provider through write-only (_wo) arguments. Terraform has no
# state encryption at any version, so this is what keeps tfstate from becoming
# a second root secret. D12's single root key survives the move to metal.
#
# What is NEW here, all four from terraform-on-bare-metal.md:
#   §2  the address is static from the first apply; DHCP covers only the
#       maintenance window
#   §3  maintenance mode is two states, and apply-config never re-runs the
#       installer — the image changes by `talosctl upgrade` only
#   §4  the ordering edge libvirt used to provide (terraform_data below)
#   §5  the Cilium seed, without which the cluster cannot bootstrap itself

locals {
  # Asserted rather than transformed — scripts/gen-talos-secrets.sh already
  # writes the provider's key spelling, so a shape mismatch is a plan-time
  # error instead of an apply-time one.
  machine_secrets = var.machine_secrets

  controlplane_node = one([for k, v in var.nodes : k if v.machine_type == "controlplane"])

  # Longhorn's disk layout, delivered as a Node annotation from the machine
  # config so it is present BEFORE Longhorn first registers the node. See
  # variables.tf — this is the setting whose cost, if wrong, is a rebuild.
  longhorn_disks_config = jsonencode(var.longhorn_disks)

  tailnet_enabled = var.tailnet_domain != ""

  # Each node's MagicDNS name, DERIVED rather than configured. TS_HOSTNAME
  # below is set to the same `each.key` that HostnameConfig sets, so this is
  # not a guess about what Tailscale will pick — it is the value we hand it.
  #
  # Deriving it is the whole point: this is the one address in the module that
  # a new router, a new DHCP scope or a renumbered LAN cannot invalidate.
  tailnet_names = {
    for k, v in var.nodes : k => local.tailnet_enabled ? "${k}.${var.tailnet_domain}" : null
  }
}

# Gap four (§5): with cluster.network.cni.name=none the node is NotReady until
# a CNI arrives, Talos reboots to retry every 10 minutes, and Flux cannot break
# the circularity because its controllers are pods that need pod networking.
# Talos applies inlineManifests during bootstrap — inside Terraform's window.
# The apiserver's identity providers.
#
# WHY THIS EXISTS ON A CLUSTER REACHED OVER THE TAILNET: the apiserver's
# tailnet exposure is a ProxyGroup in `mode: noauth`, which deliberately does
# NOT forward client certificates — it forwards every request unmodified so a
# caller's own bearer token reaches the apiserver intact. That is what makes
# per-repo isolation generic (an admission policy reading the token's claims)
# instead of one tailnet tag per app repo. The consequence is that
# client-cert kubectl works only on the LAN, and ANY off-LAN access —
# CI's GitHub token or the operator's Google token — needs this file.
#
# AuthenticationConfiguration replaces the legacy `oidc-*` apiServer flags,
# and the two are mutually exclusive: the flags support exactly one issuer,
# which is what forces both issuers into one file here.
locals {
  authentication_configuration_yaml = <<-EOT
    apiVersion: apiserver.config.k8s.io/v1
    kind: AuthenticationConfiguration
    jwt:
      - issuer:
          url: https://token.actions.githubusercontent.com
          audiences:
            # MUST match the audience CI actually requests
            # (`&audience=homelab-k8s` in each app repo's register.yml), not
            # GitHub's default audience. Using the default silently broke every
            # CI call to the VM cluster for five days — see talos.tf's note.
            - homelab-k8s
        claimMappings:
          username:
            claim: sub
            prefix: "gha:"
          groups:
            claim: repository_owner
            prefix: "gha:"
      - issuer:
          url: https://accounts.google.com
          audiences:
            - 645380473983-4r5f3jhh1thajbun7bj1t28o4o4mds0d.apps.googleusercontent.com
        claimMappings:
          username:
            claim: email
            prefix: "google:"
          # No groups claim mapped — single user, and RBAC
          # (infrastructure/human-auth/) binds the username directly rather
          # than inventing a group.
        claimValidationRules:
          - expression: "claims.email == '${var.google_operator_email}'"
            message: "only the operator's account may authenticate"
          - expression: "claims.email_verified == true"
            message: "unverified email"
  EOT
}

locals {
  cilium_seed = file("${path.module}/cilium-seed.yaml")

  common_patches = [
    yamlencode({
      machine = {
        # Generous on purpose. A MISSING certSAN does not fail cleanly:
        # talos_machine_bootstrap HANGS, because the provider retries a
        # failure that can never clear. Not rebuild-only, so adding one later
        # is seconds — but paying that here costs nothing.
        certSANs = concat(["127.0.0.1", "localhost"], var.extra_cert_sans)

        nodeLabels = {
          # Longhorn honours the annotation below only with this label set.
          "node.longhorn.io/create-default-disk" = "config"
        }
        nodeAnnotations = {
          "node.longhorn.io/default-disks-config" = local.longhorn_disks_config
        }

        kubelet = {
          # Required by metrics-server, and this half ALONE DOES NOTHING: the
          # other half is the kubelet-serving-cert-approver deployed beside it,
          # because kube-controller-manager deliberately does not auto-approve
          # kubelet-serving CSRs. Both halves or neither — otherwise the CSR
          # sits Pending forever and the kubelet keeps its self-signed cert,
          # which is the same symptom as not setting this at all.
          extraArgs = {
            rotate-server-certificates = "true"
          }
          # Longhorn's data paths must be visible to the kubelet, and rshared
          # so volume mounts propagate.
          extraMounts = [
            for d in var.longhorn_disks : {
              destination = d.path
              type        = "bind"
              source      = d.path
              options     = ["bind", "rshared", "rw"]
            }
          ]
        }
      }
      cluster = {
        # Single node: without this every workload stays Pending forever
        # against a control-plane taint nothing tolerates.
        allowSchedulingOnControlPlanes = true

        # Unlike the CNI and kube-proxy settings below, the apiserver is a
        # Talos STATIC POD rather than a bootstrap manifest — so this lands on
        # an ordinary `terraform apply` and does NOT need a rebuild.
        #
        # Risk worth naming: single control plane. Malformed config here means
        # the apiserver does not come back, with nothing to fall back on.
        # Recovery is reverting the machine config with talosctl, which works
        # because the PKI is in SOPS rather than in tfstate.
        apiServer = {
          extraArgs = {
            authentication-config = "/etc/kubernetes/auth/authentication-config.yaml"
          }
          extraVolumes = [{
            # hostPath must be under /var — see the machine.files patch.
            # mountPath is the in-container path and is unconstrained.
            hostPath  = "/var/etc/kubernetes/auth"
            mountPath = "/etc/kubernetes/auth"
            readonly  = true
          }]
        }

        # Cilium-only (cilium-only-networking.md). Both of these are Talos
        # BOOTSTRAP MANIFESTS and do not retrofit a running cluster — Talos
        # re-renders, reports no error, and leaves live objects untouched. They
        # land on a rebuild, which is why they must be right the first time.
        network = { cni = { name = "none" } }
        proxy   = { disabled = true }
      }
    }),

    yamlencode({
      machine = {
        files = [{
          op = "create"
          # MUST be under /var. Talos's root filesystem is a read-only
          # squashfs, and `op: create` outside /var fails at boot with "create
          # operation not allowed outside of /var", which then wedges the node
          # in a 35-minute reboot loop — the kubelet cannot write its bootstrap
          # PKI either once the boot is degraded. Learned live on the VM
          # cluster, 2026-08-17/18.
          path = "/var/etc/kubernetes/auth/authentication-config.yaml"
          # 420 decimal == 0o644. NOT 0o600: the apiserver container reads this
          # as a non-root process and an owner-only file crash-loops it with
          # "permission denied" — learned in the same incident. World-readable
          # is fine: the mount is read-only and the content is an email plus an
          # already-public OAuth client ID.
          permissions = 420
          content     = local.authentication_configuration_yaml
        }]
      }
    }),
  ]
}

# Gap three (§4): libvirt used to supply the ordering edge — talos.tf in the
# sibling module carries `depends_on = [libvirt_domain.node]`, commented "the
# domain has to be running and in maintenance mode before config can land." On
# metal there is no resource to depend on.
#
# A BLIND WAIT is the shape of failure this repo has already paid for once (see
# the certSANs note above, where the provider hung instead of erroring). So
# this fails fast, with the address in the message.
resource "terraform_data" "maintenance_ready" {
  for_each = var.nodes

  input = each.value.ip

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
      i=0
      while [ $i -lt 60 ]; do
        if nc -z -w2 ${each.value.ip} 50000 2>/dev/null; then exit 0; fi
        i=$((i+1)); sleep 5
      done
      echo "not reachable on ${each.value.ip}:50000 after 5m — is ${each.key} powered on and in maintenance mode?" >&2
      exit 1
    EOT
  }
}

ephemeral "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${var.cluster_endpoint_ip}:6443"
  machine_type       = each.value.machine_type
  machine_secrets    = local.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(
    local.common_patches,
    [
      # Hostname is its OWN document in Talos v1.13, not a v1alpha1 field.
      # `auto: off` is required, not decorative: a patch MERGES into the
      # generated document, so the generated `auto: stable` survives and Talos
      # rejects the pair with "'auto' and 'hostname' cannot be set at the same
      # time". Neither `$patch: replace`, `auto: ""` nor `auto: null` work.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HostnameConfig"
        auto       = "off"
        hostname   = each.key
      }),
      yamlencode({
        machine = {
          install = {
            # §3: this does NOT re-run the installer on an already-installed
            # node. Changing the installed image is `talosctl upgrade`.
            image = var.install_image
          }
          # Talos APPENDS list values across patches rather than replacing
          # them, which is why 127.0.0.1/localhost from common_patches survive
          # this entry rather than being overwritten by it.
          #
          # The tailnet name is what `talosctl config endpoint` is pointed at
          # off-LAN, and TLS is verified against the name DIALLED — so omitting
          # it does not degrade to "works but unverified", it fails every
          # authenticated call with "certificate is valid for <ip>, not
          # <name>". The node's own 100.x address is deliberately NOT here: it
          # is not known until the node first joins, and dialling by name means
          # nothing ever needs it.
          certSANs = compact([each.value.ip, local.tailnet_names[each.key]])
          network = {
            # By MAC, never by name. An interfaces entry naming a device that
            # does not exist is ignored SILENTLY, and the failure mode is a
            # node that quietly stays on DHCP — indistinguishable from success
            # until the lease moves.
            interfaces = [{
              deviceSelector = { hardwareAddr = each.value.mac }
              addresses      = ["${each.value.ip}/${var.cidr_prefix}"]
              routes = [{
                network = "0.0.0.0/0"
                gateway = var.gateway
              }]
            }]
            nameservers = var.nameservers
          }
        }
      }),
    ],

    # The tailnet identity: a separate v1alpha1 DOCUMENT, not a v1alpha1 field,
    # so it is its own patch exactly like HostnameConfig above.
    #
    # WHY THE NODE AND NOT A SUBNET ROUTER: the alternative is machine 1
    # advertising the LAN as a subnet route, which routes the bare-metal node's
    # ONLY diagnostic path through a different machine — and "machine 1 is
    # down" is a case you actively want talosctl for
    # (fleet-provisioning-design-notes.md §6.4). It also dies with machine 1.
    #
    # THE PORT LIST IS THE SECURITY BOUNDARY, NOT THE ROUTE. Putting the node
    # on the tailnet puts its whole listening surface one grant away, and it is
    # not all authenticated: measured 2026-09-03, :9100 on this node answers
    # HTTP 200 with no auth at all (node-exporter, hostNetwork, privileged
    # namespace). policy.hujson grants tcp:50000 and nothing else, and its
    # tests block denies the rest so a widening cannot pass silently.
    !local.tailnet_enabled ? [] : [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "ExtensionServiceConfig"
        name       = "tailscale"
        environment = [
          "TS_AUTHKEY=${var.tailscale_authkey}",

          # Same value as HostnameConfig above, so the MagicDNS name is
          # `<node>.<tailnet_domain>` — the derived, renumber-proof handle in
          # local.tailnet_names, and the certSAN issued two patches up.
          "TS_HOSTNAME=${each.key}",

          # containerboot's default is FALSE, which means it runs
          # `tailscale up --authkey` on EVERY service start. Talos restarts
          # this service on every boot, so the default quietly makes each
          # reboot depend on a key Tailscale caps at 90 days — a node that
          # rebooted after expiry would drop off the tailnet with the machine
          # config still looking correct. Verified against containerboot
          # v1.98.9 (settings.go: defaultBool("TS_AUTH_ONCE", false)).
          "TS_AUTH_ONCE=true",

          # Belt and braces: this is containerboot's behaviour when the var is
          # unset (AcceptDNS is a *bool; nil renders --accept-dns=false), but
          # it is upstream's default rather than ours, and the consequence of
          # it flipping is the node's resolver silently becoming MagicDNS on a
          # single control plane. machine.network.nameservers is meant to be
          # the only thing that decides this.
          "TS_ACCEPT_DNS=false",

          # The ACL destination. A tag rather than an address is what lets
          # policy.hujson survive this node being renumbered or replaced.
          "TS_EXTRA_ARGS=--advertise-tags=${join(",", var.tailscale_tags)}",
        ]
      })
    ],

    # The seed goes on CONTROL-PLANE configs only, and identical across them —
    # Sidero's own Cilium guide is explicit about both.
    each.value.machine_type != "controlplane" ? [] : [
      yamlencode({
        cluster = {
          inlineManifests = [{
            name     = "cilium-seed"
            contents = local.cilium_seed
          }]
        }
      })
    ],
  )
}

ephemeral "talos_client_configuration" "cluster" {
  cluster_name    = var.cluster_name
  machine_secrets = local.machine_secrets
  endpoints       = [var.cluster_endpoint_ip]
  nodes           = [for k, v in var.nodes : v.ip]
}

resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  # _wo (write-only): sent to the provider, never recorded in state.
  client_configuration_wo        = ephemeral.talos_client_configuration.cluster.client_configuration
  machine_configuration_input_wo = ephemeral.talos_machine_configuration.node[each.key].machine_configuration
  node                           = each.value.ip

  # Returns the machine to maintenance mode on destroy, which restores the
  # rehearsal property the VM had and bare metal otherwise loses. NOTE its
  # caveat: a change to on_destroy must be applied BEFORE the destroy that
  # relies on it.
  on_destroy = {
    reset    = true
    graceful = false
    reboot   = true
  }

  depends_on = [terraform_data.maintenance_ready]

  timeouts = {
    create = "10m"
  }
}

# Exactly one node, exactly once, ever. The variable validation upstream is
# what guarantees "one".
resource "talos_machine_bootstrap" "cluster" {
  client_configuration_wo = ephemeral.talos_client_configuration.cluster.client_configuration
  node                    = var.nodes[local.controlplane_node].ip

  depends_on = [talos_machine_configuration_apply.node]

  timeouts = {
    create = "10m"
  }
}
