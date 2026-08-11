# External consumer access to platform data services — investigation notes

Status: **investigation only, nothing built.** Records what was verified on the
live cluster on 2026-08-11, what it constrains, and what remains open. Distinct
from `self-service-platform-design-notes.md`, which covers D15/D16 — those are
about apps *inside* the platform. This is about consumers outside it.

## Context — the problem this is about

D15 delivered `Database`/`ObjectStorage`/`Application`. Every endpoint the
platform hands out is cluster-internal:

- `rgd-application.yaml` hardcodes `http://seaweed-s3.seaweedfs.svc:8333`.
- CloudNativePG's `<name>-app` Secret carries `uri` (`…@fastapi-echo-db-rw:5432/app`)
  and `fqdn-uri` (`…-rw.fastapi-echo.svc.cluster.local…`). Both verified by key
  listing on the live Secret.

So an app hosted off-platform — even one already on the tailnet — cannot use
either endpoint, and handing it the Secret verbatim would not help.

The coupling is two independent problems, and conflating them is what makes the
current API feel app-shaped:

1. **Reachability.** No endpoint is resolvable or routable from outside.
2. **Credential issuance.** For `Database` this is mild — CloudNativePG mints
   `<name>-app` on its own, and `Database.status.secretName` already publishes
   it. For `ObjectStorage` it is total: the `S3Identity`/`S3Credentials`/
   `S3Policy`/`S3PolicyBinding` quad lives inside `rgd-application.yaml`'s
   `forEach`, so **there is no way to obtain an S3 credential without declaring
   an `Application`** — i.e. without letting the platform run your workload.

## Design direction under consideration (not decided)

Three objects, matching how AWS/GCP/Heroku/Cloud Foundry/Crossplane all
decompose this, with the **binding as a first-class object** rather than a field
on either side:

- **Resource kinds** (`Database`, `ObjectStorage`, …) — provision, know nothing
  about consumers. Publish a uniform `status.endpoints`.
- **`ServiceBinding`** — one object = one scoped credential for one consumer.
  The *only* place credentials are minted, for every resource type.
- **`Application`** — consumes bindings, never mints them. Its existing
  `databases[]`/`objectStorage[]` attachment lists stay exactly as they are and
  render `ServiceBinding` objects instead of inlining credential logic.

An off-platform consumer then writes a `ServiceBinding` directly. No separate
"external consumer" kind is needed, because "is this consumer on the platform?"
stops being a question the API has to answer.

## A. kro mechanism — spiked, all green

Run against kro v0.9.3 on the live cluster with a throwaway `BindingSpike`/
`AppSpike` RGD pair (group `platform.homelab` so the existing
`rbac-kro-aggregate.yaml` grant applied; CRDs deleted afterwards, since
`config.allowCRDDeletion=false` means they survive RGD deletion).

| Question | Result |
|---|---|
| `includeWhen` gating two `externalRef` collections of **different kinds** | `GraphAccepted=True` — the static type checker allows it |
| Does a gated-off branch actually not render? | Confirmed — the off-branch objects were `NotFound` |
| Real value resolution through a gated collection | `fastapi-echo-db-app` and `personal-finance-dashboard-pfd-bucket` both resolved |
| **Uniform status field** reading whichever collection is active (CEL ternary) | Works — resolved correctly on both branches |
| **An RGD rendering another kro-generated CRD** via `forEach` | Works — one parent rendered 3 children of mixed kinds |
| Parent reading back child `status` | Works |
| Cascade delete, two levels | Clean — children and grandchildren removed, siblings untouched |

**Conclusion: one polymorphic `ServiceBinding` is expressible.** The fallback of
per-type binding kinds (`DatabaseBinding`/`ObjectStorageBinding`) is not needed.

Why the mixed-kind case works: the parent renders one *uniform* child kind and
each child gates itself, so `forEach` and `includeWhen` never appear on the same
resource entry — which matters, because kro already forbids `forEach` +
`externalRef` together (see `self-service-platform-design-notes.md` §5.1).

### Two constraints this surfaced

1. **kro cannot author Secrets, deliberately.** `rbac-kro-aggregate.yaml` grants
   secrets `get/list/watch` only, with the stated reason that nothing in this
   platform has kro authoring credentials "and keeping it read-only makes that
   checkable". A uniform binding-Secret contract would require kro to write one
   for the Database branch. The S3 branch is unaffected — SeaweedFS's
   `S3Credentials` mints that Secret, not kro.

   The resolution is already named in `rgd-database.yaml`'s own header comment:
   CloudNativePG's `DatabaseRole.clientCertificate`, which the operator
   auto-generates *and rotates*. That preserves the invariant, gives per-binding
   isolation, and dissolves the 1:1-consumer limitation at the same time. Costs
   `pg_hba` cert-auth config and driver TLS support. **Untested.**

2. **Unresolved references are silent, not loud.** A gated-off collection
   resolves to an *empty list*, not an error — indistinguishable from a
   reference that simply doesn't exist. A spike child pointing at a nonexistent
   `Database` reported `Ready=True` with an empty target. This is the same trap
   `Application.status.attachmentsResolved` already exists to catch, so
   `ServiceBinding` needs its own explicit `resolved`/`unresolvedRef` status from
   revision 1 — and per the printer-column gotcha, the column must be right the
   first time.

## B. Network and TLS — verified against the tailnet

Throwaway `Ingress` (S3) and `LoadBalancer` Service (Postgres) applied by hand,
tested, and deleted. Tailscale operator 1.98.9, tailnet `tailf4742d.ts.net`.

**Confirmed working:**

- **`loadBalancerClass: tailscale` exposes arbitrary TCP.** The CloudNativePG
  primary got both a tailnet IP and a MagicDNS name, port 5432 preserved. This
  was previously an assumption; it is now tested.
- **The L4 proxy carries the Postgres wire protocol end-to-end.** A full
  `openssl s_client -starttls postgres` handshake completed through it.
- **Postgres TLS is end-to-end; the proxy does not terminate it.** The
  certificate delivered over the tailnet is CloudNativePG's own.
- **The Tailscale Ingress terminates TLS with a valid public certificate**
  (`ssl_verify_result=0` — no `-k` needed), so S3 over the tailnet is real HTTPS.
- **Path-style S3 addressing survives the Ingress routing.** An unsigned request
  to `https://<host>/<bucket>` returned a proper S3 XML error with `<BucketName>`
  correctly parsed, so SeaweedFS received and parsed the path as expected.
- **SigV4 works over the tailnet, and prefix-scoped credentials work from
  outside the cluster.** A real signed request from a tailnet client — using the
  live `personal-finance-dashboard-data-s3` credentials, path-style addressing,
  against the `personal-finance-dashboard-data/` prefix — listed the expected
  object. So the *product* question is answered: an off-platform consumer on the
  tailnet can genuinely use this platform's S3 with the credentials the platform
  issues.

  **Important caveat on how this was measured.** It was run against the S3
  gateway exposed at **L4** (`loadBalancerClass: tailscale`, plain HTTP on 8333),
  *not* through the Tailscale Ingress — because Ingress exposure was blocked by
  the ACME failure below. An L4 proxy forwards raw TCP and never touches HTTP
  headers, so `Host` reaches SeaweedFS untouched by construction. **This
  therefore does not validate the L7/Ingress path**, which is the intended one
  (see below).

**Confirmed broken / constrained:**

- **`sslmode=verify-full` cannot work externally as things stand.** The
  CloudNativePG server certificate is `CN=fastapi-echo-db-rw` with SANs covering
  only `fastapi-echo-db-{rw,r,ro}` and their `.fastapi-echo[.svc[.cluster.local]]`
  forms. No tailnet name. Verified twice — from the `-server` Secret, and from a
  live TLS connection over the tailnet.
- **`verify-ca` requires distributing the cluster CA.** The chain is
  self-signed by an internal CA (`OU=fastapi-echo, CN=fastapi-echo-db`; OpenSSL
  verify error 19), so an external client needs `<cluster>-ca` shipped to it.
- **A declarative fix exists but is untested:**
  `clusters.postgresql.cnpg.io` exposes `spec.certificates.serverAltDNSNames`
  (array). Injecting the tailnet name there should make `verify-full` viable, and
  would imply a `Database` field.
- **MagicDNS does not resolve from inside a normal pod.** CoreDNS does not
  forward `.ts.net`; the node resolves it fine. Any in-cluster client of an
  external endpoint needs `dnsConfig`, and — more importantly for the actual use
  case — a containerised off-platform app will usually *not* inherit its host's
  MagicDNS resolver. That is a real DX cliff hiding behind "assume they're on the
  tailnet", and it needs a documented answer before this is offered to users.

### Unanticipated finding: `*.ts.net` certificate issuance is flaky and rate-limited

**Three** hostnames failed ACME DNS-01 with `WaitOrder: OrderError status
"invalid"` roughly one second after the `SetDNS` call completed — including one
that failed *before* any request was made to it, so this is not a
request-triggered race. Let's Encrypt then applied its "too many failed
authorizations (5) for <host> in the last 1h" limit per hostname, and the
retry-after window slid forward on each subsequent attempt.

Critically, **one of the three was a hostname that had issued successfully on
its first try earlier the same day** and then failed on a later recreate. So
this is not per-hostname bad luck or a misconfiguration in any one manifest.

**Which limit this was, precisely.** The 429s were
`too many failed authorizations (5) for <host> in the last 1h0m0s` — the
failed-authorization limit, a rolling one-hour window, whose retry-after we
watched slide forward on each further attempt. It was **not** the duplicate-
certificate limit (5 identical certs per 168h), which is the more commonly cited
Tailscale/Let's Encrypt trap and which would have meant a multi-day lockout. Worth
stating explicitly because the two have very different recovery times, and the
observed one recovers in minutes.

**The rate limit was a consequence, not the cause.** Each hostname's *first*
failure was `WaitOrder: OrderError status "invalid"` about one second after
`SetDNS` returned, with no 429 involved — Let's Encrypt attempted validation and
rejected it. The 429 only appeared after five such failures. The leading
hypothesis is that the `_acme-challenge` TXT record is not yet visible to Let's
Encrypt's validators at the moment they check, i.e. a propagation race that the
client does not wait out. Unconfirmed.

**What amplified it, and this part is confirmed.** The operator caches issued
certificates in the proxy's own state Secret — a live proxy's Secret contains
`<host>.crt`, `<host>.key` and `acme-account.key.pem` alongside its device
state. But that Secret is named `ts-<name>-<random>-0` and is created and
destroyed with the Ingress/Service it backs. **Deleting and recreating an
exposure therefore always produces a new, empty state Secret and an
unconditional fresh ACME order — there is no cross-recreate cert cache.** Five
recreates of the same hostname within an hour is enough to lock it out on its
own, independent of whatever is causing the underlying validation failure.

This makes the churn pattern a first-class design concern rather than a testing
artefact: a platform that creates and destroys a tailnet exposure per resource
is, structurally, a certificate-churn machine. The candidate fix is a
`ProxyGroup` — long-lived shared proxies whose state (and therefore cached
certs) outlives any individual Ingress or Service. Not yet tested.

**This is currently the blocker on the intended design, not a curiosity.** HTTPS
with a real certificate is the route this platform wants for S3 — an external
consumer's SDK should get a properly authenticated TLS endpoint, not plain HTTP
with "the tailnet is encrypted anyway" as the justification. That argument is
true but it is a fallback rationale, not a design goal, and it silently drops
server authentication and any prospect of using this outside a WireGuard mesh.

So the ACME failure has to be **root-caused and fixed**, not routed around. The
L4 exposure used above is a diagnostic that unblocked measurement; it is
explicitly *not* the chosen mechanism.

Secondary implications, still valid regardless of how ACME is fixed:

- expose the **shared** S3 gateway once rather than per-`ObjectStorage`
  (which the sharing model already implies — see `rgd-objectstorage.yaml`), and
- prefer `ProxyGroup`-shared proxies over a hostname per resource, and
- treat exposure as a deliberate, explicit act rather than a casual default —
  a platform minting a hostname per `Database` inherits these rate limits on
  every provision.

## C. Still open

- **Root-cause the ACME DNS-01 failure.** Now the top item: it blocks the HTTPS
  path this design wants, and it blocks the L7 test below. The amplifier is
  understood (no cert cache across recreates, above); the underlying
  `OrderError status "invalid"` is not. Next probes: watch for the
  `_acme-challenge.<host>.<tailnet>.ts.net` TXT record from a public resolver
  during the challenge window to test the propagation-race hypothesis, and
  confirm HTTPS certificates are still enabled for the tailnet.
- **Test whether a `ProxyGroup` survives exposure churn.** If shared long-lived
  proxies keep their state Secret — and therefore their cached certificate —
  across Ingress/Service lifecycles, that removes the churn amplifier
  independently of the root cause, and is likely wanted anyway for per-exposure
  pod cost.
- **Does SigV4 survive the Tailscale *Ingress*?** Still unmeasured. S3 request
  signing covers the `Host` header; if the L7 proxy rewrites it, signed requests
  fail `SignatureDoesNotMatch`. The L4 result above does *not* answer this —
  raw TCP forwarding preserves `Host` by construction, an HTTP reverse proxy need
  not. This is the remaining risk on the intended HTTPS route, and it can only be
  tested once cert issuance works again.
- Whether `serverAltDNSNames` actually lands in a generated certificate.
- Whether prefix isolation still holds over an external endpoint — a signed
  request within the consumer's own prefix succeeded, but the negative case (an
  unscoped bucket-root list, expected `AccessDenied`) was not re-run externally.
  Server-side IAM should make this identical to the in-cluster behaviour proven
  during D15, but "should" is why it is listed here.
- `DatabaseRole.clientCertificate` end-to-end, including `pg_hba` and driver
  support — the deepest unknown, and what decides whether the binding Secret
  contract can ever be uniform.
- Per-exposure cost on this single node (each exposure is another `ts-*-0` pod;
  four already run, on the host where Grafana was memory-squeezed).
- Credential rotation and revocation for the Postgres side; whether a
  two-valid-credentials window is achievable at all.
- Cross-namespace bindings and the grant object that would gate them
  (`ResourceReferenceGrant` is the in-repo precedent), plus which namespace the
  credential Secret lands in.
- Migration safety: if `Application` stops inlining the S3 quad, every derived
  name and prefix must come out byte-identical, or existing objects orphan.
  Note the prefix is `<app>-<alias>`, *not* the Kubernetes object name.

## How to reproduce

Everything above was run with hand-applied throwaway objects, deliberately not
added to Flux — Flux does not prune objects it never applied, so no suspension
was needed (contrast with the standing rule for testing *managed* manifests).
All spike objects, generated CRDs, and tailnet devices were removed afterwards
and the baseline re-verified.

The S3 measurement needs `aws` on the host (added to the `cli_tools` role) and
a tailnet endpoint. The L4 exposure that unblocked it, kept here because it is
the diagnostic to reach for when ACME is misbehaving — **not** as the proposed
mechanism:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: s3-lb-spike
  namespace: seaweedfs
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:            # must match seaweed-s3's own selector exactly
    app.kubernetes.io/component: s3
    app.kubernetes.io/instance: seaweed
    app.kubernetes.io/name: seaweedfs
  ports:
    - name: s3
      port: 8333
      targetPort: 8333
```

It comes up in well under a minute with no ACME involved, at
`<namespace>-<name>.<tailnet>.ts.net:8333`. Then, from any tailnet device (note
`addressing_style = path` — SeaweedFS needs path-style, and a bare
`aws configure set default.s3.addressing_style path` is enough):

```
aws --endpoint-url http://seaweedfs-s3-lb-spike.<tailnet>.ts.net:8333 \
    s3 ls s3://<bucket>/<app>-<alias>/
```

Two traps worth knowing: the S3 `Service` selector is
`app.kubernetes.io/name: seaweedfs` while the `Seaweed` CR is named `seaweed`,
so a guessed selector silently yields an empty `EndpointSlice` and a connection
timeout rather than an error; and the credentials must be read straight into the
command's environment rather than printed.
