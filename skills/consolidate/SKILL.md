---
name: consolidate
owner: consolidate-spec
description: Reconcile a branch's code with its governance documentation across four levels — architecture, governed specs, file headers + top-of-file comments, and (opt-in) function/inline comments. Regenerates AUTO sections, preserves HUMAN sections (stale-flagging broken refs), appends harvested decisions from design specs and plans.
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
argument-hint: "[path/to/design-spec.md] [--audit-comments]"
layer: 0
---

# Consolidate

Reconcile the branch with its governance documentation. Reconciliation covers four levels:

| Level | Surfaces | Treatment |
|---|---|---|
| 1. Architecture | `docs/ARCHITECTURE.md`, `PRINCIPLES.md` | Diff-driven impact prompt; user authors edits by hand. |
| 2. Governed specs | `docs/specs/*.spec.md`, `docs/REGISTER.md`, `contracts.yaml` | Full reconciliation — AUTO regen, HUMAN preserve, APPEND-AUTO decisions. |
| 3. File headers + top-of-file comments | `# owner:` lines and the comment block following them | `# owner:` rewrites are mechanical; comment-block freshness uses the level-2 stale-reference scanner. |
| 4. Function/inline comments | Comments touching changed lines in the diff | **Opt-in** via `--audit-comments`. Default proposed action per flag is *delete*, not *rewrite*. |

For each governed spec touched by this branch (level 2):

- **AUTO sections** (frontmatter, status, Tests, Implementation Notes → Design record) regenerate silently from current code, tests, and citation files.
- **HUMAN sections** (Purpose, Behaviour, free-text Implementation Notes) are preserved. Stale detection scans for file-path-token references that no longer exist on disk; any matches are surfaced to the user for review. (Function-name and test-case detection are deferred — see issue #108.)
- **APPEND-AUTO sections** (Decisions) accumulate new rows harvested from design specs (`docs/superpowers/specs/*-design.md`) and plans (`docs/plans/*.md`) referenced by this spec. Existing rows are never modified or removed. The Source column is the idempotency key.

When all reconciliation succeeds, the spec's status flips automatically: `draft → active` (first reconciliation) or `stale → active` (after drift). Design specs and plans are **retained as permanent historical records** — never deleted by this skill.

## Procedure

### Step 0: Read the pipeline.workflow flag

Before any reconciliation work, validate the active named pipeline:

```bash
PIPELINE=$(bash scripts/read-pipeline-flag.sh)
```

The reader must succeed before reconciliation. The current general-release
pipeline uses the unified reconciliation details below: new governed specs are
born from built state, behaviour supersession is surfaced explicitly, and
`coverage-baseline` refactor design specs get AUTO-only reconciliation.

### Step 1: Detect base branch and gather changes

1. Determine the base branch:

   ```bash
   git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main"
   ```

2. Find the merge base:

   ```bash
   git merge-base <base-branch> HEAD
   ```

3. List all changed files on this branch:

   ```bash
   git diff --name-only <merge-base>...HEAD
   ```

4. If no changed files are found, exit early: "No changes to consolidate on this branch."

5. Categorise each changed file:

   | Category | Glob patterns | Reconciliation scope |
   |----------|--------------|----------------------|
   | Source | `src/**`, `scripts/**`, `.claude/skills/**/SKILL.md`, `skills/**/SKILL.md`, `.claude/hooks/**`, `tests/**` | Owns levels 3 and 4 |
   | Architecture-level | `docs/ARCHITECTURE.md`, `PRINCIPLES.md` | Level 1 |
   | Governance outputs | `docs/specs/**`, `docs/REGISTER.md`, `docs/definitions/**`, `contracts.yaml` | Level 2 (outputs of this process) |
   | Ephemeral | `docs/plans/**`, `docs/superpowers/**` | Harvest sources for level 2 Decisions; never deleted |
   | Config/meta | `CLAUDE.md`, `.gitignore`, `settings.json`, `*.yaml` (non-contracts) | Out of scope (`CLAUDE.md` hygiene is owned by `claude-md-improver`) |

   Files not matching any pattern default to **Source** (own levels 3 and 4).

6. Present a summary to the user.

### Step 2: Identify design specs and plans for harvest

1. Parse `$ARGUMENTS`:
   - If `--audit-comments` is present as a token, strip it as a flag and enable level-4 auditing in step 5i.
   - The remaining non-flag token, if any, is treated as the design-spec path for harvest.
   - If multiple non-flag tokens are provided, error: "Expected at most one path argument — got: `<tokens>`."

2. Otherwise, scan `docs/superpowers/specs/*.md` for design specs and `docs/plans/*.md` for plans. Both are harvest sources for the Decisions table.

3. If governed specs being updated already cite design specs / plans in their `### Design record` subsection, those are also harvest sources (decisions accumulate over a spec's lifetime).

4. Present the list of harvest sources to the user. They are **not deleted** after harvest — they are permanent records.

### Step 3: Check existing governance state

1. Verify required template:

   ```bash
   ls docs/templates/spec.md docs/templates/register.md 2>/dev/null
   ```

   If either is missing, error: "Required template missing: `docs/templates/<name>.md`. Cannot proceed." Stop.

   Before whole-file reading `docs/templates/spec.md` or an existing governed
   spec, try bounded document discovery and semantic retrieval:

   ```bash
   bash scripts/explore-doc.sh docs/templates/spec.md
   bash scripts/read-doc-sections.sh docs/templates/spec.md purpose boundaries behaviour requires provides
   ```

   If discovery or semantic retrieval is absent or invalid, fall back to the
   current explicit section or whole-template read. Template files remain
   required; shape metadata is a progressive-disclosure aid, not a hard
   precondition.

2. Check `docs/REGISTER.md`:
   - If yes: read it. Build a map of file → owning spec from the "Spec Index" table's "Owns" column.
   - If no: bootstrap from `docs/templates/register.md`.

3. Check `docs/specs/`:
   - If yes: read existing governed specs to understand current coverage.
   - If no: create it.

4. Cross-reference source files from Step 1 against the register map:
   - **Owned + changed** — file has a spec owner; the spec needs reconciliation. Read the owning spec.
   - **Unowned** — file has no spec owner; needs assignment to a new or existing spec.

### Step 4: Propose reconciliation plan

Present a structured reconciliation plan to the user, organised by level:

```
## Reconciliation Plan

### Bootstrapping required
- [ ] Create `docs/REGISTER.md` from template (only if absent)
- [ ] Create `docs/specs/` directory (only if absent)

### Level 1 — Architecture
<!-- Only show if any diff signals triggered the heuristic; otherwise note "No level-1 candidates flagged." -->
- `docs/ARCHITECTURE.md` — candidate edit
  - Triggered by: <e.g., new top-level skill `<name>` introduces a new entry in skill family table>
  - Lines potentially affected: <range>
  - Action: user authors edit by hand (skill does not auto-edit architecture prose)

### Level 2 — Governed specs

#### New governed specs to create
- `docs/specs/<proposed-name>.spec.md`
  - Would own: <file1>, <file2>, ...
  - Status on creation: `active` when code already exists for the listed owns; if no owned files exist yet, flag the create as premature and defer it until the build lands
  - Content source: harvest from `<design-spec-path>` (if provided) or code analysis only

#### Governed specs to reconcile (already exist; touched by this branch)
- `docs/specs/<existing-name>.spec.md` — owns `<changed-file>`
  - AUTO regenerate: frontmatter, Tests, Design record
  - HUMAN scan: Purpose, Behaviour, free-text Implementation Notes
  - Decisions to append: <count> new rows from design specs / plans

#### Design specs and plans to harvest decisions from
- `docs/superpowers/specs/<file>.md` (retained, not deleted)
- `docs/plans/<file>.md` (retained, not deleted)

### Level 3 — File headers + top-of-file comments

#### `# owner:` header rewrites (grouping reconciliation)
<!-- Only show if final grouping differs from headers committed in source files. -->
- `<source-file>`: `# owner: <old-name>` → `# owner: <new-name>`

#### Top-of-file comment stale-flags
<!-- Only show if the stale-reference scanner flagged any comment block. -->
- `<source-file>` § top-of-file comment: stale references `<missing-refs>`
  - Action: prompt user (review now / skip / leave flagged)

### Level 4 — Function/inline comments
<!-- Only show if `--audit-comments` was passed; otherwise note "Skipped (use --audit-comments to enable)." -->
- `<source-file>:<line>` — comment: "<text>"
  - Heuristic: <removed-identifier | behaviour-changed | contradicts-surrounding-code>
  - Default action: **delete** (per project rule "default to writing no comments"). User may override.

### Files not requiring reconciliation
- <config/meta/ephemeral files>
```

When grouping files, follow `workflows/README.md ## Spec sizing`. Test files belong with the source files they test.

Wait for user approval before proceeding.

### Step 5: Execute on approval

#### 5a. Bootstrap (if needed)

If `docs/specs/` does not exist, create it. If `docs/REGISTER.md` does not exist, create it from `docs/templates/register.md`.

#### 5b. Create new governed specs

For each new spec in the approved plan:

1. Read `docs/templates/spec.md` for the structure.

2. Determine status:
   - Status on creation is `active` when owned files already exist on disk.
   - If no owned files exist yet, flag the create as premature and defer it until the build lands. If the user declines to defer, stop this consolidation pass; do not write a governed spec for an unbuilt surface.

3. Populate sections:
   - **Purpose** — if a design spec is provided, harvest from its problem statement. Otherwise stub: `<!-- HUMAN — Why does this exist? -->`
   - **Behaviour** — if a design spec is provided, harvest from its deliverable spec / procedure. Otherwise stub: `<!-- HUMAN — What should the system do? -->` Per the collaborative authoring model, do NOT generate Behaviour from code in code-analysis-only mode.
   - **Tests** (AUTO) — list each test file under owns by name with tier; declare "N/A — [reason]" for inapplicable tiers.
   - **Implementation Notes → Design record** (AUTO) — citation list of design specs and plans referenced by this spec.
   - **Decisions** (APPEND-AUTO) — initial row(s) harvested from referenced design specs / plans (see Decision harvest below).

4. Present the drafted spec to the user. Wait for approval before writing.

5. Write the spec to `docs/specs/<name>.spec.md`.

#### 5c. Reconcile existing governed specs (regeneration)

For each existing spec touched by this branch:

1. Read the current spec.

2. **Regenerate AUTO sections** silently:
   - Frontmatter (name, owner, owns) — recompute from REGISTER and current code.
   - Status — see Step 5e (auto-flip rules below).
   - Tests — re-derive from current test files.
   - Implementation Notes → Design record — rebuild citation list from referenced design specs and plans.

3. **Scan HUMAN sections** (Purpose, Behaviour, free-text Implementation Notes) for stale references. See "Stale reference detection" below. For each section that has stale flags, prompt the user.

4. **Harvest decisions** from referenced design specs and plans into the Decisions table. See "Decision harvest" below.

5. Present diff of all changes to the user. Wait for approval before writing.

#### 5d. Update REGISTER.md

1. Add/update entries for each new or reconciled spec in the "Spec Index" table.
2. Update the "Definitions Index" if new specs reference definitions.
3. Update the "Dependency Resolution Order" if dependencies changed.

#### 5e. Auto-flip status

Per the simplified state machine (`draft / active / stale`):

- A spec at `draft` whose reconciliation succeeded with code present → flip to `active`.
- A spec at `stale` whose reconciliation resolved the drift → flip to `active`.
- A spec at `active` with no detected drift → leave at `active` (no-op).
- A spec at `draft` with no code yet → leave at `draft` (no-op).

No prompts. The flip happens automatically as part of writing the reconciled spec.

#### 5f. Update contracts.yaml

If `contracts.yaml` exists and new specs reference shared definitions, add version pins. Otherwise skip.

#### 5g. Level 3 — File headers + top-of-file comments

For each changed source file:

1. **`# owner:` header rewriting**: if the approved reconciliation plan included header rewrites (because final grouping differs from what files committed to):
   - Edit the first comment line in place (`# owner: <new-name>`).
   - Update the corresponding `Owns` cell in REGISTER.md (already done in 5d, but verify).

2. **Top-of-file comment audit**: run the stale-reference scanner (see "Stale reference detection" below) over the comment block immediately after `# owner:`. For each flagged comment block:
   - Print: "Stale references in `<source-file>` § top-of-file comment: `<missing-refs>`"
   - Prompt: "Review the section now? (y / n / skip)"
   - On `y`: present the comment for inline edit.
   - On `n` / `skip`: leave unchanged but record the flag for the consolidation summary.

#### 5h. Level 1 — Architecture impact prompt

For each changed source file in this branch, apply diff-driven heuristics to detect candidates whose changes may have altered system shape. Heuristics include:

- New top-level skill (new directory under `skills/`).
- New external dependency (additions to package manifests, new imports of third-party libraries).
- New public surface (new exported function in a level-2 spec's Provides table).
- Edits to files cited by `docs/ARCHITECTURE.md` or `PRINCIPLES.md`.

For each triggered heuristic:

- Print: "Possible architecture impact: `<source-file>` (`<heuristic>`). Affected target: `<docs/ARCHITECTURE.md | PRINCIPLES.md>`"
- Prompt: "Review the target now? (y / n / skip)"
- On `y`: open the target file and surface the relevant section for the user to edit. The skill does not auto-edit architecture-level prose.
- On `n` / `skip`: leave unchanged but record the flag for the consolidation summary.

If `docs/ARCHITECTURE.md` or `PRINCIPLES.md` is absent: skip silently — never auto-create.

#### 5i. Level 4 — Function/inline comment audit (opt-in)

Skip this substep unless the user passed `--audit-comments` as an argument to `/consolidate`.

When enabled, scan the diff for comments touching changed lines:

```bash
git diff <merge-base>...HEAD -- <source-file>
```

Apply heuristics to flag likely-stale comments:

- Comments referencing removed identifiers (function/variable names in the comment that no longer exist in the file).
- Comments describing behaviour that changed (compare adjacent code lines pre- and post-diff).
- Comments contradicting surrounding code (e.g., comment says "returns null on error" but adjacent code now throws).

For each flag:

- Print: "Possibly stale comment in `<source-file>:<line>`: `<comment-text>` — heuristic: `<which-one>`"
- Default proposed action: **delete**, per the project rule "default to writing no comments." User may override per item.
- Prompt: "Apply default (delete)? (y / edit / skip)"
- On `y`: delete the comment.
- On `edit`: present the comment for inline edit.
- On `skip`: leave unchanged but record the flag for the consolidation summary.

This substep never adds new comments. The bias is toward removing stale ones.

### Step 6: Verify

1. Run `scripts/health-check.sh --reconcile`.
2. Present results.
3. Summarise what was done:

   ```
   ## Consolidation Complete

   ### Level 1 — Architecture
   - <ARCHITECTURE.md / PRINCIPLES.md edits applied or flagged for review, or "no candidates flagged">

   ### Level 2 — Governed specs

   #### Created
   - <new spec files>
   - <REGISTER.md if bootstrapped>

   #### Reconciled
   - <spec> — AUTO regenerated; HUMAN unchanged; <N> decisions appended; status: <new>
   - <spec> — AUTO regenerated; <N> HUMAN sections stale-flagged; status: <new>

   #### Retained (no deletion)
   - <design specs and plans referenced>

   ### Level 3 — File headers + top-of-file comments
   - `# owner:` rewrites: <files, or "none">
   - Top-of-file comment edits: <files, or "none">

   ### Level 4 — Function/inline comments
   - <comment edits applied, only if --audit-comments was passed; else "skipped (use --audit-comments to enable)">

   ### Health Check
   <pass/fail summary>
   ```

## Unified-workflow reconciliation details

The four-level reconciliation model is unchanged, but the **Behaviour-section
authoring rules** (D3) and the **refactor design-spec handling** (D5) refine
Step 5b ("Create new governed specs") and Step 5c ("Reconcile existing
governed specs").

### 1. New-spec status — always `active`

When `/consolidate` creates a governed spec for a built surface, the spec is
created from built state. Step 5b's status determination uses a single rule:

- **New spec:** status is always `active` when owned files exist.

A spec that *should* still be at `draft` (no code yet) is being created
prematurely — flag the case and defer the create until the build lands. If the
user declines to defer, stop the consolidation pass; do not write a governed
spec for an unbuilt surface.

If `/design` already created approved durable intent/seam prose for the topic,
preserve that human authority and reconcile generated/evidence sections into
the existing spec instead of treating the pre-build prose as drift to overwrite.

### 2. D3 hybrid behaviour-supersession detection

When reconciling an existing governed spec (Step 5c), the design spec
referenced by this consolidation may have changed the spec's intended
behaviour. `/consolidate` must surface that, not silently overwrite Behaviour.
Use this hybrid procedure:

1. **Heuristic flag (auto):** mark the governed spec as a supersession candidate when **all four** hold:
   - **Scope-narrowed harvest set:** the design specs being evaluated for this governed spec are restricted to the union of (a) any design spec passed explicitly as `$ARGUMENTS`, (b) design specs already cited in this governed spec's existing `### Design record` subsection (per Step 2 item 3), and (c) design specs **added, modified, or renamed on the current branch** (detected via `git diff --diff-filter=AMR <merge-base>...HEAD --name-only | grep '^docs/superpowers/specs/.*\.md$'` — the `--diff-filter=AMR` is required: a bare `--name-only` also returns deleted paths, which the heuristic would then try to read behaviour-shaped content from, causing false prompts or read failures; including `R` keeps renamed-with-edit specs in scope since they are part of the current consolidation changes). Set (c) is critical: `/finish` auto-invokes `/consolidate` without an explicit `$ARGUMENTS` argument, and a brand-new design spec for the current branch is not yet cited in the governed spec's Design record (the citation gets added during *this* consolidation pass) — without (c), exactly the design spec that motivated this consolidation would fall out of scope. Step 2's default "scan all `docs/superpowers/specs/*.md`" pool is **not** used for the supersession heuristic — that pool exists for the unrelated APPEND-AUTO Decisions harvest. This 3-source union stops historical design specs unrelated to the current consolidation from flagging false-positive supersessions while still catching the live design spec on this branch.
   - That scope-narrowed set contains at least one design spec with Behaviour-shaped content (a `## Behaviour`, `## Deliverable spec`, or `## Procedure` heading with body text; or, for design specs written against the unified template, an `## Intended behaviour` section).
   - The governed spec already has a non-stub Behaviour section (not just `<!-- HUMAN — What should the system do? -->`).
   - The governed spec's Decisions table contains **no existing row** with `Source = "<design-spec-path>@<git-blob-sha> (no-change classification, unified)"` where `<git-blob-sha>` matches the design spec's **current** blob SHA (`git ls-tree HEAD -- <design-spec-path>` → blob hash). A prior consolidation that classified the design spec as a no-change restatement persists that decision keyed by content hash; the heuristic skips re-prompting only when the stored hash still matches current content. If the design spec has since been modified, its blob SHA differs from any stored marker → the no-change classification is **automatically invalidated** and the heuristic re-prompts. This stops a stale marker from suppressing supersession detection when a previously-no-change design spec later gains real behaviour changes.

2. **Human confirm (interactive):** present the existing governed Behaviour and the design spec's behaviour-shaped content side by side, then prompt:

   > "Does this design spec change the governed Behaviour of `<spec-name>`?"
   > - **yes — behaviour changed** → flag the governed Behaviour as superseded and surface both texts for the human to author the updated Behaviour (described next).
   > - **no — design spec restates existing behaviour, no change** → leave Behaviour unchanged; reconcile AUTO sections only.
   > - **no — this is a refactor design spec** → defer to the D5 refactor handling below.

3. **On "yes":** prepend the existing Behaviour section with an HTML comment marker `<!-- SUPERSEDED by docs/superpowers/specs/<design-spec>.md — author updated Behaviour below -->` and append the design-spec's behaviour text under a `<!-- NEW BEHAVIOUR from design spec — author the consolidated text -->` marker. The human authors the consolidated Behaviour during this pass; `/consolidate` does **not** auto-merge.

4. **On "no — restatement":** persist the classification by appending a row to the governed spec's APPEND-AUTO Decisions table with `Source = "<design-spec-path>@<git-blob-sha> (no-change classification, unified)"`, where `<git-blob-sha>` is the design spec's blob hash **exactly as returned by `git ls-tree HEAD -- <design-spec-path>` field 3** — store it verbatim, full length, with no abbreviation. The hash width is whatever `git ls-tree` emits for the repository's object format (40 hex for SHA-1, 64 hex for SHA-256); do not hard-code a length, but also do not truncate. Condition 4 compares against the full SHA returned by the same `git ls-tree` command; mixing abbreviated and full hashes across runs would cause spurious re-prompts and duplicate no-change rows because string-equality on `<short>` vs `<full>` fails. The Source-column dedup the Decisions table already guarantees ("Decision harvest from design specs and plans" § Idempotency) is what makes the next consolidation skip the re-prompt: the heuristic (Condition 4 above) checks for an existing Source row whose full hash matches the design spec's *current* full blob SHA. This reuses the existing durable artifact rather than inventing a new persistence file, and the content-hash key ensures the marker auto-invalidates whenever the design spec content actually changes.

This preserves the invariant that Behaviour is human-authored. The governed
Behaviour stays human-authored, but it is kept current by a prompted human edit
on every behaviour change, never by an automated rewrite.

### 3. D5 refactor-spec handling — AUTO-only reconciliation

A `coverage-baseline` refactor design spec preserves behaviour by definition
(D5, D6). When the user selects "no — this is a refactor design spec", treat
the design spec as **structure-only**:

1. **Skip Behaviour reconciliation entirely.** Do not prompt for the supersession edit. The governed Behaviour section is correct as-is (behaviour did not change).
2. **Regenerate the AUTO sections only:** frontmatter (Owns may shift if files moved or split), Tests (characterization-test rows update), Implementation Notes → Design record (the refactor design spec is added to the citation list).
3. **APPEND-AUTO Decisions** still accrues new rows harvested from the refactor design spec — D5 specs document the target structure and characterization-test baseline; those decisions are worth preserving.

If a refactor design spec inadvertently asks for a Behaviour edit, that signals the work is no longer behaviour-preserving and should reclassify as everything-else with a `brainstorm` or `investigate` Branch 1 (per D6's reclassification rule). Surface this and ask the user to either reclassify or correct the design spec.

### 4. Step 5b new-spec status

In Step 5b, when determining the new spec's status, the rule is:

| Condition | Status |
|---|---|
| Owned files exist on disk (the built-state precondition) | `active` |
| No owned files on disk yet | flag as "premature create"; defer until the build lands; if the user declines to defer, stop without writing the spec |

The pre-build `draft` create path is retired.

### 5. Step 5c reconciliation additions

In Step 5c, the base procedure (AUTO regen + HUMAN stale-scan + decision
harvest) runs as written, with one addition between substeps 3 ("Scan HUMAN
sections") and 4 ("Harvest decisions"):

- **Substep 3.5:** run the D3 hybrid supersession detection above. If flagged
  and confirmed "yes — behaviour changed", insert the supersession markers into
  the Behaviour section. If confirmed "refactor", skip Behaviour entirely (per
  the D5 handling above) and proceed to substep 4 (harvest).

## Regeneration model

Governed specs (level 2) are regenerated on each pass to reflect current code, while preserving human-authored content and accumulating decision history. The same AUTO/HUMAN/APPEND-AUTO vocabulary now extends to surfaces beyond the governed spec: `# owner:` lines (level 3) are AUTO; top-of-file source comments and `ARCHITECTURE.md` / `PRINCIPLES.md` prose are HUMAN.

Sections are classified by authorship:

- **AUTO** — frontmatter, status, Tests, Implementation Notes → Design record subsection (level 2); `# owner:` lines (level 3). Regenerated silently from current code/tests/citations on every pass.
- **HUMAN** — Purpose, Behaviour, free-text Implementation Notes (level 2); top-of-file source comments (level 3); `docs/ARCHITECTURE.md` / `PRINCIPLES.md` prose (level 1). Never overwritten by the skill. Scanned for stale references where applicable; flagged matches prompt the user.
- **APPEND-AUTO** — Decisions (level 2 only). New rows harvested from design specs and plans referenced by this spec. Existing rows are never modified or removed. The Source column is the idempotency key — `/consolidate` does not re-add a decision whose source artifact + decision ID is already cited.

## Stale reference detection

The same scanner applies to any text region classified as HUMAN that may cite file paths: governed-spec HUMAN sections (level 2) and top-of-file source comments (level 3).

For each region being scanned:

1. Extract candidate references via regex:
   - Backtick-wrapped paths: `` `docs/foo.md` `` matches `docs/foo.md`.
   - Naked path tokens matching `(\.?\w[\w./-]*\.\w+)`.
2. For each candidate, check `[ -e "$candidate" ]` (file exists).
3. If any references are missing, the region is "stale-flagged":
   - Print: "Stale references in `<file>` § `<region-name>`: `<missing-refs>`"
   - Prompt: "Review the region now? (y / n / skip)"
   - On `y`: present the region for inline edit.
   - On `n` / `skip`: leave unchanged but record the flag for the consolidation summary.

Function-name and test-case stale detection is deferred (see issue tracker for
the richer guided-reconciliation flow). Level-4 comment heuristics are
documented in 5i.

## Decision harvest from design specs and plans

For each design spec or plan referenced in the spec's `### Design record` subsection:

1. Read the file.
2. Extract decision-shaped content: tables with "Decision" / "Alternatives" columns, or numbered "Decision summary" lists.
3. For each decision found, check whether a matching row already exists in the spec's Decisions table — match by `Source artifact path + decision ID`.
4. If no match, append a new row with `Source = "<artifact-path> (decision <ID>)"`.

Idempotency: re-running `/consolidate` with no new design specs / plans produces zero new rows.

## Important Notes

- **Never auto-commit.** All changes to governed documents require user approval before writing to disk. Present drafts and proposed edits, then wait for confirmation.
- **Design specs and plans are permanent records.** Never delete them. They are cited from the governed spec's Design record subsection and harvested for decisions.
- **Respect collaborative authoring.** When harvesting from design specs, transplant human-authored content. When no design spec exists, stub Behaviour for the human to write — do not generate it from code. Level-1 architecture prose is never auto-edited by this skill; the skill surfaces candidates and the user authors edits.
- **Level 4 is opt-in and delete-biased.** `--audit-comments` enables function/inline comment auditing. The default proposed action per flag is *delete*, never *write*, per the project rule "default to writing no comments." This substep never adds new comments.
- **Status auto-flips.** No "promote to active" prompts. `draft → active` (or `stale → active`) happens automatically when reconciliation succeeds. The human's commitment moment is the act of running `/consolidate`.
- **Idempotency.** Running this skill twice with no intervening code or harvest changes produces no diff. AUTO sections regenerate to the same content; HUMAN sections are unchanged; the Decisions table is unchanged because the Source column dedups already-cited decisions.

$ARGUMENTS
