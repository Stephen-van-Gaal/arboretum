#!/usr/bin/env bash
# owner: arboretum-as-plugin
#
# Smoke test for bump-version.sh and check-version-bump.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUMP="$SCRIPT_DIR/bump-version.sh"
CHECK="$SCRIPT_DIR/check-version-bump.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_manifests() {
  # $1 = dir, $2 = version
  mkdir -p "$1/.claude-plugin"
  cat > "$1/.claude-plugin/plugin.json" <<EOF
{
  "name": "arboretum",
  "version": "$2"
}
EOF
  cat > "$1/.claude-plugin/marketplace.json" <<EOF
{
  "name": "arboretum",
  "version": "$2",
  "plugins": [
    {
      "name": "arboretum",
      "version": "$2"
    }
  ]
}
EOF
}

read_v() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1"; }
read_mp() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"][0]["version"])' "$1"; }

git_fixture() {
  # $1 = dir; a git repo with manifests at 1.0.0 plus: a shippable file
  # (skills/demo/SKILL.md), a dev-only file (docs/specs/demo.spec.md), a
  # public-mirror source (CLAUDE.public.md — shippable), a root README.md
  # (dev-only), a prefix-collision path (CLAUDE.md.bak), a dev-only skill
  # (.claude/skills/dev-demo) and a shippable one (.claude/skills/shipped).
  # Base commit captured on branch `base-ref`.
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "test"
  make_manifests "$d" "1.0.0"
  mkdir -p "$d/skills/demo" "$d/docs/specs" \
    "$d/.claude/skills/dev-demo" "$d/.claude/skills/shipped"
  echo "demo skill" > "$d/skills/demo/SKILL.md"
  echo "demo spec" > "$d/docs/specs/demo.spec.md"
  echo "public claude source" > "$d/CLAUDE.public.md"
  echo "dev readme" > "$d/README.md"
  echo "stray backup" > "$d/CLAUDE.md.bak"
  echo "dev skill" > "$d/.claude/skills/dev-demo/SKILL.md"
  echo "shipped skill" > "$d/.claude/skills/shipped/SKILL.md"
  git -C "$d" add -A
  git -C "$d" commit -qm "base"
  git -C "$d" branch -q base-ref
}

echo "=== bump-version.sh: patch increments all three spots ==="
D="$TMP/patch"; make_manifests "$D" "1.2.3"
REPO_ROOT="$D" bash "$BUMP" patch >/dev/null
[ "$(read_v "$D/.claude-plugin/plugin.json")" = "1.2.4" ] || fail "plugin.json patch"
[ "$(read_v "$D/.claude-plugin/marketplace.json")" = "1.2.4" ] || fail "marketplace.json patch"
[ "$(read_mp "$D/.claude-plugin/marketplace.json")" = "1.2.4" ] || fail "marketplace plugins[0] patch"

echo "=== bump-version.sh: minor resets patch ==="
D="$TMP/minor"; make_manifests "$D" "1.2.3"
REPO_ROOT="$D" bash "$BUMP" minor >/dev/null
[ "$(read_v "$D/.claude-plugin/plugin.json")" = "1.3.0" ] || fail "minor"

echo "=== bump-version.sh: major resets minor and patch ==="
D="$TMP/major"; make_manifests "$D" "1.2.3"
REPO_ROOT="$D" bash "$BUMP" major >/dev/null
[ "$(read_v "$D/.claude-plugin/plugin.json")" = "2.0.0" ] || fail "major"

echo "=== bump-version.sh: rejects an invalid argument ==="
D="$TMP/bad"; make_manifests "$D" "1.2.3"
if REPO_ROOT="$D" bash "$BUMP" sideways >/dev/null 2>&1; then fail "should reject bad arg"; fi

echo "=== bump-version.sh: rejects manifests that disagree before bump ==="
D="$TMP/disagree"; make_manifests "$D" "1.2.3"
python3 - "$D/.claude-plugin/marketplace.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["version"] = "9.9.9"
json.dump(d, open(p, "w"), indent=2)
PY
if REPO_ROOT="$D" bash "$BUMP" patch >/dev/null 2>&1; then fail "should reject disagreeing manifests"; fi

echo "=== bump-version.sh: preserves non-ASCII characters ==="
D="$TMP/utf8"; make_manifests "$D" "1.2.3"
python3 - "$D/.claude-plugin/marketplace.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["description"] = "arboretum — em dash"
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
REPO_ROOT="$D" bash "$BUMP" patch >/dev/null
if grep -qF '\u' "$D/.claude-plugin/marketplace.json"; then
  fail "bump-version escaped a non-ASCII character"
fi

echo "=== check-version-bump.sh: dev-only change passes without a bump ==="
D="$TMP/check-devonly"; git_fixture "$D"
echo "more" >> "$D/docs/specs/demo.spec.md"
git -C "$D" add -A; git -C "$D" commit -qm "spec edit"
REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null || fail "dev-only should pass"

echo "=== check-version-bump.sh: shippable change without a bump fails ==="
D="$TMP/check-noshippable"; git_fixture "$D"
echo "more" >> "$D/skills/demo/SKILL.md"
git -C "$D" add -A; git -C "$D" commit -qm "skill edit"
if REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null 2>&1; then
  fail "shippable change without bump should fail"
fi

echo "=== check-version-bump.sh: shippable change with a bump passes ==="
D="$TMP/check-bump"; git_fixture "$D"
echo "more" >> "$D/skills/demo/SKILL.md"
REPO_ROOT="$D" bash "$BUMP" minor >/dev/null
git -C "$D" add -A; git -C "$D" commit -qm "skill edit + bump"
REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null || fail "shippable + bump should pass"

echo "=== check-version-bump.sh: disagreeing versions fail ==="
D="$TMP/check-disagree"; git_fixture "$D"
python3 - "$D/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["version"] = "5.5.5"
json.dump(d, open(p, "w"), indent=2)
PY
git -C "$D" add -A; git -C "$D" commit -qm "break consistency"
if REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null 2>&1; then
  fail "disagreeing versions should fail"
fi

echo "=== check-version-bump.sh: public-mirror source (CLAUDE.public.md) is shippable ==="
D="$TMP/check-public"; git_fixture "$D"
echo "more" >> "$D/CLAUDE.public.md"
git -C "$D" add -A; git -C "$D" commit -qm "edit CLAUDE.public.md"
if REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null 2>&1; then
  fail "CLAUDE.public.md change without a bump should fail — sync-public.yml copies it to the published CLAUDE.md"
fi

echo "=== check-version-bump.sh: root README.md is dev-only ==="
D="$TMP/check-readme"; git_fixture "$D"
echo "more" >> "$D/README.md"
git -C "$D" add -A; git -C "$D" commit -qm "edit README.md"
REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null \
  || fail "root README.md change should pass without a bump — sync overwrites it from README.public.md"

echo "=== check-version-bump.sh: a prefix-collision path is not exempt ==="
D="$TMP/check-anchor"; git_fixture "$D"
echo "more" >> "$D/CLAUDE.md.bak"
git -C "$D" add -A; git -C "$D" commit -qm "edit CLAUDE.md.bak"
if REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null 2>&1; then
  fail "CLAUDE.md.bak change without a bump should fail — the CLAUDE.md pattern is \$-anchored"
fi

echo "=== check-version-bump.sh: .claude/skills/dev-* is dev-only ==="
D="$TMP/check-skills-dev"; git_fixture "$D"
echo "more" >> "$D/.claude/skills/dev-demo/SKILL.md"
git -C "$D" add -A; git -C "$D" commit -qm "edit dev skill"
REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null \
  || fail ".claude/skills/dev-* change should pass without a bump"

echo "=== check-version-bump.sh: non-dev .claude/skills/ paths are shippable ==="
D="$TMP/check-skills-shipped"; git_fixture "$D"
echo "more" >> "$D/.claude/skills/shipped/SKILL.md"
git -C "$D" add -A; git -C "$D" commit -qm "edit shipped skill"
if REPO_ROOT="$D" BASE_REF=base-ref bash "$CHECK" >/dev/null 2>&1; then
  fail ".claude/skills/shipped change without a bump should fail — sync-public.yml excludes only dev-*/_archived/"
fi

echo "ALL PASS"
