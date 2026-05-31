#!/usr/bin/env bash
# owner: roadmap
# Shared helpers for /roadmap and /idea skills. Source from other scripts; do
# not execute directly.


# Resolve project root. Prefers the git toplevel of the CWD (so worktrees
# resolve to their own root). Falls back to $CLAUDE_PROJECT_DIR (primary
# checkout) only when not inside a git repo, then to pwd.
roadmap_project_root() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$root" ]; then
    printf '%s\n' "$root"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
  else
    pwd
  fi
}

# Path to roadmap.config.yaml. Echoes nothing if it doesn't exist.
roadmap_config_path() {
  local root config
  root="$(roadmap_project_root)"
  config="$root/roadmap.config.yaml"
  [ -f "$config" ] && printf '%s\n' "$config"
}

# Read a top-level scalar from roadmap.config.yaml. Usage: roadmap_config_get wip_limit
# Prefers yq; falls back to python3 (stdlib only — no PyYAML required).
roadmap_config_get() {
  local key config
  key="$1"
  config="$(roadmap_config_path)"
  [ -z "$config" ] && return 1
  if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "roadmap_config_get: invalid key name: $key" >&2
    return 1
  fi
  if command -v yq >/dev/null 2>&1; then
    yq -r ".${key} // \"\"" "$config"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$config" "$key" <<'PYEOF'
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
  else
    echo "roadmap: yq or python3 required. Install yq: https://github.com/mikefarah/yq" >&2
    return 1
  fi
}

# Read a top-level list from roadmap.config.yaml (one element per line). Usage:
# roadmap_config_list component_values
# Handles block style (- item) and flow style ([a, b, c]).
roadmap_config_list() {
  local key config
  key="$1"
  config="$(roadmap_config_path)"
  [ -z "$config" ] && return 1
  if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "roadmap_config_list: invalid key name: $key" >&2
    return 1
  fi
  if command -v yq >/dev/null 2>&1; then
    yq -r ".${key}[]? // empty" "$config"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$config" "$key" <<'PYEOF'
import sys, re
def parse_list(path, key):
    items = []
    in_block = False
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            if in_block:
                m = re.match(r'^\s+-\s+(.*)', line)
                if m:
                    v = m.group(1).strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                        v = v[1:-1]
                    items.append(v)
                elif re.match(r'^\S', line):
                    break
                continue
            m = re.match(r'^' + re.escape(key) + r'\s*:\s*(.*)', line)
            if m:
                val = m.group(1).strip()
                if val.startswith('['):
                    for x in val.strip()[1:-1].split(','):
                        x = x.strip()
                        if x:
                            if len(x) >= 2 and x[0] == x[-1] and x[0] in ('"', "'"):
                                x = x[1:-1]
                            items.append(x)
                    return items
                in_block = True
    return items
for item in parse_list(sys.argv[1], sys.argv[2]):
    print(item)
PYEOF
  else
    echo "roadmap: yq or python3 required. Install yq: https://github.com/mikefarah/yq" >&2
    return 1
  fi
}

# Read a top-level scalar from a simple YAML config file. This intentionally
# mirrors roadmap_config_get's stdlib-only fallback because .arboretum.yml is
# small and uses only top-level scalar keys for framework settings.
roadmap_yaml_scalar_get() {
  local path="$1"
  local key="$2"
  [ -f "$path" ] || return 1
  if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "roadmap_yaml_scalar_get: invalid key name: $key" >&2
    return 1
  fi
  if command -v yq >/dev/null 2>&1; then
    yq -r ".${key} // \"\"" "$path"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$path" "$key" <<'PYEOF'
import sys, re
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    for line in f:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^" + re.escape(key) + r"\s*:\s*(.*)", line)
        if not m:
            continue
        val = re.sub(r"\s+#.*$", "", m.group(1)).strip()
        if val in ("", "null", "~"):
            print("")
        elif len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            print(val[1:-1])
        else:
            print(val)
        break
PYEOF
  else
    echo "roadmap: yq or python3 required. Install yq: https://github.com/mikefarah/yq" >&2
    return 1
  fi
}

# Backend selection. .arboretum.yml is the framework-level config surface;
# roadmap.config.yaml is accepted for compatibility with the original roadmap
# backend proposal. Missing/empty means GitHub so current projects keep working.
# shellcheck disable=SC2120 # Optional root arg is primarily used by callers.
roadmap_backend() {
  local root="${1:-}"
  local backend=""
  [ -n "$root" ] || root="$(roadmap_project_root)"
  if [ -f "$root/.arboretum.yml" ]; then
    backend="$(roadmap_yaml_scalar_get "$root/.arboretum.yml" backend 2>/dev/null || true)"
  fi
  if [ -z "$backend" ] && [ -f "$root/roadmap.config.yaml" ]; then
    backend="$(roadmap_yaml_scalar_get "$root/roadmap.config.yaml" backend 2>/dev/null || true)"
  fi
  case "$backend" in
    ""|github) printf '%s\n' "github" ;;
    azure|ado|azure-devops) printf '%s\n' "azure-devops" ;;
    *) printf '%s\n' "$backend" ;;
  esac
}

roadmap_require_backend() {
  local backend="${1:-$(roadmap_backend)}"
  case "$backend" in
    github)
      if ! command -v gh >/dev/null 2>&1; then
        echo "/roadmap requires the gh CLI for backend=github. Install: https://cli.github.com/" >&2
        return 1
      fi
      if ! gh auth status >/dev/null 2>&1; then
        echo "/roadmap requires gh to be authenticated for backend=github. Run: gh auth login" >&2
        return 1
      fi
      ;;
    azure-devops)
      echo "/roadmap backend=azure-devops is not implemented in this checkout yet. Use backend=github or install a future arboretum-tracker Azure adapter." >&2
      return 1
      ;;
    *)
      echo "/roadmap unsupported backend: $backend" >&2
      return 1
      ;;
  esac
}

# Backward-compatible alias for older scripts while they migrate to the
# backend-neutral helper names.
roadmap_require_gh() {
  roadmap_require_backend github
}

roadmap_tracker_issue_list() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh issue list "$@" ;;
    *) echo "roadmap_tracker_issue_list: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_issue_show() {
  local issue="$1"
  shift
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh issue view "$issue" "$@" ;;
    *) echo "roadmap_tracker_issue_show: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_issue_comment() {
  local issue="$1"
  shift
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh issue comment "$issue" "$@" ;;
    *) echo "roadmap_tracker_issue_comment: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_issue_update() {
  local issue="$1"
  shift
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh issue edit "$issue" "$@" ;;
    *) echo "roadmap_tracker_issue_update: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_issue_close() {
  local issue="$1"
  shift
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh issue close "$issue" "$@" ;;
    *) echo "roadmap_tracker_issue_close: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_issue_create() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh issue create "$@" ;;
    *) echo "roadmap_tracker_issue_create: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_label_list() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh label list "$@" ;;
    *) echo "roadmap_tracker_label_list: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_label_create() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh label create "$@" ;;
    *) echo "roadmap_tracker_label_create: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_issue_comments() {
  local issue="$1"
  shift
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh api "repos/{owner}/{repo}/issues/$issue/comments" "$@" ;;
    *) echo "roadmap_tracker_issue_comments: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_pr_list() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh pr list "$@" ;;
    *) echo "roadmap_tracker_pr_list: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

# True if a label with the given name exists in the current repo. Makes one
# round-trip per call; use a cached override (as install-labels.sh does) for
# bulk checks.
roadmap_label_exists() {
  local name="$1"
  roadmap_tracker_label_list --limit 1000 --json name --jq '.[].name' | grep -Fxq "$name"
}

# ── Phase 1.5: Pulse file helpers ─────────────────────────────────────
# Read/write .arboretum/roadmap-pulse.json.
# All helpers are fail-silent: missing file → empty return, not error.

# Path to the pulse state file. Echoes nothing if project root is unknown.
roadmap_pulse_path() {
  local root
  root="$(roadmap_project_root)"
  [ -z "$root" ] && return 0
  printf '%s\n' "$root/.arboretum/roadmap-pulse.json"
}

# Bootstrap pulse file if it does not exist (idempotent: no-op if present).
# Seeds last_*_run = now and pre-populates nag_last_fired with now for all
# known nag names — "bootstrap-as-today" ensures no nag fires on install day.
roadmap_pulse_bootstrap() {
  local path
  path="$(roadmap_pulse_path)"
  [ -z "$path" ] && return 0
  [ -f "$path" ] && return 0
  mkdir -p "$(dirname "$path")"
  local now tmp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="${path}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ts "$now" '{
      bootstrapped_at: $ts,
      last_maintain_run: $ts,
      last_revise_run: $ts,
      last_retro_completed: null,
      nag_last_fired: {
        "strategic-review-due": $ts,
        "maintain-overdue": $ts,
        "stale-flagged-today": $ts,
        "agent-ready-while-WIP-full": $ts,
        "profile-graduation-lean": $ts
      },
      sprint_alerts_fired: {}
    }' > "$tmp" 2>/dev/null \
      && mv "$tmp" "$path" || true
  else
    python3 - "$now" "$tmp" <<'PYEOF' 2>/dev/null || true
import json, sys
ts = sys.argv[1]
tmp = sys.argv[2]
nags = ['strategic-review-due','maintain-overdue','stale-flagged-today',
        'agent-ready-while-WIP-full','profile-graduation-lean']
with open(tmp, 'w') as f:
    json.dump({
        'bootstrapped_at': ts,
        'last_maintain_run': ts,
        'last_revise_run': ts,
        'last_retro_completed': None,
        'nag_last_fired': {n: ts for n in nags},
        'sprint_alerts_fired': {}
    }, f, indent=2)
    f.write('\n')
PYEOF
    [ -f "$tmp" ] && mv "$tmp" "$path" 2>/dev/null || true
  fi
}

# Read a top-level scalar field from the pulse JSON.
# Returns empty string if field is absent, null, or file missing.
roadmap_pulse_get_field() {
  local key="$1"
  local path
  path="$(roadmap_pulse_path)"
  [ -z "$path" ] || [ ! -f "$path" ] && return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty' "$path" 2>/dev/null || true
  else
    python3 - "$path" "$key" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get(sys.argv[2])
    if v is not None:
        print(v)
except Exception:
    pass
PYEOF
  fi
}

# Read nag_last_fired[<name>]. Returns empty string if not yet fired.
roadmap_pulse_get_nag() {
  local name="$1"
  local path
  path="$(roadmap_pulse_path)"
  [ -z "$path" ] || [ ! -f "$path" ] && return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg n "$name" '.nag_last_fired[$n] // empty' "$path" 2>/dev/null || true
  else
    python3 - "$path" "$name" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get('nag_last_fired', {}).get(sys.argv[2])
    if v is not None:
        print(v)
except Exception:
    pass
PYEOF
  fi
}

# Record that a nag fired: update nag_last_fired[<name>] to now.
# Writes atomically via .tmp file; silently skips on any error.
roadmap_pulse_set_nag_fired() {
  local name="$1"
  local path
  path="$(roadmap_pulse_path)"
  [ -z "$path" ] || [ ! -f "$path" ] && return 0
  local now tmp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="${path}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    jq --arg n "$name" --arg ts "$now" \
      '.nag_last_fired[$n] = $ts' "$path" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$path" || true
  else
    python3 - "$path" "$name" "$now" "$tmp" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    d.setdefault('nag_last_fired', {})[sys.argv[2]] = sys.argv[3]
    with open(sys.argv[4], 'w') as f:
        json.dump(d, f, indent=2)
        f.write('\n')
except Exception:
    pass
PYEOF
    [ -f "$tmp" ] && mv "$tmp" "$path" 2>/dev/null || true
  fi
}

# Update a top-level scalar field (e.g., last_maintain_run after /roadmap maintain).
# Usage: roadmap_pulse_update_field last_maintain_run "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
roadmap_pulse_update_field() {
  local key="$1" value="$2"
  local path
  path="$(roadmap_pulse_path)"
  [ -z "$path" ] || [ ! -f "$path" ] && return 0
  local tmp="${path}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$path" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$path" || true
  else
    python3 - "$path" "$key" "$value" "$tmp" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    d[sys.argv[2]] = sys.argv[3]
    with open(sys.argv[4], 'w') as f:
        json.dump(d, f, indent=2)
        f.write('\n')
except Exception:
    pass
PYEOF
    [ -f "$tmp" ] && mv "$tmp" "$path" 2>/dev/null || true
  fi
}
