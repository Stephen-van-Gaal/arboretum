---
date: 2026-01-01
topic: fixture-shaping
status: design
related-issue: 999
kind: shaping
---

# Fixture: Shaping Design Spec (non-buildable)

Carries only the identity field. No build-only fields — kind: shaping relaxes them.

## Substrate Survey
| Referent | Kind | Status | Evidence |
|---|---|---|---|
| validate-design-spec.sh | script | exists | scripts/validate-design-spec.sh |

**Verdict:** no substrate violations — fixture references only existing carriers.
