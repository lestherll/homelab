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

**Instance #2: `personal-finance-dashboard`**
(github.com/lestherll/personal-finance-dashboard) — a `uv`-based Streamlit
app with real state: a local data lake (DuckDB + parquet) that both a
host-side CLI and the deployed app itself read and write (statement
uploads happen through the running app, not just the CLI). First instance
with actual persistence requirements.

## What instance #2 adds to the "what varies" list

- **Data persistence strategy.** Not present at all in instance #1
  (stateless). Chosen here: a `hostPath` volume straight at the app repo's
  own `data/` directory on this host, rather than a `local-path-provisioner`
  PVC — because uploads through the app and edits through the host CLI need
  to hit the *same* files, and a PVC copy would immediately diverge from
  the host-side copy. Worth remembering: this cluster's only StorageClass
  is also node-local disk under the hood, so hostPath vs. PVC is not a
  resilience decision — either way, the actual mitigation for "the host
  dies" is an off-host backup of the data path, which doesn't exist yet
  for this app (same class of gap as D12's age-key backup).
- **Pod `securityContext` (`runAsUser`/`runAsGroup`/`fsGroup`)`.** Needed
  once a pod writes to a hostPath owned by the host user, to keep
  upload-written files owned correctly instead of as `root`. Didn't come up
  for instance #1 since it wrote nothing.
- **Repo/image visibility as one combined decision, not two.** Considered
  keeping the image public (as instance #1 did) while the source repo
  stayed private — decided that was an inconsistent posture for an app
  that's specifically about personal finances, and made both public
  instead. Worth a template eventually asking "public or private" once,
  not per-artifact.

## Status

- `fastapi-echo` is live and verified end-to-end at
  `https://fastapi-echo.tailf4742d.ts.net`.
- `personal-finance-dashboard` deploy/ manifests and Flux wiring written;
  not yet verified live (pending the repo going public and the first image
  build).
- One more hand-built instance is wanted before considering a Layer 1
  template or a typed `Application` API for app onboarding, per D1.
