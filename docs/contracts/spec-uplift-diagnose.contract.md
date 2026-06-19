---
seam: spec-uplift-diagnose
version: 5
producer-type: script
consumer-type: skill
consumes: []
produces:
  - readiness-report
related-designs:
  - docs/superpowers/specs/2026-06-15-spec-uplift-design.md
owns:
  - scripts/spec-uplift-diagnose.sh
---
<!-- owner: spec-uplift -->

# spec-uplift-diagnose — readiness-report contract

Deterministic readiness report for a governed spec — the seam between the
deterministic Diagnose scan and the AI-led phases of `/spec-uplift`. The report
lets the method decide what to fix without re-reading the spec body into
context (design D6/D7: contract-shaped output, no data dump).

## Producer

`scripts/spec-uplift-diagnose.sh <spec-path>` prints one JSON object to stdout
and nothing else; errors to stderr, non-zero exit on failure.

## Consumer

`skills/spec-uplift/SKILL.md` Diagnose phase reads the report to decide what to
fix. It must not re-read the spec body into context to recompute these fields.

## Protocol shape

### Inputs

- one argument: a path to a `docs/specs/*.spec.md` file.

### Outputs

JSON object, keys in fixed order:
`spec`, `behaviour_pointer`, `decisions_schema`, `decisions_rows`,
`missing_core`, `behaviour_facets`, `areas_declared`, `design_record_present`,
`design_record_is_changelog`, `legacy_markers_present`, `design_specs`.

- `spec` — the input path, echoed.
- `behaviour_pointer` — `true` if the `## Behaviour` section contains a line matching `see [the] design spec` / `design doc` (case-insensitive); a bare mention like "see the design team" does not match. This flags a pointer-*shaped* line, not necessarily a substitution — a supplementary cross-reference inside otherwise self-contained Behaviour also matches (validation #2 finding), so the interview confirms whether it is a true substitution; the signal is never auto-acted.
- `decisions_schema` — `"full"` (≥6-column header — the model `ID·Decision·Alternatives·Rationale·Date·Source` form), `"reduced"` (fewer than 6 columns, including the legacy 3-column `ID·Decision·Source` form — needs uplift), or `"absent"` (no table).
- `decisions_rows` — count of Decisions data rows (excludes the header and any separator/alignment row).
- `missing_core` — array of any absent mandatory headings (Purpose, Boundaries, Behaviour, Requires, Provides, Tests, Implementation Notes, Decisions); `[]` when all present. Each heading must match **exactly** on its own line — a prefix such as `## Behaviour Notes` does not satisfy `## Behaviour` — except `## Boundaries`, which also accepts the model's documented `(non-goals)` suffix.
- `behaviour_facets` — count of `###` subsections under `## Behaviour`.
- `areas_declared` — `true` if frontmatter has an `areas:` key.
- `design_record_present` — `true` if a `### Design record` subheading exists **on its own line** (a prose suffix such as `### Design record rationale` does not count).
- `design_record_is_changelog` — `true` if the `### Design record` subsection contains a pipe-table line (the model's dated changelog form); `false` if the section is absent or rendered as a bullet list (present-but-non-conformant). The subsection is bounded at the next heading of **any** depth (a table under a `####` sub-note does not count), and a lone separator/alignment row (`|---|---|`) is not a table. Refines `design_record_present`, which cannot distinguish the two.
- `legacy_markers_present` — `true` if the file contains a bare `<!-- HUMAN -->`, `<!-- AUTO -->`, or `<!-- APPEND-AUTO -->` authorship marker **alone on its own line** (the pre-#671-D11 scheme, stripped on uplift). The bracketed regen directives `<!-- [AUTO] regenerated … -->` / `<!-- [APPEND-AUTO] … -->` are NOT flagged, and neither is a marker mentioned mid-line in prose or backticks (so a spec documenting the markers is not a false positive).
- `design_specs` — deduplicated array of `docs/superpowers/specs/*.md` paths referenced anywhere in the file. **Untrusted and bounded:** the paths are extracted from spec text, are constrained to the `docs/superpowers/specs/` prefix, and any path containing `..` (traversal) is dropped; the array may be empty. Path forms with spaces or other non-`[A-Za-z0-9._/-]` characters are not extracted. **The `[A-Za-z0-9._/-]` charset is also the control-char floor for this field** — it incidentally excludes ASCII control / ANSI-escape bytes, so the field needs no separate scrub today; do not loosen the charset (e.g. to allow spaces) without adding a `scrub_control_chars` pass (CLAUDE.md defense-in-depth). Consumers MUST still treat these as untrusted and confirm each path exists before reading it.

### Invariants

- valid JSON; exactly the eleven keys above, in this order; no extra stdout; deterministic for a given input.

## Test surface

- **SUD-1:** pointer Behaviour detected (`behaviour_pointer`).
- **SUD-2:** Decisions schema classified reduced/full/absent.
- **SUD-3:** Decisions row count.
- **SUD-4:** missing mandatory headings reported.
- **SUD-5:** behaviour-facet count + `areas_declared`.
- **SUD-6:** `### Design record` presence.
- **SUD-7:** design-spec provenance paths extracted + deduplicated.
- **SUD-8:** output is valid JSON with exactly the eleven contract keys in order.
- **SUD-9–13:** traversal-path exclusion, large-Behaviour early-pointer detection, pointer false-positive guarding, 5-column-vs-≥6 schema boundary, row count under alignment tables.
- **SUD-14:** bare `<!-- HUMAN -->`/`<!-- AUTO -->` markers flagged; bracketed `[AUTO]` regen markers not.
- **SUD-15:** Design-record changelog table distinguished from a bullet list.
- **SUD-16:** a pipe-table under a `####` sub-note of a bullet Design record is not read as the changelog (heading-depth boundary).
- **SUD-17:** a lone separator/alignment row is not counted as a changelog table.
- **SUD-18:** `### Design record rationale` (prose suffix) registers as neither present nor changelog.
- **SUD-19:** legacy markers mentioned mid-line in prose/backticks are not flagged (own-line only).
- **SUD-20:** `decisions_rows` counts only the Decisions table, not a trailing `### Design record` table.
- **SUD-21:** a bare own-line `<!-- APPEND-AUTO -->` marker is flagged (pre-#671-D11 scheme).
- **SUD-22:** `## Behaviour Notes` does not satisfy the `## Behaviour` requirement; `## Boundaries (non-goals)` does.
- **SUD-23:** the Decisions schema detector stops at a `### ` subsection — a trailing `### Design record` table is not misread as the Decisions header (`decisions_schema:absent` when Decisions has no table of its own).

## Versioning

| Version | Date | Change | Issue |
|---------|------|--------|-------|
| 1 | 2026-06-15 | Initial seam contract | #684 |
| 2 | 2026-06-15 | Add `design_record_is_changelog` + `legacy_markers_present` (model-conformance gaps surfaced by validation #1) | #684 |
| 3 | 2026-06-15 | Precision fixes from B4 correctness review: heading-depth + separator-row + own-line-heading bounding for the design-record signals, own-line-only legacy markers, `decisions_rows` disarms at `### ` (SUD-16…20); document the `design_specs` charset as the control-char floor | #684 |
| 4 | 2026-06-16 | PR-review precision: `missing_core` matches headings exactly (prefix no longer satisfies; `Boundaries (non-goals)` excepted), `legacy_markers_present` also flags bare `<!-- APPEND-AUTO -->`, `behaviour_pointer` wording matches impl (SUD-21/22) | #684 |
| 5 | 2026-06-16 | PR-review round 2: the `decisions_schema` header detector also disarms at `### ` (a trailing design-record table is no longer misread as the Decisions header) (SUD-23) | #684 |
