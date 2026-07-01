---
script: scripts/detect-design-doc-pr.sh
version: 1.0
invokers:
  - type: skill
related-designs:
  - docs/superpowers/specs/2026-06-28-codex-design-review-design.md
owner: git-workflow-tooling
---
<!-- owner: git-workflow-tooling -->

# Contract for `scripts/detect-design-doc-pr.sh`

## Surface

Single source of the **design-doc PR class** (#935). Prints `--design-doc` when
the current branch is a design-doc PR, otherwise prints nothing. Consumed by
`/pr` and `/land` so both scope reviewer requests identically — the detection
logic lives in one place instead of being duplicated (and drifting) across
skills.

A branch is a design-doc PR when BOTH hold:

1. its design spec resolves by the §5.5 branch-slug convention — including
   this repo's issue-prefixed branches (`feat/<issue>-<topic>`) — and its
   frontmatter is `kind: shaping`, and
2. the branch diff against `<base-ref>` classifies as `docs-config` via
   `classify-pr-change.sh` (the load-bearing gate: any `skills/*`,
   `.github/workflows/*`, or unknown-extension path makes it `code`, so a
   code- or skill-bearing PR is never a design-doc PR regardless of branch name
   or spec contents).

## Protocol

### Arguments

```text
detect-design-doc-pr.sh <base-ref>
```

- `<base-ref>` (positional, required) — the base ref the branch diff is computed
  against (e.g. `origin/main`), the same ref `/pr`/`/land` derive from
  `workspace_base_ref`.

### Exit codes

- `0` — always. The result is on stdout (`--design-doc` or empty). Callers
  interpolate stdout straight into a `request-review.sh` call, so an
  unresolvable branch, a non-shaping spec, a code diff, or a bad/empty base ref
  all degrade to the empty string (normal review), never a hard failure.

### Side effects

None. Read-only: resolves the design spec by glob, greps its frontmatter, and
classifies the diff. No writes, no network.

## Test surface

- **DDP-1:** an issue-prefixed branch (`feat/<issue>-<topic>`) with a
  `kind: shaping` design spec and a docs-only diff emits `--design-doc`.
- **DDP-2:** a buildable (non-`kind: shaping`) branch emits nothing.
- **DDP-3:** a `kind: shaping` spec with a code-bearing diff emits nothing
  (the classifier is the gate).
- **DDP-4:** a bad/unresolvable base ref degrades to empty (an empty diff is not
  a design-doc PR).

Covered by `scripts/_smoke-test-detect-design-doc-pr.sh`.

## Versioning

`1.0` — initial contract (#935). Bump the minor when adding an output token or
a new resolution candidate; bump the major on a breaking change to the stdout
contract or argument shape.
