# Google OAuth: org-linked projects block External, and Desktop-app clients can't do device-code

**Date:** 2026-08-18 · **Tags:** oidc, google-oauth, kubelogin, les-104

**Problem:** LES-104's human-kubectl OIDC login failed at the browser
consent step with "Access blocked: homelab-auth can only be used within its
organisation", even when logging in as the account that created and owns
the project.

**Context:** `AUTH-MODEL-DRAFT.md`'s `homelab-auth` project + Desktop-app
OAuth client (client ID ending `...7798jpn1...`) had already been applied
live via `terraform apply` (PRs #69/#70).

**Investigation:**
- Confirmed the request itself was well-formed (right client ID, redirect
  URI, scopes, PKCE challenge) — ruled out a kubeconfig/kubelogin bug.
- `IAM & Admin → Settings` showed the project nested under a Cloud Identity
  organization. The OAuth consent screen's User Type toggle for
  Internal/External wasn't even visible on that project.
- Tried `gcloud beta projects move homelab-auth-505822 --organization=""` to
  detach it — rejected: `projects move` only moves *between* orgs/folders,
  it cannot detach a project to no-parent.
- Separately, tried `--grant-type=device-code` (useful for this host, which
  has no local browser) and got `invalid_client (Invalid client type.)`.

**Finding:**
- Google's "Internal" User Type checks **Directory-domain membership**, not
  project ownership or IAM role. `ljllacuna5@gmail.com` is a `gmail.com`
  address, never a member of the org's own custom domain, so it was
  rejected regardless of holding Owner/admin rights on both the project and
  the org itself. Any project nested under an org is stuck on Internal (no
  External option in console) unless the org's own admin settings allow
  external publishing.
- Google's `device-code` OAuth grant is only available to OAuth clients of
  type **"TVs and Limited Input devices"** — a "Desktop app"-type client
  (which the loopback-redirect `authcode` flow requires) rejects it outright
  at the authorization step. The two grant types need two different client
  types; this is a hard Google-side restriction, not a kubelogin config
  option.

**Decision:**
- Deleted the org-linked `homelab-auth` project (soft-delete, 30-day
  undelete window) and, after hitting the personal-account project-count
  quota (soft-deleted projects still count until purged), freed quota by
  deleting 10 unused legacy projects and created `homelab-auth-ext` with no
  organization parent (`gcloud projects create homelab-auth-ext`, no
  `--organization`/`--folder`).
- Rather than keep two OAuth client types for two grant flows (Desktop app
  for laptops, TV/Limited-Input for headless machines), `homelab-auth-ext`
  uses a single **TV/Limited-Input client** and `device-code` everywhere.
  Device-code needs no local browser or loopback listener on the machine
  running `kubectl`, so the same client + grant type works uniformly on
  this headless host and any future laptop — simpler than branching kubeconfig
  `exec` args by machine type.
- New client ID: `645380473983-4r5f3jhh1thajbun7bj1t28o4o4mds0d...`.
  `terraform/modules/talos-cluster/talos.tf`'s `AuthenticationConfiguration`
  audience and the `google-oidc` kubeconfig user were both updated to match,
  and `terraform apply` re-landed the change (apiserver restart, tailnet
  proxy briefly down — expected, per the fate-shared-proxy gotcha in
  `AGENT.md`).

**Alternatives considered:**
- Google Identity Platform / Firebase Auth as a CIAM layer to sidestep the
  org restriction — rejected: a billed, hosted product with its own JWT
  issuer and service account, disproportionate machinery for "let one Gmail
  address run kubectl" on a single-user cluster.
- Editing the org's own admin settings to allow External publishing —
  possible in principle (operator is the org's Workspace/Cloud Identity
  admin) but the exact control lives in the Workspace Admin Console, not
  Cloud Console, and was untested; recreating outside the org was faster
  and removes the org-policy surface entirely rather than depending on it.

**Why:** the fresh no-org project removes Google's org-membership check
entirely rather than trying to satisfy it, and a single device-code client
avoids maintaining two OAuth client types (and two kubeconfig `exec` shapes)
for what is fundamentally one user on one cluster.

**Validation:** `kubectl --context=google@homelab get nodes` completed a
real device-code login (URL + code, approved in a browser on another
device) and returned live cluster data, confirming the full chain: Google
OIDC → `AuthenticationConfiguration` email allow-list → existing
`ClusterRoleBinding` → RBAC-authorized request over the tailnet proxy.

**Security impact:** none negative — device-code is somewhat more
phishable than PKCE'd authcode in general, but `claimValidationRules`
already hard-locks authentication to one exact email, so the marginal risk
on a single-user cluster is low.

**Follow-up:** none — `kubelogin` install (Ansible, PR #72) and the
kubeconfig `exec` block are both done; LES-104 is fully live end-to-end.

**Ref:** LES-104, PRs #69/#70/#72, `AUTH-MODEL-DRAFT.md`
