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

## A note on old `**Ref:** CONCEPT.md D<n>` lines

Early entries cite a `CONCEPT.md` decision by its old D-number (e.g. `D1`,
`D12`). `CONCEPT.md` no longer carries that numbered decision log — it's a
short concept pitch now — so those numbers won't resolve to a section there.
The full numbered log they refer to is in git history on `CONCEPT.md`. Not
worth rewriting each entry for; this note is the fix.
