---
seam: roadmap-score-cache
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - roadmap-lib-backend
produces: []
related-designs: []
owns:
  - scripts/roadmap/score-cache.sh
---
<!-- owner: roadmap -->

# roadmap-score-cache — `roadmap/score-cache.sh` Cache Operations Contract

The seam between the `/roadmap score` skill (consumer of the multi-mode cache helper) and `scripts/roadmap/score-cache.sh`, which owns all deterministic, read-only-w.r.t.-tracker operations on the scored-issues cache. The skill drives the four modes in sequence: validate incoming records before writing them, diff the open-issue set against the cache to find stale and evicted entries, merge scored records into the cache, and list agent-ready candidates for the skill's output. This contract pins the per-mode CLI shape, stdout protocol, exit codes, and schema invariants so the skill never re-derives scoring logic from raw tracker data.

## Producer

The `/roadmap score` skill (`skills/roadmap/SKILL.md`) invokes `score-cache.sh` directly via the four modes below. No LLM turn interprets its stdout — only structured JSON or issue-number lists flow back into the skill.

## Consumer

`scripts/roadmap/score-cache.sh` — producer-type: `script`. Consumer-type: `script` (the skill drives it).

Operates on a JSON cache file keyed by issue number (string), where each value is a scored record. The cache file is treated as optional — a missing or empty file is equivalent to an empty object `{}`. Depends on `jq` and `shasum`.

## Protocol shape

### Inputs

**`--validate-record`**

- stdin: one scored record JSON object.
- Validates the record against the v3 schema: `value` ∈ `{high,medium,low}`; `value_description` is string; `posture` ∈ `{live,preventive,mixed}`; `hazard` ∈ `{blocks-legit,permits-bad,none,na}`; `complexity` ∈ `{bugfix,design,brainstorm}`; `blocker` ∈ `{none,one-decision,spec}`; `depends_on` is array; `disposition` ∈ `{keep,combine,delete,decompose}`; `class` ∈ `{work-unit,orchestrator}`; `body_sha` matches `^[0-9a-f]{12}$`; `scored` matches `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`. When `disposition=="combine"`, `anchor` must be a number and `priority_driver` must be a number.

**`--diff --cache <f>`**

- stdin: issues JSON array (each element has at least `number` and `body`).
- `--cache <f>`: path to the existing cache file (optional; missing/empty → `{}`).
- Computes `body_sha` (SHA-256 truncated to 12 hex chars, via `shasum -a 256`) for each open issue. Compares against `body_sha` values stored in the cache.

**`--merge --cache <f> [--evict <json>]`**

- stdin: JSON array of `{number,record}` objects — the scored records to write.
- `--cache <f>`: path to existing cache (optional; missing/empty → `{}`). `--evict <json>`: JSON array of integer issue numbers to remove from the cache (default `[]`).
- Scrubs ASCII control characters from `value_description` in each incoming record (via `scrub_control_chars_oneline` from `lib.sh`) before merging.

**`--agent-ready-list --cache <f>`**

- `--cache <f>`: path to the cache file.
- Filters for entries where `complexity=="bugfix"`, `blocker=="none"`, `disposition=="keep"`, `class=="work-unit"`.

**Common flags**

- `-h|--help`: prints usage from the script header and exits 0.
- Any unrecognised argument: exits 2 with `Unknown arg: <arg>` on stderr.
- No mode specified (or an unknown mode): exits 2.

### Outputs

**`--validate-record`**

- exit 0 on success; exit 3 on schema failure.

**`--diff --cache <f>`**

- stdout: one JSON object: `{"stale":[<numbers where sha changed or no cache entry>],"evict":[<numbers in cache but not in open issues>]}`.
- exit 0 on success; exit non-zero when stdin is empty or is not a valid JSON array. This guard prevents a capped or empty fetch from silently evicting the entire cache.

**`--merge --cache <f> [--evict <json>]`**

- stdout: the merged cache JSON (all existing entries plus the new records, minus evicted entries). No file writes — caller pipes to the cache path.
- exit 0 on success; exit non-zero when stdin is empty or is not a valid JSON array. This guard prevents a silent empty-write from overwriting the cache with stale or partial data. An empty JSON array `[]` is valid — it means no new scores; evictions still apply.

**`--agent-ready-list --cache <f>`**

- stdout: one issue number per line, sorted by `value` (high < medium < low).
- exit 0 always; empty output when no entries qualify.

### Invariants

- **Body-sha convention.** `--diff` hashes `printf '%s' "$body"` through `shasum -a 256 | cut -c1-12`. Any consumer that independently computes `body_sha` MUST use the same convention (no trailing newline, first 12 hex chars of the SHA-256 digest).
- **Evict does not affect non-cache reads.** `--diff` only reads the cache; it never modifies it.
- **Control-char scrub.** `--merge` always scrubs `value_description` via the shared `scrub_control_chars_oneline` helper before writing to the cache, matching the defence-in-depth requirement for author-controlled content.
- **Read-only w.r.t. the tracker.** No mode calls the tracker backend or mutates repo files; all modes are safe to run without tracker authentication.
- **Empty-cache safety.** A missing cache path or a zero-byte file is treated as `{}` in all modes; no mode exits non-zero solely because the cache does not exist.

## Test surface

Asserted by `scripts/_smoke-test-score-cache.sh` (no network; uses fixture JSON and temp files):

- **SC-1:** A valid v3 record on stdin → `--validate-record` exits 0.
- **SC-2:** A record with an invalid `value` enum → exits 3.
- **SC-3:** A record with `disposition=="combine"` but no `anchor` → exits 3.
- **SC-4:** `--diff` with a 3-issue fixture and a pre-populated cache → `stale` contains the changed and new issue numbers; `evict` contains the cache-only number.
- **SC-5:** `--merge` scrubs ASCII control characters from `value_description`; evicted entries are absent from the output.
- **SC-6:** `--agent-ready-list` returns only the issue number that satisfies all four predicates (bugfix + none + keep + work-unit).
- **SC-7:** Body-sha parity — an issue whose body hash matches the cached `body_sha` is not in the `stale` list.

## Versioning

- **1.0** (2026-06-26) — initial contract. Producer shape as of `scripts/roadmap/score-cache.sh` on `feat/roadmap-scoring`.
