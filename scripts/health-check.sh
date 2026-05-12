#!/usr/bin/env bash
# owner: health-check
# health-check.sh — Detect drift across the spec-driven workflow
#
# Requires bash 4+ (uses process substitution, arrays, [[ ]]).
#
# Usage:
#   ./scripts/health-check.sh [project-dir]
#
# Runs nine checks:
#   1. Governed documents exist (ARCHITECTURE, REGISTER, contracts, etc.)
#   2. Register vs. disk (do owned files exist?)
#   3. Unowned source files
#   4. contracts.yaml vs. spec Requires tables (are pins in sync?)
#   5. contracts.yaml vs. definition versions (are pins current?)
#   6. Spec status consistency (status enum is one of draft/active/stale)
#   7. Spec drift detection (auto-flips active → stale when owned files
#      are modified after the spec's last commit). This is the only
#      mutation; status is structurally bounded so writing it is safe.
#   8. Plan files missing Tests section (advisory)
#   9. Strategic Anchor validity (section present, time horizon future,
#      in/out scope non-empty, cadence not overdue). Silent pass when
#      roadmap.config.yaml is absent.
#
# Produces a drift report. Mutates only spec status (Check 7).
# Exit code: 0 if healthy, 1 if drift detected.

set -euo pipefail

# Guard: fail if sourced or invoked with a non-bash shell (e.g. sh, dash)
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

PROJECT_DIR="${1:-$(pwd)}"
REGISTER="$PROJECT_DIR/docs/REGISTER.md"
CONTRACTS="$PROJECT_DIR/contracts.yaml"
DEFS_DIR="$PROJECT_DIR/docs/definitions"
SPECS_DIR="$PROJECT_DIR/docs/specs"

drift_found=false
check_count=0
issue_count=0

# ── Helpers ──────────────────────────────────────────────────────────

header() {
  echo ""
  echo "━━━ $1 ━━━"
  ((check_count++)) || true
}

ok() {
  echo "  ✓ $1"
}

warn() {
  echo "  ✗ $1"
  drift_found=true
  ((issue_count++)) || true
}

info() {
  echo "  · $1"
}

# ── Check 0: Missing governed documents ──────────────────────────────

header "Check 1: Governed documents exist"

[ -f "$PROJECT_DIR/workflows/README.md" ] && ok "workflows/README.md" || warn "workflows/README.md missing"
[ -f "$PROJECT_DIR/CLAUDE.md" ] && ok "CLAUDE.md" || warn "CLAUDE.md missing"
[ -f "$PROJECT_DIR/docs/ARCHITECTURE.md" ] && ok "docs/ARCHITECTURE.md" || warn "docs/ARCHITECTURE.md missing"
[ -f "$REGISTER" ] && ok "docs/REGISTER.md" || warn "docs/REGISTER.md missing"
[ -f "$CONTRACTS" ] && ok "contracts.yaml" || warn "contracts.yaml missing"
[ -d "$DEFS_DIR" ] && ok "docs/definitions/" || warn "docs/definitions/ missing"
[ -d "$SPECS_DIR" ] && ok "docs/specs/" || warn "docs/specs/ missing"

# If register doesn't exist, we can't run most checks
if [ ! -f "$REGISTER" ]; then
  echo ""
  echo "Register not found — skipping checks 2-5."
  echo ""
  echo "Summary: $issue_count issues found across $check_count checks."
  exit 1
fi

# ── Check 2/3: Register schema detection ─────────────────────────────
#
# Detect REGISTER.md's Spec Index schema by inspecting the header row.
# Current schema (emitted by generate-register.sh): | Spec | Status | Owner | Owns |
# Legacy schema (older arboretum bootstraps):       | Spec | Status | Owns | Depends On |
# Parsing the wrong schema produces silent garbage (Owner values read as
# paths, etc.). When the schema isn't current, skip Check 2/3 with a
# clear instruction to regenerate rather than emit false-positive findings.

register_header=$(grep -E '^\| Spec \| Status \|' "$REGISTER" 2>/dev/null | head -1 || true)
register_schema_compatible=false
register_schema_message=""

if [[ -z "$register_header" ]]; then
  register_schema_message="REGISTER.md has no recognized Spec Index header"
elif [[ "$register_header" == *"Owner"* ]]; then
  register_schema_compatible=true
else
  register_schema_message="REGISTER.md uses a legacy schema (no Owner column). Run 'bash scripts/generate-register.sh' to regenerate to the current schema (Spec | Status | Owner | Owns)"
fi

# ── Check 2: Register owned files vs. disk ───────────────────────────

header "Check 2: Register owned files vs. disk"

# Extract owned file/directory patterns from register
# Format produced by generate-register.sh: | spec.md | status | owner | owns |
# Owns column entries are backtick-wrapped: `src/foo.py`, `tests/test_foo.py`.
missing_files=()
spec_owns_map=""

if [ "$register_schema_compatible" = false ]; then
  warn "$register_schema_message — skipping Check 2"
else
while IFS='|' read -r _ spec _ _ owns _; do
  spec=$(echo "$spec" | xargs)
  owns=$(echo "$owns" | xargs)
  [ -z "$spec" ] || [ -z "$owns" ] && continue

  for pattern in $(echo "$owns" | tr ',' '\n'); do
    # Strip whitespace and backticks (generate-register.sh wraps each path in
    # backticks for markdown rendering — they must be removed for path comparison).
    pattern=$(echo "$pattern" | xargs | tr -d '`')
    [ -z "$pattern" ] && continue

    # Skip ellipsis patterns like "pyproject.toml, setup.cfg, ..."
    [ "$pattern" = "..." ] && continue
    # generate-register.sh emits — for specs with empty Owns column
    [ "$pattern" = "—" ] && continue

    # Handle glob patterns
    if [[ "$pattern" == *"**"* ]]; then
      dir="${pattern%%\*\*}"
      dir="${dir%/}"
      if [ -d "$PROJECT_DIR/$dir" ]; then
        ok "$pattern (directory exists)"
      else
        warn "$pattern (directory missing, owned by $spec)"
      fi
    else
      if [ -e "$PROJECT_DIR/$pattern" ]; then
        ok "$pattern"
      else
        warn "$pattern (file missing, owned by $spec)"
      fi
    fi

    spec_owns_map+="$pattern:$spec"$'\n'
  done
done < <(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)
fi

# Check for unowned source files
header "Check 3: Unowned source files"

if [ "$register_schema_compatible" = false ]; then
  info "Skipped — REGISTER.md schema not compatible (see Check 2 message)"
else
unowned_count=0
# Look for Python files in likely implementation directories
for src_dir in src "$( basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' )" tests; do
  [ ! -d "$PROJECT_DIR/$src_dir" ] && continue

  while IFS= read -r file; do
    rel_path="${file#$PROJECT_DIR/}"
    # Skip __pycache__, .pyc files
    [[ "$rel_path" == *"__pycache__"* ]] && continue
    [[ "$rel_path" == *.pyc ]] && continue

    # Check if this file is covered by any ownership pattern
    owned=false
    while IFS=: read -r pattern owner; do
      [ -z "$pattern" ] && continue
      if [[ "$pattern" == *"**"* ]]; then
        dir="${pattern%%\*\*}"
        if [[ "$rel_path" == "$dir"* ]]; then
          owned=true
          break
        fi
      elif [ "$rel_path" = "$pattern" ]; then
        owned=true
        break
      fi
    done <<< "$spec_owns_map"

    if [ "$owned" = false ]; then
      warn "Unowned: $rel_path"
      ((unowned_count++)) || true
    fi
  done < <(find "$PROJECT_DIR/$src_dir" -name '*.py' -type f 2>/dev/null)
done

[ "$unowned_count" -eq 0 ] && ok "No unowned source files found"
fi

# ── Check 3: contracts.yaml vs. spec Requires tables ─────────────────

header "Check 4: contracts.yaml vs. spec Requires tables"

if [ ! -f "$CONTRACTS" ]; then
  warn "contracts.yaml missing — cannot check version pin sync"
else
  sync_issues=0

  # For each spec file, extract its Requires table pins and compare to contracts.yaml
  for spec_file in "$SPECS_DIR"/*.spec.md; do
    [ ! -f "$spec_file" ] && continue
    spec_name=$(basename "$spec_file" .md)

    # Extract definition@version references from the spec's Requires table
    # Look for patterns like definitions/foo.md@v1
    spec_pins=$(grep -oE 'definitions/[^@|]+@v[0-9]+' "$spec_file" 2>/dev/null || true)

    while IFS= read -r pin; do
      [ -z "$pin" ] && continue
      def_path=$(echo "$pin" | cut -d@ -f1)
      spec_version=$(echo "$pin" | cut -d@ -f2)

      # Check if contracts.yaml has this pin
      # Look for the definition path under this spec's section
      yaml_version=$(grep -A50 "^  ${spec_name%.spec}:" "$CONTRACTS" 2>/dev/null \
        | grep "$def_path" | head -1 \
        | grep -oE 'v[0-9]+' || true)

      if [ -z "$yaml_version" ]; then
        warn "$spec_name: $def_path@$spec_version in spec but missing from contracts.yaml"
        ((sync_issues++)) || true
      elif [ "$yaml_version" != "$spec_version" ]; then
        warn "$spec_name: $def_path — spec says $spec_version, contracts.yaml says $yaml_version"
        ((sync_issues++)) || true
      fi
    done <<< "$spec_pins"
  done

  [ "$sync_issues" -eq 0 ] && ok "All spec pins match contracts.yaml"
fi

# ── Check 4: contracts.yaml vs. definition current versions ──────────

header "Check 5: contracts.yaml vs. definition versions (staleness)"

if [ ! -f "$CONTRACTS" ] || [ ! -d "$DEFS_DIR" ]; then
  info "Skipped — contracts.yaml or definitions/ missing"
else
  stale_count=0

  # Extract all definition references and pinned versions from contracts.yaml
  pins=$(grep -E '^\s+definitions/' "$CONTRACTS" 2>/dev/null | sed 's/#.*//' || true)

  while IFS=: read -r def_path pinned_version; do
    [ -z "$def_path" ] && continue
    def_path=$(echo "$def_path" | xargs)
    pinned_version=$(echo "$pinned_version" | xargs)
    [ -z "$pinned_version" ] && continue

    def_file="$PROJECT_DIR/docs/$def_path"
    if [ ! -f "$def_file" ]; then
      warn "Definition not found: $def_path (pinned at $pinned_version in contracts.yaml)"
      ((stale_count++)) || true
      continue
    fi

    # Extract current version from definition file
    current_version=$(grep -A1 '^## Version' "$def_file" 2>/dev/null \
      | grep -oE 'v[0-9]+' | head -1 || true)

    if [ -z "$current_version" ]; then
      warn "$def_path: no version found in file (pinned at $pinned_version)"
      ((stale_count++)) || true
    elif [ "$current_version" != "$pinned_version" ]; then
      warn "$def_path: pinned=$pinned_version, current=$current_version — STALE"
      ((stale_count++)) || true
    else
      ok "$def_path: $current_version (current)"
    fi
  done <<< "$pins"

  [ "$stale_count" -eq 0 ] && [ -n "$pins" ] && ok "All version pins are current"
fi

# ── Check 5: Spec status consistency ─────────────────────────────────

header "Check 6: Spec status consistency"

if [ "$register_schema_compatible" = false ]; then
  info "Skipped — REGISTER.md schema not compatible (see Check 2 message)"
else
# Read order matches the current schema: | _ | spec | status | owner | owns | _ |
while IFS='|' read -r _ spec status _ owns _; do
  spec=$(echo "$spec" | xargs)
  status=$(echo "$status" | xargs)
  owns=$(echo "$owns" | xargs)
  [ -z "$spec" ] && continue

  spec_file="$SPECS_DIR/$spec"

  case "$status" in
    draft)
      # Draft specs may or may not have code; drift detection doesn't apply
      ;;
    active)
      # Active specs should have owned files that exist. generate-register
      # emits — for empty Owns, so check both empty and the em-dash sentinel.
      if [ -z "$owns" ] || [ "$owns" = "(none)" ] || [ "$owns" = "—" ]; then
        warn "$spec: status=active but owns no files"
      fi
      ;;
    stale)
      warn "$spec: status=stale — drift recorded; run /consolidate to reconcile"
      ;;
    *)
      warn "$spec: unknown status '$status' — must be one of: draft, active, stale"
      ;;
  esac

  # Check that the spec file itself exists
  if [ ! -f "$spec_file" ]; then
    warn "$spec: listed in register but file does not exist"
  fi
done < <(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)

ok "Status consistency check complete"
fi

# ── Check 7: Spec drift detection (auto-flip active → stale) ─────────

header "Check 7: Spec drift (auto-flip active → stale)"

# For each spec at status active, check whether any owned file was modified
# in commits AFTER the spec's most recent commit. If so, the spec is out of
# sync with its owned code → flip status to stale in REGISTER.md and spec
# frontmatter so the user is prompted to run /consolidate.
#
# This is the only mutation this script performs. All other findings are
# advisory ("do not auto-fix"). Drift status is structurally bounded by
# the spec status enum, so writing it is safe.
#
# Skipping when schema is incompatible is critical: this check MUTATES, so
# parsing the wrong column for `owns` could cause the loop to find no drift
# anywhere (silent no-op) or to mutate against bogus paths.

drift_flipped=0
no_drift_count=0

if [ "$register_schema_compatible" = false ]; then
  info "Skipped — REGISTER.md schema not compatible (see Check 2 message)"
elif ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Drift detection compares spec vs. owned-file commit timestamps via
  # `git log`. Without a git working tree there is nothing to compare,
  # and the bare `git log` calls below would exit 128 and propagate
  # through `set -euo pipefail` to crash the whole script (see #137).
  info "Skipped — $PROJECT_DIR is not a git working tree (drift detection requires git history)"
elif ! git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  # An empty repo (e.g. immediately after `git init`, before the first
  # commit) is a work tree but has no HEAD for `git log` to inspect.
  # The substitutions below would still hit fatal: 128 — same crash.
  info "Skipped — $PROJECT_DIR has no git history yet (drift detection requires at least one commit)"
else
# Read order matches the current schema: | _ | spec | status | owner | owns | _ |
while IFS='|' read -r _ spec status _ owns _; do
  spec=$(echo "$spec" | xargs)
  status=$(echo "$status" | xargs)
  owns=$(echo "$owns" | xargs)
  [ -z "$spec" ] && continue
  [ "$status" != "active" ] && continue

  spec_file="$SPECS_DIR/$spec"
  [ ! -f "$spec_file" ] && continue

  # git pathspecs are evaluated relative to the repo root; pass repo-relative
  # paths, not absolute, or the commit hash comes back empty.
  spec_rel="docs/specs/$spec"

  # Most recent commit touching the spec file
  spec_last_commit=$(git -C "$PROJECT_DIR" log -1 --format=%H -- "$spec_rel" 2>/dev/null)
  [ -z "$spec_last_commit" ] && continue

  drift=false
  drift_file=""

  for pattern in $(echo "$owns" | tr ',' '\n'); do
    # Strip whitespace and backticks (generate-register.sh wraps each path in
    # backticks). Skip em-dash and ellipsis sentinels.
    pattern=$(echo "$pattern" | xargs | tr -d '`')
    [ -z "$pattern" ] && continue
    [ "$pattern" = "..." ] && continue
    [ "$pattern" = "—" ] && continue

    # Resolve pattern to actual files
    if [[ "$pattern" == *"**"* ]]; then
      dir="${pattern%%\*\*}"
      dir="${dir%/}"
      [ ! -d "$PROJECT_DIR/$dir" ] && continue
      file_list=$(find "$PROJECT_DIR/$dir" -type f 2>/dev/null)
    elif [ -e "$PROJECT_DIR/$pattern" ]; then
      file_list="$PROJECT_DIR/$pattern"
    else
      continue
    fi

    for owned_file in $file_list; do
      # Convert to repo-relative for git pathspec
      owned_rel="${owned_file#$PROJECT_DIR/}"
      owned_last_commit=$(git -C "$PROJECT_DIR" log -1 --format=%H -- "$owned_rel" 2>/dev/null)
      [ -z "$owned_last_commit" ] && continue
      [ "$owned_last_commit" = "$spec_last_commit" ] && continue
      # spec_last_commit ancestor of owned_last_commit → owned modified later → drift
      if git -C "$PROJECT_DIR" merge-base --is-ancestor "$spec_last_commit" "$owned_last_commit" 2>/dev/null; then
        drift=true
        drift_file="$owned_rel"
        break 2
      fi
    done
  done

  if [ "$drift" = true ]; then
    # Escape spec name for literal use in sed's regex pattern (spec filenames
    # contain `.` which would match any character without escaping).
    escaped_spec=$(printf '%s' "$spec" | sed 's/[][\\.^$*|/]/\\&/g')

    # Flip REGISTER.md status: "| <spec> | active " → "| <spec> | stale "
    sed -i.bak -E "s/^\| ${escaped_spec} \| active /| ${spec} | stale /" "$REGISTER"
    rm -f "$REGISTER.bak"

    # Flip spec status to stale in either supported format:
    # - YAML frontmatter: "status: active" → "status: stale"
    # - Legacy markdown section:
    #     ## Status
    #     active
    if grep -q '^status: active$' "$spec_file"; then
      sed -i.bak "s/^status: active$/status: stale/" "$spec_file"
    elif grep -q '^## Status$' "$spec_file"; then
      sed -i.bak '/^## Status$/{
n
s/^active$/stale/
}' "$spec_file"
    fi
    rm -f "$spec_file.bak"

    # warn() already increments issue_count and sets drift_found
    warn "$spec: flipped active → stale (drift: $drift_file modified after spec's last commit $spec_last_commit)"
    ((drift_flipped++)) || true
  else
    ((no_drift_count++)) || true
  fi
done < <(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)

if [ "$drift_flipped" -eq 0 ]; then
  if [ "$no_drift_count" -gt 0 ]; then
    ok "No drift detected across $no_drift_count active spec(s)"
  else
    info "No active specs to check"
  fi
fi
fi  # close: register_schema_compatible guard for Check 7

# ── Check 8: Plan files missing Tests section ────────────────────────

header "Check 8: Plan files — Tests section"

PLANS_DIR="$PROJECT_DIR/docs/plans"
if [ ! -d "$PLANS_DIR" ]; then
  info "Skipped — docs/plans/ not found"
else
  plans_checked=0
  plans_warned=0

  for plan_file in "$PLANS_DIR"/*.md; do
    [ ! -f "$plan_file" ] && continue
    plan_name=$(basename "$plan_file")

    # Skip templates
    [[ "$plan_name" == "TEMPLATE.md" ]] && continue
    [[ "$plan_name" == *template* ]] && continue

    plan_content=$(cat "$plan_file")

    # Determine if the plan is test-prudent:
    # Contains source file extensions or implementation keywords
    is_test_prudent=false

    if echo "$plan_content" | grep -qE '\.(ts|js|sh|py|go|rs|rb|java|tsx|jsx)\b'; then
      is_test_prudent=true
    elif echo "$plan_content" | grep -qiE 'implement|create function|add endpoint|write code|add method|new file|modify|refactor'; then
      is_test_prudent=true
    fi

    # If only docs/config references, skip
    if [ "$is_test_prudent" = false ]; then
      continue
    fi

    ((plans_checked++)) || true

    # Check for a ## Tests or ## Test heading
    if echo "$plan_content" | grep -qE '^## Tests?(\s|$)'; then
      ok "$plan_name has a Tests section"
    else
      info "$plan_name: test-prudent plan without a ## Tests section"
      ((plans_warned++)) || true
    fi
  done

  [ "$plans_checked" -eq 0 ] && info "No test-prudent plans found"
  [ "$plans_checked" -gt 0 ] && [ "$plans_warned" -eq 0 ] && ok "All test-prudent plans have a Tests section"
fi

# ── Check 9: Strategic Anchor validity ──────────────────────────────

header "Check 9: Strategic Anchor"

strategic_anchor_check() {
  local root config claude
  root="$PROJECT_DIR"
  config="$root/roadmap.config.yaml"
  claude="$root/CLAUDE.md"

  # Silent pass — not adopted
  [ ! -f "$config" ] && return 0

  local issues=0

  # 1. Section present
  if ! grep -q '^## Strategic Anchor' "$claude" 2>/dev/null; then
    echo "WARN [strategic-anchor]: CLAUDE.md is missing '## Strategic Anchor' (roadmap.config.yaml exists)"
    issues=$((issues + 1))
  else
    # 2. Time horizon date is in the future — only if the horizon itself contains
    # an ISO date. Strip any (next review: ...) parenthetical first so we don't
    # accidentally check the review date instead of the horizon end.
    local horizon_date today_epoch horizon_epoch
    horizon_date=$(awk '/^## Strategic Anchor/{found=1} found && /\*\*Time horizon:/{print; exit}' "$claude" \
      | sed 's/(next review:[^)]*)//g' \
      | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
    if [ -n "$horizon_date" ]; then
      # macOS date -j -f, Linux date -d
      horizon_epoch=$(date -j -f '%Y-%m-%d' "$horizon_date" +%s 2>/dev/null \
        || date -d "$horizon_date" +%s 2>/dev/null \
        || echo 0)
      today_epoch=$(date +%s)
      if [ "$horizon_epoch" -lt "$today_epoch" ]; then
        echo "WARN [strategic-anchor]: Time horizon date ($horizon_date) is past — run /roadmap revise"
        issues=$((issues + 1))
      fi
    fi

    # 3. In/out scope non-empty (≥1 bullet each)
    local in_bullets out_bullets
    in_bullets=$(awk '/^### In scope/{found=1; next} found && /^### /{exit} found{print}' "$claude" \
      | grep -cE '^- ' 2>/dev/null || echo 0)
    out_bullets=$(awk '/^### Out of scope/{found=1; next} found && /^### /{exit} found{print}' "$claude" \
      | grep -cE '^- ' 2>/dev/null || echo 0)
    [ "$in_bullets" -lt 1 ] && \
      echo "WARN [strategic-anchor]: '### In scope (this period)' has no bullets" && issues=$((issues + 1))
    [ "$out_bullets" -lt 1 ] && \
      echo "WARN [strategic-anchor]: '### Out of scope (this period)' has no bullets" && issues=$((issues + 1))
  fi

  # 4. Cadence not overdue
  local last_reviewed cadence_weeks last_epoch due_epoch
  # Use python3 if yq not available (same pattern as lib.sh)
  if command -v yq >/dev/null 2>&1; then
    last_reviewed=$(yq -r '.last_reviewed // ""' "$config")
    cadence_weeks=$(yq -r '.review_cadence_weeks // ""' "$config")
  elif command -v python3 >/dev/null 2>&1; then
    _yaml_scalar() {
      python3 - "$1" "$2" <<'PYEOF'
import sys, re
def parse_scalar(path, key):
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            m = re.match(r'^' + re.escape(key) + r'\s*:\s*(.*)', line)
            if m:
                val = re.sub(r'\s+#.*$', '', m.group(1)).strip()
                if val in ('', 'null', '~'):
                    return ''
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                    val = val[1:-1]
                return val
    return ''
print(parse_scalar(sys.argv[1], sys.argv[2]))
PYEOF
    }
    last_reviewed=$(_yaml_scalar "$config" last_reviewed)
    cadence_weeks=$(_yaml_scalar "$config" review_cadence_weeks)
  fi
  if [ -n "${last_reviewed:-}" ] && [ -n "${cadence_weeks:-}" ]; then
    last_epoch=$(date -j -f '%Y-%m-%d' "$last_reviewed" +%s 2>/dev/null \
      || date -d "$last_reviewed" +%s 2>/dev/null \
      || echo 0)
    due_epoch=$(( last_epoch + cadence_weeks * 7 * 86400 ))
    if [ "$(date +%s)" -gt "$due_epoch" ]; then
      echo "WARN [strategic-anchor]: Strategic review overdue (last=$last_reviewed, cadence=${cadence_weeks}w) — run /roadmap revise"
      issues=$((issues + 1))
    fi
  fi

  [ "$issues" -eq 0 ] && echo "OK [strategic-anchor]: all checks pass"
  return $issues
}

# Run the check; harvest any WARN lines into the standard drift machinery
anchor_output=$(strategic_anchor_check 2>&1) || anchor_exit=$?
anchor_exit=${anchor_exit:-0}

if [ -z "$anchor_output" ]; then
  # strategic_anchor_check returned 0 with no output — config absent, silent pass
  info "Skipped — roadmap.config.yaml not present"
else
  while IFS= read -r line; do
    if [[ "$line" == WARN* ]]; then
      warn "${line#WARN }"
    elif [[ -n "$line" ]]; then
      info "$line"
    fi
  done <<< "$anchor_output"
  if [ "$anchor_exit" -eq 0 ] && ! echo "$anchor_output" | grep -q '^WARN'; then
    ok "Strategic Anchor looks good"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$drift_found" = true ]; then
  echo "DRIFT DETECTED: $issue_count issues found across $check_count checks."
  echo ""
  echo "Review the issues above and resolve before implementing."
  echo "Do not auto-fix — the architecture owner approves changes."
  exit 1
else
  echo "HEALTHY: No drift detected across $check_count checks."
  exit 0
fi
