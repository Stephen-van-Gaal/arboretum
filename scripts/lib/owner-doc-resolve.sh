#!/usr/bin/env bash
# owner: shared-components
# scope: plugin-only
# owner-doc-resolve.sh — resolve a `# owner: <name>` to its governing document.
#
# Sourced library; defines owner_doc_path. Group-aware (D7, #681): an owner name
# resolves to a governed spec OR a group document. Single source of owner→document
# resolution for ci-checks.sh, health-check.sh, and _smoke-test-script-owners.sh
# (prevents the parallel-drift class of #124). Spec takes precedence over group.

# owner_doc_path <name> [project-dir]
#   Echoes the resolved document path and returns 0 when one exists; echoes
#   nothing and returns 1 when neither a spec nor a group document is found.
owner_doc_path() {
  local name="$1"
  local project_dir="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local spec="$project_dir/docs/specs/$name.spec.md"
  local group="$project_dir/docs/groups/$name.md"
  if [ -f "$spec" ]; then printf '%s\n' "$spec"; return 0; fi
  if [ -f "$group" ]; then printf '%s\n' "$group"; return 0; fi
  return 1
}
