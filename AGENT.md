# AGENT.md

## Description
This repo is the declarative source of truth for a single-user homelab platform: a bare-metal Ubuntu host bootstrapped with Ansible into a k3s cluster, GitOps-managed by Flux, exposed over Tailscale, and observed via kube-prometheus-stack. Full product vision/rationale lives in `CONCEPT.md`. `PR.md` tracks the current review-findings-and-fixes cycle.

## Repo layout
- `ansible/` — host bootstrap and convergence (idempotent). `playbooks/converge.yml` runs roles in order: `host_prereqs` → `cli_tools` → `k3s_server` → `heartbeat_watchdog`. Inventory/vars in `ansible/inventory/hosts.ini`.
- `infrastructure/` — Flux-managed Kubernetes manifests (HelmRepositories, HelmReleases, namespaces, SOPS-encrypted secrets), one subdirectory per component (`tailscale-operator/`, `observability/`, `sources/`).
- `clusters/homelab/` — Flux's entrypoint Kustomization pointing at `infrastructure/`.
- `monitoring/` — the **legacy** podman-compose observability stack (pre-k3s). Still running in parallel with `infrastructure/observability` until the new stack is verified equivalent; not to be torn down casually. Config is templated: `generate-config.sh` renders `prometheus.yml` from `prometheus.yml.template`, driven by `Makefile` (`make monitoring-up/down/restart/logs`).
- `CONCEPT.md` — the full product concept doc (principles, scope, users). Read this for *why*, not just *what*.
- `PR.md` — running log of code-review findings and fix status for the current branch/PR.

## Key operational facts
- **Ansible privilege escalation is broken on this host.** Ubuntu 26.04's `sudo-rs` doesn't match Ansible's become-prompt regex (see the comment block in `ansible.cfg`). Always invoke playbooks wrapped in a top-level `sudo`, not `-K`:
  ```
  sudo ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/converge.yml --tags <tags>
  ```
  Scope with `--tags` (`host_prereqs`, `cli_tools`, `k3s_server`, `heartbeat_watchdog`) to avoid tripping unrelated guards — e.g. `heartbeat_watchdog` hard-fails until a real `ntfy_topic` replaces the `CHANGEME` placeholder in `hosts.ini`.
- **Secrets are SOPS-encrypted with age**, scoped to `infrastructure/**/*.sops.yaml`, only the `data`/`stringData` fields (see `.sops.yaml`) so diffs on rotation stay legible.
- **Version pinning convention**: chart versions (`HelmRelease.spec.chart.spec.version`), CLI tool versions (`ansible/roles/cli_tools/vars/main.yml`), and collection versions (`ansible/requirements.yml`) are pinned explicitly with a comment noting when/against-what they were last re-verified. Re-check before bumping, don't leave things unpinned to "always get latest."
- **Flux is already bootstrapped** and tracking `main` — but the working branch (currently `bootstrap/k3s-flux-phase0`) is not yet merged, so changes under `infrastructure/` don't reach the cluster until that merge happens. Check `kubectl get kustomization flux-system -n flux-system` and `kubectl get helmreleases -A` to see what's actually live before assuming a manifest change took effect.
- **Single-user, single-node.** No multi-tenancy, HA, or quota concerns — see `CONCEPT.md` §3 if that assumption ever seems wrong.

## Usage
- Bootstrap/converge the host: `sudo ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/converge.yml --tags <role>`.
- Legacy monitoring stack: `make monitoring-up` / `monitoring-down` / `monitoring-restart` / `monitoring-logs`.
- Cluster access: `kubectl` via `~/.kube/config` (kept in sync with `/etc/rancher/k3s/k3s.yaml` by the `k3s_server` role, both `0600`).
- Editing an encrypted secret: `sops infrastructure/<path>/<name>.sops.yaml`.

## Notes
- Verify idempotency after Ansible role changes by re-running the same `--tags` and checking for `changed=0` in the recap before assuming a fix is "live."
- `PR.md` should be kept current as findings get fixed — it's the working checklist, not a historical artifact.
