# Migrated bare-metal Ansible/k3s to Terraform-provisioned Talos VM

**Date:** 2026-08-16 · **Tags:** kubernetes, terraform, talos, migration

**Problem:** k3s on bare metal enforced no PodSecurity, no policy-capable
CNI, hand-managed everything below the cluster. Wanted IaC-driven cluster
lifecycle (`terraform destroy && apply` as a routine rebuild test) without
losing the metal-level Ansible layer.

**Decision:** Ubuntu stays on the metal as hypervisor (Ansible). Terraform
provisions a single Talos VM on libvirt. Flux unchanged above the cluster
boundary.

**Investigation / findings (cold-apply, invisible on k3s):**
- CRD-dependent raw manifests in the same Kustomization as the HelmRelease
  installing that CRD deadlock their own dry-run — self-sustaining across
  every retry. Fix: split into a separate Kustomization with `dependsOn`.
- Talos enforces PodSecurity `baseline`; k3s enforced nothing. hostPath/
  hostNetwork/hostPort workloads (provisioner pods, node-exporter) need
  `pod-security.kubernetes.io/enforce: privileged` on their namespace.
  Failure mode misreports as a HelmRelease DaemonSet timeout with no pod to
  inspect — admission rejected before creation, real error only in
  `kubectl describe ds`.
- kube-proxy metrics bind to 127.0.0.1 by default on Talos (k3s bound all
  interfaces) — kube-prometheus-stack's default ServiceMonitor scrapes the
  node IP and gets connection refused permanently. Fixed by exposing the
  endpoint (`metrics-bind-address: 0.0.0.0`), not deleting the alert.

**Validation:** dumps deliberately skipped on cutover (nothing on old
cluster worth carrying) — every instance came up empty by design, executed
2026-08-16.

**Security impact:** PKI kept out of Terraform state entirely — secrets
generated out-of-band (`talosctl gen secrets`), SOPS-encrypted, entered via
ephemeral resources + write-only args so state never holds the authoritative
copy.

**Ref:** `docs/talos-terraform-migration-notes.md`, `docs/talos-cutover-runbook.md`
