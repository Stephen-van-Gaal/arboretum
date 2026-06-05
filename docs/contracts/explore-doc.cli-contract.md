---
script: scripts/explore-doc.sh
version: 1.0
invokers:
  - type: script
    name: scripts/read-doc-sections.sh
  - type: script
    name: scripts/_smoke-test-contract-explore-doc.sh
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

# Contract for `scripts/explore-doc.sh`

## Surface

Read-only Markdown document explorer for profile-agnostic agent reads. Given a Markdown file, reports its document shape and retrievable sections through a deterministic line protocol. Cataloged documents resolve semantic section keys from `docs/templates/document-shapes.yaml`; uncataloged documents are still explorable by discovered heading-derived keys. This command does not retrieve body text.

## Protocol

### Arguments

```
explore-doc.sh <markdown-file>
```

- `<markdown-file>` (positional, required) - path to a Markdown file. The file is read as UTF-8.

Shape identity resolves in this order:

1. leading frontmatter `document-shape: <shape>`;
2. catalog `template:` path matching the document path relative to the repository root;
3. `unknown`.

Output is newline-delimited `key=value` records:

- `document-shape=<shape-or-unknown>`
- `section[N].key=<semantic-key>`
- `section[N].alias=<semantic-key>` when the catalog defines aliases for the section
- `section[N].heading=<actual-heading-text>`
- `section[N].level=<1-6>`
- `section[N].source=shape|heading`
- `warning[]=missing-section:<key>:<heading>` when a cataloged section is absent
- `warning[]=unmapped-heading:<heading>` when an uncataloged heading is discoverable only by its heading-derived key

### Exit codes

- `0` - document explored and line protocol printed.
- `1` - file not found, YAML-lite helper missing, shape catalog missing or invalid, or a cataloged semantic key resolves to more than one matching heading.
- `2` - invocation error, currently any argument count other than one.

### Side effects

Read-only. The command writes only to stdout/stderr and temporary files under the system temp directory, removes temporary files before exit, performs no git operations, and makes no network calls.

## Test surface

- **CLI-1: Cataloged template discovery.** Exploring `docs/templates/spec.md` reports `document-shape=governed-spec` and the cataloged `purpose` and `behaviour` keys.
- **CLI-2: Uncataloged heading discovery.** A Markdown document without shape metadata reports `document-shape=unknown`, emits heading-derived keys, and warns for unmapped headings.
- **CLI-3: Shape inference from path.** A document without frontmatter still resolves a shape when its repository-relative path matches a catalog `template:` value.
- **CLI-4: Duplicate semantic match failure.** A cataloged key whose heading or alias matches more than one document heading exits non-zero and names the ambiguity.
- **CLI-5: Alias protocol.** Cataloged aliases are emitted as `section[N].alias=<semantic-key>` records for downstream retrieval.

## Versioning

- **1.0** - initial contract for profile-agnostic document exploration (2026-06-04).
