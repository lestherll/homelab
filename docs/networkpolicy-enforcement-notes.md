# NetworkPolicy enforcement notes

Why `infrastructure/cilium/` exists, what it does and does not change, and what
to check when a policy does not behave.

## The finding

Until this component landed, **every `NetworkPolicy` on this cluster was inert.**
The API server accepted them, `kubectl get netpol` listed them, and they
enforced nothing.

The cause is the CNI. Talos defaults to Flannel — `kube-flannel` in
`kube-system`, present because `terraform/` never sets
`cluster.network.cni.name` — and Flannel implements pod networking only. It has
no policy backend. There is no admission error, no controller log line, no
condition on the object: the only way to discover it is to test a deny and watch
the traffic go through anyway.

Verified live on 2026-08-17 in a throwaway `netpol-test` namespace: a `target`
pod serving nginx behind a Service, a `client` pod, and a `default-deny-ingress`
policy selecting everything. `client` fetched `http://target` successfully both
before and after the policy was applied and settled.

**Do not read a NetworkPolicy manifest older than this document as evidence that
anything was ever enforced.** That includes the three policies Flux ships into
`flux-system`, which had never restricted anything here.

## What was done

Cilium in **CNI chaining** mode — `generic-veth` — not a CNI replacement.
Flannel keeps routing, IPAM and masquerading; Cilium attaches eBPF programs to
the veth pairs Flannel already created, and does policy and observability only.

The mechanism is a conflist. `infrastructure/cilium/cni-configuration.yaml`
holds Flannel's own conflist (copied verbatim off the node) with a third
`cilium-cni` plugin entry appended. Cilium's install container writes that file
to `/etc/cni/net.d/05-cilium.conflist`; kubelet uses the lexically first conflist
in that directory, so `05-` wins and Flannel's `10-flannel.conflist` stays on
disk unused.

### Why not replace Flannel

The clean end state is full Cilium with `cluster.network.cni.name: none`, and it
was rejected on this topology. Every no-downtime migration writeup depends on
running both CNIs on separate node pools and draining across, which needs a
second node. Here it means a `NotReady` node and roughly a ten-minute window to
land Cilium before the kubelet gives up — a real chance of a rebuild of the
cluster's only node, to enforce a handful of ingress rules.

Calico in policy-only mode (Canal) is exactly the intended shape, but the Canal
project was archived in October 2025, and adopting an archived integration as a
security control is a poor trade when chaining is current and maintained.

Chaining gives up L7 policy and IPsec transparent encryption. Plain Kubernetes
`NetworkPolicy` — all that is wanted here — works fully.

## Traps

- **A pod that predates Cilium is not managed by it.** Chaining takes effect
  when the CNI runs, which is at pod creation. Pods already running when Cilium
  was installed keep working and stay reachable, but **no policy applies to
  them**, and there is no indication of this on the pod. They must be restarted.
  This is the failure mode to suspect first when a policy appears not to apply
  to one specific workload: check the pod's age against the Cilium DaemonSet's.
- **The conflist `name` must stay `cbr0`.** It is Flannel's, the CNI result is
  keyed on it, and a mismatch fails at pod creation rather than at apply.
- **The first two plugin entries are Flannel's, verbatim.** This file *replaces*
  Flannel's config rather than being merged with it, so anything dropped there
  is a capability the cluster silently loses — `portmap` in particular is what
  makes `hostPort` work.
- **`cni.exclusive` is deliberately `false`.** See the comment in
  `helmrelease.yaml`: the default would rename Flannel's conflist away, and on a
  node with no shell that removes the way back from a broken Cilium.
- **No Talos machine-config change and no reboot.** Chaining grafts on through a
  ConfigMap, so this lands through Flux like any other component. That is most
  of why it was the affordable option.

## The kubelet-probe trap

**A default-deny ingress policy blocks the kubelet's own liveness and readiness
probes, and the workload dies while the process inside it is perfectly healthy.**
`infrastructure/cilium/allow-node-to-pods.yaml` is what stops that, and it is
load-bearing for every policy anyone writes here.

The intuition that gets this wrong — the one this repo held until it was
disproved — is "probes come from the host netns, and Cilium allows the `host`
identity by default." Chaining is what makes it false. Cilium learns the node's
addresses from the Node object and from the devices it manages, and under
chaining it manages neither Flannel's bridge nor its address. Probes arrive from
`cni0` at `10.244.0.1` and are classified **`world`** — indistinguishable from
traffic off the internet.

It was found by doing it. Restarting Flux's four controllers under its own,
previously inert, `allow-egress` policy put every one of them into a probe-driven
crash loop while their logs showed normal reconciliation throughout:

```
10.244.0.1:50492 (world) <> flux-system/notification-controller:9440
  Policy denied DROPPED (TCP Flags: SYN)
```

That is the signature. **A workload that crash-loops on probe timeouts shortly
after a policy starts selecting it is this, not the workload** — and note the
`kubectl describe` message names only the probe, so the policy is not mentioned
anywhere in the obvious place to look. `hubble observe --type drop` is.

The fix is one address (`10.244.0.1/32`, the node's gateway on the pod network),
allowed cluster-wide to all endpoints. It is a `CiliumClusterwideNetworkPolicy`
because a plain `NetworkPolicy` cannot express it: `ipBlock` only means anything
next to a rule that already selects the pods, so it would have to be copied into
every policy ever written here and remembered for every new namespace.

### A broad allow is a cluster-wide deny unless you say otherwise

The `enableDefaultDeny: {ingress: false, egress: false}` block in that file is
load-bearing, and leaving it out is the single most destructive mistake
available here. **Cilium switches on default-deny for any direction a policy
writes rules in**, and `endpointSelector: {}` selects every endpoint in the
cluster — so a policy written purely to *allow* one address instead denied all
ingress everywhere, with the node as the only permitted source. It was written
that way first, and that is what happened.

It did not look like a policy problem. It looked like DNS: every Flux controller
failing with `lookup source-controller.flux-system.svc... on 10.96.0.10:53: i/o
timeout`, because CoreDNS had been swept into default-deny too and was dropping
their queries. Nothing in that error names a NetworkPolicy.

Two habits follow. Pair any broad `endpointSelector` with an explicit
`enableDefaultDeny: false`, and when connectivity breaks cluster-wide shortly
after a policy change, check `kubectl get ccnp,cnp -A` before believing the
symptom.

## Editing policy on the live cluster

**Hand-apply and a background reconcile will fight, and the reconcile wins
silently.** The `enableDefaultDeny` fix above was applied by hand to recover the
cluster, reverted by Flux minutes later, and the identical failure then
reappeared looking like a fresh and unrelated one. Recovering a live cluster is
exactly when this is easiest to forget, because the change feels urgent rather
than experimental.

Worse, policy has a bootstrap loop the rest of the repo does not: Flux needs DNS
to fetch the fix, and the broken policy is what breaks DNS, so a plain
`flux resume` re-applies the last-known-bad revision and re-breaks the thing it
needs to recover. Breaking the loop takes a specific order:

```bash
flux suspend kustomization infrastructure
kubectl apply -f infrastructure/cilium/allow-node-to-pods.yaml   # restore DNS
flux reconcile source git flux-system                            # fetch the fix while DNS works
flux resume kustomization infrastructure                         # now applies the good revision
```

## The three `flux-system` policies

Flux installs `allow-egress`, `allow-scraping` and `allow-webhooks` into its own
namespace. Enforcement turning on changes their meaning from decoration to
control, so they were audited rather than assumed:

| Policy | Effect once live |
| --- | --- |
| `allow-egress` | All ingress from within `flux-system`; all egress anywhere. |
| `allow-scraping` | Ingress on TCP 8080 from any namespace — the controllers' metrics port, which is what `observability`'s Prometheus scrapes. |
| `allow-webhooks` | All ingress to `notification-controller` from any namespace — inbound `Receiver` webhooks. |

They are correct as written and were left alone — but note they are also what
found the kubelet-probe trap above, since restarting the controllers under them
was the first time anything on this cluster was subject to a real default-deny.
They only work because `allow-node-to-pods` exists.

## Verifying enforcement

The test that found the problem is also the test that proves the fix, and the
**negative case must actually fail** before believing any of this:

```bash
kubectl create ns netpol-test
kubectl -n netpol-test run target --image=nginx --port=80 --labels=app=target
kubectl -n netpol-test expose pod target --port=80
kubectl -n netpol-test run client --image=curlimages/curl --command -- sleep 3600
kubectl -n netpol-test wait --for=condition=ready pod/target pod/client --timeout=120s

# positive: succeeds
kubectl -n netpol-test exec client -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://target

kubectl -n netpol-test apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF

# negative: must now TIME OUT. Before Cilium this returned 200.
kubectl -n netpol-test exec client -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://target

kubectl delete ns netpol-test
```

Note both pods are created *after* Cilium, which is what makes the test valid.

Why a verdict was allowed or dropped is answerable without re-running anything:

```bash
kubectl exec -n kube-system ds/cilium -- hubble observe --type policy-verdict --last 50
kubectl exec -n kube-system ds/cilium -- hubble observe --type drop --last 50
```

Hubble's policy-verdict and drop metrics are also exported to Prometheus
(`hubble_policy_verdicts_total`, `hubble_drop_total`). That is there on purpose:
this failure was invisible precisely because a policy that enforces nothing looks
identical to a policy that allows everything, and metrics make the difference
observable rather than something to rediscover by experiment.
