---
script: scripts/validate-review-manifest.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/finish
  - type: script
    name: scripts/_smoke-test-validate-review-manifest.sh
related-designs:
  - docs/superpowers/specs/2026-06-08-review-stage-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/validate-review-manifest.sh`

## Surface

`scripts/validate-review-manifest.sh` enforces the review-manifest seam schema so a malformed manifest is rejected rather than silently accepted. It is the enforcement that makes the brief/manifest seam a real contract: any lane backend (homegrown driver, built-in `/security-review`, `/code-review`, or a future external SAST) must return a manifest that passes this validator.

## Protocol

### Arguments

```bash
bash scripts/validate-review-manifest.sh <manifest-file>
```

- `<manifest-file>` — path to a JSON manifest document. Missing argument exits with usage.

### Required fields

- `lane` (string) — which lane produced the manifest.
- `files_reviewed` (array) — paths read in full.
- `surface_identified` (string) — the risk/review surface found.
- `coverage` (array) — each entry `{category, status, why}`; `status` ∈ {`evaluated`, `cleared`}.
- `findings` (array) — each entry `{severity, location, recommendation}`; `severity` ∈ {`critical`, `warning`, `info`}.

### Exit

- `0` — valid.
- `1` — schema violation; the first offending field is printed to stderr.
