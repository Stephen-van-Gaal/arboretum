---
seam: roadmap-view
version: 1.1
producer-type: skill
consumer-type: script
consumes:
  - roadmap-view-spec
  - roadmap-lib-backend
produces:
  - roadmap-view-render
related-designs:
  - docs/superpowers/specs/2026-06-07-roadmap-scripted-view-design.md
owns:
  - scripts/roadmap/view.sh
---
<!-- owner: roadmap -->

# roadmap-view — `view.sh` Query/Render Output Contract

The seam between the **producer** of a query-spec — a `/roadmap view` preset or
the free-form NL subagent (`skills/roadmap/SKILL.md` §5) — and the **consumer**
`scripts/roadmap/view.sh`, which fetches, filters, classifies, optionally
resolves an epic tree, and renders. The whole point is that the model emits only
the validated query-spec; the deterministic render is the turn's final output,
so no LLM turn is spent reading the result set back.

The query-spec schema is governed by `definitions/roadmap-view-spec.md@v1`; this
contract governs the validation behaviour and the render shape.

## Producer

A preset (deterministic, no LLM) or a Haiku subagent (free-form NL → spec, fixed
minimal prompt — never the parent transcript) emits a query-spec JSON object and
pipes it to `view.sh` via a quoted heredoc on stdin (so `$`/backticks in
untrusted text are never evaluated). The producer MUST NOT emit a raw `gh`/`az`
or shell command.

## Consumer

`scripts/roadmap/view.sh` — consumer-type: `script`.

Reads the query-spec (stdin or `--spec-file`), validates it (see Invariants),
fetches via `roadmap_tracker_issue_list` (backend-agnostic), filters, classifies
via `audit-board.sh`, and renders per `--format`. Epic-tree mode (`epic` field)
resolves the graph via `roadmap_epic_graph` (GitHub `subIssues` / ADO
`relations`).

## Protocol shape

### Inputs

`view.sh` accepts:

- query-spec JSON on **stdin** (default) or `--spec-file <path>`.
- `--validate-spec` — validate only, no fetch.
- `--format full|condensed|view` — render shape (default `view`).
- `--quiet` — fail-silent (exit 0, no output) for the boot/hook path.
- test seams: `--board-file`, `--closed-file`, `--graph-file`.

### Outputs

- **view / full**: flat list (or `group_by:horizon` buckets) of matched issues,
  each line `  #<n>  <title>   [<label-column>]`. Label column is `horizon:*`
  (GitHub) or `State` (ADO).
- **epic-tree** (`epic` set): a header line
  `▸ #<n>  <title>[  [horizon]]   <N> open · <N> done · <N> total`, then each
  child on its own line with `├─`/`└─` connectors and a trailing `✓` for done
  (closed) children. Identical shape on both backends.
- **condensed**: the ~5-line SessionStart orientation block (byte-stable with
  the historical `render-run.sh --condensed`).

### Exit codes

- `0` — success, including zero-match (prints `no matches …`) and `--quiet`
  degradation.
- `2` — usage error (unknown flag).
- `3` — invalid query-spec (interactive); `--quiet` maps to `0`.
- `4` — tracker unavailable (interactive); `--quiet` maps to `0`.

### Invariants

- **Fail-closed validation.** Any schema violation (unknown key, bad enum,
  wrong type, out-of-range `limit`, malformed JSON) → exit `3` with a
  field-named diagnostic. No silent coercion or repair.
- **No injection.** `text_match` terms are applied as a title post-filter in
  Python/jq against fetched data; they are never interpolated into a shell or
  tracker command. The query-spec arrives via stdin/heredoc, not argv.
- **Fail-behaviour split.** In the **query path** (`--format view`), `--quiet`
  never errors out: invalid-spec, tracker-unavailable, and zero-match conditions
  all exit `0` with no output; interactive mode surfaces them (exit `3`/`4`, or a
  `no matches` line). The **orientation path** (`--format condensed`) is
  separately fail-soft (exit 0) but is *not* fully silent — when
  `roadmap.config.yaml` exists yet the tracker or `jq` is unavailable it still
  emits a single `[roadmap] …` diagnostic rather than nothing. (The SessionStart
  banner formerly consumed this `--format condensed` output; #705 retired that
  banner consumer, so the mode is now invoked only directly.)
- **Backend parity.** `state`, `label_*`, `text_match`, `group_by:horizon`, and
  flat render behave identically on GitHub and ADO. Epic-tree render is
  identical in shape; only the label column differs by backend.
- **Epic-tree ADO hierarchy.** In epic-tree mode the graph comes from
  `roadmap_epic_graph`; its ADO branch (`roadmap_ado_epic_graph`) resolves native
  hierarchy from the work-item `relations` field — `Hierarchy-Forward` = children,
  `Hierarchy-Reverse` = parent; `Related` and other link types are ignored —
  producing the same `{next_up, nodes}` shape as the GitHub `subIssues` branch.
  State is normalized to `open`/`closed` via `azure_devops_closed_states`. The
  empty graph is emitted only on fetch failure or an unlinked epic (fail-soft).
  (Preserved from the retired `epic-walk.contract.md` EWA invariant when #705
  deleted that contract; `roadmap_epic_graph` survives as `view.sh`'s graph source.)
- **Deterministic render.** Output is a pure function of the validated query-spec
  and tracker state — the model contributes only the query-spec, never ranking
  or prose over the results.

## Test surface

Asserted by `scripts/_smoke-test-contract-roadmap-view.sh` (no network; uses
`--board-file` / `--graph-file`):

- **RV-1:** empty query-spec `{}` validates (exit 0).
- **RV-2:** unknown top-level key rejected (exit 3).
- **RV-3:** out-of-enum `state` rejected (exit 3).
- **RV-4:** `limit` above the `[1,200]` bound rejected (exit 3).
- **RV-5:** scalar (non-array) `text_match` rejected (exit 3).
- **RV-6:** `text_match` filters issue titles (case-insensitive, ANY-term).
- **RV-7:** `label_any` filters by label.
- **RV-8:** zero matches → explicit `no matches …` line, exit 0.
- **RV-9:** flat view shows the horizon label column.
- **RV-10:** `group_by:horizon` buckets results under horizon headers.
- **RV-11:** `epic` field renders the epic tree (`├─/└─` connectors + `N open · N done · N total` header).
- **RV-12:** done (closed) child marked `✓`.
- **RV-13:** `--format condensed` header counts + NOW section (byte-stable orientation).
- **RV-14:** `--format full` board view renders the separator, NOW/NEXT, and RECOMMEND.
- **RV-15:** `--format full` on an empty board still renders the header, exit 0.

ADO native-hierarchy production (the **Epic-tree ADO hierarchy** invariant) is
asserted separately by `scripts/_smoke-test-contract-roadmap-ado-epic-graph.sh`
(PATH-shadowed `az` stub, no network):

- **EWA-1: ADO relations → graph.** An ADO epic whose `relations` carry two
  `Hierarchy-Forward` children (one Active, one Closed) and a `Related` link →
  `roadmap_epic_graph` (backend `azure-devops`) emits `{next_up, nodes}` with the
  epic flagged `is_epic`, both hierarchy ids as `children`, the `Related` target
  absent, child states normalized, and `parent` back-pointers set. (Assertion id
  retained from the retired epic-walk contract.)

## Versioning

- **1.1** (2026-06-10) — absorbed the **Epic-tree ADO hierarchy** invariant and
  its EWA-1 test-surface assertion from the retired `epic-walk.contract.md` when
  #705 deleted that contract. `roadmap_epic_graph` / `roadmap_ado_epic_graph`
  survive as `view.sh`'s epic-tree graph source. Issue #705.
- **1.0** (2026-06-07) — initial contract. Producer = preset/subagent emitting
  `roadmap-view-spec@v1`; consumer = `scripts/roadmap/view.sh`. Covers
  RV-1..RV-15 (validation, fetch/filter, flat/horizon render, epic-tree, and
  the condensed/full orientation cases). Issue #621.
