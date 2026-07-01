---
seam: model-families
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - model-family-id
related-designs:
  - docs/superpowers/specs/2026-06-28-pipeline-model-routing-design.md
owns:
  - scripts/lib/model-families.sh
---
<!-- owner: skill-and-agent-authoring -->

# model-families — Family→Model-ID Map Contract

`scripts/lib/model-families.sh` is a dependency-free, sourceable map from a model
*family* name (`cheap` / `capable` / `frontier`) to a concrete model id. It is the
single source of the family→id pairs for model routing: `resolve-stage-model.sh`
sources it, and the two internal Haiku sub-dispatch sites (`roadmap`,
`extract-component`) resolve `cheap` through it rather than hardcoding an id.

## Producer

`scripts/lib/model-families.sh` — producer-type: `script`.

A side-effect-free library, sourced (never executed directly). It defines one
function, `resolve_model_family <family>`, which echoes the concrete model id for
a known family and exits non-zero with a stderr diagnostic for an unknown one.
Concrete ids carry a dated re-verify note and must be re-checked on a model
release (mirrors `token-rates.sh`).

## Consumer

`scripts/resolve-stage-model.sh` (and the two Haiku sub-dispatch skill sites) —
consumer-type: `script`. Consumers depend on the fixed `resolve_model_family`
signature and the fail-loud contract on unknown families.

## Protocol shape

### Inputs

One positional argument: a model family name in the closed set
`cheap | capable | frontier`.

### Outputs

A single concrete model id printed to stdout for a known family. An unknown
family prints a `model-families: unknown family ...` diagnostic to stderr and
returns non-zero (no stdout).

### Invariants

- Total over `{cheap, capable, frontier}`; each maps to a non-empty id.
- An unknown family fails loud (non-zero exit), never a silent fallback.
- The family→id pairs appear in this file only (single source); other surfaces
  resolve a family rather than restating an id.

## Test surface

- **MF-1: known family.** `resolve_model_family cheap|capable|frontier` prints a
  non-empty concrete id.
- **MF-2: unknown fails loud.** An unrecognized family returns non-zero with a
  stderr diagnostic and no stdout.
- **MF-3: single source.** Each concrete id (`claude-haiku-4-5`,
  `claude-sonnet-5`, `claude-opus-4-8`) appears only in `model-families.sh`,
  not in any other script or skill surface.

## Versioning

- **1.0** — initial contract: `cheap/capable/frontier` → concrete id map (2026-06-28).
