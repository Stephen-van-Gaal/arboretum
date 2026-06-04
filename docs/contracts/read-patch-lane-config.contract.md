---
seam: read-patch-lane-config
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-06-04-patch-lane-bug-triage-front-half-design.md
owns:
  - scripts/read-patch-lane-config.sh
---
<!-- owner: pipeline-contracts-template -->

# read-patch-lane-config - Patch-Lane Budget Probe Contract

The seam between `scripts/read-patch-lane-config.sh` and `/start-bugfix`.
The script is the single source of truth for the experimental patch lane's
bounded investigation budget, so the skill does not need to parse
`.arboretum.yml` directly or duplicate validation rules.

## Producer

`scripts/read-patch-lane-config.sh` - producer-type: `script`.

Reads a YAML-lite config file and emits the configured patch-lane investigation
budget as a one-line key/value protocol. The default input is
`.arboretum.yml`; callers may pass one positional config path for fixture
and test use. The script parses through `scripts/lib/yaml-lite.sh`, accepts the
repository's supported YAML-lite subset, defaults an absent
`patch_lane.investigation_budget_minutes` key to `15`, and rejects missing
files, invalid YAML-lite, missing parser helper, and non-positive or
non-integer budget values.

## Consumer

Consumer-type: `skill`.

`skills/start-bugfix/SKILL.md` invokes the script at patch-lane entry to obtain
the investigation time budget before source inspection begins. The consumer
uses the emitted integer to bound upfront triage and then routes either to a
patch brief for `/build` or to shaped tracker intake when the bug is not
patchable.

Consumer obligations:

- Treat any non-zero exit as a hard stop for the patch-lane front half.
- Use the emitted `investigation_budget_minutes=<positive-int>` value as the
  authoritative budget for the current invocation.
- Do not re-read `.arboretum.yml` directly or invent a fallback after the
  helper reports an invalid configured value.

## Protocol shape

### Inputs

- Optional positional config path; defaults to `.arboretum.yml`.
- No stdin.

### Outputs

- stdout on exit 0: exactly one line,
  `investigation_budget_minutes=<positive-int>`.
- stderr on exit 1: a `read-patch-lane-config.sh: ...` diagnostic.
- Exit codes: `0` when a valid budget is printed; `1` for invocation,
  dependency, config, parser, or semantic validation failure.

### Invariants

- **Positive integer budget.** The emitted budget is always a base-10 positive
  integer with no leading zero.
- **Default budget.** If the config exists but omits
  `patch_lane.investigation_budget_minutes`, the script emits `15`.
- **Configured value wins.** A valid configured budget is emitted unchanged.
- **No mutation.** The script never writes the config file or any derived
  artifact.
- **Bare-checkout portable.** The script relies only on Bash, awk, and the
  repository's YAML-lite helper.

## Test surface

- **PLC-1: Default budget.** A config without `patch_lane` exits 0 and emits
  `investigation_budget_minutes=15`.
- **PLC-2: Explicit budget.** A config with
  `patch_lane.investigation_budget_minutes: 7` exits 0 and emits
  `investigation_budget_minutes=7`.
- **PLC-3: Positive-integer validation.** Zero and non-integer configured
  budgets exit non-zero and name the positive-integer requirement.
- **PLC-4: YAML-lite validation.** Malformed YAML-lite exits non-zero and names
  the invalid YAML-lite boundary.
- **PLC-5: Missing config.** A missing config file exits non-zero and names the
  missing path.
- **PLC-6: Contract coverage.** The coverage manifest maps
  `scripts/read-patch-lane-config.sh` to this contract, not `MISSING`.

## Versioning

- **1.0** (2026-06-04) - initial patch-lane budget probe contract for issue
  #517's experimental `/start-bugfix` front half.
