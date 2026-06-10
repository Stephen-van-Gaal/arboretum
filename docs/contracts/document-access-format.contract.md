---
seam: document-access-format
version: 1.1
producer-type: skill
consumer-type: script
consumes:
  - yaml-lite-line-protocol
produces:
  - document-access-format
related-designs:
  - docs/superpowers/specs/2026-06-04-document-access-design.md
---
<!-- owner: pipeline-contracts-template -->

# Document Access Format Contract

## Producer

Document-producing workflow surfaces, chiefly `/consolidate`, templates under
`docs/templates/`, and humans editing governed documents. Producer-type is
recorded as `skill` because the durable automated producer is the Arboretum
skill path that reconciles governed documents.

## Consumer

Document-access scripts, currently `scripts/read-doc-section.sh` and
`scripts/read-doc-profile.sh`. Consumer-type: `script`.

## Protocol shape

### Inputs

Consumers read Markdown files that may begin with YAML-lite frontmatter. The
parser-facing body format is ATX Markdown headings (`#` through `######`) plus
optional frontmatter metadata:

```yaml
read_profiles:
  compact:
    sections:
      - Purpose
      - Behaviour
```

### Outputs

The format allows access scripts to resolve requested heading names to exactly
one body section and to resolve named read profiles to an ordered list of body
sections. Scripts preserve the author's heading text in output; normalization is
only for matching.

### Invariants

- Leading YAML-lite frontmatter is metadata and is not emitted as body content.
- Selectable body sections use ATX headings. Setext headings are not part of the
  contract.
- Heading matching normalizes both the request and candidate heading text by
  trimming leading/trailing whitespace, collapsing internal whitespace to one
  space, and comparing case-insensitively.
- Punctuation remains significant.
- If more than one heading has the same normalized key, a targeted read is
  ambiguous and must fail.
- Fenced code block contents do not contribute selectable headings.
- Section extraction stops at the next heading of the same or higher level.
- `read_profiles.<profile>.sections[]` is the supported read-profile shape.
- A read profile must resolve every referenced section before printing output.

### Decisions projection (#682)

A consumer (`read-decisions.sh`) may project the `Decisions` section's Markdown
table at two altitudes:

- **Summary** — one line per data row: `<ID> · <Decision> · <Status> · <Tags>`.
  A blank `Status` cell renders as `active`; an absent `Status`/`Tags` column
  renders as `active`/empty.
- **Detail** — the verbatim original table row(s) for a requested set of decision
  IDs, emitted in the order requested.

Projection invariants:

- Columns are located by **header name** (`ID`, `Decision`, `Status`, `Tags`),
  resolved with the same whitespace/case normalization as heading matching; column
  *order* is not fixed, and the 6-column (#671) table is tolerated.
- The projection fails closed: a missing `Decisions` section, a table with no data
  rows, or a requested detail ID that is absent yields no partial stdout and a
  non-zero exit naming the miss.
- The middle-dot separator `·` is literal in summary output.

## Test surface

- **DAF-1: Case-insensitive match.** `Purpose`, `purpose`, and `PURPOSE` resolve
  to the same heading when the normalized key is unique.
- **DAF-2: Whitespace normalization.** Repeated internal whitespace in headings
  and requested section names does not prevent a unique match.
- **DAF-3: Punctuation significance.** `Boundary` and `Boundary (non-goals)` are
  distinct normalized keys.
- **DAF-4: Normalized ambiguity.** Two headings with the same normalized key
  make a targeted read fail as ambiguous.
- **DAF-5: Fenced-code exclusion.** Heading-looking text inside fenced code is
  not selectable.
- **DAF-6: Profile all-or-nothing.** A profile with one unresolved section emits
  no partial output.
- **DAF-7: Decisions projection.** Summary renders `ID · Decision · Status · Tags`
  with blank Status as `active`; detail returns verbatim rows for named IDs in
  order; an absent ID or missing Decisions section fails closed with no partial
  output. (Exercised by `_smoke-test-contract-read-decisions.sh`.)

## Versioning

- **1.1** (2026-06-09) - add the Decisions two-altitude projection (summary/detail) for Issue #682.
- **1.0** (2026-06-04) - initial document-access format contract for Issue #525.
