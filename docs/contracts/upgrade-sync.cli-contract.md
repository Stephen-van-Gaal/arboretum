---
script: scripts/upgrade-sync.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/upgrade (project-upgrade)
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-29-project-upgrade-design.md
---
<!-- owner: project-upgrade -->

# Contract for `scripts/upgrade-sync.sh`

## Surface

CLI helper invoked by the `/upgrade` skill to sync vendored framework files from the installed arboretum plugin into a project. Operates in two phases: `--plan` (pure read — emits a JSON manifest of required actions) and `--apply` (writes safe actions, merges settings, bumps the install manifest, then echoes the plan). Additional subcommands expose manifest I/O primitives for skill orchestration. Consumes `definitions/install-manifest-schema.md @v1`.

## Protocol

### Subcommands

| Subcommand | Purpose | Args |
|---|---|---|
| `--plan` | Emit a JSON plan describing every managed file's required action. Pure read — no writes. | none |
| `--apply` | Run `--plan` internally, apply all non-interactive-safe actions (`add`, `overwrite-safe`, `converged`), merge the plugin's settings template into `.claude/settings.json`, bump `framework_version` in the install manifest, then echo the full plan JSON so the caller can surface `conflict` and `report-only` entries. | none |
| `--bootstrap-manifest` | Populate `.arboretum/install-manifest.json` for a project that was installed before the manifest existed. Walks every 3-way-managed glob in the tree; records a base entry only when the tree copy matches the plugin copy (diverged files get no base, so the next `--plan` sees them as `conflict`). | none |
| `--read-manifest-sha <path>` | Print the `sha256` recorded for `<path>` in the install manifest, or empty string if absent. | `<path>` — repo-root-relative POSIX path |
| `--read-manifest-version` | Print the `framework_version` stored in the install manifest, or empty string. | none |
| `--write-manifest-entry <path> <version> <sha>` | Upsert a single file entry in the install manifest, writing `{version, sha256}` for `<path>` and setting `framework_version` to `<version>`. | `<path>` repo-root-relative POSIX path; `<version>` semver string; `<sha>` 64-char hex |

### Plan JSON shape

`--plan` and `--apply` (on stdout at exit) emit:

```json
{
  "plugin_root": "/absolute/path/to/plugin",
  "actions": {
    "scripts/health-check.sh": "overwrite-safe",
    "scripts/new-feature.sh": "add"
  },
  "policy": {
    "scripts/health-check.sh": "3way",
    "scripts/new-feature.sh": "3way"
  }
}
```

- `plugin_root` — absolute path to the resolved arboretum plugin directory.
- `actions` — map of repo-root-relative path → action (one of the closed enum below). `unchanged` entries are omitted.
- `policy` — map of repo-root-relative path → policy (`3way` or `report-only`). Keys mirror `actions`.

### Action enum (closed)

| Action | Meaning |
|---|---|
| `add` | File exists in the plugin but not in the project tree. Safe to copy. |
| `overwrite-safe` | Framework updated the file; project copy is untouched (matches base). Safe to overwrite. |
| `keep-local` | Project modified the file; framework copy is unchanged. No action needed — local wins. |
| `conflict` | Both the framework and the project have modified the file since the base. Requires human resolution. |
| `converged` | Both modified to the same content. Safe to accept as-is (records the new base). |
| `unchanged` | No change from any party. Omitted from `actions` map by `--plan`. |
| `report-removed` | File existed in manifest but is no longer in the plugin. Surfaced for human review. |
| `report-only` | File is under a `report-only` policy (e.g. `CLAUDE.md`). Surfaced for human review; never auto-applied. |

No other action values are emitted. Any value outside this set is a contract violation.

### Exit codes

- `0` — success. Subcommand completed normally.
- `2` — invocation or precondition error (emitted via `die`). Covers: unrecognised subcommand, `jq` not installed, plugin not found in cache when `UPGRADE_PLUGIN_ROOT` is unset, `--write-manifest-entry` missing required positional args.

No other exit codes. `1` is never emitted by this script.

### Side effects

`--plan` and `--read-*` subcommands are read-only — no disk writes, no network calls.

`--apply` writes:
- Copies managed files for `add`, `overwrite-safe`, `converged` actions.
- Merges plugin's `docs/templates/settings.json.template` into `.claude/settings.json` (via `seed-settings.sh`; degrades gracefully if `jq` absent).
- Rewrites `.arboretum/install-manifest.json` via `bump_manifest_version`.

`--bootstrap-manifest` and `--write-manifest-entry` write `.arboretum/install-manifest.json`.

## Test-only environment overrides

| Variable | Effect |
|---|---|
| `UPGRADE_PLUGIN_ROOT` | Replaces plugin-cache discovery — uses this directory as the plugin root. Version reported as `test`. |
| `UPGRADE_MANAGED_GLOBS` | Space-separated list of glob patterns; overrides the hardcoded managed-globs table. All substituted globs are treated as policy `3way`. |
| `UPGRADE_PLUGIN_VERSION` | Overrides `plugin_version()` — returned as the plugin semver without querying the cache. |
| `PROJECT_DIR` | Overrides the project root (fallback for `CLAUDE_PROJECT_DIR`). |

These variables are intentional test seams and must never be set in production hook or skill invocations.

## Definition dependency

This script consumes `definitions/install-manifest-schema.md @v1` — the schema governing `.arboretum/install-manifest.json`. Any change to that schema's `files` shape, `schema_version`, or field semantics requires a corresponding update to this script and a version bump in this contract.

## Versioning

- **1.0** — initial contract (2026-05-29). Ships with `upgrade-sync.sh` Task 6 (WS5 PR6, issue #316). Documents the `--plan`/`--apply`/`--bootstrap-manifest`/manifest-I/O subcommands, closed action enum, plan JSON shape, exit codes, and test-only env overrides.
