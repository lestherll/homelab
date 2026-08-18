# OAuth client secret shipped as static plaintext in every kubeconfig, on purpose

**Date:** 2026-08-17 · **Tags:** security, oidc, oauth, credential-design

**Problem:** `kubelogin`'s `exec` plugin needs both `--oidc-client-id` and
`--oidc-client-secret` for Google's token endpoint (unlike some IdPs, Google
requires the secret even for public/installed clients). Distributing a
"secret" identically to every personal machine looks wrong on its face.

**Decision:** same client ID + secret, static plaintext, copied into every
machine's kubeconfig. No per-device credential, no rotation, no
distribution problem to solve.

**Why:** Google's own docs treat an installed-app client secret as
non-confidential — it's readable out of the app/binary regardless of how
it's shipped. The actual security is PKCE (blocks authorization-code
interception) + the real browser login + the `claimValidationRules` email
allow-list at the apiserver, none of which the secret being "known"
weakens. Same model `gcloud`'s own OAuth client relies on (public in its
open-source SDK for years).

**Decision (related): operator email is a Terraform variable, not hardcoded.**
`google_operator_email` — PII, not a credential, kept out of git (mirrors
`machine_secrets`' pattern) since it's likely to rotate and this repo's
GitHub OIDC audience implies public visibility.

**Alternatives considered:**
- Template the `ClusterRoleBinding` subject (`google:<email>`) via Flux
  `postBuild.substitute` to also keep that instance out of git — rejected,
  nothing else in the repo uses `postBuild.substitute`, and introducing it
  to hide one non-secret string is more machinery than it buys. The email
  stays committed once, as an ordinary RBAC subject.

**Security impact:** correctly identifies which of two "secret-shaped"
values (OAuth client secret vs. operator email) actually needed protecting
and which didn't — inverse of the naive instinct.

**Ref:** `AUTH-MODEL-DRAFT.md` §4, `terraform/clusters/homelab/main.tf`, PR #69
