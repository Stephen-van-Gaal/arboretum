---
name: upgrade
owner: project-upgrade
description: Re-sync vendored framework files in an already-initialized arboretum project from the installed plugin. Classifies each file against the install-manifest (add/overwrite-safe/keep-local/conflict/report-only), applies the safe actions, surfaces conflicts, and verifies. Use when a project is behind the framework (e.g. missing a new hook, script, or template).
---

# Upgrade

Deploy framework evolution from the installed plugin into this project's tree.
`/plugin update` refreshes the *source* (plugin cache); `/upgrade` deploys it here.

## Preconditions (halt with the reason if any fail)
1. `.arboretum.yml` exists at the project root (this is an arboretum project; #383).
2. Inside a git repository.
3. Working tree is clean enough — if dirty, list the dirty paths and ask to stop
   (recommended; git is the recovery net) or proceed.

## Procedure

> **Note — plugin-first invocation:** The helper is invoked from the plugin copy
> (`${CLAUDE_PLUGIN_ROOT}/scripts/upgrade-sync.sh`) rather than the project copy
> (`scripts/upgrade-sync.sh`). This is intentional: the project copy may not exist
> on the first `/upgrade` run (e.g. a project initialized before the upgrade system
> was added). The plugin copy is always present once the plugin is installed.
> The plugin path below is rendered to an absolute path when this skill loads, so it
> resolves even though `CLAUDE_PLUGIN_ROOT` is **not** exported into the Bash tool's
> runtime. The project copy is used only as a fallback, when the plugin copy is absent.

```bash
# Primary: the plugin copy — always present once installed. ${CLAUDE_PLUGIN_ROOT} is
# rendered to an absolute path when this skill loads, so this resolves without the
# variable being exported into the Bash runtime (it isn't). Fall back to the project
# copy only if the plugin copy is genuinely absent.
_SYNC="${CLAUDE_PLUGIN_ROOT}/scripts/upgrade-sync.sh"
[ -f "$_SYNC" ] || _SYNC="scripts/upgrade-sync.sh"
```

1. **Plan (read-only):** `bash "$_SYNC" --plan` → parse the JSON.
   If it exits 2 with "plugin not found", relay the `/plugin install arboretum`
   guidance and stop. If the manifest is missing/malformed, run
   `bash "$_SYNC" --bootstrap-manifest` first, then re-plan.
2. **Present** the plan grouped by action:
   - `add` / `overwrite-safe` / `converged` — will be applied (safe; reversible via git).
   - `conflict` — for each, show `git diff --no-index <tree> <plugin>` and DEFAULT to
     preserve-local. Only overwrite a conflicted file on explicit user say-so.
   - `report-only` (`CLAUDE.md`, `PRINCIPLES.md`) — show the framework diff; never edit.
   - `report-removed` — note the framework dropped it; never auto-delete.
   If `actions` is empty: report "already current" and stop.
3. **Apply:** `bash "$_SYNC" --apply` (writes safe actions, merges the
   settings allowlist additively, bumps the manifest when no conflicts remain).
   For any conflict the user chose to take, copy that file from `plugin_root` manually
   and record it via `bash "$_SYNC" --write-manifest-entry <path> <version> <sha>`.
4. **Verify:** regenerate the register (`bash scripts/generate-register.sh`) and run
   `bash scripts/health-check.sh`; surface stale version pins. Leave everything
   uncommitted for git review — do NOT commit on the user's behalf.
5. Summarize: N added, N updated, N conflicts surfaced, N report-only.

## De-register migration (activates once a hook is plugin-provided)
If a path recorded in the manifest is now provided by the plugin as a plugin-level
hook (declared in the plugin's `hooks/hooks.json`) rather than a vendored file,
remove the project-level copy and its `SessionStart` registration in
`.claude/settings.json`, and drop its manifest entry — preventing a double-fire.
(No-op until the step-7 fast-follow lands; see design spec § De-vendoring migration.)
