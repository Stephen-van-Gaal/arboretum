#!/usr/bin/env bash
# owner: pipeline-contracts-template
# contract: s9-stage-to-log-helper
# assertion: S9-6
# pipeline-version: v2
#
# Asserts: if the body edit succeeds and the comment post fails (or
# vice versa), the script exits non-zero with an error naming the
# failed operation. Tested via a mocked `gh` that fails on
# comment-post but succeeds on body-edit (and gh auth status).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib/assert.sh
. "$ROOT/tests/contracts/_lib/assert.sh"

# Create a mocked gh that succeeds on auth + body edit, fails on comment.
MOCK_DIR=$(mktemp -d)
cat > "$MOCK_DIR/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh — succeed on `auth status` and `issue edit`; fail on
# `issue comment` with exit 1 and a named-stderr error.
case "${1:-}" in
  auth)
    # `gh auth status` succeeds silently
    exit 0
    ;;
  issue)
    case "${2:-}" in
      view)
        # Return a body containing the marker block (the rewriter expects
        # to find an existing block to overwrite).
        echo '{"body": "<!-- pipeline-state:current-stage -->\n**Current stage:** /design\n<!-- /pipeline-state:current-stage -->\n"}'
        exit 0
        ;;
      edit)
        # Body edit succeeds.
        exit 0
        ;;
      comment)
        echo "mocked gh: comment-post failure" >&2
        exit 1
        ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$MOCK_DIR/gh"

# Use PATH to override gh.
export PATH="$MOCK_DIR:$PATH"

err_out=$(mktemp)
bash "$ROOT/scripts/log-stage.sh" 0 /build entered key=value 2>"$err_out"
rc=$?

# Cleanup mock dir before any further exit
rm -rf "$MOCK_DIR"

# S9 contract: exit code 3 = comment-post failure.
if [ "$rc" -ne 3 ]; then
  echo "FAIL: S9-6 — expected exit 3 (comment-post failure), got $rc" >&2
  cat "$err_out" >&2
  rm -f "$err_out"
  exit 1
fi
assertStderr "$err_out" "comment" "S9-6 stderr names comment-post failure" || { rm -f "$err_out"; exit 1; }

rm -f "$err_out"
pass "S9-6"
