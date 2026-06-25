#!/usr/bin/env bash
# owner: pipeline-state-tracking
# scope: plugin-only
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
        # gh login could not be resolved. Do NOT write a present-but-bot-only
        # block: a present key flips read-journey-log into strict mode, which
        # would silently drop the human pipeline-runner's own log-stage entries
        # (they are not the bot). Leave the key ABSENT so the documented
        # permissive migration mode (+ stderr warning) applies until the human
        # authenticates and configures it (#249 review, Codex). Exit non-zero so
        # callers (init/bootstrap) surface "not seeded".
        echo "manage-trust.sh: could not resolve gh login — leaving trust.journey_log_authors UNCONFIGURED (permissive migration mode). Run 'manage-trust.sh set $CONFIG <your-login> github-actions[bot]' once authenticated, or re-run /upgrade." >&2
        exit 1
      fi
    fi
    ;;
  set)
    [ "$#" -ge 1 ] || { echo "manage-trust.sh: set requires at least one login" >&2; usage; }
    _validate_logins "$@"
    present_val="$(_present)" || exit 1
    if [ "$present_val" = "yes" ]; then
      # Replace ONLY the journey_log_authors sub-list in place, preserving the
      # trust: block's position and any SIBLING keys under it (#249 review,
      # Codex [B]). Editing in place also leaves any user comments above/around
      # the block untouched (Copilot [3]).
      python3 - "$CONFIG" "$@" <<'PY'
import re, sys
config, logins = sys.argv[1], sys.argv[2:]
lines = open(config, encoding="utf-8").read().split("\n")

def indent_of(s):
    return len(s) - len(s.lstrip(" "))

out, i, n = [], 0, len(lines)
found_trust = False
while i < n:
    if re.match(r'^trust:\s*(#.*)?$', lines[i]):
        found_trust = True
        out.append(lines[i]); i += 1            # keep `trust:` in place
        emitted = False
        # Walk the block's children (blank or indented lines).
        while i < n:
            ln = lines[i]
            if ln.strip() == "":
                out.append(ln); i += 1; continue
            if indent_of(ln) == 0:
                break                            # next top-level key ends the block
            m = re.match(r'^(\s+)journey_log_authors\s*:', ln)
            if m:
                ci = m.group(1)
                out.append(f"{ci}journey_log_authors:")
                for lg in logins:
                    out.append(f"{ci}  - {lg}")
                emitted = True
                i += 1
                # Skip the old list items / inline value: blank lines AND any
                # more-indented lines (so entries separated by a blank line are
                # fully removed). Stops at the next sibling key (indent <= key)
                # or the next top-level key.
                key_indent = len(ci)
                while i < n and (lines[i].strip() == "" or indent_of(lines[i]) > key_indent):
                    i += 1
                continue
            out.append(ln); i += 1               # preserve sibling trust key
        if not emitted:
            out.append("  journey_log_authors:")
            for lg in logins:
                out.append(f"    - {lg}")
        continue
    out.append(lines[i]); i += 1

if not found_trust:
    # present=yes but no block-form `trust:` line (e.g. flow-style
    # `trust: {journey_log_authors: [...]}`). Refuse rather than append a
    # duplicate block — ask the human to edit manually.
    sys.stderr.write(
        "manage-trust.sh: trust block is not in block form (`trust:` on its own line); "
        "edit .arboretum.yml manually to avoid clobbering it.\n")
    sys.exit(1)

open(config, "w", encoding="utf-8").write("\n".join(out).rstrip("\n") + "\n")
PY
    else
      _append_block "$CONFIG" "$@"
    fi
    ;;
  *) usage ;;
esac
