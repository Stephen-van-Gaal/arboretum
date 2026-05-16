#!/usr/bin/env bash
# owner: session-start-cycle-state
# SessionStart hook: produce a compact project state summary for Claude's context.
# Reads REGISTER.md, contracts.yaml, and definition files to surface:
# - Which specs exist and their statuses
# - Any stale version pins (contracts.yaml vs definition files)
# - What's next in the dependency resolution order
#
# Output goes to Claude's context as additionalContext.
# Must be fast — runs on every session start.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
REGISTER="$PROJECT_DIR/docs/REGISTER.md"
CONTRACTS="$PROJECT_DIR/contracts.yaml"
DEFS_DIR="$PROJECT_DIR/docs/definitions"
CONFIG="$PROJECT_DIR/.arboretum.yml"

# Detect current layer (default: 0)
LAYER=$(sed -n 's/^layer:[[:space:]]*\([0-9]\).*/\1/p' "$CONFIG" 2>/dev/null || true)
LAYER="${LAYER:-0}"

output=""

# ── Check if governed documents exist ────────────────────────────────

missing=()
[ ! -f "$PROJECT_DIR/docs/ARCHITECTURE.md" ] && missing+=("ARCHITECTURE.md")
[ ! -f "$REGISTER" ] && missing+=("REGISTER.md")
[ ! -f "$CONTRACTS" ] && missing+=("contracts.yaml")
[ ! -d "$DEFS_DIR" ] && missing+=("docs/definitions/")

if [ ${#missing[@]} -gt 0 ]; then
  output+="[Spec Workflow] Missing governed documents: ${missing[*]}."
  output+=$'\n'"  → Why: The document chain must exist top-down before specs can be implemented."
  output+=$'\n'"    Create them in order: ARCHITECTURE.md → definitions/ → specs → REGISTER.md → contracts.yaml. See workflows/README.md."
fi

# ── Session handoff (next-up GitHub issue) ───────────────────────────
# Surface the issue tagged with the `next-up` label on GitHub. The
# cache at .arboretum/next-cache.json is refreshed by
# scripts/refresh-next-cache.sh (synchronously on first session,
# in the background when stale). 1-hour TTL.
#
# Deliberately not plugin-aware — the cache is a project artefact, never
# plugin-shipped. Rooting at $PROJECT_DIR is correct here (#145).
#
# See issue #155 and docs/superpowers/specs/2026-04-28-session-handoff-design.md.

NEXT_CACHE="$PROJECT_DIR/.arboretum/next-cache.json"
NEXT_REFRESH="$PROJECT_DIR/scripts/refresh-next-cache.sh"
NEXT_TTL_SECONDS=3600

if [ -f "$NEXT_REFRESH" ]; then
  # First-session synchronous refresh if no cache exists.
  if [ ! -f "$NEXT_CACHE" ]; then
    bash "$NEXT_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true
  else
    # Background refresh if cache is older than TTL.
    cache_age=$(( $(date +%s) - $(stat -c %Y "$NEXT_CACHE" 2>/dev/null \
                                  || stat -f %m "$NEXT_CACHE" 2>/dev/null \
                                  || echo 0) ))
    if [ "$cache_age" -gt "$NEXT_TTL_SECONDS" ]; then
      ( bash "$NEXT_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true ) &
      disown 2>/dev/null || true
    fi
  fi

  if [ -f "$NEXT_CACHE" ]; then
    # Extract fields with python3 (preferred) or sed fallback.
    if command -v python3 >/dev/null 2>&1; then
      next_block=$(python3 - "$NEXT_CACHE" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        cache = json.load(f)
except Exception:
    sys.exit(0)

# Defence in depth: the cache writer already scrubs ASCII control
# characters from author-controlled strings (issue titles, body
# lines), but if the cache was hand-edited or written by an older
# version of the script, scrub again here so the boot banner
# can never render terminal-escape sequences from remote input.
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s

err = cache.get("error")
no_remote = cache.get("no_gh_remote", False)
issue = cache.get("issue")

lines = []
if err == "gh-unavailable":
    lines.append("[Next-up] ERROR: gh CLI not available — cannot read next-up state.")
    lines.append("  → Install: https://cli.github.com/")
    lines.append("  → Authenticate: gh auth login")
    lines.append("  → Then refresh: bash scripts/refresh-next-cache.sh")
elif no_remote:
    pass  # silent skip; not a GH project
elif err:
    lines.append(f"[Next-up] (cache error: {scrub(err)}; see .arboretum/next-cache.err)")
elif issue is None:
    lines.append("[Next-up] (no issue queued — run /handoff to set one)")
else:
    n = issue.get("number")
    title = scrub(issue.get("title", ""))
    lines.append(f"[Next-up] #{n}: {title}")
    if issue.get("body_empty"):
        lines.append("  (body empty — readiness check would fail)")
    for ln in issue.get("body_first_lines", [])[:5]:
        lines.append(f"  {scrub(ln)}")
    url = issue.get("url", "")
    if url:
        lines.append(f"  → {scrub(url)}")
print("\n".join(lines))
PY
)
    else
      # Minimal sed fallback. Handles the three states bare-bones.
      next_block=""
      if grep -q '"error":[[:space:]]*"gh-unavailable"' "$NEXT_CACHE"; then
        next_block="[Next-up] ERROR: gh CLI not available — cannot read next-up state."$'\n'"  → Install: https://cli.github.com/"$'\n'"  → Authenticate: gh auth login"$'\n'"  → Then refresh: bash scripts/refresh-next-cache.sh"
      elif grep -q '"no_gh_remote":[[:space:]]*true' "$NEXT_CACHE"; then
        next_block=""
      elif grep -q '"issue":[[:space:]]*null' "$NEXT_CACHE"; then
        next_block="[Next-up] (no issue queued — run /handoff to set one)"
      else
        n=$(sed -n 's/.*"number":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$NEXT_CACHE" | head -1)
        t=$(sed -n 's/.*"title":[[:space:]]*"\([^"]*\)".*/\1/p' "$NEXT_CACHE" | head -1)
        next_block="[Next-up] #${n}: ${t}"
      fi
    fi

    if [ -n "$next_block" ]; then
      output+=$'\n'"$next_block"
    fi
  fi
fi

# ── Arboretum update check ───────────────────────────────────────────
# Surface a one-line notice if the installed plugin is behind the latest
# published release. Cache at .arboretum/update-cache.json; refreshed by
# scripts/refresh-update-cache.sh with a 24-hour TTL (background after
# first run, same pattern as next-cache). Silent on error or missing gh.

UPDATE_CACHE="$PROJECT_DIR/.arboretum/update-cache.json"
UPDATE_REFRESH="$PROJECT_DIR/scripts/refresh-update-cache.sh"
UPDATE_TTL_SECONDS=86400

if [ -f "$UPDATE_REFRESH" ]; then
  if [ ! -f "$UPDATE_CACHE" ]; then
    bash "$UPDATE_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true
  else
    cache_age=$(( $(date +%s) - $(stat -c %Y "$UPDATE_CACHE" 2>/dev/null \
                                  || stat -f %m "$UPDATE_CACHE" 2>/dev/null \
                                  || echo 0) ))
    if [ "$cache_age" -gt "$UPDATE_TTL_SECONDS" ]; then
      ( bash "$UPDATE_REFRESH" "$PROJECT_DIR" >/dev/null 2>&1 || true ) &
      disown 2>/dev/null || true
    fi
  fi

  update_block=""
  if [ -f "$UPDATE_CACHE" ]; then
    if command -v python3 >/dev/null 2>&1; then
      update_block=$(python3 - "$UPDATE_CACHE" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        cache = json.load(f)
except Exception:
    sys.exit(0)
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
if cache.get("update_available"):
    iv = _CTRL.sub("", cache.get("installed_version") or "?")
    lv = _CTRL.sub("", cache.get("latest_version") or "?")
    print(f"[Arboretum] Update available: v{iv} → v{lv} — run /plugin update arboretum to upgrade.")
PY
) || true
    else
      if grep -q '"update_available"[[:space:]]*:[[:space:]]*true' "$UPDATE_CACHE" 2>/dev/null; then
        _iv=$(sed -n 's/.*"installed_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPDATE_CACHE" | head -1)
        _lv=$(sed -n 's/.*"latest_version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$UPDATE_CACHE" | head -1)
        update_block="[Arboretum] Update available: v${_iv:-?} → v${_lv:-?} — run /plugin update arboretum to upgrade."
      fi
    fi
  fi
  if [ -n "${update_block:-}" ]; then
    output+=$'\n'"$update_block"
  fi
fi

# ── Build-cycle state ────────────────────────────────────────────────
# When a build cycle is in flight on the current branch, surface the
# observable state so the human and LLM see "where am I" without
# re-deriving it. Detection is shell-only — no gh calls. Per
# docs/specs/session-start-cycle-state.spec.md (issue #167).
#
# Forward-compat: CYCLE_MODE will switch from "spec" to "workflow"
# when OQ5 step 1 lands (#164). Detection logic is structured around
# the CYCLE_MODE variable so the directories searched can change
# without rewriting the matching logic.

CYCLE_MODE="${ARBORETUM_CYCLE_MODE:-spec}"
CYCLE_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ -n "$CYCLE_BRANCH" ] && [ "$CYCLE_BRANCH" != "main" ] && [ "$CYCLE_BRANCH" != "master" ]; then
  # Strip prefix to get topic substring (D2)
  CYCLE_TOPIC="${CYCLE_BRANCH#feat/}"
  CYCLE_TOPIC="${CYCLE_TOPIC#fix/}"
  CYCLE_TOPIC="${CYCLE_TOPIC#docs/}"
  CYCLE_TOPIC="${CYCLE_TOPIC#chore/}"

  # Search dirs depend on mode (D6 forward-compat). Use an array for
  # PLAN_DIRS so paths containing spaces survive iteration.
  if [ "$CYCLE_MODE" = "spec" ]; then
    DESIGN_DIR="$PROJECT_DIR/docs/superpowers/specs"
    PLAN_DIRS=("$PROJECT_DIR/docs/plans" "$PROJECT_DIR/docs/superpowers/plans")
  else
    # Future: workflows-mode dirs
    DESIGN_DIR="$PROJECT_DIR/docs/superpowers/specs"
    PLAN_DIRS=("$PROJECT_DIR/docs/plans" "$PROJECT_DIR/docs/superpowers/plans")
  fi

  # Find matching design spec by branch-name substring match (D2)
  CYCLE_SPEC=""
  if [ -d "$DESIGN_DIR" ]; then
    CYCLE_SPEC=$(ls -t "$DESIGN_DIR"/*"$CYCLE_TOPIC"*.md 2>/dev/null | head -1 || true)
  fi

  # Find matching plan
  CYCLE_PLAN=""
  for plan_dir in "${PLAN_DIRS[@]}"; do
    [ -d "$plan_dir" ] || continue
    found=$(ls -t "$plan_dir"/*"$CYCLE_TOPIC"*.md 2>/dev/null | head -1 || true)
    if [ -n "$found" ]; then
      CYCLE_PLAN="$found"
      break
    fi
  done

  # Trigger condition (D1): emit section only if either present
  if [ -n "$CYCLE_SPEC" ] || [ -n "$CYCLE_PLAN" ]; then
    cycle_block="[Build cycle]   branch: $CYCLE_BRANCH"

    if [ -n "$CYCLE_SPEC" ]; then
      cycle_block+=$'\n'"                spec:   $(basename "$CYCLE_SPEC")"
    fi

    if [ -n "$CYCLE_PLAN" ]; then
      # Plan-checkbox parsing (D3 input). grep -c exits 1 on no matches but
      # still prints "0"; capture the value via assignment, fall back via
      # the failure branch to avoid pipefail double-echo.
      checked=$(grep -c '^[[:space:]]*-[[:space:]]*\[x\]' "$CYCLE_PLAN" 2>/dev/null) || checked=0
      unchecked=$(grep -c '^[[:space:]]*-[[:space:]]*\[ \]' "$CYCLE_PLAN" 2>/dev/null) || unchecked=0
      total=$((checked + unchecked))

      if [ "$total" -gt 0 ]; then
        cycle_block+=$'\n'"                plan:   $(basename "$CYCLE_PLAN") (${checked}/${total} tasks complete)"
      else
        cycle_block+=$'\n'"                plan:   $(basename "$CYCLE_PLAN")"
      fi

      # Phase inference (D3)
      remaining=$((total - checked))
      if [ "$total" -eq 0 ]; then
        phase="ready to start implementation"
      elif [ "$checked" -eq 0 ]; then
        phase="ready to start implementation"
      elif [ "$checked" -lt "$total" ]; then
        phase="mid-implementation, ${remaining} tasks remain"
      else
        phase="ready for /finish"
      fi
    elif [ -n "$CYCLE_SPEC" ]; then
      # Design spec but no plan
      phase="pre-implementation, settle plan"
    else
      phase=""
    fi

    if [ -n "$phase" ]; then
      cycle_block+=$'\n'"                phase:  $phase"
    fi
    cycle_block+=$'\n'"                next:   run /start to continue"

    output+=$'\n'"$cycle_block"
  fi
fi

# ── Parse register for spec statuses ─────────────────────────────────

if [ -f "$REGISTER" ]; then
  # Extract spec index table rows (lines matching "| something.spec.md |")
  spec_lines=$(grep -E '^\|.*\.spec\.md' "$REGISTER" 2>/dev/null || true)

  if [ -n "$spec_lines" ]; then
    draft_count=0
    active_count=0
    stale_count=0
    stale_specs=""
    draft_specs=""

    while IFS='|' read -r _ spec status _ _; do
      spec=$(echo "$spec" | xargs)
      status=$(echo "$status" | xargs)
      case "$status" in
        draft)
          ((draft_count += 1)) || true
          draft_specs+="$spec, "
          ;;
        active) ((active_count += 1)) || true ;;
        stale)
          ((stale_count += 1)) || true
          stale_specs+="$spec, "
          ;;
      esac
    done <<< "$spec_lines"

    output+=$'\n'"[Spec Status] draft:$draft_count active:$active_count stale:$stale_count"

    if [ -n "$stale_specs" ]; then
      output+=$'\n'"[Stale] ${stale_specs%, }"
      output+=$'\n'"  → $stale_count spec(s) stale — run /consolidate to reconcile or /health-check for details."
    fi
    if [ -n "$draft_specs" ]; then
      output+=$'\n'"[Draft] ${draft_specs%, }"
    fi
  fi
fi

# ── Check register staleness ─────────────────────────────────────────

if [ -f "$REGISTER" ] && [ -d "$PROJECT_DIR/docs/specs" ]; then
  register_stale=false
  for spec_file in "$PROJECT_DIR"/docs/specs/*.spec.md; do
    [ -f "$spec_file" ] || continue
    if [ "$spec_file" -nt "$REGISTER" ]; then
      register_stale=true
      break
    fi
  done
  if [ "$register_stale" = true ]; then
    output+=$'\n'"[Register] REGISTER.md may be stale — spec files are newer than the register."
    output+=$'\n'"  → Why: Stale register data causes incorrect staleness checks and ownership lookups."
    output+=$'\n'"    Run scripts/generate-register.sh to resync."
  fi
fi

# ── Check version pin staleness ──────────────────────────────────────

if [ -f "$CONTRACTS" ] && [ -d "$DEFS_DIR" ]; then
  stale=""

  # Extract definition paths and pinned versions from contracts.yaml
  # Format: definitions/foo.md: v1
  pins=$(grep -E '^\s+definitions/' "$CONTRACTS" 2>/dev/null | sed 's/#.*//' || true)

  while IFS=: read -r def_path pinned_version; do
    [ -z "$def_path" ] && continue
    def_path=$(echo "$def_path" | xargs)
    pinned_version=$(echo "$pinned_version" | xargs)
    [ -z "$pinned_version" ] && continue

    def_file="$PROJECT_DIR/docs/$def_path"
    if [ -f "$def_file" ]; then
      # Extract current version from definition file's ## Version section
      current_version=$(grep -A1 '^## Version' "$def_file" 2>/dev/null \
        | grep -oE 'v[0-9]+' | head -1 || true)

      if [ -n "$current_version" ] && [ "$current_version" != "$pinned_version" ]; then
        stale+="  $def_path: pinned=$pinned_version current=$current_version"$'\n'
      fi
    fi
  done <<< "$pins"

  if [ -n "$stale" ]; then
    output+=$'\n'"[Stale Version Pins] Definition versions have drifted from contracts.yaml:"$'\n'"$stale"
    output+="  → Why: Implementing against stale pins risks silent drift between code and contracts."
    output+=$'\n'"    Run /health-check or scripts/sync-contracts.sh to reconcile."
  fi
fi

# ── Layer upgrade suggestions ────────────────────────────────────────

if [ "$LAYER" -lt 1 ]; then
  # Count specs to suggest Layer 1
  spec_count=0
  if [ -d "$PROJECT_DIR/docs/specs" ]; then
    spec_count=$(find "$PROJECT_DIR/docs/specs" -name "*.spec.md" 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ "$spec_count" -ge 3 ]; then
    output+=$'\n'"[Layer Suggestion] $spec_count specs detected at Layer 0."
    output+=$'\n'"  → Why: Layer 1 adds ownership context on every edit and auto-register updates — useful once you have 3+ specs."
    output+=$'\n'"    Set layer: 1 in .arboretum.yml to activate."
  fi
fi

if [ "$LAYER" -lt 2 ]; then
  # Check for multi-author or CI to suggest Layer 2
  suggest_l2=false
  if [ -d "$PROJECT_DIR/.github/workflows" ]; then
    ci_count=$(find "$PROJECT_DIR/.github/workflows" -name "*.yml" -o -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
    [ "$ci_count" -gt 0 ] && suggest_l2=true
  fi
  if [ "$suggest_l2" = false ]; then
    author_count=$(git -C "$PROJECT_DIR" log --format='%ae' 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "$author_count" -ge 2 ] && suggest_l2=true
  fi
  if [ "$suggest_l2" = true ]; then
    output+=$'\n'"[Layer Suggestion] CI workflows or multiple git authors detected at Layer $LAYER."
    output+=$'\n'"  → Why: Layer 2 adds version-pin enforcement, branch protection, and post-commit drift detection — valuable for multi-author projects."
    output+=$'\n'"    Set layer: 2 in .arboretum.yml to activate."
  fi
fi

# ── Active skills by layer ───────────────────────────────────────────

SKILLS_DIR="$PROJECT_DIR/.claude/skills"
if [ -d "$SKILLS_DIR" ]; then
  # Build skill lists per layer
  layer0_skills=""
  layer1_skills=""
  layer2_skills=""

  for skill_dir in "$SKILLS_DIR"/*/; do
    [ ! -d "$skill_dir" ] && continue
    skill_file="$skill_dir/SKILL.md"
    [ ! -f "$skill_file" ] && continue
    skill_name="$(basename "$skill_dir")"

    # Extract layer from YAML frontmatter (between --- markers)
    skill_layer=$(sed -n '/^---$/,/^---$/{ s/^layer:[[:space:]]*\([0-9]\).*/\1/p; }' "$skill_file")
    [ -z "$skill_layer" ] && continue

    case "$skill_layer" in
      0) layer0_skills+="/$skill_name, " ;;
      1) layer1_skills+="/$skill_name, " ;;
      2) layer2_skills+="/$skill_name, " ;;
    esac
  done

  active_output=""
  if [ -n "$layer0_skills" ] && [ "$LAYER" -ge 0 ]; then
    active_output+="Layer 0: ${layer0_skills%, }"
  fi
  if [ -n "$layer1_skills" ] && [ "$LAYER" -ge 1 ]; then
    active_output+="; Layer 1: ${layer1_skills%, }"
  fi
  if [ -n "$layer2_skills" ] && [ "$LAYER" -ge 2 ]; then
    active_output+="; Layer 2: ${layer2_skills%, }"
  fi

  if [ -n "$active_output" ]; then
    output+=$'\n'"[Active Skills] $active_output"
  fi
fi

# ── Roadmap orientation (issue #152) ─────────────────────────────────
# render-run.sh exits silently when roadmap.config.yaml is absent, so this
# is a no-op on projects that haven't instantiated the roadmap system.
# Nag machinery runs inside render-run.sh before the gh guard.

ROADMAP_RENDER="$PROJECT_DIR/scripts/roadmap/render-run.sh"
if [ -x "$ROADMAP_RENDER" ]; then
  orientation_text="$(bash "$ROADMAP_RENDER" --condensed 2>/dev/null || true)"
  if [ -n "$orientation_text" ]; then
    [ -n "$output" ] && output+=$'\n'
    output+="$orientation_text"
  fi
fi

# ── Output ───────────────────────────────────────────────────────────

if [ -n "$output" ]; then
  echo "$output"
fi

exit 0
