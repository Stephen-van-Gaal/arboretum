#!/usr/bin/env bash
# owner: project-infrastructure
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

extract_yaml_list() {
  local frontmatter="$1"
  local field="$2"
  local in_field=false
  local patterns=()

  while IFS= read -r line; do
    if [[ "$line" =~ ^${field}: ]]; then
      in_field=true
      continue
    fi
    if [ "$in_field" = true ]; then
      if [[ "$line" =~ ^[[:space:]]*-[[:space:]](.+) ]]; then
        local pattern="${BASH_REMATCH[1]}"
        pattern=$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$pattern" ] && patterns+=("$pattern")
      elif [[ "$line" =~ ^[^[:space:]] ]]; then
        in_field=false
      fi
    fi
  done <<< "$frontmatter"

  # ${arr[@]+"${arr[@]}"} is the bash idiom for "expand only if set" —
  # plain "${arr[@]}" on an empty local array trips `set -u` with
  # "patterns[@]: unbound variable" on bash 4.4+. A spec with no owns:
  # block (or an inline `owns: []`) leaves patterns empty here.
  printf '%s\n' "${patterns[@]+"${patterns[@]}"}"
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
spec_provides_lists=()    # one entry per spec; newline-separated definition names
spec_requires_lists=()    # one entry per spec; newline-separated definition names

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
  done < <(extract_yaml_list "$frontmatter" "owns")

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

  # Capture provides/requires for the Definition Index. Each entry is the
  # raw newline-separated list of definition names declared in frontmatter;
  # we walk them later when building the per-definition Providers/Requirers
  # columns. Specs without these fields just contribute empty entries.
  provides_block=$(extract_yaml_list "$frontmatter" "provides")
  requires_block=$(extract_yaml_list "$frontmatter" "requires")

  spec_names+=("$name")
  spec_statuses+=("${status:-draft}")
  spec_owners+=("${owner:-}")
  spec_owns_display+=("$owns_display")
  spec_filenames+=("$filename")
  spec_provides_lists+=("$provides_block")
  spec_requires_lists+=("$requires_block")
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
  # Strip trailing blank lines so each regeneration doesn't accumulate them
  existing_unowned=$(printf '%s' "$section_content")

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
  # Strip trailing blank lines so each regeneration doesn't accumulate them
  existing_dep_order=$(printf '%s' "$section_content")
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

# ── Parse definitions (Layer 1+: shared contracts) ───────────────────

# Definitions live under docs/definitions/*.md. Each file declares a
# shared contract (a data shape, an API surface, a config schema) that
# multiple specs may provide or require by name.
#
# We auto-detect the dir and parse frontmatter for `name`, `version`,
# `status`. If the dir is missing or empty, the Definition Index emits
# the historical placeholder comment — backwards compatible with
# projects that have no shared definitions.

definitions_dir="$PROJECT_DIR/docs/definitions"
definition_names=()
definition_versions=()
definition_statuses=()

if [ -d "$definitions_dir" ]; then
  while IFS= read -r def_file; do
    [ -z "$def_file" ] && continue
    def_fm=$(extract_frontmatter "$def_file" || true)

    # Distinct variable names (def_name/def_version/def_status) avoid
    # shadowing the loop-scope `name/status/owner` from the spec-parsing
    # loop above — these are top-level script variables, not function-
    # locals, so a clobber would propagate.

    # Definition name defaults to the filename stem (matches the convention
    # consumer projects already use — e.g. `docs/definitions/pubmed-record.md`
    # is the `pubmed-record` definition).
    def_name=$(extract_scalar "$def_fm" "name")
    [ -z "$def_name" ] && def_name=$(basename "$def_file" .md)

    def_version=$(extract_scalar "$def_fm" "version")
    [ -z "$def_version" ] && def_version="v0"

    def_status=$(extract_scalar "$def_fm" "status")
    [ -z "$def_status" ] && def_status="draft"

    definition_names+=("$def_name")
    definition_versions+=("$def_version")
    definition_statuses+=("$def_status")
  done < <(find "$definitions_dir" -name "*.md" -type f 2>/dev/null | sort)
fi

# ── Generate REGISTER.md ─────────────────────────────────────────────

output=""
output+="# Project Register"$'\n'
output+=$'\n'
output+="## Definitions Index"$'\n'
output+=$'\n'

# Consistent table header in both branches keeps REGISTER.md
# programmatically parseable and avoids noisy diffs when a project
# first adds a definition (column names would otherwise change at
# the same time as the first row appears).
output+="| Name | Version | Status | Provided By | Required By |"$'\n'
output+="|------|---------|--------|-------------|-------------|"$'\n'

if [ ${#definition_names[@]} -eq 0 ]; then
  output+=$'\n'
  output+="<!-- No shared definitions yet. -->"$'\n'
else

  for i in "${!definition_names[@]}"; do
    def_name="${definition_names[$i]}"

    # Walk each spec's provides/requires lists looking for this definition.
    # Specs without the field contribute nothing. Names that appear in
    # multiple specs accumulate into a comma-separated list.
    providers=()
    requirers=()
    for j in "${!spec_names[@]}"; do
      while IFS= read -r p; do
        [ "$p" = "$def_name" ] && providers+=("${spec_names[$j]}")
      done <<< "${spec_provides_lists[$j]}"
      while IFS= read -r r; do
        [ "$r" = "$def_name" ] && requirers+=("${spec_names[$j]}")
      done <<< "${spec_requires_lists[$j]}"
    done

    # Manual ", " join — bash's IFS-based join only uses IFS's first char.
    providers_str="—"
    if [ ${#providers[@]} -gt 0 ]; then
      providers_str=""
      for p in "${providers[@]}"; do
        [ -n "$providers_str" ] && providers_str+=", "
        providers_str+="$p"
      done
    fi
    requirers_str="—"
    if [ ${#requirers[@]} -gt 0 ]; then
      requirers_str=""
      for r in "${requirers[@]}"; do
        [ -n "$requirers_str" ] && requirers_str+=", "
        requirers_str+="$r"
      done
    fi

    output+="| ${def_name} | ${definition_versions[$i]} | ${definition_statuses[$i]} | ${providers_str} | ${requirers_str} |"$'\n'
  done
fi

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

# Emit canonical states first in lifecycle order, then any other observed
# states alphabetically. Pre-fix this loop iterated only `draft active stale`
# and silently dropped extended-enum states (ready, in-progress, implemented,
# etc.) from the summary — leaving an empty table for projects using a
# richer vocabulary. Iterating actual observed labels keeps the summary
# vocabulary-agnostic without needing to read .arboretum.yml here.
_summary_order=$({
  for s in draft active stale; do echo "$s"; done
  printf '%s\n' "${status_labels[@]}" | sort -u | grep -vxE 'draft|active|stale' || true
})
while IFS= read -r status; do
  [ -z "$status" ] && continue
  count=$(get_status_count "$status")
  if [ "$count" -gt 0 ]; then
    output+="| $status | $count |"$'\n'
  fi
done <<< "$_summary_order"

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
