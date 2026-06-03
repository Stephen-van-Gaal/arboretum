---
script: scripts/check-release-gate.sh
version: 1.1
invokers:
  - type: script
    name: scripts/check-version-bump.sh
  - type: script
    name: scripts/ci-checks.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-03-release-intent-lane-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/check-release-gate.sh`

## Surface

Pull-request gate that enforces release intent for shippable feature PRs and
strict manifest-version correctness for Release Package PRs. It reads plugin
versions from `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
top-level `version`, `.claude-plugin/marketplace.json plugins[0].version`, and
`.codex-plugin/plugin.json`. It computes the diff against the merge-base and
classifies the diff as dev-only, shippable non-manifest, or manifest-touching.
Shippable non-manifest diffs require valid pending release intent when a PR
body or GitHub event is available; local pre-PR runs without either intent
input skip so `/finish` can reach `/pr`, where intent is selected and
validated. Manifest diffs require all version occurrences to agree and be
greater than base.

## Protocol

### Arguments

No positional arguments and no flags. Configuration is via environment
variables:

- `BASE_REF` (optional) - git ref for the merge-base comparison. Defaults to
  `origin/main`.
- `REPO_ROOT` (optional) - repository root. Defaults to the parent directory of
  `scripts/`.
- `RELEASE_INTENT_BODY_FILE` (optional) - PR body file passed to
  `scripts/read-release-intent.sh --body-file`.
- `RELEASE_INTENT_EVENT` (optional) - GitHub pull-request event JSON passed to
  `scripts/read-release-intent.sh --github-event`.

When both release-intent input variables are present, `RELEASE_INTENT_BODY_FILE`
takes precedence.

### Exit codes

- `0` - one of five success paths: consumer root with no plugin manifests,
  dev-only diff, shippable non-manifest diff with no release-intent input
  available yet (local pre-PR skip), shippable non-manifest diff with pending
  `patch|minor|major` intent, or manifest diff with versions consistent and
  greater than base.
- `1` - incomplete manifest set, manifest-version disagreement, manifest diff
  without a version increment, supplied release-intent input that is missing or
  invalid for shippable non-manifest content, or release intent explicitly set
  to `none` for shippable content.

No other exit codes are documented. `git`, JSON, or Python failures propagate
under `set -euo pipefail`.

### Side effects

Read-only. The script reads git history, plugin manifests, and optionally a PR
body or GitHub event file. It invokes `scripts/read-release-intent.sh`. It
writes only stdout/stderr and performs no git writes, no network calls, no
commits, no tags, and no filesystem mutation.

## Test surface

- **CLI-1: Dev-only diff.** A diff confined to dev-only paths exits 0 without
  release intent and emits `no shippable content changed`.
- **CLI-2: Pending release intent.** A shippable non-manifest diff with
  `release-impact: patch` and `release-state: pending` exits 0 and emits
  `release intent patch pending`.
- **CLI-3: Pre-PR skip.** A shippable non-manifest diff without
  release-intent input exits 0 and emits `release intent input not available`.
- **CLI-3b: Missing supplied release intent.** A shippable non-manifest diff
  with supplied body/event input that lacks a Release Intent section exits 1 and
  emits `release intent is missing or invalid`.
- **CLI-4: None release intent.** A shippable non-manifest diff with
  `release-impact: none` exits 1 and emits `release-impact is none`.
- **CLI-5: Manifest bump.** A manifest-touching diff whose current version is
  greater than base exits 0 and emits the old and new versions.
- **CLI-6: Stale manifest edit.** A manifest-touching diff whose current
  version is equal to base exits 1 and emits `plugin version was not incremented`.
- **CLI-7: Manifest disagreement.** Disagreeing version occurrences exit 1 and
  emit `plugin version occurrences disagree`.
- **CLI-8: Consumer-root skip.** A root with no plugin manifests exits 0 and
  emits `plugin version manifests not found`.

## Versioning

- **1.1** - local pre-PR runs skip when no release-intent input exists yet,
  while supplied PR body/event inputs remain strict (2026-06-03).
- **1.0** - initial release gate contract separating release intent from
  Release Package materialization (2026-06-03).
