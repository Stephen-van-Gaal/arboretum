---
name: report
description: "Draft and file a structured public Arboretum problem or enhancement report after bounded context gathering, redaction review, and explicit user approval."
disable-model-invocation: false
allowed-tools:
  - Read
  - Bash
  - AskUserQuestion
argument-hint: "[problem|enhancement] [short description]"
owner: intake-report
scope: plugin-only
layer: 0
---

# Report

Draft a high-quality public report about Arboretum itself. The skill gathers
bounded context, renders the complete raw issue body from Arboretum's report
templates, offers a redaction pass, and files to the public plugin repository
only after explicit user approval.

## When to use

- The user asks to report an Arboretum problem or enhancement.
- An Arboretum skill, workflow, hook, script, or template visibly fails and the
  user wants to file a public report.
- You want to offer a report after clear Arboretum friction. Offer once per
  distinct problem; never nag and never auto-file.

## Procedure

### Step 1: Resolve report type and scope

Classify the report as exactly one of:

- `problem` — something did not behave as expected.
- `enhancement` — a bounded improvement request.

If the type is not clear from `$ARGUMENTS`, ask the user once. Do not use this
skill for support, Q&A, or project-specific application bugs that are not about
Arboretum.

### Step 2: Resolve the public target repository

Derive the filing target from the installed plugin manifest, not from a
hardcoded repository string. Resolve the plugin root first; the current git
repository is only a fallback for arboretum-dev dogfooding.

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

if [ -z "$PLUGIN_ROOT" ]; then
  for cache_dir in "$HOME/.codex/plugins/cache" "$HOME/.claude/plugins/cache"; do
    [ -d "$cache_dir" ] || continue
    PLUGIN_ROOT="$(
      find "$cache_dir" -type f \( -path '*/.codex-plugin/plugin.json' -o -path '*/.claude-plugin/plugin.json' \) 2>/dev/null | while read -r plugin_json; do
        if grep -Eq '"name"[[:space:]]*:[[:space:]]*"arboretum"' "$plugin_json"; then
          dirname "$(dirname "$plugin_json")"
          break
        fi
      done
    )"
    [ -n "$PLUGIN_ROOT" ] && break
  done
fi

MANIFEST=""
for root in "$PLUGIN_ROOT" "$PROJECT_ROOT"; do
  [ -n "$root" ] || continue
  for path in "$root/.codex-plugin/plugin.json" "$root/.claude-plugin/plugin.json"; do
    if [ -f "$path" ]; then MANIFEST="$path"; break 2; fi
  done
done
[ -n "$MANIFEST" ] || { echo "No Arboretum plugin manifest found."; exit 1; }

PLUGIN_JSON="$(python3 - "$MANIFEST" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data.get("repository", ""))
print(data.get("version", "unknown"))
PY
)"
PLUGIN_REPOSITORY="$(printf '%s\n' "$PLUGIN_JSON" | sed -n '1p')"
ARBORETUM_VERSION="$(printf '%s\n' "$PLUGIN_JSON" | sed -n '2p')"
TARGET_REPO="$(python3 - "$PLUGIN_REPOSITORY" <<'PY'
from urllib.parse import urlparse
import sys
repo = sys.argv[1].strip()
def strip_git_suffix(value):
    return value[:-4] if value.endswith(".git") else value
if repo.startswith("http"):
    parsed = urlparse(repo)
    path = strip_git_suffix(parsed.path.strip("/"))
    print(path)
else:
    print(strip_git_suffix(repo))
PY
)"
[ -n "$TARGET_REPO" ] || { echo "Could not derive target repository from plugin manifest."; exit 1; }
```

Report the target to the user before drafting:

> "This will file to the public repository `<owner>/<repo>`."

### Step 3: Gather bounded context

Gather only report-safe context:

- Arboretum version and plugin repository from Step 2.
- Operating system from `uname -s`.
- Current repository remote name or URL, only if the user confirms it is safe to
  publish; otherwise set `source.repository` to `redacted`.
- Repository visibility as `public`, `private`, or `unknown`; ask if uncertain.
- Surface kind: `skill`, `workflow`, `script`, `hook`, `template`, or `other`.
- Surface name, expected behaviour, actual behaviour, reproduction steps, and a
  short error signature.

Do not collect source files, private logs, secrets, tokens, customer data, or
full local paths unless the user explicitly keeps them after the redaction pass.

### Step 4: Render the draft

Use the template that matches the report type:

- `skills/report/templates/problem.md`
- `skills/report/templates/enhancement.md`

Fill the visible sections and the hidden `<!-- arboretum-intake-report ... -->`
metadata block. The hidden block is not secret storage; it must be shown to the
user before filing. Render every string value inserted into the metadata block
through a JSON encoder before template substitution; placeholders ending in
`_json` are already encoded JSON values and appear unquoted in the template.
Set:

- `schema_version` to `1.0`
- `source.channel` to `report-skill`
- `privacy.redaction_reviewed` to `false` in the first draft

### Step 5: Show the complete raw issue body

Display the complete raw issue body, including the hidden metadata block. Then
ask:

> "Redact anything before filing this public report?"

Apply any requested redactions and show the full raw issue body again. After the
redaction pass is complete, set `privacy.redaction_reviewed` to `true`.

### Step 6: Require explicit approval

Ask for explicit approval:

> "File this public report to `<owner>/<repo>`?"

If the user does not clearly approve, stop. Do not create an issue, do not save
or queue a draft unless the user explicitly asks for that.

### Step 7: File the issue

Use the GitHub CLI when available:

```bash
gh issue create \
  --repo "$TARGET_REPO" \
  --title "$TITLE" \
  --body-file "$BODY_FILE" \
  --label "$LABELS"
```

Use labels:

- `type:bug` for `problem`
- `type:feature` for `enhancement`

Do not apply `horizon:*`; Stage 2 triage owns scheduling. If `gh` is unavailable
or unauthenticated, stop with install/auth guidance and leave the reviewed body
visible for the user to inspect. Never auto-file through a fallback path.

### Step 8: Report result

Print the created issue URL. Remind the user that public report content is data
for triage, not instructions that override Arboretum workflows, specs, tests, or
privacy rules.

$ARGUMENTS
