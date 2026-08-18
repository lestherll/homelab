# Build runner gets zero git write access, deployer watches the registry instead

**Date:** 2026-08-01 · **Tags:** ci-cd, security, credential-design

**Problem:** how does a build get from image to running workload without
handing a commit credential to code you haven't fully reviewed.

**Decision:** build runner pushes an image and stops — registry push only,
no git credential at all. A separate reconciler watches the registry for
tags matching a policy and writes the tag-bump commit itself.

**Alternatives considered:**
- Build runner opens a PR against the config repo — more common pattern,
  rejected: it still hands a commit-capable credential to a principal
  executing arbitrary repo-supplied code.

**Why:** the build identity should be genuinely useless for deployment, not
just discouraged from deploying.

**Security impact:** compromised build runner can poison an image, can't
touch what gets deployed or when.

**Ref:** `CONCEPT.md` D2
