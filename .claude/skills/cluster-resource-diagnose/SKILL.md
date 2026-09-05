---
name: cluster-resource-diagnose
description: Diagnose whether a workload on the homelab k3s cluster actually has enough CPU/memory, versus just using more than its request. Use this whenever asked to check resource usage/capacity, whether something "has enough resources" or can "handle the load", investigate probe failures/restarts/OOMKills, size or re-size a HelmRelease's `resources:` block, or check Prometheus cardinality. Ends with a concrete resources-block fix, landed the repo's normal way.
---

# Cluster resource diagnosis

Single-node k3s homelab, `kubectl` needs an explicit kubeconfig (`KUBECONFIG` is
unset in this shell): pass `--kubeconfig ~/.kube/config` on every call, or
`export KUBECONFIG=~/.kube/config` once per session.

## 1. Node-level headroom

```
kubectl --kubeconfig ~/.kube/config top nodes
kubectl --kubeconfig ~/.kube/config get node <node> -o jsonpath='{.status.allocatable.memory} {.status.allocatable.cpu}{"\n"}'
```

Cross-check against observability's own hard budget cap: ~20% of the
machine, ~3GB. Sum the `resources.limits` of everything under
`infrastructure/observability/helmrelease.yaml` before treating a bump as free
— it should stay under that budget, not just under total node capacity.

## 2. Pod-level usage vs. configured requests/limits

```
kubectl --kubeconfig ~/.kube/config top pods -A --containers | sort -k4 -h -r | head -20
```

For a specific suspect, get what's actually applied to the live pod (not just
what's in git — confirm Flux has reconciled the values you're reading):

```
kubectl --kubeconfig ~/.kube/config get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].resources}'
```

`kubectl top` on a multi-container pod (e.g. Grafana's `sc-dashboard`/
`sc-datasources` sidecars) aggregates all containers — always re-run with
`--containers` to find which one is actually the bottleneck before touching
any resources block.

## 3. Live symptoms, not just snapshots

A container using more than its *request* is normal and not a problem by
itself — requests only affect scheduling. What actually indicates starvation:

- CPU usage sitting at or above the *limit* (throttled, not just busy).
- Memory usage within ~5-10% of the *limit* (heading for OOMKill).
- Recent restarts:
  ```
  kubectl --kubeconfig ~/.kube/config get pod <pod> -n <ns> -o jsonpath='{range .status.containerStatuses[*]}{.name}{" ready="}{.ready}{" restarts="}{.restartCount}{"\n"}{end}'
  kubectl --kubeconfig ~/.kube/config get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
  ```
- Live events, most recent first — `Unhealthy`, `OOMKilled`, `BackOff` are the
  signal, a lone old event isn't:
  ```
  kubectl --kubeconfig ~/.kube/config get events -n <ns> --field-selector involvedObject.name=<pod> --sort-by='.lastTimestamp' | tail -20
  ```

Note that `lastState.terminated.reason` can read `Unknown` with `exitCode: 255`
for what was actually an OOM-driven kill — don't rule out memory pressure just
because the reason field doesn't literally say `OOMKilled`; corroborate with
the events list and the memory-vs-limit comparison instead.

## 4. Prometheus-specific: is it a sizing problem or a cardinality problem?

Before assuming a `resources` bump fixes Prometheus, check whether growth is
actually about how much data exists, not how fast it's processed:

```
kubectl --kubeconfig ~/.kube/config port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090 &
PF=$!; sleep 2
curl -s http://localhost:9090/api/v1/status/tsdb | python3 -m json.tool
kill $PF
```

`headStats.numSeries` and `seriesCountByMetricName` show where cardinality
actually comes from. Pre-existing kubelet/cAdvisor scrape jobs routinely
dominate (tens of thousands of series) — don't attribute growth to a newly
added `ServiceMonitor`/`PodMonitor` without checking whether it's actually a
small fraction of the total.

**Always kill any port-forward you start** (`kill $PF` — don't leave it
running in the background across turns).

## 5. Decide, then fix

If usage is genuinely pinned at the limit with live probe failures/restarts —
not just "higher than the request" — bump the relevant `resources:` block
under `infrastructure/<component>/helmrelease.yaml`. Follow this repo's
existing convention: leave a dated comment explaining *why* the number
changed (what was observed, not just the new value — see the existing Grafana
OOM comment in `infrastructure/observability/helmrelease.yaml` for the style
to match). Re-check the observability budget sum from step 1 after the change.

Land it the normal way for this repo: branch → commit → `gh pr create` →
user merges. Never edit and leave live-applied via `kubectl edit`/`kubectl
patch` as the persisted fix — that's for the diagnosis step only, not for
resource-limit changes, which belong in git so Flux reconciles them.

## 6. Verify after rollout

```
kubectl --kubeconfig ~/.kube/config rollout status deployment/<name> -n <ns>
kubectl --kubeconfig ~/.kube/config top pod <new-pod> -n <ns> --containers
kubectl --kubeconfig ~/.kube/config get events -n <ns> --field-selector involvedObject.name=<new-pod> --sort-by='.lastTimestamp'
```

Confirm usage now sits comfortably under the new limit and no fresh
`Unhealthy`/restart events appear — don't declare it fixed from the diff
alone.
