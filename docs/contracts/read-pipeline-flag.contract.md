---
seam: read-pipeline-flag
version: 1.2
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-06-04-pipeline-workflow-codenames-design.md
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/read-pipeline-flag.sh
---
<!-- owner: pipeline-contracts-template -->

# read-pipeline-flag — `read-pipeline-flag.sh` Pipeline Probe Contract

The seam between `scripts/read-pipeline-flag.sh` and the workflow-stage skills
that need to validate the configured development pipeline. Arboretum supports
one general-release pipeline at a time; `pipeline.workflow` is a named pipeline
feature flag, not a compatibility selector for retired workflow versions. The
script's stdout is a one-token protocol naming the active pipeline. The current
general-release token is `unified`.

## Producer

`scripts/read-pipeline-flag.sh` — producer-type: `script`.

Reads `roadmap.config.yaml` from the current working directory and prints the
active `pipeline.workflow` value to stdout. It parses the framework's supported
YAML-lite subset through `scripts/lib/yaml-lite.sh`, which uses Python 3
standard library only. Supported forms include block style, simple flow mapping
style, quoted and unquoted scalar values, and inline comments.

Prints `unified` and exits `0` when the `pipeline` block or `workflow` key is
absent. Exits `1` with a stderr diagnostic when the config file is missing, the
YAML-lite helper is missing, the YAML-lite input is invalid, the value is a
retired historical token (`v1` or `v2`), or the value is outside the current
closed set `{unified}`.

## Consumer

Consumer-type: `skill`. Pipeline-stage skills capture the stdout token via
command substitution to validate the active pipeline without re-reading the
config:

- `skills/design/SKILL.md`, `skills/consolidate/SKILL.md`,
  `skills/start/SKILL.md`, `skills/health-check/SKILL.md` — each runs
  `PIPELINE=$(bash scripts/read-pipeline-flag.sh)` as an early validation seam.
- `skills/finish/SKILL.md` — resolves the active worktree root first, then runs
  `PIPELINE="$(cd "$PROJECT_DIR" && bash "$PROJECT_DIR/scripts/read-pipeline-flag.sh")"`
  so `/finish` works when invoked from a subdirectory before the backend-aware
  ship tail starts.
- `scripts/_smoke-test-contract-tests.sh` (test consumer) gates contract-test
  execution on the named pipeline token.

**Consumer obligations:**

- Consumers MUST treat any reader failure as a hard error; they MUST NOT swallow
  that exit and continue.
- Consumers MUST NOT cache the value across a config edit within the same session without re-invoking.
- Consumers MUST accept `unified` as the meaning of "absent pipeline block" —
  they MUST NOT require the key to be present.

## Protocol shape

### Inputs

- CWD-relative `roadmap.config.yaml`. No arguments. No stdin.

### Outputs

- stdout: exactly one line, `unified` (no trailing decoration).
- stderr (exit 1 only): a `read-pipeline-flag.sh: …` diagnostic.
- Exit codes: `0` — value printed (including the `unified` default); `1` —
  config missing, YAML-lite helper missing, invalid YAML, retired value, or
  value outside `{unified}`.

### Invariants

- **Closed value set.** stdout on exit 0 is always exactly `unified`. A YAML
  int/bool/other surfaces as exit 1, never as a third printed token.
- **Default-to-general-release.** Absent `pipeline` block, absent `workflow`
  key, or a `pipeline` that is not a mapping all yield `unified` exit 0 —
  never exit 1.
- **Retired values fail closed.** `v1` and `v2` are historical workflow tokens.
  They exit 1 with a retired-value diagnostic instead of silently selecting
  compatibility behavior.
- **No mutation.** Read-only — the script never writes `roadmap.config.yaml` or any file.
- **Bare-checkout portable.** The script does not require PyYAML, yq, jq, or any package install; the shared YAML-lite helper provides the required parser subset.

## Test surface

- **RPF-1:** `pipeline.workflow: unified` → stdout `unified`, exit 0.
- **RPF-2:** absent `pipeline` block → stdout `unified`, exit 0.
- **RPF-3:** absent `workflow` key under a present `pipeline` block → stdout `unified`, exit 0.
- **RPF-4:** retired values (`v1`, `v2`) → exit 1, retired diagnostic, no stdout token.
- **RPF-5:** out-of-set value (e.g. `experimental`) → exit 1, unknown-value diagnostic, no stdout token.
- **RPF-6:** missing `roadmap.config.yaml` → exit 1, stderr diagnostic.
- **RPF-7:** read-only — `roadmap.config.yaml` mtime/content unchanged after invocation.
- **RPF-8:** PyYAML unavailable via import hook still parses a supported `pipeline.workflow` declaration.
- **RPF-9:** missing `scripts/lib/yaml-lite.sh` helper → exit 1, stderr `yaml-lite helper not found`, no stdout token.

## Versioning

- **1.2** (2026-06-04) — pipeline selector changed from v1/v2 compatibility to the named `unified` general-release pipeline; retired `v1`/`v2` now fail closed.
- **1.1** (2026-06-01) — missing YAML-lite helper emits an explicit dependency diagnostic instead of being reported as invalid YAML-lite.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/read-pipeline-flag.sh` on `main`. Issue #303 (WS5 PR 7a).
