---
script: scripts/read-doc-profile.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-contract-read-doc-profile.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-02-customer-validation-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-doc-profile.sh`

## Surface

Read-only Markdown read-profile extractor for bounded agent reads. Given a Markdown file and a profile name, reads the file's leading YAML-lite frontmatter for `read_profiles.<profile>.sections[]`, validates that every referenced section resolves through `scripts/read-doc-section.sh`, then prints the requested sections as compact Markdown separated by one blank line. V1 profile metadata is optional for documents overall but required for this command. Profile names are exact and case-sensitive. Section extraction semantics are inherited from `read-doc-section.sh`: exact heading names, leading frontmatter omitted, duplicate matching headings rejected as ambiguous, and heading boundaries determined by same-or-higher heading level.

## Protocol

### Arguments

```
read-doc-profile.sh <markdown-file> <profile-name>
```

- `<markdown-file>` (positional, required) — path to a Markdown file with leading YAML-lite frontmatter.
- `<profile-name>` (positional, required) — exact profile key under `read_profiles:`.

The supported v1 profile shape is:

```yaml
read_profiles:
  compact:
    sections:
      - Purpose
      - Behaviour
      - 'Edge Cases: punctuation & symbols?'
```

Section names that contain YAML metacharacters such as `:` should be quoted so the shared YAML-lite parser treats them as scalar list items.

### Exit codes

- `0` — profile found, all referenced sections resolved uniquely, and concatenated Markdown printed to stdout.
- `1` — file not found, YAML-lite helper missing, frontmatter missing or invalid, `read_profiles` missing, profile missing or empty, a referenced section missing, or a referenced section ambiguous because of duplicate headings.
- `2` — invocation error, currently any argument count other than two.

### Side effects

Read-only. The command writes only to stdout/stderr and temporary files under the system temp directory, removes those temporary files before exit, performs no git operations, and makes no network calls.

## Test surface

- **CLI-1: Compact profile output.** A profile with multiple sections prints only those sections, preserves nested headings within selected sections, omits leading frontmatter, and excludes unrequested sibling sections.
- **CLI-2: Nested section targeting.** A profile may target a nested heading directly when that heading text is unique.
- **CLI-3: Invalid profile failure.** A missing profile exits non-zero with no stdout and an error naming the requested profile.
- **CLI-4: Unresolved references.** A profile that references a missing section exits non-zero with no stdout and an error naming the unresolved section.
- **CLI-5: Missing profile metadata.** A document with frontmatter but no `read_profiles` block rejects profile reads clearly.

## Versioning

- **1.0** — initial contract for WS3 bounded Markdown read profiles (2026-06-03).
