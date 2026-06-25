#!/usr/bin/env bash
# owner: pipeline-contracts-template
# scope: plugin-only
# Smoke test for docs/dev-contracts/release/bump-version.cli-contract.md.
# Exercises CLI-1..CLI-7 via fixture scenarios driving bump-version.sh
# against mktemp -d temp dirs (never the live repo). Picked up
# automatically by ci-checks.sh's === Smoke tests === loop.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUMP="$ROOT/dev-tools/release/bump-version.sh"

[ -f "$BUMP" ] || { echo "FAIL: script not found at $BUMP" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# make_manifests <dir> <version>
# Seeds $dir with the Claude and Codex plugin manifests, with the given
# version in all four locations that bump-version.sh rewrites.
make_manifests() {
  local d="$1" v="$2"
  mkdir -p "$d/.claude-plugin" "$d/.codex-plugin"
  python3 - "$d/.claude-plugin/plugin.json" "$v" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
data = {"name": "arboretum", "version": version}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
  python3 - "$d/.claude-plugin/marketplace.json" "$v" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
data = {
    "name": "arboretum",
    "version": version,
    "plugins": [{"name": "arboretum", "version": version}]
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
  python3 - "$d/.codex-plugin/plugin.json" "$v" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
data = {"name": "arboretum", "version": version}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

read_plugin_v()     { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1/.claude-plugin/plugin.json"; }
read_market_top_v() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1/.claude-plugin/marketplace.json"; }
read_market_p0_v()  { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"][0]["version"])' "$1/.claude-plugin/marketplace.json"; }
read_codex_v()      { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$1/.codex-plugin/plugin.json"; }

fail=0

# --------------------------------------------------------------------------
# Scenario A — CLI-1: patch increment updates all four occurrences.
# --------------------------------------------------------------------------
A="$TMP/a"; make_manifests "$A" "1.2.3"
OUT="$(REPO_ROOT="$A" bash "$BUMP" patch 2>/dev/null)"
RC=$?
PV="$(read_plugin_v "$A")"
MV="$(read_market_top_v "$A")"
MP="$(read_market_p0_v "$A")"
CV="$(read_codex_v "$A")"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: A — expected exit 0, got $RC" >&2; fail=1
elif [ "$PV" != "1.2.4" ] || [ "$MV" != "1.2.4" ] || [ "$MP" != "1.2.4" ] || [ "$CV" != "1.2.4" ]; then
  echo "FAIL: A — expected all occurrences 1.2.4; got plugin=$PV market_top=$MV market_p0=$MP codex=$CV" >&2; fail=1
elif [ "$OUT" != "1.2.3 -> 1.2.4" ]; then
  echo "FAIL: A — expected stdout '1.2.3 -> 1.2.4'; got '$OUT'" >&2; fail=1
else
  echo "PASS: A — patch increment (all four occurrences 1.2.3 -> 1.2.4)"
fi

# --------------------------------------------------------------------------
# Scenario B — CLI-2: minor increment resets patch to 0.
# --------------------------------------------------------------------------
B="$TMP/b"; make_manifests "$B" "1.2.3"
REPO_ROOT="$B" bash "$BUMP" minor >/dev/null 2>&1
PV="$(read_plugin_v "$B")"
if [ "$PV" != "1.3.0" ]; then
  echo "FAIL: B — expected 1.3.0, got $PV" >&2; fail=1
else
  echo "PASS: B — minor increment resets patch (1.2.3 -> 1.3.0)"
fi

# --------------------------------------------------------------------------
# Scenario C — CLI-3: major increment resets minor and patch to 0.
# --------------------------------------------------------------------------
C="$TMP/c"; make_manifests "$C" "1.2.3"
REPO_ROOT="$C" bash "$BUMP" major >/dev/null 2>&1
PV="$(read_plugin_v "$C")"
if [ "$PV" != "2.0.0" ]; then
  echo "FAIL: C — expected 2.0.0, got $PV" >&2; fail=1
else
  echo "PASS: C — major increment resets minor and patch (1.2.3 -> 2.0.0)"
fi

# --------------------------------------------------------------------------
# Scenario D — CLI-4: no git side effects after a successful bump.
# A temp dir with no git repo at all — bump must succeed without needing
# git, and must NOT create any git tag or commit. We verify by asserting
# the temp dir has no .git directory after the bump.
# --------------------------------------------------------------------------
D="$TMP/d"; make_manifests "$D" "0.1.0"
REPO_ROOT="$D" bash "$BUMP" patch >/dev/null 2>&1
if [ -d "$D/.git" ]; then
  echo "FAIL: D — bump-version.sh created a .git directory (unexpected git init or commit)" >&2; fail=1
else
  echo "PASS: D — no git side effects (no .git directory after bump)"
fi

# --------------------------------------------------------------------------
# Scenario E — CLI-5: bad argument rejected with non-zero exit.
# --------------------------------------------------------------------------
E="$TMP/e"; make_manifests "$E" "1.0.0"
if REPO_ROOT="$E" bash "$BUMP" sideways >/dev/null 2>&1; then
  echo "FAIL: E — bad argument 'sideways' should exit non-zero" >&2; fail=1
else
  echo "PASS: E — bad argument rejected (non-zero exit)"
fi

# Scenario E2 — missing argument also rejected.
E2="$TMP/e2"; make_manifests "$E2" "1.0.0"
if REPO_ROOT="$E2" bash "$BUMP" >/dev/null 2>&1; then
  echo "FAIL: E2 — missing argument should exit non-zero" >&2; fail=1
else
  echo "PASS: E2 — missing argument rejected (non-zero exit)"
fi

# --------------------------------------------------------------------------
# Scenario F — CLI-6: missing manifest file exits non-zero with error.
# We create the dir but omit plugin.json.
# --------------------------------------------------------------------------
F="$TMP/f"
mkdir -p "$F/.claude-plugin"
python3 - "$F/.claude-plugin/marketplace.json" "1.0.0" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
data = {"name": "arboretum", "version": version, "plugins": [{"name": "arboretum", "version": version}]}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
# plugin.json is intentionally absent
if REPO_ROOT="$F" bash "$BUMP" patch >/dev/null 2>&1; then
  echo "FAIL: F — missing plugin.json should exit non-zero" >&2; fail=1
else
  echo "PASS: F — missing manifest rejected (non-zero exit)"
fi

# --------------------------------------------------------------------------
# Scenario G — CLI-7: disagreeing manifests rejected without modifying files.
# Set marketplace.json top-level version to something different, then run.
# --------------------------------------------------------------------------
G="$TMP/g"; make_manifests "$G" "1.0.0"
python3 - "$G/.claude-plugin/marketplace.json" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path, encoding="utf-8"))
d["version"] = "9.9.9"   # deliberately break consistency
with open(path, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
if REPO_ROOT="$G" bash "$BUMP" patch >/dev/null 2>&1; then
  echo "FAIL: G — disagreeing manifests should exit non-zero" >&2; fail=1
else
  # Verify plugin.json was NOT modified (should still be 1.0.0).
  PV="$(read_plugin_v "$G")"
  if [ "$PV" != "1.0.0" ]; then
    echo "FAIL: G — bump modified plugin.json despite manifest disagreement (got $PV)" >&2; fail=1
  else
    echo "PASS: G — disagreeing manifests rejected without modifying files"
  fi
fi

# --------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED" >&2
  exit 1
fi
echo "SMOKE TEST PASSED"
exit 0
