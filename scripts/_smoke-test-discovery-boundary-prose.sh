#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# _smoke-test-discovery-boundary-prose.sh — Guards the codified discovery boundary
# (#667): when a skill does discovery via the deterministic document-access scripts
# vs. delegates to a read-only Explore-style subagent. The invariant lives once in
# skill-and-agent-authoring.spec.md, as the read-side sibling to the fresh-context
# driver-dispatch (execution-side) idiom.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "run with bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { echo "PASS: $1"; }

SPEC="docs/specs/skill-and-agent-authoring.spec.md"

# In a non-dev checkout (public sync / marketplace staging) the governed spec
# this guard protects is excluded — docs/specs/ is dev-only — so there is
# nothing to guard. Skip cleanly rather than fail when the spec is absent; in
# arbo-dev the spec is always present and every assertion runs in full. (Without
# this, ci-checks.sh treats this plugin-only test as applicable in a staged
# plugin root and it would fail on the missing spec — #667 Codex review.)
[ -f "$SPEC" ] || { echo "SKIP: $0 — $SPEC absent (dev-only governed spec not in this checkout)"; exit 0; }

# (a) The canonical subsection exists.
grep -q '^### Discovery: Explore vs document-access' "$SPEC" \
  || fail "canonical '### Discovery: Explore vs document-access' section missing from $SPEC"
ok "single-source discovery boundary section present"

# Scope every body assertion to the subsection itself — from its '### Discovery'
# heading up to (not including) the next '### '/'## ' heading. Without this the
# greps would also see the Tests-section bullet that *describes* this test, so
# deleting the guarded prose would still pass on the self-description (the
# false-pass the #667 correctness review caught). Flatten newlines so wrapped
# phrases aren't hostage to the column an author wrapped at.
SECTION_FLAT="$(awk '
  /^### Discovery: Explore vs document-access[[:space:]]*$/ { cap=1; next }
  cap && /^(###|##) / { exit }
  cap { print }
' "$SPEC" | tr '\n' ' ')"
[ -n "$SECTION_FLAT" ] || fail "could not extract '### Discovery' section body from $SPEC"

# (b) Cross-tool degradation rule: Explore degrades to deterministic search off
# Claude Code. Match 'degrade' near a deterministic-search token.
printf '%s' "$SECTION_FLAT" | grep -Eqi 'degrade[^.]*(grep|explore-doc|deterministic)' \
  || fail "cross-tool degradation rule (Explore → bounded grep/explore-doc off Claude Code) missing from $SPEC"
ok "cross-tool degradation rule present"

# (c) Exact / governance-critical reads are never delegated to an inference-based
# explorer. Anchor on the distinctive phrase 'inference-based explorer', which
# appears only in the invariant — not in any section self-description — so the
# guard genuinely fails if the invariant prose is removed or reworded away.
printf '%s' "$SECTION_FLAT" | grep -Eqi 'never[^.]*delegat[^.]*inference-based explorer' \
  || fail "exact/governance-reads-never-delegated invariant missing from $SPEC § Discovery"
ok "exact-reads-never-delegated invariant present"

echo "ALL PASS: discovery boundary prose"
