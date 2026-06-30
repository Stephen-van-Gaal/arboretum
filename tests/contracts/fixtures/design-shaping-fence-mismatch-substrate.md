---
date: 2026-01-01
topic: fixture-shaping-fence-mismatch
status: design
related-issue: 999
kind: shaping
---

# Fixture: heading fenced in a ``` block that contains a ~~~ line

The `## Substrate Survey` heading below is inside a real backtick fence that
also contains a `~~~` line. A different-family marker must NOT close the fence,
so the heading stays fenced and does not satisfy S2-9.

```
~~~
## Substrate Survey
| Referent | Kind | Status | Evidence |
```
