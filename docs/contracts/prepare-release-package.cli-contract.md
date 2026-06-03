---
script: scripts/prepare-release-package.sh
version: 1.1
invokers:
  - type: developer
  - type: skill
    name: /cleanup
related-designs:
  - docs/superpowers/specs/2026-06-03-release-intent-lane-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/prepare-release-package.sh`

## Surface

Creates a Release Package from pending release intents. The helper runs from an
up-to-date `main` branch, identifies the release checkpoint, collects pending
`patch|minor|major` intents, computes the highest impact, generates the next
version, delegates manifest edits to `scripts/bump-version.sh`, writes
`docs/releases/vX.Y.Z.md`, and updates `CHANGELOG.md`. Before materializing a
non-dry-run package, the manifest version must match the checkpoint version;
after `bump-version.sh` runs, the manifest version must match the computed next
version. Usage:
`scripts/prepare-release-package.sh [--body-dir <path> | --since <ref>] [--checkpoint-version <semver>] [--dry-run]`.

## Protocol

### Arguments

- `--body-dir <path>` - fixture/manual mode. Reads `*.md` PR-body files from
  the directory.
- `--since <ref>` - live mode. Uses roadmap tracker helpers to list merged PRs,
  optionally filtering by merge time after the git commit date of `<ref>`.
- `--checkpoint-version <semver>` - bootstrap fallback when no
  `docs/releases/v*.md` record exists.
- `--dry-run` - computes and prints the package summary without invoking
  `bump-version.sh` and without writing release notes or changelog entries.

`REPO_ROOT` may point at a fixture repository. When unset, the helper uses the
current git toplevel or `$PWD`.

### Exit codes

- `0` - a pending Release Package was computed; in non-dry-run mode manifests
  were delegated to `bump-version.sh` and package notes were written.
- `1` - not on `main`, no pending release intents were found, release-intent
  parsing failed for an invalid supplied body, checkpoint version was malformed,
  checkpoint and manifest versions disagree, live PR collection reached its
  safety limit before the requested cutoff, `bump-version.sh` failed, or the
  post-bump manifest version did not match the computed next version.
- `2` - invocation problem: unknown argument, missing argument value, missing
  body directory, or incompatible `--body-dir` and `--since` arguments.

### Side effects

In `--dry-run` mode the helper is read-only. In normal mode it invokes
`scripts/bump-version.sh <impact>` with `REPO_ROOT` set, verifies the manifest
version now equals the computed `next-version`, writes `docs/releases/vX.Y.Z.md`,
and updates `CHANGELOG.md`. It does not commit, tag, push, create a pull
request, deploy, or call the public sync workflow.

Live mode fetches merged PRs through `roadmap_tracker_pr_list` with an explicit
safety limit. If the result reaches that limit and the oldest fetched PR is
still newer than the `--since` cutoff, the helper fails closed instead of
silently omitting older pending intents. PR titles are sanitized before being
stored in the helper's internal delimited record format, so `|` in a title
cannot corrupt impact calculation or release-note output.

## Test surface

- **CLI-1: Fixture max impact.** Given pending `patch` and `minor` bodies plus
  explicit `none`, dry-run exits 0 with `release-impact=minor`,
  `next-version=0.25.0`, and `included-count=2`.
- **CLI-2: Dry-run read-only.** The same dry-run does not create
  `docs/releases/` or `CHANGELOG.md`.
- **CLI-3: Release note output.** Normal mode writes `docs/releases/v0.25.0.md`
  with the expected title, included PR entries, and upgrade notes.
- **CLI-4: Changelog index.** Normal mode updates `CHANGELOG.md` with a link to
  the per-release notes.
- **CLI-5: Bump delegation.** Normal mode invokes `scripts/bump-version.sh`
  with the computed impact.
- **CLI-6: Materialized skip.** Bodies with `release-state: materialized` do
  not count as pending release intents.
- **CLI-7: No-pending failure.** A body set containing only `none`,
  `not-needed`, materialized, or missing intents exits 1 with
  `no pending release intents found`.
- **CLI-8: Main-branch guard.** Running from any branch other than `main`
  exits 1 with `must run from main`.
- **CLI-9: Checkpoint/manifest agreement.** A non-dry-run package whose
  checkpoint version differs from the current manifest version exits 1 before
  invoking `bump-version.sh`.
- **CLI-10: Post-bump verification.** If `bump-version.sh` returns success but
  leaves manifests at a version other than `next-version`, the helper exits 1
  and writes no release notes.
- **CLI-11: Title sanitization.** PR titles containing `|` are sanitized in
  generated release notes.
- **CLI-12: Live collection safety limit.** Live mode fails closed when the
  merged-PR collection reaches its safety limit before the `--since` cutoff.

## Versioning

- **1.1** - fail closed on checkpoint/manifest drift, verify post-bump
  manifest version, sanitize pipe-delimited titles, and guard live PR
  collection against silent truncation (2026-06-03).
- **1.0** - initial Release Package helper contract (2026-06-03).
