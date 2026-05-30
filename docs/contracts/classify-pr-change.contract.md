---
seam: classify-pr-change
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/classify-pr-change.sh
---
<!-- owner: pipeline-contracts-template -->

# classify-pr-change — `classify-pr-change.sh` Change-Set Classifier Contract

The seam between `scripts/classify-pr-change.sh` (which classifies a change set as `docs-config` or `code` to drive the tiered merge handoff) and the `/land` skill, which pipes a PR's changed-file list into the script and branches the merge tier on the single-token stdout. This contract pins the closed `{docs-config, code}` output, the path-classification rules, and the safe-default behaviour so `/land` never has to re-implement the docs-vs-code decision.

## Producer

`scripts/classify-pr-change.sh` — producer-type: `script`.

Reads a set of changed file paths and prints exactly one token — `docs-config` or `code` — to stdout, then exits `0`. Two input modes:

- `classify-pr-change.sh <base-ref>` — classifies `git diff <base-ref>...HEAD --name-only`.
- `classify-pr-change.sh --files-from -` — classifies a newline-separated path list read from stdin (the mode `/land` uses).
- `classify-pr-change.sh --files-from <file>` — classifies a path list read from a file.

Classification scans the path list and short-circuits to `code` on the **first** path that changes agent or repo behaviour:

- `skills/*`, `.claude/skills/*` → `code` (skill files change agent behaviour).
- `.github/workflows/*` → `code` (CI definitions change repo behaviour).
- `*.md`, `*.txt`, `docs/*`, `.github/*` (non-workflow), `*.yml`, `*.yaml`, `*.json`, `.gitignore`, `LICENSE` → treated as docs/config (does not trigger `code` on its own).
- Any other path → `code`.

If no path triggers `code` (including an empty list), the script prints `docs-config` as the safe default.

## Consumer

Consumer-type: `skill`. One downstream consumer:

- **`skills/land/SKILL.md`** (~line 177) runs `gh pr diff <N> --name-only | bash scripts/classify-pr-change.sh --files-from -` and branches the merge handoff tier on the `docs-config` vs `code` token.

**Consumer obligations:**

- Consumers MUST treat the stdout token as a closed two-value set — `docs-config` or `code`, nothing else.
- Consumers MUST treat `code` as the higher-scrutiny tier — any code, skill, or workflow change short-circuits to it.
- Consumers MUST accept `docs-config` as the meaning of "empty diff / docs-and-config-only" — the safe default is not an error.

## Protocol shape

### Inputs

- `<base-ref>` positional — classify `git diff <base-ref>...HEAD --name-only` (requires a git repo). OR
- `--files-from -` — newline-separated path list on stdin. OR
- `--files-from <file>` — newline-separated path list in a file.

### Outputs

- stdout: exactly one token, `docs-config` or `code`, followed by a newline.
- Exit code: `0` in all classification modes. (A missing `<base-ref>` argument with no `--files-from` triggers the `:?` usage guard — non-zero.)

### Invariants

- **Closed value set.** stdout is always exactly `docs-config` or `code` — never a third token.
- **First-code-wins short-circuit.** Classification returns `code` on the first behaviour-changing path encountered; it does not need to read the rest of the list.
- **Skill/workflow paths are code.** `skills/*`, `.claude/skills/*`, and `.github/workflows/*` classify as `code` even though they are not source-language files — they change agent/repo behaviour.
- **Safe default.** An empty path list (or a list of only docs/config paths) classifies as `docs-config`, never `code`.
- **No mutation.** Read-only — the script never writes any file.

## Test surface

- **CPC-1:** A docs-only file list (`README.md`, `docs/x.md`) via `--files-from -` → stdout `docs-config`.
- **CPC-2:** A list containing a source file (e.g. `src/foo.ts`) → stdout `code`.
- **CPC-3:** A list whose only behaviour-changing path is a skill file (`skills/build/SKILL.md`) → stdout `code` (boundary: skill paths are code).
- **CPC-4:** A list whose only behaviour-changing path is `.github/workflows/ci.yml` → stdout `code` (boundary: workflow paths are code, even though `.github/*` and `*.yml` are otherwise docs-config).
- **CPC-5:** Config-only file list (`contracts.yaml`, `.gitignore`, `package.json`) → stdout `docs-config`.
- **CPC-6:** Empty stdin (no paths) → stdout `docs-config` (safe default).
- **CPC-7:** `--files-from <file>` mode classifies a file-borne list identically to the stdin mode.

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/classify-pr-change.sh` on this branch. Issue #303 (WS5 PR 7a).
