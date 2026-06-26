#!/usr/bin/env bash
# owner: intake-report
# scope: plugin-only
# ci-parallel: serial
# Smoke test for the WS7 Stage 1 report skill and public form mirror.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/report/SKILL.md"
PROBLEM="$ROOT/skills/report/templates/problem.md"
ENHANCEMENT="$ROOT/skills/report/templates/enhancement.md"
FORM_PROBLEM="$ROOT/.github/ISSUE_TEMPLATE/arboretum-problem.md"
FORM_ENHANCEMENT="$ROOT/.github/ISSUE_TEMPLATE/arboretum-enhancement.md"
SYNC="$ROOT/.github/workflows/sync-public.yml"

fail() {
  echo "FAIL report-skill: $1" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: ${1#"$ROOT/"}"
}

assert_grep() {
  local pattern="$1" file="$2" message="$3"
  grep -qE -- "$pattern" "$file" || fail "$message (${file#"$ROOT/"})"
}

assert_file "$SKILL"
assert_file "$PROBLEM"
assert_file "$ENHANCEMENT"
assert_file "$FORM_PROBLEM"
assert_file "$FORM_ENHANCEMENT"

assert_grep '^name:[[:space:]]*report$' "$SKILL" "skill frontmatter name must be report"
assert_grep '^owner:[[:space:]]*intake-report$' "$SKILL" "skill owner must resolve to intake-report"
assert_grep 'disable-model-invocation:[[:space:]]*false' "$SKILL" "skill must be model-invocable"
assert_grep 'plugin\.json|plugin manifest' "$SKILL" "skill must derive target repo from plugin metadata"
assert_grep 'CLAUDE_PLUGIN_ROOT' "$SKILL" "skill must resolve plugin metadata from the installed plugin root"
assert_grep 'complete raw issue body|full raw issue body' "$SKILL" "skill must show complete raw body"
assert_grep 'redaction' "$SKILL" "skill must include redaction pass"
assert_grep 'explicit approval' "$SKILL" "skill must require explicit approval"
assert_grep 'Never auto-file|never auto-files|Do not auto-file' "$SKILL" "skill must prohibit auto-filing"
assert_grep 'roadmap_tracker_issue_create|gh issue create' "$SKILL" "skill must name a filing mechanism"
if grep -q 'removesuffix' "$SKILL"; then
  fail "skill must avoid Python 3.9-only str.removesuffix()"
fi

for template in "$PROBLEM" "$ENHANCEMENT"; do
  assert_grep '<!-- arboretum-intake-report' "$template" "template must include metadata marker"
  for field in schema_version report_type generated_at source arboretum runtime surface failure privacy redaction_reviewed; do
    assert_grep "\"$field\"" "$template" "template missing metadata field $field"
  done
  assert_grep '^## Summary' "$template" "template must include Summary section"
  assert_grep '^## Expected' "$template" "template must include Expected section"
  assert_grep '^## Context' "$template" "template must include Context section"
done

assert_grep '"report_type":[[:space:]]*"problem"' "$PROBLEM" "problem template report_type must be problem"
assert_grep '"report_type":[[:space:]]*"enhancement"' "$ENHANCEMENT" "enhancement template report_type must be enhancement"

for template in "$PROBLEM" "$ENHANCEMENT"; do
  block="$(sed -n '/<!-- arboretum-intake-report/,/-->/p' "$template")"
  if printf '%s\n' "$block" | grep -qE '":[[:space:]]*"\{\{[^}]+\}\}"'; then
    fail "metadata placeholders must be pre-rendered with JSON encoding (${template#"$ROOT/"})"
  fi
done

for field in generated_at source_repository repository_visibility project_archetype arboretum_version plugin_repository agent agent_version os surface_kind surface_name error_signature; do
  assert_grep "\{\{${field}_json\}\}" "$PROBLEM" "problem template missing JSON placeholder ${field}_json"
  assert_grep "\{\{${field}_json\}\}" "$ENHANCEMENT" "enhancement template missing JSON placeholder ${field}_json"
done
assert_grep '\{\{reproducibility_json\}\}' "$PROBLEM" "problem template missing JSON placeholder reproducibility_json"

assert_grep '^labels:.*type:bug' "$FORM_PROBLEM" "problem form must carry type:bug"
assert_grep '^labels:.*type:feature' "$FORM_ENHANCEMENT" "enhancement form must carry type:feature"
for form in "$FORM_PROBLEM" "$FORM_ENHANCEMENT"; do
  assert_grep 'arboretum-intake-report' "$form" "form must mention the metadata marker"
  assert_grep 'public' "$form" "form must warn that reports are public"
  assert_grep 'Skill template source of truth|skill templates remain the source of truth' "$form" "form must not become schema authority"
done

assert_grep 'arboretum-problem\.md' "$SYNC" "public sync must copy problem report form"
assert_grep 'arboretum-enhancement\.md' "$SYNC" "public sync must copy enhancement report form"
assert_grep '--exclude=.*\.github/' "$SYNC" "public sync should still exclude .github by default"

echo "PASS report skill"
