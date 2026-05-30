---
seam: validate-test-surface
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/validate-test-surface.sh
---
<!-- owner: pipeline-contracts-template -->

# validate-test-surface — `validate-test-surface.sh` S3-6 Enforcement-Validator Contract

The enforcement validator that checks a `/design`-spec's test-surface discipline against the S3 seam's S3-6 post-condition (`docs/contracts/s3-build-to-finish.contract.md`). It confirms that every changed test file is accounted for in the spec's `test-surface-changes:` block (or `## Test surface changes` body section), or — absent such a block — that the spec's test-tiers are all explicitly `n/a — <reason>` and no test files changed. This contract pins the validator's own protocol — the exact `S3-6:` message format and exit codes — so the consumers (the S3 contract-test file) can assert on its output without re-deriving the test-surface-discipline rule. Standalone validator contract per design decision D-7a-2: it governs the *script that checks the seam*, distinct from the S3 seam contract that governs the `/build` → `/finish` interface itself.

## Producer

`scripts/validate-test-surface.sh` — producer-type: `script`.

Takes two positional arguments — the design-spec path (arg 1) and a changed-test-files list file (arg 2, one path per line) — and checks the S3-6 test-surface-discipline rule:

- If the spec carries a `test-surface-changes:` frontmatter block **or** a `## Test surface changes` body section, every entry in the changed-files list MUST appear as a listed token in that block. The block is tokenized with python3, which strips YAML list prefixes (`- `, `-`), surrounding quotes, and trailing reason text (em-dash / comma / `#`-comment forms) before exact set-membership comparison — so the contract-compliant reason-bearing form `- tests/foo.sh — added for X` parses correctly and regex-metachar filenames never wildcard-match.
- The spec's `test-tiers:` block is also parsed: each of `unit`, `contract`, `integration` must be `yes` (quoted or unquoted) or `n/a — <reason>`; missing or malformed tiers are issues.
- Absent any test-surface block, the pair is valid **only** if all three tiers are explicitly `n/a — <reason>` AND the changed-files list is empty.

Emits one summary `S3-6:` line plus one indented bullet per issue to stderr; never mutates the spec or list.

## Consumer

Consumer-type: `script`. The S3 contract test is the consumer:

- `tests/contracts/s3/s3-6-success-test-surface-discipline.sh` — invokes the validator against the shared `tests/contracts/fixtures/design-with-test-surface*.md` + `test-surface-list-*.txt` fixtures: the good pair (block present, every file listed) must exit 0; the bad pair (`design-good.md`, which lacks the block, + a non-empty list) must exit 1 with `S3-6` on stderr naming the missing file; and the metachar / quoted / reason-bearing regression fixtures assert the tokenizer's exact-match behaviour.

The validator is also reachable as an S3-6 gate from the `/build`/`/finish` skills, which treat a non-zero exit as drift to surface.

**Consumer obligations:** consumers MUST treat any non-zero exit as drift and MUST NOT swallow it; they MUST match the `S3-6:` summary and `  - <reason>` bullet shape rather than re-implementing the test-surface-discipline rule. A consumer testing a spec with changed files MUST pass arg 2 (the changed-files list) — omitting it is an invocation error (exit 2), not a clean pass.

## Protocol shape

### Inputs

- Positional argument 1: `<design-spec-path>` — a Markdown file with leading YAML frontmatter and/or a `## Test surface changes` body section.
- Positional argument 2: `<changed-files-list>` — a file with one changed test-file path per line (may be empty). No stdin. Exactly two arguments; any other count is an invocation error.

### Outputs

- **stdout:** none.
- **stderr (drift only):** a summary line `S3-6: <N> issue(s) in <spec-path>` followed by one indented bullet per issue, `  - <reason>` (e.g. `  - test file tests/example/foo_test.sh changed but not listed in test-surface-changes block`, `  - spec lacks test-surface-changes block and (test-tiers not all explicit N/A OR changed-files list not empty)`, `  - test-tier unit malformed: '…' (expected 'yes' or 'n/a — <reason>')`).
- **stderr (invocation error):** `usage: validate-test-surface.sh <spec> <changed-files-list>` (wrong arg count), or `S3-6: spec not found: <path>` / `S3-6: changed-files list not found: <path>` (a named argument is not an existing file).
- **Exit codes:** `0` — pair satisfies S3-6; `1` — one or more contract violations (issues on stderr); `2` — invocation problem (wrong arg count, or a named file missing/unreadable).

### Invariants

- **Drift goes to stderr, never stdout.** stdout stays empty; the `S3-6:` block is stderr-only.
- **Exact-token set match, not regex.** The test-surface block is tokenized and compared by exact string membership, so a filename differing by one character (`foo-testXsh` vs `foo-test.sh`) does not match, and a YAML-quoted entry (`- "foo.sh"`) matches its unquoted changed-files counterpart.
- **`yes`/quoted-`yes` equivalence.** A `test-tiers` tier of `yes`, `"yes"`, or `'yes'` is accepted identically, matching `validate-design-spec.sh`'s PyYAML treatment so a spec valid in one tool is valid in the other.
- **Reason-bearing entries parse.** The contract-compliant `- tests/foo.sh — <reason>` (and comma / `#`-comment reason forms) tokenize to the bare filename; the reason text is parsed but ignored for membership.
- **No mutation.** Read-only — never writes the spec, the list, or any file other than its own scratch tempfiles.
- **Exit-2 carries an `S3-6:` prefix for a missing named file, but `usage:` for wrong arg count.** Unlike the S2/S3/S9 line validators (whose exit-2 path never emits the seam prefix), a missing-file invocation error here is reported as `S3-6: spec not found: …` / `S3-6: changed-files list not found: …`. The `S3-6:` prefix alone therefore does not distinguish exit-1 drift from an exit-2 missing-file error; the exit code is authoritative. A wrong arg count still uses the prefix-free `usage:` form.

## Test surface

- **VTS-1:** good pair (`design-with-test-surface.md` + `test-surface-list-good.txt`) → exit 0, no `S3-6:` summary on stderr.
- **VTS-2:** bad pair — `design-good.md` (no test-surface block) + non-empty `test-surface-list-bad.txt` → exit 1, stderr `S3-6:` summary + the `spec lacks test-surface-changes block …` bullet.
- **VTS-3:** metachar near-miss (`design-with-test-surface-metachar.md` + `test-surface-list-good.txt`) → exit 1, stderr `  - test file tests/example/foo_test.sh changed but not listed`.
- **VTS-4:** YAML-quoted entry (`design-with-test-surface-quoted.md` + `test-surface-list-good.txt`) → exit 0 (quotes stripped, token matches).
- **VTS-5:** reason-bearing entry (`design-with-test-surface-reasons.md` + `test-surface-list-good.txt`) → exit 0.
- **VTS-6:** invocation error — non-existent spec path → exit 2, stderr `S3-6: spec not found`, no `S3-6: <N> issue(s)` summary line.

## Versioning

- **1.0** (2026-05-30) — initial contract. Validator shape as of `scripts/validate-test-surface.sh` on `main` (S3-6 stderr format, exit 0/1/2; missing-file invocation errors carry the `S3-6:` prefix). Issue #303 (WS5 PR 7a).
