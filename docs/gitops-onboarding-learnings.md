# GitOps app-onboarding: learnings from instance #1

Per `CONCEPT.md`'s D1 promotion rule, a resource type earns a Layer 1
template (or Layer 2 typed API) only after the third instance has been
built by hand — designing the abstraction before real instances exist is
the standard way platform APIs end up leaky. This doc tracks what each
hand-built instance actually teaches, so that whenever a template does get
built, it's built from evidence instead of guesswork.

**Instance #1: `fastapi-echo`** (github.com/lestherll/fastapi-echo) — a
minimal `uv`-based FastAPI echo server, no database, deployed as a
deliberately simple first case for the multi-repo GitOps pattern.

## What a future template would need to parameterize

Per-app values, observed to actually vary:

- repo URL
- image reference
- container port
- Tailscale hostname
- resource requests/limits
- health-check probe path

## What stayed pure boilerplate

Identical every time, and so exactly what a template should absorb:

- The `Ingress` shape (`ingressClassName: tailscale`, hostname via
  `spec.tls[].hosts`, not `metadata.name`)
- The `GitRepository` source shape
- The Flux `Kustomization` pointer shape (`path`/`prune`/`sourceRef`)

## Confirmed working, previously only assumed

- The homelab-repo footprint for a new app stays small (~20 lines: one
  `GitRepository` + one `Kustomization`) — no app code or manifests need
  to live in this repo.
- Prometheus's cluster-wide `ServiceMonitor`/target auto-discovery picked
  up the new namespace with zero extra configuration.
- The Tailscale ingress + HTTPS pattern extends to a new app with no
  manual cert step, same as it did for Grafana/Alertmanager.

## Real rough edges found

- **GHCR package visibility isn't automatable with the current `gh` CLI
  token** (missing `packages` scope) — flipping a freshly-pushed image
  package to public requires a manual step in the GitHub web UI. A
  "zero to running in one push" golden path needs to either solve this
  (a properly-scoped token) or document it as an expected one-time step
  per new app repo.
- **No rollback story yet.** This instance uses `:latest` +
  `imagePullPolicy: Always`, which is fine for a disposable test server
  but isn't the platform's actual intended answer — that's D2 (registry-
  watching reconciler + tag-bump commits), which isn't built yet.

## Status

- `fastapi-echo` is live and verified end-to-end at
  `https://fastapi-echo.tailf4742d.ts.net`.
- Two more hand-built instances are wanted before considering a Layer 1
  template or a typed `Application` API for app onboarding, per D1.
