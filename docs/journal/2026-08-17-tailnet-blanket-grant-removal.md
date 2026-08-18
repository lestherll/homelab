# Removed Tailscale's blanket allow-all grant, replaced with per-purpose rules

**Date:** 2026-08-17 · **Tags:** security, tailscale, zero-trust

**Problem:** Tailscale's default `{"src":["*"],"dst":["*"],"ip":["*"]}` grant
made every narrower rule in the ACL file decorative — same failure shape as
the NetworkPolicy finding same day.

**Decision:** removed the blanket grant. Every reachability path now exists
because an explicit rule says so: operator devices to each other
(`autogroup:self`), operator to app proxies (ports 80/443 only), CI to the
apiserver service only (not the proxy device, the *service* — device grants
and service grants are separate).

**Validation:** added a `tests` block to the policy file — every accept
paired with a deny, since the failure mode here is silent (an over-wide rule
breaks nothing and stays invisible). Runs on every PR via `test` mode,
without touching the live tailnet.

**Finding (test-writing gotcha):** destinations in the tests block must be
tags or the named `hosts` entries — a MagicDNS device name is not
resolvable there. First draft used device names, failed validation with
`unknown user or host`. Tags are also the better target anyway: they
survive a proxy being recreated under a new name/address.

**Ref:** `tailscale-acl/policy.hujson`, PR #67/#68
