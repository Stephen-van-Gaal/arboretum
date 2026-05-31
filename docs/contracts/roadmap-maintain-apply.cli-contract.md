---
script: scripts/roadmap/maintain-apply.sh
version: 1.1
invokers:
  - type: skill
    name: arboretum:/roadmap (maintain)
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/roadmap/maintain-apply.sh`

## Surface

Applies the non-interactive `/roadmap maintain` actions sourced from a scan JSON produced by `scripts/roadmap/maintain-scan.sh`. Reads the scan document via `--scan-file <path|->` (pass `-` to read from stdin); validates it with `jq -e .` before acting. Applies only the five high-confidence, reversible action buckets — `auto_close`, `soft_resolved`, `orphan`, `agent_ready_invalidated`, `agent_ready_stale` — leaving `untriaged` and `unshaped_next` for the interactive skill flow. Each action posts an evidence-bearing comment to the affected tracker item before or after the label/close mutation. Supports `--dry-run` to print intended actions without mutating anything. Requires the configured tracker backend to be available and authenticated for live runs; the dry-run path makes no tracker calls. The default GitHub adapter delegates to `gh issue` subcommands. This is a script→tracker side-effect surface: the input is a structured scan JSON (consumed from the scan script's stdout), and the outputs are tracker mutations — making it correctly CLI-shape per D1 of the related design.

## Protocol

### Arguments

- `--scan-file <path|->` — **required.** Path to the scan JSON file produced by `maintain-scan.sh`, or `-` to read from stdin. The file is read with `cat`, then validated with `jq -e .`. Exits `1` if the path does not exist; exits `1` if the content is not valid JSON.
- `--dry-run` — optional flag. When present, prints the intended action for each bucketed issue (prefixed `[dry-run]`) and exits `0` without calling the tracker. No tracker mutations occur.
- `-h|--help` — prints usage extracted from the script header and exits `0`.
- Any other argument causes an immediate exit `2` with `Unknown arg: <arg>` on stderr.

`--scan-file` is required; omitting it exits `2` with `Missing --scan-file` on stderr.

### Exit codes

- `0` — completed successfully. In live mode: all reachable issues were acted on (per-item tracker errors are logged to stderr as warnings and do not abort the run). In dry-run mode: all intended actions were printed.
- `1` — pre-flight failure: scan file path does not exist, scan JSON is invalid, or (live mode only) the configured tracker backend is unavailable or unauthenticated.
- `2` — argument error: unknown flag, or `--scan-file` omitted.

### Side effects

Mutates tracker items through `scripts/roadmap/lib.sh` helper functions — one or more of the following per bucketed item, depending on bucket:

- `auto_close` — closes the item and posts an evidence comment.
- `soft_resolved` — adds label `provisionally-resolved` and posts an evidence comment.
- `orphan` — adds label `provisionally-stale` and posts an evidence comment.
- `agent_ready_invalidated` — removes label `agent-ready` and posts an evidence comment.
- `agent_ready_stale` — removes label `agent-ready`, adds label `agent-prep:in-progress`, and posts an evidence comment.

Per-item tracker errors are non-fatal: the script logs a warning to stderr and continues to the next item. In `--dry-run` mode: read-only — no side effects. No disk writes; no network calls outside the configured tracker adapter.

## Test surface

- **CLI-1: Scan-file ingestion — empty buckets, exit 0.** Given a valid scan JSON with empty (or absent) actionable bucket arrays, `maintain-apply.sh --scan-file <path> --dry-run` exits `0`, produces no stdout output, and makes no tracker calls. Pins the "nothing to apply" path and the `--scan-file` argument contract. **`--dry-run` is required for the no-tracker guarantee:** in live mode the backend guard runs *before* the bucket loops, so even an empty-buckets scan reaches that guard and exits non-zero on a host without an authenticated tracker backend.
- **CLI-2: Dry-run produces output, no tracker calls.** Given a scan JSON with at least one entry in each of the five actionable buckets, `maintain-apply.sh --scan-file <path> --dry-run` exits `0` and emits one `[dry-run] ...` line per entry to stdout — without invoking the tracker. Pins the `--dry-run` flag and the per-bucket dispatch loop.
- **CLI-3: Missing --scan-file exits 2.** Invoking `maintain-apply.sh` with no arguments exits `2` and emits `Missing --scan-file` on stderr.
- **CLI-4: Invalid JSON exits 1.** Given a file containing non-JSON content, `maintain-apply.sh --scan-file <path>` exits `1` and emits `Invalid scan JSON` on stderr.
- **CLI-5: Unknown flag exits 2.** Invoking `maintain-apply.sh --bogus` exits `2` and emits `Unknown arg: --bogus` on stderr.

## Versioning

- **1.1** (2026-05-31) — live mutations flow through backend-neutral tracker helpers; GitHub remains the default adapter.
- **1.0** — initial contract (2026-05-30).
