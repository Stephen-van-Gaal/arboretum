---
name: roadmap
description: "Manage the roadmap system: install vocabulary, view orientation, and (in later phases) triage, shape, ready, sprint, and revise. Use '/roadmap instantiate' to set up a fresh project, '/roadmap run' (or just '/roadmap') for the daily orientation view."
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - AskUserQuestion
owner: roadmap
argument-hint: "[instantiate|run] [args]"
layer: 0
---

# Roadmap

Dispatcher for the roadmap system. Phase 1 sub-methods: `instantiate`, `run`.
Future phases add `maintain`, `shape <n>`, `ready <n>`, `agent-prep <n>`,
`sprint open`, `sprint close`, `retro`, `revise`.

## When to use

- New project, roadmap system not yet installed: `/roadmap instantiate`.
- Daily orientation check: `/roadmap run` or just `/roadmap` (no args).

## Procedure

Parse `$ARGUMENTS`. First token selects the sub-method; remaining tokens are
its args. Default (no arguments) is `run`.

### `run` (default)

If `$ARGUMENTS` is empty or starts with `run`, execute:

```bash
ROOT="$(git rev-parse --show-toplevel)"
bash "$ROOT/scripts/roadmap/build-orientation.sh"
```

Print the output verbatim. No interaction.

### `instantiate`

If `$ARGUMENTS` starts with `instantiate`, follow the instantiate procedure
defined below.

#### Step i.1: Preconditions

Check `gh` is installed and authenticated:

```bash
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/roadmap/lib.sh"
roadmap_require_gh || exit 1
```

Verify the repo has a GitHub remote that `gh` can resolve:

```bash
gh repo view >/dev/null 2>&1 || { echo "No accessible GitHub remote found."; exit 1; }
```

#### Step i.2: Choose adoption profile

Use AskUserQuestion:

> "Which adoption profile fits this project?"

Options:
- **Minimal** — `/idea` + `/roadmap run` only. <30 issues, single-stream, low ceremony.
- **Lean** — schema + `/idea` + run + maintain + Epics + agent-prep. Exploratory/internal, no fixed cadence.
- **Full** — Lean + sprints + audience axis + promotion gates + quarterly revise. Deadline-driven, customer-facing.

Record the choice as `$PROFILE` (lowercase: `minimal`, `lean`, or `full`).

#### Step i.3: Collect component values

Read the top-level directories from the repo root (excluding dot-directories,
`node_modules`, `dist`, `build`, `.git`):

```bash
ROOT="$(git rev-parse --show-toplevel)"
find "$ROOT" -maxdepth 1 -mindepth 1 -type d \
  ! -name '.*' ! -name node_modules ! -name dist ! -name build \
  -exec basename {} \; | sort
```

Suggest up to 7 values from this list. Present them with AskUserQuestion
(multiSelect: true) for the user to accept, edit, or replace.

Record as `$COMPONENT_VALUES` (newline-separated list).

#### Step i.4: Collect strategic anchor inputs

Ask three questions using AskUserQuestion:
1. "What is the time horizon for this period? (e.g., 'Through 2026-Q3')"
2. "What are the 1-3 top priorities in scope for this period? (one per line)"
3. "What is explicitly out of scope for this period? (one per line)"

Record as `$TIME_HORIZON`, `$IN_SCOPE`, `$OUT_OF_SCOPE`.

#### Step i.5: Write `roadmap.config.yaml`

Render `docs/templates/roadmap.config.yaml.template`:
- Replace `{{TIME_HORIZON}}` with `$TIME_HORIZON`
- Replace `{{TODAY_YYYY_MM_DD}}` with `$(date +%Y-%m-%d)`
- Replace `{{PROFILE}}` with `$PROFILE`
- Replace `{{COMPONENT_VALUES_YAML_LIST}}` with each component value on its
  own line with 2-space indent and `- ` prefix:
  ```
    - framework
    - workflows
  ```

Write to `$ROOT/roadmap.config.yaml`. If the file already exists, show the
diff and ask the user to confirm before overwriting.

#### Step i.6: Insert Strategic Anchor section into CLAUDE.md

Check if `CLAUDE.md` already contains a `## Strategic Anchor` heading. If
not, render `docs/templates/strategic-anchor.md.template`:
- Replace `{{TIME_HORIZON}}` with `$TIME_HORIZON`
- Replace `{{NEXT_REVIEW_YYYY_MM_DD}}` with the date 12 weeks from today
- Replace `{{IN_SCOPE_PLACEHOLDER}}` with the first in-scope bullet
- Replace `{{OUT_OF_SCOPE_PLACEHOLDER}}` with the first out-of-scope bullet

Append the rendered section to the end of `CLAUDE.md`.

If the section already exists, inform the user and skip (use `/roadmap revise`
to update it — Phase 6).

#### Step i.7: Copy issue templates

For each file in `docs/templates/issue-templates/`, copy to
`.github/ISSUE_TEMPLATE/<same-name>` only if the destination does not exist.
Create `.github/ISSUE_TEMPLATE/` if needed. Do not overwrite existing
templates without confirmation.

#### Step i.8: Install labels

```bash
bash "$ROOT/scripts/roadmap/install-labels.sh"
```

Show output to the user.

#### Step i.8b: Bootstrap pulse file

Bootstrap the pulse state file so nags have a baseline on day one:

```bash
ROOT="$(git rev-parse --show-toplevel)"
source "$ROOT/scripts/roadmap/lib.sh"
roadmap_pulse_bootstrap
```

If `.arboretum/roadmap-pulse.json` now exists, confirm:
> "Pulse state file ready at `.arboretum/roadmap-pulse.json` — nag machinery active."

If `.arboretum/roadmap-pulse.json` is not already in `.gitignore`, add it:

```bash
ROOT="$(git rev-parse --show-toplevel)"
grep -qFx '.arboretum/roadmap-pulse.json' "$ROOT/.gitignore" \
  || printf '\n.arboretum/roadmap-pulse.json\n' >> "$ROOT/.gitignore"
grep -qFx '.arboretum/roadmap-pulse.json.tmp' "$ROOT/.gitignore" \
  || printf '.arboretum/roadmap-pulse.json.tmp\n' >> "$ROOT/.gitignore"
```

#### Step i.9: Surface migration candidates (optional)

Run:
```bash
gh label list --limit 100 --json name --jq '.[].name' \
  | grep -E '^(priority|area|kind|p[0-9]):' || true
```

If any hits, print them and offer:
> "I found legacy labels that may map to horizon:*. The framework recommends
> a conversational migration rather than automated relabeling. Options:
> walk through them now, defer to later, or skip entirely."

Defer is the default. Never auto-relabel.

#### Step i.10: Done

Print:
> "Roadmap system installed (profile: $PROFILE). Try '/idea' to capture an
> idea or '/roadmap run' for the orientation view."

Suggest committing: `roadmap.config.yaml`, `.github/ISSUE_TEMPLATE/*.md`,
and `CLAUDE.md` if modified.
