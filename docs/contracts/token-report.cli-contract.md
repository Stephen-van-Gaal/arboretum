---
script: scripts/token-report.sh
version: 1.1
invokers:
  - type: script
    name: scripts/token-cleanup.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-06-token-accounting-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/token-report.sh`

## Surface

Advisory token-accounting reporter over the append-only token ledger and the
transcript-derived billed surface. Dispatches one of six subcommands —
`diagnose`, `billed`, `compare`, `trend`, `busts`, `journey`. The first five are
read-only and print a bounded summary that never dumps the raw ledger (D5);
`journey` is the only subcommand that **writes a report artifact** and, by
default, prints just a pointer to it (not the report body). `diagnose` groups
ledger rows by contributor and prints per-contributor row counts, byte totals,
and estimated-token totals. `billed` delegates to `scripts/read-session-billed.sh`
for the real cache/cost split of a session transcript. `compare` diffs two
ledger files per contributor and flags inflation. `trend` computes per-run
contributor shares bucketed by `(workflow, stage)` and flags a latest-run
breach beyond a rolling median ± 3·MAD control band. `busts` reads a session
transcript and attributes each avoidable cache-bust deficit to a cause
(model-switch / TTL-expiry / prefix-change), printing per-bust and total
avoidable cost; compaction-driven deficits are reported but excluded from waste.
`journey` delegates to `scripts/read-session-journey.sh` to derive per-stage /
skill / subagent cost from a transcript (with depth-agnostic subagent
attribution via a `parentUuid` fixpoint join), writes a bounded report artifact,
and prints a ≤3-line pointer + headline to context; `--stdout` dumps the full
body. Everything is advisory and opt-in; the reporter gates no workflow.

## Protocol

### Arguments

```
token-report.sh [diagnose] [--ledger <file.jsonl>]
token-report.sh billed
token-report.sh compare <baseline.jsonl> <after.jsonl>
token-report.sh trend [--ledger <file.jsonl>]
token-report.sh busts [--transcript <file.jsonl>]
token-report.sh journey [--transcript <file.jsonl>] [--output-dir <dir>] [--format md|json] [--descriptor <x>] [--stdout]
```

- First positional — subcommand, one of `diagnose` (default), `billed`,
  `compare`, `trend`, `busts`, `journey`. Unknown subcommands print `unknown
  subcommand: <name>` to stderr and exit `2`.
- `--ledger <file.jsonl>` — ledger path for `diagnose` and `trend`. Defaults to
  `$ARBORETUM_TOKEN_LEDGER`, else `.arboretum/token-ledger/session.jsonl`.
- `compare` consumes two positional ledger paths (`<baseline> <after>`).
- `billed` reads the transcript path from `$ARBORETUM_TRANSCRIPT`; unset is a
  blocking error (`set ARBORETUM_TRANSCRIPT`, exit `2`).
- `busts` reads the transcript from `--transcript <file.jsonl>` or, if omitted,
  `$ARBORETUM_TRANSCRIPT`; neither set is a blocking error (exit `2`).
- `journey` reads the transcript from `--transcript <file.jsonl>` or, if omitted,
  `$ARBORETUM_TRANSCRIPT`; neither set is a blocking error (exit `2`). For
  `output_dir` and `format`, precedence is **flag > env > `.arboretum.yml`
  `token_journey:` > default** (`.arboretum/token-journey`, `md`). `--descriptor`
  overrides the auto-resolved name (cascade: open PR number > `$ISSUE` > branch
  number > session id). `--stdout` additionally prints the full report body.

### Exit codes

- `0` — the dispatched subcommand completed and printed its summary.
- `2` — unknown subcommand, `billed` invoked without `$ARBORETUM_TRANSCRIPT`, or
  `busts`/`journey` invoked without a transcript (`--transcript` or
  `$ARBORETUM_TRANSCRIPT`).

### Side effects

Read-only with respect to the repository for `diagnose`/`billed`/`compare`/
`trend`/`busts` — these spawn `jq` (`diagnose`), `python3` (`compare`, `trend`,
`busts`), or `scripts/read-session-billed.sh` (`billed`), read the named ledger
or transcript files, write nothing to disk, and make no network calls. `journey`
delegates to `scripts/read-session-journey.sh`, which **writes one report
artifact** to `<output_dir>/<transcript-timestamp>-<descriptor>.<ext>`; the
filename is derived from the transcript's last-message timestamp, so re-running
the same transcript is deterministic and idempotent (same path, same bytes). The
descriptor cascade is best-effort and may call `gh pr view` (network);
offline/CI runs fall through to `$ISSUE`/branch/session deterministically.

## Test surface

- **CLI-1: diagnose groups by contributor.** Over a fixture ledger, `diagnose`
  prints one summary line per contributor with row count, byte total, and
  est-token total — never the raw rows.
- **CLI-2: compare flags inflation.** `compare baseline after` prints a signed
  per-contributor delta and marks positive (inflated) deltas.
- **CLI-3: trend breach detection.** A series whose latest-run contributor
  share jumps beyond median ± 3·MAD prints a breach line naming the
  `(workflow, stage)` bucket and the contributor.
- **CLI-4: unknown subcommand exits 2.** An unrecognized first positional exits
  `2` with a diagnostic.
- **CLI-5: busts attributes deficits and excludes compaction.** Over a transcript
  fixture, `busts` prints a per-bust cause + avoidable cost and a total, with
  compaction-driven deficits reported but excluded from the waste total; a
  missing transcript exits `2`.
- **CLI-6: journey attributes per-stage/skill/subagent cost and inverts output.**
  Over a transcript fixture, `journey` writes a report artifact and prints only a
  pointer + headline by default (no report body on stdout); `--stdout` dumps the
  body; subagents (including grandchildren) roll up to their originating stage via
  the `parentUuid` fixpoint, broken chains warn without crashing; re-running the
  same transcript is idempotent (same path + bytes); a missing transcript exits
  `2`. Covered by `scripts/_smoke-test-token-journey.sh`.

## Versioning

- **1.0** — initial contract: diagnose / billed / compare / trend / busts subcommands (2026-06-06).
- **1.1** — journey subcommand (2026-06-07).
