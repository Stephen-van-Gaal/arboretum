---
name: start
owner: workflow-unification
description: Entry point for new work — ensures a GitHub issue exists, determines whether the change is planned or exploratory, and routes to the appropriate workflow path. Auto-invoked by CLAUDE.md when a change request is detected.
disable-model-invocation: false
allowed-tools: Bash, Read, Grep, Glob
layer: 0
---

# Start

Entry point for all change requests. Establishes context and routes the user into the correct workflow path.

## When to invoke

Claude should invoke this skill (or follow its logic) whenever the user:
- Asks to add a feature, fix a bug, refactor code, or make any change
- References a GitHub issue they want to work on
- Starts a session with an intent to modify the project

This skill is read-only under `v1` (gather context, recommend next steps). Under `v2` (`pipeline.workflow: v2`), the agent-target lane in Step 4-v2 writes a task brief via `scripts/write-agent-brief.sh`; the v1 routing path remains read-only.

## Procedure

### Stage logging

At entry, if `$ISSUE` is set, log the stage:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /start entered
fi
```

At exit (when the procedure completes), log:

```bash
if [ -n "${ISSUE:-}" ]; then
  bash scripts/log-stage.sh "$ISSUE" /start exited
fi
```


### 0. Read the pipeline.workflow flag

Before any routing, read the active pipeline version:

```bash
PIPELINE=$(bash scripts/read-pipeline-flag.sh)
```

- **`v1` (default)** — continue with Steps 1–6 below (Path A/B routing). Skip Section 4-v2.
- **`v2`** — continue with Steps 1–3 (issue, survey, branch state) as usual, then jump to **Step 4-v2: Agent-target triage** instead of Step 4.

### 1. Identify the change request

From the user's message, extract:
- **What** they want to change (feature, bug fix, refactor, docs, etc.)
- **Why** (if stated)
- **Any referenced issue number** (e.g., "fix #12", "working on issue 42")

### 2. Check for a GitHub issue

If the user referenced an issue number:
```bash
gh issue view <number> --json title,state,body
```

If no issue was referenced, check if there's an open issue that matches:
```bash
gh issue list --state open --limit 20
```

Present what you found:
- If a matching issue exists: "Found issue #N: <title>. Working from this?"
- If no issue exists: "No GitHub issue found for this work. Want me to create one, or proceed without?"

Do not block on issue creation — suggest it but proceed if the user declines.

### 2b. Survey existing specs (v1 only — skip under v2)

Under v2, SURVEY is owned by `/design` Section v2.1 (for everything-else) or is not needed (for agent-target, which is spec-exempt or fits-existing-spec by definition). Skip this step entirely when `PIPELINE=v2`.

Read existing specs in `docs/specs/` and `docs/ARCHITECTURE.md` to understand where this change fits in the existing project structure. Identify which specs are likely touched by this work.

### 3. Check current branch and project state

```bash
git rev-parse --abbrev-ref HEAD
git status --short
```

Report:
- Current branch (are they already on a feature branch?)
- Any uncommitted work
- Whether they need to create a feature branch

### 4. Determine the workflow path — A or B

Recommend Path A (spec-first) or Path B (design-first):

**Path A (spec-first)** — recommend when:
- The user can describe Behaviour upfront ("add X that does Y when Z")
- Bug with known root cause ("the auth handler doesn't validate expiry")
- Refactor with clear scope (existing spec describes the behaviour to preserve)

**Path B (design-first)** — recommend when:
- The right Behaviour wording will only crystallize after seeing code
- Open-ended improvement ("can we improve performance? unclear how yet")
- Significant new architecture worth a brainstorm before any code

If unsure, default to Path A — it's cheaper to switch from A to B (drop the spec, brainstorm fresh) than from B to A (you've already coded against unsettled design).

Present recommendation:
> "This sounds like **Path A (spec-first)**. I'd recommend:
>  1. Run `/design` to settle the spec
>  2. `/consolidate` to create the governed spec at `docs/specs/`
>  3. Plan and build
>  4. `/finish` to PR
>
> Or do you want to take **Path B (design-first)** — brainstorm and build first, governed spec at the end?"

For genuinely exploratory questions (no idea what to build yet), the **explore** workflow with a *spike* may be more appropriate than Path B — see `workflows/explore.md ## Spike vs. Path B`.

### 4-v2. Agent-target triage (when `PIPELINE=v2`)

Skip this section when `PIPELINE=v1`. When `PIPELINE=v2`, replace Step 4 with this triage.

The unified workflow's only structural fork: classify the request as **agent-target** or **everything-else**.

**Agent-target requires all four criteria to hold unambiguously:**

1. **Decision-free** — exactly one sensible implementation; no choice between approaches.
2. **Bounded** — one owner/spec, a handful of files, no architecture or cross-spec impact.
3. **Gate-cheap** — spec-exempt (patch-fix / implementation-detail refactor / supplementary test) OR fits within an existing `active` governed spec's behaviour. No spec change required.
4. **Low blast radius** — reversible, cheap to verify.

**Precedence:** if any criterion is uncertain or borderline, classify as **everything-else**. The triage never rounds up — the escape hatch in `/build` recovers anything that slips through.

**When classified as agent-target:**

1. Author the crisp task statement (one or two sentences naming the change and the file(s) it touches).
2. Write the task brief. **Use a quoted heredoc** so the task statement is written verbatim even if it contains `$`, backticks, or other shell metacharacters (the original user request is untrusted input):

   ```bash
   bash scripts/write-agent-brief.sh <issue> <<'EOF'
   <crisp task statement>
   EOF
   ```

   Do not use `echo "..."` — a double-quoted echo argument would evaluate `$(...)` and backticks in the task statement before piping, opening a shell-injection path from user-controlled issue text.

3. Hand off to `/build` with the brief:

   ```
   /build .arboretum/agent-briefs/<issue>.md
   ```

   No `/design`, no plan — the brief is the implementation brief (WS2 D2).

**When classified as everything-else:**

Hand off to `/design` with the issue number AND the user's original request:

```
/design Issue #<N>: <user's original change request>
```

The `Issue #<N>:` prefix gives `/design` v2 the value it needs for the `related-issue` field in the design spec's S2 frontmatter (`/build`'s gate requires it). If no issue exists yet, hand off as `/design Issue #pending: <request>` and `/design` will prompt to create one before writing the spec.

`/design` (under v2) runs SURVEY + Branch 1 dispatch + writes the design spec + folds in planning + exits to `/build`. See `/design` Section v2 for the Branch 1 mode vocabulary. Steps 1 (issue) and 3 (branch state) above are already complete — pass them along, don't re-run. Step 2b (SURVEY) is owned by `/design` v2.1; `/start` skips it under v2 (see Step 2b's v2-skip note).

### 5. Verify the workflow's required plugins

Each workflow declares its external-plugin dependencies in its frontmatter `requires:` field. Before routing, read the chosen workflow's file and verify each required plugin is installed.

```bash
# Locate the workflow file (covers arbo-dev, retrofitted, and plugin-installed layouts)
WORKFLOW_NAME="<feature|bug-fix|explore|refactor|documentation|publish|new-project|retrofit>"
WORKFLOW_FILE=""
for path in \
    "workflows/${WORKFLOW_NAME}.md" \
    "docs/workflows/${WORKFLOW_NAME}.md" \
    "${CLAUDE_PLUGIN_ROOT:-/dev/null}/workflows/${WORKFLOW_NAME}.md"; do
  if [ -f "$path" ]; then WORKFLOW_FILE="$path"; break; fi
done

if [ -z "$WORKFLOW_FILE" ]; then
  echo "Workflow file for '$WORKFLOW_NAME' not found — proceeding without dependency check."
else
  # Extract requires: list (simple YAML; entries are "  - <name>" under "requires:")
  REQUIRES=$(awk '
    /^---$/ { if (++hr == 1) in_fm=1; else exit; next }
    in_fm && /^requires:/ { cap=1; next }
    in_fm && cap && /^[[:space:]]+-[[:space:]]+/ { sub(/^[[:space:]]+-[[:space:]]+/, ""); print; next }
    in_fm && cap && /^[a-zA-Z]/ { cap=0 }
  ' "$WORKFLOW_FILE")

  # Content-based plugin discovery: scan all installed plugin manifests
  # and match against the declared `name` field. Same approach as
  # `/arboretum:init` — robust to marketplaces that install plugins under
  # different cache namespaces (the plugin folder name need not match its
  # declared name).
  MISSING=""
  for plugin in $REQUIRES; do
    found=""
    for manifest in $(find ~/.claude/plugins/cache -type f -path '*/.claude-plugin/plugin.json' 2>/dev/null); do
      if grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"$plugin\"" "$manifest"; then
        found=1
        break
      fi
    done
    if [ -z "$found" ]; then
      MISSING="$MISSING $plugin"
    fi
  done

  if [ -n "$MISSING" ]; then
    echo "MISSING:$MISSING"
  fi
fi
```

If any plugin is missing, **halt and tell the user**:

> "The `<workflow>` workflow requires the `<plugin>` plugin, which is not installed. Install it with:
>
>     /plugin install <plugin>
>
> from the official Claude marketplace, then re-run `/start`."

For each missing plugin, surface what it provides so the user understands the cost of installing vs. proceeding without:

- `superpowers` — brainstorming, writing-plans, test-driven-development, executing-plans, systematic-debugging, requesting-code-review, verification-before-completion. Without it, arboretum's `/design` will conduct the design conversation directly but won't produce as structured a design spec; planning and TDD will fall back to ad-hoc execution.

Surface the install guidance and ask the user how to proceed. Recommend installing the plugin and re-running `/start` (the spec treats `requires:` as a hard requirement, not graceful fallback). If the user explicitly chooses to proceed without it, warn clearly that workflow guidance will degrade and continue — `/start` is guidance to the human, and the human stays in control of routing decisions.

### 6. Route to next step

Based on the user's choice:

- **Path A:** Invoke `/design` to brainstorm and produce the governed spec, then transition to planning and build.
- **Path B:** Invoke `/design` to brainstorm and produce a *design spec* in `docs/superpowers/specs/`, then transition to planning and build; `/consolidate` runs at the end to produce the governed spec from built state.

## Workflow transitions

If the user's situation changes mid-workflow, re-evaluate and route to the appropriate workflow. Common transitions:

- **feature → explore:** Unknowns surface during survey/design — pause feature, enter explore workflow
- **bug-fix → feature:** Classification reveals a spec gap, not just wrong code — the fix becomes a feature
- **refactor → bug-fix:** Restructuring surfaces a bug — pause refactor, capture the bug separately
- **explore → feature:** Spike produces enough understanding — `/consolidate` findings and enter feature at design step
- **any → documentation:** Docs-only issues noted during any workflow — handle in a separate pass after current workflow

See `workflows/README.md ## Workflow transitions` for the full transition table.

## Important

- This skill is **guidance, not a gate**. If the user wants to skip straight to coding, let them — but note what governance steps they're skipping.
- Do not create files, modify code, or make commits. This skill only gathers context and recommends.
- If the project is at Layer 0 with no governed documents yet, mention that `/init-project` can set up the infrastructure, but don't block on it.
- If the project has an existing codebase without governance, suggest the **retrofit** workflow instead.
- Keep the output concise. The user wants to start working, not read a manual.

$ARGUMENTS
