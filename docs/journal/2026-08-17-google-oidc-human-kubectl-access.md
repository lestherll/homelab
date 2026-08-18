# Google OIDC for human kubectl over the tailnet, incl. a self-inflicted control-plane outage

**Date:** 2026-08-17 · **Tags:** kubernetes, oidc, talos, terraform, incident

**Problem:** only auth path to the cluster was a direct-network kubeconfig
on the host. Wanted tailnet-based human kubectl with real identity, no
shared static credential.

**Decision:** multi-issuer `AuthenticationConfiguration` (GitHub Actions +
Google), replacing the legacy single-issuer `oidc-*` apiServer flags (the
two are mutually exclusive). Reused the existing `kube-apiserver-ci`
`noauth` ProxyGroup for the human path instead of adding a second one — a
`noauth` proxy forwards every request unmodified regardless of caller, so a
human's Google token reaches the apiserver exactly like CI's GitHub token
does. Google email allow-listed via a Terraform variable (PII, not a
credential — kept out of git, unlike SOPS-encrypted secrets).

**Alternatives considered:**
- Second ProxyGroup in `auth` mode, impersonating the caller's tailnet
  identity — original plan, dropped once `noauth`'s forward-unmodified
  behavior was confirmed against the live CRD; unnecessary complexity.

## Incident: shipped a machine-config bug, wedged the only control-plane node

**Investigation:** `terraform apply` restarted the apiserver as expected,
but kubelet fully stopped and every pod entered `nodeshutdown_manager`
termination — a full node reboot, not the static-pod-only restart the
existing docs described.

**Finding 1:** `machine.files` path was under `/etc/kubernetes/auth/...`.
Talos's root is a read-only squashfs — `op: create` outside `/var` fails at
boot (`create operation not allowed outside of /var`), cascading into
kubelet unable to write its own bootstrap PKI, which put the node on a
35-minute auto-reboot loop retrying the same broken config.

**Finding 2 (after fixing #1):** apiserver container kept crash-looping with
`permission denied` reading the same file. Cause: `permissions: 0o600`
(owner-only) — the apiserver process isn't root inside its container.

**Decision:** live-patched via `talosctl apply-config --mode reboot` twice
(path fix, then permissions fix) to recover, verified each with a dry-run
diff first. `--mode try`/`no-reboot` are rejected outright for
`machine.files` changes ("can't be applied in immediate mode") — reboot mode
is mandatory for this class of change, not a choice.

**Validation:** node `Ready`, all pods `Running`, apiserver serving both
issuers, RBAC (`ClusterRole`/`ClusterRoleBinding`) confirmed present —
before committing the same fix back to the repo so a future rebuild doesn't
reintroduce it.

**Security impact:** file content (operator email + already-public OAuth
client ID) isn't sensitive, so `0o644` is fine — the mount is read-only
regardless.

**Follow-up:** `kubelogin` install + kubeconfig `exec` block per machine —
one-time local setup, not committed here.

**Ref:** PR #69 (shipped bug), PR #70 (fix)
