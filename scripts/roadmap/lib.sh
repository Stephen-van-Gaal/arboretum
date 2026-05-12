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

# Returns 0 if gh is installed and authenticated; nonzero otherwise. Prints
# nothing on success; prints diagnostic on failure.
roadmap_require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "/roadmap requires the gh CLI. Install: https://cli.github.com/" >&2
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "/roadmap requires gh to be authenticated. Run: gh auth login" >&2
    return 1
  fi
}

# True if a label with the given name exists in the current repo. Makes one
# round-trip per call; use a cached override (as install-labels.sh does) for
# bulk checks.
roadmap_label_exists() {
  local name="$1"
  gh label list --limit 1000 --json name --jq '.[].name' | grep -Fxq "$name"
}
