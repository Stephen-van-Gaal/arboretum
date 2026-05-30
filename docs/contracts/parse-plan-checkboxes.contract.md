---
seam: parse-plan-checkboxes
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/parse-plan-checkboxes.sh
---
<!-- owner: pipeline-contracts-template -->

# parse-plan-checkboxes — `parse-plan-checkboxes.sh` Plan Checkbox Counter Contract

The seam between `scripts/parse-plan-checkboxes.sh` (which counts the task checkboxes in a plan file) and the `/build` skill, which captures the script's stdout to decide whether a plan still has open tasks. The script's stdout is a single fixed-shape line; this contract pins that line's exact `open=N total=N skipped=N` form and the checkbox classification rules so `/build` never has to re-scan the plan markdown.

## Producer

`scripts/parse-plan-checkboxes.sh` — producer-type: `script`.

Takes exactly one positional argument: the path to a plan file. Scans the file for markdown task checkboxes and prints one line, `open=N total=N skipped=N`, to stdout, then exits `0`. Classification (per WS1 D4):

- `- [ ] …` → **open** (counted in both `total` and `open`).
- `- [x] …` → **resolved** (counted in `total`).
- `- [x] (skipped: <reason>) …` → **resolved + skipped** (counted in `total` and `skipped`; a skipped checkbox is a checked checkbox, so it is also in `total`, never in `open`).

Matching is anchored to line start allowing leading whitespace (`^\s*-\s+\[…\]\s`), so nested/indented checkboxes count. `total` is `open + checked`; `skipped` is a sub-count of the checked set. Usage errors (wrong arg count, missing file) exit `1`.

## Consumer

Consumer-type: `skill`. One downstream consumer:

- **`skills/build/SKILL.md`** (~line 169) runs `PARSED="$(bash scripts/parse-plan-checkboxes.sh "$PLAN")"` and inspects the `open=` count to decide whether the plan is fully executed before advancing the build stage.

**Consumer obligations:**

- Consumers MUST parse the three space-separated `key=N` tokens from a single stdout line — the line shape is fixed and ordered `open total skipped`.
- Consumers MUST treat `open=0` as "no remaining tasks," regardless of `skipped` — a skipped task is resolved, not open.
- Consumers MUST NOT assume `total == open + skipped`; `skipped` is a sub-count of the resolved (checked) set, not of the open set.

## Protocol shape

### Inputs

- One positional argument: the path to a plan markdown file. No stdin.

### Outputs

- stdout (exit 0): exactly one line, `open=N total=N skipped=N`, where each N is a non-negative integer.
- stderr (exit 1 only): a `Usage:` or `plan file not found:` diagnostic.
- Exit codes: `0` — counts printed; `1` — usage error (wrong arg count or file not found).

### Invariants

- **Fixed line shape.** stdout on exit 0 is always exactly `open=N total=N skipped=N` — three space-separated `key=integer` tokens in that order, one line, no decoration.
- **total = open + checked.** `total` counts every `- [ ]` and `- [x]` checkbox; `open` counts only `- [ ]`. A skipped checkbox is a checked checkbox.
- **skipped ⊆ checked.** `skipped` counts only `- [x] (skipped: …)` checkboxes — a subset of the checked set, never overlapping `open`.
- **Indented checkboxes count.** Leading whitespace before the `-` is tolerated, so nested list items are counted.
- **No mutation.** Read-only — the script never writes the plan or any file.

## Test surface

- **PPC-1:** A plan with 2 open, 1 plain checked, 1 skipped checkbox → stdout `open=2 total=4 skipped=1`, exit 0.
- **PPC-2:** All checkboxes checked, none skipped → `open=0`, `total` = checked count, `skipped=0`.
- **PPC-3:** Empty plan (no checkboxes) → `open=0 total=0 skipped=0`, exit 0.
- **PPC-4:** An indented (nested) `- [ ]` checkbox is counted in `open` and `total`.
- **PPC-5:** A `- [x] (skipped: reason)` line counts in `total` and `skipped` but NOT in `open`.
- **PPC-6:** Missing file → exit 1, stderr diagnostic.
- **PPC-7:** Read-only — the plan file's content is unchanged after invocation.

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/parse-plan-checkboxes.sh` on this branch. Issue #303 (WS5 PR 7a).
