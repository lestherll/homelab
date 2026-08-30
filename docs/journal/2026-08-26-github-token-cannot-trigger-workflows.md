# A GITHUB_TOKEN push triggers nothing, so the build dispatches register.yml

**Date:** 2026-08-26 · **Tags:** github-actions, flux, ci, delivery

**Problem:** D19's event-driven half never worked. `build.yml` pushes a
digest-pin commit; `register.yml` was supposed to fire on that push and
force-reconcile Flux. It never fired once. Delivery silently fell back to
Flux's 5-minute poll — the exact thing D19 set out to replace.

**Context:**
- D19 landed digest-pinning and the reconcile trigger together (PR #83).
- Digest-pinning worked end to end and is live on both apps.
- The reconcile trigger sat in `register.yml`, gated on `on: push`.

**Investigation:**
1. Post-merge, `register.yml` had no run against the digest-pin commit —
   `gh api repos/.../commits/<sha>/check-runs` returned `total_count: 0`.
2. Flux had the commit anyway, timing consistent with the 5m poll, not a push.
3. GitHub docs: events raised with the default `GITHUB_TOKEN` do not create
   workflow runs, to prevent recursion.
4. Same docs, and the 2022-09-08 changelog: `workflow_dispatch` and
   `repository_dispatch` are **explicit exceptions** — they always create runs.

**Finding:**
- The suppression is on *implicit* events only. `push` from CI is dead;
  an explicit `workflow_dispatch` from the very same token is not.
- This was knowable up front. It went in because the plan asserted
  "`register.yml` has no path filter, so it still runs on the bump commit" and
  nobody checked. The mechanism was verified only after merging to three repos.

**Decision:** `build.yml` ends with
`gh workflow run register.yml --ref main -f action=register`, gated on the
digest having actually changed, with `actions: write` added to its
`permissions:`. `register.yml` is unchanged — it already had a
`workflow_dispatch` trigger defaulting to `action: register`.

**Alternatives considered:**
- *Duplicate join/mint/annotate into `build.yml`* — cluster access in two files
  per repo, kept in sync by hand, against a copyable-verbatim template, to save
  ~20s. Its one merit: a build could still reconcile while `register.yml` is
  broken.
- *Composite action in this repo, used by both* — no duplication and no second
  run, but a versioned cross-repo CI dependency and a pinning question.
  Overbuilt for two app repos; revisit if the block grows.
- *SSH deploy key for the push* — deploy keys are not suppressed, so `on: push`
  would fire naturally. Rejected: a stored per-repo credential and per-repo
  onboarding setup, against D16's "only three secrets, none a cluster
  credential."
- *Just shorten the Flux interval to 1m* — no credentials, no CI complexity,
  0-60s lag. Still the honest fallback if the dispatch ever becomes a
  maintenance burden; the two compose fine.

**Why:** dispatching keeps every piece of cluster access — tailnet join, OIDC
token, `kubectl` — in `register.yml`, the file the platform docs call
copyable-verbatim, and leaves a build workflow knowing only the registry and
its own repo. The cost is ~20s of run-start latency, which buys back the
duplication the alternative would have created.

**Validation:** a push to an app repo produces, in order: `build.yml` builds
and pushes the digest-pin commit → dispatched `register.yml` run → fresh
`reconcile.fluxcd.io/requestedAt` on both objects → `Application.spec.image` at
the new digest, in about a minute rather than up to five.

**Follow-up:** `paths-ignore: [deploy/**]` on `build.yml` is now redundant for
loop prevention (the token already cannot re-trigger it) but kept: it becomes
the only guard if the push credential ever changes, and it correctly skips a
rebuild when a human edits `deploy/` without touching code.

**Ref:** LES-57, LES-73, D19. PRs: lestherll/homelab#83 (original),
lestherll/fastapi-echo#5, lestherll/personal-finance-dashboard#14.
