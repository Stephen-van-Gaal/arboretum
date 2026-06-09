---
seam: workspace-collision-check
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - workspace-context
  - scrub-control-chars
produces:
  - collision-verdict
related-designs:
  - docs/superpowers/specs/2026-06-09-collision-mvp-design.md
owns:
  - scripts/workspace-collision-check.sh
---
<!-- owner: pipeline-contracts-template -->

# workspace-collision-check — collision verdict producer contract

The seam between `scripts/workspace-collision-check.sh` (producer of the
`VERDICT=` token) and its consumers: `skills/start/SKILL.md` (`--issue N`, rich)
and `.claude/hooks/pre-commit-branch-check.sh` (`--pre-commit`, narrow).

## Producer

`scripts/workspace-collision-check.sh` — producer-type: `script`. Sources
`workspace-context.sh` (fails closed if it can't). Scrubs all author-controlled
strings via the shared `scrub-control-chars` primitive before emitting them.

## Consumer

Two consumers. `/start` reads the token and acts advisorily (offers reattach).
The pre-commit hook maps `warn-reattach` → exit 0 + advisory stderr (non-blocking)
and never blocks on the collision case.

## Protocol shape

### Inputs

`workspace-collision-check.sh (--issue N | --pre-commit)`. Optional test seam:
`ARBO_COLLISION_ISSUE_JSON` (fixture path; `--issue` mode reads the recorded
claim from it instead of the tracker).

### Outputs

- stdout: exactly one line `VERDICT=clear|warn-reattach|block`.
- stderr: human-readable reason (diagnostic, not user chrome).

### Invariants

- Exit `0` whenever a verdict is computed (including `block`); exit `≥1` only on
  operational error (bad args, not a git repo, unsourceable helper).
- `--pre-commit` performs no network I/O and reads no recorded claim.
- Author-controlled output is control-char scrubbed.

## Test surface

`scripts/_smoke-test-contract-workspace-collision-check.sh` (bare-repo fixtures,
offline via the `ARBO_COLLISION_ISSUE_JSON` seam). Auto-discovered by
`ci-checks.sh`'s `_smoke-test-*` glob.

- **CWCC-1: exit-code contract.** Bad/empty args → exit 1 (operational error),
  distinct from a computed verdict's exit 0.
- **CWCC-2: token grammar.** stdout is exactly one `VERDICT=clear|warn-reattach|block`
  line; exit 0 when a verdict is computed.
- **CWCC-3: mapping — recorded claim → warn-reattach.** A `branch:` claim on the
  issue (read from the fixture JSON) yields `warn-reattach`.
- **CWCC-4: mapping — live worktree → block.** A branch for the issue checked out
  in another worktree yields `block`.
- **CWCC-5: `--pre-commit` is local-only.** With ≥2 on-disk branches for the
  current branch's issue, `--pre-commit` yields `warn-reattach` without reading the
  network or the recorded claim.

## Versioning

v1.0 — initial. Additive modes/signals bump minor; a changed verdict token,
output-contract change, or removed mode bumps major.
