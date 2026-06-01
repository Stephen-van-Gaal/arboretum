---
seam: read-s2-frontmatter
version: 1.1
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
  - yaml-lite-line-protocol
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
  - docs/superpowers/specs/2026-06-01-runtime-portability-design.md
owns:
  - scripts/read-s2-frontmatter.sh
---
<!-- owner: pipeline-contracts-template -->

# read-s2-frontmatter — `read-s2-frontmatter.sh` S2 Frontmatter Reader Contract

The seam between `scripts/read-s2-frontmatter.sh` (the strict whole-schema gate that reads the S2 input frontmatter off a design spec) and the `/build` skill, which captures the script's stdout via command substitution and dispatches its build branches on the parsed values. The script's stdout is a `key=value` protocol; this contract pins the flattened key set, the strict-gate exit semantics, and the dot-notation flattening of the nested `test-tiers` object so `/build` never has to re-parse the spec's YAML.

## Producer

`scripts/read-s2-frontmatter.sh` — producer-type: `script`.

Takes exactly one positional argument: the path to a design spec. Reads the leading `---`-delimited YAML frontmatter block through `scripts/lib/yaml-lite.sh` (no PyYAML, yq, jq, or package install), then validates the whole schema strictly (per WS1 D5): every required field must be present, and each must satisfy its type/enum rule. On success it prints one `key=value` line per required field to stdout and exits `0`; the nested `test-tiers` object is flattened to `test-tiers.<sub-key>=<value>` lines. On any missing field, bad enum, or malformed input it writes a `read-s2-frontmatter: …` diagnostic to stderr and exits `2`. Usage errors (wrong arg count, missing file, missing helper) exit `1`.

Required fields and their rules:

- `related-issue` — a positive integer.
- `test-tiers` — an object with at least one of the sub-keys `unit`, `contract`, `integration` (a scalar is rejected).
- `implementation-mode` — one of `{direct, executing-plans, subagent-driven-development}`.
- `triage` — one of `{agent-target, everything-else}`.
- `plan` — `null`, or a non-empty relative path (absolute paths and empty strings are rejected; surrounding quotes are stripped and the value is normalized to its unquoted form in the printed line).

## Consumer

Consumer-type: `skill`. One downstream consumer:

- **`skills/build/SKILL.md`** (~line 50) runs `FRONTMATTER="$(bash scripts/read-s2-frontmatter.sh "$DESIGN_SPEC")"` and branches Branch 2 (TDD assessment) and Branch 3 (implementation mode) on the captured `key=value` lines. A non-zero exit is treated as a hard escape-hatch — `/build` does not proceed on a `2`.

**Consumer obligations:**

- Consumers MUST treat exit `2` as a strict-gate failure and abort the build dispatch — they MUST NOT continue on partial frontmatter.
- Consumers MUST read `test-tiers` via the flattened `test-tiers.<sub-key>=…` lines, not by re-parsing the spec.
- Consumers MUST NOT require the `plan` value to be a path — `plan=null` is a valid, expected outcome meaning "no plan file."

## Protocol shape

### Inputs

- One positional argument: the path to a design spec file. No stdin.

### Outputs

- stdout (exit 0 only): one `key=value` line per required field, in the fixed order `related-issue`, `test-tiers`, `implementation-mode`, `triage`, `plan`. The `test-tiers` object expands to one `test-tiers.<sub-key>=<value>` line per sub-key.
- stderr (exit 1 or 2 only): a `read-s2-frontmatter: …` (or `Usage:`/not-found) diagnostic.
- Exit codes: `0` — all fields valid, key=value printed; `1` — usage error (wrong arg count or file not found); `2` — strict-gate failure (missing field, bad enum, malformed/absent frontmatter, scalar `test-tiers`, non-int `related-issue`, absolute/empty `plan`).

### Invariants

- **Whole-schema strict gate.** stdout on exit 0 always contains every required field — partial-schema acceptance is impossible; any missing-or-invalid field is exit 2 with nothing on stdout.
- **Flattened nested object.** The `test-tiers` object is emitted as dot-notation `test-tiers.<sub-key>=<value>` lines — never as a single opaque `test-tiers=…` scalar line.
- **Plan normalization.** A quoted `plan` value has its surrounding quotes stripped before being printed; `plan=null` is printed verbatim when the field is `null`.
- **No mutation.** Read-only — the script never writes the spec or any file.
- **Bare-checkout portable.** The reader does not require PyYAML, yq, jq, or any package install; it shares parser behavior through `scripts/lib/yaml-lite.sh`.

## Test surface

- **RS2-1:** A spec with all five required fields valid → exit 0; stdout includes `related-issue=<int>`, an `implementation-mode=<enum>` line, a `triage=<enum>` line, a `plan=…` line.
- **RS2-2:** The nested `test-tiers` object is flattened — stdout includes at least one `test-tiers.<sub-key>=…` line and no bare `test-tiers=` line.
- **RS2-3:** Missing required field (e.g. `triage` absent) → exit 2, stderr diagnostic, no stdout.
- **RS2-4:** Out-of-enum `implementation-mode` (e.g. `yolo`) → exit 2, stderr diagnostic.
- **RS2-5:** Scalar `test-tiers` (not an object) → exit 2.
- **RS2-6:** Missing file → exit 1; no frontmatter at all → exit 2.
- **RS2-7:** `plan: null` → stdout `plan=null`; a quoted relative `plan` value → printed unquoted.
- **RS2-8:** Read-only — the spec file's content is unchanged after invocation.

## Versioning

- **1.1** (2026-06-01) - parser moved onto shared `yaml-lite.sh` helper for Issue #437.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/read-s2-frontmatter.sh` on this branch. Issue #303 (WS5 PR 7a).
