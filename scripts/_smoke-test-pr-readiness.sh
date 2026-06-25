#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# Smoke test: pr-readiness.sh — fixture-driven readiness classification.
# Uses a PATH-shadowed gh stub and temp git repos so it never touches network.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/pr-readiness.sh"
fail=0

pass() { echo "PASS: $1"; }
note() { echo "FAIL: $1" >&2; fail=1; }

[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    case "${GH_CASE:-ready}" in
      draft)
        printf '{"isDraft":true,"mergeable":"MERGEABLE","mergeStateStatus":"DRAFT","headRefOid":"h-draft","baseRefOid":"b-draft"}' ;;
      ready)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"h-ready","baseRefOid":"b-ready"}' ;;
      conflict)
        printf '{"isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","headRefOid":"h-conflict","baseRefOid":"b-conflict"}' ;;
      blocked)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","headRefOid":"h-blocked","baseRefOid":"b-blocked"}' ;;
      behind)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BEHIND","headRefOid":"h-behind","baseRefOid":"b-behind"}' ;;
      unknown)
        printf '{"isDraft":false,"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","headRefOid":"h-unknown","baseRefOid":"b-unknown"}' ;;
      failing)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"h-failing","baseRefOid":"b-failing"}' ;;
      pending)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"h-pending","baseRefOid":"b-pending"}' ;;
      absent)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"h-absent","baseRefOid":"b-absent"}' ;;
      skipped)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"h-skipped","baseRefOid":"b-skipped"}' ;;
      checks_unavailable)
        printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"h-unavailable","baseRefOid":"b-unavailable"}' ;;
      *)
        echo "gh stub: unknown GH_CASE=${GH_CASE:-}" >&2; exit 97 ;;
    esac
    exit 0 ;;
  "pr checks")
    printf '%s\n' "${GH_CASE:-}" >> "${GH_CHECK_LOG:?}"
    case "${GH_CASE:-ready}" in
      ready)
        printf '[{"name":"ci","bucket":"pass","state":"SUCCESS"}]' ;;
      blocked)
        printf '[{"name":"ci","bucket":"pass","state":"SUCCESS"}]' ;;
      failing)
        printf '[{"name":"ci","bucket":"fail","state":"FAILURE"},{"name":"lint","bucket":"pass","state":"SUCCESS"}]' ;;
      pending)
        printf '[{"name":"ci","bucket":"pending","state":"PENDING"}]'
        exit 8 ;;
      absent)
        printf '[]' ;;
      skipped)
        printf '[{"name":"ci","bucket":"pass","state":"SUCCESS"},{"name":"draft_guard","bucket":"skipping","state":"SKIPPED"}]' ;;
      checks_unavailable)
        echo "api rate limit exceeded" >&2
        exit 1 ;;
      *)
        printf '[]' ;;
    esac
    exit 0 ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
GH
chmod +x "$tmp/bin/gh"

run_remote() {
  local case_name="$1"; shift
  PATH="$tmp/bin:$PATH" SHIP_BACKEND=github GH_CASE="$case_name" \
    GH_CHECK_LOG="$tmp/checks.log" READINESS_RETRY_SLEEP=0 \
    bash "$PROBE" remote 42 "$@"
}

assert_contains() {
  local label="$1" out="$2" needle="$3"
  if [[ "$out" == *"$needle"* ]]; then
    return 0
  fi
  note "$label missing '$needle' in: $out"
  return 1
}

assert_no_checks_called() {
  local label="$1"
  if [ ! -s "$tmp/checks.log" ]; then
    pass "$label"
  else
    note "$label should not call gh pr checks; log=$(cat "$tmp/checks.log")"
  fi
  : > "$tmp/checks.log"
}

: > "$tmp/checks.log"

out="$(run_remote draft --allow-draft 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "draft-clean exited $rc: $out"
assert_contains draft-clean "$out" "readiness=draft-clean"
assert_contains draft-clean "$out" "reason=draft-only"
assert_contains draft-clean "$out" "next_action=mark-ready"
assert_contains draft-clean "$out" "ci=not-checked"
assert_no_checks_called "draft-clean skips checks"

out="$(run_remote ready 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "ready exited $rc: $out"
assert_contains ready "$out" "readiness=ready"
assert_contains ready "$out" "reason=clean"
assert_contains ready "$out" "next_action=proceed"
assert_contains ready "$out" "ci=pass"
: > "$tmp/checks.log"

out="$(run_remote conflict 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "conflict exited $rc: $out"
assert_contains conflict "$out" "readiness=blocked"
assert_contains conflict "$out" "reason=merge-conflict"
assert_contains conflict "$out" "next_action=repair-conflicts"
assert_contains conflict "$out" "ci=not-checked"
assert_no_checks_called "conflict skips checks"

out="$(run_remote blocked 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "blocked exited $rc: $out"
assert_contains blocked "$out" "reason=merge-state-blocked"
assert_contains blocked "$out" "next_action=escalate"
: > "$tmp/checks.log"

out="$(run_remote behind 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "behind exited $rc: $out"
assert_contains behind "$out" "reason=merge-state-blocked"
assert_contains behind "$out" "next_action=escalate"
assert_contains behind "$out" "ci=not-checked"
assert_no_checks_called "behind skips checks"

out="$(run_remote unknown 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "unknown exited $rc: $out"
assert_contains unknown "$out" "readiness=unknown"
assert_contains unknown "$out" "reason=mergeability-unknown"
assert_contains unknown "$out" "next_action=retry-readiness"
assert_no_checks_called "unknown skips checks"

out="$(run_remote failing 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "failing exited $rc: $out"
assert_contains failing "$out" "readiness=blocked"
assert_contains failing "$out" "reason=ci-failing"
assert_contains failing "$out" "next_action=fix-ci"
assert_contains failing "$out" "failing_checks=ci"
: > "$tmp/checks.log"

out="$(run_remote pending 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "pending exited $rc: $out"
assert_contains pending "$out" "readiness=waiting"
assert_contains pending "$out" "reason=ci-pending"
assert_contains pending "$out" "next_action=wait-ci"
: > "$tmp/checks.log"

out="$(run_remote checks_unavailable 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "checks unavailable exited $rc: $out"
assert_contains checks-unavailable "$out" "readiness=unknown"
assert_contains checks-unavailable "$out" "reason=ci-unavailable"
assert_contains checks-unavailable "$out" "next_action=retry-readiness"
assert_contains checks-unavailable "$out" "ci=unknown"
: > "$tmp/checks.log"

out="$(run_remote skipped 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "skipped exited $rc: $out"
assert_contains skipped "$out" "readiness=unknown"
assert_contains skipped "$out" "reason=ci-absent"
assert_contains skipped "$out" "next_action=configure-ci"
: > "$tmp/checks.log"

out="$(run_remote absent 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "absent exited $rc: $out"
assert_contains absent "$out" "readiness=unknown"
assert_contains absent "$out" "reason=ci-absent"
assert_contains absent "$out" "next_action=configure-ci"
: > "$tmp/checks.log"

out="$(run_remote ready 2>&1)"
if [[ "$out" == *"mergeable="* || "$out" == *"merge_state="* || "$out" == *"raw_mergeable="* || "$out" == *"raw_merge_state="* ]]; then
  note "default output should omit raw provider keys: $out"
else
  pass "default output omits raw provider keys"
fi

out="$(PATH="$tmp/bin:$PATH" SHIP_BACKEND=github GH_CASE=ready GH_CHECK_LOG="$tmp/checks.log" READINESS_DEBUG=1 bash "$PROBE" remote 42 2>&1)"
assert_contains debug "$out" "raw_mergeable=MERGEABLE"
assert_contains debug "$out" "raw_merge_state=CLEAN"

out="$(SHIP_BACKEND=azure-devops GH_CHECK_LOG="$tmp/checks.log" PATH="$tmp/bin:$PATH" bash "$PROBE" remote 42 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "ado unsupported exited $rc: $out"
assert_contains ado "$out" "readiness=unknown"
assert_contains ado "$out" "reason=unsupported-backend"
assert_contains ado "$out" "next_action=escalate"
assert_contains ado "$out" "backend=azure-devops"

out="$(PATH="$tmp/bin:$PATH" SHIP_BACKEND=github GH_CASE=ready GH_CHECK_LOG="$tmp/checks.log" bash "$PROBE" remote abc 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  pass "nonnumeric PR exits 2"
else
  note "nonnumeric PR should exit 2, got rc=$rc out=$out"
fi

# Local clean/dirty checks in an isolated git repo.
repo="$tmp/repo"
mkdir "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Test User"
printf 'base\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m init
git -C "$repo" branch -M main
git -C "$repo" checkout -q -b feature
out="$(cd "$repo" && bash "$PROBE" local main 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "local clean exited $rc: $out"
assert_contains local-clean "$out" "readiness=ready"
assert_contains local-clean "$out" "reason=clean"
assert_contains local-clean "$out" "next_action=proceed"
mkdir -p "$repo/docs"
printf 'literal marker text\n<<<<<<< example\nchanged in both\n' > "$repo/docs/markers.md"
git -C "$repo" add docs/markers.md
git -C "$repo" commit -q -m markers
out="$(cd "$repo" && bash "$PROBE" local main 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "local clean marker text exited $rc: $out"
assert_contains local-clean-marker-text "$out" "readiness=ready"
assert_contains local-clean-marker-text "$out" "reason=clean"
git -C "$repo" checkout -q main
printf 'main\n' > "$repo/file.txt"
git -C "$repo" commit -am main -q
git -C "$repo" checkout -q feature
printf 'feature\n' > "$repo/file.txt"
git -C "$repo" commit -am feature -q
out="$(cd "$repo" && bash "$PROBE" local main 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "local conflict exited $rc: $out"
assert_contains local-conflict "$out" "readiness=blocked"
assert_contains local-conflict "$out" "reason=local-conflict"
assert_contains local-conflict "$out" "next_action=repair-local"
printf 'dirty\n' > "$repo/dirty.txt"
out="$(cd "$repo" && bash "$PROBE" local main 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || note "local dirty exited $rc: $out"
assert_contains local-dirty "$out" "readiness=blocked"
assert_contains local-dirty "$out" "reason=local-dirty"
assert_contains local-dirty "$out" "next_action=repair-local"

if [ "$fail" -eq 0 ]; then
  echo "PASS: pr-readiness"
else
  exit 1
fi
