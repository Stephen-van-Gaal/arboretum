---
name: idea
description: "Capture a new idea as a GitHub issue with the minimum ceremony (work-later template, horizon:later label, project-defined component). Single-purpose capture — never blocks, never triages."
disable-model-invocation: false
allowed-tools:
  - Bash
  - AskUserQuestion
argument-hint: "[<title>]"
layer: 0
---

# Idea

The capture endpoint of the roadmap system. Creates a new GitHub issue using
the `work-later.md` template with `horizon:later` set, prompts for a
project-defined `component:*` label, and exits. No shaping, no readying — those
are `/roadmap shape` and `/roadmap ready` (Phase 3).

## When to use

- An idea surfaces mid-session and you don't want to lose it.
- A bug or improvement is reported but isn't this session's work.
- Anywhere you'd reach for `gh issue create` for a low-detail backlog item.

## Procedure

### Step 1: Preconditions

- `roadmap.config.yaml` exists at repo root (the project has been
  instantiated). If not, exit with: "Run `/roadmap instantiate` first."
- `gh` is installed and authenticated (reuse `roadmap_require_gh` from
  `scripts/roadmap/lib.sh`).

```bash
SCRIPT_DIR="$(git rev-parse --show-toplevel)/scripts/roadmap"
source "$SCRIPT_DIR/lib.sh"

config="$(roadmap_config_path)"
if [ -z "$config" ]; then
  echo "No roadmap.config.yaml found. Run '/roadmap instantiate' first."
  exit 1
fi

roadmap_require_gh || exit 1
```

### Step 2: Resolve title

If `$ARGUMENTS` is non-empty, use it as the issue title. Otherwise prompt
once using AskUserQuestion:

> "What's the idea? (one-line title)"

### Step 3: Resolve component

List values from `roadmap_config_list component_values` in the shell. If
only one value exists, auto-apply it. Otherwise present as options using
AskUserQuestion:

> "Which component does this touch?"

Use one option per component value.

### Step 4: Compose the body

Use the `work-later.md` template format:

```
<one paragraph problem or opportunity statement; that is all>

Spec: N/A
```

Use the title as the one-paragraph body if no elaboration is provided. Do
not prompt for elaboration unless the user volunteers it — the goal is
friction-free capture.

### Step 5: Create the issue

```bash
gh issue create \
  --title "<title>" \
  --label "horizon:later,component:<value>" \
  --body "$BODY"
```

Print the resulting issue URL.

### Step 6: Done

Exit. Do not run `/roadmap maintain`, do not triage, do not suggest a
horizon promotion.
