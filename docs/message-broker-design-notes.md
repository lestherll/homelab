# Message broker on the platform API — design notes

**Status:** exploratory working notes, committed for reference. Nothing here
is built or decided.
**Written:** 2026-08-09, during review of the D15 PoC plan
(`~/.claude/plans/declarative-scribbling-yeti.md`).
**Question answered:** "what happens when this platform wants a message
queue / broker / Kafka — per-app, or shared across apps?" Recorded so the
future decision is executable rather than re-derived. Nothing here is built
or decided; a broker is deliberately *not* in the D15 PoC scope.

CONCEPT.md already anticipates this twice: C6's "should" lists a message
broker on the same self-service pattern ("the specific list matters less
than the pattern generalising"), and GP6 is literally this scenario ("I add
a few lines to a repo. It's provisioned, credentials are delivered to my
app, it's backed up, and it appears in monitoring").

## Background: the conventions this builds on

From the D15 plan review rounds (the "attachment pattern" these notes
reuse):

- **New data service = new top-level kro kind + a new aliased list field on
  `Application`.** Never an `engine` enum on an existing kind, never a
  boolean. Each kind owns an honest, engine-specific credential contract.
- **Aliased attachments:** `databases: [{ ref: orders-db, as: main }]` →
  `DATABASE_URL_MAIN`. Uniform shape for one-or-many; no singular/list
  split, no implicit defaults (D1: explicable, not magical).
- **Owning vs. attaching:** exactly one instance declares a shared resource
  (renders the container CR); other consumers only reference it by name and
  get their own isolated identity/credentials/policy. No `Bucket`-equivalent
  collisions, no privileged first consumer.
- **Prefix-scoped isolation:** each consumer's policy reaches only its own
  namespace within the shared resource (`<bucket>/<app>/*`).
- **Name-is-the-handle, with global names derived:** anything living in a
  cluster-global flat namespace (buckets, IAM names) is derived as
  `<namespace>-<name>` so the handle stays collision-free and derivable.
- **Additive-only schema evolution** within `platform.homelab/v1alpha1`
  (kro group/version immutable; breaking change = new version).
- **Kind-approval gate:** a kind ships only if a proven operator can mint
  isolated, zero-touch credentials (C6's success test), verified against
  live CRDs (`kubectl explain`), not docs alone.

## 1. Why a broker is the hardest test of the pattern

1. **Sharing is the point, not the option.** Postgres sharing could be
   descoped in the PoC because single-consumer databases are the common
   case. A single-app broker is nearly pointless — messaging exists to
   connect apps (or an app to its own async workers, same machinery). The
   per-app isolation machinery deferred on the Postgres side is the *MVP*
   here. There is no "descoped phase 1" for a broker.
2. **Topology is app-domain config.** A `Database` renders a container
   (schema is the app's business via migrations); a `Bucket` is a container
   (keys are the app's business). But queues/exchanges/bindings/topics live
   *between* infra and app: code-coupled, changing with app releases,
   differing per consumer. Ownership of topology declaration is a new
   design question (§3).
3. **It's an acceptance test the concept doc already wrote.** If the
   attachment pattern can't absorb a broker without new ad-hoc machinery,
   C6's bet ("the pattern generalises") fails.

## 2. How it maps onto the PoC design

**Platform level: the broker cluster is raw infrastructure, not a type.**
A Strimzi `Kafka` CR (or `RabbitmqCluster` CR) lives directly in
`infrastructure/messaging/` — exactly like the `Seaweed` instance in
`infrastructure/seaweedfs/`. Nobody self-services a second Kafka cluster on
one node; making it a kind would be speculative abstraction.

**The self-service unit is the per-app messaging scope.** One new kind
(working name `MessageQueue`): an instance renders *a namespaced slice of
the shared broker* — identity + credentials + scoped permissions. The
SeaweedFS/ObjectStorage machinery translates 1:1:

| `ObjectStorage` (PoC design) | `MessageQueue` (Kafka/Strimzi flavour) |
|---|---|
| shared `Seaweed` cluster (raw infra) | shared `Kafka` cluster (raw infra) |
| `Bucket` (one declaring owner) | topics (app-owned — see §3) |
| `S3Identity` + `S3Credentials` (auto-generated keys) | `KafkaUser` (operator auto-generates SCRAM secret) |
| `S3Policy` scoped to `<bucket>/<app>/*` | `KafkaUser` ACLs, `patternType: PREFIXED`, on topic **and** consumer-group prefixes (native Kafka feature) |
| S3 endpoint injected by RGD | bootstrap servers injected by RGD |
| cross-namespace via `ResourceReferenceGrant` | Strimzi CRs reference clusters name-only → namespace-local, like CNPG (verify) |

**Dedicated vs. shared needs no new machinery** — it's the owning/attaching
asymmetry reused: a private job queue is a `MessageQueue` instance only one
app references; a cross-app event bus is a `MessageQueue` instance (e.g.
named `events`) that several apps attach to, each getting an identity
scoped to its own prefix. Same "exactly one declarer per name" rule.

**DX contract sketch** (follows the aliased-attachment rule):

```yaml
spec:
  queues:
    - { ref: jobs, as: worker }
```

Kafka bends the "one well-known variable" ideal — clients need a small
documented set (`KAFKA_BOOTSTRAP_SERVERS_WORKER`,
`KAFKA_USERNAME_WORKER`, `KAFKA_PASSWORD_WORKER`, security protocol),
whereas AMQP stays single-URL-shaped (`AMQP_URL_WORKER`). Per-kind
contract, documented once, per the extensibility rule.

## 3. The genuinely new decision: who declares topology

Options considered:

- **(a) Platform schema fields** (`queues: [...]` on the attachment) —
  rejected: app-release-coupled detail churning the platform API is the
  leak D1 exists to prevent.
- **(b) Runtime self-declaration by apps** (AMQP cultural default) —
  rejected as *primary*: topology becomes invisible to git; stale queues/
  exchanges outlive the code that created them (drift no reconciler sees).
- **(c) Apps declare the operator's topology CRDs directly in their own
  `deploy/`** (`KafkaTopic`, or RabbitMQ `Queue`/`Exchange`/`Binding`) —
  **recommended.** Git-visible, app-owned, reviewed in the same PR as the
  code using it. The platform's job stops at the trust boundary: identity,
  credentials, ACLs making app A's topology unreachable by app B.

Consequence to name explicitly: `deploy/` grows a **third file category**
alongside platform-type instances and `namespace.yaml` — raw operator CRDs.
That's principle 4 working as designed (golden path for identity/
credentials, visible raw layer for app-domain config), but it must be
written into the onboarding convention or every app repo will improvise it
differently.

## 4. Operator gate survey (verified 2026-08-09)

- **Strimzi (Kafka)** — strongest CRD fit in this space: `Kafka`,
  `KafkaNodePool`, `KafkaTopic`, `KafkaUser` (auto-generated SCRAM or
  TLS-client-cert credential Secrets), declarative ACLs with native
  prefixed patterns. CNPG-grade. Cost: JVM broker, realistically ~1Gi+ even
  single-node KRaft, against S10's "half the machine for workloads" on a
  16GB node already running SeaweedFS + CNPG + observability.
- **RabbitMQ cluster-operator + messaging-topology-operator** — active
  (topology operator: 1,640 commits). Full CRD set: `Vhost`, `User`,
  `Permissions`, `Queue`, `Exchange`, `Binding`, `Policy`, shovel/
  federation. Vhosts are a natural per-`MessageQueue` isolation unit. Two
  wrinkles: the topology operator wants cert-manager for its webhook (this
  cluster has none; a self-signed path exists but is friction), and the
  `User` CRD's credential auto-generation must be verified against the live
  CRD before claiming zero-touch.
- **Redpanda** — Kafka-API-compatible, single binary, no JVM, materially
  lighter; operator active (3,066 commits, maintained release branches,
  v25/v26 series). Verify maturity of its declarative user/ACL surface
  before it passes the gate — footprint alone doesn't qualify it.
- **NATS** — tiniest footprint; thinnest declarative identity/account story
  (JetStream streams/consumers have CRDs via `nack`; accounts/users are
  config-file/JWT-ish). Likely fails the credential gate today despite
  winning the resource budget.

**New clause for the kind-approval gate:** operator quality and zero-touch
credentials are necessary but not sufficient — **the engine's resource
footprint is part of the approval decision** (S10 applies to candidate
engines, not just running components). This collides with CONCEPT.md §2's
"educational wins" clause (Kafka is the industry-standard thing to learn);
the reading offered here is that §8/S10 ("a platform that consumes its own
machine has failed its purpose") outranks learning value — but it's a
conscious call to record when a broker is actually proposed, not to settle
in the abstract.

## 5. D4 nuance: message data is probably not "durable"

Messaging is the first service where the *data itself* (in-flight messages)
arguably shouldn't carry `platform.homelab/durability: durable`: the
topology in git is the real backup, and messages are closer to
`regenerable`/`disposable` by nature. GP6's "it's backed up" needs this
interpretation, or it implies backing up queue contents — almost never the
intent. Broker storage classification is a small, real D4 amendment to make
at proposal time.

## 6. What to record when a broker is actually proposed

Four sentences, executable as-is:

1. Broker cluster = raw platform infra (like `Seaweed`), never a
   self-service kind; the self-service unit is the per-app scoped identity
   (`MessageQueue`), following `ObjectStorage`'s owning/attaching rules
   exactly.
2. Topology is app-owned: operator topology CRDs live in the app's
   `deploy/` — the sanctioned third file category. The platform brokers
   only identity + prefix-scoped ACLs.
3. The kind gate gains a resource-budget clause (S10 applies to candidate
   engines).
4. D4 gains the "message data is not durable" nuance (topology in git is
   the backup).

## Meta-observation

Every convention from the D15 PoC review — name-is-the-handle,
owning/attaching, prefix-scoped isolation, contract-per-kind, additive
schema evolution — transferred to a service the plan never designed for,
unchanged. That's what the D15 pivot's thesis predicts ("cheap to revise in
place") and is the strongest evidence so far the API shape is right. The
broker case added exactly one new pattern (app-owned topology CRs in
`deploy/`) and one new gate clause (resource budget), both recorded above.
