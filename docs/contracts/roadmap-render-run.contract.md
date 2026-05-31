---
seam: roadmap-render-run
version: 1.1
producer-type: script
consumer-type: hook
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/roadmap/render-run.sh
---
<!-- owner: pipeline-contracts-template -->

# roadmap-render-run — `roadmap/render-run.sh` Orientation-View Stdout Contract

The seam between `scripts/roadmap/render-run.sh` (which renders the `/roadmap run` daily view, or a compact orientation block under `--condensed`) and its hook consumer `.claude/hooks/session-start.sh` (~line 780), which captures `--condensed` stdout into `orientation_text` and appends it to the SessionStart boot-banner output (Claude's `additionalContext`). The script's stdout is the protocol; this contract pins the two output modes, the markers the `--condensed` block carries (the `[roadmap] …` header line that the hook injects verbatim), the silent-when-no-config behaviour, and the consumer's obligations — including the unscrubbed-content gap.

## Producer

`scripts/roadmap/render-run.sh` — producer-type: `script`.

Sources `scripts/roadmap/lib.sh` for root/config access. Two output modes:

- **default (full view)** — a `/roadmap run` board view: a `═══`-ruled header (`Roadmap — N open · …`), then `DONE` / `NOW` / `NEXT` / `AGENT-READY` / `LATER` / `SLACK` sections and a `RECOMMEND` block, with captured `nag.sh` output appended last.
- **`--condensed`** — a compact orientation block for SessionStart injection: a single `[roadmap] N open · N now · N next · N later · N untriaged · WIP: N` header line, then conditional `NOW:` (top 3), `★ agent-ready:` (top 3), and a `→ /roadmap maintain has N untriaged` hint (only when untriaged ≥ 5).

Inputs come from the configured tracker backend in live mode, or from `--board-file <path>` / `--closed-file <path>` in test mode (open / recently-closed issue JSON). In live mode it config-guards first: with no resolvable `roadmap.config.yaml` it exits 0 with empty stdout (no-op on un-instantiated projects); with config but unavailable/unauthenticated tracker it prints only captured nag output (if any) and exits 0. `--board-file` mode skips the config/backend guards entirely. Issue titles flow verbatim from the tracker into the rendered lines.

## Consumer

Consumer-type: `hook`. One downstream consumer:

- **`.claude/hooks/session-start.sh`** (~line 780): `orientation_text="$(bash "$ROADMAP_RENDER" --condensed 2>/dev/null || true)"`. When non-empty, it appends `orientation_text` to the banner `output` (newline-separated) which is echoed as the SessionStart `additionalContext` Claude sees on boot.

**Consumer obligations:**

- The hook MUST invoke render-run with `--condensed` and treat empty stdout as "no roadmap orientation" (the un-instantiated / no-tracker case), not an error — it already wraps with `|| true`.
- The hook MUST inject the captured block verbatim (it is pre-formatted, leading with the `[roadmap] …` header line) — it does not re-parse the block.
- **Scrubbing gap (documented, not asserted).** Issue titles flow unscrubbed from the tracker through render-run into the `--condensed` block, and `session-start.sh` appends `orientation_text` to `output` **without** the control-char `scrub()` it applies to the next-cache block (~line 123). Per the repo's "scrub author-controlled content into Claude's context" rule, this block is author-controlled (issue titles) reaching `additionalContext` with neither a source-side nor consumer-side scrub. Neither render-run nor the hook currently scrubs it. This contract records the gap; closing it (scrub at render-run's title emission and/or at the hook's append) is follow-up work, out of scope for this read-only contract.

## Protocol shape

### Inputs

- Flags: `--condensed` (compact block), `--board-file <path>` / `--closed-file <path>` (test-mode issue JSON), `-h`-less; unknown flag → exit 2.
- Live mode (no `--board-file`): reads `roadmap.config.yaml` + tracker issue lists (open & recently-closed); captures `nag.sh` stdout.
- No stdin.

### Outputs

- **`--condensed` stdout:** a `[roadmap] N open · N now · N next · N later · N untriaged · WIP: N` header line, then optional `NOW:` / `★ agent-ready:` / `→ /roadmap maintain …` blocks. Empty stdout in live mode when `roadmap.config.yaml` is absent.
- **default stdout:** the full `═══`-ruled board view (`Roadmap — …` header, `DONE`/`NOW`/`NEXT`/`AGENT-READY`/`LATER`/`SLACK`/`RECOMMEND`), nag output appended.
- Exit code: `0` on success (including the silent no-config / no-tracker paths); `2` on unknown flag.

### Invariants

- **Two modes.** Default emits the full `═══`-ruled view; `--condensed` emits the compact orientation block. The two are textually distinct.
- **Condensed header marker.** The `--condensed` block always begins with a single `[roadmap] ` header line carrying the open/now/next/later/untriaged/WIP counts; downstream injection relies on this leading marker.
- **Config-gated (live).** In live mode with no resolvable `roadmap.config.yaml`, stdout is empty and exit is 0 (no-op on un-instantiated projects); `--board-file` test mode bypasses this guard.
- **Count fidelity.** The header counts reflect the board: `now`/`next`/`later` are issues bearing the matching `horizon:*` label; `untriaged` is issues with no `horizon:*` label.
- **Read-only.** render-run never mutates issues or repo files.
- **Unscrubbed passthrough (known gap).** Issue titles pass verbatim through render-run into the condensed block and are not control-char scrubbed by render-run or by the consuming hook before reaching `additionalContext`.

## Test surface

- **RRR-1:** `--condensed --board-file <fixture>` emits a leading `[roadmap] …` header line and exits 0.
- **RRR-2:** The `--condensed` header counts match the fixture: a board with one `horizon:now`, two `horizon:next`, and one unlabelled issue yields `1 now · 2 next · … · 1 untriaged`.
- **RRR-3:** With `horizon:now` issues present, the `--condensed` block contains a `NOW:` section listing the now item; with an `agent-ready` issue present, it contains a `★ agent-ready:` section.
- **RRR-4:** Default (non-condensed) `--board-file` mode emits the full `═══`-ruled `Roadmap —` header — textually distinct from the condensed block.
- **RRR-5:** An unknown flag exits 2.

## Versioning

- **1.1** (2026-05-31) — live issue reads flow through backend-neutral tracker helpers; GitHub remains the default adapter.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/roadmap/render-run.sh` on this branch. Issue #303 (WS5 PR 7a).
