---
script: scripts/review-dispatch.sh
version: 1.1
invokers:
  - type: skill
    name: arboretum:/finish
  - type: script
    name: scripts/_smoke-test-review-dispatch.sh
  - type: script
    name: scripts/_smoke-test-contract-review-dispatch-verdicts.sh
related-designs:
  - docs/superpowers/specs/2026-06-08-review-stage-design.md
  - docs/superpowers/specs/2026-06-24-review-dispatch-gate-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/review-dispatch.sh`

## Surface

`scripts/review-dispatch.sh` deterministically computes the B4 review-stage lane plan for a change set. It is LLM-free and reproducible: the same file list always yields the same lane plan. `/finish` consumes its output to decide which review drivers to dispatch and in what order.

## Protocol

### Arguments

```bash
bash scripts/review-dispatch.sh [--verdicts] <base-ref>
bash scripts/review-dispatch.sh [--verdicts] --files-from <file|->
```

- `<base-ref>` — plan from `git diff <base-ref>...HEAD --name-only`.
- `--files-from <file|->` — plan from a newline-separated file list (`-` reads stdin).
- `--verdicts` — optional; when present it must be the **first** argument (it may precede `<base-ref>` or `--files-from`). Switches output to verdict mode.
- No arguments exits 1 with usage.

### Output

**Lane-list mode (default).** Lane identifiers, one per line, in run order:

- `ai-surface` — emitted **first**, only when changed files match the AI-facing path globs (`skills/`, `.claude/skills/`, `.claude/hooks/`, `.githooks/`, `scripts/`, `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`).
- `general-security` — **always** emitted (safe default).
- `correctness` — emitted only when the change set contains code (delegated to `classify-pr-change.sh` == `code`).

**Verdict mode (`--verdicts`, #854).** A single JSON object replacing the lane list — per-lane relevance for the B4 review-dispatch gate:

```json
{
  "lanes": {
    "ai-surface":       { "relevant": <bool>, "reason": "<string>" },
    "general-security": { "relevant": <bool>, "reason": "<string>" },
    "correctness":      { "relevant": <bool>, "reason": "<string>" }
  },
  "any_relevant": <bool>
}
```

- `ai-surface.relevant` — true when the AI-facing globs match (same predicate as lane-list).
- `correctness.relevant` — true when `classify-pr-change.sh` == `code`.
- `general-security.relevant` — true unless **every** changed path is **provably-safe prose** (the `is_safe_prose` ALLOWLIST): root `README.md`/`CHANGELOG.md`, any `*.txt`, or a *direct* child of `docs/` (`docs/*.md`, not nested). Everything outside the allowlist keeps `general-security` relevant — code, config (`*.yml`/`*.json`/`.github/*`), `*.rst` (treated as code by `classify-pr-change.sh`), skill/instruction files, and nested/agent-facing docs (`workflows/*.md`, `ARBORETUM.md`, `docs/templates/*`, `docs/specs/*`). Allowlist, not blocklist: in an instruction-dense repo a blocklist cannot enumerate every agent-facing `*.md`, so the gate fails toward reviewing.
- `reason` strings are fixed templates keyed by file-class — no untrusted free-text from file paths.

### Invariants

- **Lane-list mode is unchanged from v1.0:** `general-security` is always present (including empty and docs-only diffs); `ai-surface` precedes it; `correctness` follows it. The verdict mode does not alter lane-list output.
- In verdict mode, `any_relevant` is the boolean OR of the three lanes' `relevant` values.
- Verdict mode emits exactly the three lanes `ai-surface`, `general-security`, `correctness`, each with a boolean `relevant` and a string `reason`.
- Output is deterministic and contains no LLM-derived content (both modes are LLM-free, zero model tokens).
