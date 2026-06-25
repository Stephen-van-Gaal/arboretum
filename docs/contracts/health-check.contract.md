---
seam: health-check
version: 1.5
producer-type: script
consumer-type: script
consumes:
  - register-md-schema
  - spec-status-state-machine
  - module-contract-template-file
produces:
  - health-check-output-schema
  - governs-narrative-field-discipline
related-designs:
  - docs/superpowers/specs/2026-05-27-pipeline-overhaul-ws5-pr3-health-check-design.md
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/health-check.sh
---
<!-- owner: pipeline-contracts-template -->

# health-check — `health-check.sh` Drift-Finding Producer Contract

The seam between `scripts/health-check.sh` (the project's drift-finding producer — runs nine checks across governed documents, spec status consistency, owned-file presence, contract version pins, plan freshness, and the Strategic Anchor) and its sole downstream consumer `scripts/ci-checks.sh` (which invokes `bash scripts/health-check.sh "$ROOT"` as one block of the CI suite). One folded-in bug closes as non-recurrable: **#176** — `component-architecture-diagram.spec.md` had `status: active` + `owns: []` (a state Check 6 was implicitly tolerating); the new `governs-narrative:` field discipline encoded in HC-4 makes the conjunction a write-time contradiction (escape via explicit declaration) the smoke test pins in CI.

## Producer

`scripts/health-check.sh` — producer-type: `script`.

Runs nine numbered checks against a project directory (defaults to `pwd`, overridable via positional arg). Each check emits a `━━━ Check N: <name> ━━━` header followed by zero or more finding lines prefixed by `✓` (ok), `·` (info), `✗` (blocking warn), or `⚠` (advisory). The script's exit code is three-level (S2 #641): `0` when no finding was emitted, `1` when any blocking check (1/2/3/4/6) emitted a `✗` line, `2` when only advisory checks (5/7/8/9) emitted `⚠` lines (blocking wins on precedence). All path resolution uses `PROJECT_DIR` (the arg or default) — never `$(pwd)` directly, never `git rev-parse --show-toplevel` — so the script is safe to invoke against a remote project tree from any working directory.

Check 7 is read-only by default; passing `--reconcile` is the only thing that mutates files (status flips from active → stale in spec frontmatter and REGISTER.md). All other checks are always read-only. Check 9 (Strategic Anchor) emits a single info line `· Skipped — roadmap.config.yaml not present` when `roadmap.config.yaml` is absent (from the wrapper at `scripts/health-check.sh:1190`), and no `✗` warn lines — so projects that haven't adopted the roadmap system see only the skipped-info line, not failures.

Check 6 (Spec status consistency) reads `status` and `owns` columns from REGISTER.md's `## Spec Index` table, then for the `status=active + owns=—` corner case opens the spec file directly to read its frontmatter `governs-narrative:` field. The branching encoded in HC-4 below is the post-#176 invariant.

## Consumer

One downstream consumer, consumer-type: `script`:

- **`scripts/ci-checks.sh`** (script). Invokes `bash scripts/health-check.sh "$ROOT"` as one block of the CI suite, currently non-blocking (`|| echo "(health-check reported issues — non-blocking)"`). The non-blocking discipline is deliberate — drift findings other than the contract-tested invariants should surface as advisory signal, not red-bar CI. The blocking enforcement comes from the contract test (`scripts/_smoke-test-contract-health-check.sh`), which runs inside `ci-checks.sh`'s blocking smoke-test loop and asserts the HC-* invariants against a fixture.

The consumer depends on the output-format stability (HC-1) and exit-code semantics (HC-2) of `health-check.sh`. Schema drift in the producer's output is the failure mode this contract pins against.

(Note: `scripts/validate-cross-refs.sh` is NOT a consumer of this seam. An earlier draft listed it, but verification confirmed it reads `docs/REGISTER.md` and spec files directly, not health-check.sh output. It's a sibling reader of REGISTER.md, governed by the register-pipeline contract — not by this contract.)

## Protocol shape

### Inputs

`scripts/health-check.sh` accepts these optional CLI arguments (flags are order-independent and precede the positional `project-dir`):

- **`--reconcile`** — flag, optional. When present, Check 7 mutates spec frontmatter and REGISTER.md (flips `active → stale` for drifted specs). **Branch-scoped by default (#750):** a spec flips only if one of its *drifted* owned files is in the current branch's changed set — `git diff --name-only <merge-base>...HEAD` against the integration base resolved by `workspace_base_ref`. Drifted specs whose drift is outside that scope are surfaced as a single advisory roll-up but not flipped. When no integration base resolves, or HEAD *is* the integration base (merge-base == HEAD), scoped `--reconcile` flips nothing and emits an advisory naming `--reconcile --all`. Without the flag, Check 7 is read-only — drift is reported but no files are touched.
- **`--all`** — flag, optional; meaningful only with `--reconcile`. Restores the repo-wide sweep: every drifted `active` spec is flipped regardless of branch scope (the pre-#750 behaviour, now an explicit opt-in for deliberate maintenance). `--all` without `--reconcile` is reported as a no-op modifier, not an error.
- **`[project-dir]`** — positional, defaults to `pwd`. Sets the root under which `docs/specs/`, `docs/REGISTER.md`, `contracts.yaml`, `docs/definitions/`, `.arboretum.yml`, and `roadmap.config.yaml` are resolved.

Reads (under the project-dir root):

- `docs/REGISTER.md` — Spec Index table is the primary data source for Checks 2/3/6/7.
- `docs/specs/*.spec.md` files — Check 6 opens individual spec files directly to read `governs-narrative:` for the active+empty-owns corner case; Check 7 reads `status:` for the auto-flip.
- `contracts.yaml` — Checks 4/5 consume version pins.
- `docs/definitions/*.md` — Check 5 consumes definition versions.
- `.arboretum.yml` (optional) — overrides for `status_enum:` (Check 6) and `source_paths:` (Check 3 Half B).
- `.arboretum/install-manifest.json` (optional) — Check 3 Half A uses the committed framework install manifest to distinguish vendored framework files from local scripts in consumer roots when an Arboretum-internal owner spec is not installed.
- `roadmap.config.yaml` (optional) — gates Check 9; absence silently skips the check.
- Plans under `docs/plans/` and `docs/superpowers/plans/` — Check 8 scans for missing Tests sections.

### Outputs

Writes to stdout (no file mutation by default; with `--reconcile`, Check 7 mutates spec frontmatter and REGISTER.md).

Output format: each check section starts with a header line `━━━ Check N: <name> ━━━` (where N is the check number, 1-9). Finding lines are prefixed by exactly one of:

- `  ✓ <message>` — ok (informational pass)
- `  · <message>` — info (non-failing observation, e.g. extended-enum acknowledgement, governs-narrative citation)
- `  ✗ <message>` — warn (blocking drift finding; contributes to exit 1)
- `  ⚠ <message>` — advise (advisory finding; contributes to exit 2)

Exit code (three-level, severity-tiered — S2 #641):

- `0` if no finding line was emitted by any check (clean run)
- `1` if any **blocking** check (1/2/3/4/6) emitted a `✗` line
- `2` if only **advisory** checks (5/7/8/9) emitted `⚠` lines and no blocking finding is present (blocking wins on precedence)

The `--reconcile` flag does NOT change exit-code semantics — Check 7's mutations don't suppress findings from other checks; they just clean up the active→stale drift in-place. Exit code still reflects the highest-severity finding emitted (any blocking `✗` → `1`, else any advisory `⚠` → `2`, else `0`), including by the now-mutated Check 7 (itself an advisory check).

### Invariants

- **Output-format stability.** Each check's section begins with the `━━━ Check N: <name> ━━━` header line. Consumers parse output by check-section boundaries; reordering or renaming check headers is a producer-side schema break.
- **Exit-code contract (three-level, severity-tiered — S2 #641).** Exit `0` when no finding was emitted; `1` when any blocking check (1/2/3/4/6) emitted a `✗` line; `2` when only advisory checks (5/7/8/9) emitted `⚠` lines (blocking precedence: any blocking finding yields `1`). `--reconcile` does not change this — Check 7 mutations and drift findings are independent dimensions. See the Severity classification invariant below and HC-2.
- **Status-enum invariant (Check 6).** Status MUST be in the configured enum (default `{draft, active, stale}` per the plugin's canonical vocabulary; configurable per-project via `.arboretum.yml status_enum:`). Unknown values: in configured projects, per-spec `warn`; in default projects, aggregate into a single post-loop `info` line (`Project uses extended status enum...`) to avoid per-spec warning floods.
- **Consumer-root framework owner applicability (Check 3 Half A).** In plugin roots, every owner marker on scanned shell/bin/SKILL surfaces must resolve to `docs/specs/<owner>.spec.md`. In consumer roots, a scanned file listed in `.arboretum/install-manifest.json` is framework-managed: if its owner marker is well-formed but the named Arboretum-internal spec is not installed locally, Check 3 emits an info line rather than a drift finding. This carve-out applies only to manifest-managed files; malformed markers and local non-managed files with missing owner specs remain `warn` findings.
- **Active-empty-owns discipline (Check 6, post-#176).** When a spec has `status: active` AND `owns` resolves to empty (empty list, `(none)`, or `—`): if the spec's frontmatter declares a non-empty `governs-narrative:` value, Check 6 emits `info` with the narrative cited (existing carve-out preserved); if `governs-narrative:` is unset or empty, Check 6 emits `warn` (contributes to exit 1) — the `active + owns:[] + no governs-narrative` conjunction is a write-time contradiction.
- **Severity classification (S2 #641).** Every check is **blocking** or **advisory**. Blocking = {1, 2, 3, 4, 6} (a present, committed inconsistency between artifacts) → `warn()` emits `✗` and contributes to exit `1`. Advisory = {5, 7, 8, 9} (heuristic / proxy / nudge) → `advise()` emits `⚠` and contributes to exit `2`. Severity is a first-class producer signal (the consumer reads the exit code rather than reconstructing severity from output text). This split is fixed by the contract; reclassifying a check is a contract change.
- **Check 7 read-only default.** Without `--reconcile`, Check 7 reports drift findings via `⚠` advisory lines (Check 7 is advisory per the severity classification above) but does NOT mutate any file. With `--reconcile`, Check 7 flips `active → stale` in BOTH the spec's frontmatter AND its REGISTER.md row (both surfaces must update atomically — the in-place sed editing is the implementation). The `--reconcile` flip does not change exit-code semantics: the advisory finding still yields exit `2`.
- **Check 7 reconcile scope (#750).** The set of specs `--reconcile` flips is bounded by branch scope, NOT the whole register. Default (`--reconcile` without `--all`): a drifted `active` spec flips only if at least one of its **drifted** owned files is in the current branch's changed-file set — `git diff --name-only <merge-base>...HEAD`, where the integration base is `workspace_base_ref` (probe order origin/HEAD → origin/main → origin/master → local). Scope is decided on the *drifted* file, not on any owned file: a spec whose only drift is on a file the branch never touched is NOT flipped, even if the branch changed a different (non-drifted) file the spec owns. Drifted-but-out-of-scope specs are reported as **one** advisory roll-up (a count, not a per-spec line — a branch over many latent-drifted specs is not spammed). **Degenerate scope** — no base resolves, or merge-base == HEAD (HEAD *is* the integration branch) — flips nothing; when drift was detected it emits a single advisory naming `--reconcile --all`, but when no drift exists the run stays clean and exits `0` (scope resolution must not, by itself, make a clean run advisory — HC-2). **`--all`** restores the unscoped repo-wide flip; `--all` without `--reconcile` is a reported no-op `info` line (exit-neutral), never an error. Scope resolution is read-only (no network fetch) and PROJECT_DIR-rooted: the base resolver runs inside a `( cd "$PROJECT_DIR" … )` subshell, which honours the PROJECT_DIR-isolation invariant (explicit project root, never silent caller-CWD) while reusing `workspace-context.sh`'s CWD-relative helpers. Scope changes which specs flip; it does not change exit-code semantics (the flip and the roll-up are advisory, exit `2`).
- **PROJECT_DIR isolation.** All path resolution inside the script derives from the `PROJECT_DIR` variable (positional arg or `pwd` default). The script MUST NOT call `git rev-parse --show-toplevel` to discover paths — that would resolve relative to the caller's CWD instead of `PROJECT_DIR`, breaking invocations against a remote project tree. Strategic Anchor (Check 9) and all other path-derived state must be `PROJECT_DIR`-rooted.
- **Check 9 roadmap-config gating.** `roadmap.config.yaml` absent → Check 9 emits exactly one info line `· Skipped — roadmap.config.yaml not present` (from the wrapper code at `scripts/health-check.sh:1190` when `strategic_anchor_check` returns empty) and no `✗` warn lines. Present → Check 9 runs normally (verifies `## Strategic Anchor` section in CLAUDE.md, in/out scope bullets exist, review-cadence date not overdue). The gate is on file presence, not content.

## Test surface

- **HC-1: Output-format-stability.** Each invoked check's section begins with the `━━━ Check N: <name> ━━━` header. The smoke test asserts the headers for at least Checks 1, 6, 7, and 9 are present in a clean fixture run.
- **HC-2: Exit-code contract (three-level, severity-tiered — S2 #641).** `bash scripts/health-check.sh <fixture>` exits `0` when the fixture has no findings; `1` when at least one **blocking** check (1, 2, 3, 4, 6) emits a `✗` line; `2` when only **advisory** checks (5, 7, 8, 9) emit `⚠` lines and no blocking finding is present. **Blocking precedence:** any blocking finding yields exit `1` even when advisory findings are also present. Adding `--reconcile` does not change these semantics. The smoke test asserts all branches: no-finding (`0`), advisory-only (`2`), blocking (`1`), and blocking-wins precedence (`1`), with and without `--reconcile`.
- **HC-3: Status-enum-invariant.** A fixture spec at an unconfigured-extended-enum status (e.g. `ready`) triggers the post-loop info line `Project uses extended status enum (states observed: ...)` rather than per-spec warns. (The contract assertion covers the default-project extended-enum branch; the configured-project typo branch — `.arboretum.yml status_enum:` block present plus a typo-like status — is part of Check 6's behaviour but is not pinned by HC-3 in this contract. If a future regression of the configured-enum parser matters enough to pin, add it as a separate HC-3b assertion in a follow-up PR.)
- **HC-4: Active-owns-discipline (closes #176).** Two fixture specs both at `status: active` + `owns: []`:
  - spec-with-narrative: declares `governs-narrative: <value>` → Check 6 emits `· <spec>: status=active but owns no files (governs narrative: <value>)` AND the script's exit code is unaffected.
  - spec-without-narrative: no `governs-narrative:` field → Check 6 emits `✗ <spec>: status=active but owns no files AND no governs-narrative declared — contradiction (...)` AND the script's exit code is 1.
  The smoke test asserts both output lines AND the exit-code transition between the two fixture sub-cases.
- **HC-5: Check-7-read-only-default + mutation mechanics.** Fixture: one spec at `status: active` whose owned file has a **non-benign (behaviour) change** committed after the spec's last commit (a comment/whitespace/frontmatter-only change is benign under Check 7's content-aware classifier and would not flag — see HC-9). Without `--reconcile`: Check 7 emits a `⚠` advisory drift finding (exit `2`); spec frontmatter and REGISTER.md row are byte-identical to pre-run. With **`--reconcile --all`**: same spec at `status: stale` in both the spec frontmatter and REGISTER.md row after the run, and the run still exits `2` (the advisory finding is independent of the mutation). HC-5 pins the *mutation mechanics* (atomic active→stale in both surfaces), which are scope-independent — the single-commit fixture has no feature branch (merge-base == HEAD), so `--all` is required to exercise the flip under the #750 default; branch-scoping itself is pinned by HC-10. Smoke test diffs pre-/post-run state and asserts the exit code for both flag-modes.
- **HC-6: PROJECT_DIR-isolation.** Run `cd $UNRELATED_DIR && bash $FIXTURE_DIR/scripts/health-check.sh $FIXTURE_DIR` (caller's CWD differs from PROJECT_DIR). The smoke test asserts: (a) no `$UNRELATED_DIR` path string appears anywhere in stdout; (b) `$FIXTURE_DIR` paths DO appear; (c) exit code matches a same-CWD baseline run. Pins against `git rev-parse --show-toplevel` regressions in any check function.
- **HC-7: Check-9-roadmap-gating.** Two fixture projects:
  - Main fixture: no `roadmap.config.yaml` → Check 9 emits the single info line `· Skipped — roadmap.config.yaml not present` (from the wrapper at `scripts/health-check.sh:1190`) and zero `✗` warn lines. Assertion: zero `✗` lines inside the Check 9 section.
  - Mini fixture (separate `mktemp -d`): has `roadmap.config.yaml` plus a CLAUDE.md with the required `## Strategic Anchor` section, plus all Check 1 prerequisites (workflows/README.md, docs/ARCHITECTURE.md, docs/REGISTER.md, contracts.yaml, docs/definitions/, docs/specs/) → Check 9 emits at least one `✓` line. Assertion: Check 9 `✓` line present AND script exits 0 (no other check triggers drift).
- **HC-8: Consumer-root framework owner applicability.** Fixture: `.arboretum/install-manifest.json` lists a framework script whose line-2 owner spec is intentionally absent from `docs/specs/`. Check 3 emits no `Unowned:` warning for that manifest-managed file and the clean fixture exits 0. A second local script with the same missing-owner-spec shape but absent from the manifest is still flagged as `Unowned:` and exits non-zero.
- **HC-9: Check-7-content-aware-benign-pass.** Fixture: one spec at `status: active` whose owned file has a change committed after the spec's last commit where that change is confined to a benign diff-class (comment-only / whitespace-only / frontmatter-only / net-empty). Check 7 emits **no** `✗` drift finding for that spec, and the spec's status is unchanged with and without `--reconcile`. The smoke test asserts the absence of the drift line and byte-identical spec/REGISTER state. Guards the #238 content-aware classifier against regressing to the commit-ordering proxy.
- **HC-10: Check-7-reconcile-branch-scope (#750).** Fixture: a local `main` with TWO `active` specs (A owns `src/a.py`, B owns `src/b.py`), both drifted by a post-spec behaviour-change commit on `main`; then a feature branch whose only further commit changes `src/a.py` (B is main-only drift the branch never touched).
  - **Default `--reconcile` on the feature branch:** spec A flips to `stale` (in-scope); spec B is byte-identical (`status: active` in both spec frontmatter and REGISTER.md row); an advisory roll-up names the out-of-scope drift (`… outside this branch's scope … run --reconcile --all`).
  - **`--reconcile --all` on the feature branch:** BOTH A and B flip to `stale`.
  - **Default `--reconcile` with HEAD on `main` (merge-base == HEAD):** nothing flips (A and B stay `active`) and an advisory names `--reconcile --all`.
  The smoke test diffs pre-/post-run spec + REGISTER state for each sub-case and asserts the advisory lines. Pins the branch-scope default against regressing to the unscoped repo-wide flip (the #750 footgun).
- **HC-11: source-languages-opt-in (#859).** With no `source_languages:` key, Check 3 Half B scans only `*.py` — an unowned `.ts` in a source root is not *block-flagged* `Unowned:` and does not yield exit `1` (a Half C advisory nudge about the undeclared `.ts` is expected and is exit `2`). With `source_languages: [py, ts]`, the same unowned `.ts` is flagged `Unowned:` and the run exits `1`. Pins the backward-compatible default and the opt-in enforcement glob.
- **HC-12: undeclared-source-type-discovery (advisory, #859).** A recognized code source type (`.sql`) present in a `source_paths` root but absent from both `source_languages:` and `source_languages_ignore:` yields a `⚠ … not declared in source_languages` line; this finding is advisory (does not by itself produce exit `1`). Listing the extension in `source_languages_ignore:` silences it. Pins Half C as a non-blocking nudge with an acknowledge path.

## Versioning

- **1.5** (2026-06-25) — Check 3 is language-aware (#859). Half B's scan set is driven by `source_languages:` (default `[py]`, backward-compatible); in-file `<prefix> owner:` markers (leading-block, any recognized language — `#`/`--`/`//`) count as ownership alongside `owns:` patterns, so a generated provenance banner satisfies ownership. New advisory **Half C** nudges (`advise()`, exit `2`, never blocking) for recognized code source types undeclared in `source_languages:`/`source_languages_ignore:`. Adds **HC-11** (opt-in + backward-compat) and **HC-12** (advisory discovery + ignore). Issue #859.
- **1.4** (2026-06-12) — `--reconcile` is **branch-scoped by default** (#750): it flips only specs whose owned files changed on the current branch (vs the `workspace_base_ref` integration base); out-of-scope drift is surfaced as one advisory roll-up, not flipped; degenerate scope (no base, or HEAD == base) flips nothing and advises `--all`. Adds the `--all` flag (order-independent) restoring the repo-wide sweep, the "Check 7 reconcile scope" invariant, and **HC-10** (branch-scope). **HC-5** now invokes `--reconcile --all` (its single-commit fixture has no feature branch, so the scope-independent mutation mechanics need the repo-wide opt-in). Closes the collateral-stale footgun where a shared `main`'s latent drift was written into an unrelated branch's diff. Issue #750 / lineage epic #640.
- **1.3** (2026-06-08) — Findings are severity-tiered (S2 #641). HC-2 becomes a three-level exit-code contract: `0` clean / `1` ≥1 blocking finding (`✗`; checks 1/2/3/4/6) / `2` advisory-only findings (`⚠`; checks 5/7/8/9), with blocking precedence (any blocking finding yields `1`). Adds a severity-classification property; the Check 7 read-only/`--reconcile` property and HC-5 now describe advisory (`⚠`, exit `2`) findings. The frontmatter `version:` is corrected to track the changelog head (was stale at `1.0`). Issue #641 / epic #640.
- **1.2** (2026-06-07) — Check 7 is now content-aware (#238): a drift candidate (owned file committed after its spec) only flags when the net change is non-benign. HC-5's fixture change becomes a behaviour change (a comment-only edit is now benign); adds HC-9 (benign diff-classes do not flag). Issue #238 / epic #640.
- **1.1** (2026-06-02) — Check 3 Half A now treats `.arboretum/install-manifest.json` as the consumer-root authority for vendored framework files whose Arboretum-internal owner specs are not installed locally. Adds HC-8. Issue #477.
- **1.0** (2026-05-27) — initial contract. Producer + consumer shapes as of `scripts/health-check.sh` post-Task-0b on `main`. Closes #176 (active+empty-owns + no governs-narrative is a contradiction) as "non-recurrable by construction" — HC-4 asserts both branches in CI; any future regression that loses the governs-narrative escape or fails to fail on the no-narrative case will red-bar the smoke test.
