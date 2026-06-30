---
date: 2026-01-01
topic: fixture-shaping-subheading-substrate
status: design
related-issue: 999
kind: shaping
---

# Fixture: Shaping doc whose Substrate Survey opens with a subheading

## Substrate Survey

### Notes
| Referent | Kind | Status | Evidence |
|---|---|---|---|
| validate-design-spec.sh | script | exists | scripts/validate-design-spec.sh |

**Verdict:** no substrate violations — a deeper (H3) subheading and `#`-prefixed
content are part of the section, not a section boundary, so this must pass S2-9.
