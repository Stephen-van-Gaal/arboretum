---
seam: refresh-pipeline-context
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - scrubbed-string
produces:
  - pipeline-context-cache
related-designs:
  - docs/superpowers/specs/2026-06-08-pipeline-context-ledger-design.md
owns:
  - scripts/refresh-pipeline-context.sh
---
<!-- owner: pipeline-contracts-template -->

# refresh-pipeline-context — Pipeline-context Cache Writer Contract

`scripts/refresh-pipeline-context.sh <issue>` computes the ship-tail handoff
fields for the current `HEAD` and writes `.arboretum/pipeline-context-cache.json`
atomically, scrubbing every author-controlled string at the source layer via
`scripts/lib/scrub-control-chars.sh` (the shared scrub primitive — no inline
regex, per the SCC-3 enforcement guard).

## Producer

`scripts/refresh-pipeline-context.sh` — producer-type: `script`.

## Consumer

`scripts/read-pipeline-context.sh` consumes the produced cache file (the only
reader of the `head_sha` stamp + fields). Transitively, the ship-tail stage
skills (`/finish`, `/consolidate`, `/pr`) consume individual fields through that
reader's read-through pattern. No consumer re-parses the cache JSON directly.

## Protocol shape

### Inputs

One positional arg: the tracker issue number. Reads `HEAD`, the `main`-based diff
range, `docs/REGISTER.md` § Spec Index, and `gh issue view <issue>`.

### Outputs

`.arboretum/pipeline-context-cache.json` with exactly these top-level keys:

    head_sha, base_ref, written_at,
    issue {number, title, body, labels},
    spec_index, changed_files, diff_stat

### Invariants

- `head_sha` equals `git rev-parse HEAD` at write time.
- Every string field is free of the canonical control-char class.
- Atomic write (`mktemp` → `mv`); never a partial file.
- Exit 0 on success; degraded inputs (missing issue / REGISTER) yield empty
  fields, not failure.

## Test surface

- **RPC-1: well-formed, SHA-stamped cache.** `_smoke-test-refresh-pipeline-context.sh`
  asserts the cache is written, `head_sha` equals `git rev-parse HEAD`, and the
  issue/spec-index fields are carried.
- **RPC-2: source-layer scrub.** A control char embedded in the issue body
  (JSON-escaped, as `gh` emits) is absent from the written cache.
- **RPC-3: exact key set.** `_smoke-test-contract-refresh-pipeline-context.sh`
  asserts the produced cache carries exactly
  `head_sha, base_ref, written_at, issue, spec_index, changed_files, diff_stat`.

## Versioning

- **1.0** — initial: issue snapshot + spec-index + diff/changed-files, SHA-stamped.
