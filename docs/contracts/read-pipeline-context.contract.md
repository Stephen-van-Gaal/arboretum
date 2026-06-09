---
seam: read-pipeline-context
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - pipeline-context-cache
  - scrubbed-string
produces:
  - pipeline-context-field
related-designs:
  - docs/superpowers/specs/2026-06-08-pipeline-context-ledger-design.md
owns:
  - scripts/read-pipeline-context.sh
---
<!-- owner: pipeline-contracts-template -->

# read-pipeline-context — Pipeline-context Cache Reader Contract

`scripts/read-pipeline-context.sh <field>` emits one field from
`.arboretum/pipeline-context-cache.json` **only when** the cache's `head_sha`
matches the current `HEAD`, scrubbing again at the consumer layer (via
`scripts/lib/scrub-control-chars.sh`) before emit.

## Producer

`scripts/read-pipeline-context.sh` — producer-type: `script`.

## Consumer

The ship-tail stage skills `/finish`, `/consolidate`, and `/pr` consume the
emitted field via a read-through pattern (`read-pipeline-context.sh <field>` →
on a non-zero miss, recompute live). `/pr` deliberately does **not** consume a
health-check field — there is none; health-check is recomputed fresh (design D3).

## Protocol shape

### Inputs

One positional arg, the field name ∈ `{issue, spec_index, changed_files,
diff_stat}`.

### Outputs

The requested field to stdout: `issue` and `changed_files` as JSON, `spec_index`
and `diff_stat` as text. Nothing on a miss.

### Invariants

- Exit 0 + field iff `stored head_sha == git rev-parse HEAD`.
- Exit non-zero (no stdout) on: SHA mismatch, missing cache, malformed JSON,
  unknown field.
- **Empty field is a miss.** An empty value (empty string, list, or object) for
  the requested field exits non-zero, so the consumer's live fallback runs rather
  than receiving an empty hit (preserves the additive invariant).
- **`spec_index` input-freshness.** `spec_index` additionally misses when
  `docs/REGISTER.md` is newer than the cache's `written_at` — catching an
  uncommitted REGISTER rewrite at the same `HEAD` (e.g. `/consolidate` before its
  commit).
- The reader never computes or writes — pure lookup.
- Emitted strings are free of the canonical control-char class.

## Test surface

- **RDC-1: fresh hit per field.** `_smoke-test-read-pipeline-context.sh` asserts
  each of `issue, spec_index, changed_files, diff_stat` is emitted when the cache
  stamp matches `HEAD`.
- **RDC-2: miss paths.** Reads exit non-zero (no stdout) on stale SHA, missing
  file, and unknown field.
- **RDC-3: consumer-layer scrub.** A control char in the cached issue body is
  absent from the emitted field.
- **RDC-4: field vocabulary + freshness gate.**
  `_smoke-test-contract-read-pipeline-context.sh` asserts the four documented
  fields hit, an undocumented field misses, and an advanced `HEAD` gates all
  reads.

## Versioning

- **1.0** — initial: four-field vocabulary, SHA-freshness gate.
