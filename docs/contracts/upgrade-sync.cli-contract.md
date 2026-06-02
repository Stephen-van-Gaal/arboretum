---
script: scripts/upgrade-sync.sh
version: 1.3
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
| `--apply` | Run `--plan` internally, apply all non-interactive-safe actions (`add`, `overwrite-safe`, `overwrite-local`, `converged`, `remove-obsolete`), merge the plugin's settings template into `.claude/settings.json`, bump `framework_version` in the install manifest, then echo the full plan JSON so the caller can surface `conflict` and `report-only` entries. | none |
| `--bootstrap-manifest` | Populate `.arboretum/install-manifest.json` for a project that was installed before the manifest existed. Walks every 3-way-managed glob in the tree; records a base entry only when the tree copy matches the plugin copy (diverged files get no base, so the next `--plan` sees them as `overwrite-local` under the plugin-wins policy). | none |
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
  },
  "removal_detection": "active"
}
```

- `plugin_root` — absolute path to the resolved arboretum plugin directory.
- `actions` — map of repo-root-relative path → action (one of the closed enum below). `unchanged` entries are omitted.
- `policy` — map of repo-root-relative path → policy (`3way`, `report-only`, or `obsolete`). Keys mirror `actions`.
- `removal_detection` — `active` when the install manifest has a baseline (≥1 tracked file) and `report-removed` detection is meaningful; `inconclusive` when the manifest is empty or absent, so removal detection is disabled and the absence of `report-removed` entries is NOT a guarantee that no framework files are stale (#407). Callers must not present an inconclusive plan as "zero removals".

### Action enum (closed)

| Action | Meaning |
|---|---|
| `add` | File exists in the plugin but not in the project tree. Safe to copy. |
| `overwrite-safe` | Framework updated the file; project copy is untouched (matches base). Safe to overwrite. |
| `overwrite-local` | Framework file present in both, with a divergent local copy. Under the plugin-wins policy (#394) the plugin copy wins: applied like `overwrite-safe`, but named distinctly because it **discards local edits** to a framework file (git is the recovery net). Adopters do not fork framework code. |
| `keep-local` | Project deleted a tracked framework file that the plugin still ships unchanged. Deletion respected — not re-added. (Plugin-wins governs edits, not deletions.) |
| `conflict` | Project deleted a tracked framework file that the plugin has since changed. Requires human resolution. |
| `converged` | Both modified to the same content. Safe to accept as-is (records the new base). |
| `remove-obsolete` | Project tree contains a file that now matches an excluded framework path (for example `scripts/_smoke-test-*.sh`) and is safe to delete because it either still matches the recorded install-manifest base or exactly matches the current plugin copy. Applied by `--apply`; also removes that path from the install manifest when present. |
| `unchanged` | No change from any party. Omitted from `actions` map by `--plan`. |
| `report-removed` | File existed in manifest but is no longer in the plugin. Surfaced for human review; never auto-deleted. Only meaningful when `removal_detection` is `active`. |
| `report-only` | File is under a `report-only` policy (e.g. `CLAUDE.md`). Surfaced for human review; never auto-applied. |

No other action values are emitted. Any value outside this set is a contract violation.

### Managed file set

Default managed globs cover operational framework files under `scripts/*.sh`, `scripts/lib/*`, `scripts/roadmap/*`, `.claude/hooks/*`, `.githooks/*`, `docs/templates/*`, `docs/definitions/*`, and `workflows/*`. Exclusions apply after the glob union is computed: `scripts/bootstrap-project.sh` is legacy bootstrap-only, and `scripts/_smoke-test-*.sh` are plugin/dev self-tests. Neither path class is propagated by `/upgrade`, including when `UPGRADE_MANAGED_GLOBS` is set for tests. If such an excluded file already exists in a project and is safe framework residue (manifest-base match or current-plugin-copy match), `--plan` emits `remove-obsolete` and `--apply` deletes it. Locally edited excluded files are left in place.

### Exit codes

- `0` — success. Subcommand completed normally.
- `2` — invocation or precondition error (emitted via `die`). Covers: unrecognised subcommand, `jq` not installed, plugin not found in cache when `UPGRADE_PLUGIN_ROOT` is unset, `--write-manifest-entry` missing required positional args.

No other exit codes. `1` is never emitted by this script.

### Side effects

`--plan` and `--read-*` subcommands are read-only — no disk writes, no network calls.

`--apply` writes:
- Copies managed files for `add`, `overwrite-safe`, `overwrite-local`, `converged` actions.
- Deletes safe obsolete excluded framework files for `remove-obsolete` actions and drops their manifest entries.
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

- **1.3** — adds `remove-obsolete` so `/upgrade --apply` cleans up already-copied excluded framework files, such as plugin self-tests, when they are safe to delete (2026-06-02).
- **1.2** — excludes plugin/dev self-tests (`scripts/_smoke-test-*.sh`) from managed upgrade propagation, matching `/init`'s consumer packaging boundary (2026-06-02).
- **1.1** — plugin-wins policy + removal-detection honesty (2026-05-30, issues #394/#407). Adds the `overwrite-local` action: a divergent local copy of a framework file present in both tree and plugin now resolves to plugin-wins (applied, discards local edits) instead of `keep-local`/`conflict` — adopters do not fork framework code. Redefines `keep-local`/`conflict` as deletion-only cases. Adds the `removal_detection` plan field (`active`|`inconclusive`) so an empty-manifest plan is not misread as "zero removals". `--bootstrap-manifest` divergent files now classify `overwrite-local` on the next `--plan`.
- **1.0** — initial contract (2026-05-29). Ships with `upgrade-sync.sh` Task 6 (WS5 PR6, issue #316). Documents the `--plan`/`--apply`/`--bootstrap-manifest`/manifest-I/O subcommands, closed action enum, plan JSON shape, exit codes, and test-only env overrides.
