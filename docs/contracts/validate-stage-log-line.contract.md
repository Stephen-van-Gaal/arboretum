---
seam: validate-stage-log-line
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/validate-stage-log-line.sh
---
<!-- owner: pipeline-contracts-template -->

# validate-stage-log-line — `validate-stage-log-line.sh` S9 Enforcement-Validator Contract

The enforcement validator that checks a journey-log comment block — as emitted by `scripts/log-stage.sh` — against the S9 seam's comment-marker conformance assertion (`docs/contracts/s9-stage-to-log-helper.contract.md`, assertion S9-5). This contract pins the validator's own protocol — the exact `S9-DRIFT:` message format and exit codes — so the S9 contract test can assert on its output without re-deriving the journey-log line grammar. Standalone validator contract per design decision D-7a-2: it governs the *script that checks the seam*, distinct from the S9 seam contract that governs the stage-skill → `log-stage.sh` interface itself.

## Producer

`scripts/validate-stage-log-line.sh` — producer-type: `script`.

Reads the comment block at the file argument (arg 1) and validates the two-line shape with python3:

- **Line 1** must be exactly the canonical marker `<!-- pipeline-state:log -->`.
- **Line 2** must begin `- `, then `<ISO-8601-UTC-zulu> — <stage> <action>[, <key>: <value>]*` where: the timestamp matches `YYYY-MM-DDTHH:MM:SSZ`; the separator is ` — ` (em-dash with surrounding spaces); the stage is a `/`-prefixed lowercase-kebab token; the action is one of the recognized vocabulary `{entered, exited, skipped, re-entered, summary, repair, dispatched}` (CWD-2's seven entries; `repair` is deprecated as of #570 — no longer emitted by log-stage, but still recognized here so historical journey-log lines validate); KV pairs use `key: value` form, comma-space separated, with any value containing the structural `, ` delimiter double-quoted (S9-7 escaping).

Emits one summary `S9-DRIFT:` line plus one indented `  - <assertion-id>: <reason>` bullet per issue to stderr; never mutates the file.

## Consumer

Consumer-type: `script`. The S9 contract test is the consumer:

- `tests/contracts/s9/s9-5-comment-marker-conformance.sh` — invokes the validator against the shared `tests/contracts/fixtures/log-stage-comment-*.txt` fixtures: the good fixture must exit 0, and each bad fixture (bad marker, bad timestamp, bad action) must exit 1 with the matching `assertStderr` substring (`S9-5: missing marker`, `S9-5: timestamp`, `S9-2: action`).

**Consumer obligations:** the consumer MUST treat any non-zero exit as drift and MUST NOT swallow it; it MUST match the `S9-DRIFT:` summary and `  - <assertion-id>: <reason>` bullet shape (note the assertion-id prefix is `S9-5`, `S9-2`, or `S9-7` depending on the violated rule) rather than re-implementing the line grammar.

## Protocol shape

### Inputs

- Positional argument 1: `<comment-file>` — a file whose first two lines are the marker + journey-log data line. No stdin. Exactly one argument; zero or more-than-one is an invocation error.

### Outputs

- **stdout:** none.
- **stderr (drift only):** a summary line `S9-DRIFT: <N> issue(s) in <file>` followed by one indented bullet per issue, `  - <assertion-id>: <reason>`. Assertion ids: `S9-5` (marker / data-line shape / timestamp / stage / key form), `S9-2` (action not in the seven-entry vocabulary), `S9-7` (unquoted/unterminated quoted value carrying the structural `, ` delimiter).
- **stderr (invocation error):** `usage: validate-stage-log-line.sh <comment-file>` or `validate-stage-log-line.sh: file not found: <path>`.
- **Exit codes:** `0` — line conforms; `1` — one or more contract violations (issues on stderr); `2` — invocation problem (wrong arg count, file missing).

### Invariants

- **Drift goes to stderr, never stdout.** stdout stays empty; the `S9-DRIFT:` block is stderr-only.
- **Whole-block report, not first-fail.** All applicable checks are evaluated; the summary `<N>` is the total issue count.
- **Assertion-id is rule-specific, not uniform.** A given drift bullet is prefixed with the id of the rule it violated (`S9-5` / `S9-2` / `S9-7`), not a single seam-wide id.
- **Literal-Z timestamp.** The timestamp must end with a literal `Z`; a numeric offset (`+00:00`) is drift, not an accepted equivalent.
- **No mutation.** Read-only — never writes the comment file or any file other than its own scratch tempfile.
- **Exit-2 is distinct from exit-1.** An invocation problem exits `2` with no `S9-DRIFT:` line; contract drift exits `1` and emits one.

## Test surface

- **VSL-1:** good fixture (`tests/contracts/fixtures/log-stage-comment-good.txt`) → exit 0, no `S9-DRIFT:` on stderr.
- **VSL-2:** bad marker fixture (`log-stage-comment-bad-marker.txt`) → exit 1, stderr `  - S9-5: missing marker`.
- **VSL-3:** bad timestamp fixture (`log-stage-comment-bad-timestamp.txt`) → exit 1, stderr `  - S9-5: timestamp`.
- **VSL-4:** bad action fixture (`log-stage-comment-bad-action.txt`) → exit 1, stderr `  - S9-2: action`.
- **VSL-5:** bad quoting fixture (`log-stage-comment-bad-quoting.txt`) → exit 1, stderr `  - S9-7:` (unquoted embedded `, ` delimiter).
- **VSL-6:** invocation error — non-existent path → exit 2, stderr `file not found`, no `S9-DRIFT:` line.

## Versioning

- **1.0** (2026-05-30) — initial contract. Validator shape as of `scripts/validate-stage-log-line.sh` on `main` (S9-DRIFT stderr format, exit 0/1/2). Issue #303 (WS5 PR 7a).
