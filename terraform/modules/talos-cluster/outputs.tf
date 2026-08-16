output "node_ip" {
  description = "Static address of the control-plane node."
  value       = var.node_ip
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = "https://${var.node_ip}:6443"
}

output "system_volume_path" {
  description = "Host path of the disposable system image. Useful when reasoning about / free space, since these images are sparse and host df under-reports the commitment."
  value       = libvirt_volume.system.target.path
}

output "fast_volume_path" {
  description = "Host path of the durable low-latency data image (SSD)."
  value       = libvirt_volume.fast.target.path
}

output "bulk_volume_path" {
  description = "Host path of the durable high-capacity data image (HDD)."
  value       = libvirt_volume.bulk.target.path
}

# Deliberately no kubeconfig or talosconfig output.
#
# Both are derived from the machine secrets and are therefore ephemeral in this
# module — and an ephemeral value cannot be written to a file or consumed by a
# non-ephemeral output, which is exactly the property that keeps them out of
# state. Fetch them with talosctl instead, which needs no Terraform state at
# all and is the command you would reach for in a recovery anyway:
#
#   talosctl --talosconfig <cfg> --nodes <ip> kubeconfig ~/.kube/config
#
# See terraform/README.md for the full bootstrap sequence.
