#!/usr/bin/env bash
# owner: skill-and-agent-authoring
# scope: plugin-only
# resolve-stage-model.sh <skill-name> [--skills-root DIR] [--config FILE]
#
# Resolves a stage's effective model in fixed precedence and emits the concrete
# model id (or the literal SESSION_DEFAULT when no floor applies):
#
#   1. override — .arboretum.yml  workflow.stage_models.<skill-name>
#   2. floor    — skill frontmatter  default-model
#   3. fallback — SESSION_DEFAULT  (caller omits the model param: inherit session)
#
# An invalid family at any layer fails loud (propagates model-families.sh exit).
# Reads frontmatter/config via the shared yaml-lite parser; no new YAML dep.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YAML_LITE="$ROOT/scripts/lib/yaml-lite.sh"
source "$ROOT/scripts/lib/model-families.sh"

SKILL=""
SKILLS_ROOT="$ROOT/skills"
CONFIG="$ROOT/.arboretum.yml"
while [ $# -gt 0 ]; do
  case "$1" in
    --skills-root) SKILLS_ROOT="$2"; shift 2 ;;
    --config)      CONFIG="$2"; shift 2 ;;
    -*)            echo "resolve-stage-model: unknown flag '$1'" >&2; exit 2 ;;
    *)             SKILL="$1"; shift ;;
  esac
done
[ -n "$SKILL" ] || { echo "resolve-stage-model: missing <skill-name>" >&2; exit 2; }
# Validate the skill name: it indexes a frontmatter key and a regex pattern, so
# constrain it to a safe identifier. Closes regex-metachar / ReDoS surface for
# future callers and keeps the override grep pattern literal.
case "$SKILL" in
  *[!a-z0-9_-]*|'') echo "resolve-stage-model: invalid skill name '$SKILL' (want [a-z0-9_-]+)" >&2; exit 2 ;;
esac

family=""

# 1. Override — workflow.stage_models.<skill> (yaml-lite flattens to dotted keys).
# Capture yaml-lite's exit status separately from grep's: a *present* config that
# fails to parse must fail loud (honouring the "fail loud at any layer" contract),
# not silently drop the override layer (grep no-match is the only legitimate empty).
if [ -f "$CONFIG" ]; then
  cfg_parsed="$(bash "$YAML_LITE" file "$CONFIG" 2>/dev/null)" \
    || { echo "resolve-stage-model: cannot parse config '$CONFIG'" >&2; exit 2; }
  family="$(printf '%s\n' "$cfg_parsed" \
    | grep -E "^workflow\.stage_models\.${SKILL}=" \
    | head -n1 | cut -d= -f2- || true)"
fi

# 2. Floor — skill frontmatter default-model. Same fail-loud discipline: a present
# skill file whose frontmatter cannot be parsed is malformed, not floor-absent.
if [ -z "$family" ]; then
  skill_file="$SKILLS_ROOT/$SKILL/SKILL.md"
  if [ -f "$skill_file" ]; then
    fm_parsed="$(bash "$YAML_LITE" frontmatter "$skill_file" 2>/dev/null)" \
      || { echo "resolve-stage-model: cannot parse frontmatter of '$skill_file'" >&2; exit 2; }
    family="$(printf '%s\n' "$fm_parsed" \
      | grep -E '^default-model=' | head -n1 | cut -d= -f2- || true)"
  fi
fi

# 3. Fallback
[ -n "$family" ] || { echo "SESSION_DEFAULT"; exit 0; }

# Map family -> concrete id (fails loud on unknown family)
resolve_model_family "$family"
