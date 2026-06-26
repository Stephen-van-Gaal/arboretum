---
script: scripts/roadmap/score-apply.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/roadmap (score)
  - type: developer
related-designs: []
---
<!-- owner: roadmap -->

# Contract for `scripts/roadmap/score-apply.sh`

## Surface

Executes the combine/delete/decompose dispositions stored in the score cache produced by `score-cache.sh`. Reads the cache from `--cache <file>` (required) and applies only the safe, reversible subset: issues with `disposition=="delete"` and `class=="work-unit"` are closed via the tracker (with an evidence comment). `combine` dispositions are noted as PLAN lines but are skill-orchestrated, not auto-executed here. `decompose` is nominate-only — no auto-create. Issues where `class=="orchestrator"` or where `class` is absent or unrecognised are routed to NEEDS-CONFIRM and skipped; `type:epic` issues carry an additional live-label guard (re-checked from the tracker at apply time) so a stale or mis-classified cache entry cannot trigger an auto-close. Supports `--dry-run` to print intended actions without mutating anything.

## Protocol

### Arguments

- `--cache <file>` — **required.** Path to the score cache JSON file. Exits 2 (`Missing --cache`) if omitted; exits 1 (`Not a file: <path>`) if the path does not exist; exits 1 (`Invalid cache JSON`) if the content is not valid JSON.
- `--dry-run` — optional flag. When present, prints PLAN/NEEDS-CONFIRM/NOMINATE lines and exits 0 without calling the tracker. No tracker mutations occur and `lib.sh` is not sourced.
- `-h|--help` — prints usage from the script header and exits 0.
- Any other argument: exits 2 with `Unknown arg: <arg>` on stderr.

### Exit codes

- `0` — completed successfully. In live mode: all reachable delete-work-unit entries were acted on (per-item tracker errors are logged to stderr as warnings and do not abort the run). In dry-run mode: all plan/confirm/nominate lines were printed.
- `1` — pre-flight failure: cache file does not exist, cache JSON is invalid, or (live mode only) the configured tracker backend is unavailable or unauthenticated.
- `2` — argument error: unknown flag, or `--cache` omitted.

### Output lines

For every dispositioned entry in the cache:

- `PLAN: close #<n> (delete) — reason: <value_description>` — `disposition=="delete"` and `class=="work-unit"`.
- `NEEDS-CONFIRM: #<n> delete (class is <class> — skipped)` — `disposition=="delete"` and `class` is not `work-unit` (including absent/null).
- `NEEDS-CONFIRM: #<n> combine (type:epic — skipped)` — `disposition=="combine"` and `class=="orchestrator"`.
- `PLAN: combine #<n> → anchor #<m> (body-review gate — skill-driven)` — `disposition=="combine"` and `class` is not `orchestrator`.
- `NOMINATE: #<n> decompose (nominate-only; no auto-create)` — `disposition=="decompose"`.
- Entries with `disposition=="keep"` produce no output.

In live (non-dry-run) mode, after the PLAN/NEEDS-CONFIRM/NOMINATE pass, only the `delete`/`work-unit` entries are acted on:

- A comment is posted to the issue: `Closed by \`/roadmap score --apply\` (disposition: delete). Evidence: <value_description>. Reversible — reopen if mis-scored.`
- The issue is closed with reason `not planned`.
- If the live tracker shows a `type:epic` label (re-fetched at apply time), the issue is redirected to a `NEEDS-CONFIRM` line and skipped regardless of the cache value.
- Per-item tracker errors are non-fatal: a warning is emitted to stderr and the loop continues.

### Side effects

Live mode only: posts a comment and closes issues via the configured tracker backend (`roadmap_tracker_issue_comment` + `roadmap_tracker_issue_close` from `scripts/roadmap/lib.sh`). `--dry-run` is fully read-only: no tracker calls, no file writes.

## Test surface

Asserted by `scripts/_smoke-test-score-apply.sh` (dry-run only; no network):

- **SA-1:** Issue #5 (`disposition=="delete"`, `class=="work-unit"`) → a PLAN close line is emitted.
- **SA-2:** Issue #8 (`disposition=="delete"`, `class=="orchestrator"`) → a NEEDS-CONFIRM line is emitted; issue is not planned for close.
- **SA-3:** Issue #6 (`disposition=="decompose"`, `class=="orchestrator"`) → a NOMINATE line is emitted.
- **SA-4:** Issue #7 (`disposition=="delete"`, `class` absent/null) → a NEEDS-CONFIRM line is emitted; no PLAN line is emitted for #7.

## Versioning

- **1.0** (2026-06-26) — initial contract. Script shape as of `scripts/roadmap/score-apply.sh` on `feat/roadmap-scoring`.
