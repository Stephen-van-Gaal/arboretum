---
script: scripts/roadmap/build-orientation.sh
version: 1.1
invokers:
  - type: skill
    name: arboretum:/roadmap
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/roadmap/build-orientation.sh`

## Surface

Produces a roadmap orientation block to stdout for display in `/roadmap run` output and the SessionStart hook. Sources `scripts/roadmap/lib.sh` for root/config resolution and tracker access. Runs `nag.sh` before the tracker guard so time-based nags (e.g. `strategic-review-due`) surface even when the tracker is unavailable. Emits a `[Roadmap]` header line with `horizon:now`, `horizon:next`, `untriaged`, and `agent-ready` counts followed by the current branch and up to three top-NEXT items; nag output is appended after the orientation block when the tracker is available, or emitted alone on the no-tracker early-exit path. Exits 0 with empty stdout when `roadmap.config.yaml` is absent (so callers on un-instantiated projects are no-ops).

**Known caveat — apparently orphaned:** PR 7a (D-7a-1) flagged this script as apparently orphaned. The comment at the top of the file declares it serves the SessionStart hook, but the live hook (`session-start.sh` ~line 780) calls `render-run.sh --condensed` instead. No live non-test consumer currently invokes `build-orientation.sh`. The script is retained for coverage; dead-code triage is tracked separately and is out of scope for this PR.

## Protocol

### Arguments

The script takes no positional arguments and no flags.

```
build-orientation.sh
```

It reads context from the environment and filesystem:

- `roadmap.config.yaml` — located via `roadmap_config_path()` (sourced from `lib.sh`). When absent, the script exits 0 immediately with no output.
- Configured tracker backend — used for live issue counts and top-NEXT listing. When the backend is unavailable or unauthenticated, the script emits any captured nag output (if any) and exits 0. The default GitHub adapter delegates to `gh issue list`.
- `$CLAUDE_PROJECT_DIR` / CWD — used by `roadmap_project_root()` (from `lib.sh`) to locate the project root. Falls back to `git rev-parse --show-toplevel`, then `$CLAUDE_PROJECT_DIR`, then `pwd`.

### Exit codes

- `0` — success. Covers all documented paths: (a) normal orientation block emitted; (b) `roadmap.config.yaml` absent — exits immediately with no output; (c) tracker unavailable or unauthenticated — nag output emitted (if any) and exits 0.
- No other exit codes. The script uses `set -euo pipefail` with no explicit `exit 1` paths; unexpected subprocess failures may propagate their exit code, but such cases are not part of the documented contract.

### Side effects

**Not read-only when `roadmap.config.yaml` is present.** Before the tracker guard the script spawns `nag.sh`, which calls `roadmap_pulse_bootstrap` and (when a nag fires) the pulse-update helpers — these create and rewrite `.arboretum/roadmap-pulse.json`. A caller in a project with no pulse file (or a due nag) can therefore see its working tree dirtied by a `build-orientation.sh` invocation. The script makes no tracker mutations and no network calls beyond tracker issue-list reads (live mode only); its own stdout is the orientation block. When `roadmap.config.yaml` is absent the script exits before `nag.sh` and is genuinely read-only. Spawns `nag.sh` and (live mode) tracker issue-list subprocesses.

## Test surface

- **CLI-1: Config-absent silent exit.** When no `roadmap.config.yaml` is resolvable from the working directory, the script exits 0 with empty stdout. This is the safe no-op contract that allows the SessionStart hook to invoke the script on any project.
- **CLI-2: No-tracker nag passthrough.** When `roadmap.config.yaml` is present but the configured tracker backend is unavailable or unauthenticated, the script exits 0 and emits nag output to stdout if `nag.sh` produced any; it does not emit the orientation header block.
- **CLI-3: Orientation block format.** When `roadmap.config.yaml` is present and the tracker is available, stdout begins with a `[Roadmap]` header line carrying `horizon:now=N`, `horizon:next=N`, `untriaged=N`, and `agent-ready=N` counts, followed by a `Branch:` line.

## Versioning

- **1.1** (2026-05-31) — live issue reads flow through backend-neutral tracker helpers; GitHub remains the default adapter.
- **1.0** — initial contract (2026-05-30).
