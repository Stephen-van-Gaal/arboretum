#!/usr/bin/env bash
# owner: project-infrastructure
# uses: definitions/register-schema.md @v1
# uses: definitions/contracts-yaml-schema.md @v1
# uses: definitions/spec-status-state-machine.md @v1
# health-check.sh — Detect drift across the spec-driven workflow
#
# Requires bash 4+ (uses process substitution, arrays, [[ ]]).
#
# Usage:
#   ./scripts/health-check.sh [project-dir]
#
# Runs nine checks:
#   1. Governed documents exist (ARCHITECTURE, REGISTER, contracts, etc.)
#   2. Register vs. disk (do owned files exist?)
#   3. Unowned source files. Half A — framework owner-marker scan
#      (.sh/bin/ line-2 # owner:, SKILL.md owner: frontmatter), runs
#      register-independent. Half B — general source-ownership scan of
#      project source roots (*.py vs. spec owns: coverage), gated on a
#      compatible REGISTER.md schema.
#   4. contracts.yaml vs. spec Requires tables (are pins in sync?)
#   5. contracts.yaml vs. definition versions (are pins current?)
#   6. Spec status consistency. Canonical enum is draft/active/stale.
#      Projects can override via .arboretum.yml status_enum: — typos
#      then warn against the declared vocabulary. With no config and
#      richer states observed, a single info line acknowledges the
#      extended enum rather than flooding per-spec warnings.
#   7. Spec drift detection (auto-flips configured active_states →
#      configured stale_state when owned files are modified after the
#      spec's last commit). This is the only mutation; status is
#      structurally bounded so writing it is safe. Default canonical
#      vocabulary maps to active → stale. Unconfigured extended-enum
#      projects: auto-flip is a no-op; surface that explicitly so the
#      empty result isn't mysterious.
#   8. Plan files missing Tests section (advisory)
#   9. Strategic Anchor validity (section present, time horizon future,
#      in/out scope non-empty, cadence not overdue). Silent pass when
#      roadmap.config.yaml is absent.
#
# Produces a drift report. Mutates only spec status (Check 7).
# Exit code: 0 if healthy, 1 if drift detected.

set -euo pipefail

# Guard: fail if sourced or invoked with a non-bash shell (e.g. sh, dash)
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

PROJECT_DIR="${1:-$(pwd)}"
REGISTER="$PROJECT_DIR/docs/REGISTER.md"
CONTRACTS="$PROJECT_DIR/contracts.yaml"
DEFS_DIR="$PROJECT_DIR/docs/definitions"
SPECS_DIR="$PROJECT_DIR/docs/specs"

drift_found=false
check_count=0
issue_count=0

# ── Helpers ──────────────────────────────────────────────────────────

header() {
  echo ""
  echo "━━━ $1 ━━━"
  ((check_count++)) || true
}

ok() {
  echo "  ✓ $1"
}

warn() {
  echo "  ✗ $1"
  drift_found=true
  ((issue_count++)) || true
}

info() {
  echo "  · $1"
}

# O(N) membership test. Kept linear (not an associative array) because
# macOS ships bash 3.2, which lacks `declare -A`. N is typically <10
# (status states / active_states), so linear scan is fine.
_in_array() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# ── Status enum config ───────────────────────────────────────────────
#
# Defaults match the plugin's canonical vocabulary. A project can override
# by adding a status_enum: block to .arboretum.yml:
#
#   status_enum:
#     states: [draft, ready, in-progress, implemented, stale]
#     active_states: [implemented]   # subset eligible for Check 7 auto-flip
#     stale_state: stale             # written when flipping; omit to disable
#
# When `states:` is non-empty, the project is treated as having explicitly
# configured its vocabulary: Check 6 emits per-spec warnings for values
# outside `states:` (the typo-detection signal), and the unconfigured-path
# "extended enum no-op" info line is suppressed.
STATUS_STATES=(draft active stale)
STATUS_ACTIVE_STATES=(active)
STATUS_STALE_STATE="stale"
STATUS_ENUM_CONFIGURED=false

_read_status_enum() {
  local config="$PROJECT_DIR/.arboretum.yml"
  [ -f "$config" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  # Emit one fixed-prefix line per field, plus an ERROR: line if the
  # block is malformed. Pipe-joining inside the value is safe because
  # tokens are validated to [A-Za-z0-9_-]+ — pipes are explicitly
  # forbidden, so they can't collide with the field separator.
  #
  # Token validation happens here (at the parser boundary) rather than
  # being escaped at each sed/regex site downstream: the Check 7 flip
  # path edits both REGISTER.md and the spec frontmatter with separate
  # sed invocations, and any metachar that survived to a later site
  # could desync the two files. Rejecting bad tokens up front keeps the
  # downstream sed calls free of escaping logic and makes the failure
  # mode loud (block rejected, canonical defaults retained) instead of
  # silent (partial flip).
  local raw
  raw=$(python3 - "$config" <<'PYEOF' 2>/dev/null || true
import sys, re
path = sys.argv[1]
TOKEN_RE = re.compile(r'^[A-Za-z0-9_-]+$')

def _validate_list(name, raw):
    # raw must be a Python list of stringy scalars; reject scalars (e.g.
    # `states: draft` which iterates as 'd','r','a','f','t'), mappings,
    # and any token containing regex/sed metachars or pipe (the bash
    # reader's field separator).
    if raw is None:
        return [], None
    if not isinstance(raw, list):
        return None, f"status_enum.{name} must be a YAML list, got {type(raw).__name__}"
    out = []
    for x in raw:
        if isinstance(x, (dict, list)):
            return None, f"status_enum.{name} contains non-scalar entry: {x!r}"
        s = str(x).strip()
        if not s:
            continue
        if not TOKEN_RE.match(s):
            return None, (f"status_enum.{name} contains invalid token {s!r} "
                          "— allowed characters: [A-Za-z0-9_-]")
        out.append(s)
    return out, None

def _validate_scalar(name, raw):
    if raw is None or raw == '':
        return '', None
    if isinstance(raw, (dict, list)):
        return None, f"status_enum.{name} must be a scalar, got {type(raw).__name__}"
    s = str(raw).strip()
    if not s:
        return '', None
    if not TOKEN_RE.match(s):
        return None, (f"status_enum.{name} contains invalid token {s!r} "
                      "— allowed characters: [A-Za-z0-9_-]")
    return s, None

def emit(states, active, stale):
    print('STATES:' + '|'.join(states))
    print('ACTIVE:' + '|'.join(active))
    print('STALE:'  + stale)

def _bail(msg):
    print('ERROR:' + msg)
    emit([], [], '')
    sys.exit(0)

# Distinguish PyYAML absent (use fallback parser) from PyYAML present
# but YAML invalid (reject loudly). Conflating the two — `except
# Exception` — let a malformed file (e.g. bad indentation under
# `status_enum`) silently fall through to the permissive regex parser,
# which could partially accept it and run Check 7 in a half-applied
# state with no rejection message.
parsed = None
yaml_module = None
try:
    import yaml as yaml_module
except ImportError:
    pass

if yaml_module is not None:
    # PyYAML loaded — it is the single source of truth. Whatever it
    # returns (or fails to return) is final; do NOT fall back to the
    # regex parser, which is more permissive.
    try:
        with open(path) as f:
            cfg = yaml_module.safe_load(f) or {}
    except yaml_module.YAMLError as e:
        _bail(f'.arboretum.yml is not valid YAML: {e}')
    except OSError:
        emit([], [], '')
        sys.exit(0)
    if not isinstance(cfg, dict):
        emit([], [], '')
        sys.exit(0)
    se = cfg.get('status_enum')
    if se is None:
        emit([], [], '')
        sys.exit(0)
    if not isinstance(se, dict):
        _bail(f'status_enum must be a YAML mapping, got {type(se).__name__}')
    parsed = (se.get('states'), se.get('active_states'), se.get('stale_state'))
else:
    # PyYAML absent — fall back to a tight regex parser that handles
    # flow-style lists ([a, b, c]) and a scalar stale_state nested
    # under a top-level `status_enum:` block. Block-style lists are
    # not supported on this path; flow style is the documented form.
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        emit([], [], '')
        sys.exit(0)
    in_block = False
    block_indent = None
    raw_states = raw_active = None
    raw_stale = None
    def parse_list(s):
        s = s.strip()
        if not (s.startswith('[') and s.endswith(']')):
            return None
        return [x.strip().strip('"').strip("'")
                for x in s[1:-1].split(',') if x.strip()]
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^(\s*)([A-Za-z_][\w_]*)\s*:\s*(.*?)\s*(?:#.*)?$', line)
        if not m:
            continue
        ind, key, val = len(m.group(1)), m.group(2), m.group(3)
        if not in_block:
            if ind == 0 and key == 'status_enum' and not val:
                in_block = True
            continue
        if ind == 0:
            break
        if block_indent is None:
            block_indent = ind
        elif ind < block_indent:
            break
        if ind == block_indent:
            v = val.strip().strip('"').strip("'")
            # When val is non-empty but doesn't parse as a flow-style
            # list, propagate the raw scalar (not None). _validate_list
            # then sees a non-list and rejects it. Returning None here
            # would silently treat malformed config as "key omitted",
            # so the PyYAML-absent path would diverge from the PyYAML-
            # present path which rejects scalars loudly.
            def _list_or_scalar(value):
                if not value:
                    return None
                lst = parse_list(value)
                return lst if lst is not None else v
            if key == 'states':
                raw_states = _list_or_scalar(val)
            elif key == 'active_states':
                raw_active = _list_or_scalar(val)
            elif key == 'stale_state':
                raw_stale = v
    parsed = (raw_states, raw_active, raw_stale)

raw_states, raw_active, raw_stale = parsed

states_v, err = _validate_list('states', raw_states)
if err:
    _bail(err)
active_v, err = _validate_list('active_states', raw_active)
if err:
    _bail(err)
stale_v, err = _validate_scalar('stale_state', raw_stale)
if err:
    _bail(err)

# Cross-validate enum internal consistency. Only meaningful when the
# user has opted in (states non-empty). When states is empty the bash
# reader discards active_states / stale_state anyway, so internal
# checks are moot.
#
# Without these checks the validator only rejects badly-shaped tokens
# but lets internally-inconsistent enums through, and Check 6 / Check 7
# end up disagreeing about the same spec status (Check 6 warns it as
# unknown; Check 7 happily flips it). That's the same split-brain class
# the atomic opt-in fix was supposed to close — checking shape without
# checking membership leaves it open at a different layer.
if states_v:
    states_set = set(states_v)
    extras = [t for t in active_v if t not in states_set]
    if extras:
        _bail('status_enum.active_states contains tokens not in states: '
              + ', '.join(repr(t) for t in extras))
    if stale_v and stale_v not in states_set:
        _bail(f'status_enum.stale_state {stale_v!r} is not in states '
              f'({", ".join(repr(s) for s in states_v)})')

emit(states_v, active_v, stale_v)
PYEOF
)

  [ -z "$raw" ] && return 0

  # First pass: surface any ERROR: line and bail without overriding
  # defaults. A malformed block is treated as "no config" — canonical
  # draft/active/stale stays in effect — but the user is told why.
  local line
  while IFS= read -r line; do
    if [ "${line%%:*}" = "ERROR" ]; then
      echo "  · status_enum config rejected: ${line#ERROR:}" >&2
      return 0
    fi
  done <<< "$raw"

  # Second pass: parse the three field lines. Treat `states:` as the
  # atomic opt-in signal. When it's present:
  #   - STATUS_ENUM_CONFIGURED flips to true
  #   - STATUS_ACTIVE_STATES resets to () before applying active_states
  #     (prevents partial-config: active_states without states leaving
  #     the canonical default in effect — Check 6 would say "no config"
  #     but Check 7 would still flip)
  #   - STATUS_STALE_STATE resets to "" before applying stale_state
  #     (omitting stale_state means "warn only, do not flip" — must
  #     not silently inherit the canonical "stale" default)
  # When `states:` is absent the whole block is ignored and canonical
  # defaults remain. This makes opt-in an all-or-nothing decision.
  local states_payload="" active_payload="" stale_payload="" key payload
  while IFS= read -r line; do
    key="${line%%:*}"
    payload="${line#*:}"
    case "$key" in
      STATES) states_payload="$payload" ;;
      ACTIVE) active_payload="$payload" ;;
      STALE)  stale_payload="$payload"  ;;
    esac
  done <<< "$raw"

  if [ -n "$states_payload" ]; then
    IFS='|' read -ra STATUS_STATES <<< "$states_payload"
    STATUS_ENUM_CONFIGURED=true
    STATUS_ACTIVE_STATES=()
    STATUS_STALE_STATE=""
    if [ -n "$active_payload" ]; then
      IFS='|' read -ra STATUS_ACTIVE_STATES <<< "$active_payload"
    fi
    if [ -n "$stale_payload" ]; then
      STATUS_STALE_STATE="$stale_payload"
    fi
  fi
}

_read_status_enum

# ── Source-roots config ──────────────────────────────────────────────
#
# Check 3's general source-ownership scan (Half B) walks a set of source
# roots for *.py files. The default roots are `src`, the lowercased
# project directory name, and `tests`. A project with a non-standard
# layout can override the list via a `source_paths:` YAML list in
# .arboretum.yml:
#
#   source_paths:
#     - app
#     - lib
#     - tests
#
# The default three roots are used when .arboretum.yml, python3, or the
# `source_paths:` key is absent. Modelled on _read_status_enum() above.
SOURCE_PATHS=(src "$( basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' )" tests)

_read_source_paths() {
  local config="$PROJECT_DIR/.arboretum.yml"
  [ -f "$config" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  # Emit one pipe-joined PATHS: line. Tokens are validated to a safe
  # path-fragment charset — pipes (the field separator) and other
  # shell/glob metachars are rejected so a malformed list can't desync
  # the find roots downstream. A malformed block emits ERROR: and the
  # bash reader keeps the canonical defaults.
  local raw
  raw=$(python3 - "$config" <<'PYEOF' 2>/dev/null || true
import sys, re
path = sys.argv[1]
TOKEN_RE = re.compile(r'^[A-Za-z0-9_./-]+$')

def emit(paths):
    print('PATHS:' + '|'.join(paths))

def _bail(msg):
    print('ERROR:' + msg)
    emit([])
    sys.exit(0)

def _validate_list(raw):
    if raw is None:
        return [], None
    if not isinstance(raw, list):
        return None, f"source_paths must be a YAML list, got {type(raw).__name__}"
    out = []
    for x in raw:
        if isinstance(x, (dict, list)):
            return None, f"source_paths contains non-scalar entry: {x!r}"
        s = str(x).strip()
        if not s:
            continue
        if not TOKEN_RE.match(s):
            return None, (f"source_paths contains invalid token {s!r} "
                          "— allowed characters: [A-Za-z0-9_./-]")
        out.append(s)
    return out, None

# PyYAML when available is the single source of truth; otherwise fall
# back to a tight flow-style-list parser. Mirrors _read_status_enum().
parsed = None
yaml_module = None
try:
    import yaml as yaml_module
except ImportError:
    pass

if yaml_module is not None:
    try:
        with open(path) as f:
            cfg = yaml_module.safe_load(f) or {}
    except yaml_module.YAMLError as e:
        _bail(f'.arboretum.yml is not valid YAML: {e}')
    except OSError:
        emit([])
        sys.exit(0)
    if not isinstance(cfg, dict):
        emit([])
        sys.exit(0)
    parsed = cfg.get('source_paths')
else:
    # PyYAML absent — parse a top-level `source_paths:` flow-style list
    # ([a, b, c]) or block-style list (- a / - b) by hand.
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        emit([])
        sys.exit(0)
    def parse_flow(s):
        s = s.strip()
        if not (s.startswith('[') and s.endswith(']')):
            return None
        return [x.strip().strip('"').strip("'")
                for x in s[1:-1].split(',') if x.strip()]
    in_block = False
    items = None
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^(\s*)([A-Za-z_][\w_-]*)\s*:\s*(.*?)\s*(?:#.*)?$', line)
        bullet = re.match(r'^(\s*)-\s+(.*?)\s*(?:#.*)?$', line)
        if not in_block:
            if m and len(m.group(1)) == 0 and m.group(2) == 'source_paths':
                val = m.group(3).strip()
                flow = parse_flow(val)
                if flow is not None:
                    parsed = flow
                    break
                if val:
                    # Non-list scalar — propagate so the validator
                    # rejects it loudly (mirrors the status_enum path).
                    parsed = val
                    break
                in_block = True
                items = []
            continue
        # Inside the block: collect bullets until a non-indented line.
        if bullet and len(bullet.group(1)) > 0:
            items.append(bullet.group(2).strip().strip('"').strip("'"))
            continue
        if m and len(m.group(1)) == 0:
            break
    if in_block:
        parsed = items

paths_v, err = _validate_list(parsed)
if err:
    _bail(err)
emit(paths_v)
PYEOF
)

  [ -z "$raw" ] && return 0

  # First pass: surface any ERROR: line and keep the canonical defaults.
  local line
  while IFS= read -r line; do
    if [ "${line%%:*}" = "ERROR" ]; then
      echo "  · source_paths config rejected: ${line#ERROR:}" >&2
      return 0
    fi
  done <<< "$raw"

  # Second pass: apply the PATHS: line when non-empty.
  local paths_payload=""
  while IFS= read -r line; do
    case "${line%%:*}" in
      PATHS) paths_payload="${line#*:}" ;;
    esac
  done <<< "$raw"

  if [ -n "$paths_payload" ]; then
    IFS='|' read -ra SOURCE_PATHS <<< "$paths_payload"
  fi
}

_read_source_paths

# ── Check 0: Missing governed documents ──────────────────────────────

header "Check 1: Governed documents exist"

[ -f "$PROJECT_DIR/workflows/README.md" ] && ok "workflows/README.md" || warn "workflows/README.md missing"
[ -f "$PROJECT_DIR/CLAUDE.md" ] && ok "CLAUDE.md" || warn "CLAUDE.md missing"
[ -f "$PROJECT_DIR/docs/ARCHITECTURE.md" ] && ok "docs/ARCHITECTURE.md" || warn "docs/ARCHITECTURE.md missing"
[ -f "$REGISTER" ] && ok "docs/REGISTER.md" || warn "docs/REGISTER.md missing"
[ -f "$CONTRACTS" ] && ok "contracts.yaml" || warn "contracts.yaml missing"
[ -d "$DEFS_DIR" ] && ok "docs/definitions/" || warn "docs/definitions/ missing"
[ -d "$SPECS_DIR" ] && ok "docs/specs/" || warn "docs/specs/ missing"

# If register doesn't exist, we can't run most checks
if [ ! -f "$REGISTER" ]; then
  echo ""
  echo "Register not found — skipping checks 2-5."
  echo ""
  echo "Summary: $issue_count issues found across $check_count checks."
  exit 1
fi

# ── Register schema detection (gates Check 2 and Check 3 Half B) ─────
#
# Detect REGISTER.md's Spec Index schema by inspecting the header row.
# Current schema (emitted by generate-register.sh): | Spec | Status | Owner | Owns |
# Legacy schema (older arboretum bootstraps):       | Spec | Status | Owns | Depends On |
# Parsing the wrong schema produces silent garbage (Owner values read as
# paths, etc.). When the schema isn't current, skip the register-derived
# checks — Check 2, and Check 3's source-ownership scan (Half B) — with a
# clear instruction to regenerate rather than emit false-positive
# findings. Check 3's owner-marker scan (Half A) reads markers straight
# off files and never touches REGISTER.md, so it still runs.

register_header=$(grep -E '^\| Spec \| Status \|' "$REGISTER" 2>/dev/null | head -1 || true)
register_schema_compatible=false
register_schema_message=""

if [[ -z "$register_header" ]]; then
  register_schema_message="REGISTER.md has no recognized Spec Index header"
elif [[ "$register_header" == *"Owner"* ]]; then
  register_schema_compatible=true
else
  register_schema_message="REGISTER.md uses a legacy schema (no Owner column). Run 'bash scripts/generate-register.sh' to regenerate to the current schema (Spec | Status | Owner | Owns)"
fi

# ── Check 2: Register owned files vs. disk ───────────────────────────

header "Check 2: Register owned files vs. disk"

# Extract owned file/directory patterns from register
# Format produced by generate-register.sh: | spec.md | status | owner | owns |
# Owns column entries are backtick-wrapped: `src/foo.py`, `tests/test_foo.py`.
spec_owns_map=""

if [ "$register_schema_compatible" = false ]; then
  warn "$register_schema_message — skipping Check 2"
else
while IFS='|' read -r _ spec _ _ owns _; do
  spec=$(echo "$spec" | xargs)
  owns=$(echo "$owns" | xargs)
  [ -z "$spec" ] || [ -z "$owns" ] && continue

  for pattern in $(echo "$owns" | tr ',' '\n'); do
    # Strip whitespace and backticks (generate-register.sh wraps each path in
    # backticks for markdown rendering — they must be removed for path comparison).
    pattern=$(echo "$pattern" | xargs | tr -d '`')
    [ -z "$pattern" ] && continue

    # Skip ellipsis patterns like "pyproject.toml, setup.cfg, ..."
    [ "$pattern" = "..." ] && continue
    # generate-register.sh emits — for specs with empty Owns column
    [ "$pattern" = "—" ] && continue

    # Handle glob patterns
    if [[ "$pattern" == *"**"* ]]; then
      dir="${pattern%%\*\*}"
      dir="${dir%/}"
      if [ -d "$PROJECT_DIR/$dir" ]; then
        ok "$pattern (directory exists)"
      else
        warn "$pattern (directory missing, owned by $spec)"
      fi
    else
      if [ -e "$PROJECT_DIR/$pattern" ]; then
        ok "$pattern"
      else
        warn "$pattern (file missing, owned by $spec)"
      fi
    fi

    spec_owns_map+="$pattern:$spec"$'\n'
  done
done < <(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)
fi

# Check 3: every source file carries a resolvable owner marker.
#   .sh under scripts/ (excl _archived/, _fixtures/) and .claude/hooks/,
#   and bin/* executables: line 2 must be `# owner: <spec-name>`.
#   skills/*/SKILL.md: YAML frontmatter must carry an `owner:` key.
#   The named spec must exist at docs/specs/<name>.spec.md.
# Scan roots are fixed: scripts/, .claude/hooks/, bin/, skills/.
header "Check 3: Unowned source files"

unowned_count=0
owner_re='^# owner: ([a-z][a-z0-9-]+)$'
skill_owner_re='^owner:[[:space:]]*([a-z][a-z0-9-]+)[[:space:]]*$'

# .sh files under scripts/ (excl _archived, _fixtures) and .claude/hooks/,
# plus bin/* — all use the line-2 `# owner:` convention.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  rel="${f#$PROJECT_DIR/}"
  line2=$(sed -n '2p' "$f")
  if [[ "$line2" =~ $owner_re ]]; then
    if [ ! -f "$SPECS_DIR/${BASH_REMATCH[1]}.spec.md" ]; then
      warn "Unowned: $rel — owner '${BASH_REMATCH[1]}' has no spec at docs/specs/${BASH_REMATCH[1]}.spec.md"
      ((unowned_count++)) || true
    fi
  else
    warn "Unowned: $rel — no '# owner:' header on line 2"
    ((unowned_count++)) || true
  fi
done < <(
  find "$PROJECT_DIR/scripts" \
       -type d \( -name _archived -o -name _fixtures \) -prune -o \
       -type f -name '*.sh' -print 2>/dev/null
  [ -d "$PROJECT_DIR/.claude/hooks" ] && \
    find "$PROJECT_DIR/.claude/hooks" -type f -name '*.sh' -print 2>/dev/null
  [ -d "$PROJECT_DIR/bin" ] && \
    find "$PROJECT_DIR/bin" -type f -print 2>/dev/null
)

# skills/*/SKILL.md — YAML frontmatter `owner:` key.
if [ -d "$PROJECT_DIR/skills" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#$PROJECT_DIR/}"
    owner_line=$(awk '/^---[[:space:]]*$/{n++; next} n>=2{exit} n==1 && /^owner:/{print; exit}' "$f")
    if [[ "$owner_line" =~ $skill_owner_re ]]; then
      if [ ! -f "$SPECS_DIR/${BASH_REMATCH[1]}.spec.md" ]; then
        warn "Unowned: $rel — owner '${BASH_REMATCH[1]}' has no spec at docs/specs/${BASH_REMATCH[1]}.spec.md"
        ((unowned_count++)) || true
      fi
    else
      warn "Unowned: $rel — no 'owner:' key in YAML frontmatter"
      ((unowned_count++)) || true
    fi
  done < <(find "$PROJECT_DIR/skills" -type f -name 'SKILL.md' -print 2>/dev/null)
fi

# ── Check 3 Half B: general source-ownership scan ────────────────────
#
# Half A above is arboretum-framework-specific (owner markers on .sh/
# bin/SKILL.md). Half B is the general source-ownership scan that
# downstream adopter projects depend on: walk the project source roots
# for *.py files and flag any not covered by a spec's owns: patterns.
# It reuses the spec_owns_map built for Check 2, so — like Check 2 — it
# is gated on register_schema_compatible: an incompatible REGISTER.md
# schema means spec_owns_map is empty and every file would mis-flag.
if [ "$register_schema_compatible" = false ]; then
  info "Source-ownership scan skipped — REGISTER.md schema not compatible (see Check 2 message)"
else
  for src_dir in "${SOURCE_PATHS[@]}"; do
    [ -z "$src_dir" ] && continue
    [ ! -d "$PROJECT_DIR/$src_dir" ] && continue
    while IFS= read -r file; do
      rel_path="${file#$PROJECT_DIR/}"
      [[ "$rel_path" == *"__pycache__"* ]] && continue
      [[ "$rel_path" == *.pyc ]] && continue
      owned=false
      while IFS=: read -r pattern _; do
        [ -z "$pattern" ] && continue
        if [[ "$pattern" == *"**"* ]]; then
          dir="${pattern%%\*\*}"
          if [[ "$rel_path" == "$dir"* ]]; then owned=true; break; fi
        elif [ "$rel_path" = "$pattern" ]; then owned=true; break; fi
      done <<< "$spec_owns_map"
      if [ "$owned" = false ]; then
        warn "Unowned: $rel_path"
        ((unowned_count++)) || true
      fi
    done < <(find "$PROJECT_DIR/$src_dir" -name '*.py' -type f 2>/dev/null)
  done
fi

[ "$unowned_count" -eq 0 ] && ok "All source files carry a resolvable owner"

# ── Check 4: contracts.yaml vs. spec Requires tables ─────────────────

header "Check 4: contracts.yaml vs. spec Requires tables"

if [ ! -f "$CONTRACTS" ]; then
  warn "contracts.yaml missing — cannot check version pin sync"
else
  sync_issues=0

  # For each spec file, extract its Requires table pins and compare to contracts.yaml
  for spec_file in "$SPECS_DIR"/*.spec.md; do
    [ ! -f "$spec_file" ] && continue
    spec_name=$(basename "$spec_file" .md)

    # Extract definition@version references from the spec's Requires table
    # Look for patterns like definitions/foo.md@v1
    spec_pins=$(grep -oE 'definitions/[^@|]+@v[0-9]+' "$spec_file" 2>/dev/null || true)

    while IFS= read -r pin; do
      [ -z "$pin" ] && continue
      def_path=$(echo "$pin" | cut -d@ -f1)
      spec_version=$(echo "$pin" | cut -d@ -f2)

      # Check if contracts.yaml has this pin
      # Look for the definition path under this spec's section
      yaml_version=$(grep -A50 "^  ${spec_name%.spec}:" "$CONTRACTS" 2>/dev/null \
        | grep "$def_path" | head -1 \
        | grep -oE 'v[0-9]+' || true)

      if [ -z "$yaml_version" ]; then
        warn "$spec_name: $def_path@$spec_version in spec but missing from contracts.yaml"
        ((sync_issues++)) || true
      elif [ "$yaml_version" != "$spec_version" ]; then
        warn "$spec_name: $def_path — spec says $spec_version, contracts.yaml says $yaml_version"
        ((sync_issues++)) || true
      fi
    done <<< "$spec_pins"
  done

  [ "$sync_issues" -eq 0 ] && ok "All spec pins match contracts.yaml"
fi

# ── Check 4: contracts.yaml vs. definition current versions ──────────

header "Check 5: contracts.yaml vs. definition versions (staleness)"

if [ ! -f "$CONTRACTS" ] || [ ! -d "$DEFS_DIR" ]; then
  info "Skipped — contracts.yaml or definitions/ missing"
else
  stale_count=0

  # Extract all definition references and pinned versions from contracts.yaml
  pins=$(grep -E '^[[:space:]]+definitions/' "$CONTRACTS" 2>/dev/null | sed 's/#.*//' || true)

  while IFS=: read -r def_path pinned_version; do
    [ -z "$def_path" ] && continue
    def_path=$(echo "$def_path" | xargs)
    pinned_version=$(echo "$pinned_version" | xargs)
    [ -z "$pinned_version" ] && continue

    def_file="$PROJECT_DIR/docs/$def_path"
    if [ ! -f "$def_file" ]; then
      warn "Definition not found: $def_path (pinned at $pinned_version in contracts.yaml)"
      ((stale_count++)) || true
      continue
    fi

    # Extract current version from definition file
    current_version=$(grep -A1 '^## Version' "$def_file" 2>/dev/null \
      | grep -oE 'v[0-9]+' | head -1 || true)

    if [ -z "$current_version" ]; then
      warn "$def_path: no version found in file (pinned at $pinned_version)"
      ((stale_count++)) || true
    elif [ "$current_version" != "$pinned_version" ]; then
      warn "$def_path: pinned=$pinned_version, current=$current_version — STALE"
      ((stale_count++)) || true
    else
      ok "$def_path: $current_version (current)"
    fi
  done <<< "$pins"

  [ "$stale_count" -eq 0 ] && [ -n "$pins" ] && ok "All version pins are current"
fi

# ── Check 5: Spec status consistency ─────────────────────────────────

header "Check 6: Spec status consistency"

if [ "$register_schema_compatible" = false ]; then
  info "Skipped — REGISTER.md schema not compatible (see Check 2 message)"
else
# Two modes drive this check:
#
# 1) STATUS_ENUM_CONFIGURED=true (project declared status_enum: in .arboretum.yml):
#    typos warn per-spec against the declared vocabulary. This is the
#    signal Option A's graceful no-op (PR #196) had to drop.
# 2) STATUS_ENUM_CONFIGURED=false (no config, defaults to draft/active/stale):
#    unknown values aggregate into a single "extended enum" info line so
#    extended-enum projects don't get per-spec warning floods.
#
# extended_enum_states accumulates unknown values only when there is no
# explicit config — otherwise per-spec WARNs replace this summary line.
# Array (not \n-joined string) so the post-loop format uses printf '%s\n'
# which does not interpret backslash escapes from spec frontmatter values.
extended_enum_states=()

# Read order matches the current schema: | _ | spec | status | owner | owns | _ |
while IFS='|' read -r _ spec status _ owns _; do
  spec=$(echo "$spec" | xargs)
  status=$(echo "$status" | xargs)
  owns=$(echo "$owns" | xargs)
  [ -z "$spec" ] && continue

  spec_file="$SPECS_DIR/$spec"

  if [ -z "$status" ]; then
    : # blank status — generate-register would have defaulted, ignore here
  elif ! _in_array "$status" "${STATUS_STATES[@]}"; then
    # Unknown status.
    if [ "$STATUS_ENUM_CONFIGURED" = true ]; then
      # Explicit config → this is a typo signal worth surfacing per-spec.
      warn "$spec: unknown status '$status' — must be one of: ${STATUS_STATES[*]}"
    else
      # No config; aggregate for the post-loop extended-enum info line.
      extended_enum_states+=("$status")
    fi
  else
    # Valid status. Specific classes:
    # - active-state spec with no owned files: info, not drift. A spec
    #   can legitimately be active with owns: [] when its deliverable is
    #   a section inside another spec's file (e.g. an ARCHITECTURE.md
    #   section). A perpetual ✗ here would erode signal, so surface it
    #   as a non-failing · line.
    # - stale-state spec (drift previously recorded, awaits /consolidate)
    if _in_array "$status" "${STATUS_ACTIVE_STATES[@]}"; then
      if [ -z "$owns" ] || [ "$owns" = "(none)" ] || [ "$owns" = "—" ]; then
        info "$spec: status=$status but owns no files"
      fi
    elif [ -n "$STATUS_STALE_STATE" ] && [ "$status" = "$STATUS_STALE_STATE" ]; then
      warn "$spec: status=$status — drift recorded; run /consolidate to reconcile"
    fi
    # Other valid states (e.g. draft, ready, implemented) are silent.
  fi

  # Spec file presence check applies regardless of vocabulary.
  if [ ! -f "$spec_file" ]; then
    warn "$spec: listed in register but file does not exist"
  fi
done < <(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)

# Surface extended-enum usage as a single info line — only when the
# project hasn't explicitly configured status_enum. With config present,
# the per-spec WARNs above are the signal; an info line would be noise.
if [ "$STATUS_ENUM_CONFIGURED" = false ] && [ ${#extended_enum_states[@]} -gt 0 ]; then
  distinct_states=$(printf '%s\n' "${extended_enum_states[@]}" | sort -u | tr '\n' ' ' | xargs)
  info "Project uses extended status enum (states observed: $distinct_states). Canonical plugin enum is draft/active/stale — Check 7 auto-flip will be a no-op."
fi

ok "Status consistency check complete"
fi

# ── Check 7: Spec drift detection (auto-flip active → stale) ─────────

header "Check 7: Spec drift (auto-flip active → stale)"

# For each spec at status active, check whether any owned file was modified
# in commits AFTER the spec's most recent commit. If so, the spec is out of
# sync with its owned code → flip status to stale in REGISTER.md and spec
# frontmatter so the user is prompted to run /consolidate.
#
# This is the only mutation this script performs. All other findings are
# advisory ("do not auto-fix"). Drift status is structurally bounded by
# the spec status enum, so writing it is safe.
#
# Skipping when schema is incompatible is critical: this check MUTATES, so
# parsing the wrong column for `owns` could cause the loop to find no drift
# anywhere (silent no-op) or to mutate against bogus paths.

drift_flipped=0
no_drift_count=0

if [ "$register_schema_compatible" = false ]; then
  info "Skipped — REGISTER.md schema not compatible (see Check 2 message)"
elif ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Drift detection compares spec vs. owned-file commit timestamps via
  # `git log`. Without a git working tree there is nothing to compare,
  # and the bare `git log` calls below would exit 128 and propagate
  # through `set -euo pipefail` to crash the whole script (see #137).
  info "Skipped — $PROJECT_DIR is not a git working tree (drift detection requires git history)"
elif ! git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  # An empty repo (e.g. immediately after `git init`, before the first
  # commit) is a work tree but has no HEAD for `git log` to inspect.
  # The substitutions below would still hit fatal: 128 — same crash.
  info "Skipped — $PROJECT_DIR has no git history yet (drift detection requires at least one commit)"
else
# Read order matches the current schema: | _ | spec | status | owner | owns | _ |
while IFS='|' read -r _ spec status _ owns _; do
  spec=$(echo "$spec" | xargs)
  status=$(echo "$status" | xargs)
  owns=$(echo "$owns" | xargs)
  [ -z "$spec" ] && continue
  _in_array "$status" "${STATUS_ACTIVE_STATES[@]}" || continue

  spec_file="$SPECS_DIR/$spec"
  [ ! -f "$spec_file" ] && continue

  # git pathspecs are evaluated relative to the repo root; pass repo-relative
  # paths, not absolute, or the commit hash comes back empty.
  spec_rel="docs/specs/$spec"

  # Most recent commit touching the spec file
  spec_last_commit=$(git -C "$PROJECT_DIR" log -1 --format=%H -- "$spec_rel" 2>/dev/null)
  [ -z "$spec_last_commit" ] && continue

  drift=false
  drift_file=""

  for pattern in $(echo "$owns" | tr ',' '\n'); do
    # Strip whitespace and backticks (generate-register.sh wraps each path in
    # backticks). Skip em-dash and ellipsis sentinels.
    pattern=$(echo "$pattern" | xargs | tr -d '`')
    [ -z "$pattern" ] && continue
    [ "$pattern" = "..." ] && continue
    [ "$pattern" = "—" ] && continue

    # Resolve pattern to actual files
    if [[ "$pattern" == *"**"* ]]; then
      dir="${pattern%%\*\*}"
      dir="${dir%/}"
      [ ! -d "$PROJECT_DIR/$dir" ] && continue
      file_list=$(find "$PROJECT_DIR/$dir" -type f 2>/dev/null)
    elif [ -e "$PROJECT_DIR/$pattern" ]; then
      file_list="$PROJECT_DIR/$pattern"
    else
      continue
    fi

    for owned_file in $file_list; do
      # Convert to repo-relative for git pathspec
      owned_rel="${owned_file#$PROJECT_DIR/}"
      owned_last_commit=$(git -C "$PROJECT_DIR" log -1 --format=%H -- "$owned_rel" 2>/dev/null)
      [ -z "$owned_last_commit" ] && continue
      [ "$owned_last_commit" = "$spec_last_commit" ] && continue
      # spec_last_commit ancestor of owned_last_commit → owned modified later → drift
      if git -C "$PROJECT_DIR" merge-base --is-ancestor "$spec_last_commit" "$owned_last_commit" 2>/dev/null; then
        drift=true
        drift_file="$owned_rel"
        break 2
      fi
    done
  done

  if [ "$drift" = true ]; then
    # No stale_state configured → warn-only, no mutation. This is a
    # supported configuration for projects that want drift surfaced but
    # don't want auto-flips (e.g. they manage status manually).
    if [ -z "$STATUS_STALE_STATE" ]; then
      warn "$spec: drift detected ($drift_file modified after spec's last commit $spec_last_commit) — no stale_state configured, not flipping"
      ((drift_flipped++)) || true
      continue
    fi

    # Escape spec name for literal use in sed's regex pattern (spec filenames
    # contain `.` which would match any character without escaping).
    escaped_spec=$(printf '%s' "$spec" | sed 's/[][\\.^$*|/]/\\&/g')

    # Flip REGISTER.md status: "| <spec> | <status> " → "| <spec> | <stale_state> "
    sed -i.bak -E "s/^\| ${escaped_spec} \| ${status} /| ${spec} | ${STATUS_STALE_STATE} /" "$REGISTER"
    rm -f "$REGISTER.bak"

    # Flip spec status in either supported format:
    # - YAML frontmatter: "status: <status>" → "status: <stale_state>"
    # - Legacy markdown section:
    #     ## Status
    #     <status>
    if grep -q "^status: ${status}\$" "$spec_file"; then
      sed -i.bak "s/^status: ${status}\$/status: ${STATUS_STALE_STATE}/" "$spec_file"
    elif grep -q '^## Status$' "$spec_file"; then
      sed -i.bak "/^## Status\$/{
n
s/^${status}\$/${STATUS_STALE_STATE}/
}" "$spec_file"
    fi
    rm -f "$spec_file.bak"

    # warn() already increments issue_count and sets drift_found
    warn "$spec: flipped ${status} → ${STATUS_STALE_STATE} (drift: $drift_file modified after spec's last commit $spec_last_commit)"
    ((drift_flipped++)) || true
  else
    ((no_drift_count++)) || true
  fi
done < <(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)

if [ "$drift_flipped" -eq 0 ]; then
  if [ "$no_drift_count" -gt 0 ]; then
    ok "No drift detected across $no_drift_count active spec(s)"
  elif [ "$STATUS_ENUM_CONFIGURED" = true ]; then
    # Configured project with no specs at its declared active_states.
    # Acknowledge so an empty Check 7 isn't mysterious.
    info "No specs at active states (${STATUS_ACTIVE_STATES[*]}) — drift auto-flip is a no-op"
  else
    # Unconfigured project with no specs at canonical `active`. Check 6
    # may have surfaced an extended-enum acknowledgement already.
    info "No specs at status 'active' — drift auto-flip is a no-op (project may use an extended status enum; see Check 6)"
  fi
fi
fi  # close: register_schema_compatible guard for Check 7

# ── Check 8: Plan files missing Tests section ────────────────────────

header "Check 8: Plan files — Tests section"

PLANS_DIR="$PROJECT_DIR/docs/plans"
if [ ! -d "$PLANS_DIR" ]; then
  info "Skipped — docs/plans/ not found"
else
  plans_checked=0
  plans_warned=0

  for plan_file in "$PLANS_DIR"/*.md; do
    [ ! -f "$plan_file" ] && continue
    plan_name=$(basename "$plan_file")

    # Skip templates
    [[ "$plan_name" == "TEMPLATE.md" ]] && continue
    [[ "$plan_name" == *template* ]] && continue

    plan_content=$(cat "$plan_file")

    # Determine if the plan is test-prudent:
    # Contains source file extensions or implementation keywords
    is_test_prudent=false

    if echo "$plan_content" | grep -qE '\.(ts|js|sh|py|go|rs|rb|java|tsx|jsx)\b'; then
      is_test_prudent=true
    elif echo "$plan_content" | grep -qiE 'implement|create function|add endpoint|write code|add method|new file|modify|refactor'; then
      is_test_prudent=true
    fi

    # If only docs/config references, skip
    if [ "$is_test_prudent" = false ]; then
      continue
    fi

    ((plans_checked++)) || true

    # Check for a ## Tests or ## Test heading
    if echo "$plan_content" | grep -qE '^## Tests?(\s|$)'; then
      ok "$plan_name has a Tests section"
    else
      info "$plan_name: test-prudent plan without a ## Tests section"
      ((plans_warned++)) || true
    fi
  done

  [ "$plans_checked" -eq 0 ] && info "No test-prudent plans found"
  [ "$plans_checked" -gt 0 ] && [ "$plans_warned" -eq 0 ] && ok "All test-prudent plans have a Tests section"
fi

# ── Check 9: Strategic Anchor validity ──────────────────────────────

header "Check 9: Strategic Anchor"

strategic_anchor_check() {
  local root config claude
  root="$PROJECT_DIR"
  config="$root/roadmap.config.yaml"
  claude="$root/CLAUDE.md"

  # Silent pass — not adopted
  [ ! -f "$config" ] && return 0

  local issues=0

  # 1. Section present
  if ! grep -q '^## Strategic Anchor' "$claude" 2>/dev/null; then
    echo "WARN [strategic-anchor]: CLAUDE.md is missing '## Strategic Anchor' (roadmap.config.yaml exists)"
    issues=$((issues + 1))
  else
    # 2. Time horizon date is in the future — only if the horizon itself contains
    # an ISO date. Strip any (next review: ...) parenthetical first so we don't
    # accidentally check the review date instead of the horizon end.
    local horizon_date today_epoch horizon_epoch
    horizon_date=$(awk '/^## Strategic Anchor/{found=1} found && /\*\*Time horizon:/{print; exit}' "$claude" \
      | sed 's/(next review:[^)]*)//g' \
      | grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
    if [ -n "$horizon_date" ]; then
      # macOS date -j -f, Linux date -d
      horizon_epoch=$(date -j -f '%Y-%m-%d' "$horizon_date" +%s 2>/dev/null \
        || date -d "$horizon_date" +%s 2>/dev/null \
        || echo 0)
      today_epoch=$(date +%s)
      if [ "$horizon_epoch" -lt "$today_epoch" ]; then
        echo "WARN [strategic-anchor]: Time horizon date ($horizon_date) is past — run /roadmap revise"
        issues=$((issues + 1))
      fi
    fi

    # 3. In/out scope non-empty (≥1 bullet each)
    local in_bullets out_bullets
    in_bullets=$(awk '/^### In scope/{found=1; next} found && /^### /{exit} found{print}' "$claude" \
      | grep -cE '^- ' 2>/dev/null || echo 0)
    out_bullets=$(awk '/^### Out of scope/{found=1; next} found && /^### /{exit} found{print}' "$claude" \
      | grep -cE '^- ' 2>/dev/null || echo 0)
    [ "$in_bullets" -lt 1 ] && \
      echo "WARN [strategic-anchor]: '### In scope (this period)' has no bullets" && issues=$((issues + 1))
    [ "$out_bullets" -lt 1 ] && \
      echo "WARN [strategic-anchor]: '### Out of scope (this period)' has no bullets" && issues=$((issues + 1))
  fi

  # 4. Cadence not overdue
  local last_reviewed cadence_weeks last_epoch due_epoch
  # Use python3 if yq not available (same pattern as lib.sh)
  if command -v yq >/dev/null 2>&1; then
    last_reviewed=$(yq -r '.last_reviewed // ""' "$config")
    cadence_weeks=$(yq -r '.review_cadence_weeks // ""' "$config")
  elif command -v python3 >/dev/null 2>&1; then
    _yaml_scalar() {
      python3 - "$1" "$2" <<'PYEOF'
import sys, re
def parse_scalar(path, key):
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            m = re.match(r'^' + re.escape(key) + r'\s*:\s*(.*)', line)
            if m:
                val = re.sub(r'\s+#.*$', '', m.group(1)).strip()
                if val in ('', 'null', '~'):
                    return ''
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                    val = val[1:-1]
                return val
    return ''
print(parse_scalar(sys.argv[1], sys.argv[2]))
PYEOF
    }
    last_reviewed=$(_yaml_scalar "$config" last_reviewed)
    cadence_weeks=$(_yaml_scalar "$config" review_cadence_weeks)
  fi
  if [ -n "${last_reviewed:-}" ] && [ -n "${cadence_weeks:-}" ]; then
    last_epoch=$(date -j -f '%Y-%m-%d' "$last_reviewed" +%s 2>/dev/null \
      || date -d "$last_reviewed" +%s 2>/dev/null \
      || echo 0)
    due_epoch=$(( last_epoch + cadence_weeks * 7 * 86400 ))
    if [ "$(date +%s)" -gt "$due_epoch" ]; then
      echo "WARN [strategic-anchor]: Strategic review overdue (last=$last_reviewed, cadence=${cadence_weeks}w) — run /roadmap revise"
      issues=$((issues + 1))
    fi
  fi

  [ "$issues" -eq 0 ] && echo "OK [strategic-anchor]: all checks pass"
  return $issues
}

# Run the check; harvest any WARN lines into the standard drift machinery
anchor_output=$(strategic_anchor_check 2>&1) || anchor_exit=$?
anchor_exit=${anchor_exit:-0}

if [ -z "$anchor_output" ]; then
  # strategic_anchor_check returned 0 with no output — config absent, silent pass
  info "Skipped — roadmap.config.yaml not present"
else
  while IFS= read -r line; do
    if [[ "$line" == WARN* ]]; then
      warn "${line#WARN }"
    elif [[ -n "$line" ]]; then
      info "$line"
    fi
  done <<< "$anchor_output"
  if [ "$anchor_exit" -eq 0 ] && ! echo "$anchor_output" | grep -q '^WARN'; then
    ok "Strategic Anchor looks good"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$drift_found" = true ]; then
  echo "DRIFT DETECTED: $issue_count issues found across $check_count checks."
  echo ""
  echo "Review the issues above and resolve before implementing."
  echo "Do not auto-fix — the architecture owner approves changes."
  exit 1
else
  echo "HEALTHY: No drift detected across $check_count checks."
  exit 0
fi
