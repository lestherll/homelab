# Self-service typed API: Application, Database, ObjectStorage — why it's shaped this way

D15 (self-service typed platform API) and D16 (zero-touch app registration),
recorded in `CONCEPT.md`. Both are built and live. This page used to be the
full design derivation and PR-by-PR build diary for getting there — research
notes, a spike, corrections found along the way, verification checklists.
That process is finished; what's kept here is the architectural rationale
that still explains the current shape. For the current field reference, see
`docs/platform-api-usage.md`; for D16 (how an app registers itself), see
`docs/zero-touch-app-registration.md`; for the RBAC grant that must extend
whenever a kind is added, see `infrastructure/platform-api/rbac-kro-aggregate.yaml`.
Build-time gotchas worth remembering live in the journal:
`docs/journal/2026-08-10-kro-operational-gotchas.md` and
`docs/journal/2026-08-11-flux-prune-annotation-and-cel-struct-strictness.md`.

## Why kro, and why three types split as they are

**kro** (chosen over Crossplane and a hand-rolled operator) composes
`Database`/`ObjectStorage`/`Application` from a `ResourceGraphDefinition`.
Two of its features are load-bearing: `externalRef` lets an RGD read a
resource it doesn't own (the mechanism for "attach to a `Database`/
`ObjectStorage` instance another app created"), and `forEach` expands one
resource template into N resources driven by a schema list, kept in sync as
the list changes. The two are mutually exclusive on the same resource
template, which is why attachment resolution in the `Application` RGD is
split into a collection `externalRef` (fetches candidates) and a separate
`forEach` (CEL-matches against the fetched collection) rather than one
combined entry.

**Conceptually this is two APIs, not three unrelated types.** `Database` and
`ObjectStorage` are *resource APIs* — "provision this infrastructure,"
unaware of any consumer. `Application`'s `databases`/`objectStorage` lists
are an *attachment API* — "consume this resource with an isolated,
consumer-specific credential." Neither `Database` nor `ObjectStorage` needs
to know `Application` exists, which is what lets a future kind (a coding
environment, a batch/CronJob workload) adopt the same attachment shape later
without changing either resource API.

**The extensibility rule:** a new service
type is a new kind plus a new aliased attachment list, never an `engine` enum
or a boolean flag on an existing type — a field silently changing a type's
whole meaning is exactly the leak the platform API exists to prevent.

**Two permanent, one-way-door choices**, both worth remembering before
touching either: `platform.homelab/v1alpha1` is the group/version every app
repo hardcodes into every instance manifest — it cannot change without a
coordinated migration across every app repo. And a CRD's
`additionalPrinterColumns` can only be set correctly on its first create —
see the kro-gotchas journal entry for why fixing them later means deleting
every instance of that type.

## `Database` — single-consumer by convention, not a limitation of the schema

A `Database` instance renders exactly one CNPG `Cluster` plus one
`PodMonitor`. Its consumer uses CNPG's own bootstrap `<cluster>-app` Secret.
There is no `DatabaseRole` and no multi-consumer story: CNPG's
`DatabaseRole.spec.passwordSecret` requires a pre-existing Secret rather than
generating one, and hand-rolling credential derivation in CEL would be
exactly the kind of novelty this platform avoids. A second `Application`
attaching to the same `Database` would get *identical* credentials to the
first — literal shared access — so **each `Database` instance is 1:1 with
its consumer by convention**, enforced by review discipline rather than a
webhook, matching this repo's single-operator scope.

**Revisit trigger:** multi-consumer Postgres becomes worth building when a
second app actually needs to share an engine. `DatabaseRole`'s
`clientCertificate` option is the leading candidate — the operator
auto-generates and rotates a `<name>-client-cert` Secret, genuinely
zero-touch, unlike a shared password — but it needs `pg_hba` cert-auth
config and app-driver TLS support, real work, correctly deferred.

## `ObjectStorage` — one instance per bucket, uniform scoping for every consumer

Exactly one `ObjectStorage` instance exists per shared bucket, created once
by whichever app needs it first. A second app wanting the *same* bucket does
not create a second `ObjectStorage` instance (declaring one twice would
render two `Bucket` CRs resolving to the same underlying bucket name, which
fails) — it adds an entry to its own `Application`'s `objectStorage` list,
referencing the existing instance by name via `externalRef`.

**Every consumer gets the same `<bucket>/<app-name>/*` prefix scoping,
including the bucket's first and only consumer.** There is no "full scope
for whoever got there first" special case — an `Application` RGD instance
only ever sees its own spec, so it has no reliable way to know whether it's
the first attachment, and a permanent isolation asymmetry with no tightening
trigger would be worse than one uniform rule. This is what makes "credentials
fail outside their own prefix" a true statement for every consumer, not just
some.

## Observability is part of the type, not bolted on per app

Observability is a requirement, not an enhancement — CONCEPT.md's "observable
by default" ground rule. `Database` renders a
`PodMonitor` alongside its `Cluster`. `Application` renders a
`PrometheusRule` unconditionally (three alerts derived from kube-state-metrics
and the kubelet — availability, restart-looping, memory-near-limit, all
computable without the app exposing anything) and a `PodMonitor` only when
`metrics.enabled: true` — deliberately opt-in, because scraping an app that
serves no `/metrics` produces a permanently-red target that nobody can fix
from the platform side, and a permanently-red thing in the monitoring UI is
what teaches an operator to stop reading it. One shared dashboard, templated
on namespace/deployment, serves every `Application` instance rather than a
per-app dashboard — a per-app dashboard would be exactly the per-app toil the
typed API exists to delete.
