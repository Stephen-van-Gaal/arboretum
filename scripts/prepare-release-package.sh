#!/usr/bin/env bash
# owner: arboretum-as-plugin
# Build a Release Package from pending release intents.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
BODY_DIR=""
SINCE_REF=""
CHECKPOINT_VERSION=""
DRY_RUN=0
PR_LIST_LIMIT="${RELEASE_PACKAGE_PR_LIMIT:-1000}"

usage() {
  cat >&2 <<'EOF'
usage: prepare-release-package.sh [--body-dir <path> | --since <ref>] [--checkpoint-version <semver>] [--dry-run]
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      BODY_DIR="$2"
      shift 2
      ;;
    --since)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SINCE_REF="$2"
      shift 2
      ;;
    --checkpoint-version)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      CHECKPOINT_VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "prepare-release-package: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ "$branch" != "main" ]; then
  echo "FAIL: prepare-release-package must run from main" >&2
  exit 1
fi

if [ -n "$BODY_DIR" ] && [ -n "$SINCE_REF" ]; then
  echo "prepare-release-package: choose --body-dir or --since, not both" >&2
  exit 2
fi

if [ -n "$BODY_DIR" ] && [ ! -d "$BODY_DIR" ]; then
  echo "prepare-release-package: body dir not found: $BODY_DIR" >&2
  exit 2
fi

case "$PR_LIST_LIMIT" in
  ''|*[!0-9]*|0)
    echo "prepare-release-package: RELEASE_PACKAGE_PR_LIMIT must be a positive integer" >&2
    exit 2
    ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

latest_release_version() {
  python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
versions = []
release_dir = root / "docs" / "releases"
if release_dir.is_dir():
    for path in release_dir.glob("v*.md"):
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)\.md", path.name)
        if match:
            versions.append(tuple(int(part) for part in match.groups()))
if versions:
    print(".".join(str(part) for part in sorted(versions)[-1]))
PY
}

manifest_version() {
  python3 - "$REPO_ROOT/.claude-plugin/plugin.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh)["version"])
PY
}

checkpoint="$(latest_release_version)"
if [ -z "$checkpoint" ]; then
  checkpoint="$CHECKPOINT_VERSION"
fi
if [ -z "$checkpoint" ]; then
  checkpoint="$(manifest_version)"
fi
current_manifest_version="$(manifest_version)"

released_numbers_file="$TMP/released-numbers"
python3 - "$REPO_ROOT" >"$released_numbers_file" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
release_dir = root / "docs" / "releases"
seen = set()
if release_dir.is_dir():
    for path in release_dir.glob("v*.md"):
        text = path.read_text(encoding="utf-8")
        seen.update(re.findall(r"PR #([0-9]+)", text))
for number in sorted(seen, key=lambda n: int(n)):
    print(number)
PY

if [ -n "$BODY_DIR" ]; then
  find "$BODY_DIR" -type f -name '*.md' | LC_ALL=C sort >"$TMP/body-files"
else
  BODY_DIR="$TMP/live-bodies"
  mkdir -p "$BODY_DIR"
  # shellcheck source=scripts/roadmap/lib.sh
  source "$SCRIPT_DIR/roadmap/lib.sh"
  list_json="$(roadmap_tracker_pr_list --state merged --limit "$PR_LIST_LIMIT" --json number,title,mergedAt)"
  python3 - "$list_json" "$SINCE_REF" "$REPO_ROOT" "$PR_LIST_LIMIT" >"$TMP/live-prs" <<'PY'
import json
import subprocess
import sys
from datetime import datetime

items = json.loads(sys.argv[1] or "[]")
since_ref = sys.argv[2]
repo_root = sys.argv[3]
limit = int(sys.argv[4])
since_dt = None
if since_ref:
    raw = subprocess.check_output(
        ["git", "-C", repo_root, "log", "-1", "--format=%cI", since_ref],
        text=True,
    ).strip()
    since_dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))

if len(items) >= limit:
    merged_dates = [
        datetime.fromisoformat(item["mergedAt"].replace("Z", "+00:00"))
        for item in items
        if item.get("mergedAt")
    ]
    oldest = min(merged_dates) if merged_dates else None
    if since_dt is None or oldest is None or oldest > since_dt:
        print(
            f"FAIL: merged PR collection reached limit {limit} before since cutoff",
            file=sys.stderr,
        )
        sys.exit(1)

for item in items:
    merged_at = item.get("mergedAt")
    if since_dt and merged_at:
        merged_dt = datetime.fromisoformat(merged_at.replace("Z", "+00:00"))
        if merged_dt <= since_dt:
            continue
    print(item.get("number", ""))
PY
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    body_json="$(roadmap_tracker_pr_show "$number" --json title,body)"
    python3 - "$body_json" "$BODY_DIR/$number.md" "$number" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
title = data.get("title") or f"PR {sys.argv[3]}"
body = data.get("body") or ""
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(f"title: {title}\n\n")
    fh.write(body)
    if not body.endswith("\n"):
        fh.write("\n")
PY
  done <"$TMP/live-prs"
  find "$BODY_DIR" -type f -name '*.md' | LC_ALL=C sort >"$TMP/body-files"
fi

entries_file="$TMP/pending-entries"
: >"$entries_file"

while IFS= read -r body_file; do
  [ -n "$body_file" ] || continue
  stem="$(basename "$body_file" .md)"
  if grep -Fxq "$stem" "$released_numbers_file"; then
    continue
  fi

  parse_out="$TMP/parse-out"
  parse_err="$TMP/parse-err"
  if ! bash "$SCRIPT_DIR/read-release-intent.sh" --body-file "$body_file" >"$parse_out" 2>"$parse_err"; then
    if grep -q 'release intent section missing' "$parse_err"; then
      continue
    fi
    cat "$parse_err" >&2
    exit 1
  fi
  impact="$(awk -F= '$1 == "release-impact" { print $2; exit }' "$parse_out")"
  state="$(awk -F= '$1 == "release-state" { print $2; exit }' "$parse_out")"
  if [ "$state" != "pending" ]; then
    continue
  fi
  case "$impact" in
    patch|minor|major) ;;
    *) continue ;;
  esac
  title="$(awk -F': *' 'tolower($1) == "title" { print substr($0, index($0, ":") + 1); exit }' "$body_file" | sed 's/^ *//')"
  [ -n "$title" ] || title="PR $stem"
  title="$(printf '%s' "$title" | tr '|' '/')"
  printf '%s|%s|%s\n' "$stem" "$title" "$impact" >>"$entries_file"
done <"$TMP/body-files"

included_count="$(wc -l <"$entries_file" | tr -d ' ')"
if [ "$included_count" = "0" ]; then
  echo "FAIL: no pending release intents found" >&2
  exit 1
fi

impact="$(python3 - "$entries_file" <<'PY'
import sys

rank = {"patch": 1, "minor": 2, "major": 3}
selected = "patch"
with open(sys.argv[1], encoding="utf-8") as fh:
    for raw in fh:
        parts = raw.rstrip("\n").split("|")
        if len(parts) == 3 and rank[parts[2]] > rank[selected]:
            selected = parts[2]
print(selected)
PY
)"

next_version="$(python3 - "$checkpoint" "$impact" <<'PY'
import sys

version, impact = sys.argv[1], sys.argv[2]
major, minor, patch = (int(part) for part in version.split("."))
if impact == "major":
    major, minor, patch = major + 1, 0, 0
elif impact == "minor":
    minor, patch = minor + 1, 0
else:
    patch += 1
print(f"{major}.{minor}.{patch}")
PY
)"

echo "release-impact=$impact"
echo "checkpoint-version=$checkpoint"
echo "next-version=$next_version"
echo "included-count=$included_count"

if [ "$DRY_RUN" -eq 1 ]; then
  exit 0
fi

if [ "$current_manifest_version" != "$checkpoint" ]; then
  {
    echo "FAIL: checkpoint version $checkpoint does not match manifest version $current_manifest_version."
    echo "Run from an up-to-date main branch whose manifests reflect the last release checkpoint."
  } >&2
  exit 1
fi

BUMP="$REPO_ROOT/scripts/bump-version.sh"
[ -f "$BUMP" ] || BUMP="$SCRIPT_DIR/bump-version.sh"
REPO_ROOT="$REPO_ROOT" bash "$BUMP" "$impact"

materialized_version="$(manifest_version)"
if [ "$materialized_version" != "$next_version" ]; then
  {
    echo "FAIL: manifest version $materialized_version does not match computed next-version $next_version."
    echo "Release notes were not written."
  } >&2
  exit 1
fi

release_dir="$REPO_ROOT/docs/releases"
release_file="$release_dir/v$next_version.md"
mkdir -p "$release_dir"

{
  echo "# Arboretum v$next_version"
  echo ""
  echo "## Summary"
  echo ""
  echo "Release Package v$next_version materializes $impact changes since v$checkpoint."
  echo ""
  echo "## Included Changes"
  echo ""
  while IFS='|' read -r number title entry_impact; do
    [ -n "$number" ] || continue
    echo "- PR #$number - $title (\`$entry_impact\`)"
  done <"$entries_file"
  echo ""
  echo "## Upgrade Notes"
  echo ""
  echo "No special upgrade action required."
} >"$release_file"

python3 - "$REPO_ROOT/CHANGELOG.md" "$next_version" "$impact" "$included_count" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
version, impact, count = sys.argv[2], sys.argv[3], sys.argv[4]
entry = f"- [v{version}](docs/releases/v{version}.md) - {impact} release package with {count} changes."
if path.exists():
    lines = path.read_text(encoding="utf-8").splitlines()
else:
    lines = ["# Changelog"]
if not lines or lines[0] != "# Changelog":
    lines = ["# Changelog", ""] + lines
insert_at = 1
if len(lines) > 1 and lines[1] == "":
    insert_at = 2
lines = lines[:insert_at] + [entry, ""] + lines[insert_at:]
path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY

echo "release-notes=docs/releases/v$next_version.md"
