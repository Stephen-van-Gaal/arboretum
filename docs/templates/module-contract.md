<!-- owner: pipeline-contracts-template -->

# Module-Contract Template

This file is the template for live seam-contract files at `docs/contracts/<seam>.contract.md`. The substantive design lives in `docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws3a-pipeline-contracts-design.md` (WS3a §D1–D7). The first three live contracts using this template — for seams S2, S3, S9 — ship alongside this template per WS3b's design (`docs/superpowers/specs/2026-05-24-pipeline-overhaul-ws3b-pipeline-contracts-finalize-design.md` §D1).

## How to use this template

Copy this file to `docs/contracts/<seam-id>.contract.md`, replace the placeholder content under each `## ` section with your seam's actual content, and ship the file in the same PR as any producer or consumer changes that the contract gates. WS4 produces the validator that enforces the structure described below; until WS4 ships, `scripts/_smoke-test-contracts.sh` provides a presence check on the required-section / required-frontmatter shape.

The five required body sections and the required frontmatter fields are documented inline below. Missing any required section or frontmatter field fails the smoke test (and will fail WS4's validator once it lands).

## Frontmatter schema

Every contract file opens with YAML frontmatter:

```yaml
---
seam: <kebab-case-id>           # e.g. s2-design-to-build, s9-stage-to-log-helper
version: <major>.<minor>        # semver-light per WS3a §D7 (no patch)
producer-type: <enum>           # see Consumer-type enum below — applies to both fields
consumer-type: <enum>           # see Consumer-type enum below
consumes:                       # M2 frontmatter convention — concepts this contract depends on
  - <concept-id>
produces:                       # M2 convention — concepts this contract defines (may be empty for terminal-consumer contracts)
  - <concept-id>
related-designs:                # design specs that authored this contract
  - docs/superpowers/specs/<date>-<topic>-design.md
---
```

All seven keys are required.

### Consumer-type enum (closed)

The `producer-type` and `consumer-type` fields accept exactly these values (per WS3a §D3):

- **`skill`** — a slash-invokable arboretum skill (e.g. `/build`, `/handoff`).
- **`script`** — a bash script under `scripts/` (e.g. `log-stage.sh`).
- **`hook`** — a Claude Code hook (e.g. `session-start.sh`, `statusline.sh`).
- **`plugin`** — an external plugin's surface (e.g. a superpowers skill invoked by an arboretum skill).
- **`sub-agent`** — a worktree-isolated background agent (WS6's execute method dispatch shape).
- **`cross-repo`** — a consumer in a different GitHub repository.

WS4's contract test framework dispatches based on these values; the enum must stay closed. New types are added by amending WS3a's design, not by individual contracts.

## Required body sections

Every contract has these five sections in this order:

### `## Producer`

Names the module that emits this seam's outputs. Identify the module by its file path (e.g. `skills/build/SKILL.md`, `scripts/log-stage.sh`) and by the `producer-type` frontmatter value.

### `## Consumer`

Names the module that reads this seam's outputs. Same identification scheme.

### `## Protocol shape`

Prose description of what flows across the seam, under three required sub-headings:

- **`### Inputs`** — what the consumer reads (positional arguments, frontmatter fields, file paths, CLI argv, comment-body content, etc.).
- **`### Outputs`** — what the producer emits (state changes, return values, side effects, API operations, log entries).
- **`### Invariants`** — properties that must hold for the seam to be honored (closed enums, no-self-heal rules, atomicity declarations, error-surfacing rules).

The sub-headings are required; the content under each is free-form prose. Different seams have wildly different shapes — the template doesn't prescribe a fixed structure within the sub-headings, just that they exist.

### `## Test surface`

A bullet list of named test assertions. Each bullet:

- Starts with a unique ID in the form `<seam-id>-<n>` (e.g. `S2-1`, `S9-3`), bolded.
- Is followed by a short name (one or two words).
- States one observable property of the seam under valid use.

Format:

```markdown
- **<ID>: <Short name>.** <One-sentence statement of the observable property.>
```

WS4 writes one test per assertion. The contract IS the test plan — WS4 does not invent assertions.

Per WS3b §D6, assertion IDs are immutable once published in a contract version. Deprecated assertions are marked `(deprecated)` in their body but keep their ID; new assertions take the next available integer.

### `## Versioning`

A one-line-per-version change log:

```markdown
## Versioning

- **1.0** (YYYY-MM-DD) — initial contract; producer + consumer shapes as specified by <design spec citation>.
```

Bump major on producer/consumer incompatibility. Bump minor on additive changes (adding a new optional field, adding a new test assertion). No patch (typo fixes don't bump).

## Worked example: S2 contract

The S2 contract (`docs/contracts/s2-design-to-build.contract.md`) is the canonical worked example. The frontmatter and body shapes below mirror what the live S2 file ships with — read that file alongside this template for the full populated form.

```markdown
---
seam: s2-design-to-build
version: 1.0
producer-type: skill
consumer-type: skill
consumes:
  - s2-input-contract
  - module-contract-template-file
produces: []                    # empty list when this contract is a terminal consumer (no downstream concepts defined)
related-designs:
  - docs/superpowers/specs/2026-05-22-pipeline-overhaul-ws1-build-orchestrator-design.md
  - docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws3a-pipeline-contracts-design.md
  - docs/superpowers/specs/2026-05-24-pipeline-overhaul-ws3b-pipeline-contracts-finalize-design.md
---
<!-- owner: pipeline-contracts-template -->

# S2 — `/design` → `/build` Contract

## Producer

`/design` — `skills/design/SKILL.md`. Producer-type: `skill`. ...

## Consumer

`/build` — `skills/build/SKILL.md`. Consumer-type: `skill`. ...

## Protocol shape

### Inputs

Positional argument `<design-spec-path>` (string, relative file path). Required frontmatter fields on the spec file:

- `related-issue` (positive integer)
- `test-tiers` (object with at least `unit`, `contract`, `integration` keys, each `yes` or `n/a — <reason>`)
- `implementation-mode` (closed enum: `direct` | `executing-plans` | `subagent-driven-development`)
- `triage` (closed enum: `agent-target` | `everything-else`)
- `plan` (string path or literal `null`)

### Outputs

`/build`'s normal execution proceeds when all five fields are present and valid; Branch 2 dispatches per `test-tiers:`; Branch 3 dispatches per `implementation-mode:`. ...

### Invariants

Strict whole-schema gate — any one missing required field fails entry, no field-by-field tolerance. ...

## Test surface

- **S2-1: Producer-completeness.** `/design`'s v2 exit produces a design spec with all five required frontmatter fields.
- **S2-2: Consumer-strict-gate.** `/build` refuses to run if any required S2 field is missing.
- ...

## Versioning

- **1.0** (2026-05-24) — initial contract per WS1 §D3 and PR #321 / PR #329.
```

(The live file populates each section fully; this excerpt elides for brevity.)
