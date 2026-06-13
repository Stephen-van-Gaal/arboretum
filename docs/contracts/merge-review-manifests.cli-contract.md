---
script: scripts/merge-review-manifests.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-merge-review-manifests.sh
  - type: skill
    name: arboretum:/finish
related-designs:
  - docs/superpowers/specs/2026-06-13-section-dispatch-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/merge-review-manifests.sh`

## Surface

The **deterministic, LLM-free merge** (#791 D6, section-dispatch element 6): reconciles N
worker manifests (`docs/contracts/review-manifest.contract.md`) into one **ReviewResult**.
Findings are deduped by `(location, normalized recommendation)` — the "rule" of the
issue's `(file, line, rule)` key, since the manifest carries no separate rule field; on a
collision the highest severity wins (`critical > warning > info`) and lane provenance is
unioned. Semantic dedupe (differently worded findings about one defect) is deliberately
out of scope — that needs an LLM; this is the LLM-free floor.

## Protocol

### Arguments

```bash
bash scripts/merge-review-manifests.sh [--degraded id,id,...] <manifest-file>...
```

- `--degraded` — comma-separated ids of reviewers whose backend was absent (recorded in
  `reviewers_degraded`; supplied by the dispatcher, never inferred here).
- positional — one or more worker manifest files.

### Output — the ReviewResult

```jsonc
{
  "reviewers_run": ["ai-surface","codex"],     // contributing lanes, in dispatch order
  "reviewers_degraded": ["general-security"],  // from --degraded
  "files_reviewed": [ ... ],                    // union, sorted-unique
  "coverage": [ { ...manifest coverage entry..., "lane": "<id>" } ],
  "findings": [ { "severity", "location", "recommendation", "lanes": [ ... ] } ]
}
```

### Exit codes

- `0` — emitted a ReviewResult on stdout.
- `2` — no manifest files given, an unknown flag, or a named manifest not found.

### Side effects

Reads manifest files; writes JSON to stdout. No mutation. A degenerate fan-out (one
worker) skips merge at the dispatcher; invoked on a single manifest here it still returns
a well-formed ReviewResult.

## Test surface

- **MRM-1:** two manifests merge; `reviewers_run` preserves dispatch order; `files_reviewed` unioned.
- **MRM-2:** same location + same normalized recommendation dedupes to one finding with both lanes.
- **MRM-3:** severity collision resolves to the max (warning + critical → critical).
- **MRM-4:** `--degraded` populates `reviewers_degraded`, absent from `reviewers_run`.
- **MRM-5:** recommendation normalization (case + whitespace) collapses; max-severity text kept.
- **MRM-6:** degenerate (one manifest) → ReviewResult wraps it, findings 1:1.
- **MRM-7:** coverage entries carry lane provenance.
- **MRM-8:** `--degraded` tolerates a trailing comma without leaking an empty `""` id.

## Versioning

- **1.0** — initial: manifests → ReviewResult merge for review-stage (#791).
