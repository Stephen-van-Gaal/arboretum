---
name: build
owner: workflow-management
description: "Thin orchestrator for the build stage. Reads S2 input frontmatter from the design spec; dispatches Branch 2 (TDD assessment) and Branch 3 (implementation mode) by reading frontmatter values; writes pipeline-state via WS9's helper; exits with explicit success/escape-hatch status. Use as the build-stage entry point after /design exits."
allowed-tools:
  - Read
  - Edit
  - Bash
  - AskUserQuestion
  - Skill
layer: 0
---

# Build

Thin orchestrator for the build stage of the unified pipeline. Reads the design spec's S2 frontmatter, dispatches to the right superpowers skill, monitors for escape-hatch conditions, and exits with an explicit two-state contract that `/finish` reads to route the ship tail.

## When to use

- Invoked by the user (or by `/start`) after `/design` exits and the design spec is complete with all five S2 frontmatter fields populated.
- Standard invocation: `/build docs/superpowers/specs/<date>-<topic>-design.md`.

This skill does **not** do the build work itself — it dispatches to:

- `superpowers:test-driven-development` for Branch 2 (when any test tier applies).
- `superpowers:executing-plans` for Branch 3 (when `implementation-mode: executing-plans`).
- `superpowers:subagent-driven-development` for Branch 3 (when `implementation-mode: subagent-driven-development`).
- Nothing — proceed inline (when `implementation-mode: direct`).

## Procedure

### Step 1: Read & validate the S2 input frontmatter (strict gate per D5)

The positional argument is the design-spec path. Read its frontmatter via the helper:

```bash
DESIGN_SPEC="$1"
[ -f "$DESIGN_SPEC" ] || { echo "Design spec not found: $DESIGN_SPEC" >&2; exit 1; }

# Default the exit status to success — Step 5 flips it to escape-hatch
# only when the escape-hatch trigger fires. Initialising up front means
# Step 6's `$EXIT_STATUS != "escape-hatch"` predicate is always defined.
EXIT_STATUS="success"

FRONTMATTER="$(bash scripts/read-s2-frontmatter.sh "$DESIGN_SPEC")" || {
  echo "S2 contract drift — design spec frontmatter is missing required fields." >&2
  echo "Fix in /design, then re-invoke /build." >&2
  exit 1
}
```

The helper exits 2 with a named-field error if any of `related-issue:`, `test-tiers:`, `implementation-mode:`, `triage:`, `plan:` is missing or if `implementation-mode:` / `triage:` carries an invalid enum value. This is the **whole-schema strict gate from D5** — `/build` never self-heals; it refuses and surfaces the drift.

Extract the values you'll need downstream:

```bash
ISSUE=$(echo "$FRONTMATTER" | grep -E '^related-issue=' | cut -d= -f2)
MODE=$(echo "$FRONTMATTER"  | grep -E '^implementation-mode=' | cut -d= -f2)
PLAN=$(echo "$FRONTMATTER"  | grep -E '^plan=' | cut -d= -f2-)
TRIAGE=$(echo "$FRONTMATTER" | grep -E '^triage=' | cut -d= -f2)
```

### Step 2: Write the WS9 entry-state

Every state write goes through WS9's helper — never inline `gh` calls (D6).

```bash
bash scripts/log-stage.sh "$ISSUE" "/build" entered \
  "branch=$(git rev-parse --abbrev-ref HEAD)" \
  "design-spec=$DESIGN_SPEC" \
  "mode=$MODE" \
  "plan=$PLAN"
```

If the helper exits non-zero, surface the error and refuse to proceed — the entry-state write is the precondition for the journey-log invariant.

### Step 3: Branch 2 — TDD-tier dispatch

Read the per-tier `test-tiers.<tier>=` lines from `$FRONTMATTER`. **Any tier whose value is not exactly `n/a`** (case-insensitive prefix, since values like `n/a — no shared definitions` carry trailing reason text) is applicable.

```bash
APPLICABLE=$(echo "$FRONTMATTER" | grep -E '^test-tiers\.' | grep -viE '=n/a' | wc -l | tr -d ' ')
```

- **`APPLICABLE >= 1`** → dispatch to `superpowers:test-driven-development`:

  ```bash
  bash scripts/log-stage.sh "$ISSUE" "/build" dispatched \
    "target=superpowers:test-driven-development" \
    "reason=Branch 2 — $APPLICABLE applicable tier(s)"
  ```

  Then invoke `Skill superpowers:test-driven-development` and wait for it to complete.

- **`APPLICABLE == 0`** (all tiers N/A) → log the skip and proceed to Branch 3:

  ```bash
  bash scripts/log-stage.sh "$ISSUE" "/build" skipped \
    "branch=2" \
    "reason=all test tiers declared N/A"
  ```

### Step 4: Branch 3 — implementation-mode dispatch

Branch on `$MODE`:

- **`direct`** — no skill dispatch; the user (or this session) drives the build inline. Log:

  ```bash
  bash scripts/log-stage.sh "$ISSUE" "/build" skipped \
    "branch=3" \
    "reason=mode=direct (no skill — proceed inline)"
  ```

- **`executing-plans`** — dispatch to `superpowers:executing-plans` against `$PLAN`. Refuse if `$PLAN` is `null` (D3 requires a plan path in this mode):

  ```bash
  [ "$PLAN" != "null" ] || { echo "mode=executing-plans requires a plan path; got plan: null. Fix in /design." >&2; exit 1; }
  bash scripts/log-stage.sh "$ISSUE" "/build" dispatched \
    "target=superpowers:executing-plans" \
    "reason=Branch 3 — mode=executing-plans" \
    "plan=$PLAN"
  ```

  Then invoke `Skill superpowers:executing-plans` with the plan path.

- **`subagent-driven-development`** — dispatch to `superpowers:subagent-driven-development`:

  ```bash
  bash scripts/log-stage.sh "$ISSUE" "/build" dispatched \
    "target=superpowers:subagent-driven-development" \
    "reason=Branch 3 — mode=subagent-driven-development"
  ```

  Then invoke `Skill superpowers:subagent-driven-development`.

### Step 5: Escape-hatch monitoring (during build)

While the dispatched skill runs, watch for **mid-build reclassification triggers** — the conditions WS2 D2 names for the agent-target lane (the build surfaced a genuine design decision that needs `/design` re-entry rather than coding through it). If one fires, ask the user via `AskUserQuestion`:

> "A design decision surfaced mid-build (`<trigger-name>`): `<one-line description>`. This is what WS2 D2 names the escape hatch. Want to record it and return to `/design`, or stay in `/build` and code through it?"

If the user says "record + return":

```bash
bash scripts/write-escape-hatch.sh "$DESIGN_SPEC" "<trigger-name>" "/design"
EXIT_STATUS="escape-hatch"
```

Then jump to Step 6. The success-path conditions (plan checkboxes, test gate) do **not** apply on the escape-hatch path (D4).

If the user says "code through":

Continue the dispatched skill's work. Do not write an escape-hatch block.

### Step 6: Exit — success or escape-hatch (D4)

**Success-exit conditions** (all must hold for `exit-status=success`):

1. **Plan checkboxes resolved.** If `$PLAN` is a path, every checkbox is either checked or annotated `(skipped: <reason>)`. If `$PLAN` is `null`, this condition is N/A by construction.

   ```bash
   if [ "$PLAN" != "null" ]; then
     PARSED="$(bash scripts/parse-plan-checkboxes.sh "$PLAN")"
     OPEN=$(echo "$PARSED" | grep -oE 'open=[0-9]+' | cut -d= -f2)
     if [ "$OPEN" != "0" ]; then
       echo "Plan has $OPEN unresolved checkbox(es). Resolve them (check or annotate with (skipped: <reason>)) before exiting /build." >&2
       exit 1
     fi
   fi
   ```

2. **Test suite green and surface unchanged-or-grown.** Run the project's test suite (the arboretum convention is `bash scripts/ci-checks.sh`; other projects discover via `package.json`, `Makefile`, `pytest.ini`, etc.). If any tier in `test-tiers:` is declared N/A and the build cycle added, modified, or deleted any test file under that tier, surface the contract breach and refuse to exit — the N/A claim is invalidated by mutation.

3. **No escape-hatch fired** — confirmed by `$EXIT_STATUS != "escape-hatch"`.

When all three hold:

```bash
bash scripts/log-stage.sh "$ISSUE" "/build" exited \
  "exit-status=success" \
  "plan=resolved" \
  "tests=green" \
  "next=/finish"
```

**Escape-hatch exit:**

```bash
bash scripts/log-stage.sh "$ISSUE" "/build" exited \
  "exit-status=escape-hatch" \
  "trigger=<name>" \
  "next=/finish" \
  "redirect-target=/design"
```

`next:` always names the immediate S3 consumer (`/finish` — the single-consumer invariant from D2). `redirect-target:` (escape-hatch path only) names where `/finish` will route control after reading `exit-status:`.

### Step 7: Hand off to `/finish`

Both exit paths route through `/finish` — `/finish` is the seam consumer for S3; it reads `exit-status:` from the most recent `/build exited` log entry and routes accordingly (`success` → continue the ship tail; `escape-hatch` → return control to `/design`).

```bash
echo "Build complete (exit-status=$EXIT_STATUS). Invoke /finish to continue the ship tail."
```

**Do not auto-invoke `/finish`.** The user (or a calling skill) drives the next stage. Keeping the seam observable lets the user pause between `/build` and `/finish` for review, and matches the convention of every other stage seam in the pipeline.

## Important

- **Thin orchestrator (D2).** This skill never owns red/green/refactor, plan-checkbox execution, or subagent dispatch loops — it invokes the superpowers skills that own those. Never duplicate their logic here.
- **Strict S2 gate (D5).** Missing required frontmatter fields are *never* self-healed inside `/build`. The contract test (when WS4 ships) asserts this — a self-heal path would be invisible drift that defeats the gate.
- **WS9 helper is mandatory (D6).** Every state write goes through `scripts/log-stage.sh`. No inline `gh issue edit` or `gh issue comment` calls — a parallel implementation would drift from the WS9 paired-write semantics.
- **No `/handoff` here.** The handoff lives at the end of the ship tail (`/reflect` Q5 → `/handoff --completed`), per D8. `/build` exits to `/finish` and is done with the cycle.
- **One consumer on S3 (D2 step 6).** `/build` always hands to `/finish`, regardless of exit status. `/finish` is the only thing that reads `exit-status:` and routes. Keeping the seam single-target is what makes it template-able for WS3a.
