#!/usr/bin/env bash
# owner: workflow-unification
# scope: plugin-only
# ci-parallel: safe
# Prose smoke: /finish documents a kind:shaping no-build mode that skips
# build-assuming sub-steps (build-exit gate, consolidate reconcile) instead
# of failing closed. Guards design #935 decision D3a.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/finish/SKILL.md"
fail=0
note() { echo "FAIL: $1"; fail=1; }

grep -qiE 'kind: ?shaping' "$SKILL" \
  || note "/finish does not mention a kind:shaping branch"
grep -qiE 'shaping-doc mode|no-build (mode|ship)|shaping.*skip' "$SKILL" \
  || note "/finish does not document a shaping-doc no-build mode"
# Must explicitly NOT fail closed when /build exited is absent on a shaping branch
grep -qiE 'absent|no .*/build.* exited|never ran /build|skip.*build-assuming' "$SKILL" \
  || note "/finish does not handle an absent /build-exited value for shaping docs"
# #935 C1: shaping-doc mode must open a READY (non-draft) PR so /pr's design-doc
# detection runs — a draft would defer the request to /land, which drops the class.
grep -qiE 'without .*--draft|ready .*\(non-draft\)|non-draft .*PR' "$SKILL" \
  || note "/finish shaping-doc mode does not specify a ready (non-draft) PR"

[ "$fail" -eq 0 ] && echo "PASS: finish-shaping-doc" || exit 1
