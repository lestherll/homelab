output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = "https://${var.cluster_endpoint_ip}:6443"
}

output "node_ips" {
  description = "Node addresses, keyed by hostname."
  value       = { for k, v in var.nodes : k => v.ip }
}

output "controlplane_node" {
  description = "Hostname of the node that bootstraps the cluster."
  value       = local.controlplane_node
}

output "talos_endpoints" {
  description = <<-EOT
    What to point `talosctl config endpoint` at, keyed by hostname.

    MagicDNS names once tailnet_domain is set, LAN addresses otherwise. Names
    rather than addresses on purpose: `talosctl` verifies TLS against the value
    it DIALS, and a name is the half of that pair the LAN cannot renumber.

    This is `--endpoints` ONLY. Do not feed it to `--nodes`: that is a routing
    header apid resolves on the NODE, using machine.network.nameservers, which
    do not resolve .ts.net — it fails with "produced zero addresses", which
    looks like a client DNS fault and is not one.

    Safe as an output — unlike a talosconfig this is a hostname, not PKI.
  EOT
  value       = { for k, v in var.nodes : k => coalesce(local.tailnet_names[k], v.ip) }
}

# Deliberately NOT an output: kubeconfig and talosconfig. Both embed the PKI,
# and an output is stored in state — which is the one thing this module's
# design exists to prevent. Generate them from the SOPS-encrypted secrets
# instead; AGENT.md carries the talosctl recipe, including the warning to
# shred all four generated files rather than only the plaintext secrets.
