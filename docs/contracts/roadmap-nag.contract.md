---
seam: roadmap-nag
version: 1.1
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/roadmap/nag.sh
---
<!-- owner: pipeline-contracts-template -->

# roadmap-nag — `roadmap/nag.sh` Nag-Line Stdout Contract

The seam between `scripts/roadmap/nag.sh` (which computes time-based roadmap nags and emits them to stdout) and the script that captures that stdout — `scripts/roadmap/view.sh`'s orientation render, via `$(bash nag.sh 2>/dev/null || true)`. The script's stdout is a line protocol: zero or more `[nag] <message>` lines, where no output means "no nags due." This contract pins the line prefix, the empty-when-quiet semantics, the fail-silent exit-0 guarantee, and the per-nag throttle so callers can capture and concatenate the output without parsing it.

## Producer

`scripts/roadmap/nag.sh` — producer-type: `script`.

Sources `scripts/roadmap/lib.sh` for config/pulse access (silently exits 0 if the lib is unavailable). Reads `roadmap.config.yaml` and the pulse file (`.arboretum/roadmap-pulse.json`), bootstrapping the pulse if absent. Evaluates up to five nag conditions, each gated by a per-day or per-week throttle keyed on `nag_last_fired[<name>]` in the pulse:

1. **strategic-review-due** (weekly; tracker-independent) — fires when `now - last_reviewed >= review_cadence_weeks * 7` days.
2. **maintain-overdue** (daily; needs tracker) — fires when `last_maintain_run` > 7d ago AND `>= 3` untriaged issues.
3. **stale-flagged-today** (daily; needs tracker) — fires when `>= 1` `provisionally-stale` open issue exists.
4. **agent-ready-while-WIP-full** (daily; needs tracker) — fires when WIP `>= wip_limit` AND `>= 1` agent-ready issue.
5. **profile-graduation-lean** (weekly; needs tracker) — fires when `profile=minimal` AND `>= 20` open issues.

Each fired nag prints one `[nag] <message>` line and records its name; after all evaluation, fire timestamps are batch-written to the pulse (so a fired nag is throttled on the next run). The tracker-dependent nags (2–5) are silently skipped when the configured backend is unavailable or unauthenticated.

## Consumer

Consumer-type: `script`. One downstream consumer capturing stdout via command substitution:

- **`scripts/roadmap/view.sh`** (orientation render) `nag_output="$(bash "$SCRIPT_DIR/nag.sh" 2>/dev/null || true)"`, run before the tracker guard and appended to the full view (trailing) and the no-tracker early-exit path so review nags surface offline.

**Consumer obligations:**

- Consumers MUST treat empty stdout as "no nags due" — a valid, non-error state.
- Consumers MUST capture stdout via command substitution and print it verbatim; nag lines are pre-formatted (`[nag] …`) and are not re-parsed.
- Consumers MUST NOT treat a nonzero exit as a failure mode — the script is fail-silent and exits 0 always; consumers already wrap it with `|| true`.

## Protocol shape

### Inputs

- No CLI args.
- Reads `roadmap.config.yaml` (`last_reviewed`, `review_cadence_weeks`, `wip_limit`, `profile`) and the pulse JSON (`last_maintain_run`, `nag_last_fired[…]`) relative to the roadmap project root.
- Tracker-dependent nags additionally query the configured tracker issue list (untriaged / provisionally-stale / horizon:now / agent-ready / open counts).

### Outputs

- stdout: zero or more lines, each `[nag] <message>\n`. No output = no nags due.
- stderr: none in normal operation (all subprocess noise is suppressed).
- Side effect: fire timestamps written to `.arboretum/roadmap-pulse.json` (`nag_last_fired[<name>]`) for any nag that fired.
- Exit code: **always 0** (fail-silent — never blocks session start).

### Invariants

- **Line prefix.** Every emitted line begins with the literal `[nag] ` prefix.
- **Empty-when-quiet.** When no nag condition fires (or all are throttled), stdout is empty.
- **Always exit 0.** The script exits 0 in every path, including missing lib, missing config, missing pulse, missing/unauthenticated tracker.
- **Config-gated.** With no resolvable `roadmap.config.yaml`, the script exits 0 with empty stdout (no nags).
- **Tracker-independence of nag 1.** strategic-review-due is computed without tracker calls; nags 2–5 are silently skipped when the tracker is unavailable.
- **Per-nag throttle.** A nag that fired within its window (day for daily nags, 7 days for weekly) is suppressed; firing records a timestamp in the pulse.
- **Install-day quiet.** On a project whose pulse does not yet exist, `roadmap_pulse_bootstrap` (invoked first) seeds every `nag_last_fired` to "now," so no nag fires on the first run after instantiation regardless of config age.

## Test surface

- **RN-1:** In a roadmap fixture with `last_reviewed` well past `review_cadence_weeks` and an old pre-seeded pulse (so the install-day quiet guarantee doesn't suppress the nag), nag.sh emits exactly one `[nag] …` line (strategic-review-due) with the `[nag] ` prefix; exit 0. (tracker-independent — the tracker CLI is omitted from PATH.)
- **RN-2:** With `last_reviewed` recent (within cadence) and no other condition met, stdout is empty; exit 0.
- **RN-3:** With no `roadmap.config.yaml` under the root, stdout is empty and exit is 0 (config-gated).
- **RN-4:** A second run immediately after a strategic-review-due fire is throttled (empty stdout) — the pulse recorded the fire (per-week throttle).

## Versioning

- **1.1** (2026-05-31) — tracker-dependent nags flow through backend-neutral tracker helpers; GitHub remains the default adapter.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/roadmap/nag.sh` on this branch. Issue #303 (WS5 PR 7a).
