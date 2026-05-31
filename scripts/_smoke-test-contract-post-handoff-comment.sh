#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-post-handoff-comment.sh — Contract test for
# docs/contracts/post-handoff-comment.contract.md. Asserts PHC-1..PHC-6
# against scripts/post-handoff-comment.sh.
#
# The producer posts via the roadmap tracker adapter. In the default GitHub
# backend that delegates to `gh issue comment <n> --body-file <tmp>`. We shadow
# PATH with a `gh` stub that captures the --body-file contents to $GH_CAPTURE so
# we can assert the marker + body shape without network.
# A GH_FAIL=1 env makes the stub exit nonzero to exercise the exit-2 path.
# PHC-2 round-trips the captured body through the *consumer's* regex
# (refresh-next-cache.sh's parser) to prove the marker is parseable.
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/post-handoff-comment.sh"
[ -f "$PROBE" ] || { echo "FAIL: $PROBE not found" >&2; exit 1; }

FIX=$(mktemp -d)
GH_STUB_DIR=$(mktemp -d)
trap 'rm -rf "$FIX" "$GH_STUB_DIR" "${NOGH_BIN:-}"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && echo "  $2" >&2; fail=1; }

# ── gh stub: capture the --body-file contents to $GH_CAPTURE ──────────
cat > "$GH_STUB_DIR/gh" <<'GH'
#!/usr/bin/env bash
# gh issue comment <issue> --body-file <path>
if [ "$1 $2" = "auth status" ]; then exit 0; fi
if [ "${GH_FAIL:-0}" != 0 ]; then echo "gh stub: simulated failure" >&2; exit 1; fi
bf=""
while [ $# -gt 0 ]; do
  case "$1" in --body-file) bf="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$bf" ] && [ -n "${GH_CAPTURE:-}" ] && cp "$bf" "$GH_CAPTURE"
exit 0
GH
chmod +x "$GH_STUB_DIR/gh"

BRANCH="feat/ws5-pr7a-full-shape-sweep"
NOTE="$FIX/note.md"
printf '→ Next action: open the next workstream PR\n\nFollow the WS5 sweep order; build the remaining contracts.\n' > "$NOTE"
CAP="$FIX/captured-body.txt"

run() { GH_CAPTURE="$CAP" PATH="$GH_STUB_DIR:$PATH" bash "$PROBE" "$@" 2>"$FIX/.err"; }

# PHC-1 — posts a body whose first line is the arbo-handoff marker w/ branch
rm -f "$CAP"
out=$(run 42 "$BRANCH" "$NOTE" "$FIX"); rc=$?
first_line=$(head -1 "$CAP" 2>/dev/null)
if [ "$rc" = 0 ] && [ -f "$CAP" ] \
   && [[ "$first_line" == "<!-- arbo-handoff: $BRANCH "*" -->" ]]; then pass PHC-1
else fail_case PHC-1 "rc=$rc first=[$first_line] err=$(cat "$FIX/.err")"; fi

# PHC-2 — captured body is round-trip-parseable by the consumer's regex
parsed=$(python3 - "$CAP" "$BRANCH" <<'PY'
import re, sys
body = open(sys.argv[1]).read()
want_branch = sys.argv[2]
m = re.search(r"<!--\s*arbo-handoff:\s*(\S+)\s+(\S+)\s*-->", body)
if not m:
    print("NOMATCH"); sys.exit(0)
branch, posted = m.group(1), m.group(2)
print("OK" if branch == want_branch and posted else f"BAD branch={branch} posted={posted}")
PY
)
[ "$parsed" = OK ] && pass PHC-2 || fail_case PHC-2 "parsed=$parsed"

# PHC-3 — the → Next action: line survives verbatim into the body
if grep -q '^→ Next action: open the next workstream PR$' "$CAP"; then pass PHC-3
else fail_case PHC-3 "next-action line missing from captured body"; fi

# PHC-4 — missing note-file → exit 1, no gh call (no capture written)
rm -f "$CAP"
out=$(run 42 "$BRANCH" "$FIX/does-not-exist.md" "$FIX"); rc=$?
[ "$rc" = 1 ] && [ ! -f "$CAP" ] && pass PHC-4 || fail_case PHC-4 "rc=$rc capture-exists=$( [ -f "$CAP" ] && echo yes || echo no )"

# PHC-5 — gh absent → exit 1
NOGH_BIN=$(mktemp -d)
for t in bash date mktemp cat rm git dirname; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOGH_BIN/$t" 2>/dev/null || true
done
out=$(PATH="$NOGH_BIN" bash "$PROBE" 42 "$BRANCH" "$NOTE" "$FIX" 2>/dev/null); rc=$?
[ "$rc" = 1 ] && pass PHC-5 || fail_case PHC-5 "rc=$rc out=$out"

# PHC-6 — tracker issue comment fails → exit 2
out=$(GH_FAIL=1 GH_CAPTURE="$CAP" PATH="$GH_STUB_DIR:$PATH" bash "$PROBE" 42 "$BRANCH" "$NOTE" "$FIX" 2>"$FIX/.err"); rc=$?
if [ "$rc" = 2 ] && grep -qi 'tracker issue comment failed' "$FIX/.err"; then pass PHC-6
else fail_case PHC-6 "rc=$rc err=$(cat "$FIX/.err")"; fi

[ "$fail" = 0 ] && echo "post-handoff-comment contract: ALL PASS" || exit 1
