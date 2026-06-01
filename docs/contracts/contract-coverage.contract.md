---
seam: contract-coverage
version: 1.1
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
  - filesystem-scan-surface
produces:
  - coverage-manifest-schema
related-designs:
  - docs/superpowers/specs/2026-05-30-pipeline-overhaul-ws5-pr6-contract-coverage-meta-design.md
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/generate-coverage.sh
  - scripts/validate-coverage-manifest.sh
---
<!-- owner: pipeline-contracts-template -->

# contract-coverage — `generate-coverage.sh` → `_coverage.md` → `validate-coverage-manifest.sh` Contract

The **drift-detection meta-contract**: the seam between the script that produces the coverage manifest (`scripts/generate-coverage.sh` → `docs/contracts/_coverage.md`) and the script that freshness-checks it in CI (`scripts/validate-coverage-manifest.sh`). It is the formal answer to issue #140 — *"arboretum is a tool for detecting drift between artifacts, but currently fails to detect drift in its own artifacts."* WS5's entire contract surface is that answer; this contract makes the answer self-referential, pinning the invariant that **the drift detector is itself a contracted, drift-checked surface**. Closes #140.

The meta-property is conceptual, not a data-layer cycle: the manifest's rows are scanned `*.sh` files (`scripts/**/*.sh`, `.claude/hooks/**/*.sh`), and this contract document is read by `generate-coverage.sh` *as a coverage source*, never scanned *as a covered row*. So the contract names the two coverage scripts; the scripts never name the contract back as a row; there is no bootstrap ordering hazard.

## Producer

`scripts/generate-coverage.sh` — producer-type: `script`.

Walks the governance-script surface (`scripts/**/*.sh` and `.claude/hooks/**/*.sh`, excluding any path with a `_*` component), reads every `*.contract.md` (full WS3a shape — `owns:` list) and `*.cli-contract.md` (lighter WS5 shape — `script:` scalar) in `docs/contracts/`, and writes `docs/contracts/_coverage.md`: a deterministic table mapping each scanned surface to its covering contract (or `MISSING`). Reads contract frontmatter through `scripts/lib/yaml-lite.sh`: full-shape contracts contribute `owns[]` entries and CLI-shape contracts contribute the `script` scalar. Duplicate detection and row emission use Python 3 standard library only. Deterministic by construction — `LC_ALL=C sort`, no timestamps, stable formatting, bash-3.2 compatible (no `declare -A`). Raises `DUPLICATE-OWNERSHIP` and exits non-zero if two contracts claim the same surface. Emits a `Rollout in progress` annotation in the manifest header while any `MISSING` row remains.

## Consumer

`scripts/validate-coverage-manifest.sh` — consumer-type: `script`. Read-only; invoked from `scripts/ci-checks.sh` via the `=== Contract coverage validation ===` line (peer to `=== Cross-reference validation ===`).

Verifies the committed `_coverage.md` is both **fresh** (matches a fresh `generate-coverage.sh` run) and **complete** (every in-scope surface has a row). It regenerates into an isolated temp dir — symlinking the real `scripts/` and `.claude/` trees, copying the contract files, copying the YAML-lite helper beside the copied generator, and placing the regenerator at `$tmp/_regen.sh` *outside* the scanned tree so its own presence does not pollute the table — then `diff`s the fresh output against the committed file. It never modifies the committed manifest. Two-mode progression (post-re-tightening):

- **Bootstrap** — zero `*.cli-contract.md` files in `docs/contracts/` (PR-1-of-WS5 only). Emits a stderr note and exits 0. Structurally unreachable once any cli-contract lands (PR 2): deleting all manifest rows cannot re-enter bootstrap, because the cli-contract file remains on disk.
- **Strict** — no `MISSING` rows permitted. Fails (`COVERAGE-MANIFEST-INCOMPLETE`, non-zero) if any in-scope surface is uncovered. **This is the live steady state.** A `MISSING` row is now only reachable as a regression — a new uncovered governance surface — and it fails the build.

The contract originally specified a third, transitional **Ramp** tier: while the WS5 sweep PRs (6 / 7a / 7b) were still populating the manifest, a `MISSING` row exited 0 with a warning naming the remaining count and the sweep PRs, keeping every intermediate PR CI-green without sweeping coverage prematurely. That tier was a rollout-window scaffold; the **re-tightening event that removed it** is the deletion of the ramp branch from `validate-coverage-manifest.sh`. The WS5 design and this contract pinned that deletion to PR 7b, but PR 7b shipped without it (it auto-removed the manifest's *"rollout in progress"* comment — a `generate-coverage.sh` behaviour — and mistook that for re-tightening the validator). The deletion was completed as a Pass-2 reconciliation finding (see the WS5 follow-up issue), restoring strict enforcement.

## Protocol shape

### Inputs

`generate-coverage.sh` takes no CLI arguments; it derives its root from `$(pwd)`. Under that root it reads:

- `scripts/**/*.sh` and `.claude/hooks/**/*.sh` — the scanned surfaces (recursive; any path containing a `_*` component is excluded — `_smoke-test-*.sh`, `_archived/`, `_fixtures/`, `lib/_*`).
- `docs/contracts/*.contract.md` — full-shape contracts; the `owns:` YAML list names covered surfaces.
- `docs/contracts/*.cli-contract.md` — cli-shape contracts; the `script:` scalar names the single covered surface.

`validate-coverage-manifest.sh` takes no arguments; it reads the committed `docs/contracts/_coverage.md` plus the same scan surface (via its sandboxed regen).

### Outputs

`generate-coverage.sh` writes `docs/contracts/_coverage.md`:

1. `# Governance-script contract coverage` heading.
2. An `<!-- AUTO — regenerated by scripts/generate-coverage.sh from filesystem scan. -->` comment, a `Sources:` comment, and — while any `MISSING` row remains — a `Rollout in progress` comment.
3. A table with three columns: `| Script / Hook | Contract | Shape |`. Each scanned surface is one row; `Contract` is the covering contract's repo-relative path or `MISSING`; `Shape` is `full`, `cli`, or `—`. Rows are `LC_ALL=C`-sorted by surface path (scripts before hooks).

`validate-coverage-manifest.sh` writes nothing to disk; it signals via exit code (0 = pass/bootstrap, non-zero = drift or incompleteness) and stderr diagnostics.

### Invariants

- **Self-coverage (the #140 meta-invariant).** A contract whose `owns:`/`script:` frontmatter names the two coverage scripts causes a fresh `generate-coverage.sh` run to map both rows to that contract (shape `full`), not `MISSING`. The drift detector is itself covered. (CC-1.)
- **Deterministic regen.** Running `generate-coverage.sh` twice in succession produces byte-identical `_coverage.md` (`LC_ALL=C sort`, no timestamps). Necessary precondition for the freshness gate — a non-deterministic generator could never pass a `diff` against its own re-run. (CC-2.)
- **Freshness-drift detection.** `validate-coverage-manifest.sh` exits non-zero with `COVERAGE-MANIFEST-DRIFT` when the committed manifest differs from a fresh regen, and exits 0 when they match. (CC-3.)
- **Read-only validation.** The validator leaves the committed `_coverage.md` byte-identical before and after a run — it regenerates into an isolated temp dir and never writes the artifact it checks. (CC-4.)
- **Duplicate-ownership rejection.** `generate-coverage.sh` exits non-zero with `DUPLICATE-OWNERSHIP` when two contracts claim the same surface. This guards the one-contract-per-surface invariant the manifest depends on. (CC-5.)
- **Strict-mode completeness.** With the rollout-window ramp tier removed (the PR-7b re-tightening, completed during Pass 2), any `MISSING` row in the committed manifest fails the validator non-zero with `COVERAGE-MANIFEST-INCOMPLETE`. A regression that adds an uncovered governance surface fails the build rather than passing with a warning. (CC-6.)
- **Scan-scope exclusion.** Surfaces under a `_*` path component (`_smoke-test-*.sh`, `_archived/`, `_fixtures/`) are excluded from the manifest — they never get a row. This is what lets this contract's own smoke test live in `scripts/` without creating a `MISSING` row. (CC-7.)
- **Bare-checkout portable.** Coverage regeneration does not require PyYAML, yq, jq, or any package install.

## Test surface

Asserted by `scripts/_smoke-test-contract-contract-coverage.sh` against fixture projects (`mktemp -d` skeletons; the live coverage scripts run with `cwd` set to the fixture root):

- **CC-1: Self-coverage (the #140 meta-invariant).** Given a contract whose `owns:` lists the two coverage scripts, a fresh `generate-coverage.sh` run maps both script rows to that contract (shape `full`), not `MISSING`.
- **CC-2: Deterministic regen.** Running `generate-coverage.sh` twice against the same fixture produces byte-identical `_coverage.md`.
- **CC-3: Freshness-drift detection.** `validate-coverage-manifest.sh` exits non-zero with `COVERAGE-MANIFEST-DRIFT` when the committed manifest differs from a fresh regen; exits 0 when they match.
- **CC-4: Read-only validation.** `validate-coverage-manifest.sh` leaves the committed `_coverage.md` byte-identical before and after a run.
- **CC-5: Duplicate-ownership detection.** `generate-coverage.sh` exits non-zero with `DUPLICATE-OWNERSHIP` when two contracts claim the same surface.
- **CC-6: Strict-mode completeness.** With the ramp tier removed, a `MISSING` row (a regression) makes the validator exit non-zero with `COVERAGE-MANIFEST-INCOMPLETE`.
- **CC-7: Scan-scope exclusion.** Surfaces under a `_*` path component are excluded from the manifest — no row is emitted for them.

## Versioning

- **1.1** (2026-05-31) — re-tightening: the transitional ramp tier was removed from `validate-coverage-manifest.sh`, making strict mode the live steady state. CC-6 flips from "ramp-mode discipline" to "strict-mode completeness." This is the PR-7b re-tightening event the 1.0 contract pinned but PR 7b shipped without; completed as a Pass-2 reconciliation finding. No producer behaviour change.
- **1.0** (2026-05-30) — initial contract. Producer + consumer shapes as of `scripts/generate-coverage.sh` and `scripts/validate-coverage-manifest.sh` (PR 1 of WS5) plus the ramp-mode branch (PR 5) on `main`. Closes #140 ("arboretum should detect drift in its own artifacts") as resolved-by-construction — CC-1 asserts the drift detector is itself covered, and CI fails on any regression that drops the coverage scripts' rows or breaks the freshness/duplicate/ramp invariants. The lifecycle-enum-unification item of #140 (Item 4) is tracked independently as #398.
