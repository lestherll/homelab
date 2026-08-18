# ClusterRole scoped per API group with a wildcard, not per-kind

**Date:** 2026-08-17 · **Tags:** kubernetes, rbac, security

**Problem:** how granular should the operator's own `ClusterRole` be, now
that human access exists as a real OIDC identity instead of a direct
kubeconfig.

**Decision:** `resources: ["*"]` per listed API group (core/apps/batch/
networking, Flux's four groups, kro + platform.homelab, Cilium/Tailscale/
CNPG/SeaweedFS), not individually enumerated kinds. Explicitly excludes
`rbac.authorization.k8s.io/*` and CRD definitions — no self-escalation, no
redefining what a CRD is, even for this identity.

**Alternatives considered:**
- Enumerate exact kinds per group — narrower, rejected as more maintenance
  for marginal extra safety on a single-user cluster where the identity is
  already the operator's own account.

**Security impact:** still well short of `cluster-admin` (RBAC/CRD writes
excluded), but broad within each listed group. Acceptable given single-user
scope (`CONCEPT.md` §3) — would need revisiting if a second real identity
is ever added.

**Ref:** `infrastructure/human-auth/rbac.yaml`, PR #69
