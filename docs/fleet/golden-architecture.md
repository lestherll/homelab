# The golden architecture — three layers, and the contracts between them

**Status: standing description, 2026-08-31.** Not a decision record. It describes
what this system already is, names the boundaries it has been relying on
unnamed, and states what those boundaries commit to.

> **This file outlives the D20 ADR.** `docs/adr/0001-single-model-talos-fleet.md`
> says that on acceptance its Decision becomes D20 in `CONCEPT.md` and its body
> becomes `single-model-fleet-design-notes.md`, after which that file is deleted.
> This one is not part of that migration — D20 is a decision *inside* this
> architecture, not the architecture itself.

**Why it is being written now.** Four investigations in one sitting — Metal³,
Tinkerbell, Tinkerbell + Cluster API, and the fleet's actual hardware — all
landed in the same place, and **not one of them changed a file in
`infrastructure/` or in the platform API.** That is the shape of the system
showing through. The ADR has already made this argument twice, for D18 and again
for D20, each time without naming the layers it was arguing about. Naming them
turns a recurring rhetorical move into something checkable.

---

## 1. The three layers

| Layer | Owns | Reconciled by | Lives in |
| --- | --- | --- | --- |
| **Platform API** | `Database`, `ObjectStorage`, `Application` — the typed products other repos consume | kro | `infrastructure/platform-api/`, `scripts/platform-render` |
| **Infrastructure** | The cloud primitives: CNI + policy, storage classes, ingress/identity, data-service operators, telemetry | Flux, from git | `infrastructure/**` |
| **Fleet** | Machines: acquisition, inventory, power, boot, OS install, machine config, decommission | Terraform + hand, today | `terraform/`, `docs/fleet/`, retiring `ansible/` |

**The Platform API is the product.** `CONCEPT.md` §1 describes the whole project
as going *"from an idea to code, built, running, and observable without manually
provisioning anything"* — that sentence describes this layer. The other two exist
to hold it up. Every decision below the top layer is justified by whether the top
layer notices, which is why §4 is the section that matters.

## 2. The picture

```
┌─ PLATFORM API ─────────────────────────────────── the product ─┐
│  Database    ObjectStorage    Application                      │
│  kro ResourceGraphDefinitions · platform.homelab/v1alpha1      │
│  consumers: app repos, self-registering (D16)                  │
│                                                                │
│  D1's "Layer 0/1/2" (raw → templates → typed) is the           │
│  THICKNESS of this layer, not a sibling of these three.        │
└──────────────────────────┬─────────────────────────────────────┘
      ▲ contract: a typed resource containing no concept
      │           of a node, a disk or a machine
┌─ INFRASTRUCTURE ─────────┴────────────── the cloud primitives ─┐
│  Cilium      storage classes    Tailscale operator             │
│  CNPG        SeaweedFS          kro operator                   │
│  kube-prometheus-stack   metrics-server   (KubeVirt)           │
└──────────────────────────┬─────────────────────────────────────┘
      ▲ contract: storage classes named by GUARANTEE, an
      │           ingress, a policy backend, an identity
┌─ FLEET ──────────────────┴─ hardware lifecycle & provisioning ─┐
│  machines · power · boot · OS install · machine config         │
│  today: USB install + Terraform (siderolabs/talos)             │
│  later: plain iPXE  →  Tinkerbell (Smee + Hardware CRD)        │
└────────────────────────────────────────────────────────────────┘
      ▲ contract: N nodes, disks of known ROLE, one network

  cross-cutting — deliberately not inside a layer:
    tailscale-acl/   git-owned, outside Flux; AGENT.md's
                     "fourth control plane"
    observability    CONCEPT.md C7 calls it cross-cutting;
                     it reads all three layers
```

Two things the diagram is making explicit that prose keeps losing:

- **The arrows point up.** A layer offers a contract; it does not reach into the
  one above. Every leak in §5 is a case where that failed.
- **The cross-cutting pair sit beside the stack, not in it.** Forcing
  `tailscale-acl/` into a layer is what makes people think it is reconciled by
  Flux, which is exactly the mistake AGENT.md warns about.

## 3. The invariant

One claim, and everything else here is either evidence for it or an exception to
it:

> **Each layer's contract is expressed in terms that do not name the layer
> below.**

`scratch` / `fast` / `bulk` are the exemplar. They name *guarantees* —
disposable, low-latency, sequential-and-large — not disks, paths or provisioners.
That is why the k3s → Talos cutover left them untouched, why the planned Longhorn
migration leaves them untouched, and why `target-architecture.md`'s invariant 3
(*"storage classes name guarantees, not implementations"*) is this invariant
stated for one layer.

The rule that keeps it true: **a change that forces an edit in the layer above is
a boundary violation, and gets recorded as one** — not silently absorbed. §5 is
that record.

## 4. The evidence: this boundary has been tested three times

### 4.1 D18 — k3s to Talos, executed 2026-08-16

The node platform was replaced underneath a running platform. App authors saw
nothing. D18 called that *"the strongest available evidence the self-service
abstraction (D15) was drawn in the right place."* **Infrastructure changed;
Platform API did not.**

### 4.2 D20 — hypervisor to bare metal, designed

Six files in `infrastructure/` change. The Platform API's **spec surface** is
nearly untouched: one visible change (`Application.spec.host` gains a cluster
suffix) and one semantic one (`persistence.size` becomes a real limit). Full
accounting in `platform-api-under-d20.md`.

The ADR originally overclaimed this as *"`infrastructure/` is untouched, not one
file"* and was corrected. **The corrected version is the more useful claim,
because it is the one that distinguishes the layers:** the implementation moved,
the contract mostly did not.

### 4.3 The Fleet investigations — 2026-08-31, and the cleanest test yet

Four investigations, all resolved, **none of which produced a single change in
`infrastructure/` or `platform-api/`:**

| Investigation | Outcome | Reached Infrastructure? |
| --- | --- | --- |
| `metal3-investigation.md` | Rejected — BMC-gated, and Talos cannot read its config drive | no |
| `tinkerbell-investigation.md` | Right project, wrong time; adopt as Smee + `Hardware` | no |
| Tinkerbell + Cluster API | Rejected — CAPT hard-requires cloud-init | no |
| `hardware-fit-notes.md` | Fleet is two mismatched machines, no BMC anywhere | **once — see §5** |

Three of the four are pure Fleet-layer work that the layers above cannot observe.
**That is the boundary doing its job**, and it is why this document is worth
writing rather than assuming.

### 4.4 The boundary is enforced, not just described

`clusters/homelab/` carries four Flux Kustomizations, and
`infrastructure-platform-api` declares `dependsOn: [infrastructure]`. **The
Platform API layer already cannot reconcile before the Infrastructure layer
does.** That dependency was added for a cold-apply ordering reason (the RGDs'
CRD ships with the kro HelmRelease), not as an architectural statement — but it
is the layer boundary, expressed in the one place that actually enforces
anything.

## 5. Where it leaks

An architecture document that claims only clean boundaries is marketing. These
are the real leaks, each with its direction:

| Leak | Direction |
| --- | --- |
| `Application.spec.host` gains a cluster suffix | Infrastructure → Platform API |
| `persistence.size` stops being documentation and becomes a real limit under Longhorn | Infrastructure → Platform API |
| `replicas > 1` and `persistence` become mutually exclusive (RWO means one node) | Infrastructure → Platform API |
| Per-`Application` `NetworkPolicy` keys on Tailscale `parent-resource` labels, so moving to a `ProxyGroup` breaks every instance at once | Infrastructure → Platform API |
| **`bulk` cannot reach its specified 2 replicas, because the fleet contains exactly one HDD** | **Fleet → Platform API, skipping Infrastructure** |

**The last one is the sharpest, and it is new.** `target-architecture.md` §5.1
specifies `bulk` at two replicas; `hardware-fit-notes.md` §5 establishes that
only machine 1 has a spinning disk. A *hardware inventory fact* therefore reaches
a *durability promise made to app authors* without passing through the
Infrastructure layer that is supposed to absorb exactly this. It is fixable with
a £30 drive — but the interesting part is not the fix, it is that **a two-layer
jump is the failure mode this architecture is least protected against**, and
nothing before now would have caught it.

Worth stating plainly: four of these five are Infrastructure → Platform API, and
all four arrive with the same change (the Longhorn migration). **Leaks cluster at
migrations**, which is an argument for landing D20's Platform API changes in one
revision, as `platform-api-under-d20.md` already recommends.

## 6. Where the repo layout disagrees with the layering

`infrastructure/platform-api/` is a Platform API directory living inside an
Infrastructure one. The directory tree predates the layering and does not express
it.

**Do not move it.** The boundary that matters is already enforced by the separate
Flux Kustomization (§4.4), which `platform-api/`, `seaweedfs-runtime/` and
`tailscale-runtime/` each have. A directory move would churn every path in
`clusters/homelab/`, every cross-reference in `docs/`, and AGENT.md, to make the
tree agree with a diagram — while changing nothing about what reconciles in what
order. Note the mismatch, keep the Kustomization split as the real boundary, and
spend the effort elsewhere.

## 7. What each layer may assume

Stated so a future change can be checked against it rather than argued about.

**Fleet may assume:** nothing from above. It is the bottom. It may *not* assume
any particular machine class — `hardware-fit-notes.md` is what happens when a
design assumes uniform mini-PCs and the fleet turns out to be a laptop and an
SFF desktop.

**Infrastructure may assume:** N Kubernetes nodes exist; each node's disks are
identifiable by *role* rather than path; all nodes share one network. It may
**not** assume node count, machine model, disk size, or that any two nodes are
comparable.

**Platform API may assume:** storage classes named by guarantee; an ingress that
supplies identity; a policy backend that enforces; a metrics pipeline. It may
**not** assume node count, storage implementation, replica counts, or that any
volume is on a particular tier of hardware.

**The rule.** If a change requires the layer above to change too, that is not
automatically wrong — but it is a boundary violation, and it goes in §5 with its
direction, rather than being absorbed quietly.

---

## Related

- `docs/adr/0001-single-model-talos-fleet.md` — D20, a **Fleet + Infrastructure**
  decision; its §10 is this document's §4 argued before the layers had names
- `docs/fleet/target-architecture.md` — the detailed build-out of the Fleet and
  Infrastructure layers under D20
- `docs/fleet/platform-api-under-d20.md` — the Infrastructure → Platform API
  boundary, priced
- `docs/fleet/inventory-and-provisioning-approach.md` — the Fleet →
  Infrastructure boundary, and why inventory splits across it
- `docs/fleet/fleet-control-plane-survey.md` — its "five planes" decompose the
  **Fleet layer**, one level below this document
- `CONCEPT.md` §11 D1 — "Layer 0/1/2" is the *thickness* of the Platform API
  layer, not a sibling of these three
