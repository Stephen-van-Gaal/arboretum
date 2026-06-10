---
seam: inflight-classifier
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - roadmap-graph-json
  - roadmap-lib-backend
produces:
  - classified-board-json
related-designs:
  - docs/superpowers/specs/2026-06-09-inflight-work-classifier-design.md
owns:
  - scripts/roadmap/inflight.sh
---
<!-- owner: inflight-work-classifier -->

# inflight-classifier — `inflight.sh` Classified-Board Output Contract

The seam between `scripts/roadmap/inflight.sh` (the in-flight-work classifier
that finds & classifies all open board work into epic / sub-issue / naked issue)
and its consumers — the roadmap in-flight view (#704), the board-structure
cleanup (#706), and any future surface. The engine does no rendering; it emits
one classified-board JSON.

## Producer

`scripts/roadmap/inflight.sh` — producer-type: `script`. Emits the
classified-board JSON on stdout. Two modes: `--graph-file <path>` +
`--signals-file <path>` (test seams; no network), or live — it builds the board
graph via `roadmap_inflight_board_graph` (`scripts/roadmap/lib.sh`) plus local
git signals (`inflight_local_signals`). The classification core is single-sourced
in `scripts/roadmap/_classify_core.py`, shared with `epic-walk.sh`.

## Consumer

The roadmap in-flight view (`#704`), board-structure cleanup (`#706`), and any
future on-demand surface (statusline, `/start`) — consumer-type: `script`. The
consumer reads the classified-board JSON from stdout and renders it; it passes
`--me` / `--unassigned` through as query flags and labels the view from the
echoed `viewer` / `filter` fields.

## Protocol shape

### Inputs

`inflight.sh` accepts:

- `--graph-file <path>` — a board graph JSON
  `{ "nodes": { "<num>": {number,title,stage,labels[],state,parent,children[],is_epic,has_open_pr,assignees[],author} }, "degraded"?: bool } }`
  (test seam; no network).
- `--signals-file <path>` — a file of issue numbers (one per line) with a
  correlated local branch/worktree (test seam).
- `--signals-stdin` — read branch names on stdin, emit correlated issue numbers.
- `--me` / `--unassigned` — optional person filters; `--viewer <handle>` is a
  test seam injecting the current user (bypassing `roadmap_current_user`).
- (live) no `--graph-file`: builds the graph via `roadmap_inflight_board_graph`
  and local git.

### Outputs

The classified-board JSON on stdout:

```
{ "epics": [ {number,title,done,total,active[],next|null,blocked[],author,
              sub_issues[{number,title,class,signal,assignees[],author}]} ],
  "naked_issues": [ {number,title,signal,assignees[],author} ],
  "degraded": bool, "viewer": string|null, "filter": "me"|"unassigned"|null }
```

- `signal ∈ {"stage:<value>","pr","branch"}`, precedence stage > pr > branch.
- `class ∈ {active, ready, blocked}` per open sub-issue.
- `viewer` is the resolved current user (or `null`); `filter` echoes the applied
  filter so the consumer can label the view honestly.

### Invariants

- A sub-issue never also appears in `naked_issues` (a unit is in exactly one place).
- An epic appears iff ≥1 child done OR ≥1 child active — board-wide, no `next_up`
  dependency (the #573 fix).
- `signal` is the first that holds in precedence order stage > pr > branch.
- `assignees` is a list of backend-local handles (ADO ≤1); `author` a handle.
  Identity is non-portable — comparison is within one backend only.
- `--me` keeps viewer-assigned nodes; `--unassigned` keeps empty-assignee nodes;
  epic `done/total` always reflect the **unfiltered** epic.
- `--me` with unresolvable identity exits non-zero (3) and emits **no** board.
- Fail-soft: any single fetch failure sets `degraded:true` and emits the partial
  board (exit 0); total failure emits `{epics:[],naked_issues:[],degraded:true}`
  (exit 0). The engine never crashes a consumer.

## Test surface

Asserted by `scripts/_smoke-test-contract-inflight-classifier.sh` against
`tests/fixtures/inflight/` (no network); the integration tier is
`scripts/_smoke-test-inflight-classifier-integration.sh`.

- **IC-1: Taxonomy.** Over `board-basic.json` + `signals-basic.txt`, #516 is an epic; 624/305/671 are naked; epic children 677/665/304 never appear as naked.
- **IC-2: Signal precedence.** stage > pr > branch — 624 → `stage:design`, 305 → `pr`, 671 → `branch`.
- **IC-3: Epic inclusion.** #516 surfaced with done=1/total=3 and active=[677] (≥1 done OR active).
- **IC-4: Sub-issue classification.** Open children nested under the epic with `class ∈ {active, ready, blocked}` (677 active, 665 ready).
- **IC-5: Degraded propagation.** `board-degraded.json` yields `degraded:true`.
- **IC-6: Local-signal parsing.** `--signals-stdin` maps `feat/703-…`/`fix/624-…` branch names to issue numbers {703,624}, ignoring non-matching branches.
- **IC-7: --unassigned filter.** Keeps only empty-assignee nodes; epic `done/total` stay unfiltered.
- **IC-8: --me filter.** With the `--viewer` seam, keeps viewer-assigned nodes, retains an epic via a matching child, preserves unfiltered `done/total`, and echoes `viewer`/`filter`.
- **IC-9: --me unresolvable.** `--me --viewer ""` exits non-zero and emits no board (anti-silent-failure).
- **IC-10: Live mode valid seam.** With board-graph + local-signal builders injected via the `INFLIGHT_LIB` seam, emits valid seam JSON and exits 0.
- **IC-11: Live mode fail-soft.** A failing board-graph builder yields `degraded:true`, an empty board, and exit 0.
- **IC-12: Consumer-side person-field scrub.** Over `board-hostile-handles.json`, author-controlled `author`/`assignees` handles carrying ANSI escapes are scrubbed at the classifier boundary (defense-in-depth — producer AND consumer); no ESC byte survives into any emitted `author` or `assignees` across epic/sub_issue/naked surfaces.
- **IC-13: --me fails closed without a viewer.** In `--graph-file` mode, `--me` with no `--viewer` (no live resolver available) exits non-zero (3) and emits no board — never a silent empty board with exit 0.
- **INT-1: Board-wide epic discovery.** Multiple in-flight epics surfaced board-wide with no `next_up`; an idle epic (no done/active child) is excluded.
- **INT-2: Naked-signal integration.** Naked issues carry correct precedence signals; an open issue with no signal is excluded; no sub-issue is double-listed.
- **INT-3: Sub-issue classes + progress.** active/ready/blocked classes assigned per child; epic `done/total` reflect unfiltered progress.
- **INT-4: Degraded integration.** The degraded fixture propagates `degraded:true`.

The existing `docs/contracts/epic-walk.contract.md` (EW-1..EW-7) must still pass
against the extracted `_classify_core.py` (regression — epic-walk output unchanged).

## Versioning

- **1.0** (2026-06-09) — initial contract; producer + consumer shapes as built on
  `feat/703-inflight-work-classifier`. Covers IC-1..IC-13 + INT-1..INT-4. Issue #703.
