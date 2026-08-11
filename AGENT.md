# AGENT.md

## Description
This repo is the declarative source of truth for a single-user homelab platform: a bare-metal Ubuntu host bootstrapped with Ansible into a k3s cluster, GitOps-managed by Flux, exposed over Tailscale, and observed via kube-prometheus-stack. On top of that, a self-service typed platform API (kro) provisions `Database`/`ObjectStorage`/`Application` instances for other repos. Full product vision/rationale lives in `CONCEPT.md`.

## Repo layout
- `ansible/` — host bootstrap and convergence (idempotent). `playbooks/converge.yml` runs roles in order: `host_prereqs` → `cli_tools` → `k3s_server` → `heartbeat_watchdog`. Inventory/vars in `ansible/inventory/hosts.ini`.
- `infrastructure/` — Flux-managed Kubernetes manifests (HelmRepositories, HelmReleases, namespaces, SOPS-encrypted secrets), one subdirectory per component:
  - `tailscale-operator/`, `observability/`, `sources/`, `storage/` — platform scaffolding from Phase 0.
  - `kro/` — the kro operator (`rbac.mode: aggregation`; its privilege doc is `platform-api/rbac-kro-aggregate.yaml`, extend it when a new kind is added to an RGD).
  - `platform-api/` — the `Database`/`ObjectStorage`/`Application` `ResourceGraphDefinition`s (`platform.homelab/v1alpha1`), per decision D15.
  - `postgres/` — CloudNativePG operator, backing every `Database` instance.
  - `seaweedfs/` — SeaweedFS operator + HelmRelease.
  - `seaweedfs-runtime/` — the `Seaweed` cluster/`ResourceReferenceGrant`/`PodMonitor`s, deliberately its **own** Flux Kustomization (`dependsOn: [infrastructure]`) — see `docs/self-service-platform-design-notes.md`'s Implementation log for why pairing a HelmRelease with CRD-dependent raw manifests in the same Kustomization deadlocks on cold apply.
  - `fastapi-echo/`, `personal-finance-dashboard/` — per-app Flux pointer objects (`GitRepository`+`Kustomization`) for apps whose manifests live in their own repos.
- `clusters/homelab/` — Flux's entrypoint Kustomizations, pointing at `infrastructure/` (and, separately, `infrastructure/seaweedfs-runtime/`).
- `CONCEPT.md` — the full product concept doc (principles, scope, users, decisions D1–D16). Read this for *why*, not just *what*.
- `docs/` — supplementary notes:
  - `gitops-onboarding-learnings.md` — what each hand-built app/data-service instance taught, per D1's promotion rule (superseded for `Database`/`ObjectStorage`/`Application` by D15's pivot, noted inline).
  - `self-service-platform-design-notes.md` — full design + build record for D15/D16, including a detailed implementation log of every gotcha hit building the platform API.
  - `platform-api-usage.md` — practical field reference for onboarding/migrating an app onto `Database`/`ObjectStorage`/`Application`.
  - `message-broker-design-notes.md` — exploratory notes on a future message-broker data service; not built, not scheduled.
  - `external-consumer-access-notes.md` — investigation into letting apps hosted *off* the platform consume `Database`/`ObjectStorage` over the tailnet. Nothing built; records what was verified on the live cluster (kro can express a polymorphic `ServiceBinding`; SigV4 works over the tailnet) and the constraints any such design inherits.

## Key operational facts
- **Ansible privilege escalation is broken on this host.** Ubuntu 26.04's `sudo-rs` doesn't match Ansible's become-prompt regex (see the comment block in `ansible.cfg`). Always invoke playbooks wrapped in a top-level `sudo`, not `-K`:
  ```
  sudo ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/converge.yml --tags <tags>
  ```
  Scope with `--tags` (`host_prereqs`, `cli_tools`, `k3s_server`, `heartbeat_watchdog`) to avoid tripping unrelated guards — e.g. `heartbeat_watchdog` hard-fails until a real `ntfy_topic` replaces the `CHANGEME` placeholder in `hosts.ini`.
- **Secrets are SOPS-encrypted with age**, scoped to `infrastructure/**/*.sops.yaml`, only the `data`/`stringData` fields (see `.sops.yaml`) so diffs on rotation stay legible.
- **Version pinning convention**: chart versions (`HelmRelease.spec.chart.spec.version`), CLI tool versions (`ansible/roles/cli_tools/vars/main.yml`), and collection versions (`ansible/requirements.yml`) are pinned explicitly with a comment noting when/against-what they were last re-verified. Re-check before bumping, don't leave things unpinned to "always get latest."
- **Flux is already bootstrapped** and tracking `main` — but the working branch (currently `bootstrap/k3s-flux-phase0`) is not yet merged, so changes under `infrastructure/` don't reach the cluster until that merge happens. Check `kubectl get kustomization flux-system -n flux-system` and `kubectl get helmreleases -A` to see what's actually live before assuming a manifest change took effect.
- **Recreating a Tailscale exposure burns a certificate — edit in place instead.** Every `tailscale`-class Ingress (and `loadBalancerClass: tailscale` Service) gets a proxy whose state Secret, `ts-<name>-<random>-0`, caches the issued cert next to its device identity. That Secret is created and destroyed *with the exposure*, so delete-and-recreate always forces a fresh Let's Encrypt order — there is no cross-recreate cache. Five failed attempts on one hostname within an hour trips LE's failed-authorization limit and that hostname serves no TLS until the window clears; each further attempt slides the window forward, so retrying makes it worse. Symptom is a client that hangs rather than errors. Check `kubectl logs -n tailscale ts-<name>-<hash>-0 | grep -i acme` before suspecting your manifest. Note this is *not* the 7-day duplicate-certificate limit that most Tailscale/LE write-ups describe — recovery here is minutes. Full analysis in `docs/external-consumer-access-notes.md`.
- **MagicDNS names don't resolve from inside pods.** CoreDNS doesn't forward `.ts.net`, though the node itself resolves it fine. A pod that must reach a tailnet name needs explicit `dnsConfig` — worth knowing before debugging a connection failure that is really a DNS failure.
- **Single-user, single-node.** No multi-tenancy, HA, or quota concerns — see `CONCEPT.md` §3 if that assumption ever seems wrong.

## Usage
- Bootstrap/converge the host: `sudo ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/converge.yml --tags <role>`.
- Cluster access: `kubectl` via `~/.kube/config` (kept in sync with `/etc/rancher/k3s/k3s.yaml` by the `k3s_server` role, both `0600`).
- Editing an encrypted secret: `sops infrastructure/<path>/<name>.sops.yaml`.

## Notes
- Verify idempotency after Ansible role changes by re-running the same `--tags` and checking for `changed=0` in the recap before assuming a fix is "live."
- A new kind added to any `ResourceGraphDefinition` under `platform-api/` needs a matching grant in `platform-api/rbac-kro-aggregate.yaml`, or kro reconciliation fails with a permission error.
