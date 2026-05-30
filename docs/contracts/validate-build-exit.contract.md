---
seam: validate-build-exit
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/validate-build-exit.sh
---
<!-- owner: pipeline-contracts-template -->

# validate-build-exit — `validate-build-exit.sh` S3 Enforcement-Validator Contract

The enforcement validator that checks a `/build exited` journey-log line (and its referenced design spec) against the S3 seam (`docs/contracts/s3-build-to-finish.contract.md`). This contract pins the validator's own protocol — the exact `S3-DRIFT:` message format and exit codes — so the S3 contract-test files can assert on its output without re-deriving the S3 post-condition rules. Standalone validator contract per design decision D-7a-2: it governs the *script that checks the seam*, distinct from the S3 seam contract that governs the `/build` → `/finish` interface itself.

## Producer

`scripts/validate-build-exit.sh` — producer-type: `script`.

Reads the first line of the log-line file (arg 1) and checks the S3 post-conditions:

- **S3-1** — the line must carry an `exit-status:` field.
- **S3-2** — `exit-status` value must be in the closed enum `{success, escape-hatch}`. The token boundary is whitespace **or** comma (log-stage.sh emits comma-separated KV form).
- **S3-3** — `exit-status: success` with a non-`null` `plan:` requires the design-spec path argument (arg 2); the plan file must resolve under the repo root, and any unchecked plan checkbox (`- [ ]`) lacking a `(skipped: …)` marker is drift.
- **S3-7** — `exit-status: escape-hatch` requires arg 2 to point at a design spec carrying an `^escape-hatch:` block.

Emits one summary `S3-DRIFT:` line plus one indented `  - <assertion-id>: <reason>` bullet per issue to stderr; never mutates the log line or spec.

## Consumer

Consumer-type: `script`. The S3 contract-test files under `tests/contracts/s3/` are the consumers:

- `s3-1-exit-status-emitted.sh` — asserts `S3-1: log line missing 'exit-status:'`.
- `s3-2-exit-status-enum.sh` — asserts `S3-2: exit-status value not in`.
- `s3-3-success-plan-resolved.sh`, `s3-4-success-plan-NA.sh`, `s3-5-success-tests-green.sh`, `s3-6-success-test-surface-discipline.sh`, `s3-7-escape-hatch-trigger-recorded.sh`, `s3-9-comma-separated-form.sh` — invoke the validator against the shared `tests/contracts/fixtures/build-exit-*.txt` fixtures and assert exit code + an `assertStderr` substring.

**Consumer obligations:** consumers MUST treat any non-zero exit as drift and MUST NOT swallow it; they MUST match the `S3-DRIFT:` summary and `  - <assertion-id>: <reason>` bullet shape rather than re-implementing the S3 post-condition rules. Consumers that test `success` + non-null `plan` MUST pass arg 2 (the design-spec path) — omitting it is itself S3-3 drift.

## Protocol shape

### Inputs

- Positional argument 1: `<log-line-file>` — a file whose first line is the `/build exited` journey-log line.
- Positional argument 2 (optional): `<design-spec-path>` — required when `exit-status` is `escape-hatch`, or when `exit-status` is `success` and `plan:` is non-`null`.
- No stdin. One or two arguments; zero or more-than-two is an invocation error.

### Outputs

- **stdout:** none.
- **stderr (drift only):** a summary line `S3-DRIFT: <N> issue(s) in <log-line-file>` followed by one indented bullet per issue, `  - <assertion-id>: <reason>` (e.g. `  - S3-1: log line missing 'exit-status:' field`, `  - S3-2: exit-status value not in {success, escape-hatch} (got '…')`, `  - S3-7: design spec missing 'escape-hatch:' block naming the trigger criterion`).
- **stderr (invocation error):** `usage: validate-build-exit.sh <log-line-file> [<design-spec-path>]` or `validate-build-exit.sh: log file not found: <path>`.
- **Exit codes:** `0` — log line + spec satisfy S3 post-conditions; `1` — one or more contract violations (issues on stderr); `2` — invocation problem (wrong arg count, log file missing).

### Invariants

- **Drift goes to stderr, never stdout.** stdout stays empty; the `S3-DRIFT:` block is stderr-only.
- **Comma-OR-whitespace token boundary.** `exit-status:` and `plan:` values are extracted with a boundary of whitespace or comma, so the comma-separated KV emission form (`exit-status: success, plan: …`) parses without a trailing comma contaminating the value.
- **Whole-line report, not first-fail.** All applicable assertions are evaluated; the summary `<N>` is the total issue count.
- **Spec-arg-required-when-relevant.** A `success` exit with a non-`null` plan, or any `escape-hatch` exit, with no arg 2 is itself drift (S3-3 / S3-7) — the validator does not silently skip the unverifiable check.
- **No mutation.** Read-only — never writes the log line, the spec, or the plan file.
- **Exit-2 is distinct from exit-1.** An invocation problem exits `2` with no `S3-DRIFT:` line; contract drift exits `1` and emits one.

## Test surface

- **VBE-1:** good success fixture (`tests/contracts/fixtures/build-exit-success-good.txt`) with its design-spec arg (`design-good.md`) → exit 0, no `S3-DRIFT:` on stderr.
- **VBE-2:** missing `exit-status:` fixture (`build-exit-no-status.txt`) → exit 1, stderr `  - S3-1: log line missing 'exit-status:' field`.
- **VBE-3:** out-of-enum `exit-status` fixture (`build-exit-bad-status-enum.txt`) → exit 1, stderr `  - S3-2: exit-status value not in`.
- **VBE-4:** escape-hatch line with a spec lacking the `escape-hatch:` block (`build-exit-escape-hatch-no-trigger.txt` + `design-good.md`) → exit 1, stderr `  - S3-7: design spec missing 'escape-hatch:' block`.
- **VBE-5:** invocation error — non-existent log file → exit 2, stderr `log file not found`, no `S3-DRIFT:` line.

## Versioning

- **1.0** (2026-05-30) — initial contract. Validator shape as of `scripts/validate-build-exit.sh` on `main` (S3-DRIFT stderr format, exit 0/1/2). Issue #303 (WS5 PR 7a).
