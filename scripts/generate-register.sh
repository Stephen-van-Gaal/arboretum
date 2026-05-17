#!/usr/bin/env bash
# generate-register.sh — Auto-generate REGISTER.md from spec frontmatter.
#
# Reads all docs/specs/*.spec.md files, extracts YAML frontmatter
# (name, status, owner, owns), resolves owns patterns to actual files,
# and generates docs/REGISTER.md.
#
# Preserves "## Unowned Code" and "## Dependency Resolution Order" sections
# from the existing REGISTER.md if present.
#
# Usage:
#   ./scripts/generate-register.sh [project-dir] [--dry-run]
#
# Options:
#   --dry-run   Print generated content to stdout instead of writing to file.
#
# Requires bash 4+ (uses arrays).

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

# ── Parse arguments ──────────────────────────────────────────────────

DRY_RUN=false
PROJECT_DIR=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) [ -z "$PROJECT_DIR" ] && PROJECT_DIR="$arg" ;;
  esac
done

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
SPECS_DIR="$PROJECT_DIR/docs/specs"
REGISTER="$PROJECT_DIR/docs/REGISTER.md"

if [ ! -d "$SPECS_DIR" ]; then
  echo "Error: specs directory not found: $SPECS_DIR" >&2
  echo "No specs to generate register from." >&2
  exit 1
fi

# ── Find spec files ──────────────────────────────────────────────────

spec_files=()
while IFS= read -r f; do
  [ -n "$f" ] && spec_files+=("$f")
done < <(find "$SPECS_DIR" -name "*.spec.md" -type f 2>/dev/null | sort)

if [ ${#spec_files[@]} -eq 0 ]; then
  echo "No *.spec.md files found in $SPECS_DIR" >&2
  exit 1
fi

# ── Extract frontmatter from a spec file ─────────────────────────────

extract_frontmatter() {
  local file="$1"
  local in_fm=false
  local fm_done=false
  local delimiters=0
  local result=""

  while IFS= read -r line; do
    if [ "$fm_done" = true ]; then break; fi
    if [[ "$line" == "---" ]]; then
      ((delimiters++)) || true
      if [ "$delimiters" -eq 1 ]; then in_fm=true; fi
      if [ "$delimiters" -eq 2 ]; then fm_done=true; fi
      continue
    fi
    if [ "$in_fm" = true ]; then
      result+="$line"$'\n'
    fi
  done < "$file"

  if [ "$delimiters" -lt 2 ]; then
    echo ""
    return 1
  fi

  echo "$result"
}

extract_scalar() {
  local frontmatter="$1"
  local field="$2"
  echo "$frontmatter" | sed -n "s/^${field}:[[:space:]]*//p" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

extract_owns_list() {
  local frontmatter="$1"
  local in_owns=false
  local patterns=()

  while IFS= read -r line; do
    if [[ "$line" =~ ^owns: ]]; then
      in_owns=true
      continue
    fi
    if [ "$in_owns" = true ]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]](.+) ]]; then
        local pattern="${BASH_REMATCH[1]}"
        pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$pattern" ] && patterns+=("$pattern")
      elif [[ "$line" =~ ^[^[:space:]] ]]; then
        in_owns=false
      fi
    fi
  done <<< "$frontmatter"

  # Guard the expansion: on bash < 4.4, "${patterns[@]}" on an empty
  # declared array trips `set -u`. Mirrors the guard in resolve_owns below.
  if [ ${#patterns[@]} -gt 0 ]; then
    printf '%s\n' "${patterns[@]}"
  fi
}

# ── Resolve owns patterns to actual files ────────────────────────────

resolve_owns() {
  local pattern="$1"
  local resolved=()

  # Try exact path match first
  if [ -e "$PROJECT_DIR/$pattern" ]; then
    echo "$pattern"
    return
  fi

  # Try glob expansion
  while IFS= read -r -d $'\0' file; do
    file="${file#./}"
    resolved+=("$file")
  done < <(cd "$PROJECT_DIR" && find . -path "./$pattern" -print0 2>/dev/null | sort -z)

  if [ ${#resolved[@]} -gt 0 ]; then
    printf '%s\n' "${resolved[@]}"
  else
    # Return the raw pattern even if unresolved (so it shows in the register)
    echo "$pattern"
  fi
}

# ── Parse all specs ──────────────────────────────────────────────────

# Arrays indexed by position
spec_names=()
spec_statuses=()
spec_owners=()
spec_owns_display=()
spec_filenames=()

for spec_file in "${spec_files[@]}"; do
  frontmatter=$(extract_frontmatter "$spec_file") || true

  if [ -z "$frontmatter" ]; then
    echo "Warning: no frontmatter in $(basename "$spec_file"), skipping." >&2
    continue
  fi

  name=$(extract_scalar "$frontmatter" "name")
  status=$(extract_scalar "$frontmatter" "status")
  owner=$(extract_scalar "$frontmatter" "owner")
  filename=$(basename "$spec_file")

  # Use filename stem as name if frontmatter name is empty
  if [ -z "$name" ]; then
    name="${filename%.spec.md}"
  fi

  # Extract and resolve owns patterns
  owns_patterns=()
  while IFS= read -r p; do
    [ -n "$p" ] && owns_patterns+=("$p")
  done < <(extract_owns_list "$frontmatter")

  # Build display string for owns column
  owns_display=""
  if [ ${#owns_patterns[@]} -gt 0 ]; then
    resolved_all=()
    for pattern in "${owns_patterns[@]}"; do
      while IFS= read -r resolved; do
        [ -n "$resolved" ] && resolved_all+=("$resolved")
      done < <(resolve_owns "$pattern")
    done
    # Join with ", " separator (IFS only uses first char, so join manually)
    owns_display=""
    for j in "${!resolved_all[@]}"; do
      if [ "$j" -gt 0 ]; then owns_display+=", "; fi
      owns_display+="${resolved_all[$j]}"
    done
  fi

  spec_names+=("$name")
  spec_statuses+=("${status:-draft}")
  spec_owners+=("${owner:-}")
  spec_owns_display+=("$owns_display")
  spec_filenames+=("$filename")
done

if [ ${#spec_names[@]} -eq 0 ]; then
  echo "No valid specs with frontmatter found." >&2
  exit 1
fi

# ── Preserve sections from existing REGISTER.md ─────────────────────

existing_unowned=""
existing_dep_order=""

if [ -f "$REGISTER" ]; then
  # Extract "## Unowned Code" section (from header to next ## or EOF)
  in_section=false
  section_content=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+Unowned[[:space:]]+Code ]]; then
      in_section=true
      continue
    fi
    if [ "$in_section" = true ]; then
      if [[ "$line" =~ ^##[[:space:]] ]]; then
        in_section=false
        continue
      fi
      section_content+="$line"$'\n'
    fi
  done < "$REGISTER"
  existing_unowned="$section_content"

  # Extract "## Dependency Resolution Order" section
  in_section=false
  section_content=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+Dependency[[:space:]]+Resolution ]]; then
      in_section=true
      continue
    fi
    if [ "$in_section" = true ]; then
      if [[ "$line" =~ ^##[[:space:]] ]] && ! [[ "$line" =~ ^### ]]; then
        in_section=false
        continue
      fi
      section_content+="$line"$'\n'
    fi
  done < "$REGISTER"
  existing_dep_order="$section_content"
fi

# ── Count statuses for status summary ────────────────────────────────
# Avoid associative arrays (not available in bash 3.x / macOS default).
# Use parallel arrays instead.

status_labels=()
status_counts=()

increment_status() {
  local target="$1"
  local i
  for i in "${!status_labels[@]}"; do
    if [ "${status_labels[$i]}" = "$target" ]; then
      status_counts[$i]=$(( ${status_counts[$i]} + 1 ))
      return
    fi
  done
  status_labels+=("$target")
  status_counts+=("1")
}

for s in "${spec_statuses[@]}"; do
  increment_status "$s"
done

get_status_count() {
  local target="$1"
  local i
  for i in "${!status_labels[@]}"; do
    if [ "${status_labels[$i]}" = "$target" ]; then
      echo "${status_counts[$i]}"
      return
    fi
  done
  echo "0"
}

# ── Generate REGISTER.md ─────────────────────────────────────────────

output=""
output+="# Project Register"$'\n'
output+=$'\n'
output+="## Definitions Index"$'\n'
output+=$'\n'
output+="| Definition | Version | Status | Primary Implementor | Required By |"$'\n'
output+="|------------|---------|--------|---------------------|-------------|"$'\n'
output+=$'\n'
output+="<!-- No shared definitions yet. -->"$'\n'
output+=$'\n'
output+="## Spec Index"$'\n'
output+=$'\n'
output+="| Spec | Status | Owner | Owns (files/directories) |"$'\n'
output+="|------|--------|-------|--------------------------|"$'\n'

for i in "${!spec_names[@]}"; do
  owns_col="${spec_owns_display[$i]}"
  if [ -n "$owns_col" ]; then
    owns_col="\`${owns_col//,\ /\`, \`}\`"
  else
    owns_col="—"
  fi
  owner_col="${spec_owners[$i]}"
  [ -z "$owner_col" ] && owner_col="—"

  output+="| ${spec_filenames[$i]} | ${spec_statuses[$i]} | ${owner_col} | ${owns_col} |"$'\n'
done

output+=$'\n'
output+="## Status Summary"$'\n'
output+=$'\n'
output+="| Status | Count |"$'\n'
output+="|--------|-------|"$'\n'

for status in draft active stale; do
  count=$(get_status_count "$status")
  if [ "$count" -gt 0 ]; then
    output+="| $status | $count |"$'\n'
  fi
done

output+=$'\n'
output+="## Unowned Code"$'\n'

if [ -n "$existing_unowned" ]; then
  output+="$existing_unowned"
else
  output+="<!-- This section should always be empty. If it is not, something"$'\n'
  output+="     needs to be assigned to a spec or deleted. -->"$'\n'
fi

output+=$'\n'
output+="## Dependency Resolution Order"$'\n'

if [ -n "$existing_dep_order" ]; then
  output+="$existing_dep_order"
else
  output+="<!-- Topological sort of the spec dependency graph."$'\n'
  output+="     This is the order in which specs should be implemented. -->"$'\n'
fi

# ── Output ────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  echo "$output"
else
  # Ensure docs directory exists
  mkdir -p "$(dirname "$REGISTER")"
  echo "$output" > "$REGISTER"
  echo "Generated $REGISTER from ${#spec_names[@]} spec(s)."
fi
