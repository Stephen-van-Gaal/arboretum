---
seam: statusline
version: 1.0
producer-type: hook
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - .claude/hooks/statusline.sh
---
<!-- owner: pipeline-contracts-template -->

# statusline — `statusline.sh` Statusline Renderer Contract

The seam between `.claude/hooks/statusline.sh` (the Claude Code statusline renderer that replaces the default statusline) and its consumer — Claude Code's statusline surface, which renders the hook's single-line stdout. The hook is a *consumer* of the refresh-stage-cache seam (`.arboretum/active-stage-cache.json`, fully specified in `docs/contracts/refresh-stage-cache.contract.md`) for the pipeline-state chip, and a *producer* of the rendered statusline. This contract pins the rendered line's segment shape, the chip format for present/absent cache, the all-or-nothing rate-limit segment, and the consumer-side control-char re-scrub obligation.

## Producer

`.claude/hooks/statusline.sh` — producer-type: `hook`.

Renders the project status line on a single line:

```
<model>  |  ts HH:MM  |  <project>/<branch>  |  ctx <N>%  |  5h:<N>% 7d:<N>%  |  wt:<name>  |  [#<issue> <stage>] <title>
```

Reads the Claude Code session payload as JSON on stdin (schema at `https://code.claude.com/docs/en/statusline`) for model, project_dir, context %, rate-limit %, and worktree. Resolves the git branch in bash (`git rev-parse --abbrev-ref HEAD`). Reads the pipeline-state chip data from `.arboretum/active-stage-cache.json` (refresh-stage-cache seam). Background-refreshes that cache (fire-and-forget, `disown`ed) when absent or older than a 30 s TTL.

Optional segments collapse their `  |  ` separators so the line never carries a stranded separator. The `ts` segment (local `HH:MM`) is always present. The hook **always exits 0** — absent `python3` exits 0 early (no line); a missing/unparseable cache yields no chip, never an error.

## Consumer

Consumer-type: `skill` — the rendered single line flows to Claude Code's statusline surface (and to Claude as ambient context). The contract's behavioural assertions are exercised by the existing smoke test, which drives the real hook with a stdin payload in a git fixture and asserts on its stdout:

- **`scripts/_smoke-test-statusline.sh`** — asserts the full line shape, graceful omission of absent segments (chip, ctx, rate-limit, worktree), the always-present `ts` segment, and control-char scrubbing of string fields.
- **`scripts/_smoke-test-contract-statusline.sh`** (this contract's test) — asserts the chip format for present/absent stage cache and the consumer re-scrub of the `stage` field.

**Consumer obligations (the stage-cache consumer side, per `refresh-stage-cache.contract.md`):**

- The consumer MUST treat a missing or unparseable cache as "no chip" — render nothing, never error (the read is wrapped in `os.path.exists` + `try/except`).
- The consumer MUST render `[#<issue> <stage>]` only when both `issue` (truthy) and `stage` (non-empty) are present; `[#<issue>]` when only `issue`; nothing otherwise. When a chip renders and the cache carries a non-empty `title` (#763), it is appended after the chip (`[#<issue> <stage>] <title>`), control-char scrubbed and truncated to 40 chars (39 + `…`).
- The consumer MUST re-scrub the `stage` and `title` (#763) fields (mirror of the producer's `_CTRL` regex) before render, as belt-and-braces against a hand-edited or older-version cache. (`statusline.sh` does this — `scrub()` ~line 61, applied to `stage`/`title` at chip assembly and to model / project / branch / worktree.)
- The consumer MUST tolerate `issue: null` / `stage: null` (the degraded cache) silently.

## Protocol shape

### Inputs

- **stdin** — the Claude Code session JSON payload: `model.display_name`, `workspace.project_dir` / `workspace.git_worktree`, `cwd`, `context_window.used_percentage`, `rate_limits.five_hour.used_percentage` / `rate_limits.seven_day.used_percentage`, `worktree.name`. Empty/invalid stdin → `{}` (segments omitted, `ts` still rendered).
- Environment: `CLAUDE_PROJECT_DIR` (defaults to `pwd`) — root for git-branch resolution and the cache path.
- `.arboretum/active-stage-cache.json` — refresh-stage-cache seam: `{issue, stage, title, ts}`. Background-refreshed past a 30 s TTL.
- No CLI args.

### Outputs

stdout: a single line, segments joined by `  |  `; absent optional segments are omitted with their separators. Never a trailing newline beyond the line itself. Segments and order: `model`, `ts HH:MM`, `project/branch`, `ctx N%`, `5h:N% 7d:N%`, `wt:name`, `[#issue stage]`. Exit code: `0` always.

### Invariants

- **Always-exits-0.** Exits 0 unconditionally — including the no-`python3` early exit (no line) and any cache/stdin degradation.
- **`ts` always present.** The `ts HH:MM` segment renders on every invocation (local system time, no external content — not scrubbed). With a model present it sits immediately after model; with no model it leads.
- **Chip format (stage-cache consumer).** `[#<issue> <stage>]` only when both `issue` truthy AND `stage` non-empty; `[#<issue>]` when only `issue`; no chip otherwise (absent cache, unparseable cache, or both fields null/empty). When a chip renders and `title` is non-empty (#763), `<title>` is appended after the chip, control-char scrubbed and truncated to 40 chars.
- **Title is user-only (#763).** The title is rendered only to the statusline — a display surface the model never ingests — so an author-controlled title here cannot reach the model's context (the model-facing SessionStart banner renders only the bare issue number).
- **All-or-nothing rate-limit segment.** `5h:N% 7d:N%` renders only when BOTH `five_hour` and `seven_day` percentages are present; either absent → the whole segment is omitted.
- **Separator collapse.** Optional segments that are omitted do not leave a stranded `  |  ` — the line is rebuilt from the present-segments list.
- **Consumer re-scrub invariant.** Every string field surfaced to the statusline is control-char scrubbed (`\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f`) at render: `model`, `project`, `branch`, `worktree`, and the cache `stage` field. This mirrors the producer-side scrub in `refresh-stage-cache.sh` and is the consumer obligation recorded in `refresh-stage-cache.contract.md`.
- **Read-only.** The hook renders only; the sole side effect is the fire-and-forget background `refresh-stage-cache.sh` invocation. It mutates no governed files.

## Test surface

- **STL-1:** Chip present — a stage cache `{issue, stage}` with both fields renders `[#<issue> <stage>]` at the end of the line.
- **STL-2:** Chip absent — no `active-stage-cache.json` → no `[#…]` chip; the rest of the line still renders and the hook exits 0.
- **STL-3:** Consumer re-scrub — a stage value carrying a raw ESC (`0x1b`) control byte renders into the chip with the ESC byte stripped (printable residue preserved), confirming the consumer-side re-scrub of the `stage` field.
- **STL-4 (#763):** Title segment — a cache `title` renders appended to the chip (`[#<issue> <stage>] <title>`); a raw ESC in the title is stripped at render; a title longer than 40 chars is truncated to `39 + …`. (Asserted by `_smoke-test-statusline.sh` cases 1b/1c.)

## Versioning

- **1.1** (2026-06-12) — adds the title segment to the chip (#763): when the stage cache carries a non-empty `title`, it renders as `[#<issue> <stage>] <title>`, control-char scrubbed and truncated to 40 chars. The title is user-only — the statusline is never ingested by the model — which is what makes surfacing the author-controlled title here injection-safe while the model-facing SessionStart banner renders only the bare number. Cache shape consumed becomes `{issue, stage, title, ts}`; STL-4 added.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `.claude/hooks/statusline.sh` on `feat/ws5-pr7a-full-shape-sweep`. Consumer side of the refresh-stage-cache seam (`docs/contracts/refresh-stage-cache.contract.md`). Issue #303 (WS5 PR 7a).
