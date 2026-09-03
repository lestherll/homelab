# Tailscale ACL-as-code

`policy.hujson` is the tailnet's access-control policy — tags, ACL rules,
Grants, SSH rules and autoApprovers. It is applied to Tailscale's control plane
by `.github/workflows/tailscale-acl.yml`, not by Flux: Tailscale's control
plane is not a Kubernetes API, so there is nothing for Flux to reconcile. That
makes this the one place in the repo where **CI writes to live infrastructure
directly** — the same shape as an app repo's deploy pipeline, pointed at the
tailnet instead of at the cluster.

It is a sibling of `ansible/`, `terraform/` and `infrastructure/` rather than a
subdirectory of any of them, for that reason: it is a fourth control plane, not
a part of the other three. In particular it is *not* under
`infrastructure/tailscale-operator/` — that directory is the operator running
*inside* the cluster, reconciled by Flux, and confusing the two means editing
the wrong file.

## What the tailnet permits

Tailscale's default blanket grant (`{"src":["*"],"dst":["*"],"ip":["*"]}`) is
gone. Six rules replace it:

| Source | Destination | Ports |
| --- | --- | --- |
| the operator's own devices | each other (`autogroup:self`) | everything |
| the operator's own devices | `tag:k8s` — every proxy the operator creates | `tcp:80`, `tcp:443` |
| `tag:ci` | `svc:kube-apiserver-metal` | `tcp:443` |
| the operator's own devices | `svc:kube-apiserver-metal` | `tcp:443` |
| the operator's own devices | `tag:talos` — the Talos nodes themselves | `tcp:50000` |
| the operator's own devices | `talos-cp-01` (superseded, dies with machine 1) | `tcp:50000` |

Three consequences worth knowing before debugging a connection that hangs:

- **A grant on `tag:k8s` is not a grant on `svc:kube-apiserver-metal`.** Device
  grants and service grants are separate, which is why CI reaching the apiserver
  needs its own rule and gets no access to any app from it.
- **Tailscale SSH needs a grant, not just the `ssh` block.** The `ssh` block
  decides who may open a session and as which local user; `tcp:22` reachability
  comes from the first rule above. Delete that rule and SSH to the host stops
  working, with nothing in the `ssh` block hinting why.
- **The port list on `tag:talos` is the entire security boundary.** A Talos node
  is a tailnet device in its own right, so unlike the subnet-routed
  `talos-cp-01` row there is no route to withhold as well. `:9100` on a node is
  unauthenticated node-exporter; widening `tcp:50000` to `["*"]` publishes it to
  every device on the tailnet. The `tests` block denies it, and five other
  ports, so that widening cannot pass silently.

Not granted, deliberately: anything reaching `tag:k8s-operator`; any outbound
rule for the proxies (they receive connections and originate none over the
tailnet); and `tcp:6443` on `tag:talos`, which would be a break-glass `kubectl`
that does not route through an in-cluster proxy — wanted, but it needs an
apiserver certSAN alongside it and is a decision worth taking on its own
(`docs/fleet/talosctl-off-lan.md` §8).

## Changing the policy

1. Branch, edit `policy.hujson`, open a PR.
2. CI runs the policy in **`test`** mode against the live tailnet: it validates
   syntax and runs any `tests` block in the file, without applying anything.
3. Merge to `main`. CI runs **`apply`** and the policy is live.

Review of the PR *is* the enforcement mechanism for tag and Grant scope
changes — consistent with this repo's stance elsewhere that a single-operator
platform gets review discipline, not a webhook.

Write `tests` blocks for rules that matter. They are the only thing standing
between a typo'd `dst` and a silently wider tailnet, and they run on every PR
for free.

**Pair every accept with a deny.** This file's failure mode is silent: a rule
that is too *wide* breaks nothing and stays invisible until someone re-reads the
policy. An accept-only suite passes exactly as happily against a blanket
allow-everything grant as against a tight one, so the denies are the half that
actually tests anything.

**A test destination cannot be a MagicDNS name.** It resolves against tags,
autogroups, entries in the `hosts` block and literal IPs — nothing else. Writing
`fastapi-echo:443` fails validation with `unknown user or host`, which is a
confusing error for what is really "that name means nothing here". Prefer a tag:
it survives a proxy being recreated, and it tests the rule rather than one
instance of it. `hosts` is for the rare destination that has no tag, and the
block deliberately lists only the long-lived host — pinning a proxy's address
there would produce a test that breaks on an unrelated redeploy.

## Drift: console edits are overwritten, not merged

The admin console still lets you edit the policy directly, and nothing stops
it. The next `apply` overwrites whatever was typed there — git is the source of
truth, by design.

The workflow restores `version-cache.json` between runs so `gitops-pusher` can
compare the live policy's ETag against the last one CI applied, which is how a
console edit becomes visible at all. Note the action does **not** pass
`--fail-on-manual-edits`, so a detected console edit is reported in the job log
and the apply proceeds anyway. If a console edit ever needs keeping, export it
into this file first — same "catch up rather than fight" rule the Talos
bootstrap-manifests caveat in `AGENT.md` describes.

## One-time setup (already done; recorded so a rebuild isn't archaeology)

Authentication is **workload identity federation**, not a stored OAuth client
secret: the job mints a short-lived GitHub OIDC token per run and trades it for
a Tailscale API token, so no long-lived credential for the tailnet's policy
exists anywhere. This also rehearses the OIDC federation pattern the zero-touch
app-registration work needs against the apiserver.

In the Tailscale admin console, under **Settings → Trust credentials → New
credential → OpenID Connect**:

- **Issuer**: GitHub Actions
- **Subject**: `repo:lestherll@37829703/homelab@1318804989:*`

  **Note the `@<id>` suffixes — this is the part that will waste an hour.**
  GitHub mints *ID-based* subjects (`repo:<owner>@<owner-id>/<repo>@<repo-id>:…`),
  not the `repo:<owner>/<repo>:…` form that every doc and example still shows,
  including Tailscale's own. The IDs make the trust relationship rename-proof,
  which is why they exist. Get them with
  `gh api repos/lestherll/homelab --jq '{repo_id: .id, owner_id: .owner.id}'`,
  or just read them off the console: on a mismatch Tailscale reports the exact
  subject it received, which is the fastest way to the right value.

  The trailing `*` makes one credential cover both events — `:pull_request`
  for the validate runs and `:ref:refs/heads/main` for the apply. A pull
  request from a fork cannot mint an id-token at all, so the wildcard does not
  hand apply-capable credentials to an untrusted contributor; splitting this
  into two credentials would buy nothing here.

  A subject mismatch fails at **token exchange** with a bare
  `403 Unauthorized`, before scopes or tailnet are ever consulted — so a 403
  here means the claims didn't match, not that a permission is missing.
- **Scopes**: `policy_file` (write). Nothing else — this credential must not be
  able to touch devices, keys or DNS. `policy_file:read` is enough to *validate*
  and would be the tighter grant if the PR runs had their own credential, but
  the single credential here also has to apply.

Then copy the generated **Client ID** and **Audience** into this repo's Actions
secrets, along with the tailnet name:

| Secret | Value |
| --- | --- |
| `TS_OAUTH_CLIENT_ID` | Federated identity Client ID from the console |
| `TS_AUDIENCE` | Audience (`aud` claim) from the console |
| `TS_TAILNET` | Tailnet name, as shown in the admin console |

Neither the Client ID nor the Audience is actually a secret — Tailscale's docs
say so, and both stay visible in the console. They are Actions secrets only to
keep tailnet-identifying strings out of a file in a public repo; treat losing
one as an annoyance, not an incident.

## Background

Design rationale lives in ADR 0001 (Unified platform auth model), workstream 3.
