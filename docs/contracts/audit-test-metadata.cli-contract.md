---
script: scripts/audit-test-metadata.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-test-metadata.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-26-ci-test-metadata-audit-design.md
---

# Contract for `scripts/audit-test-metadata.sh`

## Surface

Classifies every `scripts/_smoke-test-*.sh` for parallel-safety and reports,
checks, or applies `# ci-parallel:` declarations. Read-only by default; `--apply`
edits headers in place.

## Protocol

### Arguments

- (none) — **report** mode: print a per-test table (`TAG  VERDICT  FILE`) to
  stdout; read-only; exit 0.
- `--check` — read-only; exit 1 and list offenders if any smoke test is
  **untagged**, carries an **invalid** value (anything other than `safe`/`serial`
  in its first 12 lines), or if **zero** `scripts/_smoke-test-*.sh` are found
  (e.g. run from the wrong directory); exit 0 only when every test declares a
  valid value.
- `--apply` — write `# ci-parallel: safe` to `safe-candidate` tests and
  `# ci-parallel: serial` to `serial-required` tests that are currently
  untagged; never tags `needs-review`; mutating; exit 0.
- any other argument — usage error, exit 2.

### Exit codes

- `0` — report/apply succeeded, or `--check` found every test declared.
- `1` — `--check` found at least one untagged test.
- `2` — invalid usage.

### Side effects

- report / `--check`: none (read-only).
- `--apply`: edits untagged `scripts/_smoke-test-*.sh` headers in place,
  inserting `# ci-parallel: <safe|serial>` **after the `# owner:` / optional
  `# scope:` header lines** (never above `# owner:` — the line-2 owner invariant
  must hold). Falls back to inserting after the shebang only when no `# owner:`
  line is present. Exits non-zero if any edit fails.

## Test surface

`scripts/_smoke-test-contract-audit-test-metadata.sh`

## Versioning

1.0 — initial: report / `--check` / `--apply`.
