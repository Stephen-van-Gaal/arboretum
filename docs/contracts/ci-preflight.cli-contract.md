---
script: scripts/ci-preflight.sh
version: 1.0
invokers:
  - type: script
    name: scripts/ci-checks.sh
  - type: script
    name: .github/workflows/ci.yml
  - type: script
    name: .github/workflows/nightly-release-candidate.yml
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-06-standard-ci-preflight-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/ci-preflight.sh`

## Surface

Readiness gate that runs before expensive CI. It checks cheap known blockers,
optionally applies allowlisted deterministic repairs, commits repair output only
in explicitly trusted modes, and stops the current run when unresolved blockers
or repair commits remain. Full CI must validate the repaired commit in a fresh
run.

Usage:

```bash
bash scripts/ci-preflight.sh [--apply-safe-repairs] [--scope standard|release] [--continue-after-repair] [--repair-commit-mode none|same-branch|repair-pr]
```

## Protocol

### Arguments

- `--apply-safe-repairs` attempts allowlisted repairs. Without this flag,
  preflight is read-only.
- `--scope standard|release` selects standard blockers only, or standard plus
  release-lane blockers. Default: `standard`.
- `--continue-after-repair` allows a local/debug caller to exit 0 after repairs
  resolve blockers. Hosted workflows do not set this flag.
- `--repair-commit-mode none|same-branch|repair-pr` controls automated repair
  commits. Default: `none`.
- `--repair-branch <branch>` names the branch used by `same-branch` push or
  `repair-pr` automation.
- `--push-safe-repairs` permits `same-branch` mode to push the committed repair
  to `origin`.
- `--gh-cmd <path>` selects the provider CLI for repair PR create/update.
- `--root <path>` is a developer/test argument that runs checks against another
  project root. Relative roots are canonicalized before the helper changes
  directory.

### Exit codes

- `0` - no blockers remain and no repair diff or repair commit blocks
  continuation.
- `1` - blockers remain, or repairs were applied/committed and the current run
  must stop so a fresh SHA can be validated.
- `2` - invalid arguments or missing required helper/provider.

### Safe repairs

- `scripts/health-check.sh --reconcile` for unrecorded Check 7 active-to-stale
  drift. Preflight blocks on the unrecorded drift line that says to run with
  `--reconcile`; a later `status=stale` warning is recorded drift for
  `/consolidate`, not a pointless-CI blocker.
- `scripts/generate-coverage.sh` when `scripts/validate-coverage-manifest.sh`
  reports `COVERAGE-MANIFEST-DRIFT`.

Preflight must not run `/consolidate`, rewrite human-authored spec prose,
resolve merge conflicts, edit release intent, or repair arbitrary smoke-test
failures.

### Release scope

Release scope runs the standard blocker set first, then runs the nightly release
workflow smoke and release-candidate helper smoke as early blockers. Release
scope failures are not repaired automatically.

### Automated commit modes

- `none` leaves repair diffs for the caller to review and exits 1 unless
  `--continue-after-repair` is set.
- `same-branch` requires a clean pre-repair worktree, stages only repair output,
  commits with the configured bot identity, and pushes only when a trusted
  caller supplies `--push-safe-repairs` plus `--repair-branch`.
- `repair-pr` requires a clean pre-repair worktree, commits on a bot-owned
  repair branch, validates any existing same-repo repair PR ownership before
  changing the branch, pushes with a lease, and creates or updates one marked
  repair PR.

Generated repair PR bodies start with:

```markdown
<!-- arboretum-ci-preflight-repair:bot-owned -->
```

The helper may update an existing repair PR only when this marker is present.

### Manual PR automation

```mermaid
flowchart TD
  A["PR opened or updated"] --> B["Preflight job runs first"]
  B --> C["Checkout PR head"]
  C --> D["ci-preflight --apply-safe-repairs"]
  D --> E{"Any blockers?"}
  E -->|No| F["Preflight passes"]
  F --> G["Full CI job starts via needs: preflight"]
  E -->|Repairable blockers| H["Apply allowlisted repairs locally"]
  H --> I["Do not push PR-head code with write token"]
  I --> J["Fail preflight with repair diagnostics"]
  J --> K["Full CI skipped"]
  E -->|Unresolved blockers| L["Fail preflight"]
  L --> M["Full CI skipped"]
```

### Nightly automation

```mermaid
flowchart TD
  A["Nightly schedule starts on main"] --> B["Checkout main"]
  B --> C["ci-preflight --scope release --apply-safe-repairs"]
  C --> D{"Any blockers?"}
  D -->|No| E["Run full CI"]
  E --> F{"Full CI passes?"}
  F -->|Yes| G["Update or create release candidate PR"]
  F -->|No| H["Stop: normal CI failure"]
  D -->|Repairable blockers| I["Apply allowlisted repairs on repair branch"]
  I --> J["Commit repairs to bot-owned branch"]
  J --> K["Open or update repair PR"]
  K --> L["Stop nightly run before full CI"]
  L --> M["Human merges repair PR"]
  M --> N["Next nightly or manual dispatch releases from repaired main"]
  D -->|Unresolved blockers| O["Stop before full CI"]
  O --> P["Report blockers in preflight log"]
```

## Test surface

- **CLI-1: Contract shape.** The contract names safe repairs, release scope,
  automated commit modes, and the manual PR/nightly diagrams.
- **CLI-2: Clean standard preflight.** A fixture with no unrecorded drift and
  fresh coverage exits 0 and prints `PREFLIGHT OK`.
- **CLI-3: Recorded stale drift does not block.** A fixture whose health check
  emits `status=stale` but no unrecorded drift exits 0.
- **CLI-4: Read-only drift blocks without mutation.** Unrecorded Check 7 drift
  exits 1 without changing fixture files when `--apply-safe-repairs` is absent.
- **CLI-5: Safe repair leaves reviewable diff by default.** With
  `--apply-safe-repairs`, unrecorded drift is reconciled and reported, but the
  command exits 1 because repair output must be reviewed or committed.
- **CLI-6: Local continue escape hatch.** The same repair exits 0 only with
  `--continue-after-repair`.
- **CLI-7: Same-branch auto-commit stops current run.** Same-branch mode commits
  repair output from a clean tree, leaves the tree clean, and exits 1.
- **CLI-8: Repair PR mode creates a marked bot PR.** Repair-PR mode commits on
  the configured branch, refuses human-owned existing repair PRs before pushing,
  pushes it, and calls the provider to create/update a marked PR body.
- **CLI-9: Coverage drift repair.** `COVERAGE-MANIFEST-DRIFT` triggers
  `scripts/generate-coverage.sh` only in repair mode.
- **CLI-10: Release-scope blockers stop early.** Release-scope smoke failures
  exit 1 and are not repaired automatically.

## Versioning

- **1.0** - initial standard CI preflight contract with safe repair and scoped
  automated repair commits (2026-06-06).
