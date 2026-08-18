# App repos self-register via GitHub OIDC + admission policy, zero commits to platform repo

**Date:** 2026-08-11 · **Tags:** ci-cd, oidc, kubernetes, security

**Problem:** D15 still needed one manual step per app — a Flux pointer
object committed to the platform repo, even though the app owns everything
else about itself.

**Decision:** each app repo's own CI joins the tailnet and `kubectl apply`s
its own `GitRepository`+`Kustomization` directly, authenticated via GitHub
Actions OIDC federated straight to the apiserver — no stored token.

**Alternatives considered:**
- ArgoCD `ApplicationSet` SCM generator — native org-wide auto-discovery,
  rejected: disproportionate swap, means running a second CD tool.
- Flux `gitopssets-controller` — no GitHub-discovery generator available.

**Finding (revised before build):** first draft used a long-lived bound SA
token. Revisited immediately, before anything was built, once GitHub OIDC
federation was confirmed GA at the cluster's k8s version — no reason to ship
the weaker posture first.

**Security impact:** per-repo isolation enforced by a `ValidatingAdmissionPolicy`
comparing the object name against the repo name in the caller's own `sub`
claim (CEL `==`, not `startsWith`, to block `fastapi-echo-evil` reaching
`fastapi-echo`). RBAC alone can't express "only the object matching your own
repo" — the VAP is the actual security boundary, RBAC just gets everyone in
the door.

**Follow-up:** no automatic reaction to a repo being deleted/archived
without its teardown job being run first — open, documented as policy.

**Ref:** `CONCEPT.md` D16, `docs/zero-touch-app-registration.md`
