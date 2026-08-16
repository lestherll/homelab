# Self-service typed API PoC: Application, Database, Object Storage

*Design plan and build record for decisions D15 and D16. D15 shipped and is
closed (LES-54); D16 is still design-only (LES-55). See CONCEPT.md for where
these decisions are recorded, and the Implementation log below for what
actually happened building D15.*

## Context

Two apps and one hand-built Postgres instance have proven the raw pattern (per
`docs/gitops-onboarding-learnings.md`). CONCEPT.md's D1 promotion rule says a
resource type earns a Layer 1/2 API only after a third hand-built instance —
but the user has decided, for this build, that **instance count doesn't
matter as much as proving the self-service pattern now**: declare an app,
optionally attach a database and/or object storage, and get all of it
provisioned with zero manual wiring. This is a deliberate pivot from D1's
counting rule, recorded in CONCEPT.md as decision **D15**. The current branch
(`concept/d14-reconciliation-lane`) is unmerged — sequence D15 after D14
lands on `main`, or build both on the same branch and merge together.

**Why the pivot is defensible:** the leakiness D1 guards against comes from
hand-committing to bespoke YAML per instance and migrating everyone off it
later. A kro `ResourceGraphDefinition` doesn't have that failure mode the
same way — it's declarative and cheap to revise in place. The risk moves
from "wrong abstraction, expensive to fix" to "kro's API is v1alpha1" — real
but smaller (see Risks).

**Composition engine: kro** (user's choice over Crossplane / hand-rolled
operator). Three types — `Application`, `Database`, `ObjectStorage` —
matching D1's original naming.

## Research findings (verified against primary sources — CRD Go source,
## live cluster state, and the actual app repo, not just docs)

- **kro**: v0.9.3, OCI Helm chart `oci://registry.k8s.io/kro/charts/kro`,
  API `v1alpha1`. Canonical repo confirmed as `github.com/kubernetes-sigs/
  kro` — kro moved orgs (`awslabs/kro` → `kro-run/kro` →
  `kubernetes-sigs/kro`) and is now a Kubernetes SIG Cloud Provider/CNCF
  subproject, not a single-vendor project — a real maturity signal,
  consistent with the OCI path already living under `registry.k8s.io`.
  Two of its features are load-bearing for this design, both confirmed
  against kro's own v0.9.3 docs (not assumed, and re-verified a second
  time after an initial design draft got their interaction wrong — see
  §5.1):
  - **`externalRef`**: an RGD can reference a resource it does *not* create
    or manage — reads it from the cluster, waits for it to exist, exposes
    its fields to CEL — without kro touching its lifecycle. Comes in two
    forms: **scalar** (`metadata.name`, one object) and **collection**
    (`metadata.selector`, an array of matching objects) — mutually
    exclusive with each other, confirmed at `kro.run/docs/concepts/rgd/
    resource-definitions/external-references/`. This is the real mechanism
    for "attach to a `Database`/`ObjectStorage` instance another app (or
    file) created," replacing the earlier draft's fragile "just assume the
    name matches" convention with an actual resolved lookup.
  - **`forEach` (Collections)**: one resource template can expand into N
    resources, driven by a CEL-iterated list in the schema, staying in sync
    as the list changes. This makes a real multiple-attachments-per-app
    schema buildable now, not a someday-maybe. **Confirmed mutually
    exclusive with `externalRef` on the same resource template**
    (`kro.run/docs/concepts/rgd/resource-definitions/collections/`,
    "Constraints & Gotchas": *"A resource cannot use both `forEach` and
    `externalRef`"*) — §5.1 designs around this with two separate resource
    entries per attachment type instead of one combined entry. Also
    confirmed: an empty collection (scalar-`externalRef`-selector or
    `forEach` source) is considered *ready*, not blocking — unresolved
    references need explicit CEL status logic, not implicit blocking (§5.1).
- **MinIO Operator is archived** (2026-03-20) — ruled out.
- **SeaweedFS core**: v4.41 (2026-08-06), very active.
- **`seaweedfs-operator`**: actively maintained, installs via Flux
  `HelmRelease`, no cert-manager dependency (Helm hook generates its
  webhook cert). CRD set, all `seaweed.seaweedfs.com/v1`: `Seaweed`,
  `Bucket`, `BucketLifecyclePolicy`, `S3Identity`, `S3Credentials`,
  `S3Policy`, `S3PolicyBinding`, `ResourceReferenceGrant`.
- **Read directly from the CRDs' Go source** (`api/v1/*_types.go` on
  `seaweedfs/seaweedfs-operator`), not just prose docs, because the last
  review round caught prose/reality drift once already:
  - `Bucket.spec.clusterRef` (required), `S3Identity.spec.seaweedRef`
    (required), `S3Policy.spec.seaweedRef` (required) — **all three**
    reference the `Seaweed` cluster cross-namespace, alongside the
    already-known `S3Credentials`/`S3PolicyBinding`. **All five kinds need
    `ResourceReferenceGrant` coverage**, not the three the previous draft
    listed.
  - `Bucket.spec.name` is a **separate, optional field** from
    `metadata.name` (immutable once set, defaults to `metadata.name` if
    unset) — this is the lever for giving buckets a globally-unique
    underlying name without renaming the k8s object itself.
  - `Bucket.spec.adoptExisting` (bool, default `false`) is real and exists
    for exactly the "re-declare after a Retain-policy delete" recovery
    path — but it's opt-in, so a plan that relies on Retain+recovery
    without ever setting it doesn't actually work.
  - `Bucket.spec.reclaimPolicy` defaults to `Retain`; `S3Identity`/
    `S3Policy`/(confirmed same pattern for `S3Credentials`/
    `S3PolicyBinding`) default to `Delete`.
  - `S3Policy.spec` requires **exactly one** of `statements` (shorthand) or
    `policyDocument` (raw JSON) — confirms prefix-conditioned policies
    (which need an `s3:prefix` condition on `s3:ListBucket`, not expressible
    in the shorthand) need `policyDocument`.
- **Read the actual live and app-repo state, not just assumed
  render-equivalence:** `fastapi-echo`'s live `Deployment`
  (`github.com/lestherll/fastapi-echo/deploy/deployment.yaml`) wires its
  database credential with an **explicit** `env: - name: DATABASE_URL,
  valueFrom: secretKeyRef: {name: fastapi-echo-db-app, key: uri}` — not
  `envFrom`. A design that used `envFrom` would dump every key in that
  Secret (`host`, `user`, `password`, `uri`, …) as bare env vars instead of
  producing `DATABASE_URL`, breaking the render-equivalence this plan
  claims for the `fastapi-echo` migration. Fixed below (§5).

## Design

**Conceptually, this is two APIs, not three unrelated types**: `Database`/
`ObjectStorage` are *resource APIs* ("provision this infrastructure,"
unaware of any consumer), while `Application`'s `databases`/
`objectStorage` lists are an *attachment API* ("consume this resource
with an isolated, consumer-specific credential"). Neither `Database` nor
`ObjectStorage` needs to know `Application` exists — which is exactly why
the D1-named future types (`CodingEnvironment`, batch/CronJob workloads)
can adopt the same attachment shape later without changing either
resource API. Worth stating once, up front, since it's the load-bearing
idea behind §5's design.

### 1. Platform-level infrastructure

- `infrastructure/kro/` — `HelmRepository` (`type: oci`) + `HelmRelease`,
  pinned version.
- `infrastructure/seaweedfs/`:
  - `namespace.yaml`, `helmrepository.yaml` + `helmrelease.yaml` for
    `seaweedfs-operator` (pinned version; note its CRDs ship with
    `helm.sh/resource-policy: keep`, so a Flux uninstall won't remove them
    — different from every other chart here, worth the comment).
  - `seaweed-cluster.yaml` — one `Seaweed` instance: 1 master, 1 volume
    (PVC on `local-path-retain`, `platform.homelab/durability: durable`),
    1 filer, and a **top-level `spec.s3` block** (the recommended,
    standalone-Deployment mode — not the deprecated `spec.filer.s3.enabled`
    embedded path). Server image tag pinned explicitly (no `latest`).
  - `resourcereferencegrant.yaml` — **one platform-owned grant**, in the
    `seaweedfs` namespace, trusting `Bucket`, `S3Identity`,
    `S3Credentials`, `S3Policy`, and `S3PolicyBinding` sources from any
    namespace labeled `platform.homelab/seaweedfs-access: "true"` via a
    `namespaceSelector`. All five kinds, not three — the previous draft's
    gap, caught by reading the actual CRD source.
- `infrastructure/platform-api/` — the kro `ResourceGraphDefinition`s.
  `platform.homelab/v1alpha1` is the group/version every app repo will
  hardcode into every instance manifest — **treat this as a permanent,
  one-way-door choice**, not a placeholder (kro CRD group/version can't be
  changed post-creation without a coordinated migration across every app
  repo).

### 2. Namespace topology

- Shared `Seaweed` cluster + `seaweedfs-operator` live in one `seaweedfs`
  namespace.
- Each app still creates its own namespace via `namespace.yaml` in its own
  repo's `deploy/` (unchanged). Label it
  `platform.homelab/seaweedfs-access: "true"` if it uses object storage.
  **This label is a security-sensitive capability grant, not cosmetic
  metadata** — per §1's `resourcereferencegrant.yaml`, possessing it lets
  a namespace's `Bucket`/`S3Identity`/`S3Credentials`/`S3Policy`/
  `S3PolicyBinding` objects reference the shared `Seaweed` cluster.
  Acceptable without finer-grained control given AGENT.md's explicit
  single-user/no-multi-tenancy scope (same reasoning §3 already applies to
  Postgres sharing), but call it what it is in the RGD's own comments, and
  make label-toggling part of Verification, below.
- `Database` instances render their `Cluster` in the app's own namespace —
  no cross-namespace reference for Postgres in this PoC (sharing is
  descoped, §3), so no grant needed on that side.

### 3. `Database` — single-consumer only in this PoC, and why that's correct, not a shortcut

CNPG's `DatabaseRole.spec.passwordSecret` **requires a pre-existing
Secret** — the operator does not generate one, and kro's CEL can't mint a
random password (deterministic by design; hand-rolling credential
derivation would be exactly the novelty D1 principle 5 warns against).
`S3Credentials` auto-generates; `DatabaseRole` does not. The two data
services are **not symmetric**, and this plan doesn't claim they are.

**Decision:** a `Database` instance (`kind: Database`, schema `{ size:
small|medium }`) renders exactly one CNPG `Cluster`, matching the spec
already live for `fastapi-echo-db`, plus one `PodMonitor` (§7). Its
consumer uses CNPG's own bootstrap `<cluster>-app` Secret. No
`DatabaseRole`, no multi-consumer story.

**"Using an existing db from another app" — not supported as a first-class
path yet, on purpose.** A `Database` instance's `<name>-app` Secret has one
role. A second `Application` attaching to the same `Database` would get
*identical* credentials to the first — literal shared access, already
decided earlier in this planning process to be a deliberate Layer-0 escape
hatch, never a schema-level feature, because it collapses blast-radius
isolation between two apps. **Treat each `Database` instance as 1:1 with
its consumer by convention**, documented in the RGD's own comments — this
is a solo-operator repo, so review discipline is the enforcement mechanism,
not a webhook.

**Named trigger to revisit (recorded in D15):** multi-consumer Postgres
becomes worth building when a second app actually needs to share an
engine. Leading candidate: `DatabaseRole`'s `clientCertificate` option,
which *does* have the operator auto-generate and rotate a
`<name>-client-cert` Secret — genuinely zero-touch, unlike a shared
password. Needs `pg_hba` cert-auth config and app-driver TLS support; real
work, correctly deferred.

### 3.1 External / unmanaged databases

Handled as a variant within the attachment shape in §5, not a separate
field — see below.

### 4. `ObjectStorage` — composes `seaweedfs-operator`'s CRDs

`kind: ObjectStorage`, schema `{ }`. Renders one `Bucket`:
```yaml
metadata:
  name: ${schema.metadata.name}       # k8s object name — namespaced, no collision risk
spec:
  name: ${schema.metadata.namespace}-${schema.metadata.name}  # actual S3 bucket name — globally unique
  clusterRef: { name: seaweed, namespace: seaweedfs }
  adoptExisting: true                 # safe: this CR only ever owns its own derived name
```
`adoptExisting: true` unconditionally — safe because the bucket's real name
is derived from this CR's own namespace+name, so it can only ever "adopt"
a bucket it previously created itself (the Retain-then-recreate recovery
path the design already relies on, now actually wired to work).

**The derived-name invariant needs an explicit constraint, not just a
comment.** `${namespace}-${name}` must be a legal S3 bucket name (3–63
chars, lowercase alphanumeric/hyphen, no leading/trailing hyphen, not
IP-formatted) for `adoptExisting`'s "only ever adopts its own bucket"
safety property to hold — a namespace+name combination that produces an
*invalid* bucket name fails loudly at kro apply time (acceptable), but one
that's merely *long* could theoretically collide or truncate ambiguously.
Add a schema-level length check on `ObjectStorage`'s `metadata.name`
sized so `namespace + "-" + name` can never exceed 63 chars for this
cluster's realistic namespace-name lengths — same "fail at apply time"
philosophy already used for `size`/`as` (§5), not a runtime surprise.

**`ObjectStorage` must publish a status, or §5 has nothing to read.** §5's
`Application`-side wiring resolves the bucket name via `externalRef` off
`status.bucketName` — that field has to actually exist on the RGD, not be
assumed. Add one CEL status expression:
`status.bucketName: ${bucket.status.bucketName}` (echoing the rendered
`Bucket`'s own resolved-name status field, confirmed to exist on the
`Bucket` CRD in §"Research findings"). One line in the RGD; without it the
whole attachment contract in §5 references a field that isn't there.

**Sharing flow, stated precisely (the previous draft had a real bug here):**
exactly **one** `ObjectStorage` instance exists per shared bucket, created
once by whichever app first needs it. A second app that wants the *same*
bucket does **not** create a second `ObjectStorage` instance — declaring
`ObjectStorage` named `X` twice renders two `Bucket` CRs both resolving to
the same underlying S3 bucket name, which fails
(`BucketAlreadyExists`, since `adoptExisting` only helps a CR reclaim its
*own* prior bucket, not a sibling's). The second app instead only adds an
entry to its own `Application`'s `objectStorage` list (§5), referencing
`X` by name via kro's `externalRef` — no new `ObjectStorage` CR.

**Per-app isolation, uniform for every consumer (not just the first):**
each `Application` attachment to an `ObjectStorage` instance renders its
own `S3Identity` + `S3Credentials` (namespace-prefixed name, since IAM
names are cluster-global — confirmed in the Go source) and an `S3Policy`
(via `policyDocument`, not `statements`, since scoping needs an
`s3:ListBucket` grant on the bucket ARN *with* an `s3:prefix` condition,
plus object actions scoped to `<bucket>/<app-name>/*`) + `S3PolicyBinding`.
**Every consumer gets the same `<bucket>/<app-name>/*` scoping, including
the bucket's first and only consumer** — no "full scope for whoever got
there first." The earlier draft's version of this was actually
unimplementable: an `Application` RGD instance only ever sees its own
spec, with no way to know whether it's the first attachment to branch on,
and even if it could, "first consumer keeps full access forever, everyone
after gets scoped" is a permanent isolation asymmetry with no tightening
trigger. Uniform scoping is simpler, safer, and makes "credentials fail
outside their own prefix" a true statement for every consumer, not just
some.

### 5. The developer-facing contract

**Attachments are lists with aliases from day one, not a single field that
would need a breaking migration later.** kro's `forEach` makes "N databases,
N buckets, aliased" buildable now; the group/version choice in §1 is a
one-way door once app repos hardcode manifests against it, so this is the
moment to pick the shape that doesn't need a cliff-edge migration the day
an app grows a second attachment. A single-attachment app just writes a
one-item list.

```yaml
# deploy/database.yaml
apiVersion: platform.homelab/v1alpha1
kind: Database
metadata:
  name: fastapi-echo-db
  namespace: fastapi-echo
spec:
  size: small
---
# deploy/application.yaml
apiVersion: platform.homelab/v1alpha1
kind: Application
metadata:
  name: fastapi-echo
  namespace: fastapi-echo
spec:
  image: ghcr.io/lestherll/fastapi-echo:latest
  port: 8000
  host: fastapi-echo
  probePath: /healthz
  size: small
  databases:
    - ref: fastapi-echo-db
      as: main
```

### 5.1 Attachment resolution mechanism — corrected against kro v0.9.3's actual constraints

**This subsection replaces an earlier draft that combined `forEach` and
`externalRef` on the same resource template — confirmed against kro
v0.9.3's own docs (`kro.run/docs/concepts/rgd/resource-definitions/
collections/`, "Constraints & Gotchas") to be flatly disallowed: *"A
resource cannot use both `forEach` and `externalRef` — they are mutually
exclusive fields."* The fix below is kro's own documented alternative
(`external-references/`, "External Collections"), not a workaround.**

The RGD's `spec.resources` splits attachment resolution into two separate
resource entries per attachment type, never combined on one:

1. **A collection `externalRef`** (one per attachment type, not
   `forEach`'d): `externalRef.metadata.selector: {}` against the
   `Database` (respectively `ObjectStorage`) kind, scoped to the
   `Application` instance's own namespace — an empty `matchLabels`
   selector selects every instance of that kind in-namespace under
   standard Kubernetes label-selector semantics (no new labels needed on
   `Database`/`ObjectStorage` — **verify this empty-selector behavior
   against a real v0.9.3 cluster in the "Implementation sequencing" spike,
   below**, since kro's
   docs describe selector syntax but don't show an empty-selector example
   explicitly). This yields a CEL-visible array, e.g. `databasesInNs`.
2. **A separate `forEach`** entry (over `schema.spec.databases` /
   `schema.spec.objectStorage`) that does *not* perform its own
   `externalRef` — instead its CEL matches each loop item against the
   *already-fetched* collection from (1): e.g.
   `databasesInNs.filter(d, d.metadata.name == item.ref)`. This is where
   the mutual-exclusion rule is satisfied: the entry doing the lookup
   isn't the entry doing the loop.

**Unresolved refs must be explicit, not assumed blocking.** kro's own
docs state plainly (same Collections page, "Empty Collections Are
Ready"): *"An empty array produces zero resources. The collection is
still considered ready, because there are no items to wait on."* This
directly invalidates the earlier draft's claim that "a typo'd `ref`
blocks the whole render" — with collection-based matching, a typo'd `ref`
instead silently produces an empty filtered result that reads as
*ready*. The RGD's status must therefore compute unresolved refs
explicitly in CEL, e.g.:
```yaml
status:
  unresolvedDatabaseRefs: >-
    ${schema.spec.databases.filter(d,
      size(databasesInNs.filter(x, x.metadata.name == d.ref)) == 0
    ).map(d, d.ref)}
  # same pattern for unresolvedObjectStorageRefs
  ready: >-
    ${size(unresolvedDatabaseRefs) == 0 &&
      size(unresolvedObjectStorageRefs) == 0 && <workload ready>}
```
This is now a **first-class part of the base design**, not a deferred
nice-to-have (§ Risks previously deferred "refs resolve into what `ready`
means" to "a later pass" — that deferral is retracted; collection
semantics make it load-bearing from the start).

**What this renders into the Deployment (explicit, not implied):**
- The Deployment's `env` list itself does **not** need `forEach` at all —
  it's a single CEL `.map()` over `schema.spec.databases` /
  `schema.spec.objectStorage` computed inline within the one Deployment
  resource, referencing the matched entries from (2) above. `forEach` is
  only needed where **multiple separate K8s objects** must be stamped out
  per attachment — i.e. the `S3Identity`/`S3Credentials`/`S3Policy`/
  `S3PolicyBinding` set per `objectStorage[]` entry (§4), not the env vars.
- Each matched `databases[]` entry renders an explicit env var
  `DATABASE_URL_${entry.as.upperAscii().replace('-', '_')}` via
  `secretKeyRef` to `<ref>-app`/`uri` (kro's CEL environment registers
  `ext.Strings()`, whose function is `upperAscii()` — there is no bare
  `upper()`) — matching exactly how `fastapi-echo` already reads its
  credential, just alias-suffixed. `as` is schema-validated against
  `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` so every accepted alias produces a
  legal env var name — same "fail at apply time" reasoning as `size`.
  **Always suffixed, no bare-name special case for a single entry** — one
  code path. This does mean `fastapi-echo`'s own code needs a one-line
  rename (`DATABASE_URL` → `DATABASE_URL_MAIN`, confirmed as the only
  occurrence, in `src/fastapi_echo/__init__.py`) as part of its migration —
  a tiny, named, explicit cost, and the first real evidence this PoC
  produces about what "adopting the platform" costs an app (Proof step 1).
- Each `databases[]` entry with `external.secretRef` set (the escape hatch
  for a database this platform doesn't own) skips `Database`/`Cluster`
  entirely and wires the same `DATABASE_URL_${entry.as.upperAscii()...}`
  from the named pre-existing Secret instead. No provisioning, just wiring.
- Each matched `objectStorage[]` entry reads its `ObjectStorage`
  instance's resolved `status.bucketName` (the `ObjectStorage` RGD must
  define this — see §4's fix below; without it there's nothing here to
  read) — not guessed from a naming convention. The `forEach`'d resource
  entry renders the per-app `S3Identity`/`S3Credentials`/`S3Policy`/
  `S3PolicyBinding` from §4, then the Deployment's CEL-mapped env list
  wires: `S3_ENDPOINT_${AS}` (`http://<cluster-name>-s3.seaweedfs.svc:8333`
  — derived, not secret), `S3_BUCKET_${AS}`, `AWS_ACCESS_KEY_ID_${AS}`,
  `AWS_SECRET_ACCESS_KEY_${AS}`. **Secret key names confirmed, not
  assumed**: `seaweedfs-operator`'s `S3Credentials` controller
  (`internal/controller/s3credentials_controller.go:45-46`, confirmed
  against the operator's actual Go source) defaults to Secret keys
  `accessKey`/`secretKey` — but these are configurable via
  `spec.secretRef.accessKeyField`/`secretKeyField` (`api/v1/
  s3credentials_types.go:64-76`), so the rendered `S3Credentials` resource
  must **pin them explicitly** rather than rely on the default silently
  matching, and this pairing should become a small contract test (create
  `S3Credentials`, assert the Secret has non-empty `accessKey`/`secretKey`)
  so a future operator upgrade that changes the default fails loudly
  instead of silently breaking every `Application`.
  **No bare-name special case here either — dropped, not kept.** An
  earlier draft of this plan proposed also emitting bare
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for a single-entry list, for
  SDK auto-discovery convenience. That's a real cliff wearing a "pure
  addition" disguise: the day a second `objectStorage` entry is added, the
  bare vars would have to disappear (no way to tell an SDK's default chain
  which of two buckets a bare var means), silently breaking whatever
  config depended on them — exactly the migration cliff this whole
  attachment shape exists to avoid, and inconsistent with paying that same
  uniformity cost on the database side one bullet above. Dropped in favor
  of one code path; a single-bucket app points its S3 client at the
  aliased env names explicitly (one line of client config).
- **Status contract, strengthened**: `Application`'s kro schema reports
  `ready: bool`, `url: string`, `unresolvedDatabaseRefs: []string`,
  `unresolvedObjectStorageRefs: []string` (§5.1 above) — `ready` is
  `false` whenever any ref is unresolved, not just when the workload
  itself isn't ready. `kubectl get applications -n <ns>` shows readiness,
  the live URL, and *why* it isn't ready, directly.
- **Validation contract**: `size` is schema-constrained to an enum
  (`small`/`medium`) — a typo fails at `kubectl apply`/git-push time, not
  deep in a reconcile loop. (Naming note: the earlier draft had `Database`
  use `size` and `Application` use `resources` for the same t-shirt-size
  concept — standardized on `size` everywhere.)
- **Schema still needs fields the evidence doc already named** —
  `securityContext`, a persistence story — added when
  `personal-finance-dashboard` migrates (Proof step 2), not invented
  speculatively now. Adding them then is itself a small, deliberate test of
  this pivot's central claim ("cheap to revise in place"): kro
  re-reconciles every existing `Application` instance against the new
  schema revision when the RGD changes, and additive optional fields are
  the safe case. Worth collecting that as evidence on purpose, not just
  noting it in passing. **Make the test matrix explicit, not just the
  happy path** (folded into Proof step 2's scope, below): confirm the
  additive case (`fastapi-echo`'s existing `Application` instance survives
  the schema revision unchanged, still reconciles, still `ready: true`)
  *and* deliberately attempt a breaking change against a throwaway
  instance (change an existing field's type, flip optional→required,
  rename a field) to confirm it fails validation as expected rather than
  silently corrupting state. The claim to walk away with is "additive
  evolution is cheap, breaking evolution is not" — as evidence, not
  philosophy.

### 6. Database administration and object-storage admin — reuse, don't build

`kubectl cnpg psql <cluster> -n <namespace>` (official CNPG plugin) for
interactive Postgres access against any `Cluster`. Add `kubectl-cnpg` to
`ansible/roles/cli_tools/vars/main.yml`. For SeaweedFS: `weed shell` via
`kubectl exec`, plus `mc`/`aws s3` against the real S3-compatible gateway.
No platform-side tooling to build for either.

### 7. Observability for provisioned data services

CONCEPT.md's C7/C6 make this a **must**. Checked against the live cluster
while writing this plan: **`fastapi-echo-db` is not being scraped today** —
`enablePodMonitor: false`, no `PodMonitor` exists anywhere in the cluster.
This predates the PoC; fixing it is in scope since the `Database` RGD
renders `Cluster`s from here on anyway.

- `enablePodMonitor` is **deprecated** by CNPG upstream in favor of a
  hand-managed `PodMonitor`. The `Database` RGD renders **`Cluster` +
  `PodMonitor`** as one bundle (targeting the exporter every CNPG instance
  already runs on port 9187).
- **Dashboards: reuse.** CloudNativePG's community Grafana dashboard
  (grafana.com ID `20417`, confirmed live under the official CloudNativePG
  org) as a ConfigMap under `infrastructure/observability/dashboards/`,
  same mechanism already used for Node Exporter Full (ID `1860`). For
  SeaweedFS, name a specific dashboard ID/source file at implementation
  time rather than asserting one now — unverified here — but add it via
  the same ConfigMap mechanism once found.
- **SeaweedFS metrics config lives on the `Seaweed` CR itself, not the
  operator's Helm values** (confirmed against the CRD's Go source): each
  component (`master`/`volume`/`filer`/`s3`/`admin`/`worker`) has its own
  `metricsPort` field in `seaweed-cluster.yaml`, so that's where scraping
  gets enabled, not `infrastructure/seaweedfs/helmrelease.yaml`. Only the
  `s3` (and `admin`) components' `metricsPort` doc says setting it "causes
  the operator to provision a matching `ServiceMonitor`" automatically —
  master/volume/filer don't document that, so full engine-wide scrape
  coverage may need hand-managed `PodMonitor`s for those three, mirroring
  what `Database` already does for CNPG. Verify per component during
  implementation rather than assuming symmetry across all six. Separately:
  `spec.metricsAddress` on the `Seaweed` CR is a **Prometheus Pushgateway
  push target**, not a scrape config — don't reach for it by mistake, it
  solves a different problem than what kube-prometheus-stack needs here.
- SeaweedFS metrics cover the shared engine's own health, not per-app/
  per-bucket attribution — it has no per-bucket Prometheus labels, and C7's
  cardinality rule wouldn't want them if it did. Per-app usage questions
  are answered with `mc`/`weed shell` on demand.
- **Alerting inherits an existing, separately-tracked gap.** Alertmanager's
  receiver is still `null`. Any `PrometheusRule` added here evaluates
  correctly but reaches no one until that's fixed — name this plainly in
  D15 rather than shipping alerts that fire into the void (C7's own
  "alerts I learn to ignore" anti-requirement).
- **`Application.status.ready` and Prometheus scrape health are
  independent guarantees — prove they don't get conflated.** `ready:
  true` (§5.1) means refs resolved + workload ready; it says nothing
  about whether Prometheus is actually scraping the `PodMonitor`. Add
  this as an explicit Verification check (below), not an assumption.

## Onboarding checklist (per app)

1. Create the app's namespace (unchanged). Label it
   `platform.homelab/seaweedfs-access: "true"` if it uses object storage.
2. If a *new* database is wanted: add one `Database` instance. (Skip this
   if attaching to one that already exists — see step 4.)
3. If a *new* object-storage bucket is wanted: add one `ObjectStorage`
   instance. (Skip if attaching to an existing one — §4's sharing flow.)
4. Add one `Application` instance with `databases`/`objectStorage` lists
   referencing whichever instances apply, new or pre-existing, by name.
5. **App repo, not homelab repo** (per D16, §8 below): add
   `flux/flux-pointer.yaml` **at the app repo's root — deliberately
   outside `./deploy`**, since the app's own `Kustomization` reconciles
   `./deploy` with `prune: true`; if the pointer objects lived inside the
   path Flux reconciles, the `Kustomization` would manage (and could
   prune) its own registration — a self-referential loop. Plus one CI
   step + 5 GitHub Actions secrets. The homelab repo is never touched.

## Implementation sequencing — spike the risky mechanism first

**Not the order the sections above are written in, deliberately.** §5.1's
collection-`externalRef` + `forEach` composition is confirmed correct
against kro's docs, but kro's own docs/examples repo has **no worked
example** of this exact pattern (confirmed during review — it's implied
by cross-references between the Collections and External References
pages, not demonstrated end-to-end). That's the single highest-risk
unknown in this whole plan — higher than anything SeaweedFS-related,
where the risk was "prose might be stale" (mitigated by reading Go
source) rather than "this composition might not work as documented at
all." Build in this order, not top-to-bottom:

1. **Spike the attachment-resolution mechanism in isolation, before
   touching SeaweedFS.** A throwaway RGD with a schema list of `{ref, as}`
   entries, a collection `externalRef` against a couple of hand-created
   dummy CRs, and a `forEach`-driven consumer template matching against
   the fetched collection via CEL. Test explicitly: 0 attachments, 1, 2;
   a nonexistent `ref`; deleting a referenced resource after the fact;
   adding/removing a list entry; alias validation. If the empty-selector
   behavior (§5.1) or the two-resource-entry split doesn't work as
   designed, find out here, cheaply, not mid-way through building
   `Database`+`ObjectStorage`+SeaweedFS around it.
2. **`Database` + `fastapi-echo`** (Proof step 1) — the simpler
   attachment type, no SeaweedFS dependency.
3. **`ObjectStorage` + `personal-finance-dashboard`** (Proof step 2), then
   the sharing proof (Proof step 3) — now exercising the full
   `forEach`-generated `S3Identity`/`S3Credentials`/`S3Policy`/
   `S3PolicyBinding` set per attachment.
4. **Schema evolution proof** (Proof step 4) — additive and breaking.
5. **D16** (§8) — only once D15 itself is proven working end-to-end.
   Debugging a novel composition mechanism and a novel CI-registration
   mechanism simultaneously is avoidable risk; D16 doesn't depend on D15
   working correctly, so there's no forcing reason to interleave them.

## Proof — two migrations, scoped honestly

1. **`fastapi-echo`** — migrate to one `Database` + one `Application`
   instance. Infra render-equivalence: the rendered `Cluster`/`Deployment`/
   `Service`/`Ingress` match what's live today, *except* the one named,
   deliberate change — `DATABASE_URL` → `DATABASE_URL_MAIN` — which needs a
   one-line change in `fastapi-echo`'s own settings code. Document this as
   the first real evidence of "what does adopting the platform cost an
   app," not hide it inside a broader "zero changes" claim. `kubectl cnpg
   psql fastapi-echo-db` should work immediately; this migration also fixes
   the currently-live monitoring gap (§7) for the first time.
2. **`personal-finance-dashboard`** — migrate `Application`/Deployment
   plumbing, add one `ObjectStorage` instance + an `objectStorage` entry.
   Scope stops at the platform boundary: `S3Identity`/`S3Credentials`
   provisioned, bucket reachable, credentials verified with `mc`/`aws s3`
   from a debug pod. The app's own S3-adapter code and its hostPath→bucket
   data migration are explicit follow-up work in that repo — not this PoC.
   A single-node `Seaweed` cluster is still one disk on this one machine;
   this step removes the hostPath-specific coupling, it does not by itself
   deliver off-host resilience (that needs SeaweedFS's own remote-tier or
   backup story, separate follow-up).
3. **Sharing proof — object storage only** (Postgres sharing is descoped,
   §3). Add a second, even-throwaway `Application` whose `objectStorage`
   list references the *same* `ObjectStorage` instance created in step 2
   (no second `ObjectStorage` CR — per §4's corrected sharing flow) and
   confirm it gets its own `S3Identity`/`S3Credentials`/prefix-scoped
   policy, distinct from the first consumer's.
4. **Schema-evolution proof, additive and breaking** (§5's "Schema still
   needs fields" bullet). After step 2 adds `securityContext`/persistence
   to the `Application` RGD: confirm `fastapi-echo`'s already-existing
   instance (step 1) survives the revision untouched — still reconciles,
   still `ready: true`, no manual intervention. Separately, against a
   throwaway instance, deliberately make a breaking schema change
   (retype/require/rename an existing field) and confirm it fails
   validation loudly rather than silently corrupting a running instance —
   the negative case matters as much as the positive one.

## Files to add/change

- `infrastructure/kro/` — namespace, HelmRepository (oci), HelmRelease,
  kustomization
- `infrastructure/seaweedfs/` — namespace, HelmRepository, HelmRelease,
  `seaweed-cluster.yaml` (pinned image, `spec.s3` block),
  `resourcereferencegrant.yaml` (all 5 kinds), kustomization
- `infrastructure/platform-api/` — three RGDs (`Database` renders
  `Cluster`+`PodMonitor`; `ObjectStorage` renders `Bucket` with
  `spec.name`/`adoptExisting` set; `Application`'s `databases`/
  `objectStorage` are resolved per §5.1 — a collection `externalRef` per
  attachment type plus a separate `forEach` doing CEL-based matching, not
  a single combined resource template), kustomization
- `infrastructure/kustomization.yaml` — add the three new directories
- `infrastructure/sources/` — HelmRepository entries for kro (oci) and
  seaweedfs-operator
- `infrastructure/observability/dashboards/` — `cloudnativepg.json` (ID
  `20417`, confirmed) + a SeaweedFS dashboard (ID TBD at implementation
  time), same ConfigMap mechanism as `node-exporter-full.json`
- `infrastructure/seaweedfs/seaweed-cluster.yaml` — set per-component
  `metricsPort` on `master`/`volume`/`filer`/`s3` (confirmed as fields on
  the `Seaweed` CR itself, not Helm chart values); add hand-managed
  `PodMonitor`s for whichever components don't auto-provision one (verify
  per component — only `s3`/`admin` are documented to auto-provision)
- `ansible/roles/cli_tools/vars/main.yml` — add `kubectl-cnpg`
- `AGENT.md` — repo-layout update for the three new `infrastructure/`
  directories
- `fastapi-echo` repo (`deploy/` + app settings code) — one `Database` +
  one `Application` instance, plus the one-line `DATABASE_URL_MAIN` rename;
  **if D16 (§8) lands together with D15**, also add `flux/flux-pointer.yaml`
  + CI registration step (D16), and delete this repo's now-obsolete
  `infrastructure/sources/gitrepository-fastapi-echo.yaml` +
  `infrastructure/fastapi-echo/flux-kustomization.yaml`
- `personal-finance-dashboard` repo (`deploy/`) — same, plus one
  `ObjectStorage` instance (app-code S3 work out of scope, see Proof §2);
  same D16 pointer-migration note applies if built together
- `CONCEPT.md` — v0.5 revision note; decision **D15** covering: the
  PoC-first pivot; kro as the Layer-2 mechanism (and `externalRef`/
  `forEach` as the concrete capabilities that make it work); the
  MinIO-archived/seaweedfs-operator-chosen finding and why; the
  `Database`/`ObjectStorage` sharing asymmetry with the client-cert-auth
  revisit trigger; the `external.secretRef` escape hatch; the
  `platform.homelab/v1alpha1` group/version as a permanent choice; **the
  extensibility rule for future service types — a new kind + a new aliased
  attachment list, never an `engine` enum or a boolean flag on an existing
  type**, since a field silently changing a type's whole meaning is exactly
  the leak D1 exists to prevent; and the observation that the real
  generalization here is "declare an instance, attach by name+alias, get
  isolated auto-minted credentials" — `Application` is only its first
  consumer, `CodingEnvironment` (D1's third type) and batch/CronJob
  workloads are the next likely ones, **not built now**, gated on real
  instances per D1's own spirit surviving inside this pivot.
- `docs/gitops-onboarding-learnings.md` — status update: the pivot, the
  substantive reason ("hand-built MinIO instance" skipped because the
  operator landscape changed, not just a preference), and the two
  migrations as the new evidence base.

## Risks / open items to carry forward, not hide

- kro is `v1alpha1`; `platform.homelab/v1alpha1` group/version is a
  permanent choice once app repos hardcode it — no do-overs without a
  coordinated multi-repo migration.
- `seaweedfs-operator` is younger/smaller than CloudNativePG — this plan
  already caught two doc/reality gaps (deprecated `spec.filer.s3`,
  incomplete grant list) by reading the actual Go source instead of
  trusting prose; keep doing that during implementation.
- **CEL complexity ceiling**: `forEach` over attachments, ARN string
  interpolation for `policyDocument`, alias upper-casing — this is already
  pushing real logic into CEL. Name the limit explicitly: when a template
  needs logic that isn't cleanly expressible in readable CEL, that
  component graduates to a real controller (D1's hand-rolled-operator
  option), rather than letting RGDs slowly become unmaintainable DSL soup.
- Postgres multi-consumer sharing is explicitly out of scope (§3) — don't
  let a future instance quietly bolt on shared-password `DatabaseRole`
  usage without revisiting the decision.
- Dangling references at *deletion* time: a `Database` deleted out from
  under a live `Application` won't retroactively flip `ready` to `false`
  until the next reconcile picks up the now-empty matched collection
  (§5.1) — reconcile-loop latency, not indefinite silence like the
  original concern (which assumed scalar `externalRef`'s wait-for-existence
  semantics; §5.1's collection-based design already makes "refs resolve"
  part of `ready` from the start, resolving the original worry about
  dangling references going undetected — this residual is just normal
  reconcile-interval lag).
- Credential rotation is undefined day-2 DX for either service — rotate +
  `kubectl rollout restart` (no reloader in this cluster) is the honest
  current answer; document it per service rather than discovering it
  mid-incident.
- No `dependsOn` between an app's Flux `Kustomization` and kro's/
  seaweedfs-operator's CRDs — matches this repo's existing implicit-
  ordering pattern; transient reconcile errors on first apply are expected,
  as already happened historically with CNPG.

## Verification

- `flux get helmrelease -A` shows `kro` and `seaweedfs-operator` Ready;
  `kubectl get seaweed -A` shows the cluster Ready, standalone `spec.s3`
  Deployment up, gateway responding on `<cluster-name>-s3:8333`.
- `kubectl get resourcereferencegrant -n seaweedfs` shows one grant naming
  all five kinds (`Bucket`, `S3Identity`, `S3Credentials`, `S3Policy`,
  `S3PolicyBinding`) — not a subset.
- `kubectl get resourcegraphdefinition` shows `Application`, `Database`,
  `ObjectStorage` Ready; `kubectl get crd` shows the three generated
  instance CRDs.
- **Platform footprint check against S10**: sum requests/limits across
  kro, seaweedfs-operator, and the Seaweed master/volume/filer/s3 pods.
- After migrating `fastapi-echo`: rendered `Cluster`/`Deployment`/
  `Service`/`Ingress` match today's live resources except the documented
  `DATABASE_URL_MAIN` rename; `kubectl cnpg psql fastapi-echo-db` works;
  `kubectl get applications -n fastapi-echo` shows `ready: true` and the
  correct URL; `kubectl get podmonitor -n fastapi-echo` shows one targeting
  the cluster, `up` in Prometheus; the CloudNativePG dashboard renders real
  data in Grafana.
- After the `personal-finance-dashboard` object-storage step: `kubectl get
  bucket,s3identity,s3credentials -n personal-finance-dashboard` shows the
  provisioned resources; from a debug pod, `mc`/`aws s3` **succeeds inside
  the app's own key prefix and fails outside it** — not just "a policy
  exists," since a fail-everywhere policy would otherwise pass an
  existence-only check by accident.
- **Sharing proof**: the second `Application` (Proof step 3) does **not**
  create a second `Bucket` CR; its `S3Identity`/`S3Credentials`/policy are
  distinct from the first consumer's, and each identity's credentials fail
  outside its own prefix.
- **Reclaim check, split correctly:** delete an `Application` instance and
  confirm its `S3Identity`/`S3Credentials` (and its `Database`'s `Cluster`)
  are gone — automatic. Separately confirm the `Bucket`'s underlying data
  is *retained* — deliberate, matching `local-path-retain`'s own stated
  philosophy, not a bug.
- **Unresolved-ref check (§5.1)**: point a throwaway `Application`'s
  `databases[].ref` at a nonexistent `Database` name — confirm
  `status.unresolvedDatabaseRefs` lists it and `ready` is `false`, not
  silently `true` off an empty matched collection.
- **Readiness/observability independence (§7)**: confirm `Application
  status.ready: true` and Prometheus actually scraping the app's
  `PodMonitor` (`up == 1`) are checked and can be demonstrated
  independently — e.g. by temporarily breaking scrape config without
  touching the workload, confirming `ready` stays `true` while Prometheus
  shows the target down.
- **`platform.homelab/seaweedfs-access` label as capability, not
  decoration (§2)**: `kubectl label namespace foo
  platform.homelab/seaweedfs-access=true`, confirm `Bucket`/`S3*` refs
  resolve; `kubectl label namespace foo
  platform.homelab/seaweedfs-access-`, confirm a *new* cross-namespace
  reference attempt is rejected by the `ResourceReferenceGrant`.

---

## 8. D16: Zero-touch app registration — CI self-registers directly to the cluster

### Context

Step 5 of the D15 onboarding checklist (above) still required a small,
manual, per-app change to *this* repo — a `GitRepository` + Flux
`Kustomization` pointer (~20 lines) — even though the app's own manifests
already live entirely in the app's own repo. The user's requirement,
stated plainly: **literal zero changes to the homelab repo, ever, per
app** — this repo is infrastructure, not a per-app registry — and
ideally the app repo shouldn't even need to *reference* the homelab
repo's existence.

### Mechanism chosen, and what was ruled out (researched against primary
### sources, not assumed)

- **ArgoCD `ApplicationSet` with an SCM Provider Generator** does true
  org/topic-wide GitHub auto-discovery and materializes `Application` CRs
  directly in-cluster (never git-committed) — confirmed the closest thing
  to a "shipped feature" for this. **Ruled out**: adopting it means
  running ArgoCD as a second/alternative CD tool, a real architectural
  swap that contradicts AGENT.md's "Flux is already bootstrapped"
  foundation and is disproportionate to this specific problem.
- **`gitops-tools/gitopssets-controller`** (actively maintained fork of
  Weaveworks' `gitopssets-controller`, commits as recent as 2026-08-08) is
  a genuine Flux-native equivalent — its generators template out real
  `GitRepository`/`Kustomization` objects and apply them directly
  in-cluster, never via git commit. **Ruled out for now**: it ships
  generators for PRs/lists/git-repos/cluster/image-policy data, but
  **no org/topic-wide GitHub-discovery generator** — replicating that
  would mean hand-composing its generic `apiClient` generator against
  GitHub's search API, standing up a new controller, and managing a
  stored PAT/GitHub App credential. More novel/DIY than this problem
  warrants. **Named as the fallback path** if a future requirement needs
  the app repo to carry *zero* CI changes too (not just zero homelab-repo
  changes) — not built now.
- **Chosen: each app repo's own CI registers itself directly against the
  cluster.** On push, CI joins the tailnet as an ephemeral node
  (`tailscale/github-action`) and `kubectl apply`s its own
  `GitRepository`+`Kustomization` pair straight into the cluster, using a
  bound ServiceAccount token scoped by RBAC. Reuses three primitives
  already proven in this repo or standard in Kubernetes — Tailscale
  (already how every app is exposed, `infrastructure/tailscale-operator/`),
  Kubernetes RBAC, and plain `kubectl apply` — **no new controller, no new
  platform component to run or maintain.**

**Revised before any of this was built (pre-implementation design review,
2026-08-11): the auth mechanism below is GitHub OIDC federation, not a
stored bound-ServiceAccount token.** The original draft (directly below,
in "One-time platform setup" and "Per-app onboarding") named the long-lived
token explicitly as a PoC posture with GitHub OIDC federation as the named
revisit trigger. Since nothing had been built yet, that revisit happens
now rather than being built once and migrated later. What changed, and why:

- **Auth model.** k3s's API server trusts `https://
  token.actions.githubusercontent.com` directly (traditional single-issuer
  `--oidc-*` apiserver flags — GA, no need for the newer structured
  `AuthenticationConfiguration` file; confirmed against this cluster's live
  version, k3s `v1.36.2`/Kubernetes 1.36, well past the 1.30 floor either
  mechanism needs). Each CI run mints its own ID token at request time
  (`permissions: id-token: write`, `actions/core`'s `getIDToken()`) and uses
  it directly as the `kubectl` bearer credential. **No token is stored
  anywhere, in any secret, ever** — it's minted fresh and expires in
  minutes. This directly resolves the risk named below ("long-lived
  bound-token rotation is undefined day-2 DX") by removing the long-lived
  token rather than accepting its rotation cost.
- **Cross-app isolation.** GitHub's OIDC `sub` claim already encodes the
  calling repo (`repo:lestherll/<reponame>:ref:refs/heads/main`) — the
  identity carries its own scope for free. One `ValidatingAdmissionPolicy`
  (CEL-native, built into Kubernetes since 1.30, no extra controller),
  written once as platform setup, enforces that a `gha:`-prefixed caller
  may only mutate a `GitRepository`/`Kustomization` whose name/`spec.url`
  matches the repo name embedded in *its own* `sub` — never another repo's.
  This resolves the "no cross-app RBAC isolation" risk named below, without
  adding a single per-app object to this repo: the policy is one static
  rule that reads the caller's own identity, not a per-repo binding.
- **Delete/offboarding.** The registrar Role gains the `delete` verb
  (safe to grant now, since the same admission policy scopes it to
  "delete your own objects only"), and each app's CI file gains a
  `workflow_dispatch` teardown job reusing the same OIDC+Tailscale steps.
  This resolves the "registrar's RBAC can't clean up even if CI tried" gap
  named below. What it deliberately does **not** add: any automation that
  reacts to a repo simply being deleted/archived on GitHub with no teardown
  run first — that gap stays open, named, and policy-only (run teardown
  before you archive), matching this repo's existing "review discipline,
  not a controller" stance for single-operator gaps (D15 §3's Postgres-
  sharing convention is the precedent).

The rest of this section — "One-time platform setup" through
"Verification" — is written to reflect this revision directly, not left as
the superseded draft; the diffs above are recorded here so the *reasoning*
for the change isn't lost, matching this doc's practice of stating
corrections rather than silently rewriting them (see §5.1's precedent).

**Confirmed safe and feasible (not assumed):**
- Flux's `Kustomization` prune is scoped strictly to that Kustomization's
  own applied inventory (confirmed against `fluxcd.io/flux/components/
  kustomize/kustomizations/`) — objects created by `kubectl apply` from
  outside a Kustomization's configured git source are structurally
  invisible to it and never pruned. The existing root `infrastructure`
  Kustomization (`clusters/homelab/infrastructure.yaml`) will never see or
  touch app-registered objects.
- `ansible/inventory/hosts.ini` already sets `tailscale_ip` (100.121.11.84)
  as k3s's `tls-san` — the API server is **already** reachable over the
  tailnet. No k3s/networking change needed for this design.
- `infrastructure/sources/gitrepository-fastapi-echo.yaml` and
  `infrastructure/fastapi-echo/flux-kustomization.yaml` (read in full)
  confirm both existing per-app pointer objects live in the `flux-system`
  namespace — that's the namespace CI needs scoped RBAC against.

### One-time platform setup (in this repo — a single cost, not per-app;
### same shape as D15 §1's kro/seaweedfs platform setup)

1. **k3s API server trusts GitHub's OIDC issuer** (`ansible/roles/
   k3s_server/templates/config.yaml.j2`, added to the existing
   `kube-apiserver-arg` list):
   ```yaml
   kube-apiserver-arg:
     - "oidc-issuer-url=https://token.actions.githubusercontent.com"
     - "oidc-client-id=<chosen audience string, e.g. the tailnet API URL>"
     - "oidc-username-claim=sub"
     - "oidc-username-prefix=gha:"
     - "oidc-groups-claim=repository_owner"
     - "oidc-groups-prefix=gha:"
   ```
   Traditional single-issuer flags, not the newer structured
   `AuthenticationConfiguration` file — this cluster only ever needs to
   trust one issuer (GitHub's), so the simpler, longer-GA mechanism is the
   right one, not the more general one. `repository_owner` is constant
   (`lestherll`) across every app repo under this account, so the group
   claim gives one stable, reusable RBAC subject without naming any
   individual repo — that's what makes step 2 a one-time cost instead of a
   per-app one.
2. **RBAC** (`infrastructure/ci-registrar/`): one `Role` (namespace
   `flux-system`) scoped to `create`/`patch`/`get`/`list`/`delete` on
   `gitrepositories.source.toolkit.fluxcd.io` and
   `kustomizations.kustomize.toolkit.fluxcd.io`, one `RoleBinding` naming
   the OIDC group `gha:lestherll` as its subject — not a `ServiceAccount`,
   since there's no in-cluster identity to bind to anymore. `delete` is
   safe to include here (not deferred the way the original draft deferred
   it) precisely because step 3's admission policy, not this Role, is what
   actually scopes each caller to its own objects.
3. **`ValidatingAdmissionPolicy` for per-repo isolation**
   (`infrastructure/ci-registrar/`): one policy + binding, matched to
   `CREATE`/`UPDATE`/`DELETE` on the same two Flux kinds, enforcing (in
   CEL) that `request.userInfo.username` — which *is* the caller's
   `sub`, e.g. `gha:repo:lestherll/fastapi-echo:ref:refs/heads/main` —
   contains the exact repo-name segment matching the target object's name
   (or `spec.url`). **Exact segment match, not substring `contains()`** —
   named explicitly because a naive substring check would let
   `fastapi-echo-evil` pass a check against `fastapi-echo`; the CEL must
   split on `/` and `:` and compare the isolated segment, not do a raw
   `contains`. This is the load-bearing security boundary for isolation
   now (RBAC no longer is), so it gets the same "spike it in isolation
   first" treatment the "Implementation sequencing" section below already
   applies to D15's riskiest mechanism — test matrix: same-repo create/
   patch/delete succeeds; a second throwaway repo identity attempting to
   touch the first repo's objects is denied; a crafted repo name that's a
   superstring/substring of another (the `fastapi-echo`/`fastapi-echo-evil`
   case above) is denied in both directions.
4. **Tailscale**: unchanged from the original draft — a new ACL tag
   `tag:ci` (admin-console-managed — this repo has no ACL-as-code file,
   matching existing practice for `tag:k8s-operator`) scoped to reach only
   the k3s host's `:6443`, not the tailnet at large; a new OAuth client
   that auto-tags ephemeral devices as `tag:ci`, generated once in the
   console. Client id/secret distributed into each app repo's secrets.
   Still needed regardless of the auth-model change above: the API server
   is only reachable over the tailnet, and OIDC federation changes *who
   the caller proves to be*, not *how the caller reaches the network*.

### Per-app onboarding (entirely app-repo-side — replaces old step 5;
### **this repo is never touched**)

1. Add `flux/flux-pointer.yaml` to the app's own repo, **at repo root —
   deliberately outside `./deploy`** (see "Interaction with D15" below for
   why this placement matters, not just a naming choice) — the
   `GitRepository`+`Kustomization` pair, same shape as today's
   `infrastructure/sources/gitrepository-fastapi-echo.yaml` +
   `infrastructure/fastapi-echo/flux-kustomization.yaml`, just relocated.
   The `Kustomization`'s own `spec.path` still points at `./deploy`,
   unchanged.
2. Add 4 GitHub Actions secrets to the app repo (one-time, GitHub UI, not
   code): `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_CLIENT_SECRET`, `KUBE_CA_CERT`,
   `KUBE_SERVER` (`https://100.121.11.84:6443`). **`KUBE_TOKEN` is gone** —
   the original draft's fifth secret, replaced by a per-run OIDC token that
   GitHub mints and CI requests live, never stored.
3. Grant the workflow `permissions: id-token: write` and add two steps to
   the app's existing build workflow: `tailscale/github-action` (join as
   ephemeral `tag:ci` node) → request an OIDC ID token via
   `actions/core`'s `getIDToken(<audience matching oidc-client-id above>)`
   and `kubectl apply -f flux/flux-pointer.yaml --token=<that token>
   --server=$KUBE_SERVER --certificate-authority=$KUBE_CA_CERT`.
   Idempotent — safe to run on every push, only strictly needs to succeed
   once.
4. From here, Flux's own reconciliation takes over exactly as it does for
   every app today, independent of CI — unaffected by D16.
5. **Offboarding**: a separate `workflow_dispatch`-triggered job in the
   same CI file (e.g. `flux-teardown`), reusing steps 3's Tailscale+OIDC
   setup, running `kubectl delete gitrepository,kustomization <name> -n
   flux-system`. Manually triggered by the operator before archiving or
   deleting the app repo — not automatic, see Risks below for why.

### Interaction with D15 (§1–§7 above) — checked for conflicts, one found and fixed

- **No conflict with the composition mechanism.** D16 only changes who
  creates the app's `GitRepository`/`Kustomization` and where they're
  declared — it doesn't touch what D15 designed. The kro `Database`/
  `ObjectStorage`/`Application` instances still live under `./deploy` and
  are still applied by that same `Kustomization`, exactly per D15. No
  overlap with `infrastructure/platform-api/`, the SeaweedFS
  `ResourceReferenceGrant`, or namespace labeling.
- **One real conflict, now fixed by placement:** the app's
  `Kustomization` has `spec.path: ./deploy`, `prune: true`. Had the
  pointer objects lived *inside* `./deploy` (as first drafted), the
  `Kustomization` would end up managing — and on prune, capable of
  deleting — its own registration: a self-referential loop where renaming
  or removing the pointer file silently halts all future reconciliation
  for that app. Resolved by keeping `flux/flux-pointer.yaml` outside the
  path the Kustomization reconciles, applied only by CI, never by Flux's
  own reconcile of `./deploy` (see step 1 above).
- **Proof-section migration nuance, not a conflict:** D15's Proof section
  migrates `fastapi-echo`/`personal-finance-dashboard` assuming the *old*
  homelab-repo pointer. Combining both decisions means each migration also
  does a one-time cleanup: delete
  `infrastructure/sources/gitrepository-fastapi-echo.yaml` and
  `infrastructure/fastapi-echo/flux-kustomization.yaml` (and the
  `personal-finance-dashboard` equivalents) from this repo once that app's
  CI takes over registration. **Precise claim**: D16 achieves *zero
  per-app registration changes to the homelab repository after D16
  adoption* — not "zero changes ever." Migrating the two *existing* apps
  onto it still costs one deletion commit apiece, here, exactly once; keep
  the wording precise so future docs don't accidentally claim the whole
  platform has no git-based registration state.
- **Sequencing:** D16 references D15's onboarding checklist directly, so
  it should land after or alongside D15, not before — consistent with
  D15's own note about sequencing after D14.

### Risks / open items (named explicitly, matching this plan's existing tone)

- **Breaks full git-reconstructibility for this one class of object.** A
  full cluster rebuild from git (Ansible converge + Flux bootstrap) would
  NOT recreate app `GitRepository`/`Kustomization` objects — each app's CI
  needs manual re-triggering (`workflow_dispatch`) post-rebuild. A
  deliberate, narrow carve-out from AGENT.md's "declarative source of
  truth" framing — name it in CONCEPT.md's D16 entry and a
  disaster-recovery runbook note, don't let it be discovered mid-incident.
- **Cross-app isolation now depends on the `ValidatingAdmissionPolicy`'s
  CEL being correct, not on RBAC.** This is a real shift in *where* the
  security boundary lives (RBAC's `Role` is now deliberately broad —
  scoped to the whole `gha:lestherll` group — and the policy is what
  narrows it per-repo), not a removal of the boundary. If the CEL has a
  bug (e.g. a substring match instead of exact-segment match, per the
  `fastapi-echo`/`fastapi-echo-evil` case named above), the practical
  effect is identical to the original draft's accepted "no isolation"
  risk — so the test matrix named in "One-time platform setup" step 3
  isn't optional polish, it's what makes the isolation claim true.
  **Revisit trigger, updated:** unchanged in spirit from the original
  draft — per-repo `resourceNames`-scoped RBAC becomes worth the extra
  per-app wiring the day a second real trust boundary exists (e.g.
  multiple humans, not just multiple repos, needing isolation from each
  other) and CEL-policy enforcement alone stops being sufficient.
- **Single-issuer constraint.** The traditional `--oidc-*` apiserver flags
  trust exactly one issuer/one client-id cluster-wide — fine here, since
  GitHub Actions is the only OIDC issuer this cluster will ever need to
  trust, but worth naming as a permanent shape: a second issuer (a
  different CI provider, a human SSO provider) would require migrating to
  the structured `AuthenticationConfiguration` file mechanism instead,
  real work, not assumed free.
- **Secret sprawl moved, not eliminated — now 4, not 5.** Each app repo
  still carries `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_CLIENT_SECRET`/
  `KUBE_CA_CERT`/`KUBE_SERVER`, set once at onboarding via the GitHub UI.
  "Zero changes to the homelab repo" is real and achieved — it is not
  "zero onboarding effort"; the effort relocated to the app repo/GitHub UI
  side, which was the actual ask. `KUBE_TOKEN` — the one genuinely
  sensitive, rotation-bearing secret of the original five — is gone.
- **Orphaned registrations on app deletion — now has a working manual
  path, but no automatic one.** The registrar Role now includes `delete`
  (scoped per-repo by the admission policy), and each app's CI carries a
  `workflow_dispatch` teardown job (per-app onboarding step 5), so
  cleanup is no longer blocked the way the original draft found it to be.
  What's still true: nothing reacts automatically to a GitHub repo being
  deleted/archived without that job having been run first — the pointer
  objects keep reconciling (harmlessly — `GitRepository` just fails to
  fetch) against a repo that may no longer exist. **Decision unchanged
  from the original draft: handle this as a documented manual policy** —
  run teardown before archiving, same "review discipline, not a
  controller" reasoning as D15 §3's Postgres-sharing convention. Building
  reactive (webhook- or poll-driven) cleanup is real, avoidable complexity
  for a single-operator repo — not built now.
- **`tag:ci`'s Tailscale ACL scope is a real security boundary** — must
  restrict to the k3s host's `:6443` specifically, not tailnet-wide
  access; verify with `tailscale status`/an ACL test during
  implementation, don't assume the console config is correct.
- **Breaks full git-reconstructibility for this one class of object.** A
  full cluster rebuild from git (Ansible converge + Flux bootstrap) would
  NOT recreate app `GitRepository`/`Kustomization` objects — each app's CI
  needs manual re-triggering (`workflow_dispatch`) post-rebuild. A
  deliberate, narrow carve-out from AGENT.md's "declarative source of
  truth" framing — name it in CONCEPT.md's D16 entry and a
  disaster-recovery runbook note, don't let it be discovered mid-incident.

### Files to add/change (this repo, one-time only)

- `ansible/roles/k3s_server/templates/config.yaml.j2` — add the
  `kube-apiserver-arg` OIDC flags (issuer, client-id, username/groups
  claim+prefix)
- `infrastructure/ci-registrar/` — `Role`, `RoleBinding` (namespace
  `flux-system`, subject is the OIDC group `gha:lestherll`, not a
  `ServiceAccount`), `ValidatingAdmissionPolicy` + binding (per-repo
  isolation), kustomization
- `infrastructure/kustomization.yaml` — add `ci-registrar`
- `CONCEPT.md` — D16 entry: the CI-self-registration mechanism chosen over
  ArgoCD `ApplicationSet` and `gitopssets-controller` (and why); GitHub
  OIDC federation as the auth model (superseding the original bound-token
  draft before it was ever built); the admission-policy isolation
  mechanism; the declarative-source-of-truth carve-out named explicitly
- `docs/gitops-onboarding-learnings.md` — update the checklist: step 5
  ("small pointer in homelab repo") replaced with "app repo:
  `flux/flux-pointer.yaml` + CI step (OIDC + Tailscale) + 4 GitHub
  secrets + a teardown job, homelab repo untouched"
- **Manual, outside version control** (named explicitly, not files): a
  Tailscale admin-console ACL grant for `tag:ci` + a scoped OAuth client.
  No token to mint — this is the one line the original draft had here
  that's gone entirely, not replaced.

### Verification

- `kubectl auth can-i create gitrepositories.source.toolkit.fluxcd.io -n
  flux-system --as=gha:repo:lestherll/fastapi-echo:ref:refs/heads/main
  --as-group=gha:lestherll` → yes (RBAC layer only — the admission policy
  is a separate check, see below); same check against a namespace outside
  `flux-system`, or a non-Flux resource type → no.
- **Isolation proof, both directions (new — the load-bearing check for
  this revision):** from two throwaway repo identities (`--as` impersonating
  two different `sub` values), confirm identity A can create/patch/delete a
  `GitRepository` named for repo A, is **denied** attempting the same
  against repo B's object, and the reverse. Include the named
  substring-collision case explicitly: an object named `fastapi-echo`
  and an identity for `fastapi-echo-evil` (or vice versa) must be denied,
  not pass on a loose match.
- A test app repo's CI run succeeds end-to-end with **zero commits to the
  homelab repo** and **zero stored Kubernetes secrets in the app repo**:
  `git log` here shows nothing new; `kubectl get
  gitrepository,kustomization -n flux-system` shows the new app's objects;
  the app's own `Kustomization` reconciles successfully; the app repo's
  GitHub Actions secrets contain no `KUBE_TOKEN`-equivalent value.
- The teardown `workflow_dispatch` job successfully deletes a throwaway
  app's `GitRepository`/`Kustomization`; re-running it against
  already-deleted objects is a no-op, not an error.
- Tailscale admin console / `tailscale status` confirms the CI's ephemeral
  node joined tagged `tag:ci`, and that it can reach `:6443` but nothing
  else on the tailnet.
- Disaster-recovery drill (can be deferred, but name it as a real test to
  eventually run): after a full Flux re-bootstrap, confirm app objects are
  indeed gone until CI is re-triggered — proves the tradeoff is
  understood, not just asserted.

---

## Implementation log

Appended as the plan is executed, so the eventual `CONCEPT.md` D15/D16
entries record what actually happened rather than what was intended.
Corrections to the design above are stated here rather than edited
silently into it.

### PR #16 — kro operator (`infrastructure/kro/`)

kro `0.9.3` installed via Flux. Chart is OCI-only
(`oci://registry.k8s.io/kro/charts/kro`), so this introduced the repo's
first `type: oci` HelmRepository. `interval` omitted deliberately — Flux
does not poll OCI repositories.

**Design addition not in the plan above: `rbac.mode: aggregation`.** The
chart's default is `unrestricted`, which grants kro cluster-wide access to
every resource in the cluster. That makes CONCEPT.md §3.2's "privileges
enumerable from a document, not by experiment" unsatisfiable by
construction, so aggregation was chosen instead. Inspected via `helm
template`, kro's base role (`kro:controller:static`) covers only:
`kro.run/resourcegraphdefinitions`, `internal.kro.run/graphrevisions`,
`apiextensions.k8s.io/customresourcedefinitions`, core `configmaps`,
`coordination.k8s.io/leases`, and `events`. Everything an RGD renders —
including **the generated instance CRDs themselves** (`platform.homelab`
group) — must be granted through a ClusterRole labelled
`rbac.kro.run/aggregate-to-controller: "true"`.

That grant file (`infrastructure/platform-api/rbac-kro-aggregate.yaml`) is
therefore load-bearing, not incidental: adding a kind to an RGD without
adding it there fails at reconcile time with a permission error. Accepted
cost — the alternative is a principal whose privileges can only be
discovered by experiment.

### Corrections to §5.1, from kro v0.9.3's in-repo documentation

The plan flagged the empty-selector behaviour as the single highest-risk
unknown, on the basis that "kro's docs describe selector syntax but don't
show an empty-selector example explicitly." **That was wrong — it is
documented.** `website/docs/docs/concepts/rgd/02-resource-definitions/
05-external-references.md` in the `v0.9.3` tag has an explicit "Empty
Selectors" subsection:

> An empty selector matches **all** resources of the given kind across all
> namespaces (or in a specific namespace if `namespace` is set).

with a worked `selector: {}` example. The risk assessment above stands as
written for the *composition* (the two-entry split still has no end-to-end
worked example upstream — `test/e2e/chainsaw/check-external-references/`
and `test/upgrade/fixtures/foreach-*/` exercise the two features
separately, never together), but the specific empty-selector question is
answered by primary source and only needs empirical confirmation, not
discovery.

**A genuine hazard the plan missed, from the same page:**

> If namespace is omitted on a collection ref, kro lists resources across
> all namespaces.

So `externalRef.metadata.namespace` is not an optional tidiness detail on
the collection refs — omitting it would make every `Application` see every
`Database` and `ObjectStorage` in the entire cluster, and a `ref` naming
another app's database would resolve successfully. It must be set
explicitly to `${schema.metadata.namespace}`. Added to the spike as a
dedicated cross-namespace leak case (a `Thing` in a second namespace that
must *not* resolve).

Mutual exclusion of `forEach` and `externalRef` is confirmed verbatim in
`04-collections.md` under "Constraints & Gotchas", as the plan states.

Two smaller confirmations for the RGD schemas: validation markers are
`required=true`, `default=`, `enum="a,b"`, `pattern="regex"`,
`minimum=`/`maximum=`, `description=`; and `schema.group` defaults to
`kro.run` if omitted, so `group: platform.homelab` must be set explicitly
on all three RGDs.

### Spike results (LES-56) — run against kro v0.9.3 on the live cluster

Throwaway `Thing` (resource API) + `Consumer` (attachment API) RGDs in
`spike-kro`, plus a second namespace `spike-kro-other` for the leak check.
Torn down afterwards.

**The mechanism works as designed.** Both RGDs reached `Active`/`Ready`,
and the `Consumer` RGD's reported topological order —
`["thingsInNs","attachmentConfigs"]` — confirms kro builds a real
dependency edge from the collection `externalRef` to the `forEach` entry
that CEL-matches against it. The two-entry split is not a workaround that
merely passes validation; the graph understands it.

| Case | Result |
|---|---|
| 0 attachments | reconciles, zero children, `allRefsResolved: true` (vacuous) |
| 1 attachment | one ConfigMap, `matchCount: 1` |
| 2 attachments | two ConfigMaps, `renderedConfigNames: c-two-main,c-two-read-replica` |
| empty `selector: {}` | selects every in-namespace `Thing` — `thingsVisible: 2` |
| namespace scoping | `gamma` in `spike-kro-other` **not** visible; `thingsVisible` stayed 2 |
| typo'd `ref` | `unresolvedRefs: ["nonexistent"]`, `allRefsResolved: false` |
| cross-namespace `ref` | `unresolvedRefs: ["gamma"]` — the leak check passes |
| delete a referenced `Thing` while live | reactive: `unresolvedRefs: ["alpha"]`, `thingsVisible: 1`, no manual reconcile |
| shrink the list 2 → 1 | `c-two-read-replica` pruned automatically |
| alias `Read_Replica` | rejected at apply time by the `pattern` marker |
| omit required `as` | rejected at apply time |
| `as.upperAscii().replace('-','_')` | `read-replica` → `THING_URL_READ_REPLICA` |
| read matched CR's **status** field | `matchedPayload: alpha-payload` — the `ObjectStorage.status.bucketName` analogue works |

kro's collection labels (`kro.run/node-id`, `kro.run/collection-index`,
`kro.run/collection-size`) land on each rendered child, which makes
`kubectl get cm -l kro.run/node-id=attachmentConfigs` a usable debugging
handle.

#### Finding 1 — `status.ready` is a trap, and §5.1's status contract is wrong as written

kro publishes its own `Ready` **condition**, and the generated CRD's
default printer columns are `State` / `Ready` / `Age`, where `Ready` reads
`.status.conditions[?(@.type=="Ready")].status`. That condition is **`True`
whenever kro successfully rendered the graph** — it is emphatically not a
statement about whether attachment refs resolved. Both the typo'd-ref and
cross-namespace consumers showed `Ready: True` while their
`unresolvedRefs` was non-empty.

A custom `status.ready` field *is* accepted and coexists with the
condition, but it does not replace it: an instance with
`status.ready: false` still printed `READY True` under `kubectl get`.

So §5.1's claim — *"`kubectl get applications -n <ns>` shows readiness, the
live URL, and why it isn't ready, directly"* — is **false as designed**.
Two corrections for the real RGDs:

1. **Do not name the custom field `ready`.** It reads as authoritative
   next to kro's own `Ready` and is silently shadowed in every default
   table view. Name it for what it actually asserts, e.g.
   `attachmentsResolved`.
2. **Set `spec.schema.additionalPrinterColumns` explicitly**, surfacing
   the custom field. Verified working: a fresh CRD with a `Resolved`
   column printed `NAME / RESOLVED` driven by `.status.ready`. Note the
   field's own documented behaviour — *"If set, no default printer columns
   will be added"* — so kro's `State`/`Ready`/`Age` must be re-declared
   explicitly if they are still wanted.

#### Finding 2 — printer columns are create-time only, and the CRD outlives the RGD

The chart default `config.allowCRDDeletion: false` means **deleting a
ResourceGraphDefinition does not delete the CRD it generated.** Re-creating
the RGD *adopts* the existing CRD. Confirmed by timestamps: the rebuilt
RGD was 87 seconds younger than the CRD it took over.

On an adopted CRD, `additionalPrinterColumns` changes are **silently
ignored** — the RGD went to revision 2, reported `Active`, and the CRD kept
kro's three default columns. They only applied after the CRD was deleted
outright and rebuilt from scratch.

Ordinary schema changes behave differently and correctly: adding
`newlyAddedField` to `spec` and `echo` to `status` propagated to the
adopted CRD immediately, with the default value present and the new status
expression evaluating. **So additive schema evolution is cheap, as the plan
predicts — but printer columns are not part of that guarantee.**

Operational consequence, and it is sharp: fixing printer columns later
requires deleting the CRD, which deletes **every instance of that type in
the cluster** — every `Application`, or every `Database`, and with it the
CNPG `Cluster` it owns. **Get `additionalPrinterColumns` right in PR-2, on
the first create.** This belongs in D15 as a named one-way door alongside
the group/version choice.

#### Finding 3 — unresolved attachments still render their children

An attachment whose `ref` matched nothing still produced its ConfigMap,
with `matchCount: "0"` and an empty payload. Translated to the real
`Application`: a typo'd `databases[].ref` will still render the Deployment,
with `DATABASE_URL_MAIN` pointing at a `secretKeyRef` for a Secret that
does not exist — so the pod fails with `CreateContainerConfigError` rather
than the render being blocked.

That is acceptable (it fails loudly at the pod, and `unresolvedRefs`
explains why), but it means "the instance reconciled" and "the workload can
start" are separate questions. It reinforces Finding 1: the resolution
status has to be surfaced in the printed table, because the condition kro
prints will say `True` the whole time.

#### Finding 4 — deleting an RGD strands its instances (found during teardown)

Tearing the spike down in the obvious order — `kubectl delete rgd`, then
`kubectl delete crd`, then `kubectl delete ns` — **hung**. Deleting the
RGD removes the controller for its generated kind, but every existing
instance still carries `kro.run/finalizer`. With no controller left to
clear it, the instances are undeletable, so the CRD delete blocks on them
and the namespace delete blocks on the CRD. Recovery needed a manual
`kubectl patch ... --type=merge -p '{"metadata":{"finalizers":null}}'`
across every orphaned instance.

Correct teardown order is therefore **instances → RGD → CRD**, never
RGD-first. This compounds Finding 2: because `config.allowCRDDeletion:
false` leaves the CRD behind anyway, an RGD-first deletion leaves both a
stranded CRD *and* uncollectable instances.

Worth carrying into D15's operational notes, and worth a line in the
offboarding procedure D16 already needs — "remove an app" must delete the
`Application`/`Database` instances before anything that owns their type.

#### Verdict

The composition in §5.1 is **confirmed working** and the plan proceeds to
PR-2 unchanged in mechanism. The corrections it takes with it are: name
the resolution status field something other than `ready` (Finding 1), ship
`additionalPrinterColumns` correct on the first CRD create because they
cannot be revised without destroying every instance (Finding 2), expect
unresolved attachments to render broken children rather than block
(Finding 3), and document instance-before-RGD teardown ordering
(Finding 4).

None of these threaten the design. Findings 1 and 2 would each have been
discovered late and expensively — Finding 2 in particular only shows up
when you try to fix a cosmetic detail on a type that already has real
instances, which is exactly when deleting the CRD is unacceptable. The
spike paid for itself on that one alone.

### PR #17 — `Database` + `Application` RGDs (`infrastructure/platform-api/`)

Built and validated against the live cluster before the PR was opened: RGDs
applied by hand, real instances created in a throwaway `platform-api-test`
namespace, verified, then torn down (instances → RGD → CRD, per Finding 4)
so Flux creates them from git rather than adopting hand-applied objects.

**Render-equivalence is exact.** Diffing the rendered
Deployment/Service/Ingress against the live hand-written `fastapi-echo`
objects produced exactly one substantive difference — `DATABASE_URL` →
`DATABASE_URL_MAIN` — plus an allocated `clusterIP` on the Service. The
Ingress was byte-identical. The plan's Proof step 1 render-equivalence
claim is therefore already evidenced, before the app repo is touched.

**The monitoring gap is closed and measured**, not merely wired:
`up == 1` and `cnpg_collector_up == 1` against the probe instance. This is
the first Postgres ever scraped in this cluster.

Design changes made during implementation, beyond the spike findings:

- **`unresolvedRefs`, not `unresolvedDatabaseRefs`.** Forced by Finding 2 —
  printer columns can't be added later, so the column has to exist now with
  a name that still fits once `objectStorage` attachments land in PR-4.
  §5.1's two-separate-lists design would have needed a second column that
  could never be added without destroying every `Application`. One combined
  list, one column, extended by CEL in PR-4.
- **The `external.secretRef` escape hatch flattened to
  `externalSecretName`/`externalSecretKey`** on the attachment type rather
  than a nested `external` object. Nested optional objects made the CEL
  (`has(d.external) ? ... : ...`) harder to read for no gain, and the
  flattened form keeps the whole env-var expression to one readable `.map()`
  — relevant to the CEL complexity ceiling named in the risks.
- **`readyWhen: ${cluster.status.readyInstances > 0}`** on the `Database`'s
  Cluster, so kro's own `Ready` condition means "Postgres is serving" rather
  than "the object was created". Costs nothing and makes the one condition
  kro *does* publish meaningful for this type.
- **kro secrets access is read-only** in the aggregate ClusterRole. Nothing
  in this design has kro authoring credentials — CNPG and (later)
  `S3Credentials` mint their own — so a read-only grant makes that property
  checkable rather than asserted.

YAML gotcha worth recording: CEL ternaries must be quoted
(`'${x == "a" ? "1Gi" : "5Gi"}'`). The `: ` inside the expression is
otherwise parsed as a YAML mapping and the manifest fails to load, with an
error pointing at the line rather than the cause.

### PR fastapi-echo#2 — Proof step 1, and two costs the plan did not anticipate

The migration itself worked: `deploy/` went from five files to three,
`Database` and `Application` both reconcile `Ready`/`Resolved`, the app runs
on `DATABASE_URL_MAIN`, and the CNPG `PodMonitor` reports `up == 1` — this
app's Postgres is scraped for the first time.

But two things went wrong that belong in the record more than the successes
do, because both will recur on every subsequent migration.

#### The prune guard failed, and the database was rebuilt

The plan correctly identified that removing `cluster-postgres.yaml` would let
Flux prune the live `Cluster` while kro created a fresh one under the same
name. The chosen mitigation was to annotate the live object
`kustomize.toolkit.fluxcd.io/prune: disabled` imperatively before merging.

**That does not work.** Flux's garbage collector evaluates prune-exclusion
from the manifest it last applied, not from the object as it currently exists
in the cluster. The annotation was present and visible on the live `Cluster`,
and the kustomize-controller deleted it anyway:

```
garbage collection completed: Cluster/fastapi-echo/fastapi-echo-db deleted
```

CNPG then bootstrapped a new cluster (`Primary instance (initdb)`) on a new
PVC. The old PV survives as `Released` with `Retain`
(`pvc-9da4a7e4-21be-42ea-a448-29f1c859c031`) — the data is recoverable, but
nothing reattaches it automatically.

Adoption itself is not the problem and works exactly as hoped. Verified
beforehand in a throwaway namespace: a hand-written `Cluster` with a marker
row, then a `Database` of the same name created over it — the `Database` went
`Ready`, the row survived, the PVC kept its UID, and kro took ownership via
its applyset labels. **The failure was in keeping Flux's hands off the object
long enough for that adoption to happen.**

**Correct procedure, for the remaining migrations:** the annotation has to be
in the *manifest* and applied by Flux before the manifest is removed — the
two-PR sequence. First PR adds `kustomize.toolkit.fluxcd.io/prune: disabled`
to the existing resource and merges; second PR swaps in the typed instance.
An imperative annotation is not a substitute, and this is the one place in
this migration where the imperative lane genuinely could not stand in for the
declarative one.

#### Recreating a Tailscale Ingress produces noisy — but not fatal — ACME log churn

Initially misdiagnosed as a live HTTPS outage; corrected here rather than
left wrong. Because the `Ingress` was pruned and re-created by kro, the
Tailscale operator tore down and rebuilt the proxy StatefulSet, which
re-registered a fresh ACME account and began re-issuing:

```
cert("fastapi-echo.tailf4742d.ts.net"): registered ACME account.
cert(...): starting SetDNS call for _acme-challenge...
cert(...): acme: WaitOrder: OrderError status "invalid"
```

Ten failed orders inside two minutes read as a real outage from this
machine — `curl` against the hostname timed out completely, not merely
TLS-rejected. But a real client on the tailnet (a phone, never involved in
any of the diagnosis) hit `/healthz` successfully throughout and got a
normal `{"status":"ok"}`. So the app was never actually down; a valid cert
was being served to real traffic the whole time.

**Root cause of the false alarm: `kubectl exec ... tailscale cert
<hostname>` was run by hand to force a fresh issuance for diagnosis.** That
forced synchronous re-issuance appears to hold some kind of per-hostname
lock in the proxy, and ordinary `curl` attempts made while it was in
flight — mine — blocked on that same path and timed out. A plain retry with
no forcing succeeded immediately (`HTTP/2 200`, `TLSv1.3`). The repeated
`OrderError: invalid` lines in the pod's logs are real and still occur on
renewal, but they are background noise around a setup that already works,
not a blocking condition — and the failure mode they cause, if you go
looking, is self-inflicted by exactly the diagnostic command used here.

Implications worth carrying:
- **Do not `exec` a forced `tailscale cert` re-issuance as a diagnostic
  step** when a hostname looks unreachable — it can create the very outage
  symptom (or worsen a real one) that it's being used to investigate. Test
  from an independent real client first.
- "Render-equivalent" is not the same as "no controller-side churn on
  replace". The Ingress the platform renders is byte-identical to the
  hand-written one, and swapping them still triggers a full ACME
  re-issuance cycle on the Tailscale proxy side, purely from object
  identity changing — worth expecting and not worth reacting to with a
  forced re-issuance.
- The underlying `OrderError: invalid` on renewal is real and unexplained;
  worth a quiet follow-up look, but it is not blocking and does not need
  to gate PR-5.

### PR-4 — SeaweedFS + `ObjectStorage` + `Application` schema revision

Full end-to-end validation against a real, freshly-installed `seaweedfs-operator`
0.1.37 and a real `Seaweed` cluster — not just RGD compilation. `ObjectStorage`
and the revised `Application` (rev 2: `objectStorage`, `securityContext`,
`persistence`) both went `Ready: True` on first apply after two CEL fixes
below; a live instance with both attachment types, a `securityContext`, and a
`persistence.hostPath` rendered every field exactly as designed; and the
prefix-isolation proof — the one this whole design rests on — passed cleanly:
writes and reads succeed inside `<app>-<alias>/*`, `AccessDenied` both outside
that prefix and at the bucket root.

#### Correction to §7 — which components auto-provision a ServiceMonitor

Read against the operator's actual controller code
(`internal/controller/*_servicemonitor.go`), not inferred from the CRD
comments alone: **S3 and SFTP** auto-provision a ServiceMonitor when
`metricsPort` is set — not "S3 and Admin" as an earlier draft guessed.

More importantly, **every** auto-provisioned ServiceMonitor (S3 included)
carries only the operator's fixed `app.kubernetes.io/*` labels
(`labelsForS3`/`labelsForMaster`/etc. in the Go source), with no field to add
`release: kube-prometheus-stack`. None of them are ever selected by this
cluster's Prometheus regardless of which components happen to auto-provision
one. Rather than track that inconsistency, `podmonitors.yaml` hand-writes one
PodMonitor per component uniformly — master/volume/filer/s3 — confirmed
against the exact selector labels and container port names
(`master-metrics`/`volume-metrics`/`filer-metrics`/`s3-metrics`) in the
source, same pattern the Database RGD already uses for CNPG.

#### A metrics-port collision caught before it shipped

The first draft picked `s3.metricsPort: 9333`, not realizing that's the
operator's own documented default `MasterHTTPPort`. No actual runtime
conflict (different pods), but confusing enough to invite a misread later.
Moved all four component metrics ports to a plain sequential block
(9410-9413) deliberately distinct from every documented default port.

#### Real CEL findings — two struct-strictness gotchas the object case did not predict

kro's static type checker validates literal map/list expressions in a
resource template against the *real* target Kubernetes struct, not just
against the branches of a ternary. Two consequences, both found by testing
against a live cluster before they could land in a merged RGD:

- A `has(...) ? {...} : null` ternary on an optional object field
  (`securityContext`) fails to compile: `found no matching overload for
  '_?_:_' applied to '(bool, int, null)'` — CEL requires both ternary
  branches to share a type, and `null` isn't unifiable with `int`. Fixed by
  wrapping **both** branches in `dyn(...)`, which resolves the ternary's
  result type to `dyn` and sidesteps the unification. Verified live: an
  instance with no `securityContext` set renders `{}` on the pod (Kubernetes
  treats that identically to the field being absent); one with it set
  renders exactly the three values.
- The same problem recurs for **list** fields (`volumeMounts`, `volumes`),
  which was not predicted — an all-string map literal like `{"name":...,
  "mountPath":...}` infers as `map(string,string)`, and kro still unifies
  that against the real `VolumeMount` struct (which has a `readOnly bool`
  field) even inside a list, so the empty-list `[]` branch doesn't save it.
  Same `dyn(...)`-wrapping fix, applied to the whole ternary rather than
  individual elements.

Neither fix is exotic once found, but both are exactly the kind of thing
that would otherwise surface as a cryptic compile error days later on an
unrelated field, in a PR with no obvious connection to `securityContext` or
`persistence`.

#### `ObjectStorage.metadata.name` length constraint — corrected, not enforced

An earlier draft's comment claimed this was "constrained below." It isn't —
kro v0.9.3's SimpleSchema validation markers (`required`/`pattern`/
`minLength`/etc.) attach to `spec`/`status` fields, and `ObjectStorage.spec`
is intentionally empty, so there is no field to hang a length check on
`metadata.name` itself. Corrected to state plainly that this is an accepted,
documented gap (a namespace+name combination producing an illegal S3 bucket
name fails at `Bucket`-create time with a clear admission error, not at
`kubectl apply` time) rather than claim an enforcement that doesn't exist.

#### A real infrastructure bug, not a design bug: `master.volumeSizeLimitMB`

The first live write to the very first `Bucket` failed with a 500
`InternalError` from the S3 API — not `AccessDenied`, so it didn't even look
like a permissions problem. Root-caused via the master's `/dir/status`
endpoint: `Max: 2, Free: 0`. SeaweedFS assigns volumes per-collection (one
`Bucket` = one collection), the unset `volumeSizeLimitMB` left the build's own
default (visible in its own startup banner as "30GB") in effect, and on this
node's disk that computed to a maximum of only 2 writable volume slots
total — both already claimed by the empty-string default collection at
cluster bootstrap, before any `Bucket` ever existed. Every subsequent bucket
was structurally unable to get a volume.

Fixed by setting `master.volumeSizeLimitMB: 100` explicitly. Confirmed via
the same endpoint: `Max: 604, Free: 602` on the same disk (local-path PVCs
aren't quota-enforced, so SeaweedFS sees the node's actual free space divided
by this value — not the 5Gi `volume.requests.storage`, which is a separate,
non-binding number). Re-ran the full write/read/deny proof after the fix;
all four cases passed.

This would have hit on the very first real migration (`personal-finance-
dashboard`, Proof step 2) with no warning beyond a generic 500 — worth
recording as a reminder that a component's install checklist (`kubectl get
seaweed -A` Ready) proves the control plane is up, not that the data plane
can actually take a write.

#### Two things found only during teardown, neither in the design mechanism itself

- **Testing directly against a live, Flux-managed cluster is unsafe once
  local changes exist that aren't yet merged.** Flux's periodic reconcile of
  `infrastructure` re-applied the `main`-branch (pre-PR-4) `rgd-application.yaml`
  mid-test, and kro correctly rejected it as a breaking-change downgrade
  (`Property objectStorage was removed; Property persistence was removed;
  Property securityContext was removed`) — which is exactly the intended
  behavior, just triggered by an operational mistake rather than a deliberate
  test. It also clobbered the locally-applied `rbac-kro-aggregate.yaml`,
  which stranded an `ObjectStorage` instance mid-deletion with a `Bucket`-forbidden
  RBAC error. Recovered by `flux suspend kustomization infrastructure` (the
  platform's own documented break-glass mechanism, D14) for the remainder of
  the teardown, then `flux resume`. **For any future spike or PR validation
  that takes more than a few minutes, suspend the Kustomization first.**
- This RBAC interruption produced a second orphaned-finalizer case beyond
  Finding 4 from the spike: kro lost track of an instance mid-deletion when
  its authorization was pulled out from under it, not just when its
  controller (RGD) was deleted. Same manual recovery
  (`kubectl patch ... finalizers: null`) applied.

#### Verification run (all against the live cluster, all torn down afterward)

- `flux get helmrelease -A` — not applicable during testing (operator
  installed by hand via `helm install` to iterate faster; uninstalled before
  merge so Flux performs the real, git-tracked install).
- `kubectl get seaweed -A` — Ready; all four components (master/volume/
  filer/s3) `1/1` Running.
- `kubectl get resourcereferencegrant -n seaweedfs` — one grant, five `from`
  entries (`Bucket`/`S3Identity`/`S3Credentials`/`S3Policy`/`S3PolicyBinding`),
  confirmed against the CRD's actual `ReferenceGrantFrom` shape (one `kind`
  per entry — there is no multi-kind list field).
- `kubectl get resourcegraphdefinition` — `Application` (rev 2), `Database`,
  `ObjectStorage` all `Ready: True` before Flux's clobber (see above for the
  self-resolving post-merge state).
- Render check: `S3Credentials`' generated Secret has non-empty `accessKey`/
  `secretKey` under the pinned field names — confirmed, not assumed.
- **Isolation proof** (the one Proof step 2 and Verification actually ask
  for): from a debug pod using the minted credentials — write+read inside
  `<app>-<alias>/*` succeed; write outside that prefix and at the bucket root
  both fail `AccessDenied`.
- Reclaim check (partial — full sharing/second-consumer proof deferred to
  PR-5 with a real second app): deleting the `ObjectStorage` instance leaves
  the underlying `Bucket`'s reclaim policy at its `Retain` default,
  unexercised in this PR since the throwaway bucket was deleted for real as
  test cleanup rather than left to prove retention.

### PR #19 — the merge itself broke `infrastructure/`, fixed by splitting the Kustomization

Not caught during PR-4's own validation because that validation ran against
a cluster that already had the seaweedfs-operator CRDs installed (from
earlier manual testing) — the failure mode only appears on a genuinely cold
apply, which is exactly what the real merge to `main` produced. Recorded
here because it's a real, general lesson, not specific to SeaweedFS: **any
raw CRD-dependent manifest placed in the same Kustomization as the
HelmRelease that installs its CRD is a latent whole-tree deadlock**, and it
will not show up in testing unless the CRD is genuinely absent when the test
runs. `infrastructure/postgres/` never had this problem only because its
CRD-dependent object (`fastapi-echo-db`'s `Cluster`) happens to live in a
different repo's Kustomization by construction, not because the pattern was
avoided deliberately.

Fixed by splitting `infrastructure/seaweedfs-runtime/` into its own
top-level Flux Kustomization with `dependsOn: [infrastructure]`. Verified by
reproducing the exact cold-start sequence live (operator and CRDs deleted
entirely, then replayed both Kustomizations in order) rather than trusting
the reasoning alone.

Worth carrying forward: **any future platform-owned component that pairs a
HelmRelease with CRD-dependent raw manifests needs this same split from the
start**, not discovered again the hard way. `infrastructure/kro/` and
`infrastructure/postgres/` don't have this problem (kro's own instance CRDs
are consumed only by kro itself, not by another raw manifest in the same
tree; postgres's CRD-dependent object lives in app repos) — SeaweedFS is the
first component in this repo with a platform-owned CRD-dependent resource
sitting next to its own installer, and won't be the last if a message broker
(see `docs/message-broker-design-notes.md`) or similar follows the same
shape.

### PR — `Application` revision 4: telemetry, and the defaulting trap it exposed

Closes the gap where the type the platform exists to run was the only one
emitting no telemetry: `Database` rendered a `PodMonitor` and SeaweedFS shipped
four `ServiceMonitor`s, while `Application` rendered `Deployment` + `Service` +
`Ingress` and stopped.

What shipped, and the one decision worth arguing about:

- **A `PrometheusRule` on every instance, unconditionally.** Three alerts —
  `ApplicationNotAvailable`, `ApplicationRestartLooping`,
  `ApplicationMemoryNearLimit` — all derived from kube-state-metrics and the
  kubelet, so they work for an app that exposes nothing at all. The memory one
  exists because the platform, not the app author, sets the memory limit (from
  `spec.size`); without it an OOMKill arrives as an unexplained restart of a
  limit nobody chose.
- **A `PodMonitor` only when `metrics.enabled: true`.** Deliberately opt-in,
  against the instinct that a platform should just do it. Scraping an app that
  serves no `/metrics` yields a permanently-failing target that nobody can fix
  from the platform side, and a permanently-red thing in the monitoring UI is
  precisely what teaches an operator to stop reading it. A missing target is
  honest; an expected-to-fail one is corrosive.
- **One dashboard for all apps**, templated on namespace/deployment rather than
  authored per app — a per-app dashboard would be per-app work, which is what
  the typed API exists to delete. Its Delivery row shares its definition of
  health with the alerts above, so the two cannot drift apart.
- `PodMonitor` uses `portNumber`, not a named `port`. Selecting by name would
  have meant naming the container port in the Deployment, and **any** edit to a
  pod template rolls every running instance — an otherwise purely additive
  revision would have restarted every app on the cluster to gain a name nothing
  reads.

#### The real finding: `has(schema.spec.<block>)` cannot gate anything

Revision 4 was written with `includeWhen: ${has(schema.spec.metrics)}`, copying
revision 3's `has(schema.spec.persistence)`. It did not work — the `PodMonitor`
appeared on `fastapi-echo`, which sets no `metrics`. Chasing that revealed the
mechanism, and that **revision 3 had the same bug live and undetected**.

kro emits `"default": {}` on a custom-type field in the generated CRD whenever
**any** of that type's sub-fields carries a default. The API server then
materialises the block on every instance that omits it, so `has()` on the parent
is always true. Both halves confirmed against the live CRD: `securityContext`
(no sub-field defaults) carries no `default: {}` and gates correctly;
`persistence` (three defaults) carried one.

The consequence had been running in production since revision 3: `fastapi-echo`,
which sets no persistence, was holding a bound 1Gi PVC on the `fast` tier and a
phantom `/app/data` mount. Since both tiers are `Retain`, every app deleted in
that state would have left an orphaned PV behind. Nothing failed and nothing
alerted — the failure mode is silent in both directions, which is why it
survived a revision that was itself carefully reviewed.

The fix, and the idiom for any future optional block: **gate on a leaf field
that carries no default, never on the parent.** `persistence.size` lost its
`1Gi` default and became that leaf, which is also the more honest API — a
platform cannot guess how much disk an app needs, and asking for persistence
without saying how much never meant anything. `metrics` has no such natural
leaf, being a pure on/off, so it carries an explicit `enabled: false`.

Verified live end to end, not reasoned about: graph accepted at revision 5; the
phantom PVC deleted and the volume/volumeMount gone from the Deployment;
`metrics.enabled` toggled true and false with the `PodMonitor` appearing and
disappearing; all three alert rules loaded into Prometheus with `health: ok` and
their PromQL — including the `group_left()` memory join — returning real
samples; the dashboard served by Grafana with both template variables
resolving, every Delivery query returning data and the RED queries returning
empty for an app that has not opted in.

Left behind on purpose: one `Released` PV (`pvc-d921aecd…`, empty) from the
phantom claim, and `Alertmanager`'s receiver still `null` (LES-69) — these
alerts are visible in the Prometheus and Alertmanager UIs and are delivered
nowhere until that lands.
