---
date: 2026-01-01
topic: fixture-test-surface-metachar
status: design
related-issue: 999
triage: everything-else
implementation-mode: direct
plan: null
test-tiers:
  unit: yes
  contract: yes
  integration: yes
test-surface-changes:
  added:
    - tests/example/foo_testXsh
  modified: []
  removed: []
---

# Fixture: block lists `tests/example/foo_testXsh` — sharing the same path
# prefix as the changed-file entry `tests/example/foo_test.sh` (which the
# test passes via test-surface-list-good.txt). The only difference is the
# `.` vs `X` at the same position. Under the original regex-token matcher,
# `${f}` was inserted raw so the `.` in `foo_test.sh` was a regex wildcard
# matching `X` — this fixture would have falsely satisfied the block.
# The current token-set matcher compares strings exactly and correctly
# rejects. (Codex round-2 P2 #1 + round-3 P3 — make the fixture actually
# exercise the bug it guards.)
