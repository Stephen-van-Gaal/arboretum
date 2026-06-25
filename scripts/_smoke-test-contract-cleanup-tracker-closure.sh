#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# _smoke-test-contract-cleanup-tracker-closure.sh — Contract test for
# docs/contracts/cleanup-tracker-closure.cli-contract.md.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/scripts/cleanup-tracker-closure.sh"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
fail=0

pass() { echo "PASS: $1"; }
fail_case() {
  echo "FAIL: $1" >&2
  [ -n "${2:-}" ] && printf '  %s\n' "$2" >&2
  fail=1
}

assert_json() {
  local name="$1" json="$2" filter="$3"
  if printf '%s' "$json" | jq -e "$filter" >/dev/null; then
    pass "$name"
  else
    fail_case "$name" "json=[$json] filter=[$filter]"
  fi
}

BIN="$FIX/bin"; mkdir -p "$BIN"
GH_LOG="$FIX/gh.log"; : > "$GH_LOG"
AZ_LOG="$FIX/az.log"; : > "$AZ_LOG"
export GH_LOG AZ_LOG

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
printf '%s\n' "$*" >> "${GH_LOG:?}"

if [ "$1 $2" = "pr view" ]; then
  issue="${GH_STUB_ISSUE:-500}"
  mode="${GH_STUB_PR_MODE:-close}"
  case "$mode" in
    close) body="## Tracker
Closes #$issue" ;;
    multi) body="## Tracker
Closes #500
Closes #501" ;;
    reference) body="## Tracker
See #$issue" ;;
    none) body="## Tracker
No tracker closure" ;;
    *) body="$mode" ;;
  esac
  python3 - "$body" <<'PY'
import json
import sys
print(json.dumps({
    "number": 42,
    "body": sys.argv[1],
    "state": "MERGED",
    "mergedAt": "2026-06-04T00:00:00Z",
}, separators=(",", ":")), end="")
PY
  exit 0
fi

if [ "$1 $2" = "issue view" ]; then
  issue="$3"
  state="${GH_STUB_ISSUE_STATE:-OPEN}"
  python3 - "$issue" "$state" <<'PY'
import json
import sys
issue, state = sys.argv[1], sys.argv[2]
print(json.dumps({
    "number": int(issue),
    "title": f"Tracker item {issue}",
    "state": state,
    "url": f"https://github.example/issues/{issue}",
}, separators=(",", ":")), end="")
PY
  exit 0
fi

if [ "$1 $2" = "issue close" ]; then
  exit 0
fi

echo "unexpected gh call: $*" >&2
exit 2
GH
chmod +x "$BIN/gh"

cat > "$BIN/az" <<'AZ'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${AZ_LOG:?}"
if [ "$1 $2" = "devops -h" ] || [ "$1 $2" = "boards -h" ] || [ "$1 $2" = "repos -h" ]; then
  exit 0
fi
if [ "$1 $2 $3" = "devops configure --list" ]; then
  printf 'organization = https://dev.azure.com/example\nproject = Demo\n'
  exit 0
fi
if [ "$1 $2 $3 $4" = "repos pr work-item list" ]; then
  printf '%s\n' '[{"id":500,"fields":{"System.Title":"ADO tracker item","System.State":"Active"},"url":"https://dev.azure.com/example/Demo/_apis/wit/workItems/500"}]'
  exit 0
fi
if [ "$1 $2 $3" = "boards work-item show" ]; then
  printf '%s\n' '{"id":500,"fields":{"System.Title":"ADO tracker item","System.Description":"Body","System.State":"Active"},"_links":{"html":{"href":"https://dev.azure.com/example/Demo/_workitems/edit/500"}}}'
  exit 0
fi
if [ "$1 $2 $3" = "boards work-item update" ]; then
  exit 0
fi
echo "unexpected az call: $*" >&2
exit 2
AZ
chmod +x "$BIN/az"

run_target() {
  ( cd "$REPO_ROOT" && PATH="$BIN:$PATH" "$TARGET" "$@" )
}

if [ ! -x "$TARGET" ]; then
  fail_case "helper exists" "missing executable: $TARGET"
  exit 1
fi

closeable="$(run_target classify --pr 42 --issue 500)"
assert_json "CTC-1: GitHub close intent plus open issue is closeable" \
  "$closeable" \
  'length == 1 and .[0].status == "closeable" and .[0].provider == "github" and .[0].intent == "close" and .[0].verification == "supported" and .[0].issue_number == "500"'

no_confirm_log="$FIX/no-confirm-gh.log"; : > "$no_confirm_log"
GH_LOG="$no_confirm_log" run_target close --pr 42 --issue 500 >/tmp/ctc-no-confirm.out 2>/tmp/ctc-no-confirm.err
rc=$?
if [ "$rc" -eq 1 ] && ! grep -q 'issue close' "$no_confirm_log"; then
  pass "CTC-3: missing confirmation exits 1 and does not close"
else
  fail_case "CTC-3: missing confirmation exits 1 and does not close" "rc=$rc log=$(cat "$no_confirm_log")"
fi

confirm_log="$FIX/confirm-gh.log"; : > "$confirm_log"
confirm_out="$(GH_LOG="$confirm_log" run_target close --pr 42 --issue 500 --confirm-close)"
rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$confirm_out" | jq -e '.status == "closeable"' >/dev/null \
   && grep -q 'issue close 500 --reason completed --comment Closed by Arboretum cleanup after verifying merged PR #42 completed this work.' "$confirm_log" \
   && grep -q 'Evidence: Merged PR #42 declares close intent for #500' "$confirm_log"; then
  pass "CTC-2: confirmed close calls roadmap close with evidence"
else
  fail_case "CTC-2: confirmed close calls roadmap close with evidence" "rc=$rc out=[$confirm_out] log=$(cat "$confirm_log")"
fi

closed="$(GH_STUB_ISSUE_STATE=CLOSED run_target classify --pr 42 --issue 500)"
assert_json "CTC-4: already closed issue is reported" \
  "$closed" \
  '.[0].status == "already-closed" and .[0].issue_state == "CLOSED"'

ambiguous="$(GH_STUB_PR_MODE=reference run_target classify --pr 42 --issue 500)"
assert_json "CTC-5: reference-only intent is ambiguous" \
  "$ambiguous" \
  '.[0].status == "ambiguous" and .[0].intent == "reference"'

ado_open="$(ROADMAP_BACKEND=azure-devops run_target classify --pr 42 --issue 500)"
assert_json "CTC-6: ADO open linked work item remains unknown" \
  "$ado_open" \
  '.[0].status == "unknown" and .[0].provider == "azure-devops" and .[0].verification == "unknown" and (.[0].reason | test("not closed"))'

multi="$(GH_STUB_PR_MODE=multi run_target classify --pr 42 --issue 500 --issue 501)"
assert_json "CTC-7: multiple candidates classify independently" \
  "$multi" \
  'length == 2 and .[0].status == "closeable" and .[1].status == "closeable"'

run_target close --pr 42 --issue 500 --issue 501 --confirm-close >/tmp/ctc-multi-close.out 2>/tmp/ctc-multi-close.err
rc=$?
if [ "$rc" -eq 1 ]; then
  pass "CTC-7: close rejects multiple issues"
else
  fail_case "CTC-7: close rejects multiple issues" "rc=$rc out=$(cat /tmp/ctc-multi-close.out) err=$(cat /tmp/ctc-multi-close.err)"
fi

[ "$fail" -eq 0 ] && echo "cleanup-tracker-closure contract: ALL PASS" || exit 1
