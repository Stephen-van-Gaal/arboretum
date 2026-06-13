---
script: scripts/build-review-request.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-build-review-request.sh
  - type: skill
    name: arboretum:/finish
related-designs:
  - docs/superpowers/specs/2026-06-13-section-dispatch-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/build-review-request.sh`

## Surface

Constructs the **ReviewRequest** the pipeline stage hands the dispatcher (#791 D2,
section-dispatch element 1: the context-parameterized request). Emits the
`{altitude, artifact, base, brief}` object whose `altitude` + `artifact` dimensions
`review-registry-filter.sh` selects workers on. LLM-free.

## Protocol

### Arguments

```bash
bash scripts/build-review-request.sh --altitude <design|build|finish> \
                                     --artifact <doc|diff|tree> \
                                     --base <ref> [--brief <file|->]
```

- `--altitude` — closed set `design|build|finish`.
- `--artifact` — closed set `doc|diff|tree`.
- `--base` — the ref the diff is scoped against (required).
- `--brief` — free-text context for the workers; from a file or `-` (stdin). Optional
  (defaults to empty string). **Not scrubbed**: the brief is authored by this pipeline,
  not external input — runtime worker *output* is scrubbed at its adapter boundary.

### Exit codes

- `0` — emitted a ReviewRequest JSON object on stdout.
- `2` — `--altitude`/`--artifact` outside its closed set, `--base` missing, an unknown
  argument, or a `--brief` file not found.

### Side effects

Reads an optional brief from stdin/a file; writes JSON to stdout. No mutation.

## Test surface

- **BRR-1:** emits an object carrying all four request dimensions (brief from `-`).
- **BRR-2:** `brief` defaults to `""` when `--brief` is omitted.
- **BRR-3:** altitude outside `{design,build,finish}` → exit 2.
- **BRR-4:** artifact outside `{doc,diff,tree}` → exit 2.
- **BRR-5:** missing `--base` → exit 2.

## Versioning

- **1.0** — initial: ReviewRequest builder for the review-stage section dispatch (#791).
