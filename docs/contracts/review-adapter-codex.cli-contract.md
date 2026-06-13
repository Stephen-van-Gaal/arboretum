---
script: scripts/review-adapter-codex.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-contract-review-adapter-codex.sh
  - type: skill
    name: arboretum:/finish
related-designs:
  - docs/superpowers/specs/2026-06-13-section-dispatch-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/review-adapter-codex.sh`

## Surface

The `runtime` adapter for the codex reviewer (#791 D5). Maps codex `review --json` output
onto the shared review-manifest (`docs/contracts/review-manifest.contract.md`) so a
deterministic CLI reviewer emits the same schema as the skill-invoked lanes — the
replaceability seam of the review-stage section dispatch. LLM-free; the codex invocation
itself is the registry row's `invoke` (driven by the dispatcher), not this script.

## Protocol

### Arguments

```bash
<codex --json> | bash scripts/review-adapter-codex.sh
bash scripts/review-adapter-codex.sh <codex-json-file>
```

- Reads codex `review --json` from stdin (default, `-`) or a file argument.

### Exit codes

- `0` — emitted a review-manifest on stdout.
- `2` — input is not codex `review --json` (not an object with a `findings[]` array), or a
  named file is not found.

### Side effects

Reads stdin/a file; writes a manifest to stdout. **Scrubs control characters** from codex
output at this trust boundary (`scripts/lib/scrub-control-chars.sh`) before it is parsed or
can reach Claude's context. No filesystem/network mutation.

## Test surface

- **RAC-1:** output validates against `validate-review-manifest.sh` (the shared schema).
- **RAC-2:** `lane` is `codex` (provenance).
- **RAC-3:** severity map — codex `critical`→`critical`, `high`/`medium`→`warning`, `low`→`info`.
- **RAC-4:** `location` = `file:line_start`; `recommendation` falls back to `title — body` when empty.
- **RAC-5:** `files_reviewed` is the unique set of finding files.
- **RAC-6:** control chars (ANSI escapes) in codex text are scrubbed before reaching the manifest.
- **RAC-7:** non-codex input → exit 2.

## Versioning

- **1.0** — initial: codex `review --json` → review-manifest runtime adapter (#791).
