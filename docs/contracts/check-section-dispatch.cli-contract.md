---
script: scripts/check-section-dispatch.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-section-dispatch.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-13-section-dispatch-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/check-section-dispatch.sh`

## Surface

Conformance checker for the section-dispatch pattern (`docs/specs/section-dispatch.spec.md`). Given a section-dispatch registry file, asserts the *declarable* invariants of the pattern: a normalized-result contract is referenced (`manifest_contract:`), a degradation policy is declared (`degradation:`), every worker declares an adapter `type` from the closed set `{skill, runtime}`, every worker declares an `invoke` target, and every `runtime` worker declares `scrub: true`. It verifies declared structure, not semantic correctness (the floor; instantiation integration tests are the ceiling — see the spec's D6).

**v1 input shape.** The checker parses the canonical YAML-lite shape: top-level `manifest_contract:` and `degradation:` scalars, plus a `workers:` block whose entries are `- id:`-led mappings (`id` is the first key of each list item), each carrying `type`, `invoke`, and optional `scrub`. Comment-only scalar values count as absent; double-quoted scalars are read literally. **Not parsed in v1:** non-id-first key order within a worker mapping, and inline-flow rows (`workers: [{id: ...}]`). A registry with *no* parseable `- id:` rows fails closed (rejected as "no workers declared"). **v1 caveat (do not over-read on adversarial input):** in a *mixed* list an unsupported row after a valid `- id:` row is currently mis-attributed rather than reliably rejected, and a quoted-empty top-level value (`manifest_contract: ""`), a blank/comment-only worker id, and a malformed quoted scalar (`type: "runtime`) are not all caught. Hardening these edge cases is tracked in **#797**.

## Protocol

### Arguments

```
check-section-dispatch.sh <registry-file>
```

- `<registry-file>` (positional, required) — path to a section-dispatch registry (YAML-lite: top-level `manifest_contract:`, `degradation:`, and a `workers:` list of `{id, type, invoke, scrub?}`).

### Exit codes

- `0` — conformant.
- `1` — a conformance violation (first offender printed to stderr, prefixed `NONCONFORMANT:`).
- `2` — invocation/IO error (missing argument, file not found).

### Side effects

Read-only. Writes only to stdout/stderr; creates no files, performs no git operations, makes no network calls.

## Test surface

- **CLI-1: Conformant registry.** A registry with `manifest_contract`, `degradation`, and well-formed skill+runtime workers exits 0.
- **CLI-2: Missing adapter type.** A worker without `type` (or a type outside `{skill,runtime}`) exits 1 naming the worker.
- **CLI-3: Missing contract reference.** A registry lacking `manifest_contract:` exits 1.
- **CLI-4: Runtime without scrub.** A `type: runtime` worker lacking `scrub: true` exits 1 naming the worker.
- **CLI-5: Missing degradation policy.** A registry lacking `degradation:` exits 1.
- **CLI-6: Quoted scalars.** A worker whose `type`/`scrub` values are double-quoted (`type: "runtime"`, `scrub: "true"`) is accepted — YAML treats quoted and unquoted scalars identically.
- **CLI-7: Trailing comments.** A worker line with a trailing `# comment` after the `type`/`scrub` value is accepted (the comment is stripped before validation).
- **CLI-8: Comment-only top-level value.** A `manifest_contract:` or `degradation:` whose value is only a comment (e.g. `manifest_contract: # TODO`) is treated as absent and exits 1.
- **CLI-9: Missing invoke.** A worker with `id`/`type`/`scrub` but no `invoke` exits 1 — every worker row must declare a backend to run.
- **CLI-10: Quoted value containing `#`.** A quoted scalar whose content includes `#` (e.g. `type: "runtime # disabled"`) is read literally (the `#` is content, not a comment), so it fails the closed-set `type` check rather than passing as `runtime`.

## Versioning

Schema version `1.0`. The checker validates the v1 canonical YAML-lite registry shape described in *Surface*. Additive, backward-compatible changes (new optional row fields, broader scalar tolerance) bump the minor version. Changes that tighten acceptance or alter the parsed shape (e.g. supporting inline-flow rows or non-id-first key order, or making a previously-optional field required) bump the major version and update the CLI-N test surface in lockstep.
