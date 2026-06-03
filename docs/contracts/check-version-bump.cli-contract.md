---
script: scripts/check-version-bump.sh
version: 2.1
invokers:
  - type: script
    name: scripts/ci-checks.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/check-version-bump.sh`

## Surface

Compatibility entrypoint for the release gate. Historical callers still invoke
`scripts/check-version-bump.sh`, especially `scripts/ci-checks.sh`, but this
script now delegates directly to `scripts/check-release-gate.sh`. The behavior
is defined by `docs/contracts/check-release-gate.cli-contract.md`: shippable
non-manifest PRs require pending release intent once PR body/event input is
available, local pre-PR runs without either input skip, and manifest-touching
PRs require version consistency plus a version greater than base.

## Protocol

### Arguments

No positional arguments and no flags. All configuration is via environment
variables passed through to `scripts/check-release-gate.sh`:

- `BASE_REF` (optional) — the git ref against which the diff is computed. Defaults to `origin/main`. CI sets this to the PR target branch (e.g. `refs/remotes/origin/main`). Smoke tests set it to a local ref to avoid network access.
- `REPO_ROOT` (optional) — absolute path to the repository root. Defaults to `$(cd "$(dirname "$0")/.." && pwd)`. Set by smoke tests to a `mktemp -d` fixture so the script never touches the live repo.
- `RELEASE_INTENT_BODY_FILE` (optional) — PR body file for shippable
  non-manifest diffs.
- `RELEASE_INTENT_EVENT` (optional) — GitHub event JSON for shippable
  non-manifest diffs.

### Exit codes

- `0` — `scripts/check-release-gate.sh` exited 0.
- `1` — `scripts/check-release-gate.sh` exited non-zero.

No other exit codes are documented. The wrapper uses `exec`, so the delegated
script's exit code and diagnostics are preserved.

### Side effects

Read-only. The wrapper resolves its directory and `exec`s
`scripts/check-release-gate.sh`. It writes no files and performs no git or
network work itself.

## Test surface

- **CLI-1: Delegated manifest consistency.** Disagreeing manifest versions
  fail with the delegated release-gate diagnostic.
- **CLI-2: Delegated dev-only path.** Dev-only diffs pass with the delegated
  `no shippable content changed` diagnostic.
- **CLI-3: Delegated manifest bump path.** Manifest diffs with a version
  greater than base pass with the delegated version-bumped diagnostic.
- **CLI-4: Delegated pre-PR skip path.** Shippable non-manifest diffs without
  release-intent input skip with the delegated pre-PR diagnostic.
- **CLI-4b: Delegated supplied-intent failure path.** Shippable non-manifest
  diffs with supplied invalid release intent fail with the delegated
  release-intent diagnostic.
- **CLI-5: BASE_REF seam.** `BASE_REF` is passed through to the delegated
  release gate.
- **CLI-6: REPO_ROOT seam.** `REPO_ROOT` is passed through to the delegated
  release gate.
- **CLI-7: Public report forms are shippable.** The delegated release gate
  treats public report forms as shippable content.
- **CLI-8: Consumer-root manifest absence.** Consumer roots with no plugin
  manifests skip through the delegated release gate; partial manifest sets fail.

## Versioning

- **2.1** — preserve `/finish` pre-PR execution by allowing the delegated
  release gate to skip when no PR body/event input exists yet (2026-06-03).
- **2.0** — compatibility wrapper over `scripts/check-release-gate.sh`; shippable
  non-manifest diffs now require release intent instead of same-PR manifest
  bumps (2026-06-03).
- **1.3** — skip cleanly in consumer roots with no plugin manifests, but fail incomplete plugin-manifest sets (2026-06-02).
- **1.2** — add the public report issue-form exception for `.github/ISSUE_TEMPLATE/arboretum-{problem,enhancement}.md` (2026-06-02).
- **1.1** — add `.codex-plugin/plugin.json` as the fourth version occurrence (2026-05-31).
- **1.0** — initial contract (2026-05-30).
