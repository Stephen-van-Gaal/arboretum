---
name: document-section-schema
version: v1
status: active
---

# Document Section Schema

## Status

active

## Version
v1.1

## Description

Document section schema defines the shared vocabulary Arboretum uses to
discover and retrieve document content by semantic key. It lets templates,
skills, and future template generators agree that keys such as `purpose`,
`behaviour`, `requires`, `test-strategy`, and `final-verification` name
content roles, not merely heading strings.

## Schema

The parser-friendly catalog is a YAML-lite file with a top-level
`document_shapes:` mapping. Each shape key maps to:

- `template` - optional shipped template path.
- `description` - one-line human description.
- `sections[]` - ordered list of section records.

Each section record contains:

- `key` - stable semantic key, lowercase words separated by hyphens.
- `heading` - canonical Markdown heading text.
- `content` - short description of what belongs in the section.
- `required` - `yes` or `no`.
- `authorship` - optional; one of `human` | `auto` | `append-auto`. The
  source of truth for how `/consolidate` treats the section (preserve /
  regenerate / append). Replaces the former inline `<!-- HUMAN/AUTO -->` markers;
  when absent, consumers fall back to `human` (preserve). Granularity is
  **section-level**: a `human` section may contain an `auto` subsection — e.g.
  `implementation-notes` is `human`, but its `### Design record` subsection is
  regenerated. Consumers must key such exceptions on **subsection identity**, not
  invert the parent's section-level value.
- `aliases[]` - optional alternate heading text accepted for retrieval.

## Constraints

- Keys are stable API. Rename only by adding an alias and documenting a
  deprecation path.
- Headings are human-facing. A heading can change when an alias preserves the
  key.
- Retrieval by key must fail closed when a requested key cannot resolve
  uniquely.
- Cataloged shapes may coexist with uncataloged Markdown documents; missing
  shape metadata is a fallback condition, not a malformed document by itself.

## Examples

```yaml
document_shapes:
  governed-spec:
    template: docs/templates/spec.md
    sections:
      - key: purpose
        heading: Purpose
        content: Why this module exists and what problem it solves.
        required: yes
```

## Decisions Table — Extended Shape (#682)

The governed-spec `Decisions` section is a Markdown table. The durable columns
extend #671's required six-column core to eight:

```
| ID | Decision | Status | Tags | Alternatives Considered | Rationale | Date | Source |
```

- **Status** — `active | superseded→Dxx | moot`. Blank ≡ `active`. This is the
  **only mutable cell** in the otherwise-immutable (APPEND-AUTO) table: the
  Decision / Alternatives Considered / Rationale columns stay frozen (ADR
  discipline); only `Status` may change, and only as a deliberate human act.
- **Tags** — a mandatory facet from `{behaviour | seam | scope | quality}`,
  optionally followed by ` +area:<key>` where `<key>` is a frontmatter `areas:`
  entry (#681). Example: `seam +area:retrieval`.

**Two-altitude retrieval (projection, not a storage split).** The single table
is the source of truth. `scripts/read-decisions.sh` projects a cheap **summary**
(`ID · Decision · Status · Tags`, one line per decision) or emits the full-row
**detail** for named decision IDs. Column resolution is by header name
(case-insensitive, whitespace-normalized per `document-access-format.contract.md`),
so the projection tolerates both the 6-column and 8-column tables.

**Threshold gating (author / `/consolidate` policy — not code-enforced).** The
`Status` column appears whenever ≥1 decision is non-active (any spec size, for
correctness). The `Tags` column and routine two-altitude retrieval activate at
**≥15 decision rows**. Below that, the flat #671 six-column table stands.

## Consumers And Providers

| Spec | Role | Notes |
|------|------|-------|
| document-taxonomy | Provider | Owns shipped document templates and shape catalog. |
| document-access | Consumer | Uses shapes to discover and retrieve sections; `read-decisions.sh` projects the Decisions table. |
| workflow-unification | Consumer | Skills retrieve design/spec/plan sections during workflow stages. |
| consolidate-spec | Consumer | Harvests/preserves Decisions `Status`/`Tags`. |

## Changelog

| Date | Version | Change | Affected Specs |
|------|---------|--------|----------------|
| 2026-06-04 | v1 | Initial schema for document section discovery and retrieval. | document-access, document-taxonomy, workflow-unification |
| 2026-06-09 | v1.1 | Decisions-table extended shape: Status enum, Tags facet+area grammar, two-altitude projection, threshold gating (#682). | document-access, consolidate-spec, document-taxonomy |
