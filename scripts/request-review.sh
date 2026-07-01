#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# request-review.sh <pr> [--reviewer <name>] [--re-request] [--design-doc]
#
# Request (or re-request) the AI reviewers declared in .arboretum.yml's
# review: block, each via its configured mechanism. With --design-doc, request
# only the design_doc_policy.reviewers subset (Codex), forced (#935).
# Backend-dispatched:
#   github       — live (ready-for-review flip, @reviewer comment, api-request)
#   azure-devops — AI-reviewer request stubbed (no native bot); human
#                  reviewers are added via `az repos pr reviewer add`
#
# Set REVIEW_DRY_RUN=1 to print intended actions without touching the network
# (used by the smoke test and by callers that want a plan first).
#
# Emits one line per reviewer: "requested: <name> via <mechanism>" (or
# "re-requested: ..." with --re-request).
set -uo pipefail

PR=""
REVIEWER_FILTER=""
RE_REQUEST=0
DESIGN_DOC=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reviewer)
      [ "$#" -ge 2 ] || { echo "request-review.sh: --reviewer requires a value" >&2; exit 2; }
      REVIEWER_FILTER="$2"; shift 2 ;;
    --re-request) RE_REQUEST=1; shift ;;
    --design-doc) DESIGN_DOC=1; shift ;;
    -*) echo "request-review.sh: unknown flag $1" >&2; exit 2 ;;
    *) [ -z "$PR" ] && PR="$1"; shift ;;
  esac
done
[ -n "$PR" ] || { echo "usage: request-review.sh <pr> [--reviewer <name>] [--re-request] [--design-doc]" >&2; exit 2; }
case "$PR" in *[!0-9]*) echo "request-review.sh: PR must be a positive integer (got '$PR')" >&2; exit 2;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/roadmap/lib.sh"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "${CLAUDE_PROJECT_DIR:-$PWD}")"
BACKEND="$(roadmap_backend "$ROOT")"
DRY_RUN="${REVIEW_DRY_RUN:-}"

if [ "$BACKEND" = "azure-devops" ]; then
  echo "stub: ADO AI-reviewer request not wired (no native bot reviewer); add human reviewers via 'az repos pr reviewer add --id $PR --reviewers <login>'."
  exit 0
fi
if [ "$BACKEND" != "github" ]; then
  echo "request-review.sh: unsupported backend: $BACKEND (supported: github, azure-devops)" >&2
  exit 2
fi

CONFIG="$(cd "$ROOT" && bash "$SCRIPT_DIR/read-review-config.sh" 2>/dev/null)" || {
  echo "request-review.sh: could not read review config" >&2; exit 1
}

# Unique reviewer names from the config.
NAMES="$(printf '%s\n' "$CONFIG" | sed -n 's/^ai_reviewer\.\([^.]*\)\..*/\1/p' | sort -u)"
[ -n "$NAMES" ] || { echo "request-review.sh: no AI reviewers configured"; exit 0; }

# Design-doc PR class (#935): request only the design_doc_policy.reviewers subset
# (Codex), suppressing auto-flaky Copilot on prose. The complexity-gate bypass
# (design D6) is satisfied by construction — request-review.sh requests
# unconditionally, so design-doc PRs are never gated out; bypass_complexity_gate
# is advisory for /pr, not a knob this script reads.
if [ "$DESIGN_DOC" = "1" ]; then
  DDP="$(printf '%s\n' "$CONFIG" | sed -n 's/^design_doc_policy\.reviewers=//p')"
  # An absent or empty policy must NOT silently fall back to the full ai_reviewers
  # set — that would request Copilot on a design doc, the exact opposite of the
  # suppression intent. Request nothing and say why.
  if [ -n "$(printf '%s' "$DDP" | tr -d '[:space:]')" ]; then
    NAMES="$(printf '%s\n' "$DDP" | tr ',' '\n' | sed '/^$/d' | sort -u)"
  else
    echo "request-review.sh: --design-doc set but design_doc_policy.reviewers is empty; requesting no reviewers (configure design_doc_policy.reviewers, e.g. [codex])." >&2
    exit 0
  fi
fi

# PR-vs-issue guard (live only — dry-run never hits the network).
if [ -z "$DRY_RUN" ]; then
  if ! gh api "repos/{owner}/{repo}/pulls/$PR" --jq .number >/dev/null 2>&1; then
    echo "request-review.sh: #$PR is not a pull request (or is unreachable)." >&2
    exit 2
  fi
fi

field="request"; verb="requested"
if [ "$RE_REQUEST" -eq 1 ]; then field="re_request"; verb="re-requested"; fi

ready_done=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -n "$REVIEWER_FILTER" ] && [ "$name" != "$REVIEWER_FILTER" ]; then continue; fi
  mech="$(printf '%s\n' "$CONFIG" | sed -n "s/^ai_reviewer\.$name\.$field=//p")"
  [ -n "$mech" ] || mech="$(printf '%s\n' "$CONFIG" | sed -n "s/^ai_reviewer\.$name\.request=//p")"
  # A reviewer with no configured mechanism is a misconfiguration, not a silent
  # no-op: skip it loudly so dry-run and live agree instead of printing "via ".
  if [ -z "$mech" ]; then
    echo "request-review.sh: $name has no '$field' (or 'request') mechanism configured; skipping" >&2
    continue
  fi
  if [ -n "$DRY_RUN" ]; then
    echo "$verb: $name via $mech"
    continue
  fi
  case "$mech" in
    ready-for-review)
      # Idempotent across reviewers; flip once. Note: 'gh pr ready' is a no-op on
      # an already-ready (non-draft) PR — Copilot's initial review fires via
      # auto-review-on-open, not this flip. The re-request cadence lever is M-C (#535).
      [ "$ready_done" -eq 1 ] || { gh pr ready "$PR" >/dev/null 2>&1 || true; ready_done=1; }
      ;;
    comment)
      if ! gh pr comment "$PR" --body "@$name review" >/dev/null 2>&1; then
        echo "request-review.sh: failed to post '@$name review' trigger for $name; not requested" >&2
        continue
      fi
      ;;
    api-request)
      if ! gh api "repos/{owner}/{repo}/pulls/$PR/requested_reviewers" -f "reviewers[]=$name" >/dev/null 2>&1; then
        echo "request-review.sh: failed to request reviewer $name via api; not requested" >&2
        continue
      fi
      ;;
    *)
      echo "request-review.sh: $name has unknown mechanism '$mech'; skipping" >&2
      continue
      ;;
  esac
  echo "$verb: $name via $mech"
done <<< "$NAMES"
