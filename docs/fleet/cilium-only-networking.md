# Cilium as the only CNI — yes, and it removes more than it adds

**Status: recommendation, 2026-09-01. Not built.** Answers "can we run Cilium
alone in the new architecture?" — asked because the current design maintains
three networking components and the goal is to maintain fewer.

**Answer: yes. Cilium replaces both Flannel and kube-proxy, and the change is a
net deletion.** Two Talos-managed components disappear, two files in
`infrastructure/cilium/` are deleted, and one documented workaround in
`talos.tf` becomes unnecessary. There is exactly one real cost (§4), and one
scheduling constraint that matters more than the cost (§3).

---

## 1. What exists today, and why

Cilium runs in `generic-veth` **chaining** mode over Flannel. It was added for
one reason: Talos defaults to Flannel, Flannel has no policy backend, so every
`NetworkPolicy` in the repo was inert until Cilium landed
(`docs/networkpolicy-enforcement-notes.md`). Cilium attaches eBPF policy programs
to veths Flannel creates; **Flannel keeps IPAM, routing and masquerading, and
kube-proxy keeps service load-balancing.**

Three components, three failure surfaces, and two files of pure glue holding them
together.

## 2. What Cilium-only looks like

Two Talos machine-config changes:

```
cluster.network.cni.name: none      # stop rendering Flannel
cluster.proxy.disabled: true        # stop rendering kube-proxy
```

And a simpler HelmRelease. The changes, against
`infrastructure/cilium/helmrelease.yaml` as it stands:

| Value | Today | Cilium-only |
| --- | --- | --- |
| `cni.chainingMode` / `customConf` / `configMap` / `exclusive` | set, 4 keys | **removed** |
| `kubeProxyReplacement` | `false` | **`true`** |
| `enableIPv4Masquerade` | `false` (Flannel does it) | **`true`** |
| `bpf.hostLegacyRouting` | `true` (chaining artefact) | **removed** |
| `routingMode` | `native` | `native` + `autoDirectNodeRoutes: true` |
| `ipam.mode` | `kubernetes` | **unchanged** |
| `k8sServiceHost` / `k8sServicePort` | `localhost` / `7445` | **unchanged** |

Two of those rows are worth dwelling on, because they are why this is cheap here
and expensive elsewhere:

- **`k8sServiceHost: localhost:7445` is already correct.** That is Talos's
  **KubePrism**, and pointing Cilium at it is exactly what
  `kubeProxyReplacement: true` requires — Cilium needs to reach the API server
  before it has replaced the service that would let it reach the API server.
  The repo already configured its way out of that chicken-and-egg, for a
  different reason. Nothing to do.
- **`ipam.mode: kubernetes` stays**, so Talos keeps allocating node pod CIDRs and
  **the pod network does not renumber.** This is not a re-addressing exercise.

`autoDirectNodeRoutes: true` is valid because D20 puts every machine on one
bridged LAN (`target-architecture.md` §4). Nodes are L2-adjacent, so pod traffic
routes directly with no overlay. On a topology where that stopped being true, the
fallback is tunnel mode — a one-value change, not a redesign.

## 3. What gets deleted — the actual answer to "I don't want to maintain many things"

| Deleted | Why it existed |
| --- | --- |
| **Flannel** | Talos default; the only reason Cilium had to chain |
| **kube-proxy** | Superseded by `kubeProxyReplacement` |
| `infrastructure/cilium/cni-configuration.yaml` | The hand-maintained chained conflist — a byte-for-byte copy of Flannel's config that had to stay in sync with it |
| `infrastructure/cilium/allow-node-to-pods.yaml` | A `CiliumClusterwideNetworkPolicy` that exists **only** because chaining misclassifies kubelet probes |
| The `proxy.extraArgs.metrics-bind-address = "0.0.0.0"` block in `talos.tf` | ~35 lines of comment and config working around kube-proxy's ServiceMonitor |

`infrastructure/cilium/` goes from four files to two.

**Two of these deletions were predicted in the repo already.** `allow-node-to-pods.yaml`
ends with:

> *"If Flannel is ever replaced by Cilium outright, this becomes unnecessary —
> Cilium would own the bridge and classify the address as `host`. Delete it then,
> and re-run a probe-dependent workload under a default-deny to confirm."*

And `cni-configuration.yaml` exists only to hold Flannel's conflist plus a
`cilium-cni` entry. With no Flannel there is no conflist to shadow.

One swap rather than a deletion: kube-prometheus-stack ships a kube-proxy
`ServiceMonitor` enabled by default, which is what forced the `talos.tf`
workaround. With kube-proxy gone that becomes `kubeProxy.enabled: false` in
`infrastructure/observability/helmrelease.yaml` — one line, replacing a
bind-address hack that carries its own "does not retrofit" caveat.

**Compatibility checked, not assumed.** The chained conflist carries `portmap`,
and its comment notes *"portmap in particular is what makes hostPort work."*
Nothing in `infrastructure/` uses `hostPort` — node-exporter uses `hostNetwork`,
which is CNI-independent. And `kubeProxyReplacement: true` implements `hostPort`
in eBPF anyway, so the capability survives its plugin.

## 4. The one real cost: the fallback goes away

Today Cilium is **additive**. If it fails or is removed, Flannel's
`10-flannel.conflist` is still on disk and the cluster keeps routing — without
policy enforcement, but working. `cni-configuration.yaml` says so explicitly:
Flannel's conflist *"stays on disk, unused, as the fallback if Cilium is ever
removed."*

Cilium-only ends that. **A Cilium failure becomes a total network failure**, and
because `kubeProxyReplacement: true` also puts service routing in its datapath,
the blast radius includes reaching the API server from pods. KubePrism keeps the
*node's* path to the API server independent, which is what makes recovery
possible, but there is no longer a degraded-but-working mode.

That is the honest trade, and it is the standard one: **one component that must
work, instead of three that must agree.** For a fleet where the operator's stated
goal is fewer things to maintain, one is the better number — but it should be a
decision, not a side effect.

## 5. Why this must ride the §4.1 rebuild

**This is the part with a deadline.** `cluster.network.cni.name` and
`cluster.proxy.disabled` change Talos **bootstrap manifests**, and AGENT.md
records that those *do not retrofit a running cluster*: Talos re-renders them,
reports no error, and leaves the live objects untouched. Verified on v1.13.8.

So Cilium-only lands on a rebuild, or it lands as manual DaemonSet surgery on a
live cluster. ADR §4.1 collects exactly this class of change — *"everything that
gets baked in… cheap now, a rebuild later"* — and **its list does not currently
include the CNI**. Spending the rebuild on the VIP, `certSANs`, extensions and
discovery, and then discovering the CNI needed the same window, is the failure
§4.1 exists to prevent.

## 5.1 The cluster can no longer bootstrap itself, and Terraform must seed it

**Found 2026-09-02, and it is the missing half of §5.** With
`cluster.network.cni.name: none`, Talos stops rendering a CNI — and nothing else
starts rendering one. Three consequences, in order of how fast they bite:

- **The node is `NotReady`.** A node goes Ready only once a CNI is up.
- **Talos does not wait patiently.** Bootstrap stalls in the high teens of its
  phase sequence and **the node reboots to retry roughly every 10 minutes**.
  There is no leisurely window between `terraform apply` and `flux bootstrap` in
  which to install Cilium by hand.
- **Flux cannot be the thing that fixes it.** Flux's controllers are ordinary
  pods and need pod networking, so **Flux cannot install the CNI that Flux needs
  in order to run**. This circularity is new: with Flannel, Talos rendered the
  CNI itself, so the question never arose.

**The seed goes in `cluster.inlineManifests`** — present in the v1.13.8 schema
alongside `extraManifests`, applied by Talos during bootstrap, which is inside
Terraform's window rather than Flux's. Sidero's own Cilium guide gives the
constraint: put the inline manifest on **control-plane machine configs only**,
and keep them identical across control planes.

One property keeps this from becoming an ownership fight: **Talos only *creates*
missing resources from inline manifests — it never updates or deletes them.**
That is AGENT.md's bootstrap-manifest gotcha, and here it works in our favour.
The inline manifest is a one-shot seed; the `HelmRelease` in
`infrastructure/cilium/` owns Cilium from the moment Flux is up.

**Seed the minimum.** The inline manifest has exactly one job: make nodes Ready
so Flux can start. Leave `kubeProxyReplacement`, `autoDirectNodeRoutes` and the
policy configuration to the `HelmRelease`. A minimal seed never needs to stay in
sync with the chart; a full one would, and would rot silently — the seed is
applied once and then never reconciled again.

**This moves a layer boundary, and it should be recorded rather than absorbed.**
Terraform's contract stops being *"an empty cluster"* and becomes *"a cluster
with a CNI"*. In `golden-architecture.md` §5's terms that is an
**Infrastructure → Fleet** leak, and every leak currently in that table points
the other way. Its §7 rule says exactly what to do with it: put it in the table
with its direction. This should also be the **only** such exception — no
`kubernetes` provider, no `helm` provider, nothing else from `infrastructure/`
pulled down into Terraform.

Full sequencing in
[terraform-on-bare-metal.md §5](terraform-on-bare-metal.md).

## 6. A later consolidation this unlocks

Worth recording because it removes a component the fleet notes assume will be
needed: **Cilium L2 Announcements can serve `LoadBalancer` IPs on the LAN**,
which is otherwise a reason to introduce MetalLB or kube-vip. Both
`inventory-and-provisioning-approach.md` and `tinkerbell-investigation.md` §8
flag that gap — Tinkerbell's Smee needs an L2-reachable address, and its chart
defaults to a `kube-vip` load-balancer class this repo does not run.

Not part of this change, and not needed until something wants a
`LoadBalancer`. But it means the answer to that future question is a Cilium
value, not another component.

## 7. Recommendation

1. **Adopt Cilium-only, and add it to ADR §4.1's rebuild list** so it rides the
   one rebuild rather than forcing a second.
2. Keep `ipam.mode: kubernetes` and the existing `k8sServiceHost`/`Port` — the
   pod network does not renumber and KubePrism is already correct.
3. **Add the `inlineManifests` Cilium seed to the machine config in the same
   change** (§5.1). Without it the rebuilt node never reaches Ready and reboots
   every ten minutes, and Flux cannot rescue it — this is not a follow-up item,
   it is part of making the cluster come up at all.
4. Delete `cni-configuration.yaml` and `allow-node-to-pods.yaml` **in the same
   change**, not as follow-ups. Both are chaining artefacts and both become
   actively misleading once Flannel is gone.
5. Set `kubeProxy.enabled: false` in kube-prometheus-stack in the same change,
   and drop the `proxy.extraArgs` block from `talos.tf`.
6. **Re-run the enforcement test** in `docs/networkpolicy-enforcement-notes.md`
   afterwards — the positive *and* negative case. Policy enforcement is the
   reason Cilium is here at all, and this change replaces the entire datapath
   underneath it. Include a probe-dependent workload under a default-deny, which
   is what `allow-node-to-pods.yaml`'s own farewell note asks for.

---

## Related

- `docs/networkpolicy-enforcement-notes.md` — why Cilium exists here, the
  chaining mechanism, and the enforcement test to re-run
- `docs/adr/0001-single-model-talos-fleet.md` §4.1 — the one rebuild this must
  ride
- `docs/fleet/target-architecture.md` §4 — bridged networking, which is what
  makes `autoDirectNodeRoutes` valid
- `docs/fleet/golden-architecture.md` — this is an **Infrastructure**-layer
  change; no Platform API surface moves, which is the boundary test passing again
