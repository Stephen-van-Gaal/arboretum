#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# Contract test for docs/contracts/pr-readiness.cli-contract.md.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBE="$SCRIPT_DIR/pr-readiness.sh"
CONTRACT="$ROOT/docs/contracts/pr-readiness.cli-contract.md"
fail=0

pass() { echo "PASS: $1"; }
note() { echo "FAIL: $1" >&2; fail=1; }

[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }
[ -f "$CONTRACT" ] || { echo "FAIL: $CONTRACT not found" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALL_LOG:?}"
case "$1 $2" in
  "pr view")
    printf '{"isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"h1","baseRefOid":"b1"}'
    exit 0 ;;
  "pr checks")
    printf '[{"name":"ci","bucket":"pass","state":"SUCCESS"}]'
    exit 0 ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
GH
chmod +x "$tmp/bin/gh"

out="$(PATH="$tmp/bin:$PATH" SHIP_BACKEND=github GH_CALL_LOG="$tmp/gh.log" bash "$PROBE" remote 42 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [[ "$out" == readiness=* ]]; then
  pass PRR-1
else
  note "PRR-1/2 expected readiness output, rc=$rc out=$out"
fi

for key in readiness reason next_action ci head_sha base_sha; do
  if [[ "$out" == *"$key="* ]]; then
    pass "PRR-2 key $key"
  else
    note "PRR-2 missing $key in: $out"
  fi
done

if [[ "$out" == *"mergeable="* || "$out" == *"merge_state="* || "$out" == *"raw_mergeable="* || "$out" == *"raw_merge_state="* ]]; then
  note "PRR-8 default output contains raw provider keys: $out"
else
  pass PRR-8
fi

reason=$(printf '%s\n' "$out" | tr ' ' '\n' | sed -n 's/^reason=//p')
next_action=$(printf '%s\n' "$out" | tr ' ' '\n' | sed -n 's/^next_action=//p')
ci=$(printf '%s\n' "$out" | tr ' ' '\n' | sed -n 's/^ci=//p')
grep -q -- "- \`$reason\`" "$CONTRACT" || note "PRR-3 reason not in contract: $reason"
grep -q -- "- \`$next_action\`" "$CONTRACT" || note "PRR-7 next_action not in contract: $next_action"
grep -q -- "- \`$ci\`" "$CONTRACT" || note "PRR-2 ci not in contract: $ci"

out="$(bash "$PROBE" wat 42 2>/dev/null)"; rc=$?
[ "$rc" -ne 0 ] && pass PRR-6 || note "PRR-6 unexpected subcommand should fail"

: > "$tmp/gh.log"
out="$(PATH="$tmp/bin:$PATH" SHIP_BACKEND=azure-devops GH_CALL_LOG="$tmp/gh.log" bash "$PROBE" remote 42 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && [[ "$out" == readiness=unknown* ]] \
   && [[ "$out" == *"reason=unsupported-backend"* ]] \
   && [[ "$out" == *"next_action=escalate"* ]] \
   && [ ! -s "$tmp/gh.log" ]; then
  pass PRR-7
else
  note "PRR-7 ADO unsupported should not call gh; rc=$rc out=$out gh=$(cat "$tmp/gh.log")"
fi

if [ "$fail" -eq 0 ]; then
  echo "pr-readiness contract: ALL PASS"
else
  exit 1
fi
