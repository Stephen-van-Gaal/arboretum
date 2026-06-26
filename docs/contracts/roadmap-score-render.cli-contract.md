---
script: scripts/roadmap/score-render.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/roadmap (score)
  - type: developer
related-designs: []
---
<!-- owner: roadmap -->

# Contract for `scripts/roadmap/score-render.sh`

## Surface

Renders a deterministic ranked view of the scored-issues cache produced by `score-cache.sh`. Reads the cache from `--cache <file>` (required) and optionally joins issue titles from a live-fetched issues JSON supplied via `--issues <file>`. Outputs the ranked list to stdout with three sections: a `ROADMAP SCORE — ranked` header and the full ranked list sorted by value (high → low) then blocker (none → one-decision → spec), followed by a `★ AGENT-READY` section listing numbers from `--agent-ready-list` mode of `score-cache.sh`, and a `⚑ COMBINE/DELETE` section listing issues with `combine` or `delete` dispositions. Title text arriving from `--issues` is scrubbed for ASCII control characters via `lib.sh`'s `scrub_control_chars` before rendering. No tracker mutations; no network calls in the render path itself.

## Protocol

### Arguments

- `--cache <file>` — **required.** Path to the score cache JSON file. Exits 2 (`score-render: --cache is required`) if omitted; exits 2 (`score-render: cache file not found: <path>`) if the path does not exist.
- `--issues <file>` — optional. Path to an issues JSON array (each element has at least `number` and `title`). When present and the file exists, issue titles are joined into the ranked output and scrubbed of control chars. When absent or the file does not exist, the render emits cache-only entries (number + score fields, no title).
- `-h|--help` — prints usage from the script header and exits 0.
- Any other argument: exits 2 with `score-render: unknown arg: <arg>` on stderr.

### Exit codes

- `0` — render complete.
- `2` — argument error: `--cache` omitted, cache file not found, or unknown flag.

### Side effects

None. Read-only: reads the cache file and optionally the issues file; calls `score-cache.sh --agent-ready-list` as a subprocess; no tracker calls, no file writes.

### Output shape

Three sections, always present:

1. **Header + ranked list.** `ROADMAP SCORE — ranked` followed by one line per cache entry, sorted by `value` (high=0 < medium=1 < low=2), then by `blocker` (none=0 < one-decision=1 < spec=2). Each line: `#<n> [<value>/<complexity>/<blocker>] <disposition>[ <title>]`. Title is appended only when `--issues` is provided and the issue number is found in the file.
2. **★ AGENT-READY.** Lists issue numbers qualified as agent-ready candidates (complexity=bugfix, blocker=none, disposition=keep, class=work-unit), one per line prefixed `  #`.
3. **⚑ COMBINE/DELETE.** Lists issues with `disposition=="combine"` or `disposition=="delete"`, one per line as `  #<n> → <disposition>[ (anchor #<m>)]`.

## Test surface

Asserted by `scripts/_smoke-test-score-render.sh` (no network; uses a fixture temp cache file):

- **SR-1:** A two-entry cache (one high/keep, one low/combine) → output contains `#5`.
- **SR-2:** Issue #5 (bugfix/none/keep/work-unit) appears in the `★ AGENT-READY` section.
- **SR-3:** The `⚑ COMBINE/DELETE` section is present and lists the combine entry.
- **SR-4:** Issue #5 (high) sorts above issue #6 (low) in the ranked list.

## Versioning

- **1.0** (2026-06-26) — initial contract. Script shape as of `scripts/roadmap/score-render.sh` on `feat/roadmap-scoring`.
