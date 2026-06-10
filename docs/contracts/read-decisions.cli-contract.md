---
script: scripts/read-decisions.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-contract-read-decisions.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-09-decision-record-restructure-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-decisions.sh`

## Surface

Read-only two-altitude projection over a governed-spec `## Decisions` table.
Composes over `scripts/read-doc-section.sh` to extract the Decisions section,
parses the Markdown table by **column name** (so it tolerates both #671's
6-column table and the extended 8-column form), and emits one of two altitudes:

- **summary** (default or `--summary`): one line per decision —
  `<ID> · <Decision> · <Status> · <Tags>`. A blank `Status` cell renders as
  `active`; an absent `Status`/`Tags` column renders as `active`/`` respectively.
- **detail** (`--detail <ID[,ID...]>`): the full original table row(s) for the
  named decision IDs, in the order requested.

The reader locates `ID`, `Decision`, `Status`, and `Tags` by header text
(case-insensitive, whitespace-normalized per `document-access-format.contract.md`).
It fails closed.

## Protocol

### Arguments

```
read-decisions.sh <markdown-file> [--summary | --detail <ID[,ID...]>]
```

- `<markdown-file>` (positional, required) — path to a Markdown file containing a `## Decisions` section.
- `--summary` (optional, default mode) — emit the summary projection for all rows.
- `--detail <ID[,ID...]>` (optional) — emit full rows for the comma-separated IDs.

### Exit codes

- `0` — projection printed to stdout.
- `1` — file not found; no `## Decisions` section; no table rows; or a requested `--detail` ID is absent (error names the missing ID; no partial stdout).
- `2` — invocation error (missing file argument, both modes given, `--detail` with no IDs, unknown flag).

### Side effects

Read-only. Writes only stdout/stderr; creates no files; no git; no network.

## Test surface

- **RD-1: Summary projection.** `--summary` (and the no-flag default) emit `ID · Decision · Status · Tags` per data row; a blank `Status` renders `active`.
- **RD-2: Detail by ID.** `--detail D2,D1` emits the full original rows for D2 then D1, in requested order.
- **RD-3: Unknown ID fails closed.** `--detail D999` exits 1, names D999, prints no stdout.
- **RD-4: Missing section fails closed.** A document with no `## Decisions` section exits 1 with no stdout.
- **RD-5: Six-column tolerance.** A #671-shape 6-column table (no Status/Tags) projects with `Status=active`, `Tags` blank, exit 0.
- **RD-6: Invocation error.** Both `--summary` and `--detail`, or `--detail` with no IDs, or an unknown flag, exits 2.
- **RD-7: Duplicate table ID fails closed.** A table with two rows sharing an ID exits 1 (names the duplicate, no stdout) rather than silently returning one row.
- **RD-8: Escaped pipe is not a column boundary.** A cell containing an escaped `\|` (valid Markdown) is not split into extra columns; `Status`/`Tags` stay aligned.

## Versioning

- **1.0** — initial contract: two-altitude (summary/detail) projection over the Decisions table (2026-06-09).
