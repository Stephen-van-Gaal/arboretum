---
script: scripts/backfill-stage-labels.sh
version: 1.0
invokers:
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-05-stage-label-state-design.md
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/backfill-stage-labels.sh`

## Surface

One-shot migration introduced by #570 (current-stage moved from an issue-body marker block to an exclusive `stage:*` label/tag). For each **open** tracker issue whose body still carries the legacy `<!-- pipeline-state:current-stage --> **Current stage:** /<name>` marker block, the script sets the corresponding exclusive `stage:<name>` label (leading slash stripped) via `roadmap_set_prefix_exclusive_label`, then rewrites the issue body with the marker block removed. Issues without a block are skipped. The migration is **idempotent** — a second run over already-migrated issues finds no block and makes no change. Invoked manually by a developer once per repository at upgrade time; not wired into any hook or skill.

## Protocol

### Arguments

```
bash scripts/backfill-stage-labels.sh [project-dir]
```

- **`[project-dir]`** — optional positional path to the project root whose open issues are migrated. Defaults to `git rev-parse --show-toplevel`, falling back to `pwd`. The configured roadmap backend is resolved from this directory (`ROADMAP_BACKEND` env override honored).

No flags. The script reads no stdin.

### Exit codes

- `0` — completion. The script always exits 0 when it runs to completion, **including** when individual issues fail to migrate — per-issue label-set or body-rewrite failures emit a `WARN:` line to stderr and continue to the next issue (a partial migration is observable and re-runnable, not fatal).
- `1` — preflight failure only: bash unavailable, the configured roadmap backend is missing/unreachable (`roadmap_require_backend`), or `python3` is absent.

### Side effects

For each migrated open issue: one exclusive-label write (`roadmap_set_prefix_exclusive_label` → `roadmap_tracker_issue_update --add-label/--remove-label`) and one body rewrite (`roadmap_tracker_issue_update --body-file`). Both flow through the backend-neutral `roadmap_tracker_*` helpers (GitHub `gh`; ADO `System.Tags` patch). Stdout: one `backfill: #<n> -> stage:<value>` line per migrated issue plus a final `backfill complete.` line. Stderr: `WARN:` lines for per-issue failures. Writes a transient `mktemp` body file per issue (removed immediately). No other disk writes; no network calls beyond the tracker helpers.

## Test surface

- **CLI-1: Marker-to-label migration.** Given an open issue whose body contains a `**Current stage:** /<name>` marker block, the script sets `stage:<name>` (slash stripped) sourced from the **body** value (not any pre-existing stage label) and rewrites the body with the block removed (`--body-file`). Pinned by `scripts/_smoke-test-backfill-stage-labels.sh`.
- **CLI-2: Skip-when-absent (idempotent).** An issue with no current-stage marker block produces neither a label write nor a body rewrite; a second run over migrated issues is a no-op.
- **CLI-3: Preflight-fails-closed.** With the roadmap backend unreachable or `python3` absent, the script exits 1 before mutating any issue.

## Versioning

- **1.0** — initial contract (2026-06-06), #570.
