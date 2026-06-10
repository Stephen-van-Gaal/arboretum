---
seam: owner-doc-resolve
version: 1.0
producer-type: script
consumer-type: script
consumes: []
produces:
  - owner-document-path
related-designs:
  - docs/superpowers/specs/2026-06-09-group-spec-layer-design.md
owns:
  - scripts/lib/owner-doc-resolve.sh
---
<!-- owner: pipeline-contracts-template -->

# owner-doc-resolve — Group-Aware Owner→Document Resolution Contract

`scripts/lib/owner-doc-resolve.sh` is the single source of `# owner: <name>` →
governing-document resolution. It replaces the previously copy-pasted inline
`[ -f docs/specs/<name>.spec.md ]` check at three sites (the parallel-drift class of
#124) and makes resolution group-aware per D7 (#681): an owner name resolves to a
governed spec **or** a group document.

## Producer

`scripts/lib/owner-doc-resolve.sh` — producer-type: `script`.

A sourceable library that defines one function:

- `owner_doc_path <name> [project-dir]` — echoes the resolved document path and
  returns 0 when one exists; echoes nothing and returns 1 otherwise. Resolution
  order is `docs/specs/<name>.spec.md` (spec precedence) then `docs/groups/<name>.md`
  (D7 glue owner). `project-dir` defaults to `git rev-parse --show-toplevel`, else `pwd`.

## Consumer

`ci-checks.sh`, `health-check.sh`, and `_smoke-test-script-owners.sh` `source` the lib
and call `owner_doc_path` to decide whether a `# owner:` (or skill `owner:`) marker
resolves in the current root. No consumer re-inlines the spec/group existence check;
the producer is the sole source.

## Protocol shape

### Inputs

Positional: `<name>` (required), `[project-dir]` (optional). No stdin.

### Outputs

On success (return 0): the absolute path of the governing document on stdout. On
failure (return 1): nothing on stdout.

### Invariants

- **Spec precedence** — when both `docs/specs/<name>.spec.md` and `docs/groups/<name>.md`
  exist, the spec path is returned.
- **Group-aware** — a `<name>` with only a group document resolves to that group doc
  (the D7 case: a group owning thin orchestration glue).
- **Pure** — no side effects; filesystem lookup only.
- **Silent miss** — an unresolved name returns 1 with empty stdout (callers branch on
  the return code, never on output presence alone).

## Test surface

- **ODR-1: spec resolution.** A name with `docs/specs/<name>.spec.md` resolves to that
  path and returns 0.
- **ODR-2: group resolution (D7).** A name with only `docs/groups/<name>.md` resolves to
  that path and returns 0.
- **ODR-3: spec precedence + miss.** When both spec and group exist the spec wins; an
  unknown name returns 1 with empty stdout.

## Versioning

- **1.0** — initial contract: group-aware `owner_doc_path`, extracted from three inline
  spec-existence checks; consumed by ci-checks / health-check / script-owners (2026-06-09, #681).
