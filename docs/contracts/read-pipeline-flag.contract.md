---
seam: read-pipeline-flag
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/read-pipeline-flag.sh
---
<!-- owner: pipeline-contracts-template -->

# read-pipeline-flag — `read-pipeline-flag.sh` Pipeline-Version Probe Contract

The seam between `scripts/read-pipeline-flag.sh` (the single source of truth for which pipeline workflow — `v1` or `v2` — a project runs) and the pipeline-stage skills that branch on it. The script's stdout is a one-token protocol; this contract pins that token's closed value set and the always-defaults-to-v1 back-compat guarantee so no skill ever has to re-implement the read or guess at a third value.

## Producer

`scripts/read-pipeline-flag.sh` — producer-type: `script`.

Reads `roadmap.config.yaml` from the current working directory and prints the active `pipeline.workflow` value to stdout. Uses python3 + PyYAML (a project dep) so all YAML-legal forms — block or flow style, quoted or unquoted, inline comments — parse correctly. Prints `v1` and exits `0` when the `pipeline` block or `workflow` key is absent (back-compat default). Exits `1` with a stderr diagnostic when the config file is missing, the YAML is invalid, or the value is outside the closed set `{v1, v2}`.

## Consumer

Consumer-type: `skill`. Multiple pipeline-stage skills capture the stdout token via command substitution to decide v1-vs-v2 behaviour without re-reading the config:

- `skills/design/SKILL.md`, `skills/consolidate/SKILL.md`, `skills/start/SKILL.md`, `skills/finish/SKILL.md`, `skills/health-check/SKILL.md` — each runs `PIPELINE=$(bash scripts/read-pipeline-flag.sh)` and branches.
- `scripts/_smoke-test-contract-tests.sh` (test consumer) gates contract-test execution on the value.

**Consumer obligations:**

- Consumers MUST treat any non-`v1`/`v2` outcome as a hard error (the script exits `1` first; consumers MUST NOT swallow that exit and continue).
- Consumers MUST NOT cache the value across a config edit within the same session without re-invoking.
- Consumers MUST accept `v1` as the meaning of "absent pipeline block" — they MUST NOT require the key to be present.

## Protocol shape

### Inputs

- CWD-relative `roadmap.config.yaml`. No arguments. No stdin.

### Outputs

- stdout: exactly one line, `v1` or `v2` (no trailing decoration).
- stderr (exit 1 only): a `read-pipeline-flag.sh: …` diagnostic.
- Exit codes: `0` — value printed (including the `v1` default); `1` — config missing, invalid YAML, or value outside `{v1, v2}`.

### Invariants

- **Closed value set.** stdout on exit 0 is always exactly `v1` or `v2`. A YAML int/bool/other surfaces as exit 1, never as a third printed token.
- **Default-to-v1.** Absent `pipeline` block, absent `workflow` key, or a `pipeline` that is not a mapping all yield `v1` exit 0 — never exit 1.
- **No mutation.** Read-only — the script never writes `roadmap.config.yaml` or any file.

## Test surface

- **RPF-1:** `pipeline.workflow: v2` → stdout `v2`, exit 0.
- **RPF-2:** `pipeline.workflow: v1` → stdout `v1`, exit 0.
- **RPF-3:** absent `pipeline` block → stdout `v1`, exit 0 (default).
- **RPF-4:** absent `workflow` key under a present `pipeline` block → stdout `v1`, exit 0.
- **RPF-5:** out-of-set value (e.g. `v3`) → exit 1, stderr diagnostic, no `v1`/`v2`/`v3` on stdout.
- **RPF-6:** missing `roadmap.config.yaml` → exit 1, stderr diagnostic.
- **RPF-7:** read-only — `roadmap.config.yaml` mtime/content unchanged after invocation.

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/read-pipeline-flag.sh` on `main`. Issue #303 (WS5 PR 7a).
