---
script: scripts/bump-version.sh
version: 1.1
invokers:
  - type: skill
    name: /finish
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/bump-version.sh`

## Surface

Atomically increments the arboretum plugin version across all four manifest occurrences — `.claude-plugin/plugin.json version`, `.claude-plugin/marketplace.json version`, `.claude-plugin/marketplace.json plugins[0].version`, and `.codex-plugin/plugin.json version` — and prints `<old> -> <new>` on stdout. Invoked by the `/finish` skill before publishing a release, or directly by developers when preparing a version bump. Usage: `scripts/bump-version.sh <major|minor|patch>`. Requires `python3` on `$PATH`. Honours `REPO_ROOT` (env) to override the default repo root (the directory containing `scripts/`), enabling isolated testing against a temp fixture without touching the live repo.

## Protocol

### Arguments

- `$1` (positional, required) — the semver component to increment: one of `major`, `minor`, or `patch`.
  - `major` — increments the major segment and resets minor and patch to 0 (e.g. `1.2.3 → 2.0.0`).
  - `minor` — increments the minor segment and resets patch to 0 (e.g. `1.2.3 → 1.3.0`).
  - `patch` — increments the patch segment (e.g. `1.2.3 → 1.2.4`).
  - Any other value (including an empty `$1`) causes an error message on stderr and exits 1.

No flags. No variadic arguments. The `REPO_ROOT` environment variable (optional) sets the repo root; defaults to the directory containing `scripts/`.

### Exit codes

- `0` — success; all four manifest occurrences updated and `<old> -> <new>` printed to stdout.
- `1` — failure; one of:
  - bad or missing `$1` argument (not `major`, `minor`, or `patch`).
  - a required manifest file is not found under `$REPO_ROOT/.claude-plugin/` or `$REPO_ROOT/.codex-plugin/`.
  - the four version occurrences disagree before the bump (manifest inconsistency detected by the embedded Python block).
  - the version string is not `MAJOR.MINOR.PATCH` format (Python `ValueError` on split).

### Side effects

Rewrites three files in-place under `$REPO_ROOT`:

- `.claude-plugin/plugin.json` — `version` field updated to the new version.
- `.claude-plugin/marketplace.json` — top-level `version` field and `plugins[0].version` field both updated to the new version.
- `.codex-plugin/plugin.json` — `version` field updated to the new version.

Both files are re-serialised with 2-space indent and a trailing newline; `ensure_ascii=False` preserves any non-ASCII characters (e.g. em dashes in descriptions) rather than escaping them to `\uXXXX`. No other files are written. No git operations are performed — the script does not tag, commit, or stage any files. No network calls. Pinned in CLI-4.

## Test surface

- **CLI-1: patch increment.** Given manifests at `1.2.3`, `bash bump-version.sh patch` with `REPO_ROOT` set to a temp dir exits 0, prints `1.2.3 -> 1.2.4` on stdout, and all four version occurrences in the manifest files read `1.2.4`.
- **CLI-2: minor increment resets patch.** Given manifests at `1.2.3`, `bash bump-version.sh minor` exits 0 and all four occurrences read `1.3.0`.
- **CLI-3: major increment resets minor and patch.** Given manifests at `1.2.3`, `bash bump-version.sh major` exits 0 and all four occurrences read `2.0.0`.
- **CLI-4: no git side effects.** After a successful bump, no git tag is created, no commit is made, and no files outside `$REPO_ROOT/.claude-plugin/` and `$REPO_ROOT/.codex-plugin/` are modified. The script is purely a file-rewrite tool.
- **CLI-5: bad argument rejected.** Invoking with an unrecognised argument (e.g. `sideways`, empty string, or no argument) exits non-zero and emits a usage message to stderr.
- **CLI-6: missing manifest rejected.** When either `plugin.json` or `marketplace.json` is absent under `$REPO_ROOT/.claude-plugin/`, the script exits 1 with an error message on stderr naming the missing file.
- **CLI-7: disagreeing manifests rejected.** When the four version occurrences do not agree before the bump, the script exits non-zero without modifying any file.

## Versioning

- **1.1** — add `.codex-plugin/plugin.json` as the fourth version occurrence (2026-05-31).
- **1.0** — initial contract (2026-05-30).
