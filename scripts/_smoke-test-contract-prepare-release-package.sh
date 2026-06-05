#!/usr/bin/env bash
# owner: pipeline-contracts-template
# Smoke test for docs/dev-contracts/release/prepare-release-package.cli-contract.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/dev-tools/release/prepare-release-package.sh"
GIT_ID=(-c user.email=t@t -c user.name=t)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$SCRIPT" ] || { echo "FAIL: script not found at $SCRIPT" >&2; exit 1; }

fail=0

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" "${GIT_ID[@]}" init -q
  git -C "$repo" "${GIT_ID[@]}" checkout -q -b main
  mkdir -p "$repo/dev-tools/release"
  cat >"$repo/dev-tools/release/bump-version.sh" <<'BUMP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" > "${REPO_ROOT:?}/bump-version.called"
if [ "${BUMP_VERSION_STUB_MODE:-}" = "noop" ]; then
  exit 0
fi
python3 - "$REPO_ROOT" "$1" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
impact = sys.argv[2]
paths = [
    root / ".claude-plugin" / "plugin.json",
    root / ".claude-plugin" / "marketplace.json",
    root / ".codex-plugin" / "plugin.json",
]
data = [json.loads(path.read_text(encoding="utf-8")) for path in paths]
version = data[0]["version"]
major, minor, patch = (int(part) for part in version.split("."))
if impact == "major":
    major, minor, patch = major + 1, 0, 0
elif impact == "minor":
    minor, patch = minor + 1, 0
else:
    patch += 1
next_version = f"{major}.{minor}.{patch}"
for path, doc in zip(paths, data):
    doc["version"] = next_version
    if path.name == "marketplace.json":
        doc["plugins"][0]["version"] = next_version
    path.write_text(json.dumps(doc) + "\n", encoding="utf-8")
PY
BUMP
  chmod +x "$repo/dev-tools/release/bump-version.sh"
  mkdir -p "$repo/.claude-plugin" "$repo/.codex-plugin"
  printf '{"version":"0.24.7"}\n' > "$repo/.claude-plugin/plugin.json"
  printf '{"version":"0.24.7","plugins":[{"version":"0.24.7"}]}\n' \
    > "$repo/.claude-plugin/marketplace.json"
  printf '{"version":"0.24.7"}\n' > "$repo/.codex-plugin/plugin.json"
  git -C "$repo" "${GIT_ID[@]}" add dev-tools/release/bump-version.sh .claude-plugin .codex-plugin
  git -C "$repo" "${GIT_ID[@]}" commit -q -m "base"
}

write_body() {
  local path="$1" title="$2" impact="$3" state="$4"
  cat >"$path" <<BODY
title: $title

## Release Intent
release-impact: $impact
release-state: $state
BODY
}

REPO="$TMP/repo"
BODIES="$TMP/bodies"
init_repo "$REPO"
mkdir -p "$BODIES"
write_body "$BODIES/1.md" "Parser contract" patch pending
write_body "$BODIES/2.md" "Release | gate" minor pending
write_body "$BODIES/3.md" "Dev-only note" none not-needed

rc=0
out="$(REPO_ROOT="$REPO" bash "$SCRIPT" --body-dir "$BODIES" --checkpoint-version 0.24.7 --dry-run 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] \
   && echo "$out" | grep -Fxq 'release-impact=minor' \
   && echo "$out" | grep -Fxq 'next-version=0.25.0' \
   && echo "$out" | grep -Fxq 'included-count=2' \
   && [ ! -e "$REPO/docs/releases" ] \
   && [ ! -e "$REPO/CHANGELOG.md" ]; then
  echo "PASS: dry-run computes maximum impact and writes no package files"
else
  echo "FAIL: dry-run package calculation rc=$rc output=$out" >&2
  fail=1
fi

rc=0
out="$(RELEASE_PACKAGE_BUMP_SCRIPT="$REPO/dev-tools/release/bump-version.sh" REPO_ROOT="$REPO" bash "$SCRIPT" --body-dir "$BODIES" --checkpoint-version 0.24.7 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] \
   && [ -f "$REPO/docs/releases/v0.25.0.md" ] \
   && grep -q '# Arboretum v0.25.0' "$REPO/docs/releases/v0.25.0.md" \
   && grep -q 'PR #1 - Parser contract (`patch`)' "$REPO/docs/releases/v0.25.0.md" \
   && grep -q 'PR #2 - Release / gate (`minor`)' "$REPO/docs/releases/v0.25.0.md" \
   && grep -q 'No special upgrade action required.' "$REPO/docs/releases/v0.25.0.md" \
   && grep -q '\[v0.25.0\](docs/releases/v0.25.0.md)' "$REPO/CHANGELOG.md" \
   && grep -q '^minor$' "$REPO/bump-version.called" \
   && grep -q '"version": "0.25.0"' "$REPO/.claude-plugin/plugin.json"; then
  echo "PASS: package run writes release notes, changelog, and delegates bump"
else
  echo "FAIL: package artifact creation rc=$rc output=$out" >&2
  fail=1
fi

DRIFT="$TMP/drift"
init_repo "$DRIFT"
rc=0
out="$(REPO_ROOT="$DRIFT" bash "$SCRIPT" --body-dir "$BODIES" --checkpoint-version 0.24.6 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -q 'checkpoint version 0.24.6 does not match manifest version 0.24.7' \
   && [ ! -e "$DRIFT/bump-version.called" ]; then
  echo "PASS: checkpoint/manifest mismatch fails before bump"
else
  echo "FAIL: checkpoint/manifest mismatch should fail before bump; rc=$rc output=$out" >&2
  fail=1
fi

NOOP="$TMP/noop"
init_repo "$NOOP"
rc=0
out="$(BUMP_VERSION_STUB_MODE=noop RELEASE_PACKAGE_BUMP_SCRIPT="$NOOP/dev-tools/release/bump-version.sh" REPO_ROOT="$NOOP" bash "$SCRIPT" --body-dir "$BODIES" --checkpoint-version 0.24.7 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -q 'manifest version 0.24.7 does not match computed next-version 0.25.0' \
   && [ ! -e "$NOOP/docs/releases/v0.25.0.md" ]; then
  echo "PASS: post-bump manifest mismatch fails before release notes"
else
  echo "FAIL: post-bump mismatch should fail before release notes; rc=$rc output=$out" >&2
  fail=1
fi

MAT="$TMP/materialized"
mkdir -p "$MAT"
write_body "$MAT/4.md" "Already shipped" patch materialized
rc=0
out="$(REPO_ROOT="$REPO" bash "$SCRIPT" --body-dir "$MAT" --checkpoint-version 0.25.0 --dry-run 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no pending release intents found'; then
  echo "PASS: materialized intents are ignored"
else
  echo "FAIL: materialized-only body set should fail as no pending intents; rc=$rc output=$out" >&2
  fail=1
fi

NONE="$TMP/none"
mkdir -p "$NONE"
write_body "$NONE/5.md" "Dev-only" none not-needed
IF_NEEDED="$TMP/if-needed"
init_repo "$IF_NEEDED"
rc=0
out="$(RELEASE_PACKAGE_BUMP_SCRIPT="$IF_NEEDED/dev-tools/release/bump-version.sh" REPO_ROOT="$IF_NEEDED" bash "$SCRIPT" --body-dir "$NONE" --checkpoint-version 0.24.7 --if-needed 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] \
   && echo "$out" | grep -Fxq 'release-ready=no' \
   && [ ! -e "$IF_NEEDED/docs/releases" ] \
   && [ ! -e "$IF_NEEDED/CHANGELOG.md" ] \
   && [ ! -e "$IF_NEEDED/bump-version.called" ]; then
  echo "PASS: if-needed no-pending fixture exits cleanly"
else
  echo "FAIL: if-needed no-pending fixture should exit cleanly; rc=$rc output=$out" >&2
  fail=1
fi

rc=0
out="$(REPO_ROOT="$REPO" bash "$SCRIPT" --body-dir "$NONE" --checkpoint-version 0.25.0 --dry-run 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'no pending release intents found'; then
  echo "PASS: no-pending fixture fails clearly"
else
  echo "FAIL: no-pending fixture should fail; rc=$rc output=$out" >&2
  fail=1
fi

NONMAIN="$TMP/nonmain"
init_repo "$NONMAIN"
git -C "$NONMAIN" "${GIT_ID[@]}" checkout -q -b feature
rc=0
out="$(REPO_ROOT="$NONMAIN" bash "$SCRIPT" --body-dir "$BODIES" --checkpoint-version 0.24.7 --dry-run 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'must run from main'; then
  echo "PASS: non-main branch rejected"
else
  echo "FAIL: non-main branch should fail; rc=$rc output=$out" >&2
  fail=1
fi

LIVE="$TMP/live"
init_repo "$LIVE"
mkdir -p "$LIVE/scripts/roadmap"
cat >"$LIVE/scripts/roadmap/lib.sh" <<'ROADMAP'
roadmap_tracker_pr_list() {
  gh pr list "$@"
}

roadmap_tracker_pr_show() {
  number="$1"
  shift
  gh pr view "$number" "$@"
}
ROADMAP
GH_BIN="$TMP/gh-bin"
mkdir -p "$GH_BIN"
cat >"$GH_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1 $2" = "auth status" ]; then
  exit 0
fi
if [ "$1 $2" = "pr list" ]; then
  printf '[{"number":1,"title":"One","mergedAt":"2099-01-02T00:00:00Z"},{"number":2,"title":"Two","mergedAt":"2099-01-01T00:00:00Z"}]'
  exit 0
fi
if [ "$1 $2" = "pr view" ]; then
  printf '{"title":"unused","body":""}'
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$GH_BIN/gh"
rc=0
out="$(PATH="$GH_BIN:$PATH" RELEASE_PACKAGE_PR_LIMIT=2 REPO_ROOT="$LIVE" bash "$SCRIPT" --since HEAD --checkpoint-version 0.24.7 --dry-run 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q 'merged PR collection reached limit 2 before since cutoff'; then
  echo "PASS: live collection safety limit fails closed"
else
  echo "FAIL: live collection should fail closed at safety limit; rc=$rc output=$out" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
