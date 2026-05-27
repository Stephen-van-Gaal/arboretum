---
seam: register-pipeline
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
  - spec-status-state-machine
produces:
  - register-schema
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/generate-register.sh
---
<!-- owner: pipeline-contracts-template -->

# register-pipeline — `generate-register.sh` → `REGISTER.md` Contract

The seam between `scripts/generate-register.sh` (producer of `docs/REGISTER.md`) and the three downstream scripts/hooks that read REGISTER.md: `scripts/health-check.sh` (Checks 2/3 and Check 7), `scripts/validate-cross-refs.sh`, and `.claude/hooks/session-start.sh`. The schema-coupled-scripts chain CLAUDE.md calls out by name — issue #124 (the original schema-drift incident) is the canonical historical bug this contract pins against. Two folded-in bugs close as non-recurrable: #259 (non-idempotency of `generate-register.sh`) and #128 (status-summary table silently dropped values outside `{draft, active, stale}`).

## Producer

`scripts/generate-register.sh` — producer-type: `script`.

Walks `docs/specs/*.spec.md`, extracts YAML frontmatter (`name`, `status`, `owner`, `owns`, `provides`, `requires`), resolves `owns:` patterns to actual files, and writes `docs/REGISTER.md`. Idempotent by construction: running twice in a row produces byte-identical output (the trim-trailing-blank-line discipline at `generate-register.sh:248-249` and `:267-268` — in the `# ── Preserve sections from existing REGISTER.md ──` block, the two `# Strip trailing blank lines so each regeneration doesn't accumulate them` sites — enforces this). Status-summary section iterates *observed* status labels rather than a hard-coded enum (the `_summary_order` loop at `generate-register.sh:435-451`), so projects using extended-enum vocabularies (`ready`, `in-progress`, `implemented`, etc.) have their states surfaced rather than silently dropped.

## Consumer

Three downstream consumers, all consumer-type: `script` or `hook`:

- **`scripts/health-check.sh`** (script). Parses the `## Spec Index` table to drive Checks 2/3 (file-ownership drift, status-flip drift) and Check 7 (spec-drift auto-flip `active → stale` — iterates the `## Spec Index` rows via `grep -E '^\|.*\.spec' "$REGISTER"`). Reads the 4-column schema `Spec | Status | Owner | Owns` introduced by #124's fix.
- **`scripts/validate-cross-refs.sh`** (script). Reads REGISTER.md to validate cross-references between specs.
- **`.claude/hooks/session-start.sh`** (hook). Reads REGISTER.md to detect a stale register at session start and surface a "run `scripts/generate-register.sh` to resync" hint to the user.

The three consumers share the same parsing contract: the `## Spec Index` table is the data surface; column order and column count are part of the contract. Schema drift between producer and consumers is precisely the failure mode #124 exhibited.

## Protocol shape

### Inputs

`generate-register.sh` accepts two optional CLI arguments:

- **`[project-dir]`** — positional, defaults to `$(pwd)`. Sets the root under which `docs/specs/`, `docs/definitions/`, and `docs/REGISTER.md` are resolved.
- **`--dry-run`** — print generated content to stdout instead of writing to `docs/REGISTER.md`. Exit code unchanged.

Reads (under the project-dir root):

- `docs/specs/*.spec.md` files (recursive, but excludes `docs/specs/_*` subdirectories per the `find ... -prune` discipline at `generate-register.sh:55` — grep for `-name '_*' -prune` under the `# ── Find spec files ──` banner).
- Frontmatter fields on each spec: `name` (scalar), `status` (scalar), `owner` (scalar), `owns` (YAML list), `provides` (YAML list), `requires` (YAML list).
- `docs/definitions/*.md` (optional; emits the Definition Index placeholder if absent).
- Pre-existing `docs/REGISTER.md` (if present) for preservation of `## Unowned Code` and `## Dependency Resolution Order` sections.

### Outputs

Writes `docs/REGISTER.md` with five top-level sections in this fixed order:

1. **`## Definitions Index`** — table with 5 columns (`Name | Version | Status | Provided By | Required By`).
2. **`## Spec Index`** — table with 4 columns (`Spec | Status | Owner | Owns (files/directories)`). Column order, count, and header text are part of the contract — schema drift here is the #124 incident.
3. **`## Status Summary`** — table with 2 columns (`Status | Count`). Rows emit *all* status labels actually observed in spec frontmatter — canonical states (`draft`, `active`, `stale`) emit first in lifecycle order; non-canonical states emit alphabetically after. No status label that appears in spec frontmatter is silently dropped.
4. **`## Unowned Code`** — preserved from pre-existing REGISTER.md if present, else emits the canonical placeholder comment.
5. **`## Dependency Resolution Order`** — preserved from pre-existing REGISTER.md if present, else emits the canonical placeholder comment.

In `--dry-run` mode, the same content goes to stdout; `docs/REGISTER.md` on disk is untouched.

### Invariants

- **Idempotency.** Running `bash scripts/generate-register.sh` twice in succession produces byte-identical `docs/REGISTER.md`. (#259's fix; #259 closed.) This invariant is necessary for any downstream freshness gate: a non-idempotent generator can never pass a `diff -q` check against its own re-run.
- **Vocabulary-agnostic status summary.** The `## Status Summary` section enumerates *all* distinct status values that appear in spec frontmatter. Specs at `ready`, `in-progress`, `implemented`, or any other label are counted, not silently dropped. (#128's fix; #128 closed.) The implementation is at `generate-register.sh:435-451` — canonical states emit first in lifecycle order; observed-but-non-canonical states emit alphabetically after.
- **Schema stability.** The `## Spec Index` table is 4 columns (`Spec | Status | Owner | Owns`). Column count and order are immutable in the v1.x contract series. The #124 incident was precisely a producer-side schema change that broke `health-check.sh`'s parser; a contract test now prevents that recurrence.
- **Section-content preservation.** When a pre-existing `docs/REGISTER.md` contains content under `## Unowned Code` or `## Dependency Resolution Order`, that content is copied through verbatim to the regenerated file. Producer-side regeneration MUST NOT clobber human-maintained content in those two sections.
- **Trailing-blank-line discipline.** Sections preserved from the existing REGISTER.md have trailing blank lines stripped before re-emission (`generate-register.sh:248-249` and `:267-268` — both sites in the `# ── Preserve sections from existing REGISTER.md ──` block, grep for `# Strip trailing blank lines so each regeneration doesn't accumulate them`). This is the byte-level mechanism backing the idempotency invariant.
- **Empty-owns tolerance.** A spec with `owns: []` or no `owns:` block at all does not crash `generate-register.sh`. The Owns column for such specs is `—`. (Per the `${arr[@]+"${arr[@]}"}` idiom at `generate-register.sh:124` and PR #191's fix.)
- **No write on dry-run.** `--dry-run` MUST NOT modify `docs/REGISTER.md` on disk.

## Test surface

- **RP-1: Output-schema-stability.** REGISTER.md produced by `generate-register.sh` against a fixture project contains the five required top-level sections in fixed order (`## Definitions Index`, `## Spec Index`, `## Status Summary`, `## Unowned Code`, `## Dependency Resolution Order`).
- **RP-2: Spec-Index-column-shape.** The `## Spec Index` table header is exactly `| Spec | Status | Owner | Owns (files/directories) |` with the separator `|------|--------|-------|--------------------------|`. (Catches the #124 schema-drift class.)
- **RP-3: Idempotency.** Running `generate-register.sh` twice against the same fixture project produces byte-identical `docs/REGISTER.md`. (Closes #259.)
- **RP-4: Vocabulary-agnostic-status-summary.** When a fixture contains specs at non-canonical statuses (e.g. `ready`, `in-progress`, `implemented`), every one of those status labels appears as a row in the `## Status Summary` table — none are silently dropped. Canonical states (`draft`, `active`, `stale`) appear first in that lifecycle order; non-canonical states appear alphabetically after. (Closes #128.)
- **RP-5: Section-content-preservation.** When the fixture has a pre-existing `docs/REGISTER.md` with content under `## Unowned Code` and `## Dependency Resolution Order`, regeneration preserves that content byte-for-byte.
- **RP-6: Empty-owns-tolerance.** A spec with `owns: []` (or no `owns:` block) does not cause `generate-register.sh` to exit non-zero; that spec's row in the Spec Index has `—` in the Owns column; and other specs in the same fixture continue to appear correctly in the Spec Index. (The literal failure mode of #191 was the whole script crashing on the first empty-owns spec, dropping all subsequent specs.)
- **RP-7: Dry-run-no-write.** `bash scripts/generate-register.sh --dry-run` prints the generated content to stdout AND leaves any pre-existing `docs/REGISTER.md` byte-identical to its pre-run state.

## Versioning

- **1.0** (2026-05-26) — initial contract. Producer + consumer shapes as of `scripts/generate-register.sh` post-#191/post-#124/post-#259-fix/post-#128-fix on `main`. Closes #259 (idempotency) and #128 (vocabulary-agnostic status summary) as "non-recurrable by construction" — the contract test asserts both invariants; CI now fails on any future regression.
