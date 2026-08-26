# The Talos half: machine config, apply, bootstrap.
#
# The governing constraint here is that the Talos PKI must not become a second
# root secret. Terraform has no state encryption at any version — that is a
# property of the backend, not the CLI, and Terraform 1.10's ephemeral values
# are a different thing. So rather than encrypt state, this module arranges for
# state never to hold the authoritative copy:
#
#   1. Secrets are generated out of band (`talosctl gen secrets`) and stored
#      SOPS-encrypted under the existing age key. That file is authoritative.
#   2. They enter Terraform as a variable, not a talos_machine_secrets resource.
#   3. The rendered machine config and the kubeconfig are produced by EPHEMERAL
#      resources, which by construction are never persisted to state.
#   4. They reach talos_machine_configuration_apply through write-only (_wo)
#      arguments, which Terraform sends to the provider without recording.
#
# The result is Terraform proper — no OpenTofu divergence — with D12's single
# root key intact.

locals {
  # talosctl's secrets.yaml and the provider's machine_secrets schema disagree
  # on several key names, so this translation is unavoidable rather than
  # stylistic. Verified against both, 2026-08-16:
  #   talosctl              provider
  #   certs.*.crt        →  certs.*.cert
  #   certs.k8saggregator     → certs.k8s_aggregator
  #   certs.k8sserviceaccount → certs.k8s_serviceaccount
  #   secrets.bootstraptoken  → secrets.bootstrap_token
  #   secrets.secretboxencryptionsecret → secrets.secretbox_encryption_secret
  #
  # Done in scripts/gen-talos-secrets.sh so the encrypted file already holds
  # the provider's shape; this local only asserts it rather than transforming,
  # which keeps a shape mismatch a plan-time error instead of an apply-time one.
  machine_secrets = var.machine_secrets

  # AuthenticationConfiguration replaces the legacy `oidc-*` apiServer flags
  # below — the two are mutually exclusive, one issuer vs. many, which is why
  # adding the Google issuer forced migrating the existing GitHub Actions
  # trust into this file rather than adding it alongside the flags. Delivered
  # onto Talos's immutable filesystem via machine.files (writes the YAML) +
  # apiServer.extraVolumes (mounts it into the apiserver static pod) — no
  # node reboot, but `terraform apply` does restart the apiserver, and its
  # tailnet proxy is fate-shared with it (see AGENT.md).
  #
  # google_operator_email is a Terraform variable, not a literal, because an
  # operator's personal email is PII this repo's public GitHub OIDC audience
  # doesn't want committed — mirrors machine_secrets' out-of-band pattern,
  # supplied via TF_VAR_google_operator_email at apply time.
  authentication_configuration_yaml = <<-EOT
    apiVersion: apiserver.config.k8s.io/v1
    kind: AuthenticationConfiguration
    jwt:
      - issuer:
          url: https://token.actions.githubusercontent.com
          audiences:
            # MUST match the audience CI actually requests
            # (`&audience=homelab-k8s` in each app repo's register.yml), not
            # GitHub's default audience. The default is the repository-owner
            # URL, `https://github.com/lestherll`, which is what this said
            # from the AuthenticationConfiguration migration (1d802bb) until
            # 2026-08-26 — plausible-looking, and it silently broke every CI
            # call to the cluster for five days.
            #
            # A deliberately-chosen audience is a scoping control, which is
            # the reason not to use the default: a token GitHub minted for
            # some other integration cannot be replayed against the cluster,
            # because it carries that integration's audience rather than this
            # one. Changing this value means changing register.yml in every
            # app repo at the same time.
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
          # No groups claim mapped — single user, RBAC binds the username
          # directly (infrastructure/human-auth/) rather than inventing a group.
        claimValidationRules:
          - expression: "claims.email == '${var.google_operator_email}'"
            message: "only the operator's account may authenticate"
          - expression: "claims.email_verified == true"
            message: "unverified email"
  EOT

  # Patches carry everything the provider does not model as a first-class
  # argument. Kept as separate documents rather than one blob so a failing
  # patch names itself.
  config_patches = [
    # Hostname is its OWN document in Talos v1.13, not a v1alpha1 field.
    # `talosctl gen config` emits a HostnameConfig with `auto: stable`, so
    # setting machine.network.hostname as well is rejected outright with
    # "static hostname is already set in v1alpha1 config" — the two are
    # alternatives, not layers. The v1alpha1 field still exists and is still
    # documented, which is exactly why this is easy to get wrong.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      # `auto: off` is required, not decorative. A patch document MERGES into
      # the generated one rather than replacing it, so the generated
      # `auto: stable` survives and Talos then rejects the pair with "'auto'
      # and 'hostname' cannot be set at the same time". `$patch: replace` is
      # not accepted on this document ("unknown keys found during decoding"),
      # and neither `auto: ""` nor `auto: null` decode. `off` is the value that
      # works — verified with `talosctl machineconfig patch` + `validate`
      # against v1.13.8, 2026-08-16.
      auto     = "off"
      hostname = var.node_hostname
    }),

    yamlencode({
      machine = {
        # certSANs is REQUIRED here, not belt-and-braces. Talos issues the apid
        # certificate covering only what it is told, plus loopback. Without this
        # the cert carries just `DNS:<hostname>, IP:127.0.0.1`, and every
        # authenticated call from the host fails with "certificate is valid for
        # 127.0.0.1, not <node_ip>" — including talos_machine_bootstrap, which
        # then HANGS rather than errors, because the provider keeps retrying a
        # failure that can never clear.
        certSANs = [var.node_ip]

        # Required by metrics-server (infrastructure/metrics-server/), and this
        # half alone does nothing — see the second half below.
        # By default a Talos kubelet serves a SELF-SIGNED certificate
        # on :10250, so metrics-server's scrape fails x509 validation and
        # `kubectl top` returns "metrics not available" with the reason visible
        # only in the metrics-server log. This flag makes the kubelet request a
        # serving cert from the cluster CA instead.
        #
        # The other half is the kubelet-serving-cert-approver deployed
        # alongside metrics-server: kube-controller-manager's built-in CSR
        # approver deliberately does NOT auto-approve kubernetes.io/kubelet-
        # serving CSRs, so without it the CSR sits Pending forever and the
        # kubelet keeps serving its self-signed cert — same symptom as not
        # setting this at all. Both halves or neither.
        #
        # This is the path Talos documents. The alternative,
        # metrics-server's --kubelet-insecure-tls, was rejected: it is
        # defensible on a single node where the scrape never leaves the box,
        # but D3 plans a second machine, and that is exactly when a disabled
        # TLS check stops being local and nobody remembers it is set.
        kubelet = {
          extraArgs = {
            rotate-server-certificates = "true"
          }
        }

        network = {
          # Matched by MAC rather than by interface name. Talos does in fact
          # name this `eth0` (verified on the running node), so `interface:
          # eth0` would work today — but it is a property of this VM's single
          # virtio NIC, not a guarantee, and an interfaces entry naming a device
          # that does not exist is ignored SILENTLY rather than rejected. The
          # failure mode is a node that quietly stays on DHCP.
          #
          # The MAC is already pinned in two other places — the domain's
          # interface, and the DHCP reservation that answers for the node in
          # maintenance mode before any config exists — so selecting on it keeps
          # all three tied to one value.
          interfaces = [{
            deviceSelector = {
              hardwareAddr = var.node_mac
            }
            addresses = ["${var.node_ip}/${var.node_cidr_prefix}"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.node_gateway
            }]
          }]
          nameservers = var.nameservers
        }
      }
      cluster = {
        # Single-node: without this, every workload stays Pending forever
        # against a control-plane taint nothing will ever tolerate. This is a
        # day-one requirement tied to single-node, not something to add when a
        # second machine arrives.
        allowSchedulingOnControlPlanes = true

        # Talos binds kube-proxy's metrics to 127.0.0.1; k3s bound them to all
        # interfaces. kube-prometheus-stack ships a kube-proxy ServiceMonitor
        # enabled by default, so on Talos it scrapes the node IP and gets
        # `connect: connection refused` — one permanently-down target, and
        # KubeProxyDown/TargetDown firing in Alertmanager forever.
        #
        # Exposing the endpoint rather than deleting the ServiceMonitor: the
        # metrics are real and the alert is correctly telling us they are
        # unreachable. Silencing the scrape would leave kube-proxy genuinely
        # unmonitored and hide the next, real, outage of it.
        #
        # Safe on this topology — 10.10.0.10 is a host-only libvirt network
        # reachable from the host and the pod network, not from the LAN.
        #
        # CAVEAT, and it applies to kube-proxy, CoreDNS and flannel alike:
        # THIS DOES NOT RETROFIT A RUNNING CLUSTER. These are Talos *bootstrap*
        # manifests. Talos re-renders them from config immediately — the
        # Manifest resource goes to version 2 and ManifestApplyController runs
        # without error — but it does not push the new render onto an object
        # that already exists. Verified on v1.13.8, 2026-08-16: config on the
        # node carried the flag, `talosctl get manifest 10-kube-proxy` showed
        # `--metrics-bind-address=0.0.0.0`, and the live DaemonSet stayed at
        # generation 1 without it. The object is stamped
        # `config.k8s.io/owning-inventory: talos-bootstrap-manifests-inventory`
        # and owned by `talos / Apply`, which is the tell.
        #
        # So a change here reaches the cluster on a REBUILD, not on an apply.
        # To land it on a live cluster, patch the object to match what Talos
        # rendered (`talosctl get manifest <id> -o yaml` is the source of
        # truth — that is not drift, it is catching up). The failure is silent:
        # terraform reports success and the behaviour does not change. See
        # AGENT.md for the same caveat as an operational fact.
        proxy = {
          extraArgs = {
            metrics-bind-address = "0.0.0.0"
          }
        }

        # Trust GitHub Actions and Google as OIDC identity providers — GitHub
        # so an app repo's CI can authenticate with a token GitHub signs per
        # run and nothing is ever stored (what lets a new app register its own
        # Flux pointer objects without a commit to this repo), Google so the
        # operator can authenticate as themselves rather than through a static
        # kubeconfig credential. Both issuers, their claim mappings and the
        # Google email allow-list live in one AuthenticationConfiguration file
        # (local.authentication_configuration_yaml above) rather than as flags
        # here — the legacy `oidc-*` extraArgs support exactly one issuer,
        # which is what forced this migration.
        #
        # Identity for the GitHub issuer is the `sub` claim, which GitHub
        # builds from IDs rather than names:
        #   repo:<owner>@<owner-id>/<repo>@<repo-id>:<ref>
        # binding the caller to a specific repository rather than a name that
        # can be renamed or reused. Groups come from `repository_owner`, so
        # every repo under this account lands in one group (gha:lestherll)
        # that RBAC binds once; per-repo isolation deliberately does NOT come
        # from RBAC, it comes from a ValidatingAdmissionPolicy reading `sub`,
        # because RBAC cannot express "only the object matching your own
        # repository name". Both prefixes (`gha:`, `google:`) exist so a claim
        # value can never collide with a real Kubernetes user or a `system:`
        # identity.
        #
        # Unlike kube-proxy/CoreDNS/flannel, the apiserver is a Talos STATIC
        # POD, not a bootstrap manifest — so these land on `terraform apply`
        # rather than needing a rebuild. That distinction is the whole reason
        # this is cheap; see the bootstrap-manifests caveat in AGENT.md for the
        # class of change that is not.
        #
        # Risk worth naming: this is a single-node cluster and the apiserver is
        # a static pod. Malformed config here means it does not come back, with
        # no second control plane to fall back on. Recovery is reverting the
        # machine config with talosctl, which works because the PKI is in SOPS,
        # not in tfstate.
        apiServer = {
          extraArgs = {
            authentication-config = "/etc/kubernetes/auth/authentication-config.yaml"
          }
          extraVolumes = [{
            # hostPath must be under /var — see the machine.files comment
            # below for why. mountPath is unconstrained (it's the in-container
            # path, matched by extraArgs.authentication-config above) and
            # kept at the conventional /etc/kubernetes/auth for readability.
            hostPath  = "/var/etc/kubernetes/auth"
            mountPath = "/etc/kubernetes/auth"
            readonly  = true
          }]
        }
      }
    }),

    # The AuthenticationConfiguration file the apiServer.extraVolumes mount
    # above serves. A separate patch document from the machine/cluster one
    # above so a failure here names itself rather than hiding inside the big
    # patch.
    yamlencode({
      machine = {
        files = [{
          op = "create"
          # MUST be under /var — Talos's root filesystem is a read-only
          # squashfs, and `op: create` outside /var fails at boot with
          # "create operation not allowed outside of /var", which then wedges
          # the node in a 35-minute reboot loop (kubelet can't write its
          # bootstrap PKI either, since the same failed-file-write leaves the
          # machine in a degraded boot). Learned live on 2026-08-17/18 — see
          # the LES-104 PR history for the incident.
          path = "/var/etc/kubernetes/auth/authentication-config.yaml"
          # 420 decimal == 0o644 octal (world-readable). NOT 0o600: the
          # apiserver container reads this as a non-root process, and a
          # owner-only file it can't open crash-loops the container with
          # "permission denied" — also learned live in the same incident.
          # World-readable is fine here: the volume mount is read-only and the
          # content (an operator's email + an already-public OAuth client ID)
          # isn't a secret.
          permissions = 420
          content     = local.authentication_configuration_yaml
        }]
      }
    }),

    # --- User volumes -----------------------------------------------------
    # The cluster knows disk ROLES, never disk PATHS. Selection is by serial
    # (set on the domain's disks in domain.tf) rather than by vdb/vdc
    # enumeration order, so the mapping survives disks being added or removed.
    #
    # These mount at /var/mnt/<name> and that path is identical on every node
    # by construction — which is what lets the storage classes stop caring
    # which machine they are on. Caveat: a node whose config omits a volume
    # would silently get a directory on its system disk, so the volume must be
    # declared for every node in the class.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "fast"
      provisioning = {
        diskSelector = {
          match = "disk.serial == '${local.fast_serial}'"
        }
        # minSize is mandatory even with grow: a UserVolumeConfig carrying
        # neither minSize nor maxSize is rejected ("min size or max size is
        # required"). It is a floor, not a reservation — grow then takes the
        # volume out to fill its disk, so resizing the backing image is the
        # only step needed to expand the tier later.
        minSize = "1GiB"
        grow    = true
      }
      filesystem = {
        # ext4 rather than the provider default of xfs: this is nested inside a
        # raw image on ext4 already, and ext4-on-ext4 is the better-trodden
        # path for the failure modes this platform will actually hit.
        type = "ext4"
      }
    }),

    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UserVolumeConfig"
      name       = "bulk"
      provisioning = {
        diskSelector = {
          match = "disk.serial == '${local.bulk_serial}'"
        }
        minSize = "1GiB"
        grow    = true
      }
      filesystem = {
        type = "ext4"
      }
    }),
  ]
}

# Ephemeral: the rendered machine config contains the full PKI, and this is
# what keeps it out of state.
ephemeral "talos_machine_configuration" "node" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${var.node_ip}:6443"
  machine_type       = "controlplane"
  machine_secrets    = local.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches     = local.config_patches
}

ephemeral "talos_client_configuration" "node" {
  cluster_name    = var.cluster_name
  machine_secrets = local.machine_secrets
  endpoints       = [var.node_ip]
  nodes           = [var.node_ip]
}

resource "talos_machine_configuration_apply" "node" {
  # _wo (write-only) arguments: sent to the provider, never recorded in state.
  # These require Terraform 1.11+, which versions.tf enforces.
  client_configuration_wo        = ephemeral.talos_client_configuration.node.client_configuration
  machine_configuration_input_wo = ephemeral.talos_machine_configuration.node.machine_configuration
  node                           = var.node_ip

  # The domain has to be running and in maintenance mode before config can
  # land. The DHCP reservation in the libvirt network is what makes the node
  # reachable at var.node_ip during that window — before any machine config
  # exists to set the address statically.
  depends_on = [libvirt_domain.node]
}

resource "talos_machine_bootstrap" "node" {
  client_configuration_wo = ephemeral.talos_client_configuration.node.client_configuration
  node                    = var.node_ip

  depends_on = [talos_machine_configuration_apply.node]
}

# Generated locally from the machine secrets rather than fetched from the
# cluster, so it does not race the apiserver coming up.
ephemeral "talos_cluster_kubeconfig" "node" {
  cluster_name    = var.cluster_name
  machine_secrets = local.machine_secrets
  endpoint        = "https://${var.node_ip}:6443"

  depends_on = [talos_machine_bootstrap.node]
}
