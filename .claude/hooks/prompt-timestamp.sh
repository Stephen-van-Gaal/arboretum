#!/usr/bin/env bash
# owner: prompt-timestamps
# scope: plugin-only
# prompt-timestamp.sh — UserPromptSubmit hook. Emits a single dated wall-clock
# line on stdout, which Claude Code attaches to the submitted prompt as
# additionalContext. This makes per-turn timing visible in the transcript and
# durable across context compression — the "how long was that wait" surface.
# See docs/superpowers/specs/2026-05-28-prompt-timestamps-design.md.
# `|| true` keeps the exit 0 promise documented in
# docs/specs/prompt-timestamps.spec.md § Failure mode: if `date(1)` were
# somehow unavailable (effectively impossible on Darwin/Linux), the prompt
# is submitted unstamped rather than producing a non-zero hook exit that
# Claude Code would surface as a warning.
date '+[%Y-%m-%d %H:%M:%S] user prompt submitted' || true

# Refresh the per-branch liveness sentinel (#715). Run in a subshell so sourcing
# heartbeat.sh can't leak functions/vars into the hook, and never affects this
# hook's stdout (additionalContext) or exit — touch writes only to .arboretum/heartbeat/.
(
  HB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../scripts" 2>/dev/null && pwd)/heartbeat.sh"
  # shellcheck source=/dev/null
  [ -f "$HB" ] && . "$HB" && heartbeat_touch
) >/dev/null 2>&1 || true
