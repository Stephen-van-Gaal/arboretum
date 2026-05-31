---
script: scripts/check-version-bump.sh
version: 1.1
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

Pull-request gate that enforces plugin-version discipline before merge. Reads the plugin version from three locations in `.claude-plugin/` plus `.codex-plugin/plugin.json` and runs two assertions: (1) the four occurrences are mutually equal, and (2) if any shippable content was changed since the merge-base, the version has been incremented. Invoked unconditionally by `scripts/ci-checks.sh` as the final blocking check, and can be run directly by a developer in the repo root. Accepts `BASE_REF` (the comparison ref; defaults to `origin/main`) and `REPO_ROOT` (the repo root path; defaults to the parent of `scripts/`) as environment-variable seams so CI and local test fixtures can override them without patching the script.

## Protocol

### Arguments

No positional arguments and no flags. All configuration is via environment variables:

- `BASE_REF` (optional) — the git ref against which the diff is computed. Defaults to `origin/main`. CI sets this to the PR target branch (e.g. `refs/remotes/origin/main`). Smoke tests set it to a local ref to avoid network access.
- `REPO_ROOT` (optional) — absolute path to the repository root. Defaults to `$(cd "$(dirname "$0")/.." && pwd)`. Set by smoke tests to a `mktemp -d` fixture so the script never touches the live repo.

### Exit codes

- `0` — one of two success conditions: (a) all four version occurrences agree AND no shippable content changed since the merge-base (`OK: no shippable content changed`); or (b) all four occurrences agree AND shippable content changed AND the version is strictly greater than the merge-base version (`OK: shippable content changed; version bumped`).
- `1` — one of two failure conditions: (a) the four version occurrences disagree (`FAIL: plugin version occurrences disagree`); or (b) shippable content changed but the version was not incremented (`FAIL: shippable content changed but the plugin version was not incremented`). Both failure messages are emitted to stderr with the specific values that disagreed.

No other exit codes. `python3` parse errors or `git` invocation failures propagate as non-zero under `set -euo pipefail` but are not part of the documented contract surface.

### Side effects

Read-only — no side effects. The script reads JSON files under `.claude-plugin/` and `.codex-plugin/`, runs `git diff --name-only` and `git show` against the merge-base ref, and writes only to stdout/stderr. No disk writes, no network calls beyond what `git` performs to resolve `origin/main` when `BASE_REF` is left at the default.

## Test surface

- **CLI-1: Version-consistency gate.** When the version fields in `.claude-plugin/plugin.json` (`version`), `.claude-plugin/marketplace.json` (`version` and `plugins[0].version`), and `.codex-plugin/plugin.json` (`version`) are not all equal, the script exits 1 and emits `FAIL: plugin version occurrences disagree` to stderr with the differing values. All four must agree for either success path to be reachable.
- **CLI-2: No-shippable-content path exits 0.** When all four version occurrences agree and `git diff --name-only <merge-base> HEAD` returns only paths matching the dev-only regex (or no paths at all), the script exits 0 with `OK: no shippable content changed`.
- **CLI-3: Shippable-content + version-bumped path exits 0.** When all four version occurrences agree, shippable content is present in the diff, and the current version is strictly greater (tuple comparison) than the merge-base version, the script exits 0 with `OK: shippable content changed; version bumped`.
- **CLI-4: Shippable-content + no-bump path exits 1.** When all four version occurrences agree, shippable content is present in the diff, but the current version is not strictly greater than the merge-base version (equal or lower), the script exits 1 and emits `FAIL: shippable content changed but the plugin version was not incremented` to stderr.
- **CLI-5: BASE_REF seam.** When `BASE_REF` is set in the environment, the script uses it as the comparison ref for `git merge-base` and `git show` instead of `origin/main`. This allows CI and smoke tests to override the comparison target without touching the live remote.
- **CLI-6: REPO_ROOT seam.** When `REPO_ROOT` is set in the environment, the script `cd`s into that directory instead of deriving the root from `dirname "$0"`. This allows smoke tests to point the script at a temporary git fixture, isolating all file reads and git operations from the live repo.

## Versioning

- **1.1** — add `.codex-plugin/plugin.json` as the fourth version occurrence (2026-05-31).
- **1.0** — initial contract (2026-05-30).
