# Homelab Platform — Product Concept

**Status:** Draft — v0.2 open questions resolved
**Author:** —
**Last updated:** 2026-08-10 (v0.5)

---

## 1. One-liner

A single-tenant internal developer platform that lets me go from *an idea* to *code, built, running, and observable* without manually provisioning anything — and which teaches me the platform-engineering layer I don't touch in my day job.

---

## 2. Why this exists

Two motivations, deliberately held in tension.

**Practical.** I have personal projects. Each one currently needs the same tedious scaffolding: somewhere to write code, somewhere to build it, somewhere to put the artifact, somewhere to run it, a database, and some way to know whether it's alive. Today that scaffolding is either absent, done by hand, or rented from a SaaS. I want it to be a template I instantiate.

**Educational.** My working experience is application-layer: Java/Spring Boot, Node/TS, Angular/React, in enterprise finance. The layer beneath — cluster operations, infrastructure-as-code, deployment automation, observability design, self-service abstractions — is a layer I consume rather than build. This platform is the vehicle for building it.

Where the two motivations conflict, **educational wins**. If the "correct" engineering answer is to pay for a managed service, and the learning answer is to run it myself, I run it myself. This is explicitly not a cost- or effort-optimised system.

The inverse also holds: if a component becomes pure maintenance toil with no remaining learning value, externalising it is a legitimate outcome, not a failure.

---

## 3. Users

There is one *human* user, but many *principals*. Conflating those two is the mistake this section exists to prevent.

### 3.1 Human users

**Primary: me.** One person, one trust domain.

This is a real constraint, not a placeholder. It means:

- Multi-tenancy, quotas, and chargeback are out of scope
- Availability targets are "I'll fix it on Saturday"
- But **self-service is still required** — the point is to build the abstraction, even though the queue of human users is length one

**Hypothetical secondary: a future collaborator.** Not built for, but used as a design check. If I couldn't hand someone a doc and have them provision a workspace without my involvement, the abstraction isn't finished.

### 3.2 Machine identities

The platform's automated flows act on their own behalf, not as me. Each automated actor is a **functional identity**: a named, non-human principal with credentials scoped to exactly what it needs to do.

Illustrative, not exhaustive:

| Principal | Acts on | Needs |
|---|---|---|
| Reconciler | Source repos | Read code and manifests; no write |
| Build runner | Source repos, registry | Read source, push images; no deploy rights |
| Deployer | Runtime | Apply manifests within a defined boundary |
| Image puller | Registry | Pull only |
| Backup agent | Volumes, databases, off-site storage | Read state, write to backup target |
| Coding environment | Registry, provisioned services | Scoped to the project it belongs to |

**Requirements this implies:**

- My personal credentials must never be the mechanism by which automation authenticates. If a flow breaks because I rotated my own token or left, that's a design defect.
- Each functional identity is separately revocable without disturbing the others
- Privileges are enumerable and reviewable — I should be able to answer "what can the build runner reach?" from a document, not by experiment
- Identity is scoped by role and blast radius, not by convenience
- Credentials are provisioned as part of the same declarative flow as everything else, not created by hand in a web UI and pasted somewhere

**Why this matters despite one human user:** the single-user constraint removes the *organisational* reasons for identity design but not the *technical* ones. Blast radius, revocation, credential rotation, and least privilege are all still live problems, and they're a substantial part of what I'm here to learn. Coarse authorisation for the human is fine; coarse authorisation for the machines is not.

---

## 4. Product principles

1. **Git is the ledger of state; it is not always the trigger.** Declarative, slow-changing state — deployments, databases, environment promotion — is git-*triggered*: a commit is the only way to change it. Session-oriented and time-critical operations — starting a coding environment, break-glass incident response — may be triggered imperatively, but must converge back to git as the record within a bounded window (D14). Anything that never converges back is by definition temporary and will be destroyed.
2. **Observability is a gate, not a phase.** A capability is not "done" until it emits metrics, logs, and health signals, and has at least one dashboard and one alert. Shipping something unobservable is shipping something unfinished.
3. **Rebuildability over uptime.** I'd rather be able to restore the whole platform in an hour than avoid it ever going down. Recovery is the feature; availability is a side effect.
4. **Golden paths, with escape hatches.** Common cases should be one small declarative file. Uncommon cases should still be possible by dropping to the raw layer underneath.
5. **Boring where it doesn't teach.** Novelty budget is finite and should be spent on the platform layer, not on the OS, the language, or the editor.
6. **Ephemeral by default.** Compute is disposable. State is explicit, enumerated, and backed up. If I can't say which volumes matter, I've built it wrong.

---

## 5. Scope

### 5.1 In scope

| # | Capability area | Summary |
|---|---|---|
| C1 | Self-service provisioning | Declare a resource, get a resource |
| C2 | Coding environments | Remote, reproducible, terminal/editor-based dev |
| C3 | Build & CI | Turn source into tested, signed artifacts |
| C4 | Artifact storage | Somewhere to put images and packages |
| C5 | Deployment & runtime | Run applications with routing, config, secrets |
| C6 | Data services | On-demand databases and caches |
| C7 | Observability | Metrics, logs, traces, dashboards, alerts — cross-cutting |
| C8 | Access & identity | Getting in, safely, from anywhere |
| C9 | Lifecycle | Backup, restore, upgrade, rebuild |

### 5.2 Out of scope (for now)

- **Remote desktop / GUI environments.** Explored separately; parked. Coding environments are terminal- and editor-based only.
- **Public internet exposure.** Nothing is reachable from outside my private network. Public hosting is a later, deliberate decision with its own threat model.
- **High availability.** Single node initially. No redundancy, no failover, no clustering.
- **Multi-tenancy.** No human-user isolation, no quotas, no per-team anything. This does *not* extend to machine identities — separation between functional identities is in scope (§3.2, C8).
- **Windows workloads.**
- **Cost optimisation.** Not a design driver.
- **Serving other people's traffic.** No SLAs, no third-party users.

---

## 6. Capabilities

Each capability is stated as *what it must do*, not how.

### C1 — Self-service provisioning

The mechanism by which everything else is requested.

**Must:**
- Let me declare a desired resource in a short, high-level file — expressing *intent*, not implementation (`I want a Postgres database, small, v16`), and get every underlying piece created for me
- Reconcile continuously: drift from declared state is corrected without my involvement
- Support deletion as a first-class operation that reclaims everything, leaving nothing orphaned
- Report status back — what's provisioning, what's ready, what failed and why
- Make the set of available resource types discoverable and self-documenting

**Should:**
- Offer opinionated sizes (`small`/`medium`) rather than exposing raw CPU/memory numbers
- Automatically attach observability and backup to anything it provisions, without being asked
- Support a dry-run / diff view before changes are applied

**Resolved (D1):** three layers — raw manifests, composed templates, typed API — with a promotion rule governing when a resource type earns the top layer, and a requirement that the top layer render its own output.

**Amended (D15):** `Database`, `ObjectStorage`, and `Application` were promoted to layer 2 at one hand-built instance each, ahead of D1's three-instance rule — a deliberate, reasoned pivot, not an abandonment of the rule itself.

### C2 — Coding environments

Remote development. No desktop.

**Must:**
- Provision a fresh environment for a given project **on direct request — an API call, not a git commit** — from a definition stored in that project's repo
- Auto-commit the rendered layer-1 manifest (D1) for every provisioned environment back to git, as the record of what was requested and when — imperative trigger, git ledger, per D14
- Be reachable over SSH, and usable by a local editor's remote mode (VS Code / JetBrains / Neovim over SSH)
- Include the project's toolchain preinstalled and pinned — JDK, Node, whatever the project declares
- Persist my home directory and shell config across environment rebuilds
- Have credentialled access to the internal registry, the deployment target, and any provisioned databases, without me pasting secrets in
- Be destroyable and recreatable without losing anything that matters (i.e. the only durable state is the git repo and my home directory)

**Should:**
- Start in well under a minute for a warm image
- Support several concurrent environments for different projects, within hardware limits
- Reclaim resources automatically when idle
- Support a "throwaway" mode — clean environment, no persistence, for testing setup instructions

**Explicitly not:**
- Browser-based IDE as the primary path (may exist as a convenience, but SSH is the contract)
- Any GUI, X11, or desktop session

### C3 — Build & CI

Turning source into artifacts, on my own hardware.

**Must:**
- Trigger builds from git events (push, tag, PR)
- Run builds in isolated, ephemeral environments — no state carried between runs
- Produce container images and push them to the registry
- Run tests and fail the build on failure
- Surface logs and results somewhere I can read them without SSHing to a node
- Support manual triggering and re-running

**Should:**
- Cache dependencies between builds without compromising isolation
- Scale build capacity across nodes as hardware is added — *builder nodes are a distinct role from the control plane and from the runtime*, and the platform should treat them as such
- Support build-time secrets that don't leak into image layers
- Generate provenance/SBOM for what it produces
- Sign images

**Resolved (D2):** builds push images to the registry and stop. The build runner holds no git write credential and no deploy rights; the reconciler observes new tags and writes the tag-bump commit itself.

This adds a **must**: the build runner's credentials must be sufficient for registry push and nothing else, verifiable by inspection rather than by experiment.

### C4 — Artifact storage

Container images primarily; language packages secondarily.

**Must:**
- Store and serve container images to the cluster and to build environments
- Be reachable from coding environments, builders, and the runtime
- Retain enough history to roll back a deployment
- Be replaceable — the platform must not be so coupled to a specific registry that swapping it is a rewrite

**Should:**
- Support retention/garbage-collection policies so untagged layers don't accumulate forever
- Cache upstream public images to reduce external dependency and rate-limit exposure
- Scan images for vulnerabilities and report findings

**Resolved (D5):** external hosted registry initially, sharing the git host's identity system. A **pull-through cache runs locally from the start** — it's cheap, it removes rate-limit exposure, and it's most of the answer to surviving an internet outage (D10).

The coupling stays loose by referencing the registry host as exactly one configuration value that every manifest interpolates. Self-hosting is a later choice, driven by whether storage drivers and garbage collection are teaching me anything at the time.

### C5 — Deployment & runtime

Running the things I build.

**Must:**
- Deploy an application from a declarative definition, with a defined route/hostname, environment config, and secrets
- Roll out updates without manual intervention when the source of truth changes
- Roll back to a previous version
- Support both long-running services and scheduled/batch jobs
- Provide TLS and stable internal hostnames
- Keep secrets encrypted at rest in git, decrypted only at deploy time

**Should:**
- Provide per-environment separation (e.g. `dev` vs `prod`) using the same definitions with different config — **available to every application, required of none** (D3). At one operator on one machine, most projects don't earn two environments, and forcing them doubles the resource cost of the smallest workloads. The structure supports it; the golden path doesn't assume it.
- Support health checks that actually gate traffic
- Scale to zero for things I use rarely
- Make the deployed-version-to-git-commit mapping obvious and queryable

### C6 — Data services

**Must:**
- Provision a Postgres database on request, with credentials delivered to the requesting application automatically
- Back it up on a schedule, to storage that survives total loss of the machine
- Support restore, including point-in-time
- Emit database-level metrics into the observability stack by default

**Should:**
- Support other common services on the same self-service pattern (object storage, cache, message broker) — the specific list matters less than the pattern generalising
- Provide me direct query access from a coding environment without exposing the database more widely

**Test of success:** provisioning a database and connecting an app to it should involve zero manual credential handling.

**Resolved (D15):** object storage delivered on the same self-service pattern as Postgres, ahead of schedule — a typed `ObjectStorage` API (kro, backed by SeaweedFS) with per-consumer isolated credentials, proven with a real app. Message broker and cache remain unbuilt (see `docs/message-broker-design-notes.md` for exploratory notes on the former).

### C7 — Observability

**Cross-cutting. Not a component — a property every other capability must have.**

**Must:**
- Collect metrics and logs from platform components *and* from my own applications
- Instrument applications for tracing from the outset — trace IDs in structured logs, exemplars exposed on metrics — even before a trace backend exists (D7). The backend itself is deferred until there is a second service to correlate with; the instrumentation is not.
- Provide dashboards covering: node health, cluster health, per-application health, build outcomes, and data service health
- Alert me — on a channel I actually read — when something is broken or about to be
- Retain enough history to investigate something I notice a week late
- Make it trivial for a new application to become observable: instrumenting should be the default path, not extra work
- Correlate signals — from an alert, reach the relevant logs and traces without manual timestamp-hunting

**Should:**
- Track platform-level SLOs (e.g. environment provisioning success rate and latency, build duration, deployment frequency, time-to-restore)
- Include the observability stack in its own monitoring — I need to know when monitoring is down
- Support exploring costs of resource usage (CPU/RAM/storage by workload), as a proxy for the capacity planning I'd do in a real environment

**Hard constraint (D7):** the observability stack gets ~20% of the machine and no more. If a signal doesn't fit the budget, the budget wins and the signal is dropped, sampled, or shortened in retention.

**Cardinality rule:** no metric label whose value set is unbounded — no user IDs, no request paths containing identifiers, no error strings. This is the single rule that prevents most of the ways a metrics store eats a machine.

**Anti-requirement:** alerts that I learn to ignore. Alert volume is a design constraint. Every alert must be actionable; if it fires and I do nothing, it gets deleted or fixed.

**This is the capability I most want to get right**, because it's the one most poorly done in most real organisations and the one where good taste is hardest to acquire second-hand.

### C8 — Access & identity

Covers two distinct classes of principal (see §3): me, and the platform's functional identities.

**Must — human access:**
- Provide secure remote access from anywhere without exposing services to the public internet
- Give a single, consistent way to authenticate to platform UIs (dashboards, CI, registry)
- Manage SSH access to coding environments without per-environment key juggling

**Must — machine access:**
- Support distinct functional identities per automated flow, each independently issuable and revocable
- Scope every functional identity to the narrowest privilege that lets it do its job
- Never require my personal credentials for any automated flow
- Make the full set of functional identities and their privileges discoverable — declared in git, not scattered across service UIs
- Support rotation of any credential without downtime or manual reconfiguration elsewhere

**Must — both:**
- Store all credentials encrypted in git or a dedicated secrets store — never in plaintext, never only on one machine

**Should:**
- Single sign-on across platform components for human access
- Short-lived, automatically renewed credentials over long-lived static tokens **where the provider supports it** (D13). Where it doesn't, narrow scoping and a scheduled rotation are mandatory rather than optional — this is a *must* wearing a *should*'s clothes, and the distinction is the provider's, not mine.
- Workload identity derived from the platform itself rather than static secrets, where the underlying services support it
- Network policy defaulting to deny, with explicit allows
- Audit trail of what each identity did, queryable from the observability stack

**Resolved (D1, D11, D12):** credential handling is pushed as far as the layer-2 API, and stays explicable because that layer renders what it generated. Granularity is per-project for the two principals that execute repo-supplied code, coarser elsewhere. The whole chain terminates at one key.

### C9 — Lifecycle

**Must:**
- Rebuild the entire platform from an empty machine + the git repo + one secret key, in under a defined time budget
- Back up all durable state (databases, persistent volumes, configuration) off-machine
- Classify every persistent volume as **durable**, **regenerable**, or **disposable** (D4) by label, drive backup policy from that label, and **alert on any unlabelled volume**. The inventory is an invariant the platform checks, not a document that goes stale.
- Restore from those backups, verified — not assumed
- Upgrade platform components deliberately and reversibly, with pinned versions

**Should:**
- Have the rebuild exercised on a schedule, not just documented
- Support adding a node to the cluster as a repeatable, automated operation, since hardware will expand
- Handle graceful shutdown and restart (power cuts are real)

---

## 7. Golden paths

Narrative scenarios. These are the acceptance criteria for the platform as a whole — if any of them still requires manual work, the platform is incomplete.

### GP1 — New project, zero to running

> I have an idea for a small service.
>
> I create a repo from a template. I declare a coding environment and a database in it. I open the environment from my laptop's editor within a minute. I write code, with the database already connected. I push. It builds, tests, produces an image, and deploys to my `dev` environment automatically. I open a URL and it works. I open a dashboard and see its request rate, error rate, and latency — without having configured a dashboard.

### GP2 — Ongoing work

> I sit down on a Saturday. I connect to an existing coding environment, exactly as I left it. I make a change, push, watch it roll out, and check the dashboard for regressions. Total friction between "I want to change this" and "it's running": minutes, none of them spent on infrastructure.

### GP3 — Something breaks

> An alert reaches me: error rate elevated on a service. From that alert I reach a dashboard, from the dashboard I reach the logs for the failing instance, from the logs I reach the trace for a failing request. I identify the bad deploy, roll it back with a git revert, and confirm recovery on the same dashboard. I never SSH into a node.

### GP4 — Total loss

> The machine dies. I get a new one. I run one bootstrap process. The platform reconstitutes itself from git. I restore data from off-site backups. Everything is back, verified, within the time budget. Nothing was lost that I hadn't consciously decided was disposable.

### GP5 — Growth

> I add a second machine. It joins as a builder node with one automated operation. Builds start scheduling onto it. Nothing else changes, and nothing needed rewriting to accommodate it.

### GP6 — Provisioning a new capability

> I want a message broker for a project. I add a few lines to a repo. It's provisioned, credentials are delivered to my app, it's backed up, and it appears in monitoring — because that's what the platform does by default, not because I remembered to wire it up.

---

## 8. Constraints

- **Hardware:** one modest x86 laptop initially (8 cores, 16GB, 1TB). Expandable later, but the design must be useful *now*, on this.
- **Power/network:** domestic. Unreliable. Assume unplanned reboots and no static IP.
- **Time:** evenings and weekends. Anything requiring sustained attention to stay alive will rot and should not be built.
- **Single operator:** no one else to fix it, no one else to ask.
- **Resource budget:** platform overhead must leave meaningful capacity for actual workloads. A platform that consumes its own machine has failed its purpose. Within that, observability is capped at ~20% of the machine (D7).
- **Accepted single point of failure:** the external git host. Principle 1 makes git the only interface for state, and D5 keeps the registry there too, so an outage at that provider means no deploys and no promotions until it returns. Mitigated by a local mirror and by workloads continuing to run (D10), but not eliminated. Named here so it's a decision rather than a discovery.

---

## 9. Success criteria

The platform is working if:

| # | Criterion |
|---|---|
| S1 | A new project reaches "running and observable" in under 30 minutes of my time |
| S2 | I have not run an imperative command against the cluster to change state in over a month |
| S3 | A full rebuild from bare machine succeeds in under an hour, and has been done at least twice |
| S4 | A restore from backup has been tested and verified, not merely configured |
| S5 | Every running workload appears in a dashboard without bespoke per-workload setup |
| S6 | Every alert that fired in the last month was actionable |
| S7 | Adding a node required no changes to any existing definition |
| S8 | I can explain every component's purpose and would defend its inclusion in a design review |
| S9 | No automated flow depends on my personal credentials, and any single functional identity can be revoked and reissued without breaking the others |
| S10 | Platform overhead leaves at least half the machine's resources for workloads |
| S11 | Every persistent volume carries a state class, and no unlabelled volume has survived a day |
| S12 | An internet outage has been simulated, and coding, committing, and running workloads all survived it |

**Explicit non-criteria:** uptime percentage, cost, number of components, resemblance to any particular reference architecture.

---

## 10. Learning objectives

Stated separately because they justify decisions that would otherwise look irrational.

| Area | What I want to come out understanding |
|---|---|
| Cluster operations | How a scheduler, control plane, and CNI actually behave when stressed |
| Infrastructure as code | Idempotency, drift, the boundary between config management and orchestration |
| GitOps | Reconciliation, dependency ordering, secret handling, rollback semantics |
| Platform abstraction | How to design an API that developers want to use — and what makes one bad |
| Observability | Instrumentation design, cardinality, alert design, SLOs, correlation between signals |
| Build systems | Isolation, caching, supply chain, provenance |
| Storage & state | Volumes, backup strategy, consistency, restore verification |
| Networking | Ingress, service discovery, network policy, overlay networks, DNS |
| Security | Secret management, least privilege, workload identity, image scanning |
| Capacity | Requests vs limits, pressure, eviction, planning under real constraints |

---

## 11. Decisions

The open questions from v0.2, resolved. Each records the decision, the reasoning that produced it, and what would reverse it. Numbering follows the v0.2 question numbers; D9 is absent because public exposure remains deliberately parked (§11.14).

### D1 — Platform API thickness

**Decision.** Three layers, with a promotion rule.

- **Layer 0** — raw manifests in git. Always available, always the escape hatch.
- **Layer 1** — composed templates. Common shapes, parameterised.
- **Layer 2** — a genuine typed API (Crossplane compositions, kro, or a hand-written operator).

A resource type is promoted to layer 2 only **after the third instance has been built by hand**. Designing an abstraction before the instances exist is the standard way platform APIs end up leaky.

Initial layer 2 types: `Application`, `Database`, `CodingEnvironment`. Nothing else.

Layer 2 must **render its layer 1 output visibly**, so any abstraction can be read and forked down into raw manifests. This is principle 4's escape hatch made concrete, and it's what keeps automated credential handling explicable rather than magical.

**Reverses if:** the promotion rule produces abstractions that go unused, or the render requirement turns out to be impractical in the chosen tool.

### D2 — Build/deploy boundary

**Decision.** The build runner pushes an image to the registry and stops. The reconciler watches the registry for new tags matching a policy and writes the tag-bump commit itself.

The build runner therefore holds **no git write credential at all** — only registry push.

**Rejected alternative:** the build runner opens a pull request against the config repo. This is the more commonly recommended pattern, and it's worse here: it hands a commit credential to a principal that executes arbitrary repo-supplied code. Given that machine identity design is one of the things this platform exists to teach (§3.2), the model that makes the build identity genuinely useless for deployment is the one worth building.

Promotion to `prod` stays a hand-written commit pinning a digest — which is the manual gate I want anyway.

**Cost:** one more controller, and image tagging policy becomes load-bearing rather than incidental.

### D3 — Environment model

**Decision.** Single cluster. Namespace per `(application, environment)`. One config repo with a directory per environment, sharing base manifests through per-environment overlays. Promotion is a commit changing a pinned digest in the target directory.

`dev` is **optional per application** — see C5.

**Rejected:** branch-per-environment, which drifts and turns every promotion into a cherry-pick. Separate clusters per environment, which 16GB does not support.

**Reverses if:** a second machine arrives and a dedicated non-production cluster becomes affordable — at which point the directory structure already maps onto it.

### D4 — Durable state inventory

**Decision.** Three classes, enforced mechanically rather than documented.

| Class | Meaning | Examples |
|---|---|---|
| **Durable** | Loss unacceptable | Postgres data, coding-environment home directories, root key material, object storage |
| **Regenerable** | Recoverable from source, with effort | Registry contents, build caches |
| **Disposable** | Loss is a non-event | Pod filesystems, observability time series |

Every persistent volume carries a label declaring its class. Backup policy is driven off the label. **An unlabelled volume fires an alert.** That converts the inventory from a document that goes stale into an invariant the platform checks — which is what principle 6 actually needs to mean.

Observability data is explicitly **disposable**: dashboards and alert rules live in git, the time series don't survive a rebuild, and accepting that removes a large amount of backup machinery for data I'd rarely look back at.

**Partial realisation, recorded because it diverges (2026-08-13).** Durability is currently expressed two ways at once, and the two have not been reconciled. Storage tiering encodes it in the *StorageClass* — `local-path` (Delete) for disposable state, `local-path-retain` and `local-path-bulk` (Retain) for durable state, split by access pattern rather than by component (`docs/storage-tiering-notes.md`). Separately, a `platform.homelab/durability` label is set on the volumes the SeaweedFS cluster and the `Database` RGD provision. Neither is the three-valued class label this decision describes, no unlabelled-volume alert exists, and which object is authoritative is undecided. The decision stands as written; only its realisation is partial, and the gap is tracked in Linear rather than here.

### D5 — Registry: internal or external

**Decision.** External initially, on the same provider as the git host so the identity systems are shared (which materially helps D13). Local **pull-through cache from day one**.

**Reasoning.** A registry is a blob store with an API and teaches relatively little. The supply-chain layer *around* it — signing, provenance, SBOM, retention, scanning — is where the learning is, and all of that works against any registry.

**Reverses if:** storage drivers and garbage collection become something I want to learn directly, or the external provider's terms change.

### D6 — Idle reclamation for coding environments

**Decision.** Build it, and keep it stupid. **No active SSH session for 60 minutes → scale to zero.** No CPU heuristics, no activity scoring.

**Reasoning.** On 16GB, memory is the binding constraint, and manual discipline will rot — which the time constraint in §8 predicts directly. The home directory is on a persistent volume, so restart is the warm-start path C2 already requires.

**Known failure case:** a long-running build or job inside the environment with no attached session. Mitigated by a sentinel file that suppresses reclamation, and by accepting that I will occasionally forget to create it.

### D7 — Observability budget

**Decision.** A hard cap of ~20% of the machine, roughly 3GB, consistent with S10.

**What that buys:** Prometheus at around 15 days retention, Loki rather than anything Elastic-shaped, Grafana, Alertmanager.

**What it doesn't buy:** a tracing backend. Traces are therefore deferred — but **trace instrumentation is not** (C7). Trace IDs in structured logs and exemplars on metrics are nearly free, and they mean the backend can be added later without revisiting every application. The trigger for adding it is the first service that calls another service; until there's a call graph, tracing is log search with extra steps.

Cardinality discipline is part of the budget, not separate from it — see the rule in C7.

### D8 — Upgrade cadence and blast radius

**Decision.** Everything pinned by digest. Renovate raises PRs against the config repo. Batched monthly on a Saturday; security patches out of band.

Three tiers by blast radius:

| Tier | Components | Rule |
|---|---|---|
| 1 | Cluster itself, reconciler | Can break the ability to fix it. One at a time, never two in a window, never simultaneously with what they reconcile |
| 2 | Observability, registry cache, data-service operators | Breaks visibility or provisioning, not running workloads. Upgrade freely |
| 3 | Workloads | Trivial; roll back by git revert |

**The move that makes this cheap:** S3 already requires periodic rebuilds from bare metal. Where possible, the **rebuild is the tier 1 upgrade mechanism** — one Saturday produces both an upgrade and a verified restore test.

### D10 — Internet outage behaviour

**Decision.** Degraded, not down.

**Survives:** running workloads, the reconciler enforcing last-known state, coding environments, writing and committing code locally.

**Does not survive:** deployments, promotions, and pulling any dependency not already cached.

**Requirements this creates:** the pull-through image cache (D5), a dependency proxy for language package managers, cluster DNS that doesn't depend on reaching an external resolver, and a local git mirror so commits land somewhere before upstream is reachable again.

The residual exposure — the external git host as a single point of failure — is recorded in §8 as accepted rather than solved.

### D11 — Functional identity granularity

**Decision.** Granularity follows blast radius, and blast radius is highest wherever code I haven't fully reviewed executes.

| Principal | Granularity | Reasoning |
|---|---|---|
| Build runner | **Per project** | Executes arbitrary code from the repo it builds; a compromise must not reach other projects' images |
| Coding environment | **Per project** | Same argument, and it holds database credentials |
| Deployer | Per environment | `dev` and `prod` genuinely differ; per-project adds machinery without reducing meaningful blast radius |
| Image puller | Per namespace | Falls out of Kubernetes naturally, costs nothing |
| Reconciler | Single | Needs to see everything by definition; splitting it is theatre |
| Backup agent | Single, append-only | Scope the *target* instead — write-only credentials so a compromise can't destroy history |

This answers the "considerably more machinery" objection in the original question: per-project machinery is paid for in exactly the two places it buys something, and nowhere else.

### D12 — Credential bootstrap chain

**Decision.** The chain terminates at **one age/SOPS private key**. That key decrypts everything in git; every other credential is either minted by the cluster (ServiceAccount tokens, cert-manager certificates) or federated to an external provider.

**The apparent circularity** — bootstrap needs to clone the config repo before it can decrypt anything — resolves by storing the repo's read-only deploy key *encrypted with the age key*, somewhere fetchable without credentials. GP4's "one bootstrap process, one secret key" then remains literally true, which is worth preserving as a property and not just as prose.

**Protecting the root:** a hardware token if the learning is worth it; at minimum an encrypted copy in two physically separate locations plus a password manager. The threat model here is domestic — fire, theft, a dead laptop — not a targeted adversary.

**This key is the one thing the platform cannot rebuild itself out of.** It is the single point in the design where "rebuildability over uptime" does not hold, and it should be treated with the seriousness that implies.

### D13 — Short-lived credentials from external services

**Decision.** Pursue where supported; mandate scoping and rotation where not. C8's *should* is amended accordingly.

- **Git host and registry** — short-lived credentials are achievable if the provider offers app-installation tokens with roughly hourly expiry, covering the two highest-traffic external dependencies together.
- **Off-site backup** — provider-dependent. Providers supporting OIDC federation will trust the cluster as an identity provider, but that generally requires the cluster's OIDC discovery document and JWKS to be publicly fetchable. Publishing those two static files to public object storage is the standard approach; it exposes no services and doesn't meaningfully breach §5.2, but it is a conscious decision rather than an implementation detail. S3-compatible providers tend to offer long-lived application keys only, scopable to a single bucket — in which case **append-only scoping is the mitigation that matters**, since it defends the property backups actually need.
- **Anywhere long-lived tokens are unavoidable** — SOPS storage, narrowest available scope, calendar-driven rotation.

**Verify before committing.** Provider capabilities in this area change, and the specifics above should be confirmed against current documentation rather than assumed.

### D14 — Reconciliation lane: declarative trigger vs. imperative trigger, git as ledger

**Decision.** Two lanes, not one.

- **Declarative lane** (default). Deployments (C5), databases (C6), environment promotion (D3). A commit is the *only* way to change these. This is GitOps in the strict sense principle 1 originally claimed for everything, and it stays the golden path for anything long-lived, slow-changing, or where audit-trail-and-rollback-by-revert is the point.
- **Imperative lane** (first-class, not an escape hatch). Session-oriented or time-critical operations: starting/stopping a coding environment (C2), and break-glass incident intervention (GP3). These are triggered by a direct API call, not a commit. Every imperative action must **converge back to git as a record** — the acting service auto-commits the rendered layer-1 manifest (D1); I never hand-write it — within a bounded window: target under 5 minutes for environment lifecycle events, immediately following resolution for break-glass.

**Break-glass procedure, concretely:** suspend the reconciler's watch on the affected resource → make the direct fix → commit the fix to git so it matches reality → resume reconciliation. This is the same shape Flux (`flux suspend`/`resume`) and Argo CD (pause sync) formalise as standard practice, and it exists because an unsuspended reconciler reverts a manual fix on its next cycle. GP3's "I never SSH into a node" holds for the common case; the rare case now has a named procedure instead of being undefined.

**Reasoning.** Forcing session-oriented resources through commit-and-reconcile optimises for the wrong thing: GP1's "within a minute" and GP2's "minutes, none of them spent on infrastructure" both assume request latency close to zero, which a poll- or webhook-triggered reconciler doesn't give for free. Comparable systems split the same way — dev-environment platforms that went API-first for workspace lifecycle did so for exactly this reason, while IaC-first alternatives are the slower, more ceremony-heavy path in the same comparisons. Meanwhile D11–D13 already treat rotated credentials and cluster-minted tokens as living outside git's write path; this decision names that pattern as a rule instead of leaving it as three unrelated ad hoc exceptions.

**Rejected alternative:** keep everything in the declarative lane, and lean on D6's sentinel file plus a short reconciliation interval to make C2 feel responsive. Rejected because it treats a structural mismatch — a session-oriented resource forced through a reconciliation-oriented tool — as a tuning problem, and because it leaves break-glass entirely unaddressed: GP3 makes a promise the rest of the document had no mechanism to keep under real incident conditions.

**Tradeoffs.**
- *Cost:* two code paths instead of one. The typed API (D1 layer 2) now needs both a git-watching reconcile loop and a direct-call handler that writes git after the fact — more surface area, and the first place the platform has two triggers for what looks like the same state.
- *Cost:* the imperative lane weakens the audit property GitOps gives for free. "What changed and when" now depends on the acting service reliably auto-committing, not on git history being causally prior to the change — a crash between "fix applied" and "commit written" leaves a real, if brief, gap between cluster state and git.
- *Cost:* break-glass is, by construction, the one place I can diverge from declared state without review — the exact failure mode principle 1 exists to prevent. The mitigation is that it's bounded, logged, and requires a closing commit, not that the risk disappears.
- *Benefit:* C2 stops fighting its own golden paths (GP1, GP2), and GP3 gets an actual mechanism instead of an unqualified promise.
- *Benefit:* the git-as-ledger vs. git-as-trigger distinction makes D11–D13's existing exceptions legible as one rule instead of three unrelated ones.

**Reverses if:** reconciliation latency turns out to be a non-issue in practice — e.g. webhook-triggered reconciliation proves fast enough that the declarative lane meets GP1's "within a minute" unmodified — in which case C2 folds back into the declarative lane and this decision is unnecessary complexity.

### D15 — Layer-2 promotion pivot: `Database`, `ObjectStorage`, `Application` via kro, ahead of D1's instance count

**Decision.** Promote `Database`, `ObjectStorage`, and `Application` to layer 2 (D1) via kro `ResourceGraphDefinition`s at one hand-built instance each, instead of waiting for the third instance D1's rule otherwise requires. Group `platform.homelab/v1alpha1`: `Database` renders a CNPG `Cluster`+`PodMonitor` (single-consumer by convention, not schema-enforced); `ObjectStorage` renders a SeaweedFS `Bucket` and is the shared type — one instance per bucket, every attaching `Application` gets its own isolated `S3Identity`/`S3Credentials`/prefix-scoped `S3Policy`/`S3PolicyBinding`; `Application` renders `Deployment`+`Service`+`Ingress` and attaches to lists of both, with per-attachment env vars and explicit unresolved-ref status so a typo'd reference fails loudly instead of reading `ready: true`.

**Reasoning.** D1's promotion rule guards against designing an abstraction before enough instances reveal its real shape — the leakiness it prevents comes from hand-committing bespoke YAML per instance and migrating everyone off a guessed abstraction later. A kro RGD doesn't fail that way: it's declarative and cheap to revise in place, and an additive schema change re-reconciles every existing instance without touching them (confirmed live — adding `objectStorage`/`securityContext`/`persistence` to `Application`'s schema left the already-running `fastapi-echo` instance untouched). That moves the risk from "wrong abstraction, expensive to fix" to "kro's own API is v1alpha1" — real, but smaller — and it buys C1's self-service pattern now instead of spending a third hand-built instance mostly re-proving mechanics the first two already established.

**Proof status.** `fastapi-echo` (Database) and `personal-finance-dashboard` (Application + ObjectStorage) are both live and serving. The sharing proof (second `Application` attaching to the same `ObjectStorage`), the reclaim check, and a deliberate breaking-schema-change negative test were named in the design but not yet run as documented proofs — tracked in Linear, not silently dropped.

**Reverses if:** kro's v1alpha1 API breaks compatibility in a way that costs more than a third hand-built instance would have, or a promoted RGD turns out to need a rewrite rather than a revision once a real second consumer arrives.

Full design and build record, including every gotcha hit: `docs/self-service-platform-design-notes.md`.

### D16 — Zero-touch app registration: CI self-registers directly to the cluster

**Decision.** Not yet built — design only. Each app repo's own CI joins the tailnet (`tailscale/github-action`) and `kubectl apply`s its own `GitRepository`+`Kustomization` pair directly into the cluster, authenticated via GitHub Actions OIDC federated straight to k3s's API server (no stored token), instead of a per-app commit to this repo.

**Reasoning.** D15 still leaves one manual step per app: a small Flux pointer committed to *this* repo, even though the app's own manifests live entirely in the app's own repo. The requirement is literal zero changes to this repo per app, ever — it's infrastructure, not a per-app registry. ArgoCD's `ApplicationSet` SCM generator does org/topic-wide auto-discovery natively but means running a second CD tool, a disproportionate swap; the Flux-native `gitopssets-controller` ships no equivalent GitHub-discovery generator out of the box. Reusing Tailscale, Kubernetes-native OIDC trust, and `kubectl apply` — all already standard or already-proven-feasible in this repo — needs no new controller.

**Revised before build (pre-implementation design review, 2026-08-11):** the original draft used a long-lived bound ServiceAccount token, explicitly named at the time as a PoC posture with GitHub OIDC federation as the revisit trigger below. Since nothing had been built yet, that revisit happened immediately rather than being built once and migrated later — k3s trusts GitHub's OIDC issuer directly (traditional apiserver flags, GA at this cluster's live k3s `v1.36.2`), and a `ValidatingAdmissionPolicy` (CEL-native, no new controller) enforces that each repo's CI identity can only touch its own `GitRepository`/`Kustomization`, using the repo name already embedded in GitHub's `sub` claim.

**Named tradeoffs.** Breaks full git-reconstructibility for this one object class (a from-scratch cluster rebuild won't recreate app pointer objects; each app's CI needs re-triggering). No stored long-lived credential to rotate — resolved, not just accepted, by the OIDC revision above. Per-repo isolation is now real (via the admission policy) rather than accepted-as-absent, though it depends on that policy's CEL being correct — named as this decision's own load-bearing risk, with an explicit cross-repo-collision test named in the design doc. Delete lifecycle has a working manual path (a per-app teardown CI job) but still no automatic reaction to a repo being deleted/archived without running it first — that gap stays open, documented as policy.

**Reverses if:** a second real trust boundary arrives that the admission-policy model can't express (e.g. isolation needed between humans, not just between repos); or a second OIDC issuer is ever needed (the traditional single-issuer apiserver flags used here would need to migrate to the structured `AuthenticationConfiguration` mechanism).

Full design: `docs/self-service-platform-design-notes.md` §8.

### 11.14 Remaining open questions

Deliberately unresolved, and recorded so they stay that way consciously.

1. **Does anything ever get exposed publicly?** (was Q9.) Parked. If the answer becomes yes, it requires a separate threat model and a separate document — not an amendment to this one.
2. **Remote desktop / GUI environments.** Parked at v0.1 and still parked (§5.2).
3. **Image tagging policy.** D2 makes this load-bearing: the reconciler's tag-matching policy is now the mechanism by which code reaches production. Semver, timestamp, commit SHA, or a combination — undecided, and worth deciding carefully rather than by default.
4. **Is publishing OIDC discovery documents acceptable?** D13 depends on it for federated backup credentials. Low risk, but it's the first thing in the design that puts anything cluster-derived on the public internet.
5. **What reliably suppresses idle reclamation?** D6's sentinel file is a mechanism, not a guarantee. Whether something more reliable is worth the complexity is a question for after the first time it bites.

---

## 12. Glossary

| Term | Meaning here |
|---|---|
| **Platform** | The layer providing self-service capabilities; distinct from the workloads running on it |
| **Workload** | Something I built and deployed, as opposed to platform machinery |
| **Coding environment** | Remote, ephemeral, project-specific development container reachable over SSH |
| **Builder node** | Machine or capacity dedicated to running builds, distinct from control plane and runtime |
| **Golden path** | The supported, opinionated route through a common task |
| **Durable state** | Data whose loss would be unacceptable |
| **Regenerable state** | Data recoverable from source with effort — rebuildable, but not for free |
| **Disposable state** | Data whose loss is a non-event; the default class |
| **State class** | The durable/regenerable/disposable label carried by every persistent volume (D4) |
| **Promotion** | Moving a specific image digest from one environment to the next by hand-written commit |
| **Reconciliation** | Continuous correction of actual state toward declared state |
| **Principal** | Any authenticated actor — human or machine |
| **Functional identity** | A named non-human principal representing an automated flow, with independently scoped and revocable credentials |
| **Blast radius** | What a given principal could damage or reach if its credentials were compromised |

---

## 13. Revision notes

- **v0.1 (2026-08-01)** — Initial concept. Remote desktop capability explored and deliberately deferred. Scope narrowed to coding environments, builds, registry, deployment, and observability.
- **v0.2 (2026-08-01)** — Split human users from machine identities (§3). Automated flows now act as scoped functional identities rather than as the operator. C8 expanded accordingly; multi-tenancy exclusion clarified as applying to humans only.
- **v0.3 (2026-08-01)** — §11 converted from open questions to decisions (D1–D13), with public exposure and remote desktop left explicitly parked. Consequent changes elsewhere:
  - **C4** — registry decided as external initially, with a local pull-through cache from the start (D5).
  - **C5** — per-environment separation available to every application but required of none (D3).
  - **C7** — trace *backend* deferred while trace *instrumentation* becomes a must; observability given a hard resource budget and a cardinality rule (D7).
  - **C8** — short-lived credentials qualified by provider capability, with scoping and rotation mandatory where short-lived credentials aren't available (D13).
  - **C9** — three-way state classification added, enforced by label with an alert on anything unlabelled (D4).
  - **§8** — external git host named as an accepted single point of failure; observability budget recorded as a constraint.
  - **§9** — S11 (state labelling) and S12 (verified offline degradation) added.
  - Design questions in C1, C3, and C8 replaced with pointers to the decisions that answer them.
- **v0.5 (2026-08-10)** — D15 recorded: `Database`, `ObjectStorage`, and `Application` promoted to layer 2 via kro ahead of D1's three-hand-built-instance rule, with the reasoning for why that's a deliberate pivot rather than abandoning D1. D16 recorded: zero-touch app registration (CI self-registers directly to the cluster), design only, not yet built. Consequent changes:
  - **C1** — D1's promotion rule now carries a recorded amendment for these three types (D15).
  - **C6** — object storage resolved and delivered self-service, alongside Postgres (D15).
  - `AGENT.md` repo layout updated for `kro/`, `platform-api/`, `postgres/`, `seaweedfs/`, `seaweedfs-runtime/`, and per-app pointer directories. `PR.md` removed from the repo — its findings were fixed during the Phase 0 review cycle it tracked, and it wasn't being kept current as a running log for anything after.
- **v0.7 (2026-08-13)** — **D4** annotated with its partial realisation: a two-tier storage layout (`local-path-bulk` on the spinning disk, split by access pattern) plus a `platform.homelab/durability` label on some provisioned volumes — neither of which is yet the three-valued, alerted invariant D4 specifies. The decision is unchanged; the divergence is recorded rather than resolved. No new decision recorded for the tiering itself: `docs/storage-tiering-notes.md` and `AGENT.md` carry the mechanism, and this document stays a decision log rather than a work tracker.
- **v0.6 (2026-08-11)** — D16 revised pre-implementation: the bound-ServiceAccount-token auth model replaced with direct GitHub OIDC federation into k3s, and a `ValidatingAdmissionPolicy` added for real per-repo isolation (previously accepted as absent). Still design-only, not built. Motivated by a broader pass to unify the platform's auth/RBAC model, still in progress — no other decisions changed yet.