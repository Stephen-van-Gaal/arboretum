---
seam: validate-design-spec
version: 1.2
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/validate-design-spec.sh
---
<!-- owner: pipeline-contracts-template -->

# validate-design-spec — `validate-design-spec.sh` S2 Enforcement-Validator Contract

The enforcement validator that checks a `/design`-spec's frontmatter against the S2 seam (`docs/contracts/s2-design-to-build.contract.md`). This contract pins the validator's own protocol — the exact `S2-DRIFT:` message format and exit codes — so the consumers (the S2 contract-test files and the `/design` + `/build` skill gates) can assert on its output without re-deriving the S2 field rules. This is a standalone validator contract (design decision D-7a-2): it governs the *script that checks the seam*, distinct from the S2 seam contract that governs the `/design` → `/build` interface itself.

## Producer

`scripts/validate-design-spec.sh` — producer-type: `script`.

Validates the design spec at the positional path argument. Parses the leading frontmatter through `scripts/lib/yaml-lite.sh`, then applies S2-specific schema validation in Python 3 standard library code. It checks the five required S2 fields plus the cross-field invariants:

- `related-issue` — positive integer.
- `triage` — closed enum `{agent-target, everything-else}`.
- `implementation-mode` — closed enum `{direct, executing-plans, subagent-driven-development}`.
- `plan` — relative path string or the literal `null`.
- `test-tiers` — mapping with keys `unit`, `contract`, `integration`; each value `yes` (including quoted forms and the legacy normalized `True` spelling) or a reason-bearing `n/a` string.

Cross-field invariants: `plan: null` forbids `implementation-mode: executing-plans`; a `plan:` path must be relative and resolve to an existing file under the repo root (located by walking up for a `.git` dir or `CLAUDE.md`). Emits one summary `S2-DRIFT:` line plus one indented bullet per issue to stderr; never mutates the spec.

**`kind` handling (S2 v1.1, #692).** An optional `kind` field (closed enum `{buildable, shaping}`; absent ⇒ buildable) controls which schema applies. For `kind: shaping` (a non-buildable epic/shaping doc) the validator checks **only** `related-issue` and skips `triage`, `implementation-mode`, `plan`, `test-tiers`, and the cross-field invariants — so a shaping doc validates without the build-targeted fields. An out-of-enum `kind`, or a **mapping-valued** `kind` (e.g. `kind: {value: shaping}`, which flattens to `kind.<sub>` with no scalar `kind`), is a `kind:` drift issue rather than being read as absent — a malformed shaping marker never passes as buildable (fail-safe).

## Consumer

Consumer-type: `script`. Two consumer classes assert on this validator's output:

- **S2 contract-test files** under `tests/contracts/s2/` — `s2-1-producer-completeness.sh` (good fixture → exit 0), `s2-2-consumer-strict-gate.sh` (asserts `triage: missing`), `s2-4-enum-validity.sh` (asserts `implementation-mode: not in`), `s2-6-plan-path-existence.sh` (asserts `plan: file not found`), and the sibling `s2-3`/`s2-5`/`s2-7` files. They invoke the validator against the shared `tests/contracts/fixtures/design-*.md` fixtures and assert exit code + an `assertStderr` substring.
- **Skill gates** — `/design` runs it at its unified exit (`skills/design/SKILL.md` ~248) and `/build` runs it as the S2 consumer gate before reading any field (`skills/build/SKILL.md` ~40, `bash scripts/validate-design-spec.sh "$DESIGN_SPEC" || { … }`). Both treat a non-zero exit as a hard stop.

**Consumer obligations:** consumers MUST treat any non-zero exit as drift and MUST NOT swallow it; they MUST match the `S2-DRIFT:` summary and `  - <field>: <reason>` bullet shape rather than re-implementing the S2 field rules.

## Protocol shape

### Inputs

- Positional argument 1: `<design-spec-path>` (a Markdown file with leading YAML frontmatter). No stdin. Exactly one argument; zero or more-than-one is an invocation error.

### Outputs

- **stdout:** none.
- **stderr (drift only):** a summary line `S2-DRIFT: <N> issue(s) in <path>` followed by one indented bullet per issue, `  - <field>: <reason>` (e.g. `  - triage: missing`, `  - implementation-mode: not in ['direct', 'executing-plans', 'subagent-driven-development'] (got '…')`, `  - plan: file not found at <path> (resolved: <abs>)`). A malformed/absent frontmatter block yields a single `frontmatter: …` issue.
- **stderr (invocation error):** `usage: validate-design-spec.sh <design-spec-path>`, `validate-design-spec.sh: file not found: <path>`, or `validate-design-spec.sh: yaml-lite helper not found at <path>`.
- **Exit codes:** `0` — spec valid; `1` — one or more contract violations (issues on stderr); `2` — invocation problem (wrong arg count, file missing/unreadable).

### Invariants

- **Drift goes to stderr, never stdout.** stdout stays empty so callers can capture it separately; the `S2-DRIFT:` block is stderr-only.
- **Whole-schema report, not first-fail.** All five fields plus cross-field invariants are evaluated; the summary `<N>` is the total issue count, not `1`.
- **`yes`/`True` equivalence.** A `test-tiers` tier of `yes`, quoted `yes`, or the legacy normalized `True` spelling is accepted identically.
- **No mutation.** Read-only — never writes the spec or any file other than its own scratch tempfile.
- **Exit-2 is distinct from exit-1.** An invocation problem (missing file, wrong arg count, missing YAML-lite helper) exits `2` and does NOT emit an `S2-DRIFT:` line; contract drift exits `1` and does.
- **Bare-checkout portable.** The validator does not require PyYAML, yq, jq, or any package install.

## Test surface

- **VDS-1:** good fixture (`tests/contracts/fixtures/design-good.md`) → exit 0, no `S2-DRIFT:` on stderr.
- **VDS-2:** missing-`triage` fixture (`design-missing-triage.md`) → exit 1, stderr `S2-DRIFT:` summary + `  - triage: missing` bullet.
- **VDS-3:** out-of-enum `implementation-mode` fixture (`design-bad-enum-implementation-mode.md`) → exit 1, stderr `  - implementation-mode: not in …`.
- **VDS-4:** `plan:` pointing at a missing file (`design-plan-missing-file.md`) → exit 1, stderr `  - plan: file not found …`.
- **VDS-5:** invocation error — non-existent path → exit 2, stderr `file not found`, no `S2-DRIFT:` line.
- **VDS-6:** invocation error — missing `scripts/lib/yaml-lite.sh` helper → exit 2, stderr `yaml-lite helper not found`, no `S2-DRIFT:` line.
- **VDS-7:** `kind: shaping` with only `related-issue` → exit 0 (identity-only; build fields not required). (#692)
- **VDS-8:** `kind: shaping` missing `related-issue` → exit 1, `  - related-issue: missing`. (#692)
- **VDS-9:** `kind: shaping` with stray build fields present → exit 0 (fields ignored). (#692)
- **VDS-10:** out-of-enum `kind` → exit 1, `  - kind: not in [...]`. (#692)
- **VDS-11:** mapping-valued `kind` → exit 1, `  - kind: must be a scalar enum value …` (not read as absent ⇒ buildable). (#692)

## Versioning

- **1.2** (2026-06-08) — S2 v1.1 `kind` support (#692): `kind: shaping` validates identity-only (`related-issue`); out-of-enum or mapping-valued `kind` is `kind:` drift (exit 1), never read as absent; absent ⇒ buildable five-field schema unchanged. Adds VDS-7..11.
- **1.1** (2026-06-01) — missing YAML-lite helper is an invocation error (exit 2) with no `S2-DRIFT:` summary.
- **1.0** (2026-05-30) — initial contract. Validator shape as of `scripts/validate-design-spec.sh` on `main` (S2-DRIFT stderr format, exit 0/1/2). Issue #303 (WS5 PR 7a).
