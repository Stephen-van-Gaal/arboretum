---
seam: refresh-stage-cache
version: 1.1
producer-type: script
consumer-type: hook
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/refresh-stage-cache.sh
---
<!-- owner: pipeline-contracts-template -->

# refresh-stage-cache — `refresh-stage-cache.sh` Stage-Cache Producer Contract

The seam between `scripts/refresh-stage-cache.sh` (the producer of `.arboretum/active-stage-cache.json` — the cached `[#<issue> <stage>]` chip data for the active pipeline issue) and its downstream consumer `.claude/hooks/statusline.sh` (which renders the pipeline-state chip in the Claude Code statusline). This contract pins the cache JSON schema and the always-exits-0 degraded-path discipline so the statusline renderer can never silently mis-parse a shape change. The script also produces a secondary `.arboretum/log-comments-cache.json` for the session-start banner's pipeline-state block; that file's shape is pinned here too.

## Producer

`scripts/refresh-stage-cache.sh` — producer-type: `script`.

Resolves the active pipeline issue and caches its current stage. Active-issue resolution is three-tier: (1) branch-based — the current branch `<prefix>/<slug>` (also accepting the `<slug>-build` build-branch convention) matched against a design spec `docs/superpowers/specs/*-<slug>-design.md` carrying a `related-issue: <N>` frontmatter line; (2) `next-up`-labeled open tracker item fallback (via `roadmap_tracker_issue_list`); (3) else `issue: null`. When an issue is found, the script reads the issue body via `roadmap_tracker_issue_show` and extracts the stage from the `<!-- pipeline-state:current-stage --> **Current stage:** <name>` marker. The default GitHub adapter delegates these helper calls to `gh issue list`, `gh issue view`, and `gh api .../comments`.

Path resolution uses a positional `[project-dir]` arg (defaults to `git rev-parse --show-toplevel` or `pwd`). Both cache files are written atomically via per-process `mktemp` + `mv`.

The script **always exits 0** — degraded paths (configured tracker backend unavailable or unauthenticated, `python3` absent, no issue resolvable) write a minimal valid null cache (`{"issue": null, "stage": null, "ts": "<ts>"}`) rather than failing, honoring the `set -euo pipefail` + "Exit: 0 always" header contract.

All author-controlled strings written into the caches are scrubbed of ASCII control characters (`\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f` via the `_CTRL` regex) before serialization — the stage name in the main cache, and the comment `body` + `createdAt` in the log cache. This is the same defense-in-depth pattern as `scripts/refresh-next-cache.sh`. The stage cache is serialized via `python3 json.dumps` (not `printf`) so a stage value containing `"` or `\` can never break the JSON shape.

## Consumer

Consumers, consumer-type: `hook`:

- **`.claude/hooks/statusline.sh`** (hook, primary). Reads `.arboretum/active-stage-cache.json` (~line 19) and renders the pipeline-state chip: `[#<issue> <stage>]` when both `issue` and `stage` are present, `[#<issue>]` when only `issue`, nothing otherwise. It also background-refreshes the cache when it is absent or older than a 30 s TTL (fire-and-forget, `disown`ed). It re-scrubs the `stage` field before render as defense-in-depth.
- **`.claude/hooks/session-start.sh`** (hook, secondary). Reads `.arboretum/log-comments-cache.json` for the pipeline-state block of the boot banner.

**Consumer obligations:**

- The consumer MUST treat a missing or unparseable cache as "no chip" — render nothing, never error (statusline wraps the read in a try/except and an `os.path.exists` guard).
- The consumer MUST render `[#<issue> <stage>]` only when both `issue` (truthy) and `stage` (non-empty) are present; `[#<issue>]` when only `issue`; nothing otherwise.
- The consumer MUST re-scrub the `stage` field before render (mirror of the producer's `_CTRL` regex) as belt-and-braces against a hand-edited or older-version cache.
- The consumer MUST tolerate `issue: null` / `stage: null` (the degraded cache) silently.

## Protocol shape

### Inputs

`scripts/refresh-stage-cache.sh` accepts one optional CLI argument:

- **`[project-dir]`** — positional, defaults to `git rev-parse --show-toplevel` or `pwd`. Root under which `.arboretum/` caches are written and `docs/superpowers/specs/` is scanned.

Reads:

- `git -C <project-dir> rev-parse --abbrev-ref HEAD` — current branch (for slug resolution).
- `docs/superpowers/specs/*-<slug>-design.md` — for the `related-issue: <N>` frontmatter pin.
- `roadmap_tracker_issue_list --label next-up --state open --limit 1 --json number` — next-up fallback.
- `roadmap_tracker_issue_show <issue> --json body` — active issue body, for the current-stage marker.
- `roadmap_tracker_issue_comments <issue> --paginate` — log comments (filtered to `<!-- pipeline-state:log -->`).
- `roadmap_require_backend`, `command -v python3` — capability gates; failure → null-cache degraded path.

### Outputs

Writes `.arboretum/active-stage-cache.json` (atomic via mktemp + mv). Shape:

```json
{ "issue": <int> | null, "stage": "<name, control-char-stripped>" | null, "ts": "<ISO-8601 UTC>" }
```

When an issue is resolved, also writes `.arboretum/log-comments-cache.json` (atomic). Shape:

```json
[ { "body": "<comment-body, control-char-stripped>", "createdAt": "<ISO-8601, control-char-stripped>" }, ... ]
```

(only comments whose body contains the `<!-- pipeline-state:log -->` marker; `[]` when none).

Exit codes:

- `0` — always. Cache written. Sub-cases: full success (issue + stage); issue-only (`stage: null` — marker absent); fully degraded (`issue: null, stage: null` — tracker/backend/python3 unavailable or no issue resolvable).

### Invariants

- **Main-cache JSON shape.** `.arboretum/active-stage-cache.json` is valid JSON with exactly the top-level keys `{issue, stage, ts}`. No other keys. Adding or removing a key is a contract change requiring a coordinated `statusline.sh` update.
- **Always-exits-0 contract.** The script exits 0 even on degraded paths (tracker unavailable, auth failure, `python3` absent, no issue). The cache carries the degraded state via `issue: null` / `stage: null`; the exit code carries only "did the cache write succeed."
- **Always-writes-valid-JSON contract.** The main cache is never empty and always valid JSON — including every degraded path, which writes `{"issue": null, "stage": null, "ts": "<ts>"}`.
- **`issue` is int-or-null.** When resolved, `issue` is a JSON integer (`int(...)` cast), not a string. Unresolved → `null`.
- **`stage` is string-or-null.** Present marker → the scrubbed stage token (a non-empty string); absent marker → `null`.
- **`ts` always present.** Every cache write carries `ts` as an ISO-8601 UTC timestamp (`%Y-%m-%dT%H:%M:%SZ`), including the degraded null cache.
- **JSON-safe serialization.** The main cache is serialized via `python3 json.dumps`, so a stage value containing `"` or `\` cannot break the JSON shape (Codex R2-1).
- **ANSI-scrub invariant.** Author-controlled strings are scrubbed of `\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f` before being written: the `stage` field in the main cache, and `body` + `createdAt` in the log cache. The consumer (`statusline.sh`) re-scrubs `stage` as belt-and-braces.
- **Atomic-write invariant.** Both caches are written via per-process `mktemp` + `mv` atomic rename. Concurrent refreshes (the statusline fires a background refresh on every render past TTL) never produce truncated or interleaved content.
- **Log-cache filter.** `.arboretum/log-comments-cache.json` contains only comments whose body carries the `<!-- pipeline-state:log -->` marker, each as `{body, createdAt}`; `[]` when none match. Paginated tracker output (back-to-back JSON arrays in the default GitHub adapter) is walked document-by-document via `raw_decode`, never naively `json.loads`'d (Codex R2-2).

## Test surface

- **RSC-1:** Producer always exits 0 and writes a parseable `active-stage-cache.json` with top-level keys exactly `{issue, stage, ts}` — including the fully-degraded path (tracker unavailable) which writes `{"issue": null, "stage": null, "ts": ...}`.
- **RSC-2:** Degraded path — default GitHub adapter unavailable because `gh` is absent (shadowed off PATH) → `issue: null`, `stage: null`, `ts` present, exit 0.
- **RSC-3:** Branch-resolution happy path — branch `feat/<slug>` matching a design spec with `related-issue: <N>`, a stubbed tracker issue body carrying the current-stage marker → `issue: <N>` (integer), `stage: "<name>"`.
- **RSC-4:** Build-branch convention — branch `feat/<slug>-build` resolves the same `<slug>-design.md` spec (trailing `-build` stripped).
- **RSC-5:** Issue resolved but current-stage marker absent in body → `issue: <N>`, `stage: null`.
- **RSC-6:** ANSI-scrub — a stage value carrying a control char (via the stubbed issue body marker) is control-char-stripped in the written cache, readable content preserved.
- **RSC-7:** JSON-safety — a stage value containing a `"` does not break the cache JSON (file remains parseable); serialized via `json.dumps`.
- **RSC-8:** Atomic-write — `write_cache()` uses `mktemp` + `mv` (pattern assertion against the script source).

## Versioning

- **1.1** (2026-05-31) — issue body/list/comment reads flow through backend-neutral tracker helpers; cache schema unchanged.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/refresh-stage-cache.sh` and consumer `.claude/hooks/statusline.sh` on `main`. Issue #303 (WS5 PR 7a).
