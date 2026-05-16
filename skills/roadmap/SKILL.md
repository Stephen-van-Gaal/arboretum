---
name: roadmap
owner: roadmap
description: Strategic + tactical project direction. Phase 1 MVP — `run` (default; cheap daily orientation) and `instantiate` (one-time setup). Other methods (`maintain`, `shape`, `ready`, `agent-prep`, `sprint open/close`, `revise`) are stubbed and surface "not yet implemented" if invoked. See docs/superpowers/specs/2026-05-09-roadmap-system-design.md.
disable-model-invocation: false
allowed-tools: Bash, Read, AskUserQuestion, Write, Edit
layer: 2
argument-hint: "[run|instantiate|<other-method>]"
---

# Roadmap — Phase 1 MVP

Daily orientation + one-time setup. The other methods named in the design spec are stubbed; this is the smallest set that delivers session-start orientation value.

**Reference:** `docs/superpowers/specs/2026-05-09-roadmap-system-design.md` is the authoritative design. This skill implements §6a/§6b's `run` and `instantiate` methods.

## Dispatch

Parse the first argument:

| Arg | Method | Status |
|---|---|---|
| `run` (or no arg) | §1 below | implemented |
| `instantiate` | §2 below | implemented |
| `maintain` | (Phase 2) | print "not yet implemented; planned in Phase 2" + reason |
| `shape <n>` / `ready <n>` | (Phase 3) | same |
| `agent-prep <n>` | (Phase 5) | same |
| `sprint open` / `sprint close` | (Phase 4) | same |
| `revise` | (Phase 6) | same |

For stubs, surface the "not yet implemented" message and link the spec section. Don't pretend.

## Sanity gate (runs before every method)

```bash
command -v gh >/dev/null 2>&1 || { echo "[/roadmap] gh CLI not found — install gh first" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "[/roadmap] gh not authenticated — run: gh auth login" >&2; exit 1; }
```

If labels schema is missing on this repo (`gh label list` shows none of `type:feature`, `horizon:now`), surface a one-line nudge before dispatching to the requested method:

> "[/roadmap] No type:* / horizon:* labels found. Run `/roadmap instantiate` first to set up the vocabulary."

For `run`, proceed anyway (the helper renders an empty view gracefully).
For `instantiate`, this is the expected state — proceed.
For other methods, refuse and ask the user to instantiate first.

## §1. `/roadmap run` — daily orientation (default)

Cheap, fast, read-only. No mutations.

```bash
bash scripts/roadmap/render-run.sh
```

The renderer produces a one-screen view: Done (last 7d) / Now / Next / Agent-ready / Later (top 5) / Slack / Recommend.

If invoked with `--condensed`, output is the ~5-line orientation block used by the SessionStart hook. The hook calls this directly.

### Recommend logic

The renderer's RECOMMEND block surfaces a single line. The skill should narrate one extra sentence based on the output, customized to current state:

| Observed | Suggest |
|---|---|
| WIP ≥ 1 AND now-list non-empty | "Finish #<n> before starting another." |
| WIP = 0 AND now-list non-empty | "Pick up #<n>?" |
| WIP = 0 AND now-list empty AND next-list non-empty | "Promote #<n> from NEXT (run `/roadmap maintain` once Phase 2 ships, or manually edit horizon labels for now)." |
| All lists empty | "Capture new work with `/idea`." |
| agent-ready list non-empty | "★ #<n> is agent-ready — delegate via `/start --agent <n>` (when Phase 5 ships)." |

## §2. `/roadmap instantiate` — one-time setup

Walk the user through:
1. Pre-flight (`gh` auth, current labels survey)
2. Profile selection
3. `roadmap.config.yaml` authoring (component_values + audience_values)
4. Label schema install (idempotent)
5. Issue templates (optional)
6. CLAUDE.md `## Strategic Anchor` section (optional)
7. Existing-label migration (manual, LLM-guided — NOT skill-automated per spec §5)
8. Print summary + suggest `/roadmap run`

### Step 1 — Pre-flight survey

```bash
echo "[/roadmap instantiate] Surveying current state..."
gh label list --limit 100 --json name --jq '.[].name' > /tmp/roadmap-current-labels.txt
gh issue list --state open --limit 200 --json number,labels > /tmp/roadmap-current-issues.json
echo "Current labels: $(wc -l < /tmp/roadmap-current-labels.txt)"
echo "Current open issues: $(jq 'length' /tmp/roadmap-current-issues.json)"
```

Surface counts of any pre-existing labels that look like they collide:
- `enhancement`, `bug`, `documentation` (GitHub defaults — will alias, not relabel)
- `priority:*` (one-time manual migration; see step 7)
- Any other `<word>:` prefix labels (project-defined; preserve)

### Step 2 — Profile selection

Use `AskUserQuestion`:

```
Question: "What kind of project is this?"
Header: "Profile"
Options:
  - "Full":    "Product with customers and ship deadlines (e.g., conversations)"
  - "Lean":    "Internal/exploratory, no fixed cadence (e.g., cedar_prod)"
  - "Minimal": "Small repo (<30 issues), single-stream work, low ceremony"
```

Record choice as `profile:` field in config.

### Step 3 — Author `roadmap.config.yaml`

Path: `roadmap.config.yaml` (repo root, gitignored via `.gitignore`).

Walk the user through:
- `component_values:` — what are the major surfaces of your project? (5-prompt mini-interview; user lists 3-8)
- `audience_values:` — only if Full profile and user has multiple customer segments; else omit
- `branch_prefixes:` — what branch prefixes does this project use? Detect from `git branch -a`; offer the detected list as default
- `wip_limit:` — default 1; ask if user wants higher

Use the spec §4f template as the file structure. Write the file. Show diff before write.

### Step 4 — Install labels

```bash
bash scripts/roadmap/install-labels.sh --config roadmap.config.yaml
```

For **Minimal** profile, omit `--config` so component/audience labels aren't created (Minimal projects skip those axes).

Show summary: `created=N skipped=M failed=0`. Refuse to proceed if any failed.

### Step 5 — Issue templates (optional)

Ask:

> "Install `.github/ISSUE_TEMPLATE/{epic,work-now,work-next,work-later}.md` templates? (recommended; can skip if your repo has its own)"

If yes: copy from `docs/templates/issue-templates/` (when shipped — for MVP, just create them inline from the spec §4a/§4b content).

### Step 6 — CLAUDE.md `## Strategic Anchor`

Ask:

> "Add a `## Strategic Anchor` section to CLAUDE.md? (recommended for Full / Lean profiles; optional for Minimal)"

If yes: append the section using spec §4d as template. Walk user through:
- Time horizon (date in the future)
- In scope (3-5 bullets)
- Out of scope (3-5 bullets — these are usually the more valuable list)

### Step 7 — Existing-label migration (manual, LLM-guided)

This step is NOT automated. Per spec §5, priority migrations and project-specific label remapping happen as a one-time conversation, not as skill machinery. Surface to user:

> "Detected the following existing labels that likely map to the new vocabulary:
>   - `enhancement` (N issues) — will be aliased to `type:feature`; no relabel needed
>   - `priority:high` (N issues) — recommend manual review and apply `horizon:now` per-issue
>   - `priority:medium` (N issues) — recommend manual review and apply `horizon:next` per-issue
>   - `priority:low` (N issues) — recommend close-or-`horizon:later` per-issue
>   - <other detected> — surface for user decision
>
> Want to walk through the priority:* migration now (interactive, ~15-30 min for typical board), or defer? The labels stay until you migrate; the framework still works without them moving — `/roadmap run` just won't show them in the right horizon bucket until then."

If user wants to walk through: run an interactive loop that surfaces each issue and asks for the right horizon. **This is the skill's only "manual conversational" step** — everything else is mechanical.

If user defers: print the migration recipe to a file (`docs/roadmap-migration-todo.md`) and continue.

### Step 8 — Summary + next steps

```
✓ Profile: <choice>
✓ Created N labels (M skipped as already present)
✓ Wrote roadmap.config.yaml
✓ Issue templates: installed / skipped
✓ CLAUDE.md Strategic Anchor: added / skipped
✓ Migration: completed / deferred to docs/roadmap-migration-todo.md

Next:
  → Run `/roadmap` (or `/roadmap run`) to see the daily view
  → Capture new ideas with `/idea`
  → /roadmap maintain (Phase 2) is not yet implemented
```

## Operational notes

- **Read-only safety:** `run` mutates nothing. `instantiate` mutates only after explicit confirmation per step.
- **Failure handling:** if any `gh` call fails mid-instantiate, prompt the user with what succeeded vs failed; don't try to roll back (idempotent installer means re-running picks up where it left off).
- **Schema-coupled scripts rule (per CLAUDE.md):** the labels this skill installs are consumed downstream by `/roadmap maintain` (Phase 2), `/idea`, and the SessionStart hook. Before any change to the label vocabulary in `scripts/roadmap/install-labels.sh`, grep all consumers and update in the same change.

## What's NOT in this MVP (deferred)

- `/roadmap maintain` (Phase 2) — confidence × reversibility action model on orphan detection
- Promotion gates (`shape`, `ready`) (Phase 3)
- Sprint planning (Phase 4)
- Agent-prep (Phase 5)
- Strategic review (`revise`) (Phase 6)
- Pulse-file + time-based nags (Phase 1.5)

For each, the skill prints a "not yet implemented" message rather than failing silently.
