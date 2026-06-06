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
    local yq_out
    if yq_out="$(yq -r ".${key}[]?" "$config" 2>/dev/null)"; then
      [ -n "$yq_out" ] && printf '%s\n' "$yq_out"
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
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
  local yaml_file="$1"
  local key="$2"
  [ -f "$yaml_file" ] || return 1
  if ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "roadmap_yaml_scalar_get: invalid key name: $key" >&2
    return 1
  fi
  if command -v yq >/dev/null 2>&1; then
    yq -r ".${key} // \"\"" "$yaml_file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$yaml_file" "$key" <<'PYEOF'
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

roadmap_yaml_nested_scalar_get() {
  local yaml_file="$1"
  local section="$2"
  local key="$3"
  [ -f "$yaml_file" ] || return 1
  if ! [[ "$section" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] \
     || ! [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "roadmap_yaml_nested_scalar_get: invalid section/key name: $section.$key" >&2
    return 1
  fi
  if command -v yq >/dev/null 2>&1; then
    yq -r ".${section}.${key} // \"\"" "$yaml_file"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$yaml_file" "$section" "$key" <<'PYEOF'
import re, sys
path, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
in_section = False
with open(path) as f:
    for raw in f:
        line = raw.rstrip("\n")
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if not line.startswith((" ", "\t")):
            if re.match(r"^" + re.escape(section) + r"\s*:\s*(?:#.*)?$", line):
                in_section = True
                continue
            if in_section:
                break
        if not in_section:
            continue
        m = re.match(r"^[ \t]+" + re.escape(key) + r"\s*:\s*(.*)", line)
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
    [ -n "$backend" ] || backend="$(roadmap_yaml_nested_scalar_get "$root/.arboretum.yml" roadmap backend 2>/dev/null || true)"
  fi
  if [ -z "$backend" ] && [ -f "$root/roadmap.config.yaml" ]; then
    backend="$(roadmap_yaml_scalar_get "$root/roadmap.config.yaml" backend 2>/dev/null || true)"
    [ -n "$backend" ] || backend="$(roadmap_yaml_nested_scalar_get "$root/roadmap.config.yaml" roadmap backend 2>/dev/null || true)"
  fi
  case "$backend" in
    ""|github) printf '%s\n' "github" ;;
    azure|ado|azure-devops) printf '%s\n' "azure-devops" ;;
    *) printf '%s\n' "$backend" ;;
  esac
}

roadmap_backend_config_get() {
  local key="$1"
  local root="${2:-}"
  local value=""
  local nested_key=""
  local file=""
  [ -n "$root" ] || root="$(roadmap_project_root)"
  for file in "$root/.arboretum.yml" "$root/roadmap.config.yaml"; do
    [ -f "$file" ] || continue
    value="$(roadmap_yaml_scalar_get "$file" "$key" 2>/dev/null || true)"
    [ -n "$value" ] && break

    case "$key" in
      azure_devops_*)
        nested_key="${key#azure_devops_}"
        value="$(roadmap_yaml_nested_scalar_get "$file" azure_devops "$nested_key" 2>/dev/null || true)"
        if [ -z "$value" ] && [ "$nested_key" = "work_item_type" ]; then
          value="$(roadmap_yaml_nested_scalar_get "$file" azure_devops default_work_item_type 2>/dev/null || true)"
        fi
        [ -n "$value" ] && break
        ;;
    esac
  done
  [ -n "$value" ] && printf '%s\n' "$value"
}

roadmap_trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

roadmap_csv_lines() {
  printf '%s\n' "$1" | tr ',' '\n'
}

roadmap_csv_has_field() {
  local csv="$1" needle="$2" field
  while IFS= read -r field; do
    field="$(roadmap_trim "$field")"
    [ "$field" = "$needle" ] && return 0
  done < <(roadmap_csv_lines "$csv")
  return 1
}

roadmap_tracker_apply_json_options() {
  local json_fields="$1"
  local jq_filter="$2"
  local data
  data="$(cat)"
  if [ -n "$json_fields" ]; then
    data="$(printf '%s' "$data" | jq --arg fields "$json_fields" '
      ($fields | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0))) as $keep
      | def project:
          with_entries(select(.key as $k | $keep | index($k)));
      if type == "array" then map(project)
      elif type == "object" then project
      else . end
    ')" || return $?
  fi
  if [ -n "$jq_filter" ]; then
    printf '%s' "$data" | jq -r "$jq_filter"
  else
    printf '%s\n' "$data"
  fi
}

roadmap_ado_config_get() {
  local key="$1"
  local fallback="${2:-}"
  local root="${3:-}"
  local value
  value="$(roadmap_backend_config_get "$key" "$root" 2>/dev/null || true)"
  [ -n "$value" ] || value="$fallback"
  printf '%s\n' "$value"
}

roadmap_ado_organization() {
  local root="${1:-}"
  local value
  value="$(roadmap_backend_config_get azure_devops_organization "$root" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(roadmap_backend_config_get ado_organization "$root" 2>/dev/null || true)"
  [ -n "$value" ] || value="${AZURE_DEVOPS_ORG_SERVICE_URL:-${AZURE_DEVOPS_EXT_ORG:-}}"
  if [ -z "$value" ] && command -v az >/dev/null 2>&1; then
    value="$(az devops configure --list 2>/dev/null | awk -F= '
      /^[[:space:]]*organization[[:space:]]*=/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit
      }' || true)"
  fi
  case "$value" in
    ""|http://*|https://*) ;;
    dev.azure.com/*) value="https://$value" ;;
    *) value="https://dev.azure.com/$value" ;;
  esac
  [ -n "$value" ] && printf '%s\n' "$value"
}

roadmap_ado_project() {
  local root="${1:-}"
  local value
  value="$(roadmap_backend_config_get azure_devops_project "$root" 2>/dev/null || true)"
  [ -n "$value" ] || value="$(roadmap_backend_config_get ado_project "$root" 2>/dev/null || true)"
  [ -n "$value" ] || value="${AZURE_DEVOPS_PROJECT:-${SYSTEM_TEAMPROJECT:-}}"
  if [ -z "$value" ] && command -v az >/dev/null 2>&1; then
    value="$(az devops configure --list 2>/dev/null | awk -F= '
      /^[[:space:]]*project[[:space:]]*=/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit
      }' || true)"
  fi
  [ -n "$value" ] && printf '%s\n' "$value"
}

roadmap_ado_work_item_type() {
  roadmap_ado_config_get azure_devops_work_item_type "Issue"
}

roadmap_ado_done_state() {
  roadmap_ado_config_get azure_devops_done_state "Closed"
}

roadmap_ado_closed_states_joined() {
  local closed state quoted joined
  local quoted_states=()
  closed="$(roadmap_ado_config_get azure_devops_closed_states "Closed,Done,Removed")"
  while IFS= read -r state; do
    state="$(roadmap_trim "$state")"
    [ -n "$state" ] || continue
    quoted="$(roadmap_ado_wiql_string "$state")"
    quoted_states+=("$quoted")
  done < <(roadmap_csv_lines "$closed")
  if [ "${#quoted_states[@]}" -eq 0 ]; then
    quoted_states=("'Closed'" "'Done'" "'Removed'")
  fi
  joined="$(IFS=,; printf '%s' "${quoted_states[*]}")"
  printf '%s\n' "$joined"
}

roadmap_ado_state_is_closed() {
  local state="$1"
  local closed configured
  local closed_states=()
  state="$(roadmap_trim "$state")"
  configured="$(roadmap_ado_config_get azure_devops_closed_states "Closed,Done,Removed")"
  while IFS= read -r closed; do
    closed="$(roadmap_trim "$closed")"
    [ -n "$closed" ] || continue
    closed_states+=("$closed")
  done < <(roadmap_csv_lines "$configured")
  if [ "${#closed_states[@]}" -eq 0 ]; then
    closed_states=(Closed Done Removed)
  fi
  for closed in "${closed_states[@]}"; do
    [ "$state" = "$closed" ] && return 0
  done
  return 1
}

roadmap_ado_wiql_string() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "'%s'" "$escaped"
}

roadmap_ado_normalize_comments() {
  jq '
    def comment_array:
      if type == "array" then .
      elif (.value | type) == "array" then .value
      elif (.comments | type) == "array" then .comments
      else [] end;
    comment_array
    | map(select((.isDeleted // false) | not)
      | {
          body: (.body // .text // .renderedText // ""),
          createdAt: (.createdAt // .createdDate // .modifiedDate // ""),
          authorAssociation: "MEMBER"
        })
  '
}

roadmap_ado_normalize_work_items() {
  jq '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def labels_from_tags:
      (. // "" | tostring | split(";")
       | map(trim) | map(select(length > 0)) | unique | map({name: .}));
    def normalize:
      . as $item
      | ($item.fields // {}) as $f
      | {
          number: (($item.id // $f["System.Id"]) | tonumber? // ($item.id // $f["System.Id"])),
          title: ($f["System.Title"] // $item.title // ""),
          url: ($item._links.html.href // $item.url // ""),
          body: ($f["System.Description"] // $item.body // ""),
          labels: (($f["System.Tags"] // $item.tags // "") | labels_from_tags),
          createdAt: ($f["System.CreatedDate"] // $item.createdAt // ""),
          updatedAt: ($f["System.ChangedDate"] // $item.updatedAt // ""),
          closedAt: ($f["Microsoft.VSTS.Common.ClosedDate"] // $item.closedAt // ""),
          state: ($f["System.State"] // $item.state // ""),
          comments: ($item.comments // [])
        };
    if type == "array" then map(normalize)
    elif (.value | type) == "array" then (.value | map(normalize))
    else [normalize] end
  '
}

roadmap_ado_issue_comments_json() {
  local issue="$1"
  local org project raw
  local args=(devops invoke --area wit --resource workItemComments --route-parameters)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$project" ] && args+=("project=$project")
  args+=("workItemId=$issue" --api-version 7.1-preview.4 --output json --only-show-errors)
  [ -n "$org" ] && args+=(--organization "$org")
  raw="$(az "${args[@]}")" || return $?
  printf '%s' "$raw" | roadmap_ado_normalize_comments
}

roadmap_ado_enrich_items_with_comments() {
  local items="$1"
  local enriched="[]"
  local item issue comments
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    issue="$(printf '%s' "$item" | jq -r '.number')"
    comments="$(roadmap_ado_issue_comments_json "$issue")" || return $?
    item="$(printf '%s' "$item" | jq --argjson comments "$comments" '.comments = $comments')" || return $?
    enriched="$(printf '%s' "$enriched" | jq --argjson item "$item" '. + [$item]')" || return $?
  done < <(printf '%s' "$items" | jq -c '.[]')
  printf '%s\n' "$enriched"
}

roadmap_ado_normalize_label_args() {
  local raw part
  for raw in "$@"; do
    while IFS= read -r part; do
      part="$(roadmap_trim "$part")"
      [ -n "$part" ] && printf '%s\n' "$part"
    done < <(roadmap_csv_lines "$raw")
  done
}

roadmap_ado_merge_tags() {
  local current="$1"
  local adds="$2"
  local removes="$3"
  jq -Rrn --arg current "$current" --arg adds "$adds" --arg removes "$removes" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def split_semis($s): ($s | split(";") | map(trim) | map(select(length > 0)));
    def split_lines($s): ($s | split("\n") | map(trim) | map(select(length > 0)));
    (split_semis($current)) as $base
    | (split_lines($adds)) as $add_list
    | (split_lines($removes)) as $remove_list
    | (($base + $add_list)
       | unique
       | map(select(. as $tag | ($remove_list | index($tag) | not)))
       | join("; "))
  '
}

roadmap_ado_current_tags() {
  local issue="$1"
  local org project raw
  local args=(boards work-item show --id "$issue" --fields System.Tags --output json --only-show-errors)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  raw="$(az "${args[@]}")" || return $?
  printf '%s' "$raw" | jq -r '.fields["System.Tags"] // ""'
}

roadmap_ado_work_item_patch() {
  local issue="$1"
  local patch_json="$2"
  local org project tmp rc
  local args=(devops invoke --area wit --resource workItems --route-parameters)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$project" ] && args+=("project=$project")
  args+=("id=$issue" --http-method PATCH --media-type application/json-patch+json --api-version 7.1 --output none --only-show-errors)
  [ -n "$org" ] && args+=(--organization "$org")
  tmp="$(mktemp)"
  printf '%s' "$patch_json" > "$tmp"
  az "${args[@]}" --in-file "$tmp"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

roadmap_ado_markdown_to_html() {
  python3 -c '
import html
import re
import sys

text = sys.stdin.read()
lines = text.splitlines()
out = []
paragraph = []
list_open = False
code_open = False
code_lines = []
html_line = re.compile(
    r"^</?(?:h[1-6]|p|ul|ol|li|pre|code|strong|em|b|i|div|span|br|a|blockquote|table|thead|tbody|tr|td|th)(?:\s|>|/)",
    re.IGNORECASE,
)


def render_inline(value):
    escaped = html.escape(value, quote=False)
    escaped = re.sub(r"`([^`]+)`", lambda m: f"<code>{m.group(1)}</code>", escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", lambda m: f"<strong>{m.group(1)}</strong>", escaped)
    return escaped


def close_list():
    global list_open
    if list_open:
        out.append("</ul>")
        list_open = False


def flush_paragraph():
    if paragraph:
        joined = " ".join(paragraph)
        out.append(f"<p>{render_inline(joined)}</p>")
        paragraph.clear()


def is_existing_html(value):
    return (
        (value.startswith("<!--") and value.endswith("-->"))
        or html_line.match(value) is not None
    )


for line in lines:
    stripped = line.strip()

    if stripped.startswith("```"):
        flush_paragraph()
        close_list()
        if code_open:
            out.append(f"<pre><code>{html.escape(chr(10).join(code_lines), quote=False)}</code></pre>")
            code_lines.clear()
            code_open = False
        else:
            code_open = True
        continue

    if code_open:
        code_lines.append(line)
        continue

    if not stripped:
        flush_paragraph()
        close_list()
        continue

    if is_existing_html(stripped):
        flush_paragraph()
        close_list()
        out.append(stripped)
        continue

    heading = re.match(r"^(#{2,3})\s+(.+)$", stripped)
    if heading:
        flush_paragraph()
        close_list()
        level = len(heading.group(1))
        out.append(f"<h{level}>{render_inline(heading.group(2))}</h{level}>")
        continue

    item = re.match(r"^[-*]\s+(.+)$", stripped)
    if item:
        flush_paragraph()
        if not list_open:
            out.append("<ul>")
            list_open = True
        out.append(f"<li>{render_inline(item.group(1))}</li>")
        continue

    close_list()
    paragraph.append(stripped)

flush_paragraph()
close_list()
if code_open:
    out.append(f"<pre><code>{html.escape(chr(10).join(code_lines), quote=False)}</code></pre>")

sys.stdout.write("\n".join(out))
'
}

roadmap_ado_issue_list() {
  local state="open"
  local limit=""
  local search=""
  local json_fields=""
  local jq_filter=""
  local closed_after=""
  local token clause where wiql raw items comments_required
  local labels=()
  local clauses=("[System.TeamProject] = @project")
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --label) labels+=("$2"); shift 2 ;;
      --search) search="$2"; shift 2 ;;
      --json) json_fields="$2"; shift 2 ;;
      --jq) jq_filter="$2"; shift 2 ;;
      *) echo "roadmap_tracker_issue_list: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done

  case "$state" in
    open) clauses+=("[System.State] NOT IN ($(roadmap_ado_closed_states_joined))") ;;
    closed) clauses+=("[System.State] IN ($(roadmap_ado_closed_states_joined))") ;;
    all|"") ;;
    *) echo "roadmap_tracker_issue_list: unsupported azure-devops state: $state" >&2; return 2 ;;
  esac

  if [ "${#labels[@]}" -gt 0 ]; then
    for clause in "${labels[@]}"; do
      clauses+=("[System.Tags] CONTAINS $(roadmap_ado_wiql_string "$clause")")
    done
  fi

  for token in $search; do
    case "$token" in
      ""|is:open|is:issue) ;;
      is:closed) ;;
      no:label) clauses+=("[System.Tags] = ''") ;;
      closed:\>????-??-??) closed_after="${token#closed:>}" ;;
      *) echo "roadmap_tracker_issue_list: unsupported azure-devops search token: $token" >&2; return 2 ;;
    esac
  done
  if [ -n "$closed_after" ]; then
    clauses+=("[Microsoft.VSTS.Common.ClosedDate] >= $(roadmap_ado_wiql_string "${closed_after}T00:00:00Z")")
  fi

  where=""
  for clause in "${clauses[@]}"; do
    if [ -z "$where" ]; then
      where="$clause"
    else
      where="$where AND $clause"
    fi
  done
  wiql="SELECT [System.Id], [System.Title], [System.State], [System.Tags], [System.CreatedDate], [System.ChangedDate], [System.Description], [Microsoft.VSTS.Common.ClosedDate] FROM workitems WHERE $where"
  wiql+=" ORDER BY [System.ChangedDate] DESC"

  local org project
  local args=(boards query --wiql "$wiql" --output json --only-show-errors)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  raw="$(az "${args[@]}")" || return $?
  items="$(printf '%s' "$raw" | roadmap_ado_normalize_work_items)" || return $?
  if [ -n "$limit" ]; then
    if ! [[ "$limit" =~ ^[0-9]+$ ]]; then
      echo "roadmap_tracker_issue_list: --limit must be numeric for azure-devops" >&2
      return 2
    fi
    items="$(printf '%s' "$items" | jq --argjson limit "$limit" '.[:$limit]')" || return $?
  fi
  comments_required=false
  if roadmap_csv_has_field "$json_fields" comments; then
    comments_required=true
  fi
  if $comments_required; then
    items="$(roadmap_ado_enrich_items_with_comments "$items")" || return $?
  fi
  printf '%s' "$items" | roadmap_tracker_apply_json_options "$json_fields" "$jq_filter"
}

roadmap_ado_issue_show() {
  local issue="$1"
  shift
  local json_fields=""
  local jq_filter=""
  local org project raw item comments
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_fields="$2"; shift 2 ;;
      --jq) jq_filter="$2"; shift 2 ;;
      *) echo "roadmap_tracker_issue_show: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  local args=(boards work-item show --id "$issue" --expand all --output json --only-show-errors)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  raw="$(az "${args[@]}")" || return $?
  item="$(printf '%s' "$raw" | roadmap_ado_normalize_work_items | jq '.[0]')" || return $?
  if roadmap_csv_has_field "$json_fields" comments; then
    comments="$(roadmap_ado_issue_comments_json "$issue")" || return $?
    item="$(printf '%s' "$item" | jq --argjson comments "$comments" '.comments = $comments')" || return $?
  fi
  printf '%s' "$item" | roadmap_tracker_apply_json_options "$json_fields" "$jq_filter"
}

roadmap_ado_issue_comment() {
  local issue="$1"
  shift
  local body=""
  local org project
  while [ $# -gt 0 ]; do
    case "$1" in
      --body) body="$2"; shift 2 ;;
      --body-file) body="$(cat "$2")"; shift 2 ;;
      *) echo "roadmap_tracker_issue_comment: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  local args=(boards work-item update --id "$issue" --discussion "$body" --output none --only-show-errors)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  az "${args[@]}"
}

roadmap_ado_issue_update() {
  local issue="$1"
  shift
  local body=""
  local title=""
  local has_body=false
  local has_title=false
  local patch_ops="[]"
  local add_labels=()
  local remove_labels=()
  local current_tags adds removes updated_tags op patch_len
  while [ $# -gt 0 ]; do
    case "$1" in
      --body) body="$2"; has_body=true; shift 2 ;;
      --body-file) body="$(cat "$2")"; has_body=true; shift 2 ;;
      --title) title="$2"; has_title=true; shift 2 ;;
      --add-label) add_labels+=("$2"); shift 2 ;;
      --remove-label) remove_labels+=("$2"); shift 2 ;;
      *) echo "roadmap_tracker_issue_update: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  if $has_body; then
    body="$(printf '%s' "$body" | roadmap_ado_markdown_to_html)" || return $?
    patch_ops="$(printf '%s' "$patch_ops" | jq --arg body "$body" \
      '. + [{op:"add", path:"/fields/System.Description", value:$body}]')" || return $?
  fi
  if $has_title; then
    patch_ops="$(printf '%s' "$patch_ops" | jq --arg title "$title" \
      '. + [{op:"add", path:"/fields/System.Title", value:$title}]')" || return $?
  fi
  if [ "${#add_labels[@]}" -gt 0 ] || [ "${#remove_labels[@]}" -gt 0 ]; then
    current_tags="$(roadmap_ado_current_tags "$issue")" || return $?
    adds=""
    removes=""
    if [ "${#add_labels[@]}" -gt 0 ]; then
      adds="$(roadmap_ado_normalize_label_args "${add_labels[@]}")"
    fi
    if [ "${#remove_labels[@]}" -gt 0 ]; then
      removes="$(roadmap_ado_normalize_label_args "${remove_labels[@]}")"
    fi
    updated_tags="$(roadmap_ado_merge_tags "$current_tags" "$adds" "$removes")" || return $?
    if [ "$updated_tags" != "$current_tags" ]; then
      op="add"
      [ -n "$current_tags" ] && op="replace"
      patch_ops="$(printf '%s' "$patch_ops" | jq --arg op "$op" --arg tags "$updated_tags" \
        '. + [{op:$op, path:"/fields/System.Tags", value:$tags}]')" || return $?
    fi
  fi
  patch_len="$(printf '%s' "$patch_ops" | jq 'length')" || return $?
  [ "$patch_len" -eq 0 ] && return 0
  roadmap_ado_work_item_patch "$issue" "$patch_ops"
}

roadmap_ado_issue_close() {
  local issue="$1"
  shift
  local comment=""
  local org project
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) shift 2 ;;
      --comment) comment="$2"; shift 2 ;;
      --comment-file) comment="$(cat "$2")"; shift 2 ;;
      *) echo "roadmap_tracker_issue_close: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  local args=(boards work-item update --id "$issue" --state "$(roadmap_ado_done_state)" --output none --only-show-errors)
  [ -n "$comment" ] && args+=(--discussion "$comment")
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  az "${args[@]}"
}

roadmap_ado_issue_create() {
  local title=""
  local body=""
  local has_body=false
  local labels=()
  local org project tags raw
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; has_body=true; shift 2 ;;
      --body-file) body="$(cat "$2")"; has_body=true; shift 2 ;;
      --label) labels+=("$2"); shift 2 ;;
      *) echo "roadmap_tracker_issue_create: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  [ -n "$title" ] || { echo "roadmap_tracker_issue_create: --title is required for azure-devops" >&2; return 2; }
  local args=(boards work-item create --title "$title" --type "$(roadmap_ado_work_item_type)" --output json --only-show-errors)
  if $has_body; then
    body="$(printf '%s' "$body" | roadmap_ado_markdown_to_html)" || return $?
    args+=(--description "$body")
  fi
  if [ "${#labels[@]}" -gt 0 ]; then
    tags="$(roadmap_ado_merge_tags "" "$(roadmap_ado_normalize_label_args "${labels[@]}")" "")" || return $?
    [ -n "$tags" ] && args+=(--fields "System.Tags=$tags")
  fi
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  raw="$(az "${args[@]}")" || return $?
  printf '%s' "$raw" | roadmap_ado_normalize_work_items | jq '.[0]'
}

roadmap_ado_known_labels_json() {
  {
    printf '%s\n' \
      "type:epic" "type:feature" "type:bug" "type:spike" "type:refactor" "type:docs" "type:chore" \
      "horizon:now" "horizon:next" "horizon:later" \
      "appetite:small" "appetite:medium" "appetite:large" \
      "blocked" "agent-ready" "agent-prep:in-progress" "provisionally-resolved" "provisionally-stale"
    roadmap_config_list component_values 2>/dev/null | sed 's/^/component:/' || true
    roadmap_config_list audience_values 2>/dev/null | sed 's/^/audience:/' || true
  } | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | map({name: .})'
}

roadmap_ado_label_list() {
  local json_fields=""
  local jq_filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) shift 2 ;;
      --json) json_fields="$2"; shift 2 ;;
      --jq) jq_filter="$2"; shift 2 ;;
      *) echo "roadmap_tracker_label_list: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  roadmap_ado_known_labels_json | roadmap_tracker_apply_json_options "$json_fields" "$jq_filter"
}

roadmap_ado_label_create() {
  local name="${1:-}"
  [ -n "$name" ] || { echo "roadmap_tracker_label_create: label name is required" >&2; return 2; }
  # Azure DevOps tags are created on first use; schema installation is a no-op.
  return 0
}

roadmap_ado_issue_comments() {
  local issue="$1"
  shift
  local json_fields=""
  local jq_filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --paginate) shift ;;
      --json) json_fields="$2"; shift 2 ;;
      --jq) jq_filter="$2"; shift 2 ;;
      *) echo "roadmap_tracker_issue_comments: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  roadmap_ado_issue_comments_json "$issue" | roadmap_tracker_apply_json_options "$json_fields" "$jq_filter"
}

roadmap_ado_pr_list() {
  local json_fields=""
  local jq_filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --state|--limit|--json) [ "$1" = "--json" ] && json_fields="$2"; shift 2 ;;
      --jq) jq_filter="$2"; shift 2 ;;
      *) echo "roadmap_tracker_pr_list: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  printf '[]\n' | roadmap_tracker_apply_json_options "$json_fields" "$jq_filter"
}

roadmap_ado_pr_work_items_json() {
  local pr="$1"
  local org project raw
  local args=(repos pr work-item list --id "$pr" --output json --only-show-errors)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  raw="$(az "${args[@]}")" || return $?
  printf '%s' "$raw" | roadmap_ado_normalize_work_items
}

roadmap_ado_normalize_pull_request() {
  jq '
    {
      number: ((.pullRequestId // .id) | tonumber? // (.pullRequestId // .id)),
      title: (.title // ""),
      body: (.description // ""),
      state: (.status // ""),
      mergedAt: (.closedDate // .completionQueueTime // "")
    }
  '
}

roadmap_ado_pr_show() {
  local pr="$1"
  shift
  local json_fields=""
  local jq_filter=""
  local org project raw
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_fields="$2"; shift 2 ;;
      --jq) jq_filter="$2"; shift 2 ;;
      *) echo "roadmap_tracker_pr_show: unsupported azure-devops arg: $1" >&2; return 2 ;;
    esac
  done
  local args=(repos pr show --id "$pr" --output json --only-show-errors)
  project="$(roadmap_ado_project)"
  org="$(roadmap_ado_organization)"
  [ -n "$org" ] && args+=(--organization "$org")
  [ -n "$project" ] && args+=(--project "$project")
  raw="$(az "${args[@]}")" || return $?
  printf '%s' "$raw" | roadmap_ado_normalize_pull_request | roadmap_tracker_apply_json_options "$json_fields" "$jq_filter"
}

roadmap_github_pr_closure_status() {
  local pr="$1"
  local issue="$2"
  local raw tmp rc
  raw="$(roadmap_tracker_pr_show "$pr" --json number,body,state,mergedAt)" || return $?
  tmp="$(mktemp)"
  printf '%s' "$raw" > "$tmp"
  python3 - "$pr" "$issue" "$tmp" <<'PYEOF'
import json
import re
import sys

requested_pr = sys.argv[1]
issue = sys.argv[2]
path = sys.argv[3]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

body = str(data.get("body") or "")
number = str(data.get("number") or requested_pr)
state = str(data.get("state") or "")
merged = state.lower() == "merged" or bool(data.get("mergedAt"))
subject = f"Merged PR #{number}" if merged else f"PR #{number}"
issue_ref = "#" + issue

close_re = re.compile(
    r"\b(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)\s+"
    + re.escape(issue_ref)
    + r"\b",
    re.IGNORECASE,
)
ref_re = re.compile(re.escape(issue_ref) + r"\b", re.IGNORECASE)

if close_re.search(body):
    intent = "close"
    evidence = f"{subject} declares close intent for {issue_ref}"
elif ref_re.search(body):
    intent = "reference"
    evidence = f"{subject} references {issue_ref} without close intent"
else:
    intent = "none"
    evidence = f"{subject} does not reference {issue_ref}"

print("provider=github")
print(f"intent={intent}")
print("verification=supported")
print(f"evidence={evidence}")
PYEOF
  rc=$?
  rm -f "$tmp"
  return "$rc"
}

roadmap_ado_pr_closure_status() {
  local pr="$1"
  local issue="$2"
  local linked linked_item shown state
  [ -n "$pr" ] && [ -n "$issue" ] || {
    echo "roadmap_tracker_pr_closure_status: pr and issue are required" >&2
    return 2
  }
  if ! linked="$(roadmap_ado_pr_work_items_json "$pr")"; then
    printf '%s\n' \
      "provider=azure-devops" \
      "intent=unknown" \
      "verification=unknown" \
      "evidence=Azure DevOps PR #$pr linked work-item lookup failed"
    return 0
  fi
  linked_item="$(printf '%s' "$linked" | jq -c --arg issue "$issue" '
    [.[] | select((.number | tostring) == $issue)][0] // empty
  ')" || return $?
  if [ -z "$linked_item" ]; then
    printf '%s\n' \
      "provider=azure-devops" \
      "intent=none" \
      "verification=unknown" \
      "evidence=Azure DevOps PR #$pr does not link work item #$issue"
    return 0
  fi
  if ! shown="$(roadmap_ado_issue_show "$issue" --json number,state)"; then
    printf '%s\n' \
      "provider=azure-devops" \
      "intent=unknown" \
      "verification=unknown" \
      "evidence=Azure DevOps work item #$issue state lookup failed"
    return 0
  fi
  state="$(printf '%s' "$shown" | jq -r '.state // ""')" || return $?
  if roadmap_ado_state_is_closed "$state"; then
    printf '%s\n' \
      "provider=azure-devops" \
      "intent=close" \
      "verification=supported" \
      "evidence=Azure DevOps PR #$pr links work item #$issue and the work item is closed"
  else
    printf '%s\n' \
      "provider=azure-devops" \
      "intent=unknown" \
      "verification=unknown" \
      "evidence=Azure DevOps PR #$pr links work item #$issue but the work item is not closed"
  fi
}

roadmap_running_in_codex() {
  [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_SHELL:-}" ]
}

roadmap_print_codex_network_guidance() {
  local backend="$1"
  case "$backend" in
    github)
      cat >&2 <<'EOF'

This looks like Codex command network access may be blocked for GitHub.
To let sandboxed Codex commands reach GitHub without repeated escalation, add:

[sandbox_workspace_write]
network_access = true

[features.network_proxy]
enabled = true
domains = { "**.github.com" = "allow", "**.githubusercontent.com" = "allow" }

Also check GH_TOKEN and GITHUB_TOKEN. If either is set to a stale token, gh will
prefer it over keychain auth.
EOF
      ;;
    azure-devops)
      cat >&2 <<'EOF'

This looks like Codex command network access may be blocked for Azure DevOps.
To let sandboxed Codex commands reach Azure DevOps without repeated escalation,
add:

[sandbox_workspace_write]
network_access = true

[features.network_proxy]
enabled = true
domains = {
  "dev.azure.com" = "allow",
  "**.visualstudio.com" = "allow",
  "login.microsoftonline.com" = "allow"
}
EOF
      ;;
  esac
}

roadmap_probe_github_access() {
  local root="${1:-}"
  local err
  [ -n "$root" ] || root="$(roadmap_project_root)"
  roadmap_require_backend github || return $?
  err="$(mktemp)"
  if ( cd "$root" && gh api 'repos/{owner}/{repo}' --jq .full_name ) >/dev/null 2>"$err"; then
    rm -f "$err"
    return 0
  fi
  echo "/roadmap can read gh auth, but the GitHub API live-access probe failed in this agent process." >&2
  if [ -s "$err" ]; then
    sed 's/^/github probe: /' "$err" >&2
  fi
  rm -f "$err"
  if roadmap_running_in_codex; then
    roadmap_print_codex_network_guidance github
  fi
  return 1
}

roadmap_probe_ado_access() {
  local root="${1:-}"
  local org project err
  local args=(devops project show --output none --only-show-errors)
  [ -n "$root" ] || root="$(roadmap_project_root)"
  roadmap_require_backend azure-devops || return $?
  org="$(roadmap_ado_organization "$root" 2>/dev/null || true)"
  project="$(roadmap_ado_project "$root" 2>/dev/null || true)"
  if [ -z "$org" ] || [ -z "$project" ]; then
    echo "/roadmap could not resolve Azure DevOps organization/project for backend=azure-devops. Configure azure_devops.organization/project (or flat azure_devops_organization/azure_devops_project aliases), or set Azure DevOps CLI defaults." >&2
    return 1
  fi
  args+=(--organization "$org" --project "$project")
  err="$(mktemp)"
  if az "${args[@]}" >/dev/null 2>"$err"; then
    rm -f "$err"
    return 0
  fi
  echo "/roadmap can read Azure DevOps CLI defaults, but the Azure DevOps live-access probe failed in this agent process." >&2
  if [ -s "$err" ]; then
    sed 's/^/azure-devops probe: /' "$err" >&2
  fi
  rm -f "$err"
  if roadmap_running_in_codex; then
    roadmap_print_codex_network_guidance azure-devops
  fi
  return 1
}

roadmap_probe_backend_access() {
  local backend="${1:-$(roadmap_backend)}"
  local root="${2:-}"
  case "$backend" in
    github) roadmap_probe_github_access "$root" ;;
    azure-devops) roadmap_probe_ado_access "$root" ;;
    *)
      echo "/roadmap unsupported backend: $backend" >&2
      return 1
      ;;
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
      if ! command -v az >/dev/null 2>&1; then
        echo "/roadmap requires the Azure CLI for backend=azure-devops. Install: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
        return 1
      fi
      if ! command -v jq >/dev/null 2>&1; then
        echo "/roadmap requires jq for backend=azure-devops JSON normalization. Install jq: https://jqlang.github.io/jq/" >&2
        return 1
      fi
      if ! az devops -h >/dev/null 2>&1 || ! az boards -h >/dev/null 2>&1 || ! az repos -h >/dev/null 2>&1; then
        echo "/roadmap requires the Azure DevOps CLI extension for backend=azure-devops. Run: az extension add --name azure-devops" >&2
        return 1
      fi
      if ! az devops configure --list >/dev/null 2>&1; then
        echo "/roadmap could not read Azure DevOps CLI defaults. Authenticate with 'az devops login' and configure organization/project defaults." >&2
        return 1
      fi
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
    azure-devops) roadmap_ado_issue_list "$@" ;;
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
    azure-devops) roadmap_ado_issue_show "$issue" "$@" ;;
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
    azure-devops) roadmap_ado_issue_comment "$issue" "$@" ;;
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
    azure-devops) roadmap_ado_issue_update "$issue" "$@" ;;
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
    azure-devops) roadmap_ado_issue_close "$issue" "$@" ;;
    *) echo "roadmap_tracker_issue_close: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_issue_create() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh issue create "$@" ;;
    azure-devops) roadmap_ado_issue_create "$@" ;;
    *) echo "roadmap_tracker_issue_create: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_label_list() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh label list "$@" ;;
    azure-devops) roadmap_ado_label_list "$@" ;;
    *) echo "roadmap_tracker_label_list: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_label_create() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh label create "$@" ;;
    azure-devops) roadmap_ado_label_create "$@" ;;
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
    azure-devops) roadmap_ado_issue_comments "$issue" "$@" ;;
    *) echo "roadmap_tracker_issue_comments: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_pr_list() {
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh pr list "$@" ;;
    azure-devops) roadmap_ado_pr_list "$@" ;;
    *) echo "roadmap_tracker_pr_list: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_pr_show() {
  local pr="$1"
  shift
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) gh pr view "$pr" "$@" ;;
    azure-devops) roadmap_ado_pr_show "$pr" "$@" ;;
    *) echo "roadmap_tracker_pr_show: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

roadmap_tracker_pr_closure_status() {
  local pr="${1:-}"
  local issue="${2:-}"
  local backend="${ROADMAP_BACKEND:-$(roadmap_backend)}"
  [ -n "$pr" ] && [ -n "$issue" ] || {
    echo "roadmap_tracker_pr_closure_status: pr and issue are required" >&2
    return 2
  }
  roadmap_require_backend "$backend" || return $?
  case "$backend" in
    github) roadmap_github_pr_closure_status "$pr" "$issue" ;;
    azure-devops) roadmap_ado_pr_closure_status "$pr" "$issue" ;;
    *) echo "roadmap_tracker_pr_closure_status: unsupported backend: $backend" >&2; return 1 ;;
  esac
}

# True if a label with the given name exists in the current repo. Makes one
# round-trip per call; use a cached override (as install-labels.sh does) for
# bulk checks.
roadmap_label_exists() {
  local name="$1"
  roadmap_tracker_label_list --limit 1000 --json name --jq '.[].name' | grep -Fxq "$name"
}

# ── Epic-aware orientation (issue #562) ──────────────────────────────

# roadmap_github_epic_graph <next_up_number> — emit graph JSON on stdout.
# Fetches the next-up issue, its parent chain (up to 2 levels), and each
# epic's subIssues via a single GraphQL call. Returns empty graph on any
# gh/GraphQL failure (caller must treat non-zero exit as degrade).
# Native sub-issues only. Exits non-zero on gh/GraphQL failure.
roadmap_github_epic_graph() {
  local next_up="$1"
  [ -n "$next_up" ] || { printf '%s\n' '{"next_up":null,"nodes":{}}'; return 0; }
  local query='
    query($owner:String!,$repo:String!,$n:Int!){
      repository(owner:$owner,name:$repo){
        issue(number:$n){
          number state title body
          labels(first:20){nodes{name}}
          parent{ number state title body
            labels(first:20){nodes{name}}
            subIssues(first:50){nodes{number state title body labels(first:20){nodes{name}}}}
            parent{ number state title body
              labels(first:20){nodes{name}}
              subIssues(first:50){nodes{number state title body labels(first:20){nodes{name}}}} } }
          subIssues(first:50){nodes{number state title body labels(first:20){nodes{name}}}}
        } } }'
  local owner repo raw raw_file
  owner=$(gh repo view --json owner -q .owner.login 2>/dev/null) || return 1
  repo=$(gh repo view --json name -q .name 2>/dev/null) || return 1
  raw=$(gh api graphql -f query="$query" -F owner="$owner" -F repo="$repo" -F n="$next_up" 2>/dev/null) || return 1
  # Write raw to a temp file; pass as argv to python3 (mirror refresh-next-cache.sh temp-file pattern)
  raw_file=$(mktemp)
  printf '%s' "$raw" > "$raw_file"
  NEXT_UP="$next_up" python3 - "$raw_file" <<'PY'
import json, os, re, sys

_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s

STAGE_RE = re.compile(
    r"<!--\s*pipeline-state:current-stage\s*-->\s*\*\*Current\s+stage:\*\*\s*(\S+)"
)

def parse_stage(body):
    if not body:
        return None
    body = body.replace("\\n", "\n")
    m = STAGE_RE.search(body)
    return scrub(m.group(1)) if m else None

def node_from(issue, parent_num=None):
    if issue is None:
        return None
    num = issue.get("number")
    if num is None:
        return None
    labels = [scrub(ln["name"]) for ln in (issue.get("labels") or {}).get("nodes") or []]
    state = "open" if (issue.get("state") or "OPEN").upper() == "OPEN" else "closed"
    return {
        "number": num,
        "is_epic": "type:epic" in labels,
        "state": state,
        "title": scrub(issue.get("title") or ""),
        "labels": labels,
        "parent": parent_num,
        "children": [],
        "stage": parse_stage(issue.get("body") or ""),
    }

raw_path = sys.argv[1]
with open(raw_path, encoding="utf-8") as fh:
    data = json.load(fh)

next_up = int(os.environ["NEXT_UP"])
nodes = {}

def add_node(issue, parent_num=None):
    if issue is None:
        return
    n = node_from(issue, parent_num)
    if n is None:
        return
    num = n["number"]
    if num not in nodes:
        nodes[num] = n
    elif parent_num is not None and nodes[num]["parent"] is None:
        nodes[num]["parent"] = parent_num

repo_data = (data.get("data") or {}).get("repository") or {}
issue = repo_data.get("issue")
if issue is None:
    print(json.dumps({"next_up": next_up, "nodes": {}}))
    sys.exit(0)

# Flatten the next-up issue itself
add_node(issue, parent_num=None)

# Flatten its subIssues (direct children)
for sub in (issue.get("subIssues") or {}).get("nodes") or []:
    add_node(sub, parent_num=issue["number"])

# Flatten parent chain (up to 2 levels) and their subIssues
parent1 = issue.get("parent")
if parent1 is not None:
    add_node(parent1, parent_num=None)
    for sub in (parent1.get("subIssues") or {}).get("nodes") or []:
        add_node(sub, parent_num=parent1["number"])
    parent2 = parent1.get("parent")
    if parent2 is not None:
        add_node(parent2, parent_num=None)
        for sub in (parent2.get("subIssues") or {}).get("nodes") or []:
            add_node(sub, parent_num=parent2["number"])
        # Explicitly link parent1 → parent2 (don't rely on parent2.subIssues containing parent1)
        p1_num = parent1.get("number")
        p2_num = parent2.get("number")
        if p1_num is not None and p2_num is not None and p1_num in nodes and p2_num in nodes:
            nodes[p1_num]["parent"] = p2_num

# Set parent of the next-up issue using the actual parent link
if parent1 is not None and issue["number"] in nodes:
    nodes[issue["number"]]["parent"] = parent1["number"]

# Build children lists from parent back-refs
for num, n in nodes.items():
    p = n.get("parent")
    if p is not None and p in nodes:
        if num not in nodes[p]["children"]:
            nodes[p]["children"].append(num)

print(json.dumps({"next_up": next_up, "nodes": {str(k): v for k, v in nodes.items()}}, indent=2))
PY
  local rc=$?
  rm -f "$raw_file"
  return "$rc"
}

# roadmap_epic_graph <next_up> — backend-dispatched graph builder.
# Emits graph JSON on stdout. Always exits 0 (fail-soft): a github fetch
# failure (or empty output) degrades to an empty graph here, so direct
# callers need no extra guard.
roadmap_epic_graph() {
  local out
  case "${ROADMAP_BACKEND:-$(roadmap_backend)}" in
    github)
      if out=$(roadmap_github_epic_graph "$1" 2>/dev/null) && [ -n "$out" ]; then
        printf '%s\n' "$out"
      else
        printf '%s\n' '{"next_up":null,"nodes":{}}'
      fi
      ;;
    azure-devops) printf '%s\n' '{"next_up":null,"nodes":{}}' ;;   # v1: ADO native links deferred → degrade
    *)            printf '%s\n' '{"next_up":null,"nodes":{}}' ;;
  esac
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
  local pulse_file
  pulse_file="$(roadmap_pulse_path)"
  [ -z "$pulse_file" ] && return 0
  [ -f "$pulse_file" ] && return 0
  mkdir -p "$(dirname "$pulse_file")"
  local now tmp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="${pulse_file}.tmp"
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
      && mv "$tmp" "$pulse_file" || true
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
    [ -f "$tmp" ] && mv "$tmp" "$pulse_file" 2>/dev/null || true
  fi
}

# Read a top-level scalar field from the pulse JSON.
# Returns empty string if field is absent, null, or file missing.
roadmap_pulse_get_field() {
  local key="$1"
  local pulse_file
  pulse_file="$(roadmap_pulse_path)"
  [ -z "$pulse_file" ] || [ ! -f "$pulse_file" ] && return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty' "$pulse_file" 2>/dev/null || true
  else
    python3 - "$pulse_file" "$key" <<'PYEOF' 2>/dev/null || true
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
  local pulse_file
  pulse_file="$(roadmap_pulse_path)"
  [ -z "$pulse_file" ] || [ ! -f "$pulse_file" ] && return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg n "$name" '.nag_last_fired[$n] // empty' "$pulse_file" 2>/dev/null || true
  else
    python3 - "$pulse_file" "$name" <<'PYEOF' 2>/dev/null || true
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
  local pulse_file
  pulse_file="$(roadmap_pulse_path)"
  [ -z "$pulse_file" ] || [ ! -f "$pulse_file" ] && return 0
  local now tmp
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="${pulse_file}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    jq --arg n "$name" --arg ts "$now" \
      '.nag_last_fired[$n] = $ts' "$pulse_file" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$pulse_file" || true
  else
    python3 - "$pulse_file" "$name" "$now" "$tmp" <<'PYEOF' 2>/dev/null || true
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
    [ -f "$tmp" ] && mv "$tmp" "$pulse_file" 2>/dev/null || true
  fi
}

# Update a top-level scalar field (e.g., last_maintain_run after /roadmap maintain).
# Usage: roadmap_pulse_update_field last_maintain_run "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
roadmap_pulse_update_field() {
  local key="$1" value="$2"
  local pulse_file
  pulse_file="$(roadmap_pulse_path)"
  [ -z "$pulse_file" ] || [ ! -f "$pulse_file" ] && return 0
  local tmp="${pulse_file}.tmp"
  rm -f "$tmp" 2>/dev/null || true
  if command -v jq >/dev/null 2>&1; then
    jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$pulse_file" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$pulse_file" || true
  else
    python3 - "$pulse_file" "$key" "$value" "$tmp" <<'PYEOF' 2>/dev/null || true
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
    [ -f "$tmp" ] && mv "$tmp" "$pulse_file" 2>/dev/null || true
  fi
}
