---
script: scripts/validate-template-taxonomy.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-contract-validate-template-taxonomy.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-05-template-taxonomy-validator-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/validate-template-taxonomy.sh`

## Surface

Read-only validator for alignment between `docs/templates/document-shapes.yaml`
and the Markdown templates cataloged by that file. It classifies findings as
OK, warning, lifecycle-required, or hard failure. It does not mutate templates,
the catalog, document-access helpers, health-check, CI, or git state.

## Protocol

### Arguments

```text
validate-template-taxonomy.sh [catalog-path]
```

- No argument validates `docs/templates/document-shapes.yaml`.
- One argument validates the supplied YAML-lite catalog path. Fixture catalogs
  may point at fixture templates by paths relative to the repository root.
- More than one argument is an invocation error.

### Exit codes

- `0` - no hard failures. Warnings and lifecycle-required diagnostics may be
  present.
- `1` - one or more hard alignment failures.
- `2` - invocation or setup error.

### Side effects

Read-only. The command writes diagnostics and a summary to stderr, keeps stdout
empty, uses only temporary files under the system temp directory, performs no
git operations, and makes no network calls.

## Test surface

- **VTT-1:** real current cataloged templates validate with exit `0`.
- **VTT-2:** missing template path exits `1` and names the missing template.
- **VTT-3:** mismatched template `document-shape` exits `1`.
- **VTT-4:** required catalog section removal exits `1`.
- **VTT-5:** duplicate semantic heading or alias match exits `1`.
- **VTT-6:** alias-backed heading rename emits `lifecycle-required` and exits
  `0`.
- **VTT-7:** extra provider/template guidance heading emits `warning` and exits
  `0`.
- **VTT-8:** wrong argument count exits `2` with usage output.
- **VTT-9:** missing `python3` exits `2` and names the setup dependency.
- **VTT-10:** a single template heading claimed by multiple catalog sections
  exits `1`.
- **VTT-11:** duplicate catalog lookup tokens, including alias-derived tokens,
  exit `1`.

## Versioning

- **1.0** - initial standalone advisory validator for issue #559.
- **1.1** - review hardening for setup diagnostics, heading reuse, and catalog
  lookup-token collisions.
