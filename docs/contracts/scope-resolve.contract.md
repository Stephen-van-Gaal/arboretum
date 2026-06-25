---
seam: scope-resolve
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - file-scope-value
related-designs:
  - docs/superpowers/specs/2026-06-20-adopter-ci-scope-markers-design.md
owns:
  - scripts/lib/scope-resolve.sh
---
<!-- owner: pipeline-contracts-template -->

# scope-resolve — Governance-Scope Marker Resolution Contract

`scripts/lib/scope-resolve.sh` is the single source of `# scope:` reading. It is the
only place the `# scope:` marker grammar is parsed; `ci-checks.sh` and
`health-check.sh` consume it rather than re-inlining the regex (the parallel-drift
class of #124).

## Producer

`scripts/lib/scope-resolve.sh` — a sourceable library, producer-type: `script`.
Bash 3.2 compatible. Defines two functions:

- `file_scope <path>` — echoes `plugin-only | consumer | any | none`. Reads
  `# scope:` from the first 8 lines of `.sh`/`bin` files and the `scope:`
  frontmatter key of `SKILL.md`. Never fails; an unreadable or unmarked file
  resolves to `none`.
- `governed_by_framework_in_consumer_root <path>` — returns `0` when the file is
  framework-governed (scope `plugin-only`), `1` otherwise
  (`consumer`/`any`/`none`).

## Consumer

- `scripts/ci-checks.sh` — `smoke_test_applicable()` reads `file_scope` to decide
  whether a smoke test runs in this root.
- `scripts/health-check.sh` — Check 3 Half A (`missing_owner_spec_is_applicable`)
  and Half B consult `governed_by_framework_in_consumer_root` as the **primary**
  framework-file signal; install-manifest membership is the fallback for unmarked
  files.

## Protocol shape

### Inputs

- `file_scope <path>` — one positional path to a `.sh`/`bin` file or a `SKILL.md`.
- `governed_by_framework_in_consumer_root <path>` — same single positional path.

### Outputs

- `file_scope` stdout: exactly one token — `plugin-only` | `consumer` | `any` |
  `none` — followed by a newline. Exit code is always `0`.
- `governed_by_framework_in_consumer_root` returns exit code `0` when the file's
  scope is `plugin-only`, `1` otherwise (`consumer`/`any`/`none`). No stdout.

### Invariants

- **Closed value set.** `file_scope` always echoes one of the four tokens, never
  an empty string or a fifth value; an unreadable or unmarked file resolves to
  `none`.
- **Pure read.** No writes, no network.
- **Plugin root short-circuits.** In a plugin root the marker is ignored by
  consumers (`is_plugin_root` returns before the resolver is consulted) — markers
  never weaken arboretum-dev's own enforcement.
- **Single source.** The `# scope:` grammar is parsed only here; consumers call
  these functions rather than re-inlining the regex (the parallel-drift class of
  #124).
- **Bash 3.2 compatible.** No `declare -A`, no GNU-only flags.

## Test surface

- **SR-1:** `.sh` with `# scope: plugin-only` in the first 8 lines → `file_scope`
  = `plugin-only`.
- **SR-2:** `.sh` with no marker → `file_scope` = `none` (safe default).
- **SR-3:** `.sh` with `# scope: consumer` → `file_scope` = `consumer`.
- **SR-4:** `SKILL.md` with a `scope: plugin-only` frontmatter key → `file_scope`
  = `plugin-only`.
- **SR-5:** `SKILL.md` with no `scope:` key → `file_scope` = `none`.
- **SR-6:** `governed_by_framework_in_consumer_root` returns `0` for `plugin-only`
  and `1` for `none`/`consumer`.
- **SR-7:** Single-source enforcement — no consumer re-inlines the `# scope:`
  grammar (`_smoke-test-scope-single-source.sh`).

(SR-1 … SR-6 live in `scripts/_smoke-test-scope-resolve.sh`; SR-7 in
`scripts/_smoke-test-scope-single-source.sh`.)

## Versioning

- **1.0** (2026-06-20) — initial contract. Producer shape as of
  `scripts/lib/scope-resolve.sh` on the adopter-ci-scope-markers branch. Issue
  #836; design `docs/superpowers/specs/2026-06-20-adopter-ci-scope-markers-design.md`.
