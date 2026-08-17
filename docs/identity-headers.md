# Tailscale identity headers — the app-side contract

What an application running on this platform may assume about *who is calling*,
and what it must not.

This is the app-repo-facing half of the work. The platform-side half — the
`NetworkPolicy` that makes any of it true — is rendered automatically by the
`Application` RGD and needs nothing from the app.

## What arrives

Every request that reaches an `Application` through its `tailscale` Ingress
carries three headers, injected by the Tailscale proxy with no configuration on
either side:

| Header | Contents |
| --- | --- |
| `Tailscale-User-Login` | the caller's tailnet login, e.g. `someone@example.com` |
| `Tailscale-User-Name` | display name |
| `Tailscale-User-Profile-Pic` | avatar URL |

`Tailscale-User-Login` is the one to key on. The other two are presentation.

## What makes them trustworthy

Tailscale's guidance is that these headers can be believed only when the backend
cannot be reached except through the proxy. Its stated form of that — "have the
service listen on localhost" — has no Kubernetes equivalent, and on a flat pod
network any pod in the cluster could otherwise hit the app's Service directly
and set the header to anything.

The substitute is a `NetworkPolicy` restricting ingress to the app's own proxy
pod. **Every `Application` gets one automatically** (revision 5 of the RGD,
`infrastructure/platform-api/rgd-application.yaml`), and it is not optional or
opt-in. Verified live on 2026-08-17 — a pod in another namespace was denied on
the Service ClusterIP, on the pod IP, and with a spoofed header, while the
tailnet path kept returning 200:

```
header-forge-test/attacker:33550 <> fastapi-echo/fastapi-echo-...:8000
  policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
```

Two consequences worth stating outright:

- **This is only true on this platform.** The same app run anywhere else, or
  reached by any path that is not its Tailscale Ingress, has no such guarantee.
  The header is a platform-provided fact, not a property of the request.
- **It rests on one policy per app plus one cluster-wide file.** See
  `docs/networkpolicy-enforcement-notes.md`; policy enforces here only because
  `infrastructure/cilium/` exists, and only for pods created after it.

## The rules an app must follow

### 1. Absence is "unauthenticated", never an error

The headers are **not populated** in three real cases:

- **Tagged devices.** Anything authenticating as a tag — `tag:ci` in
  particular — arrives with no identity headers at all. This is the case that
  bites first, because the first CI call to a new endpoint looks like a bug.
- **Funnel traffic.** Nothing here uses Funnel today, but enabling it on an
  exposure silently strips the identity the app was relying on.
- **Any non-proxy path**, which after the lockdown means Prometheus scraping
  `/metrics` and nothing else.

So: a missing `Tailscale-User-Login` means *no user identity was established*.
Treat it as an anonymous request and apply whatever the app's anonymous policy
is. Do not 500, and do not fall back to a default user.

### 2. Do not parse it as anything but an opaque string

It is a tailnet login. Do not split it on `@` and trust the domain, and do not
assume it is stable enough to be a database primary key on its own — it changes
if the user's tailnet identity changes.

### 3. Display and audit are free; authorisation is a decision

Showing "signed in as someone@example.com" and stamping it into an audit log
needed nothing from anyone and was safe even before the lockdown landed — the
worst case was a wrong name in a log.

Authorising on it — "this login may delete records" — is what the lockdown makes
possible. If an app takes that step, it inherits the platform's blast radius: the
app's access control is now only as good as the `NetworkPolicy` and the proxy in
front of it. Say so in the app's own README, so that a later move off this
platform is not a silent loss of a security control.

### 4. There is no group, role, or scope in the header

Tailscale sends who, not what-they-may-do. Any role model is the app's own, keyed
on the login. Tailnet-level *reachability* scoping — which devices may reach the
app's port at all — lives in `tailscale-acl/policy.hujson` and is a separate,
coarser control that the app never sees.

## What the policy actually permits

For an `Application` named `foo` in namespace `foo` on port 8000:

- **In:** TCP 8000 from `tailscale/ts-foo-*` — the proxy pod labelled
  `tailscale.com/parent-resource=foo`, `parent-resource-ns=foo`,
  `parent-resource-type=ingress`. That app's own proxy, not any other app's.
- **In:** TCP 8000 from the `observability` namespace, so Prometheus can scrape
  an app that sets `spec.metrics.enabled`.
- **In:** the kubelet's probes, from `10.244.0.1`, via the cluster-wide
  `infrastructure/cilium/allow-node-to-pods.yaml`. Not in this policy, and
  deleting that file crash-loops every `Application` on the cluster.
- **Out:** everything. No egress rules — the app reaches its database, its
  bucket, DNS and the internet exactly as before.
- An attached `Database`'s CNPG pods are in the same namespace but carry
  different labels, are not selected, and are unaffected.

## If an app breaks after this lands

In order of likelihood:

1. **Something other than the proxy was calling it.** Another app using it as an
   internal API is the realistic case. That needs an additive `spec.allowFrom`
   on the `Application` API — file it rather than hand-writing a policy in the
   app repo, which would drift out of the platform's privilege documents.
2. **The app is crash-looping on probe timeouts.** That is the kubelet-probe
   trap, not the app. `kubectl describe pod` names only the probe and never the
   policy; `kubectl exec -n kube-system ds/cilium -- hubble observe --type drop`
   is where the cause is.
3. **The pod predates the Cilium DaemonSet**, in which case the policy does not
   apply to it at all and it is *more* reachable than it looks. Restart it.
