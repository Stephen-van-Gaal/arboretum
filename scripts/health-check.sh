#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# uses: definitions/register-schema.md @v1
# uses: definitions/contracts-yaml-schema.md @v1
# uses: definitions/spec-status-state-machine.md @v1
# health-check.sh — Detect drift across the spec-driven workflow
#
# Requires bash 4+ (uses process substitution, arrays, [[ ]]).
#
# Usage:
#   ./scripts/health-check.sh [--reconcile [--all]] [project-dir]
#
# Flags (order-independent; precede the positional project-dir):
#   --reconcile   Write drift findings (flip active → stale in spec files and
#                 REGISTER.md). Without this flag the run is read-only: drift
#                 is reported but no files are modified. Branch-scoped by
#                 default (#750): only specs whose owned files changed on the
#                 current branch (vs the integration base) are flipped; drift
#                 outside that scope is reported but not flipped. On the
#                 integration branch (or when no base resolves) it flips
#                 nothing and advises --all.
#   --all         With --reconcile, reconcile repo-wide (every drifted spec),
#                 not just branch-touched ones. No effect without --reconcile.
#
# Runs nine checks:
#   1. Governed documents exist (ARCHITECTURE, REGISTER, contracts, etc.)
#   2. Register vs. disk (do owned files exist?)
#   3. Unowned source files. Half A — framework owner-marker scan
#      (.sh/bin/ first non-shebang # owner:, SKILL.md owner: frontmatter), runs
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
# Produces a drift report. With --reconcile, also flips spec status (Check 7).
# Exit code: 0 if healthy, 1 if drift detected.

set -euo pipefail

# Guard: fail if sourced or invoked with a non-bash shell (e.g. sh, dash)
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Error: this script requires bash. Run with: bash $0" >&2
  exit 1
fi

RECONCILE=false
RECONCILE_ALL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --reconcile) RECONCILE=true;     shift ;;
    --all)       RECONCILE_ALL=true; shift ;;
    --) shift; break ;;
    # Distinct usage exit (EX_USAGE); avoids colliding with the script's
    # advisory-findings exit 2 so an exit-code consumer can't read a flag
    # typo as "advisory-only" (#750 review).
    -*) echo "Unknown flag: $1" >&2; exit 64 ;;
    *)  break ;;
  esac
done

PROJECT_DIR="${1:-$(pwd)}"
REGISTER="$PROJECT_DIR/docs/REGISTER.md"
CONTRACTS="$PROJECT_DIR/contracts.yaml"
DEFS_DIR="$PROJECT_DIR/docs/definitions"
SPECS_DIR="$PROJECT_DIR/docs/specs"
source "$(dirname "${BASH_SOURCE[0]}")/lib/owner-doc-resolve.sh"   # group-aware # owner: resolution (D7, #681)
source "$(dirname "${BASH_SOURCE[0]}")/lib/scope-resolve.sh"       # `# scope:` governance-scope marker (#836)

# Severity-tiered finding counters (S2 #641): warn() emits blocking ✗,
# advise() emits advisory ⚠. The exit code summarizes the run:
#   0 = clean · 1 = ≥1 blocking finding · 2 = advisory-only findings.
blocking_count=0
advisory_count=0
check_count=0

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
  ((blocking_count++)) || true
}

advise() {
  echo "  ⚠ $1"
  ((advisory_count++)) || true
}

info() {
  echo "  · $1"
}

is_plugin_root() {
  [ -d "$PROJECT_DIR/skills" ] \
    && [ -d "$PROJECT_DIR/hooks" ] \
    && [ -d "$PROJECT_DIR/docs/contracts" ] \
    && [ -d "$PROJECT_DIR/tests/contracts" ] \
    && [ -d "$PROJECT_DIR/scripts/_fixtures/roadmap" ] \
    && [ -f "$PROJECT_DIR/.github/ISSUE_TEMPLATE/agent-ready.md" ]
}

manifest_manages_path() {
  local rel="$1"
  local manifest="$PROJECT_DIR/.arboretum/install-manifest.json"

  [ -f "$manifest" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$manifest" "$rel" <<'PYEOF'
import json
import sys

try:
    with open(sys.argv[1]) as f:
        manifest = json.load(f)
except Exception:
    sys.exit(1)

files = manifest.get("files")
if isinstance(files, dict) and sys.argv[2] in files:
    sys.exit(0)
sys.exit(1)
PYEOF
  else
    grep -Fq "\"$rel\"" "$manifest"
  fi
}

missing_owner_spec_is_applicable() {
  local rel="$1"

  # Primary signal (#836): the in-file `# scope:` marker is authoritative in a
  # consumer root, ahead of manifest membership. An explicit marker decides
  # outright — only an *absent* marker falls back to the install manifest.
  if ! is_plugin_root; then
    case "$(file_scope "$PROJECT_DIR/$rel")" in
      # plugin-only → framework-governed, never the adopter's to own.
      plugin-only) return 1 ;;
      # consumer/any → adopter-owned: enforce normally even if the file is still
      # listed in the manifest (a stale manifest entry must not mask it).
      consumer|any) return 0 ;;
    esac
    # Marker absent (`none`): fall back to install-manifest membership
    # (back-compat for unmarked framework files vendored before the marker).
    if manifest_manages_path "$rel"; then
      return 1
    fi
  fi
  return 0
}

is_generated_source_artifact() {
  local rel="$1"
  case "$rel" in
    */__pycache__/*|*.pyc) return 0 ;;
  esac
  return 1
}

# Scan the contiguous leading comment block of $1 for a `<prefix> owner: <name>`
# marker (#859), tolerating a shebang and other leading comment/banner lines so
# a generated provenance banner is recognized. $2 = comment prefix. Echoes the
# owner name or nothing. Stops at the first non-comment, non-blank line.
leading_block_owner_marker() {
  local file="$1" prefix="$2"
  [ -n "$prefix" ] || return 0
  awk -v p="$prefix" '
    { sub(/\r$/, "", $0) }   # strip trailing CR so CRLF-authored files match (#859 B4 / cross-platform)
    NR==1 && /^#!/ { next }
    /^<\?php/ && !php_skipped { php_skipped=1; next }   # skip the PHP opener (after an optional shebang) before the // owner: line (#859 B4)
    {
      if ($0 ~ /^[[:space:]]*$/) next
      plen = length(p)
      if (substr($0, 1, plen) == p) {
        rest = substr($0, plen + 1)
        if (rest ~ /^ owner: [a-z][a-z0-9-]*$/) { sub(/^ owner: /, "", rest); print rest; exit }
        next
      }
      exit
    }
  ' "$file"
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

# ── Check 7 content-aware drift classifier (issue #238) ──────────────
# Decide whether the NET change in an owned file since its spec's last
# commit is benign (no real drift) or a genuine behaviour change.
# Verdict: "benign" | "drift" | "unknown". Tier 1 is deterministic;
# Tiers 2/3 are extension seams that pass through ("unknown"). Design
# D2 fail-safe: a non-benign verdict (including all "unknown") is drift.
# Callers run after PROJECT_DIR is set; functions capture it at call time.

# Line-comment prefix for a path, or "" if unknown (fail-safe: unknown
# file types can never be classified benign on the comment basis).
# Markdown (.md) is intentionally excluded: a leading `#` in Markdown is a
# heading (document content), not a line comment — treating it as one would
# hide real heading/prose edits to owned .md specs/contracts (#238 review).
# Single source of recognized source-file comment syntax (#859). `ext:prefix`
# pairs, space-separated (no prefix contains a space). Drives _comment_prefix
# (Check 7 benign-diff + owner-marker detection) AND the recognized-extension
# set. Markdown is intentionally absent: a leading `#` is a heading, not a
# comment. Data formats (yaml/yml) are recognized for comment-stripping but
# excluded from discovery (see _DISCOVERY_EXTS).
_COMMENT_PREFIX_MAP='sh:# bash:# py:# rb:# yaml:# yml:# sql:-- ts:// tsx:// js:// jsx:// mjs:// cjs:// go:// java:// scala:// rs:// kt:// swift:// c:// h:// cpp:// cc:// php://'

_comment_prefix() {
  local ext="${1##*.}" pair
  [ "$ext" = "$1" ] && return 0   # no extension → unknown
  for pair in $_COMMENT_PREFIX_MAP; do
    if [ "${pair%%:*}" = "$ext" ]; then printf '%s' "${pair#*:}"; return 0; fi
  done
  return 0
}

# Content of a file at a commit (empty if absent). Always called in an
# assignment/command-substitution context, which is exempt from `set -e`, so a
# non-zero `git show` (file absent at that commit) yields "" rather than
# aborting — "absent here, present at HEAD" then resolves to drift downstream.
_blob() { git -C "$PROJECT_DIR" show "$1:$2" 2>/dev/null; }

# Strip a COMPLETE leading Markdown/YAML frontmatter block (--- … ---) from
# stdin. If line 1 is `---` but there is no closing `---`, nothing is stripped
# (the original is emitted) — an unterminated marker must not eat the whole file
# and mask real changes (#238 review). Caller restricts this to .md files.
_strip_frontmatter() {
  awk '
    NR==1 && $0=="---" { open=1; buf=$0 ORS; next }
    open==1 && $0=="---" { open=2; buf=""; next }
    open==1 { buf=buf $0 ORS; next }
    { body=body $0 ORS }
    END { if (open==2) printf "%s", body; else printf "%s%s", buf, body }
  '
}

# Drop blank lines and whole-line comments (comment prefix = $1) from stdin.
_strip_comments_blank() {
  local p="$1"
  if [ -n "$p" ]; then grep -vE "^[[:space:]]*(${p}|\$)" || true
  else grep -vE "^[[:space:]]*\$" || true; fi
}

# Trim only LEADING and TRAILING whitespace per line. Internal whitespace is
# preserved, so a meaningful data change like `"a  b"` → `"a b"` is NOT masked
# as whitespace-only (#238 review).
_trim_ws() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# Tier 1: deterministic diff-class. Echoes benign|unknown.
# Strategy: apply a benign-class transform to BOTH versions and compare — if a
# single class of change fully accounts for the difference, it is benign.
# Comparing whole transformed blobs (not diff hunks) handles additions AND
# deletions symmetrically. Returns `unknown` (not `drift`) when no benign class
# matches, so the dispatcher consults later tiers; the dispatcher applies the
# D2 fail-safe (all-unknown → drift).
_tier1_diff_class() {
  local spec_commit="$1" file_rel="$2" a b prefix
  a="$(_blob "$spec_commit" "$file_rel")"
  b="$(_blob HEAD "$file_rel")"

  # (a) net-empty / pure rename.
  [ "$a" = "$b" ] && { printf benign; return; }

  # (b) whitespace-only (leading/trailing per line — never internal).
  [ "$(printf '%s' "$a" | _trim_ws)" = "$(printf '%s' "$b" | _trim_ws)" ] \
    && { printf benign; return; }

  # (c) frontmatter-only — Markdown front matter only (covers `owner:` keys).
  #     YAML `---` document markers are NOT frontmatter, so this never fires
  #     on .yaml/.yml owned files (#238 review).
  case "$file_rel" in
    *.md)
      [ "$(printf '%s' "$a" | _strip_frontmatter)" = "$(printf '%s' "$b" | _strip_frontmatter)" ] \
        && { printf benign; return; } ;;
  esac

  # (d) comment-only / `# owner:` marker only (known comment-prefix files).
  prefix="$(_comment_prefix "$file_rel")"
  if [ -n "$prefix" ]; then
    [ "$(printf '%s' "$a" | _strip_comments_blank "$prefix")" = "$(printf '%s' "$b" | _strip_comments_blank "$prefix")" ] \
      && { printf benign; return; }
  fi

  printf unknown
}

# Tier 2 (behaviour-surface) and Tier 3 (LLM semantic) — extension seams.
# Tier 1 returns `unknown` for diffs it cannot prove benign, so these tiers ARE
# reached for non-benign diffs; wiring real logic here needs no dispatcher edit.
_tier2_behaviour_surface() { printf unknown; }
_tier3_semantic()          { printf unknown; }

# Dispatcher: first benign|drift verdict wins; all-unknown → drift (D2 fail-safe).
classify_post_spec_diff() {
  local spec_commit="$1" file_rel="$2" v tier
  for tier in _tier1_diff_class _tier2_behaviour_surface _tier3_semantic; do
    v="$("$tier" "$spec_commit" "$file_rel")"
    [ "$v" = benign ] && { printf benign; return; }
    [ "$v" = drift ]  && { printf drift;  return; }
  done
  printf drift
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

# Languages Check 3 Half B *enforces* (flags unowned files) — opt-in, default
# [py] (today's behaviour, byte-for-byte). Same reader shape as
# _read_source_paths; charset is bare extensions [A-Za-z0-9_-]. A malformed
# block emits ERROR: on stderr and retains the [py] default. (#859)
SOURCE_LANGUAGES=(py)
# Languages explicitly acknowledged as NOT governed — silences Half C's
# undeclared-source-type nudge for deliberate exceptions. Default empty. (#859)
SOURCE_LANGUAGES_IGNORE=()

# Extensions Half C nudges about: recognized CODE source types (#859). DERIVED
# from _COMMENT_PREFIX_MAP (single source of truth — avoids the hand-maintained
# second-list drift class, #124) minus the carve-outs: sh/bash (governed by
# Half A's owner-marker scan) and data formats yaml/yml (recognized for
# comment-stripping but not governed-by-default). To govern one, add it to
# source_languages; to silence, add it to source_languages_ignore.
_DISCOVERY_EXTS=""
for _pair in $_COMMENT_PREFIX_MAP; do
  case "${_pair%%:*}" in
    sh|bash|yaml|yml) ;;
    *) _DISCOVERY_EXTS="$_DISCOVERY_EXTS ${_pair%%:*}" ;;
  esac
done

# Shared reader for the two source-language lists. $1 = config key. Echoes the
# validated, pipe-joined value list on stdout (empty when the key is absent,
# empty, or malformed) for the caller to `read -ra` into its own array — no
# indirect array assignment (avoids shellcheck SC2229). Mirrors
# _read_source_paths' PyYAML-or-fallback parse + token validation; a malformed
# block emits a stderr notice and echoes nothing, so the caller keeps its
# pre-seeded default.
_read_source_lang_list() {
  local key="$1"
  local config="$PROJECT_DIR/.arboretum.yml"
  [ -f "$config" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local raw
  raw=$(KEY="$key" python3 - "$config" <<'PYEOF' 2>/dev/null || true
import sys, os, re
path = sys.argv[1]
KEY = os.environ["KEY"]
TOKEN_RE = re.compile(r'^[A-Za-z0-9_-]+$')

def emit(vals):
    print('LANGS:' + '|'.join(vals))

def _bail(msg):
    print('ERROR:' + msg)
    emit([])
    sys.exit(0)

def _validate_list(raw):
    if raw is None:
        return [], None
    if not isinstance(raw, list):
        return None, f"{KEY} must be a YAML list, got {type(raw).__name__}"
    out = []
    for x in raw:
        if isinstance(x, (dict, list)):
            return None, f"{KEY} contains non-scalar entry: {x!r}"
        s = str(x).strip()
        if not s:
            continue
        if not TOKEN_RE.match(s):
            return None, (f"{KEY} contains invalid token {s!r} "
                          "— allowed characters: [A-Za-z0-9_-]")
        out.append(s)
    return out, None

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
    parsed = cfg.get(KEY)
else:
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
            if m and len(m.group(1)) == 0 and m.group(2) == KEY:
                val = m.group(3).strip()
                flow = parse_flow(val)
                if flow is not None:
                    parsed = flow
                    break
                if val:
                    parsed = val
                    break
                in_block = True
                items = []
            continue
        if bullet and len(bullet.group(1)) > 0:
            items.append(bullet.group(2).strip().strip('"').strip("'"))
            continue
        if m and len(m.group(1)) == 0:
            break
    if in_block:
        parsed = items

langs_v, err = _validate_list(parsed)
if err:
    _bail(err)
emit(langs_v)
PYEOF
)

  [ -z "$raw" ] && return 0

  local line
  while IFS= read -r line; do
    if [ "${line%%:*}" = "ERROR" ]; then
      echo "  · $key config rejected: ${line#ERROR:}" >&2
      return 0
    fi
  done <<< "$raw"

  local payload=""
  while IFS= read -r line; do
    case "${line%%:*}" in
      LANGS) payload="${line#*:}" ;;
    esac
  done <<< "$raw"

  # Echo the pipe-joined payload; the caller reads it into its own literal-named
  # array (avoids an indirect `read -ra "$name"`, which shellcheck flags SC2229).
  printf '%s' "$payload"
}

_sl_payload="$(_read_source_lang_list source_languages)"
[ -n "$_sl_payload" ] && IFS='|' read -ra SOURCE_LANGUAGES <<< "$_sl_payload"
_sli_payload="$(_read_source_lang_list source_languages_ignore)"
[ -n "$_sli_payload" ] && IFS='|' read -ra SOURCE_LANGUAGES_IGNORE <<< "$_sli_payload"

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
  echo "Summary: $blocking_count blocking finding(s) across $check_count checks."
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
#   and bin/* executables: first non-shebang line must be `# owner: <spec-name>`.
#   skills/*/SKILL.md: YAML frontmatter must carry an `owner:` key.
#   The named spec must exist at docs/specs/<name>.spec.md.
# Scan roots are fixed: scripts/, .claude/hooks/, bin/, skills/.
header "Check 3: Unowned source files"

unowned_count=0
skill_owner_re='^owner:[[:space:]]*([a-z][a-z0-9-]+)[[:space:]]*$'

# .sh files under scripts/ (excl _archived, _fixtures) and .claude/hooks/,
# plus bin/* — all use the first non-shebang `# owner:` convention.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  rel="${f#"$PROJECT_DIR"/}"
  if is_generated_source_artifact "$rel"; then
    continue
  fi
  # Leading-block scan (#859 B4): accept `# owner:` anywhere in the leading
  # comment block, so a generated framework .sh with a provenance banner above
  # its owner line resolves — consistent with the documented convention and Half B.
  owner_name=$(leading_block_owner_marker "$f" "#")
  if [ -n "$owner_name" ]; then
    if ! owner_doc_path "$owner_name" "$PROJECT_DIR" >/dev/null; then
      if missing_owner_spec_is_applicable "$rel"; then
        warn "Unowned: $rel — owner '$owner_name' has no spec at docs/specs/$owner_name.spec.md or group at docs/groups/$owner_name.md"
        ((unowned_count++)) || true
      else
        info "$rel: framework owner '$owner_name' spec is not installed in this root"
      fi
    fi
  else
    warn "Unowned: $rel — no '# owner:' marker in the leading comment block"
    ((unowned_count++)) || true
  fi
done < <(
  find "$PROJECT_DIR/scripts" \
       -type d \( -name _archived -o -name _fixtures \) -prune -o \
       -type f -name '*.sh' -print 2>/dev/null
  [ -d "$PROJECT_DIR/.claude/hooks" ] && \
    find "$PROJECT_DIR/.claude/hooks" -type f -name '*.sh' -print 2>/dev/null
  [ -d "$PROJECT_DIR/bin" ] && \
    find "$PROJECT_DIR/bin" \
         -type d -name __pycache__ -prune -o \
         -type f ! -name '*.pyc' -print 2>/dev/null
)

# skills/*/SKILL.md — YAML frontmatter `owner:` key.
if [ -d "$PROJECT_DIR/skills" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rel="${f#"$PROJECT_DIR"/}"
    owner_line=$(awk '/^---[[:space:]]*$/{n++; next} n>=2{exit} n==1 && /^owner:/{print; exit}' "$f")
    if [[ "$owner_line" =~ $skill_owner_re ]]; then
      owner_name="${BASH_REMATCH[1]}"
      if ! owner_doc_path "$owner_name" "$PROJECT_DIR" >/dev/null; then
        if missing_owner_spec_is_applicable "$rel"; then
          warn "Unowned: $rel — owner '$owner_name' has no spec at docs/specs/$owner_name.spec.md or group at docs/groups/$owner_name.md"
          ((unowned_count++)) || true
        else
          info "$rel: framework owner '$owner_name' spec is not installed in this root"
        fi
      fi
    else
      warn "Unowned: $rel — no 'owner:' key in YAML frontmatter"
      ((unowned_count++)) || true
    fi
  done < <(find "$PROJECT_DIR/skills" -type f -name 'SKILL.md' -print 2>/dev/null)
fi

# ── Group-spec layer membership integrity (#681) ─────────────────────
# Bidirectional parent/contains + group owns: ⇄ # owner: glue (D7). Vacuous
# on a group-free repo (exit 0, no docs/groups instances).
if bash "$(dirname "${BASH_SOURCE[0]}")/validate-group-membership.sh" "$PROJECT_DIR" >/dev/null 2>&1; then
  ok "Group-spec layer membership integrity holds"
else
  warn "Group-spec layer membership integrity violations — run scripts/validate-group-membership.sh"
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
  # Build the find name-expression from the enforced language set (#859):
  #   \( -name '*.py' -o -name '*.sql' ... \)
  find_lang_expr=()
  for _ext in "${SOURCE_LANGUAGES[@]}"; do
    [ ${#find_lang_expr[@]} -gt 0 ] && find_lang_expr+=(-o)
    find_lang_expr+=(-name "*.$_ext")
    # Advisory diagnostic (#859): an enforced language with no known comment
    # prefix can still be owned via owns: patterns, but in-file marker
    # detection cannot run for it. Surface that, do not block.
    if [ -z "$(_comment_prefix "x.$_ext")" ]; then
      advise "source_languages includes '$_ext' but no comment prefix is known — owner-marker detection cannot run for it (owns:-pattern coverage still applies)"
    fi
  done
  for src_dir in "${SOURCE_PATHS[@]}"; do
    [ -z "$src_dir" ] && continue
    [ ! -d "$PROJECT_DIR/$src_dir" ] && continue
    while IFS= read -r file; do
      rel_path="${file#"$PROJECT_DIR"/}"
      [[ "$rel_path" == *"__pycache__"* ]] && continue
      [[ "$rel_path" == *.pyc ]] && continue
      # Framework-governed by its own `# scope:` marker — out of the adopter's
      # ownership scope (#836). Primary signal; manifest-independent.
      if ! is_plugin_root && governed_by_framework_in_consumer_root "$file"; then
        continue
      fi
      owned=false
      while IFS=: read -r pattern _; do
        [ -z "$pattern" ] && continue
        if [[ "$pattern" == *"**"* ]]; then
          dir="${pattern%%\*\*}"
          if [[ "$rel_path" == "$dir"* ]]; then owned=true; break; fi
        elif [ "$rel_path" = "$pattern" ]; then owned=true; break; fi
      done <<< "$spec_owns_map"
      # Fall back to a resolvable in-file owner marker (#859): a file carrying
      # `<prefix> owner: <spec>` in its leading comment block is owned even when
      # not listed in any owns: pattern (mirrors Half A's .sh marker model, and
      # lets a generated provenance banner satisfy ownership).
      if [ "$owned" = false ]; then
        prefix="$(_comment_prefix "$rel_path")"
        if [ -n "$prefix" ]; then
          m_owner="$(leading_block_owner_marker "$file" "$prefix")"
          if [ -n "$m_owner" ] && owner_doc_path "$m_owner" "$PROJECT_DIR" >/dev/null; then
            owned=true
          fi
        fi
      fi
      if [ "$owned" = false ]; then
        warn "Unowned: $rel_path"
        ((unowned_count++)) || true
      fi
    done < <(find "$PROJECT_DIR/$src_dir" \( "${find_lang_expr[@]}" \) -type f 2>/dev/null)
  done
fi

[ "$unowned_count" -eq 0 ] && ok "All source files carry a resolvable owner"

# ── Check 3 Half C: undeclared source-type discovery (advisory, #859) ──
# Nudge (never block) when a recognized CODE source type is present in the
# source roots but declared in neither source_languages: (enforce) nor
# source_languages_ignore: (acknowledge). The safety net that keeps opt-in
# enforcement from silently missing un-governed source. advise(), not warn().
for _ext in $_DISCOVERY_EXTS; do
  _in_array "$_ext" "${SOURCE_LANGUAGES[@]}" && continue
  _in_array "$_ext" ${SOURCE_LANGUAGES_IGNORE[@]+"${SOURCE_LANGUAGES_IGNORE[@]}"} && continue
  _dcount=0
  for src_dir in "${SOURCE_PATHS[@]}"; do
    [ -z "$src_dir" ] && continue
    [ ! -d "$PROJECT_DIR/$src_dir" ] && continue
    _n=$(find "$PROJECT_DIR/$src_dir" -name "*.$_ext" -type f 2>/dev/null | wc -l | tr -d ' ')
    _dcount=$((_dcount + _n))
  done
  if [ "$_dcount" -gt 0 ]; then
    advise "Found $_dcount .$_ext file(s) not declared in source_languages — add '$_ext' to enforce ownership, or source_languages_ignore to acknowledge."
  fi
done

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

    def_file_path="$def_path"
    [[ "$def_file_path" == *.md ]] || def_file_path="${def_file_path}.md"
    def_file="$PROJECT_DIR/docs/$def_file_path"
    if [ ! -f "$def_file" ]; then
      advise "Definition not found: $def_path (pinned at $pinned_version in contracts.yaml)"
      ((stale_count++)) || true
      continue
    fi

    # Extract current version from definition file
    current_version=$(grep -A1 '^## Version' "$def_file" 2>/dev/null \
      | grep -oE 'v[0-9]+' | head -1 || true)

    if [ -z "$current_version" ]; then
      advise "$def_path: no version found in file (pinned at $pinned_version)"
      ((stale_count++)) || true
    elif [ "$current_version" != "$pinned_version" ]; then
      advise "$def_path: pinned=$pinned_version, current=$current_version — STALE"
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
    # - active-state spec with no owned files: legitimate ONLY when the
    #   spec declares governs-narrative:. The field cites a narrative
    #   section the spec governs inside a shared document (e.g. an
    #   ARCHITECTURE.md section). Without governs-narrative:, the
    #   conjunction is a write-time contradiction (#176; closed by
    #   docs/contracts/health-check.contract.md §HC-4).
    # - stale-state spec (drift previously recorded, awaits /consolidate)
    if _in_array "$status" "${STATUS_ACTIVE_STATES[@]}"; then
      if [ -z "$owns" ] || [ "$owns" = "(none)" ] || [ "$owns" = "—" ]; then
        # Read governs-narrative: from spec frontmatter (between the
        # first two `---` markers). Uses awk so false matches inside
        # the spec's prose body don't trip the check. No `local` —
        # this block is inside a top-level while loop, not a function.
        #
        # The two `sub()` calls implement the YAML scalar value
        # extraction: first strip the key + leading whitespace, then
        # strip any trailing `# comment` (YAML inline comment) plus
        # any whitespace before it. Without the second strip, a spec
        # with `governs-narrative: # TODO` would extract "# TODO" and
        # bypass the strict-warn branch even though YAML semantics
        # make that value empty (Codex caught this in PR #356 review).
        governs_narrative=""
        if [ -f "$spec_file" ]; then
          governs_narrative=$(awk '
            /^---[[:space:]]*$/ { c++; if (c == 2) exit; next }
            c == 1 && /^governs-narrative:/ {
              sub(/^governs-narrative:[[:space:]]*/, "")
              sub(/[[:space:]]*#.*$/, "")
              print
              exit
            }
          ' "$spec_file")
          # Trim surrounding whitespace with sed (NOT xargs — xargs treats
          # quotes as shell-quoting and exits non-zero on values like
          # `Owner's Guide`, which under `set -euo pipefail` aborts the
          # whole script. Codex caught this in PR #356 round-3 review.)
          governs_narrative=$(printf '%s' "$governs_narrative" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
          # Normalize YAML null spellings: a value of literal `null` or `~`
          # is YAML-semantically empty. Without this normalization, a spec
          # with `governs-narrative: null` would bypass the strict-warn
          # branch (Codex round-3 finding, same bypass class as the
          # inline-comment case round 2 fixed).
          case "$governs_narrative" in
            "null"|"~") governs_narrative="" ;;
          esac
        fi
        if [ -n "$governs_narrative" ]; then
          info "$spec: status=$status but owns no files (governs narrative: $governs_narrative)"
        else
          warn "$spec: status=$status but owns no files AND no governs-narrative declared — contradiction (see docs/contracts/health-check.contract.md §HC-4)"
        fi
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

# #750: --all is only meaningful with --reconcile. Report it as a no-op modifier
# rather than silently ignoring it (contract: "reported as a no-op modifier, not
# an error"). info() is exit-neutral, so this never affects the exit code.
if [ "$RECONCILE" = false ] && [ "$RECONCILE_ALL" = true ]; then
  info "--all has no effect without --reconcile"
fi

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
# #750: branch-scope for --reconcile. Resolve the set of files changed on the
# current branch vs the integration base ONCE, before the per-spec loop. With
# --all (RECONCILE_ALL) scoping is skipped (repo-wide flip). scope_mode:
#   all        — repo-wide (no --reconcile, or --reconcile --all)
#   scoped     — flip only specs whose owned files are in the branch diff
#   on-base    — HEAD is the integration base (merge-base == HEAD): flip nothing
#   unresolved — no integration base resolves: flip nothing
# The ( cd "$PROJECT_DIR" ... ) subshell honours the PROJECT_DIR-isolation
# invariant (explicit project root, never silent caller-CWD) while reusing
# workspace-context.sh's CWD-relative base resolver. The script's own lib dir is
# resolved to an ABSOLUTE path first, so the inner `cd` to PROJECT_DIR (a tree
# that may differ from where this script lives) cannot mis-resolve the source.
scope_mode=all
scope_changed_files=""
out_of_scope_drift=0      # scoped: drifted specs whose drift is outside branch scope
unflipped_no_scope=0      # on-base/unresolved: drifted specs we declined to flip
if [ "$RECONCILE" = true ] && [ "$RECONCILE_ALL" = false ]; then
  scope_mode=scoped
  _hc_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  scope_changed_files="$(
    cd "$PROJECT_DIR" || exit 7
    # shellcheck source=/dev/null
    source "$_hc_script_dir/workspace-context.sh" 2>/dev/null || exit 7
    base="$(workspace_base_ref 2>/dev/null)" || exit 7
    [ -n "$base" ] || exit 7
    mb="$(git merge-base "$base" HEAD 2>/dev/null)" || exit 7
    head_sha="$(git rev-parse HEAD 2>/dev/null)" || exit 7
    # HEAD *is* the integration base → no branch-unique changes → degenerate.
    [ "$mb" = "$head_sha" ] && exit 8
    git diff --name-only "$mb" HEAD 2>/dev/null
  )" || case $? in 8) scope_mode=on-base ;; *) scope_mode=unresolved ;; esac
fi

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
  in_scope_drift=false   # #750: a drifted owned file that is also in branch scope

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
      owned_rel="${owned_file#"$PROJECT_DIR"/}"
      owned_last_commit=$(git -C "$PROJECT_DIR" log -1 --format=%H -- "$owned_rel" 2>/dev/null)
      [ -z "$owned_last_commit" ] && continue
      [ "$owned_last_commit" = "$spec_last_commit" ] && continue
      # spec_last_commit ancestor of owned_last_commit → owned committed
      # later. That makes it a drift CANDIDATE; classify the net change
      # to decide whether it is a real behaviour change (#238). Benign
      # diff-classes (frontmatter/owner-only, comment, whitespace,
      # net-empty, rename) are not drift; anything else flags (D2).
      if git -C "$PROJECT_DIR" merge-base --is-ancestor "$spec_last_commit" "$owned_last_commit" 2>/dev/null; then
        if [ "$(classify_post_spec_diff "$spec_last_commit" "$owned_rel")" = drift ]; then
          drift=true
          [ -z "$drift_file" ] && drift_file="$owned_rel"
          # #750: branch-scope is decided on the DRIFTED file, not on any owned
          # file. owned_rel is the concrete file the drift loop already resolved,
          # so membership is exact-line (no second glob matcher; handles spaces).
          # Non-scoped modes take the first drift; scoped mode keeps scanning for
          # a drifted file that is also in this branch's changed-file set.
          if [ "$scope_mode" = scoped ]; then
            if printf '%s\n' "$scope_changed_files" | grep -Fxq -- "$owned_rel"; then
              in_scope_drift=true
              drift_file="$owned_rel"
              break 2
            fi
          else
            break 2
          fi
        fi
      fi
    done
  done

  if [ "$drift" = true ]; then
    # No stale_state configured → warn-only, no mutation. This is a
    # supported configuration for projects that want drift surfaced but
    # don't want auto-flips (e.g. they manage status manually).
    if [ -z "$STATUS_STALE_STATE" ]; then
      advise "$spec: drift detected ($drift_file modified after spec's last commit $spec_last_commit) — no stale_state configured, not flipping"
      ((drift_flipped++)) || true
      continue
    fi

    # #750: branch-scope gate. Under scoped mode, only flip a spec when one of
    # its DRIFTED owned files is in this branch's changed-file set (in_scope_drift,
    # decided in the drift loop). on-base/unresolved modes flip nothing. Drift we
    # decline to flip is COUNTED here and reported once as a post-loop roll-up
    # (contract: "a single advisory roll-up") — no per-spec advisory, so a branch
    # over latent main-drift is not spammed (review finding B). drift_flipped is
    # still bumped so the "No drift detected" summary stays suppressed when real
    # drift exists.
    # (Skipped entirely when scope_mode=all, i.e. read-only or --reconcile --all.)
    if [ "$RECONCILE" = true ] && [ "$scope_mode" != all ]; then
      if [ "$scope_mode" != scoped ]; then
        ((unflipped_no_scope++)) || true
        ((drift_flipped++)) || true
        continue
      fi
      if [ "$in_scope_drift" = false ]; then
        ((out_of_scope_drift++)) || true
        ((drift_flipped++)) || true
        continue
      fi
    fi

    if [ "$RECONCILE" = true ]; then
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

      advise "$spec: flipped ${status} → ${STATUS_STALE_STATE} (drift: $drift_file modified after spec's last commit $spec_last_commit)"
    else
      advise "$spec: drift detected ($drift_file modified after spec's last commit $spec_last_commit) — run with --reconcile to update"
    fi
    ((drift_flipped++)) || true
  else
    ((no_drift_count++)) || true
  fi
done < <(grep -E '^\|.*\.spec' "$REGISTER" 2>/dev/null || true)

# #750: branch-scope roll-up for --reconcile — emitted only when drift was
# actually declined (count > 0). A clean --reconcile run on the integration
# branch (no drift) emits nothing here and stays exit 0 per HC-2 (review
# finding C: scope resolution must not, by itself, turn a clean run advisory).
if [ "$RECONCILE" = true ]; then
  case "$scope_mode" in
    unresolved) if [ "$unflipped_no_scope" -gt 0 ]; then advise "Check 7: $unflipped_no_scope drifted spec(s) not reconciled — no integration base resolved; run --reconcile --all for a repo-wide sweep"; fi ;;
    on-base)    if [ "$unflipped_no_scope" -gt 0 ]; then advise "Check 7: $unflipped_no_scope drifted spec(s) not reconciled — HEAD is the integration branch; run --reconcile --all for a repo-wide sweep"; fi ;;
    scoped)     if [ "$out_of_scope_drift" -gt 0 ]; then advise "Check 7: $out_of_scope_drift spec(s) have drift outside this branch's scope — not flipped; run --reconcile --all to reconcile repo-wide"; fi ;;
  esac
fi

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
      advise "$plan_name: test-prudent plan without a ## Tests section"
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
    in_bullets=$(awk -v target="in scope" '
      function starts_scope(line, scope) {
        line = tolower(line)
        return line ~ "^###[[:space:]]*" scope "([[:space:]:()]|$)" ||
               line ~ "^\\*\\*[[:space:]]*" scope ":[[:space:]]*\\*\\*[[:space:]]*$"
      }
      starts_scope($0, target) { found=1; next }
      found && (starts_scope($0, "in scope") || starts_scope($0, "out of scope")) { exit }
      found && /^- / { count++ }
      END { print count + 0 }
    ' "$claude")
    out_bullets=$(awk -v target="out of scope" '
      function starts_scope(line, scope) {
        line = tolower(line)
        return line ~ "^###[[:space:]]*" scope "([[:space:]:()]|$)" ||
               line ~ "^\\*\\*[[:space:]]*" scope ":[[:space:]]*\\*\\*[[:space:]]*$"
      }
      starts_scope($0, target) { found=1; next }
      found && (starts_scope($0, "in scope") || starts_scope($0, "out of scope")) { exit }
      found && /^- / { count++ }
      END { print count + 0 }
    ' "$claude")
    [ "$in_bullets" -lt 1 ] && \
      echo "WARN [strategic-anchor]: 'In scope' has no bullets" && issues=$((issues + 1))
    [ "$out_bullets" -lt 1 ] && \
      echo "WARN [strategic-anchor]: 'Out of scope' has no bullets" && issues=$((issues + 1))
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
      advise "${line#WARN }"
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

# Three-level severity exit (S2 #641): blocking wins over advisory.
if [ "$blocking_count" -gt 0 ]; then
  echo "DRIFT DETECTED: $blocking_count blocking finding(s) (✗) across $check_count checks."
  [ "$advisory_count" -gt 0 ] && echo "                plus $advisory_count advisory finding(s) (⚠)."
  echo ""
  echo "Review the issues above and resolve before implementing."
  echo "Do not auto-fix — the architecture owner approves changes."
  exit 1
elif [ "$advisory_count" -gt 0 ]; then
  echo "ADVISORIES: $advisory_count advisory finding(s) (⚠) across $check_count checks; no blocking drift."
  echo ""
  echo "Advisory findings are nudges, not blockers — address when convenient."
  exit 2
else
  echo "HEALTHY: No drift detected across $check_count checks."
  exit 0
fi
