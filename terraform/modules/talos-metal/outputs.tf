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

# Deliberately NOT an output: kubeconfig and talosconfig. Both embed the PKI,
# and an output is stored in state — which is the one thing this module's
# design exists to prevent. Generate them from the SOPS-encrypted secrets
# instead; AGENT.md carries the talosctl recipe, including the warning to
# shred all four generated files rather than only the plaintext secrets.
