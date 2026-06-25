---
name: upgrade
owner: project-upgrade
scope: plugin-only
description: Re-sync vendored framework files in an already-initialized arboretum project from the installed plugin. Classifies each file against the install-manifest (add/overwrite-safe/overwrite-local/keep-local/conflict/report-only) under a plugin-wins policy — adopters do not fork framework code — applies the safe actions, surfaces conflicts, and verifies. Use when a project is behind the framework (e.g. missing a new hook, script, or template).
---

# Upgrade

Deploy framework evolution from the installed plugin into this project's tree.
`/plugin update` refreshes the *source* (plugin cache); `/upgrade` deploys it here.

## Preconditions (halt with the reason if any fail)
1. Project root is recognized: either `.arboretum.yml` exists, or the legacy
   `roadmap.config.yaml` marker exists (older Arboretum projects such as Cedar
   may predate `.arboretum.yml`). If only `roadmap.config.yaml` exists, say this
   is a legacy upgrade; `--apply` will create `.arboretum.yml` with `layer: 0`
   and preserve the configured backend.
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
   Read `.removal_detection`: if `inconclusive`, the manifest has no baseline yet,
   so removal detection is **disabled** — say so explicitly when summarizing; do
   NOT present the plan as "zero removals" (#407). Running `--bootstrap-manifest`
   (or a first `--apply`) establishes the baseline so later runs report `active`.
2. **Present** the plan grouped by action:
   - `add` / `overwrite-safe` / `converged` — will be applied (safe; reversible via git).
   - `overwrite-local` — will be applied: the plugin copy **replaces a divergent local
     edit** to a framework file (plugin-wins policy #394). For each, show
     `git diff --no-index <tree> <plugin>` so the user sees what local edit is discarded.
     git is the recovery net; flag these distinctly from clean `overwrite-safe` updates.
   - `keep-local` / `conflict` — deletion cases (a tracked framework file deleted
     locally). `keep-local`: plugin unchanged, deletion respected. `conflict`: plugin
     changed it since — show the diff and ask before re-adding.
   - `report-only` (`CLAUDE.md`, `PRINCIPLES.md`) — show the framework diff; never edit.
   - `report-removed` — note the framework dropped it; never auto-delete (only when
     `removal_detection` is `active`).
   If `actions` is empty:
   - When `.arboretum.yml` is absent and legacy `roadmap.config.yaml` is present,
     report "framework files already current; legacy marker migration still
     needed" and proceed to Step 3 so `--apply` creates `.arboretum.yml` and the
     install manifest baseline.
   - Otherwise report "already current" (noting removal-detection status) and stop.
3. **Apply:** `bash "$_SYNC" --apply` (writes safe actions, creates
   `.arboretum.yml` for legacy `roadmap.config.yaml` projects while preserving
   the backend, merges the settings allowlist additively, bumps the manifest when
   no conflicts remain).
   For any conflict the user chose to take, copy that file from `plugin_root` manually
   and record it via `bash "$_SYNC" --write-manifest-entry <path> <version> <sha>`.
4. **Seed journey-log trust allowlist (config migration, #249):** If `.arboretum.yml`
   lacks `trust.journey_log_authors` (check: `bash scripts/read-trust-config.sh .arboretum.yml`
   prints `present=no`), OFFER to seed it — do not force it.
   - Explain in one line: pipeline-state journey-log comments (`<!-- pipeline-state:log -->`)
     are now author-trust-gated so a drive-by commenter cannot forge `/land` state; until
     the key is configured, entries from all authors are surfaced with a warning.
   - Retrieve candidates from the git provider (degrade gracefully if a call fails):
     - `gh api user --jq .login` — the account that runs the pipeline (pre-select this).
     - `gh api repos/{owner}/{repo}/collaborators --jq '.[] | select(.permissions.push==true) | .login'`
       — push-access collaborators (the right trust boundary; anyone who can push could merge
       code anyway, so trusting their entries adds no marginal risk).
     - `github-actions[bot]` — offer for CI-posted entries.
     - These `gh api` calls are read-only (GET) and run during the interactive
       walk-through, so the operator approves them at the prompt; they are deliberately
       NOT in the seeded permission allow list (a broad `gh api` grant would also permit
       mutations — #598 review, Codex P1).
   - Walk the human through selection with `AskUserQuestion` (multiSelect), pre-selecting the
     current user + bot. If the collaborator call fails (org restriction / perms), fall back
     to current user + bot and say so.
   - Write the chosen set: `bash scripts/manage-trust.sh set .arboretum.yml <login>...`
     (`set` is an **authoritative replace** — it writes exactly the chosen logins, so the
     human curates add/remove here; it overwrites an existing list, which is correct because
     this write only happens after the walk-through above. `instantiate`, by contrast, is
     additive-only and never overwrites — but it cannot remove, so the curation path uses
     `set`.) Confirm what landed; note it is editable in `.arboretum.yml` and that
     `manage-trust.sh maintain` (a planned follow-up) will offer contribution-based review.
   - If the user declines, leave the key absent — the permissive grace period + warning still
     covers them. Never write without the walk-through.
5. **Verify:** regenerate the register (`bash scripts/generate-register.sh`) and run
   `bash scripts/health-check.sh`; surface stale version pins. Leave everything
   uncommitted for git review — do NOT commit on the user's behalf.
6. Summarize: N added, N updated (overwrite-safe), N local edits replaced
   (overwrite-local), N conflicts surfaced, N report-only. State the
   removal-detection status: `active` → "N stale files flagged" / "none stale";
   `inconclusive` → "removal detection disabled (no manifest baseline yet)".

## De-register migration (activates once a hook is plugin-provided)
If a path recorded in the manifest is now provided by the plugin as a plugin-level
hook (declared in the plugin's `hooks/hooks.json`) rather than a vendored file,
remove the project-level copy and its `SessionStart` registration in
`.claude/settings.json`, and drop its manifest entry — preventing a double-fire.
(No-op until the step-7 fast-follow lands; see design spec § De-vendoring migration.)
