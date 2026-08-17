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
- **Subject**: `repo:lestherll/homelab:*` — one credential covering both the
  `push` to `main` (`repo:lestherll/homelab:ref:refs/heads/main`) and the
  `pull_request` runs (`repo:lestherll/homelab:pull_request`). A pull request
  from a fork cannot mint an id-token at all, so the wildcard does not hand
  apply-capable credentials to an untrusted contributor; splitting it into two
  credentials would buy nothing here.
- **Scopes**: `policy_file` (write). Nothing else — this credential must not be
  able to touch devices, keys or DNS.

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
