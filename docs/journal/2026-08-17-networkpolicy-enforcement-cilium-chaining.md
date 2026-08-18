# NetworkPolicy was silently unenforced — Flannel accepts policy objects, enforces nothing

**Date:** 2026-08-17 · **Tags:** kubernetes, networking, security, cilium

**Problem:** three NetworkPolicy objects sat in `flux-system` for a while,
presumed enforced. Nobody had verified it.

**Investigation:** audited Flux's own policies against the live cluster.

**Finding:** Talos's default CNI is Flannel — it accepts policy objects via
the API but has no enforcement backend at all. No admission error, no
condition on the object. Three "enforced" policies had been doing nothing,
silently, since the Talos cutover.

**Decision:** installed Cilium in `generic-veth` CNI **chaining** mode —
attaches eBPF policy programs to the veths Flannel creates. Not a CNI
replacement: Flannel keeps routing/IPAM/masquerading, Cilium only adds the
policy layer. Chosen over a full CNI swap because it's a Flux change, not a
rebuild of the cluster's only node.

**Investigation (second-order trap):** with chaining, Cilium doesn't own
Flannel's bridge — kubelet probes arriving from `cni0` classify as `world`,
not `host`. A default-deny ingress policy also silently denies kubelet
health probes unless an explicit allow rule exists. Symptom: crash loop on
probe timeouts while the process inside logs completely normal operation;
`kubectl describe pod` names only the probe, never the policy. Root cause
only visible via `hubble observe --type drop`.

**Decision (follow-on):** added an explicit allow-node-to-pods policy for
kubelet probe traffic before enabling any default-deny policy.

**Validation:** wrote a positive+negative test proving enforcement is real —
never trust a deny rule that hasn't been watched fail.

**Ref:** `docs/networkpolicy-enforcement-notes.md`
