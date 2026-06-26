---
name: audit-test-metadata
owner: git-workflow-tooling
scope: plugin-only
description: Audit and tag smoke tests for parallel-safety so in-session CI stays fast. Use when the smoke suite slows down, after adding several smoke tests, or when the recurrence guard reports untagged tests.
disable-model-invocation: false
allowed-tools: Bash, Read, Edit
argument-hint: [report | apply]
---

# Audit Test Metadata

Re-runnable method to keep the smoke suite running concurrently. New
`scripts/_smoke-test-*.sh` default to serial; left unchecked, the suite slowly
re-bloats and in-session CI (`/build`, `/finish`, `/land` gates) gets slow. This
method re-establishes the parallel ratio.

## Procedure

1. **Report.** `bash scripts/audit-test-metadata.sh` — review the table. Note any
   `needs-review` rows (the classifier could not decide).
2. **Resolve `needs-review`.** Read each flagged test. If it is genuinely isolated
   (own `mktemp` sandbox, no working-tree mutation, no shared fixed path / network
   port / shared env), tag it `# ci-parallel: safe`. Otherwise tag
   `# ci-parallel: serial`. The tag line must be **exactly** `# ci-parallel: safe`
   or `# ci-parallel: serial` — the runner parses it strictly and fails on any
   trailing text. Put any reason on a **separate** line (e.g.
   `# ci-parallel-reason: mutates the shared worktree`). The classifier flags,
   e.g., real network binds and path-scoped `git -C` — but it cannot see every
   shared-state hazard, so a human confirms.
3. **Apply the unambiguous rest.** `bash scripts/audit-test-metadata.sh --apply`
   tags the clear safe/serial cases (it never touches `needs-review`).
4. **Verify empirically — the real safety gate.** Run
   `ARBORETUM_CI_JOBS=8 ARBORETUM_CI_READONLY=1 bash scripts/ci-checks.sh`
   **twice**. A test that flakes across the two runs is not parallel-safe —
   downgrade it to `# ci-parallel: serial` with a reason and re-verify. Static
   classification only proposes; the deterministic two-run green decides.
5. **Confirm the guard.** `bash scripts/_smoke-test-test-metadata.sh` must pass —
   no test left undeclared.

## Important

- The classifier **proposes**; the two-run parallel check **decides**.
- Never auto-tag a `needs-review` test — a human inspects it.
- A tag is a claim about isolation. If you cannot prove isolation, choose
  `serial` — a slow-but-correct test beats a fast-but-flaky one.
