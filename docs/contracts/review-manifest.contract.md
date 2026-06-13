---
seam: review-manifest
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - review-manifest
related-designs:
  - docs/superpowers/specs/2026-06-13-section-dispatch-design.md
  - docs/superpowers/specs/2026-06-08-review-stage-design.md
owns: []
---
<!-- owner: pipeline-contracts-template -->

# review-manifest — Normalized Review-Result Contract

The **normalized-result contract** (the `manifest`) that every review worker emits,
regardless of adapter (`skill` or `runtime`) — the single schema that makes a reviewer
swappable by editing one registry row (`docs/specs/section-dispatch.spec.md` element 4,
referenced as `manifest_contract:` by the reviewer registry). It is the **stable seam**
of the review-stage section dispatch (#791): the dispatcher and merge never change when a
reviewer is swapped, because every worker speaks this schema. The schema is enforced by
`scripts/validate-review-manifest.sh` (owned, with its own CLI contract, by
`review-stage`); this document is the *seam description*, not a second owner of that
script (hence `owns: []`).

## Producer

A review worker (a `skill` adapter's fresh-context driver, or a `runtime` adapter's
bash+jq mapping of a CLI's `--json` output). Workers return **results, never reasoning**.

## Consumer

The deterministic merge (`docs/specs/section-dispatch.spec.md` element 6) reconciles the
per-worker manifests into one `ReviewResult`; `scripts/validate-review-manifest.sh`
gates each manifest at the adapter boundary.

## Protocol shape

### Inputs

None — this is a data seam, not a callable. Producers construct a manifest; consumers
read it. The schema below is the contract both sides obey.

### Outputs

A JSON object:

```jsonc
{
  "lane": "correctness",                 // string — the worker/lane id (provenance)
  "files_reviewed": ["a.ts", "b.sh"],    // array — files the worker examined
  "surface_identified": "diff",          // string — what was reviewed
  "coverage": [                          // array — what was evaluated
    { "category": "logic", "status": "evaluated", "why": "..." }
  ],
  "findings": [                          // array — the results
    { "severity": "warning", "location": "a.ts:42", "recommendation": "..." }
  ]
}
```

- `coverage[].status` ∈ `evaluated | cleared`.
- `findings[].severity` ∈ `critical | warning | info`.
- `findings[]` entries require `severity`, `location`, `recommendation`.

This is the schema `scripts/validate-review-manifest.sh` enforces. A `runtime` worker's
adapter MUST map its CLI output into exactly this shape (and scrub control characters at
that boundary); a `skill` worker's driver returns it directly.

### Invariants

- Every adapter — `skill` or `runtime` — emits this identical schema (the replaceability seam).
- A worker returning a manifest that fails `validate-review-manifest.sh` is **dropped with
  an explicit notice** (`section-dispatch` element 8); it is never silently merged.
- Workers return results, never reasoning.

## Test surface

- **RM-SCHEMA-1:** `scripts/validate-review-manifest.sh` accepts a well-formed manifest
  and rejects each missing/invalid field (its existing contract `validate-review-manifest.cli-contract.md`).
- **RM-SCHEMA-2:** both the `skill` and `runtime` adapters' outputs validate against the
  same schema (the #791 mixed-fan-out integration test).

## Versioning

- **1.0** — documents the shipped manifest schema as the section-dispatch `manifest_contract`
  seam for review-stage (#791).
