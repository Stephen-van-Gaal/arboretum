---
seam: validate-cross-refs
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/validate-cross-refs.sh
---
<!-- owner: pipeline-contracts-template -->

# validate-cross-refs — `validate-cross-refs.sh` Cross-Document Integrity-Validator Contract

The cross-cutting integrity validator that checks consistency *across* governance documents — that definition references in specs resolve on disk, that every spec listed in `docs/REGISTER.md` exists, that `contracts.yaml` requires/provides pins agree with the specs' tables, and that frontmatter dependency notation is well-formed. This contract pins the validator's own protocol — its four checks, their output wording, and its exit codes — so its consumers (the Check-4 smoke test and the `ci-checks.sh` gate) can assert on its output without re-deriving the cross-reference rules. Standalone validator contract per design decision D-7a-2: it governs the *script that checks document integrity*, not any single seam.

## Producer

`scripts/validate-cross-refs.sh` — producer-type: `script`.

Takes one optional positional argument — `[project-dir]` (defaults to `$(pwd)`) — and resolves `docs/REGISTER.md`, `contracts.yaml`, and `docs/specs/` beneath it. Runs four checks, accumulating a single `issues` counter:

- **Check 1** — every `definitions/…` reference scraped from each spec resolves to an existing file under `docs/`. Backticks and angle brackets are excluded from the scrape so markdown-wrapped refs and `<placeholder>` prose are not treated as real references; line-range citation suffixes such as `definitions/foo.md:12-34` are not part of the filesystem path.
- **Check 2** — every `*.spec` row in `docs/REGISTER.md` names a file that exists in `docs/specs/`.
- **Check 3** — `contracts.yaml` `requires:`/`provides:` pins for each spec match the spec's own `## Requires`/`## Provides` `@vN` pins, in both directions (spec→yaml and yaml→spec).
- **Check 4** — each frontmatter `requires:`/`provides:` entry is well-formed: path-shaped entries (containing `/`) end in `.md`; versioned entries (containing `@`) match `@v<N>` exactly; bare names pass.

Missing inputs are skipped with an `info` line (`No REGISTER.md — skipping`, etc.), not treated as failures. Read-only — never mutates any document.

## Consumer

Consumer-type: `script`. Two consumer classes assert on this validator's output:

- **Check-4 smoke test** — `scripts/_smoke-test-validate-cross-refs.sh` builds a temp `project-dir` fixture tree and asserts: a well-formed fixture exits 0 with `All frontmatter dep notations are well-formed`; a fixture with five malformed dep entries exits non-zero with one distinct per-entry warning each (`… looks like a path but lacks .md suffix`, `… has malformed version`); and a no-requires/provides spec leaves Check 4 green. The exact warning wording is contract — the smoke test greps on those lines verbatim.
- **`ci-checks.sh` gate** — the `=== Cross-reference validation ===` step runs `bash scripts/validate-cross-refs.sh || fail=1`, treating any non-zero exit as a CI failure.

**Consumer obligations:** consumers MUST treat a non-zero exit as integrity drift and MUST NOT swallow it; they MUST match the per-check wording (the `✓`/`✗` lines and the `ISSUES FOUND:` / `CONSISTENT:` summary) rather than re-implementing the cross-reference rules. The whole-script exit code is authoritative: a green Check 4 inside a script that fails another check is still a failing script.

## Protocol shape

### Inputs

- Positional argument 1 (optional): `[project-dir]` — the project root to validate (defaults to `$(pwd)`). No stdin. The validator reads `docs/REGISTER.md`, `contracts.yaml`, and `docs/specs/*.spec.md` beneath it; each missing input is skipped, not failed.

### Outputs

- **stdout:** per-check section headers (`━━━ Check N: … ━━━`), one `  ✓ <summary>` line per passing check, one `  ✗ <warning>` line per issue, `  · <reason>` info lines for skipped checks, and a final summary — `CONSISTENT: All cross-reference checks passed.` (clean) or `ISSUES FOUND: <N> cross-reference problems detected.` (drift). Note: unlike the S2/S3/S9 line validators, this validator writes its findings to **stdout**, not stderr.
- **Per-issue warning wording (contract surface):**
  - Check 1: `<spec>.spec.md references <ref> but <file>.md does not exist`
  - Check 2: `REGISTER.md lists <spec> but file does not exist in docs/specs/`
  - Check 3: `<spec>.spec.md: requires <pin> but contracts.yaml disagrees or is missing it` (and the symmetric `contracts.yaml has <pin> for <spec> but spec does not require it`, plus the `provides` variants)
  - Check 4: `<spec>.spec.md: <field> entry "<entry>" looks like a path but lacks .md suffix` / `… has malformed version (expected @v<N>, got @<v>)`
- **Exit codes:** `0` — all checks consistent; `1` — one or more issues found (`issues > 0`). There is **no exit-2 invocation path**: the script runs under `set -euo pipefail`, so an unexpected internal error (e.g. an unreadable file mid-run) aborts via `set -e` rather than returning a distinct code, and a wrong/extra argument beyond `[project-dir]` is simply ignored.

### Invariants

- **Findings go to stdout, not stderr.** The `✓`/`✗`/summary lines are emitted on stdout; consumers capturing this validator should redirect `2>&1` (as both consumers do) or read stdout.
- **Whole-document report, not first-fail.** All four checks always run; the summary `<N>` is the total issue count across every check, not the first failure.
- **Missing input is skipped, not failed.** Absent `REGISTER.md`, `contracts.yaml`, or `docs/specs/` yields a `·` info line and does not increment `issues`.
- **No mutation.** Read-only — never writes any document.
- **Requires/provides block isolation (Check 3).** The `requires:` comparison reads only the `requires:` sub-block in `contracts.yaml`; the terminating `provides:` line and provider entries MUST NOT be included. Likewise, the `provides:` comparison reads only provider entries. This is portable across GNU and BSD/macOS toolchains.

## Test surface

- **VCR-1:** real repo root (`bash validate-cross-refs.sh` with no arg, project-dir defaulting to the repo) → exit 0, stdout `CONSISTENT: All cross-reference checks passed.` and `All frontmatter dep notations are well-formed`.
- **VCR-2:** the existing smoke test (`scripts/_smoke-test-validate-cross-refs.sh`) passes — well-formed fixture exits 0, line-range definition citations do not create fake filenames, a spec with both `requires:` and `provides:` passes Check 3, five malformed dep entries each flagged with their distinct warning, and a no-requires/provides spec leaves Check 4 green.

## Versioning

- **1.1** (2026-06-02) — Check 1 ignores line-range suffixes in definition citations, and Check 3 now isolates `requires:` and `provides:` blocks portably instead of documenting the BSD/macOS sed bleed as a known quirk. Issues #410 and #476.
- **1.0** (2026-05-30) — initial contract. Validator shape as of `scripts/validate-cross-refs.sh` on `main` (four checks, stdout `✓`/`✗` wording, exit 0/1, no exit-2 path). Issue #303 (WS5 PR 7a).
