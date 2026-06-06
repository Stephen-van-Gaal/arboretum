---
seam: epic-walk
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - roadmap-graph-json
  - roadmap-lib-backend
produces:
  - epics-in-flight-json
related-designs:
  - docs/superpowers/specs/2026-06-05-epic-aware-orientation-design.md
owns:
  - scripts/roadmap/epic-walk.sh
---
<!-- owner: epic-aware-orientation -->

# epic-walk — `epic-walk.sh` Epic Resolver Output Contract

The seam between `scripts/roadmap/epic-walk.sh` (the read-only resolver that transforms a native-sub-issue graph into the `epics_in_flight` + `auto_advance` structure) and its downstream consumers: `scripts/refresh-next-cache.sh` (which merges the structure into `.arboretum/next-cache.json`) and transitively `.claude/hooks/session-start.sh` (which renders the `[Epics in flight]` boot-banner section).

The resolver operates in two modes: `--graph-file <path>` (test seam — reads a pre-built graph JSON fixture; no network) and live mode via `--next-up <N>` (calls `roadmap_epic_graph` from `scripts/roadmap/lib.sh`, which dispatches to the configured backend). Both modes feed the same Python core, making all classification and selection logic exercisable from fixtures with no network.

**Active = stage rank ≥ `/design`.** Stage rank order: `/start`(1) < `/design`(2) < `/build`(3) < `/finish`(4) < `/pr`(5) < `/land`(6). Opening a PR advances the stage to `/pr` — "open linked PR" needs no separate query, it is subsumed by the stage signal.

**ADO backend** returns an empty graph in v1 (`{"next_up":null,"nodes":{}}`), degrading silently — same output contract as an unlinked GitHub epic. GitHub native sub-issue linkage only; ADO native link support is out of scope for v1.

## Producer

`scripts/roadmap/epic-walk.sh` — producer-type: `script`.

Reads the graph JSON (from `--graph-file` or from a live `roadmap_epic_graph` call) and emits the resolver output JSON on stdout. All graph logic is implemented in a Python 3 heredoc (`STAGE_RANK`, `ACTIVE_MIN`, `DEPTH_CAP`, `epic_of`, `classify`, inclusion rules, auto-advance walk). The Python core never makes network calls.

Inclusion rules:
- An epic appears in `epics_in_flight` if it has at least one active child (stage ≥ `/design`), **or** if it is the nearest epic ancestor of the current `next_up` issue.
- Idle linked epics (no active child, not parent-of-next-up) are excluded.

Auto-advance: when the current `next_up` is closed, the resolver walks upward through epic ancestors (bounded by `DEPTH_CAP = 5` and a visited-set cycle guard), finds the first ancestor that has a ready (open, unblocked) child, and emits that child as the `auto_advance` candidate. If no such ancestor exists, `auto_advance` is `null`.

On fetch failure (live mode: `roadmap_epic_graph` fails), the resolver degrades to an empty graph and emits `{"epics_in_flight":[],"auto_advance":null}` with exit 0 (fail-soft). The boot path must never be blocked by epic-walk failure.

## Consumer

Two downstream consumers:

- **`scripts/refresh-next-cache.sh`** (script). Calls `epic-walk.sh --next-up <N>` after the primary tracker list call; merges `epics_in_flight` and `auto_advanced` into `.arboretum/next-cache.json`. The auto-advance label write (moving the `next-up` label from `auto_advance.from` to `auto_advance.to`) is fail-soft and never changes the refresh script's exit code. `auto_advanced` is set only in the run that performed the label write; it is absent (`null`) in subsequent boots — naturally one-shot without any hook-side clear logic.
- **`.claude/hooks/session-start.sh`** (hook, transitive). Reads `epics_in_flight` and `auto_advanced` from the cache and renders the `[Epics in flight]` section with `▸` (active), `•` (next), `⊘` (blocked) markers and a legend line. Control-character scrubbing is applied to all title fields before rendering (the hook's `_CTRL` regex, same as the existing `[Next-up]` section).

**Consumer obligations:**

- Consumers MUST treat the `epics_in_flight` and `auto_advanced` cache keys as optional (may be absent in older caches). The additive cache schema discipline from CLAUDE.md § Schema-coupled scripts applies — `next-cache.json` has multiple consumers and a missing key must not crash any consumer.
- Consumers MUST apply ANSI scrubbing as defense-in-depth on title fields rendered from `epics_in_flight` (producer scrubs at write time; double-scrubbing guards against hand-edited or older-version caches).

## Protocol shape

### Inputs

`epic-walk.sh` accepts one of:

- **`--graph-file <path>`** — positional; reads a pre-built graph JSON from disk (test seam, no network).
- **`--next-up <N>`** — live mode; calls `roadmap_epic_graph <N>` from `scripts/roadmap/lib.sh`, writes the result to a temp file, and feeds the Python core.

Graph JSON shape (both modes produce/consume the same shape):

```json
{
  "next_up": 305,
  "nodes": {
    "295": { "number": 295, "is_epic": true, "state": "open",
             "title": "pipeline overhaul", "labels": [],
             "parent": null, "children": [297, 305, 306], "stage": null },
    "305": { "number": 305, "is_epic": false, "state": "open",
             "title": "WS7: Intake pipeline", "labels": [],
             "parent": 295, "children": [], "stage": "/build" }
  }
}
```

### Outputs

Emits JSON on stdout:

```json
{
  "epics_in_flight": [
    {
      "number": 295,
      "title": "pipeline overhaul",
      "done": 1,
      "total": 3,
      "active": [
        { "number": 305, "title": "WS7: Intake pipeline", "stage": "/build" },
        { "number": 306, "title": "WS8: Orphan bug sweep", "stage": "/design" }
      ],
      "next": null,
      "blocked": []
    }
  ],
  "auto_advance": null
}
```

`epics_in_flight` entry fields:
- `number` — the epic's issue number.
- `title` — the epic's title (control-char-scrubbed by the cache producer before writing).
- `done` / `total` — closed-child count and total-child count (progress).
- `active` — list of open children with stage ≥ `/design`, in children-list order. Each entry: `{number, title, stage}`.
- `next` — when `active` is empty: the first ready (open, unblocked) child in children-list order, as `{number, title}`. `null` when active is non-empty or all open children are blocked.
- `blocked` — when `active` is empty: open children with the `blocked` label that appear before the first ready child (in children-list order). When all open children are blocked, all blockers appear here. Empty list when active is non-empty.

`auto_advance` fields (when non-null):
- `from` — issue number of the closed next-up.
- `to` — issue number of the ready child to advance to.
- `epic` — issue number of the epic that supplies the `to` candidate.

Exit codes:
- `0` — output written successfully (including fail-soft degradation to empty result on fetch failure).
- `2` — invalid arguments (neither `--graph-file` nor `--next-up` provided, or unrecognized argument).

### Invariants

- **Output JSON shape.** Every invocation that exits 0 emits valid JSON with top-level keys `{epics_in_flight, auto_advance}`. `epics_in_flight` is an array (possibly empty); `auto_advance` is null or an object with keys `{from, to, epic}`.
- **Active-definition contract.** Active = stage rank ≥ `/design`. Open-PR is subsumed (a PR advances stage to `/pr`). Children with stage null or `/start` are never active.
- **Fail-soft exit contract.** Network or GraphQL fetch failures in live mode produce `{"epics_in_flight":[],"auto_advance":null}` on stdout and exit 0. The boot path is never blocked.
- **Inclusion correctness.** An epic appears in `epics_in_flight` if and only if it has ≥1 active child or is the nearest epic ancestor of the current `next_up`. Idle linked epics (no active child, not parent-of-next-up) are excluded.
- **Blocked-ordering contract.** In the no-active case, `blocked[]` contains only blocked children that appear before the first ready child in children-list (native) order. Children that appear after the selected `next` are not listed in `blocked`.
- **Recursion depth cap.** The auto-advance upward walk is bounded by `DEPTH_CAP = 5` iterations and a visited-set cycle guard. Cycles in the parent graph never produce an infinite loop.
- **ADO degrade.** When the configured backend is `azure-devops`, `roadmap_epic_graph` returns `{"next_up":null,"nodes":{}}` (v1 stub). The resolver output is `{"epics_in_flight":[],"auto_advance":null}`, exit 0. Same contract as unlinked.

## Test surface

Asserted by `scripts/_smoke-test-contract-epic-walk.sh` against fixtures in `tests/fixtures/epic-walk/` (no network):

- **EW-1: Active children listed, next null, progress reported.** Given an epic with ≥1 active child, `active[]` contains all active open children in children-list order, `next` is `null`, and `done`/`total` reflect the closed/total count. Fixture: `in-flight.json` (epic #295, children #297 closed, #305 `/build`, #306 `/design`). Asserts `active == [305, 306]`, `next is None`, `done == 1`, `total == 3`.
- **EW-2: No-active → first ready next; earlier blocked listed below.** Given an epic with no active children and a mix of blocked and ready open children, `next` is the first ready child in children-list order, and `blocked` contains blocked children that appear before it. Fixture: `ready-blocked.json` (epic #404, child #272 blocked then #273 ready). Asserts `active == []`, `next.number == 273`, `blocked == [272]`.
- **EW-3: All-blocked → next null, blockers listed.** Given an epic whose only open children are all blocked, `next` is `null` and `blocked` contains all blocked open children. Fixture: `all-blocked.json` (epic #446, child #451 blocked). Asserts `next is None`, `blocked == [451]`.
- **EW-4: Inclusion — parent-of-next-up appears even without active child.** Given a `next_up` whose nearest epic ancestor has no active child, that epic still appears in `epics_in_flight`. Fixture: `all-blocked.json` (`next_up = 451`, parent epic #446 has no active child). Asserts `446 in [e.number for e in epics_in_flight]`.
- **EW-5: Inclusion — epic with active child appears; parent-of-next-up included.** Given an epic that is the parent of next-up, it appears in `epics_in_flight` even when it has no active child. Fixture: `ready-blocked.json` (`next_up = 273`, parent epic #404). Asserts `404 in [e.number for e in epics_in_flight]`.
- **EW-6: Recursion — auto-advance climbs past complete epics.** When the current `next_up` is closed and its nearest epic ancestor is also complete (all children closed), the auto-advance walk climbs to the parent epic and emits the first ready child there. Depth cap and cycle guard prevent infinite loops. Fixture: `recursion.json` (`next_up = 111` closed, parent epic #110 complete; grandparent epic #100 has ready child #101). Asserts `auto_advance.from == 111`, `auto_advance.to == 101`, `auto_advance.epic == 100`.
- **EW-7: Unlinked / fetch-failure → empty result, exit 0.** Given a `next_up` with no epic parent (or an empty graph from a fetch failure), the output is `{"epics_in_flight":[],"auto_advance":null}` and the script exits 0. Fixture: `unlinked.json` (`next_up = 800`, no parent). Asserts `epics_in_flight == []` and `auto_advance is None`.

## Versioning

- **1.0** (2026-06-05) — initial contract. Producer + consumer shapes as of `scripts/roadmap/epic-walk.sh` post-Tasks-1-3 and `scripts/refresh-next-cache.sh` pre-Task-5 on `feat/562-epic-aware-orientation`. Covers EW-1..EW-7. ADO degrade documented (v1 stub). Issue #562.
