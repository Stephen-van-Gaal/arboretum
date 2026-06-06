---
seam: read-journey-log
version: 1.1
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/read-journey-log.sh
---
<!-- owner: pipeline-contracts-template -->

# read-journey-log — `read-journey-log.sh` Journey-Log TSV Reader Contract

The seam between `scripts/read-journey-log.sh` (which reads pipeline-state journey-log entries off a GitHub issue's comments and emits them as TSV) and `scripts/land-handler.sh`, which invokes the reader with stage/action filters and parses the TSV rows to recover prior `/land` summary state. The script's stdout is a tab-separated, column-ordered protocol; this contract pins the column order, the `key=value` pair encoding, the sort/filter semantics, and the exit codes so the handler never re-parses the raw comment line format.

## Producer

`scripts/read-journey-log.sh` — producer-type: `script`.

Takes a required issue number, plus optional `--stage <name>`, `--action <name>`, and `--latest` flags. It resolves the repo via `gh repo view --json nameWithOwner`, fetches the issue's comments via `gh api repos/<repo>/issues/<n>/comments --paginate`, and parses every comment body that contains the marker `<!-- pipeline-state:log -->`. Each log line of the form `- <ts> — <stage> <action>[, <k>: <v>, …]` (the format written by `log-stage.sh`) is parsed into a TSV row. Quoted values produced by the writer's quoter are unquoted (with `\"`/`\\` unescaped; `\n` is kept as the two-char escape so the TSV stays one-row-per-entry). Rows are sorted ascending by timestamp; `--stage`/`--action` filter by exact match; `--latest` keeps only the final (most-recent) row after sorting and filtering.

Only comments whose `user.login` is on the project's `trust.journey_log_authors` allowlist (`.arboretum.yml`) contribute rows when that key is present; when the key is absent the reader is permissive (all authors surface) and emits a single `stderr` migration warning. Every emitted field is control-char-scrubbed at the boundary (#249).

It depends on the `gh` CLI being installed and authenticated and on `python3` for parsing. The `gh api --paginate` output (concatenated per-page JSON arrays) is handled with `raw_decode`. The allowlist is resolved via `scripts/read-trust-config.sh` (overridable in tests with `TRUST_CONFIG_OVERRIDE`).

## Consumer

Consumer-type: `script`. One downstream consumer:

- **`scripts/land-handler.sh`** (~line 38, `READER="$SCRIPT_DIR/read-journey-log.sh"`) invokes the reader with `--stage /land --action summary`, then parses the TSV: it splits a row on tabs, reads field 1 as the timestamp (`awk -F'\t' '{print $1}'`), and recovers `head_sha=` / `head_sha_unchanged_count=` pairs by tokenizing the row on tabs and matching the `key=` prefix.

**Consumer obligations:**

- Consumers MUST split each row on the tab character; the first three fields are always `timestamp`, `stage`, `action`, in that order, and any remaining fields are `key=value` pairs.
- Consumers MUST recover a pair's value by matching the `<key>=` prefix on a tab-tokenized field — pair order within a row follows the source line and is not otherwise guaranteed.
- Consumers MUST treat a zero-row (empty) result as "no matching entries," distinct from a non-zero exit (which signals a bad-args / gh-missing / fetch failure).

## Protocol shape

### Inputs

- `<issue-number>` positional (required). Optional `--stage <name>`, `--action <name>`, `--latest`.
- Reads GitHub issue comments via `gh` (requires `gh` on PATH, an authenticated session, and a resolvable repo from the current directory).

### Outputs

- stdout: zero or more TSV rows. Each row is `<timestamp>\t<stage>\t<action>[\t<key>=<value>…]` — the first three tab-separated fields are always present and ordered; subsequent fields are `key=value` pairs. Rows are sorted ascending by timestamp.
- stderr (non-zero exit only): a diagnostic — a `Usage: read-journey-log.sh …` line on the bad-argument path (missing/invalid issue number), or a `read-journey-log.sh: …` message for the other failure modes (gh missing, unauthenticated, repo unresolvable, comment fetch failed).
- Exit codes: `0` — success (zero or more rows emitted, including the empty case); `1` — bad args, `gh` missing, unauthenticated, or repo unresolvable; `2` — comment fetch failed.

### Invariants

- **Column order.** Every emitted row's first three tab-separated fields are `timestamp`, `stage`, `action`, in that order. Trailing fields are `key=value` pairs.
- **Marker-gated.** Only comment bodies containing `<!-- pipeline-state:log -->` contribute rows; non-log comments are ignored.
- **Timestamp-sorted.** Rows are sorted ascending by timestamp before any `--latest` truncation.
- **Filter semantics.** `--stage`/`--action` keep only rows whose stage/action exactly equals the filter value; `--latest` keeps only the last row after sort+filter.
- **Pair unquoting.** A `key=value` pair whose source value was quoted by the writer is emitted unquoted, with `\"` and `\\` unescaped; an embedded `\n` is preserved as the two-char escape so one log entry stays one TSV row.
- **Author-trust gated.** When `trust.journey_log_authors` is present in `.arboretum.yml`, only comments authored by an allowlisted `user.login` contribute rows; non-allowlisted authors' marker blocks are silently ignored (not errors — they may be legitimate contributor notes). When the key is absent, all authors are surfaced and a single migration warning is written to stderr.
- **Read-side scrubbed.** Every emitted field (timestamp, stage, action, and each `key=value` pair) is stripped of ASCII control characters (`[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]`) before printing. Only the control byte is removed; printable residue of an escape sequence is preserved.
- **No mutation.** Read-only — the script never writes the issue, comments, or any repo file (only a private mktemp scratch file it removes on exit).

## Test surface

- **RJL-1:** A stubbed comments payload with two log comments → two TSV rows, each with `timestamp`/`stage`/`action` as the first three tab fields, sorted ascending by timestamp.
- **RJL-2:** A comment WITHOUT the `<!-- pipeline-state:log -->` marker contributes no rows.
- **RJL-3:** `--stage <name>` filters to only matching-stage rows; `--action <name>` filters to only matching-action rows.
- **RJL-4:** `--latest` returns exactly one row — the most-recent after sort+filter.
- **RJL-5:** A `key: value` pair on the source line is emitted as a `key=value` tab field; a quoted value (e.g. one containing `, `) is unquoted, with the comma preserved inside the single field.
- **RJL-6:** `gh` missing from PATH → exit 1.
- **RJL-7:** No matching comments → exit 0 with empty stdout (zero rows is success, not an error).
- **RJL-8:** With the allowlist key present, a marker comment authored by a non-allowlisted `user.login` contributes no rows; an allowlisted author's rows are surfaced.
- **RJL-9:** With the allowlist key absent, all authors surface and a single `trust.journey_log_authors not configured` warning is written to stderr.
- **RJL-10:** A logged value containing an ESC byte is emitted with the control byte stripped and the printable residue preserved.

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/read-journey-log.sh` on this branch. Issue #303 (WS5 PR 7a).
- **1.1** (2026-06-06) — author-trust filter (`trust.journey_log_authors` allowlist, present→strict / absent→permissive+warning) + read-side control-char scrub. Issue #249.
