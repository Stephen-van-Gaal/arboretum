---
date: 2026-01-01
topic: fixture-test-surface-reasons
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
    - tests/example/foo_test.sh — adds coverage for the new edge case the build surfaced
  modified: []
  removed: []
---

# Fixture: test-surface-changes entry includes the S3-mandated reason on the same line (regression for Codex round-3 P2 #2 — the token regex was rejecting reason-bearing entries that the S3 contract explicitly requires)
