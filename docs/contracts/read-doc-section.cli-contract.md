---
script: scripts/read-doc-section.sh
version: 1.0
invokers:
  - type: script
    name: scripts/read-doc-profile.sh
  - type: script
    name: scripts/_smoke-test-contract-read-doc-section.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-02-customer-validation-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-doc-section.sh`

## Surface

Read-only Markdown section extractor for bounded agent reads. Given a Markdown file and an exact section heading, prints that section as compact Markdown suitable for direct skill consumption. The reader treats leading YAML frontmatter as metadata and omits it from section output. V1 supports ATX headings (`#` through `######`) only, matches heading text exactly and case-sensitively, and is level-agnostic for selection: a unique matching heading at any level may be selected. The selected section includes its heading line and descendant content until the next heading at the same or higher level. Headings inside fenced code blocks are ignored.

## Protocol

### Arguments

```
read-doc-section.sh <markdown-file> <section-heading>
```

- `<markdown-file>` (positional, required) — path to a Markdown file. The file is read as UTF-8.
- `<section-heading>` (positional, required) — exact heading text after Markdown heading markers and optional closing `#` markers are stripped. Matching is case-sensitive and does not normalize punctuation.

### Exit codes

- `0` — section found and printed to stdout.
- `1` — file not found, section missing, duplicate matching section headings make the request ambiguous, or the extracted section would be empty.
- `2` — invocation error, currently any argument count other than two.

### Side effects

Read-only. The command writes only to stdout/stderr, creates no files, performs no git operations, and makes no network calls.

## Test surface

- **CLI-1: Nested section boundary.** Extracting a section includes nested lower-level headings and their body, omits leading frontmatter, and stops before the next same-or-higher-level sibling heading.
- **CLI-2: Exact punctuation matching.** A heading containing punctuation, including `:`, `&`, and `?`, is selectable when the CLI argument exactly matches the normalized heading text.
- **CLI-3: Missing section failure.** A missing section exits non-zero with no stdout and an error naming the requested section.
- **CLI-4: Duplicate ambiguity.** Duplicate exact heading text at any heading level exits non-zero with no stdout and an error naming the ambiguity.
- **CLI-5: Frontmatter-only document.** A document containing only frontmatter produces no phantom body sections and fails clearly when a section is requested.

## Versioning

- **1.0** — initial contract for WS3 bounded Markdown section reads (2026-06-03).
