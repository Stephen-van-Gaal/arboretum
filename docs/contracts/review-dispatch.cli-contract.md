---
script: scripts/review-dispatch.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/finish
  - type: script
    name: scripts/_smoke-test-review-dispatch.sh
related-designs:
  - docs/superpowers/specs/2026-06-08-review-stage-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/review-dispatch.sh`

## Surface

`scripts/review-dispatch.sh` deterministically computes the B4 review-stage lane plan for a change set. It is LLM-free and reproducible: the same file list always yields the same lane plan. `/finish` consumes its output to decide which review drivers to dispatch and in what order.

## Protocol

### Arguments

```bash
bash scripts/review-dispatch.sh <base-ref>
bash scripts/review-dispatch.sh --files-from <file|->
```

- `<base-ref>` — plan from `git diff <base-ref>...HEAD --name-only`.
- `--files-from <file|->` — plan from a newline-separated file list (`-` reads stdin).
- No arguments exits 1 with usage.

### Output

Lane identifiers, one per line, in run order:

- `ai-surface` — emitted **first**, only when changed files match the AI-facing path globs (`skills/`, `.claude/skills/`, `.claude/hooks/`, `.githooks/`, `scripts/`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`).
- `general-security` — **always** emitted (safe default).
- `correctness` — emitted only when the change set contains code (delegated to `classify-pr-change.sh` == `code`).

### Invariants

- `general-security` is always present, including on empty and docs-only diffs.
- `ai-surface`, when present, always precedes `general-security`.
- `correctness`, when present, always follows `general-security`.
- Output is deterministic and contains no LLM-derived content.
