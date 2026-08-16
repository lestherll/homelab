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
        proxy = {
          extraArgs = {
            metrics-bind-address = "0.0.0.0"
          }
        }
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
