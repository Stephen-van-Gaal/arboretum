---
script: scripts/read-doc-sections.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-contract-read-doc-sections.sh
  - type: script
    name: scripts/_smoke-test-document-access-discovery.sh
  - type: skill
    name: skills/design/SKILL.md
  - type: skill
    name: skills/consolidate/SKILL.md
  - type: skill
    name: skills/build/SKILL.md
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-04-document-access-public-uptake-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-doc-sections.sh`

## Surface

Read-only semantic Markdown section retriever for bounded agent reads. Given a Markdown file and one or more semantic section keys, resolves those keys through `scripts/explore-doc.sh`, then composes over `scripts/read-doc-section.sh` to print the requested sections in the requested order. It is profile-agnostic: callers discover available keys first, then retrieve the keys they need.

## Protocol

### Arguments

```
read-doc-sections.sh <markdown-file> <section-key>...
```

- `<markdown-file>` (positional, required) - path to a Markdown file.
- `<section-key>` (positional, one or more required) - semantic key from `explore-doc.sh` output. Canonical `section[N].key=` values and `section[N].alias=` values both resolve to the same cataloged heading.

All requested keys are validated before any section body is printed. When validation succeeds, output is compact Markdown sections separated by one blank line, in exactly the requested key order. Section boundary and heading matching semantics are inherited from `scripts/read-doc-section.sh`.

### Exit codes

- `0` - all requested keys resolved uniquely and the requested Markdown sections were printed.
- `1` - file not found, explorer or section reader missing, explorer failure, requested key missing or ambiguous, or a resolved section cannot be read.
- `2` - invocation error, currently fewer than two arguments.

### Side effects

Read-only. The command writes only to stdout/stderr and temporary files under the system temp directory, removes temporary files before exit, performs no git operations, and makes no network calls.

## Test surface

- **CLI-1: Requested-order retrieval.** Multiple keys print their sections in the caller's requested order, not catalog order.
- **CLI-2: Alias resolution.** A catalog alias key resolves to the canonical heading and prints that section.
- **CLI-3: Missing key failure.** A missing key exits non-zero, emits no stdout, and names the missing key on stderr.
- **CLI-4: Boundary preservation.** Retrieved sections preserve `read-doc-section.sh` same-or-higher heading boundaries and do not leak unrequested siblings.
- **CLI-5: Composition failure.** If the underlying single-section reader cannot read a resolved heading, this command exits non-zero rather than printing partial requested content.

## Versioning

- **1.0** - initial contract for semantic multi-section retrieval (2026-06-04).
