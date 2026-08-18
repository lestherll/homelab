# Three-layer platform API, promote only after 3rd hand-built instance

**Date:** 2026-08-01 · **Tags:** platform-engineering, api-design

**Decision:** Layer 0 (raw manifests, always the escape hatch) → layer 1
(composed templates) → layer 2 (typed API via kro). Promote a resource type
to layer 2 only after the 3rd instance is hand-built by hand.

**Why:**
- Designing an abstraction before real instances exist is how platform APIs
  end up leaky — the shape gets guessed instead of learned.
- Layer 2 must render its layer 1 output visibly, so any abstraction can be
  forked back to raw manifests if wrong. No black-box automation.

**Follow-up:** rule got overridden later — see 2026-08-10 entry.

**Ref:** `CONCEPT.md` D1
