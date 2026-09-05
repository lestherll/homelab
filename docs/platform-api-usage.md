# Platform API: what's live, and how to use it

Practical reference for `platform.homelab/v1alpha1` — the typed self-service
platform API. For the *why* behind any of this, see
`docs/self-service-platform-design-notes.md`. This doc is the *how*: what
fields exist today, what an app repo's `deploy/` looks like, and how to
verify a migration actually worked.

Current status: `Database`, `ObjectStorage`, and `Application` are live and
Flux-managed. `fastapi-echo` runs on all three today and is the reference
example throughout.

## Prerequisites

- Every namespace still needs its own `namespace.yaml`, same as before.
- If the app will use `ObjectStorage`, label the namespace:
  ```yaml
  metadata:
    labels:
      platform.homelab/seaweedfs-access: "true"
  ```
  This is a real authorization grant (a `ResourceReferenceGrant` trusts
  exactly this label), not decoration — omit it and any `Bucket`/`S3*`
  object in that namespace fails to resolve its cluster reference.

## `Database`

```yaml
apiVersion: platform.homelab/v1alpha1
kind: Database
metadata:
  name: myapp-db
  namespace: myapp
spec:
  size: small   # or "medium" — enum, anything else is rejected at apply time
```

Renders one CloudNativePG `Cluster` (single instance, `local-path-retain`
storage) plus a `PodMonitor` so it's scraped by Prometheus automatically.

**Convention, not enforced by the schema: one `Database` per consumer.**
CloudNativePG can only hand out one bootstrap credential per cluster, so a
second `Application` attaching to the same `Database` would get identical
credentials to the first. Don't do that — declare a second `Database`
instead. (Object storage below is the opposite — sharing is the point
there.)

**Credentials**: CloudNativePG auto-mints a Secret named `<database-name>-app`
with a `uri` key. `Application` wires this in for you (see below) — you
never reference this Secret directly.

## `ObjectStorage`

```yaml
apiVersion: platform.homelab/v1alpha1
kind: ObjectStorage
metadata:
  name: myapp-bucket
  namespace: myapp
spec: {}   # no fields yet
```

Renders one SeaweedFS `Bucket`, with the real S3 bucket name derived as
`<namespace>-<name>` (globally unique across the cluster; `metadata.name`
only needs to be unique within the namespace).

**Sharing is the point, unlike `Database`.** Exactly one `ObjectStorage`
instance exists per bucket — created once by whichever app needs it first. A
second app that wants the *same* bucket does **not** declare a second
`ObjectStorage`; it just adds an entry to its own `Application`'s
`objectStorage` list, referencing this one by name (see below). Declaring a
second `ObjectStorage` instance for the same bucket fails
(`BucketAlreadyExists`).

Every consumer — including the first — gets its own isolated `S3Identity` +
minted credentials + a policy scoped to `<app-name>-<alias>/*` inside the
bucket. There's no "first consumer gets full access" case.

## `Application`

```yaml
apiVersion: platform.homelab/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: myapp
spec:
  image: ghcr.io/you/myapp:latest
  port: 8000                      # default 8000
  host: myapp                     # Tailscale hostname, no tailnet suffix
  probePath: /healthz             # default /healthz
  size: small                     # small|medium, default small

  databases:
    - ref: myapp-db                 # metadata.name of a Database in this namespace
      as: main                      # alias — becomes DATABASE_URL_MAIN
      # externalSecretName/externalSecretKey: escape hatch for a database
      # this platform doesn't own — see below, rarely needed

  objectStorage:
    - ref: myapp-bucket              # metadata.name of an ObjectStorage in this namespace
      as: data                       # alias — becomes S3_*_DATA

  # Both optional — omit entirely for a plain stateless app (fastapi-echo
  # sets neither).
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  persistence:
    size: 1Gi                       # NO DEFAULT — setting it is what asks
    tier: fast                      # fast|bulk, default fast
    mountPath: /app/data            # default /app/data

  # Optional. Off unless you say otherwise — see "Telemetry" below.
  metrics:
    enabled: true                   # default false
    path: /metrics                  # default /metrics, scraped on spec.port
    interval: 30s                   # default 30s
```

Renders `Deployment` + `Service` + `Ingress` (`ingressClassName: tailscale`,
same shape every ingress in this cluster already uses), plus:

- a `PersistentVolumeClaim` named `<app>-data` — only when `persistence.size`
  is set,
- a `PrometheusRule` named `<app>` — **always**,
- a `PodMonitor` named `<app>` — only when `metrics.enabled: true`,
- a `NetworkPolicy` named `<app>` — **always**, restricting ingress to the app's
  own Tailscale proxy plus `observability`. There is no field to turn it off.
  See `Ingress lockdown` below.

### Ingress lockdown, and the identity headers it buys

Every `Application` is reachable only through its own Tailscale proxy. Nothing
else in the cluster can reach its Service or its pods, and egress is untouched.

That is not gratuitous hardening — it is the precondition for reading
`Tailscale-User-Login`. Tailscale injects that header on every proxied request,
but it is only worth believing if the backend cannot be reached any other way.
The full app-side contract, including the three cases where the header is
legitimately **absent** and must be treated as *unauthenticated* rather than as
an error, is in `docs/identity-headers.md`. Read it before an app authorises on
the header; display and audit uses need nothing.

The one thing to know when writing an app: **an app that needs to be called by
something other than its own proxy will break here**, as a connection timeout
with nothing on either object naming the policy. That needs an additive
`allowFrom` field on this API — file it rather than hand-writing a policy in the
app's repo, where it would drift out of the platform's privilege documents.

### Choosing a persistence tier

| `tier` | Guarantee | Use for |
|---|---|---|
| `fast` (default) | durable, low-latency, small | anything transactional or randomly accessed — an embedded DB, an index, a cache you need to survive a restart |
| `bulk` | durable, high-capacity, sequential | large files written and read end-to-end — uploads, archives, generated media |

Both retain their data if the `Application` is deleted, so removing an app
leaves a `Released` volume to clean up by hand rather than destroying its
contents. There is no disposable tier here on purpose: if the data does not
need to survive a restart, use an `emptyDir` in your own manifest and skip
`persistence` entirely.

> **Changed (revision 3, Talos cutover).** `persistence.hostPath` is gone,
> replaced by `size`/`tier`. It required naming a directory on one specific
> machine, which no longer exists — the new node has no home directories. If
> your app still sets `hostPath`, its `Application` will not reconcile until
> you swap the field; nothing else in the spec changes, and `mountPath` keeps
> its meaning and its default. Data in an old host directory is not migrated
> for you — copy it into the new volume before deleting the old path.

> **Changed again (revision 4).** `persistence.size` no longer defaults to
> `1Gi`. Setting it is now what *asks* for a volume, and omitting it is how you
> opt out. Revision 3 tried to read that intent from whether the `persistence`
> block was present, which turned out to be untestable — the generated CRD
> defaults the whole block in, so **every app was silently given a 1Gi volume
> and an `/app/data` mount it never requested**. If your app did ask for
> persistence, nothing changes for you. If it did not, its phantom claim is
> deleted on the next reconcile and the (empty) volume behind it is left
> `Released` for cleanup.

### Telemetry

Every `Application` gets a `PrometheusRule` with no opt-in and no work:

| Alert | Fires when |
|---|---|
| `ApplicationNotAvailable` | the Deployment has 0 available replicas for 10m |
| `ApplicationRestartLooping` | more than 3 container restarts in any 15m |
| `ApplicationMemoryNearLimit` | working set above 90% of the memory limit for 15m |

All three read kube-state-metrics and kubelet data, so they work whether or not
your app exposes anything. `ApplicationMemoryNearLimit` is the one worth
knowing about in advance: the memory limit comes from `spec.size`, which you
may never have thought about, and this alert is what turns an otherwise
unexplained OOMKill into "ask for the next size up."

The matching dashboard is **Platform — Application** in Grafana. There is one,
not one per app: pick your namespace and app from the dropdowns. Its *Delivery*
row is populated for every app, always.

Its *Application signals* row — request rate, error ratio, latency — needs two
things from you:

1. serve Prometheus metrics on your main `port`, using the standard client
   names `http_requests_total{status}` and `http_request_duration_seconds`
   (what `prometheus-fastapi-instrumentator` and its equivalents emit by
   default), and
2. set `metrics.enabled: true`.

Until then those panels are empty, which is the intended state and not a fault
to report. Scraping is **off by default** on purpose: pointing Prometheus at an
app that serves no `/metrics` produces a permanently-failing scrape target that
nobody can fix, and a monitoring page with a permanent red mark on it is one
people stop reading.

### Seeing what a type actually renders

`scripts/platform-render` exists so these types can be read rather than
trusted. `Application` wires database URIs and S3 keys into a Deployment
through `secretKeyRef`s generated several layers down; this is how you look at
that wiring instead of taking its word for it.

Before applying — validates against the live schema and, more usefully, shows
every default you did **not** set but will get:

```
scripts/platform-render preview -f deploy/application.yaml
```

After applying — the escape hatch. Every object kro really rendered, cleaned of
cluster bookkeeping, as manifests you could commit and maintain by hand:

```
scripts/platform-render eject Application/myapp -n myapp
```

`eject` labels each object with the RGD node that produced it, and says
explicitly when a resource was *not* rendered for your instance — "why is there
no PVC?" is exactly the question it exists to answer. Its output applies
cleanly as-is (verified), which is what makes forking down out of the
abstraction a real option rather than a claim.

**What `preview` deliberately does not do** is compute the rendered objects.
kro evaluates its CEL in its controller, *after* the instance is stored, not in
an admission webhook — `kubectl apply --dry-run=server` on an `Application`
returns the `Application` and nothing else. A pre-apply render would mean a
second implementation of kro's evaluator, and one that drifts from the real one
is worse than no preview. So `preview` lists which resources the RGD declares
and the condition each conditional one depends on, and stops there.

### Attachment lists are always lists

Even a single database or bucket is written as a one-item list. Aliases are
mandatory and always suffix the environment variable — there is no bare
`DATABASE_URL` or `AWS_ACCESS_KEY_ID` for the single-attachment case. This is
deliberate: it means adding a second attachment later never breaks the
first.

### Environment variables produced

| Attachment | Variable | Source |
|---|---|---|
| `databases[].as: X` | `DATABASE_URL_X` | `<ref>-app` Secret, key `uri` |
| `objectStorage[].as: X` | `S3_ENDPOINT_X` | derived, `http://seaweed-s3.seaweedfs.svc:8333` |
| | `S3_BUCKET_X` | the referenced `ObjectStorage`'s resolved bucket name |
| | `AWS_ACCESS_KEY_ID_X` | minted `S3Credentials` Secret |
| | `AWS_SECRET_ACCESS_KEY_X` | minted `S3Credentials` Secret |

`X` is the alias, upper-cased with hyphens turned to underscores
(`read-replica` → `READ_REPLICA`).

### The `external` database escape hatch

For a database this platform doesn't own/provision:

```yaml
databases:
  - ref: unused-but-required   # ignored when externalSecretName is set
    as: legacy
    externalSecretName: my-hand-created-secret
    externalSecretKey: uri     # default "uri"
```

No `Database` instance needed or looked up; `DATABASE_URL_LEGACY` is wired
straight from the named Secret. Rarely needed — most apps should provision a
real `Database`.

## Status and how to read it

```
kubectl get databases,objectstorages,applications -n <namespace>
```

`Application`'s columns:

| Column | Means |
|---|---|
| `READY` | kro's own condition — the graph rendered successfully. **Does not mean attachments resolved.** |
| `RESOLVED` | `true` only if every `databases`/`objectStorage` ref actually matched something (or used the external escape hatch) |
| `UNRESOLVED` | list of ref names that didn't resolve — empty when healthy |
| `URL` | live Tailscale FQDN, once the Ingress has one |

**Always check `RESOLVED`/`UNRESOLVED`, not just `READY`.** A typo'd ref
still renders the Deployment (with a `secretKeyRef` pointing at a Secret
that doesn't exist), which shows `READY: True` and fails at the pod with
`CreateContainerConfigError` — `UNRESOLVED` is what actually tells you why.

## Onboarding a brand-new app

1. `deploy/namespace.yaml` (as before). Add the `seaweedfs-access` label if
   using object storage.
2. `deploy/database.yaml` — only if this app needs a *new* database. Skip if
   attaching to one that already exists.
3. `deploy/objectstorage.yaml` — only if this app needs a *new* bucket. Skip
   if attaching to an existing one (see sharing, above).
4. `deploy/application.yaml` referencing whichever of the above apply, by
   name, plus your image/port/host/probe.
5. `deploy/kustomization.yaml` listing all of the above (`namespace.yaml`
   first).
6. Push. Flux picks it up on its next reconcile (5m for app repos), or force
   it: `flux reconcile kustomization <app-name> --with-source`.

## Migrating an *existing* hand-written app — read this before deleting anything

Deleting a hand-written `Cluster`/`Bucket` manifest and adding the typed
instance **in the same PR is a real data-loss risk.** Flux prunes objects
whose manifest disappears; the typed instance creates a *new* one under the
same name, and the old data is gone. This is not hypothetical — it happened
during `fastapi-echo`'s own migration.

An in-cluster annotation added by hand does **not** survive — Flux
re-evaluates prune eligibility from the manifest it applies, not from the
live object, so a `kubectl annotate` before merging doesn't help.

**Correct sequence, two PRs:**

1. **PR A** — add `kustomize.toolkit.fluxcd.io/prune: disabled` directly
   into the *existing* manifest (the old `Cluster`/`Bucket`/etc. YAML file
   itself). Merge, let Flux apply it for real, confirm the annotation is
   live on the object (`kubectl get cluster <name> -n <ns> -o
   jsonpath='{.metadata.annotations}'`).
2. **PR B** — remove the old manifest, add the `Database`/`ObjectStorage`
   instance under the same `metadata.name`. Flux prunes nothing (annotation
   already in effect), and the typed instance's controller *adopts* the
   existing object in place — confirmed empirically to preserve data and
   keep the same PVC (no reprovisioning).

**Also expect a downtime window from the image-automation gap.** There's no image-
automation reconciler yet, so if the app's `Deployment` gets recreated (as
part of adopting the typed `Application`), it may briefly run the *old*
image against a *new* environment variable name — as happened with
`fastapi-echo`'s `DATABASE_URL` → `DATABASE_URL_MAIN` rename. Force a fresh
pull once CI has published:
```
kubectl rollout restart deploy/<app-name> -n <namespace>
```

**If the app renders an `Ingress`, expect a brief HTTPS blip on recreation**
even though nothing else changed — the Tailscale proxy rebuilds and
re-issues its TLS cert. Self-heals in well under a minute; don't force-retry
a `tailscale cert` re-issuance by hand, it can make it worse.

## Verification checklist

```
export KUBECONFIG=$HOME/.kube/config

# Instances healthy
kubectl get databases,objectstorages,applications -n <namespace>

# Postgres reachable
kubectl cnpg psql <database-name> -n <namespace>

# Being scraped
kubectl get podmonitor -n <namespace>

# Rendered env vars look right
kubectl get deploy <app-name> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool

# App serving
curl -s -o /dev/null -w "%{http_code}\n" https://<host>.tailf4742d.ts.net/<probePath>
```

If using object storage, prove isolation rather than just presence — a
policy *existing* is not the same as it actually restricting anything:

```
AK=$(kubectl get secret <app>-<alias>-s3 -n <ns> -o jsonpath='{.data.accessKey}' | base64 -d)
SK=$(kubectl get secret <app>-<alias>-s3 -n <ns> -o jsonpath='{.data.secretKey}' | base64 -d)
```

Then from a debug pod (or locally against the tailnet, if reachable) with
`AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK`, endpoint
`http://seaweed-s3.seaweedfs.svc:8333`:

- write/read inside `s3://<bucket>/<app>-<alias>/...` → succeeds
- write outside that prefix, or at the bucket root → `AccessDenied`

Both cases matter — only checking the success case would miss a
fail-everywhere policy that happens to pass an existence check by accident.

Prove the ingress lockdown the same way, and for the same reason — a
`NetworkPolicy` that exists and a `NetworkPolicy` that enforces looked
identical on this cluster for months:

```
kubectl create ns netpol-check
kubectl -n netpol-check run c --image=curlimages/curl --command -- sleep 300
kubectl -n netpol-check wait --for=condition=ready pod/c --timeout=90s
SVC=$(kubectl get svc <app> -n <ns> -o jsonpath='{.spec.clusterIP}')

# negative: MUST fail. Uses the IP, so a DNS hiccup can't be mistaken for a deny.
kubectl -n netpol-check exec c -- curl -sS -m 8 -o /dev/null -w '%{http_code}\n' http://$SVC:80/

# positive: MUST still return 200
curl -s -o /dev/null -w '%{http_code}\n' https://<host>.tailf4742d.ts.net/<probePath>

kubectl exec -n kube-system ds/cilium -- hubble observe --namespace netpol-check --type drop --last 20
kubectl delete ns netpol-check
```

## Known limits, worth knowing before you start

- **No image automation yet.** `:latest` + manual `kubectl rollout
  restart` is the current story. Tracked as LES-57.
- **Schema evolution is additive-only in practice.** Adding an optional
  field to `Database`/`Application`/`ObjectStorage` is safe and doesn't
  touch existing instances. Renaming, retyping, or removing a field breaks
  every existing instance of that kind — kro refuses to apply the CRD change
  at all until the offending instances are gone.
- **Printer columns (`RESOLVED`, `URL`, etc.) can't be added or changed
  after a kind is first created**, even by deleting and recreating the RGD —
  the generated CRD survives RGD deletion and gets adopted, columns and all.
  Not something an app author needs to touch, just don't expect a `kubectl
  get` column to change without a real CRD rebuild (which means deleting
  every instance of that kind first).
