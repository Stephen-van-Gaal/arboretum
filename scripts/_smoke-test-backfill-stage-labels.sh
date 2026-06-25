#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
# _smoke-test-backfill-stage-labels.sh — Verify scripts/backfill-stage-labels.sh
# (the #570 one-shot migration): for an OPEN issue whose body carries the legacy
# current-stage marker block, the script must (a) set the exclusive stage:* label
# from the BODY value and (b) rewrite the body with the block removed.
# Usage: bash scripts/_smoke-test-backfill-stage-labels.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "PASS: $1"; }

# A gh stub: dispatches on `$1 $2`, logs every (non-auth) call to $GH_STUB_LOG.
# `issue view` serves BOTH variants the run needs: `--json labels` (consumed by
# roadmap_set_prefix_exclusive_label) and `--json body` (consumed by the
# backfill's body-strip step). Dispatch on the substring as real gh would.
bindir="$tmp/bin"; mkdir -p "$bindir"
export GH_STUB_LOG="$tmp/gh.log"; : > "$GH_STUB_LOG"
cat > "$bindir/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
case "$1 $2" in
  "issue list")
    # Honor a trailing `--jq <filter>` the way real gh does, so the script's
    # `--jq '.[].number'` extraction yields the bare issue number (7).
    jq_filter=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jq_filter="$a"; prev="$a"; done
    if [ -n "$jq_filter" ]; then printf '[{"number":7}]' | jq -r "$jq_filter"
    else printf '[{"number":7}]'; fi
    exit 0 ;;
  "issue view")
    # Real gh applies `--jq` to the requested `--json` projection. The script
    # asks for `--json body --jq .body`, so emit just the body string (with the
    # marker block) for that variant; emit the bare label name for the labels
    # variant consumed by roadmap_set_prefix_exclusive_label.
    case "$*" in
      *"--json labels"*) printf 'stage:start\n'; exit 0 ;;
      *"--json body"*)   printf '<!-- pipeline-state:current-stage -->\n**Current stage:** /build\n<!-- /pipeline-state:current-stage -->\n\nReal body.\n'; exit 0 ;;
    esac ;;
  "issue edit") exit 0 ;;
  "label create") exit 0 ;;
esac
echo "unexpected gh call: $*" >&2; exit 2
GH
chmod +x "$bindir/gh"

repo="$tmp/repo"; mkdir -p "$repo"; ( cd "$repo" && git init -q && git remote add origin https://github.com/x/y.git )
PATH="$bindir:$PATH" bash "$REPO/scripts/backfill-stage-labels.sh" "$repo" >/dev/null

# (a) Label set from the BODY value (/build → stage:build), not the existing label.
grep -q 'issue edit 7 --add-label stage:build' "$GH_STUB_LOG" \
  || fail "did not set stage:build from body"
# (b) Body rewritten to strip the marker block.
grep -q 'issue edit 7 .*--body-file' "$GH_STUB_LOG" \
  || fail "did not rewrite body to strip block"
ok "backfill: label set + marker block stripped"

# Non-conforming stage token (/build2) must NOT partially match (/build) and
# migrate — the end-anchored regex skips it (reviewer finding, #570).
bindir2="$tmp/bin2"; mkdir -p "$bindir2"
export GH_STUB_LOG2="$tmp/gh2.log"; : > "$GH_STUB_LOG2"
cat > "$bindir2/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then exit 0; fi
printf '%s\n' "$*" >> "${GH_STUB_LOG2:?}"
case "$1 $2" in
  "issue list")
    jq_filter=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jq_filter="$a"; prev="$a"; done
    if [ -n "$jq_filter" ]; then printf '[{"number":8}]' | jq -r "$jq_filter"; else printf '[{"number":8}]'; fi
    exit 0 ;;
  "issue view")
    case "$*" in
      *"--json labels"*) printf '\n'; exit 0 ;;
      *"--json body"*)   printf '<!-- pipeline-state:current-stage -->\n**Current stage:** /build2\n<!-- /pipeline-state:current-stage -->\n\nReal body.\n'; exit 0 ;;
    esac ;;
  "issue edit") exit 0 ;;
  "label create") exit 0 ;;
esac
echo "unexpected gh call: $*" >&2; exit 2
GH
chmod +x "$bindir2/gh"
GH_STUB_LOG="$GH_STUB_LOG2" PATH="$bindir2:$PATH" bash "$REPO/scripts/backfill-stage-labels.sh" "$repo" >/dev/null
grep -q 'issue edit 8 --add-label stage:' "$GH_STUB_LOG2" \
  && fail "migrated a non-conforming /build2 stage token (should skip)"
ok "backfill: non-conforming /build2 token skipped (end-anchored regex)"
