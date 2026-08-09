# GitOps app-onboarding: learnings from hand-built instances

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
  is also node-local disk under the hood, so hostPath vs. PVC was never a
  resilience decision — neither survives losing this machine.
- **Off-host backup deliberately deferred, not forgotten.** Instance #2
  exposed the first real "what if the host dies" gap for actual
  irreplaceable data (unlike Grafana/Prometheus state, which is
  reproducible from git + re-scraping). Decided *not* to bolt on a
  per-app backup script for this one hostPath — the intended fix is C6's
  object-storage service (see Next steps below), so this app's data stays
  on hostPath until that lands, then migrates. Recorded here so this
  doesn't quietly get treated as "resolved" — it isn't yet.
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

## Database track — Instance #1: `fastapi-echo` + Postgres

D1's promotion rule tracks `Application` and `Database` as **separate**
counters (both are named Layer-2 types). This is the first instance
toward `Database`'s count, and deliberately reused `fastapi-echo` rather
than a new app repo — the point was to isolate "does self-hosted
Postgres provisioning + credential delivery actually work," not to
re-test app-onboarding mechanics already proven twice.

- **Split ownership confirmed workable:** the CloudNativePG operator
  (shared, cluster-wide) lives in `homelab`'s `infrastructure/postgres/`;
  the app-specific `Cluster` CR lives in `fastapi-echo`'s own repo,
  co-located with its `Deployment`/`Service`. This avoided the
  cross-repo secret-name coordination problem a homelab-repo-owned
  `Cluster` would have created.
- **C6's "credentials delivered automatically" actually works, not just
  in principle.** CloudNativePG auto-generates a Secret
  (`<cluster-name>-app`, containing a `uri` key among others) the moment
  the `Cluster` is created — nothing hand-created, nothing SOPS-encrypted
  for this at all. This is D12's "minted by the cluster" pattern working
  as designed, confirmed by an actual instance instead of just being
  named as the goal.
- **The `local-path-retain` StorageClass fix works as a bare second
  `StorageClass` object** — same `rancher.io/local-path` provisioner,
  just `reclaimPolicy: Retain` — no provisioner-side config needed.
  Confirmed live: the resulting PV shows `RECLAIMPOLICY=Retain`.
- **D4 durability labels land on the PVC, not the PV.** `inheritedMetadata.labels`
  on the `Cluster` CR propagates to the generated PVC correctly — the PV
  itself stays unlabelled, which is normal Kubernetes dynamic-provisioning
  behavior (PVs don't inherit PVC labels), not a CloudNativePG quirk.
  Worth remembering for wherever D4's "unlabelled volume alerts"
  enforcement eventually gets built: it needs to look at PVCs.
- **The anticipated Cluster-init/pod-rollout race didn't actually bite
  this time** — the app pod came up `1/1 Running` with zero restarts, the
  database was ready before its first connection attempt. Worth recording
  as "didn't materialize," not "solved" — there's still no explicit
  ordering guarantee between the two, this was timing, not a fix.
- **The known D2 gap bit exactly as documented.** After merging, the new
  `/echo-history` route 404'd until a manual `kubectl rollout restart` —
  confirms `:latest` + `imagePullPolicy: Always` really doesn't auto-roll
  on a new image push, consistent with instance #1's finding.
- No cert-manager dependency, confirmed in practice (not just via `helm
  show values` beforehand) — the operator came up healthy without one.

## Status

- `fastapi-echo` is live and verified end-to-end at
  `https://fastapi-echo.tailf4742d.ts.net`, now with a working Postgres
  dependency (`POST /echo` persists, `GET /echo-history` reads back).
- `personal-finance-dashboard` is live and verified end-to-end at
  `https://personal-finance-dashboard.tailf4742d.ts.net` — pod `Running`,
  image pulled with no `imagePullSecret` (repo and GHCR package both
  flipped public), hostPath volume mounted, `/_stcore/health` returning
  `200`.
- **`Application` track: 2/3.** One more hand-built app instance wanted
  before considering a Layer 1 template or typed `Application` API, per
  D1.
- **`Database` track: 1/3.** Two more hand-built database-consuming
  instances wanted before considering a Layer 1 template or typed
  `Database` API, per D1.

## Next steps

- **Object storage as the platform's first C6 data service.** Surfaced by
  instance #2's upload/backup gap, not built speculatively: CONCEPT.md's
  C6 already names object storage as a "should" alongside Postgres on the
  same self-service pattern, and this is the first real pull for it.
  Scoped deliberately small for its own first instance, same D1 logic as
  the app-onboarding pattern — a single MinIO-or-equivalent `HelmRelease`
  plus one manually-provisioned bucket/credential for
  `personal-finance-dashboard`, not a templated self-service API yet (that
  still needs 2 more hand-built data-service instances before it earns
  one). Also **doesn't get this platform out of the node-local-disk
  problem for free** — a single-node object store is still one disk on
  this one machine; genuine off-host resilience needs the store's own
  bucket replication/backup, which is a distinct follow-up, not implied by
  "add object storage."
- **`personal-finance-dashboard`'s app code isn't S3-native.** It reads/
  writes local parquet + a DuckDB file via `DATA_DIR`. Moving it onto
  object storage later means either app-side changes (adapters that speak
  S3) or a fuse-style mount (rclone/s3fs) — the latter is a known
  reliability risk for a database file under concurrent access, so this
  needs a real decision when the time comes, not a default.
- **One more `Application`-track instance, two more `Database`-track
  instances** still wanted before either earns a Layer 1 template or
  typed API (per D1) — this doc should keep growing with each one.
