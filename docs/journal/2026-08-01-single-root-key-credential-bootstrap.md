# Credential chain terminates at one age/SOPS key, not per-service secrets

**Date:** 2026-08-01 · **Tags:** security, secrets-management, bootstrap

**Problem:** bootstrap needs to clone the config repo before it can decrypt
anything in it — apparent circularity.

**Decision:** one age/SOPS private key decrypts everything in git. Every
other credential is either minted by the cluster (SA tokens, cert-manager
certs) or federated to an external provider. The repo's read-only deploy key
is itself stored encrypted with the age key, fetchable without credentials —
breaks the circularity without a second root secret.

**Security impact:** this key is the one thing the platform can't rebuild
itself out of — every other design goal (rebuildability over uptime) breaks
down at this single point. Protected with a hardware token / physically
separate encrypted copies; threat model is domestic (fire, theft), not a
targeted adversary.

**Ref:** `CONCEPT.md` D12
