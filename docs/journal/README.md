# Engineering journal

Findings and decisions, not ADRs (ADRs are a separate, not-yet-scoped
concern). One file per entry, `YYYY-MM-DD-slug.md`. Purpose: fast recall of
what happened and why.

## Template

Headers below are a checklist, not a form — populate what applies, skip
what doesn't, don't pad. Bullets or one-liners only; no prose paragraphs.

```markdown
# <specific title, not "auth work">

**Date:** YYYY-MM-DD · **Tags:** kubernetes, terraform, ...

**Problem:** what broke / what was needed
**Context:** state of the system going in
**Investigation:** what was checked, in order, if it wasn't obvious
**Finding:** root cause / what was actually true
**Decision:** what was built/changed
**Alternatives considered:** rejected options + one-line why
**Why:** reasoning for the decision, if not already obvious from Finding
**Validation:** how it was confirmed to work
**Security impact:** only if there is one
**Follow-up:** open items, if any

**Ref:** link to PR / Linear / fuller doc
```

## When to add one

A deliberate decision made after finding something out, or a finding
non-obvious enough you'd forget it in six months. Not every PR, not
routine fixes.
