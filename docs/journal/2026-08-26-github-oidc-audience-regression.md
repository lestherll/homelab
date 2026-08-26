# GitHub OIDC audience regression broke all CI cluster access for five days

**Date:** 2026-08-26 · **Tags:** kubernetes, terraform, oidc, auth, ci

**Problem:** every `register.yml` run failed at its first `kubectl` call with
`failed to download openapi: the server has asked for the client to provide
credentials`. Zero-touch app registration (LES-55/D16) was dead.

**Context:**
- Surfaced while landing D19 (digest-pinned image delivery), which pushes to
  `main` and so exercises `register.yml`.
- The failing step was code nobody had touched; it last succeeded 2026-08-17.

**Investigation:**
1. Error names the OpenAPI endpoint, so it reads like a discovery/proxy quirk —
   the obvious "fix" is `--validate=false`. **Wrong track.**
2. apiserver logs gave the real error:
   `oidc: expected audience "https://github.com/lestherll" got ["homelab-k8s"]`
3. `git log -L` on `talos.tf`'s `authentication_configuration_yaml` blamed
   `1d802bb` (LES-104, Google OIDC for human kubectl access).
4. `git show 1d802bb^` confirmed the pre-migration value: the legacy flag was
   `oidc-client-id = "homelab-k8s"`.

**Finding:**
- Adding a second issuer (Google) forced migrating GitHub's trust from the
  legacy `oidc-*` apiServer flags to `AuthenticationConfiguration` — the flags
  support exactly one issuer. In that transcription the GitHub audience became
  `https://github.com/lestherll` instead of `homelab-k8s`.
- **The OpenAPI error was a red herring.** kubectl's schema download is simply
  its *first* request; the token was rejected outright, so the apply would have
  failed identically. `--validate=false` would have hidden the symptom and left
  CI auth broken.
- The wrong value is plausible-looking: `https://github.com/lestherll` is
  exactly what GitHub uses as the **default** audience when a workflow requests
  none. It looks like a correct GitHub value rather than a typo.
- **Silent for five days.** Config committed 08-17 23:30; `terraform apply`
  restarted the apiserver 08-20 20:27, putting it live; nothing pushed to an
  app repo until 08-26 00:18, so nothing exercised it. No alert fired —
  `flux-notifications/` cannot see this path, because it is CI→apiserver, not
  Flux.

**Decision:** set the audience back to `homelab-k8s`, with a comment naming the
coupling to `register.yml` in every app repo.

**Why:** a deliberately-chosen audience is a scoping control, not decoration.
Pointing it at GitHub's default means any default-audience token from any repo
the owner controls authenticates — so a token minted for an unrelated
integration could be replayed against the cluster. Not a privilege escalation
(the `app-registrar` `ValidatingAdmissionPolicy` still bounds what each repo may
touch), but the control the original flag comment described was gone.

**Security impact:** ~5 days during which the cluster accepted GitHub's default
audience rather than a purpose-minted one. No evidence of use; the window is
recorded rather than dismissed.

**Validation:** `terraform apply` (restarts the apiserver and its fate-shared
tailnet proxy), then a `register.yml` run reaching the cluster and reconciling.

**Follow-up:**
- Nothing watches CI→apiserver auth. It broke for five days in silence, and the
  only reason it surfaced was an unrelated feature happening to push. A
  synthetic check, or an alert on `authentication.go` rejections, would have
  caught it the same day — tracked separately.
- Changing this value is a two-repo-class change (here + every app repo's
  `register.yml`). Nothing enforces that coupling; it is a comment today.

**Ref:** LES-104 introduced it; found while implementing D19 (LES-57/LES-73).
