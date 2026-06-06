#!/usr/bin/env bash
# owner: pipeline-state-tracking
# manage-trust.sh — Lifecycle helper for the journey-log author allowlist
# (.arboretum.yml trust.journey_log_authors). Subcommands:
#
#   instantiate <config> [<login>...]
#       Additive-only seed. Writes the trust block ONLY when the key is
#       absent; NEVER overwrites an existing allowlist. With no logins,
#       defaults to `gh api user` + github-actions[bot] (best-effort).
#   set <config> <login>...
#       Authoritative replace — write exactly these logins (create the
#       block if absent, replace the list if present). Human-driven.
#
# `maintain` (contribution-count review) is a deferred follow-up (#249 spec).
# Exit: 0 success; 1 bad args / config missing.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "manage-trust.sh requires bash" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$SCRIPT_DIR/read-trust-config.sh"

usage() { echo "Usage: manage-trust.sh {instantiate|set} <config> [<login>...]" >&2; exit 1; }

# Validate logins against the GitHub handle charset before writing them into
# YAML (#249 security review): alphanumeric + single internal hyphens, with an
# optional `[bot]` suffix for GitHub Apps. Rejects newlines / colons / spaces
# so no caller (now or later) can inject YAML structure via a crafted login.
_validate_logins() {
  local login
  for login in "$@"; do
    if ! printf '%s' "$login" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$'; then
      echo "manage-trust.sh: refusing invalid login handle: '$login' (expected GitHub login charset)" >&2
      exit 1
    fi
  done
}

# Append a fresh trust block (used when the key is absent).
_append_block() {
  local config="$1"; shift
  {
    echo ""
    echo "# Journey-log author allowlist (#249). GitHub login handles trusted as"
    echo "# authors of pipeline-state journey-log comments. Edit to add collaborators."
    echo "trust:"
    echo "  journey_log_authors:"
    local login
    for login in "$@"; do
      echo "    - $login"
    done
  } >> "$config"
}

CMD="${1:-}"; [ -n "$CMD" ] || usage; shift || usage
CONFIG="${1:-}"; [ -n "$CONFIG" ] || usage; shift || true
[ -f "$CONFIG" ] || { echo "manage-trust.sh: config not found: $CONFIG" >&2; exit 1; }

# Resolve present=yes|no, but FAIL LOUDLY if the reader can't parse the config
# (#249 review): a malformed .arboretum.yml must not be silently treated as
# "absent", which would append/overwrite a second trust block onto broken YAML.
_present() {
  local out
  if ! out="$(bash "$READER" "$CONFIG" 2>&1)"; then
    echo "manage-trust.sh: could not parse $CONFIG — fix the YAML before seeding trust:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s\n' "$out" | sed -n 's/^present=//p'
}

case "$CMD" in
  instantiate)
    # `$(_present)` runs in a subshell, so _present's exit-on-parse-error only
    # kills the substitution — capture its status with `|| exit` so a malformed
    # config aborts instantiate instead of silently appending (#249 review [2]).
    present_val="$(_present)" || exit 1
    if [ "$present_val" = "yes" ]; then
      echo "manage-trust.sh: trust.journey_log_authors already configured — leaving as-is."
      exit 0
    fi
    if [ "$#" -gt 0 ]; then
      _validate_logins "$@"
      _append_block "$CONFIG" "$@"
    else
      seed_login="$(gh api user --jq .login 2>/dev/null || true)"
      if [ -n "$seed_login" ]; then
        _append_block "$CONFIG" "$seed_login" "github-actions[bot]"
      else
        # gh unavailable: write a hinted block + bot and warn.
        {
          echo ""
          echo "# Journey-log author allowlist (#249). Add the GitHub login that runs the pipeline."
          echo "trust:"
          echo "  journey_log_authors:"
          echo "    # - <your-github-login>"
          echo "    - github-actions[bot]"
        } >> "$CONFIG"
        echo "manage-trust.sh: could not resolve gh login — add your login to trust.journey_log_authors in $CONFIG" >&2
      fi
    fi
    ;;
  set)
    [ "$#" -ge 1 ] || { echo "manage-trust.sh: set requires at least one login" >&2; usage; }
    _validate_logins "$@"
    present_val="$(_present)" || exit 1
    if [ "$present_val" = "yes" ]; then
      # Replace the existing block in place: drop the old trust block, append fresh.
      python3 - "$CONFIG" "$@" <<'PY'
import re, sys
config, logins = sys.argv[1], sys.argv[2:]
lines = open(config, encoding="utf-8").read().split("\n")

# Only strip comment lines this script itself authored — NOT arbitrary
# user-authored comments adjacent to the trust block (#249 review, Copilot [3]).
OWN_COMMENT = re.compile(
    r"Journey-log author allowlist \(#249\)"
    r"|authors of pipeline-state journey-log comments"
    r"|Add the GitHub login that runs the pipeline"
)
def is_own_comment(s):
    t = s.lstrip()
    return t.startswith("#") and OWN_COMMENT.search(t) is not None

out, i, n = [], 0, len(lines)
while i < n:
    if re.match(r'^trust:\s*$', lines[i]):
        # Drop only our own header comment lines immediately above trust:, plus
        # one optional blank separator. Leave unrelated user comments intact.
        while out and is_own_comment(out[-1]):
            out.pop()
        if out and out[-1].strip() == "":
            out.pop()
        i += 1
        # Drop the old block body: subsequent indented/list/blank lines until
        # the next top-level key.
        while i < n:
            ln = lines[i]
            if ln.strip() == "" or ln.startswith((" ", "\t")) or ln.lstrip().startswith("-"):
                i += 1
                continue
            break
        continue
    out.append(lines[i]); i += 1
new = "\n".join(out).rstrip("\n") + "\n"
new += "\n# Journey-log author allowlist (#249).\ntrust:\n  journey_log_authors:\n"
for lg in logins:
    new += f"    - {lg}\n"
open(config, "w", encoding="utf-8").write(new)
PY
    else
      _append_block "$CONFIG" "$@"
    fi
    ;;
  *) usage ;;
esac
