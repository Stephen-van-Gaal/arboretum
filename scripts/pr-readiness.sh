#!/usr/bin/env bash
# owner: git-workflow-tooling
# pr-readiness.sh — Classify local/remote PR readiness for the ship tail.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "pr-readiness.sh requires bash" >&2; exit 2; }

usage() {
  echo "Usage: pr-readiness.sh {local <base-ref>|remote <pr-number> [--allow-draft]}" >&2
  exit 2
}

emit() {
  printf '%s\n' "$*"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  local|remote) ;;
  *) usage ;;
esac

classify_backend() {
  if [ -n "${SHIP_BACKEND:-}" ]; then
    printf '%s\n' "$SHIP_BACKEND"
    return 0
  fi

  local project_dir lib
  project_dir="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
  lib="$project_dir/scripts/roadmap/lib.sh"
  if [ -f "$lib" ]; then
    # shellcheck source=scripts/roadmap/lib.sh
    source "$lib"
    roadmap_backend "$project_dir"
    return 0
  fi

  printf 'github\n'
}

append_debug_remote() {
  local out="$1" mergeable="$2" merge_state="$3"
  if [ "${READINESS_DEBUG:-0}" = "1" ]; then
    printf '%s raw_mergeable=%s raw_merge_state=%s\n' "$out" "$mergeable" "$merge_state"
  else
    printf '%s\n' "$out"
  fi
}

fetch_pr_view() {
  local pr="$1" stderr_file out rc=""
  stderr_file="$(mktemp)"
  out="$(gh pr view "$pr" --json isDraft,mergeable,mergeStateStatus,headRefOid,baseRefOid 2>"$stderr_file")" || rc=$?
  if [ -z "$rc" ] && [ -n "$out" ]; then
    rm -f "$stderr_file"
    printf '%s' "$out"
    return 0
  fi

  sleep "${READINESS_RETRY_SLEEP:-10}"
  rc=""
  out="$(gh pr view "$pr" --json isDraft,mergeable,mergeStateStatus,headRefOid,baseRefOid 2>"$stderr_file")" || rc=$?
  rm -f "$stderr_file"
  if [ -z "$rc" ] && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

classify_checks() {
  local pr="$1" stderr_file out rc="" err lower_err
  stderr_file="$(mktemp)"
  out="$(gh pr checks "$pr" --json state,bucket,name 2>"$stderr_file")" || rc=$?
  if [ -n "$out" ]; then
    rm -f "$stderr_file"
    printf '%s' "$out"
    return 0
  fi

  err="$(cat "$stderr_file" 2>/dev/null || true)"
  rm -f "$stderr_file"
  lower_err="$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')"
  case "$lower_err" in
    *"no checks"*|*"no status checks"*)
      printf '[]'
      return 0
      ;;
  esac
  return "${rc:-1}"
}

remote() {
  local pr="${1:-}" allow_draft=0 backend view_json view_class needs_ci
  [ -n "$pr" ] || usage
  [[ "$pr" =~ ^[0-9]+$ ]] || usage
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow-draft) allow_draft=1 ;;
      *) usage ;;
    esac
    shift
  done

  backend="$(classify_backend)"
  if [ "$backend" != "github" ]; then
    emit "readiness=unknown reason=unsupported-backend next_action=escalate ci=not-checked backend=$backend"
    return 0
  fi

  command -v gh >/dev/null 2>&1 || { echo "pr-readiness.sh remote requires the gh CLI" >&2; exit 2; }
  command -v python3 >/dev/null 2>&1 || { echo "pr-readiness.sh remote requires python3" >&2; exit 2; }

  if ! view_json="$(fetch_pr_view "$pr")"; then
    emit "readiness=unknown reason=mergeability-unknown next_action=retry-readiness ci=not-checked head_sha=unknown base_sha=unknown"
    return 0
  fi

  view_class="$(VIEW_JSON="$view_json" python3 - "$allow_draft" <<'PY'
import json, os, sys
allow = sys.argv[1] == "1"
try:
    data = json.loads(os.environ.get("VIEW_JSON", ""))
except Exception:
    print("FINAL\treadiness=unknown reason=mergeability-unknown next_action=retry-readiness ci=not-checked head_sha=unknown base_sha=unknown\tUNKNOWN\tUNKNOWN")
    raise SystemExit(0)

mergeable = str(data.get("mergeable") or "").upper()
merge_state = str(data.get("mergeStateStatus") or "").upper()
is_draft = bool(data.get("isDraft"))
head = data.get("headRefOid") or "unknown"
base = data.get("baseRefOid") or "unknown"
ids = f"head_sha={head} base_sha={base}"

if mergeable in ("", "UNKNOWN") or merge_state in ("", "UNKNOWN"):
    print(f"FINAL\treadiness=unknown reason=mergeability-unknown next_action=retry-readiness ci=not-checked {ids}\t{mergeable or 'UNKNOWN'}\t{merge_state or 'UNKNOWN'}")
elif mergeable == "CONFLICTING" or merge_state == "DIRTY":
    print(f"FINAL\treadiness=blocked reason=merge-conflict next_action=repair-conflicts ci=not-checked {ids}\t{mergeable}\t{merge_state}")
elif is_draft or merge_state == "DRAFT":
    if allow and mergeable == "MERGEABLE":
        print(f"FINAL\treadiness=draft-clean reason=draft-only next_action=mark-ready ci=not-checked {ids}\t{mergeable}\t{merge_state}")
    else:
        print(f"FINAL\treadiness=blocked reason=draft-only next_action=mark-ready ci=not-checked {ids}\t{mergeable}\t{merge_state}")
elif merge_state == "BEHIND":
    print(f"FINAL\treadiness=blocked reason=merge-state-blocked next_action=escalate ci=not-checked {ids}\t{mergeable}\t{merge_state}")
elif mergeable == "MERGEABLE":
    print(f"NEEDS_CI\t{ids}\t{mergeable}\t{merge_state}")
else:
    print(f"FINAL\treadiness=blocked reason=merge-state-blocked next_action=escalate ci=not-checked {ids}\t{mergeable}\t{merge_state}")
PY
)"

  IFS=$'\t' read -r needs_ci output mergeable merge_state <<<"$view_class"
  if [ "$needs_ci" = "FINAL" ]; then
    append_debug_remote "$output" "$mergeable" "$merge_state"
    return 0
  fi

  local checks_json check_class
  if ! checks_json="$(classify_checks "$pr")"; then
    append_debug_remote "readiness=unknown reason=ci-unavailable next_action=retry-readiness ci=unknown $output" "$mergeable" "$merge_state"
    return 0
  fi
  check_class="$(CHECKS_JSON="$checks_json" python3 - "$output" "$merge_state" <<'PY'
import json, os, sys
ids = sys.argv[1]
merge_state = str(sys.argv[2] or "").upper()
try:
    data = json.loads(os.environ.get("CHECKS_JSON", ""))
except Exception:
    data = []
if not isinstance(data, list):
    data = []

fail_names = []
pending = False
skipped = False
pass_count = 0
for check in data:
    bucket = str(check.get("bucket") or "").lower()
    state = str(check.get("state") or "").upper()
    name = str(check.get("name") or "check").replace(" ", "_")
    if bucket in {"fail", "cancel"} or state in {"FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"}:
        fail_names.append(name)
    elif bucket in {"pending"} or state in {"PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"}:
        pending = True
    elif bucket in {"skipping"} or state in {"SKIPPED"}:
        skipped = True
    elif bucket in {"pass"} or state in {"SUCCESS", "NEUTRAL"}:
        pass_count += 1

if fail_names:
    names = ",".join(fail_names)
    print(f"readiness=blocked reason=ci-failing next_action=fix-ci ci=fail failing_checks={names} {ids}")
elif pending:
    print(f"readiness=waiting reason=ci-pending next_action=wait-ci ci=pending {ids}")
elif skipped or not data or pass_count == 0:
    print(f"readiness=unknown reason=ci-absent next_action=configure-ci ci=absent {ids}")
elif merge_state in {"CLEAN", "HAS_HOOKS", "UNSTABLE"}:
    print(f"readiness=ready reason=clean next_action=proceed ci=pass {ids}")
else:
    print(f"readiness=blocked reason=merge-state-blocked next_action=escalate ci=pass {ids}")
PY
)"
  append_debug_remote "$check_class" "$mergeable" "$merge_state"
}

local_check() {
  local base_ref="${1:-}" merge_base merge_out conflict_paths
  [ -n "$base_ref" ] || usage
  command -v git >/dev/null 2>&1 || { echo "pr-readiness.sh local requires git" >&2; exit 2; }

  if [ -n "$(git status --short 2>/dev/null)" ]; then
    emit "readiness=blocked reason=local-dirty next_action=repair-local ci=not-checked base_ref=$base_ref"
    return 0
  fi

  if ! git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
    emit "readiness=unknown reason=local-unknown next_action=retry-readiness ci=unknown base_ref=$base_ref"
    return 0
  fi

  if ! merge_base="$(git merge-base "$base_ref" HEAD 2>/dev/null)"; then
    emit "readiness=unknown reason=local-unknown next_action=retry-readiness ci=unknown base_ref=$base_ref"
    return 0
  fi

  if ! merge_out="$(git merge-tree "$merge_base" "$base_ref" HEAD 2>/dev/null)"; then
    emit "readiness=unknown reason=local-unknown next_action=retry-readiness ci=unknown base_ref=$base_ref"
    return 0
  fi

  if printf '%s\n' "$merge_out" | grep -qE '^(changed in both|added in both|removed in local|removed in remote)'; then
    conflict_paths="$(printf '%s\n' "$merge_out" | awk '
      /^(changed in both|added in both|removed in local|removed in remote)/ { in_conflict = 1; next }
      in_conflict && /^[[:space:]]+(base|our|their)[[:space:]]/ { print $NF; in_conflict = 0; next }
    ' | sort -u | paste -sd, -)"
    if [ -n "$conflict_paths" ]; then
      emit "readiness=blocked reason=local-conflict next_action=repair-local ci=not-checked base_ref=$base_ref conflict_paths=$conflict_paths"
    else
      emit "readiness=blocked reason=local-conflict next_action=repair-local ci=not-checked base_ref=$base_ref"
    fi
    return 0
  fi

  emit "readiness=ready reason=clean next_action=proceed ci=not-checked base_ref=$base_ref"
}

case "$cmd" in
  remote) remote "$@" ;;
  local) local_check "$@" ;;
esac
