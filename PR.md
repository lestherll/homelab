# PR #1 Review Findings — Phase 0 bootstrap: k3s, Flux, Tailscale operator scaffolding

## 1. `infrastructure/tailscale-operator/oauth-secret.sops.yaml` — stale "TEMPLATE, not yet encrypted" header on an already-encrypted, real-secret file (Medium)
**Status: Fixed in this session.**

The header comment read "TEMPLATE — placeholder values, NOT yet encrypted" and instructed the reader to replace `CHANGEME` values and run `sops --encrypt --in-place`. But the file body is already fully SOPS-encrypted (`ENC[...]` ciphertext, `mac`, `lastmodified`), and the PR description confirms these are real, verified-round-trip values. The template header wasn't cleaned up after encryption. Trimmed the header to match the pattern used by `grafana-admin-secret.sops.yaml`, keeping the useful ACL/OAuth-client setup notes for future rotation but dropping the "NOT yet encrypted" / CHANGEME instructions.

## 2. `k3s_server` role sets `write-kubeconfig-mode: "0644"`, making the cluster-admin kubeconfig world-readable (Medium — security)
**Status: Fixed.**

`config.yaml.j2` overrides k3s's default (`0600`) to `0644` for `/etc/rancher/k3s/k3s.yaml`, which holds a cluster-admin client cert. The kubeconfig copy task already runs as root via `remote_src: true`, so the looser mode isn't needed for that task to work. Dropped the override so k3s falls back to its `0600` default. Applied to the live host via `ansible-playbook --tags k3s_server` + `systemctl restart k3s` and verified: `/etc/rancher/k3s/k3s.yaml` is now `-rw-------`.

## 3. `tailscale-operator/helmrelease.yaml` has no pinned chart version, unlike `observability/helmrelease.yaml` (Low–Medium)
**Status: Fixed.**

The kube-prometheus-stack HelmRelease pins `version: "86.1.0"`. The tailscale-operator HelmRelease omitted `spec.chart.spec.version`, which Flux treats as `"*"` — every reconcile could silently jump to the latest published chart version. Pinned to `1.98.9` (latest per `pkgs.tailscale.com/helmcharts` as of 2026-08-09), with the same "re-verify before re-running" comment style used in `cli_tools/vars/main.yml`. Validated the field against the live `HelmRelease` CRD schema via `kubectl apply --dry-run=server`. Not yet reconciled on-cluster — this branch isn't merged to `main` yet, so Flux hasn't picked it up.

## Minor / non-blocking observations
- `ansible/requirements.yml` doesn't pin a `community.general` version. **Fixed** — pinned to `12.1.0` (the currently installed version).
- `k3s_server`'s config-render task always fires the `restart k3s` handler, including on first install (where the install script already started the service) — one redundant restart on fresh bootstrap. **Fixed** — the "already installed" stat check now runs before the config render, and the handler is guarded on `k3s_binary.stat.exists`, so a fresh install's already-correct first start doesn't trigger an extra restart. Verified idempotent on the live host (re-run reported `changed=0`, k3s's `ActiveEnterTimestamp` unchanged).
- No CI/lint (`ansible-lint`, `yamllint`, `kubeconform`) wired up yet. **Deferred** — out of scope for this follow-up session by request.
