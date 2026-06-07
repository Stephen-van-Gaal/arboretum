---
script: scripts/ci-checks.sh
version: 1.12
invokers:
  - type: skill
    name: /finish
  - type: script
    name: .github/workflows/ci.yml
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
  - docs/superpowers/specs/2026-06-02-adopter-ci-boundary-design.md
  - docs/superpowers/specs/2026-06-03-release-intent-lane-design.md
  - docs/superpowers/specs/2026-06-03-ci-checks-runtime-design.md
  - docs/superpowers/specs/2026-06-06-standard-ci-preflight-design.md
  - docs/superpowers/specs/2026-06-06-ci-checks-quiet-mode-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/ci-checks.sh`

## Surface

CI orchestrator and pre-PR local gate. Runs `scripts/ci-preflight.sh` first,
then, only if preflight passes, runs the expensive stages in sequence:
capability-gated ShellCheck linting, selected smoke-test loop, declared default
test command, cross-reference validation, optional contract-coverage
validation, and optional release gate. The expensive stages accumulate a `fail`
flag, then exit `$fail`. Preflight failure exits immediately before expensive
work. Invoked by `/finish` before opening a pull request and by
`.github/workflows/ci.yml` on every PR and push to main, ensuring the local gate
and CI cannot drift. Takes no arguments and exposes no `ROOT` override — the
repository root is recomputed unconditionally from the script's own location
(`BASH_SOURCE[0]`), so a caller-supplied `ROOT` is ignored and the checks always
run against the script's own tree. The orchestrator is layout-aware: Arboretum
plugin roots run the selected framework self-check set directly, while consumer
roots run the declared `default-command` when
`docs/specs/test-infrastructure.spec.md` and `scripts/read-test-config.sh` are
installed, skip framework-owned smoke tests whose owning specs are not
installed in the host project, and skip absent plugin-only coverage/release-gate
scripts.

## Protocol

### Arguments

No positional arguments and no flags. The script determines the repository root automatically:

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

The `REQUIRE_SHELLCHECK` environment variable controls the ShellCheck stage when the `shellcheck` binary is absent. Unset or any value other than `1` means the ShellCheck stage prints a `SKIP` diagnostic and remains non-blocking. `REQUIRE_SHELLCHECK=1` makes the missing binary a blocking failure.

The `ARBORETUM_CI_MODE` environment variable controls smoke-test selection:

- unset or `balanced` — default mode. Runs all applicable smoke tests except
  those explicitly marked `# ci-tier: full`.
- `full` — runs every applicable smoke test, including `# ci-tier: full`
  tests.
- `auto` — resolves to `full` when changed paths include CI/test executable
  surfaces (`scripts/ci-checks.sh`, `scripts/_smoke-test-*.sh`,
  `tests/contracts/**`, `.github/workflows/**`) or release-package surfaces
  (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`,
  `.codex-plugin/plugin.json`, `docs/releases/**`, `CHANGELOG.md`);
  otherwise resolves to `balanced`. If changed-path detection fails, auto mode
  fails closed to `full`.

Invalid `ARBORETUM_CI_MODE` values are blocking failures before any stage runs.

The `ARBORETUM_CI_JOBS` environment variable controls smoke-test concurrency
for smoke tests that explicitly opt into parallel execution with
`# ci-parallel: safe`. Unset means `8`. `ARBORETUM_CI_JOBS=1` runs all selected
smoke tests serially, which is useful for debugging. Non-positive, all-zero, or
non-numeric values are blocking failures before any stage runs. Smoke tests
without `# ci-parallel: safe` are treated as serial, preserving legacy
shared-state assumptions until a test is audited and marked safe.

The `ARBORETUM_CI_PREFLIGHT_DONE` environment variable is set by hosted
workflows when a separate preflight job already gated the expensive CI job.
When it equals `1`, `ci-checks.sh` prints
`SKIP: CI preflight already completed by caller` and proceeds to the expensive
stages without invoking `scripts/ci-preflight.sh` again.

The `ARBORETUM_CI_VERBOSE` environment variable controls output verbosity. The
script is **quiet by default**: passing sub-process output bodies are suppressed
from stdout and written to a raw log instead, while the orchestrator's own
structural lines (the seven `=== … ===` banners, the `CI mode:` line, and every
`SKIP:`/`FAIL:` diagnostic) and a compact per-stage summary are always printed.
Quiet mode is disabled — output reverts to the verbose, byte-for-byte legacy
behaviour — when the `CI` environment variable is non-empty (GitHub Actions sets
`CI=true`, so CI logs stay fully readable) **or** when `ARBORETUM_CI_VERBOSE=1`
is set. In quiet mode the full combined output of every stage is written to
`.arboretum/ci-checks-last.log` (relative to the resolved root, created with
`mkdir -p` and truncated at the start of each run); on a stage failure the
failing item's captured output is replayed to stdout (failing-item-first
diagnostics), and the raw-log path is printed at the end of the run. Quiet mode
requires `mkdir`, `mktemp`, `cat`, and `rm` on `PATH` (already required by the
parallel smoke runner).

The `BASE_REF`, `RELEASE_INTENT_EVENT`, and `RELEASE_INTENT_BODY_FILE` environment variables are consumed transitively by `dev-tools/release/check-version-bump.sh` and the delegated release gate when that dev-only tooling is installed. When called from `.github/workflows/ci.yml`, `BASE_REF` is set to `origin/<base_ref>` for pull-request events or `origin/main` for push events. `RELEASE_INTENT_EVENT` may point at the GitHub event JSON file, and `RELEASE_INTENT_BODY_FILE` may point at a local PR-body draft. When called locally without these variables, the release-gate scripts apply their own fallbacks.

### Exit codes

- `0` — preflight passed or was already completed by the caller, and all
  blocking expensive stages passed (ShellCheck when available or required,
  smoke tests, the declared default command when applicable, cross-ref
  validation, contract-coverage validation when installed or required in plugin
  roots, and release gate when installed or required in plugin roots all
  reported clean). If `shellcheck` is absent and `REQUIRE_SHELLCHECK` is not
  `1`, the ShellCheck stage is skipped and does not affect the exit code.
- `1` — preflight failed and stopped the run before expensive work, one or more
  expensive stages set `fail=1`, or mode/job validation fails before stages
  run. The failing stage(s) print their own diagnostics to stdout/stderr before
  the orchestrator exits.

### Side effects

Spawns subprocesses — one per stage:

1. `bash scripts/ci-preflight.sh --apply-safe-repairs` unless
   `ARBORETUM_CI_PREFLIGHT_DONE=1`. This is the only stage that may modify the
   working tree, and only through the safe repair policy in
   `docs/contracts/ci-preflight.cli-contract.md`. Any non-zero preflight exit
   stops `ci-checks.sh` immediately before expensive stages run.
2. `command -v shellcheck` gates the ShellCheck stage. If present, `find … -exec shellcheck …` runs ShellCheck against all `*.sh` files under the existing roots among `scripts/`, `.claude/hooks/`, `skills/`, and `dev-tools/`, excluding `_archived/` subtrees; findings remain blocking. Missing roots are not passed to `find`, so consumer repositories without top-level `skills/` or `dev-tools/` do not fail this stage solely because the plugin development tree is absent. If absent, the stage prints `SKIP: shellcheck not found on PATH …` and continues by default, or prints `FAIL: shellcheck is required but was not found on PATH` and sets `fail=1` when `REQUIRE_SHELLCHECK=1`. Read-only.
3. Selected `scripts/_smoke-test-*.sh` files run after applicability and tier filtering (excluding `_smoke-test-ci-checks.sh` by name to prevent self-referential recursion). If the glob has no matches, the loop continues silently; an unmatched literal `scripts/_smoke-test-*.sh` is never passed to `smoke_test_applicable`. A root is treated as an Arboretum plugin root when it has top-level `skills/`, top-level `hooks/`, `docs/contracts/`, `tests/contracts/`, `scripts/_fixtures/roadmap/`, and `.github/ISSUE_TEMPLATE/agent-ready.md`; plugin roots consider all smoke tests for selection. In non-plugin roots, smoke tests run only when their first eight lines include `# scope: consumer` or `# scope: any`. `# scope: plugin-only`, missing owning specs, or no consumer-applicable scope produce `SKIP` diagnostics. This prevents reserved seeded specs (for example `project-infrastructure`) from making plugin-only smoke tests look consumer-applicable. A smoke test with no `# ci-tier:` header is treated as balanced and runs in both balanced and full modes. A smoke test with `# ci-tier: full` is skipped in balanced mode with a `SKIP` diagnostic and runs in full mode. Unknown tier values are blocking failures. A smoke test with `# ci-parallel: safe` may run in bounded parallel batches when `ARBORETUM_CI_JOBS` is greater than `1`; missing `# ci-parallel:` metadata means serial, and unknown values are blocking failures. Parallel batches capture per-script logs, print them in stable selection order, and aggregate failure status before the next serial smoke test runs. Each smoke-test script may create and clean up its own temporary fixtures; the orchestrator does not manage them.
4. `bash scripts/read-test-config.sh docs/specs/test-infrastructure.spec.md` in consumer roots that have a testing-shape declaration, followed by `bash -c "$default_command"` for the emitted `default-command`. Missing declarations print `SKIP: docs/specs/test-infrastructure.spec.md not found`; plugin roots print `SKIP: plugin root runs framework checks directly` to avoid recursively invoking `ci-checks.sh` as arboretum-dev's own declared default command. Nested invocations with `ARBORETUM_CI_CHECKS_RUNNING_DEFAULT=1` print `SKIP: declared default-command already running`, preventing recursion when a consumer explicitly declares `bash scripts/ci-checks.sh`. A present declaration with no reader, an invalid declaration, a reader that omits `default-command`, or a non-zero declared command sets `fail=1`.
5. `bash scripts/validate-cross-refs.sh` — read-only cross-reference check.
6. Contract-coverage validation. If `docs/contracts/` is absent and the root has plugin package manifests (`.claude-plugin/plugin.json` or `.codex-plugin/plugin.json`), the orchestrator fails with `FAIL: docs/contracts missing in plugin root; cannot run scripts/validate-coverage-manifest.sh`. If `scripts/validate-coverage-manifest.sh` is absent in a plugin root, the orchestrator fails with `FAIL: scripts/validate-coverage-manifest.sh missing in plugin root`; if absent in a consumer root, it prints `SKIP: scripts/validate-coverage-manifest.sh not installed in this root`. If the validator is installed in a consumer root that has not adopted the contract layer (`docs/contracts/` absent), it prints `SKIP: scripts/validate-coverage-manifest.sh requires docs/contracts in this root` and leaves the gate green. Otherwise it runs `bash scripts/validate-coverage-manifest.sh`.
7. `bash dev-tools/release/check-version-bump.sh` when the dev-only script exists. This compatibility entrypoint delegates to the release gate. If absent in a plugin root, the orchestrator fails with `FAIL: dev-tools/release/check-version-bump.sh missing in plugin root`; if absent in a consumer root, it prints `SKIP: dev-tools/release/check-version-bump.sh not installed in this root`.

The expensive stages do not write repository files. The preflight stage may
write only the safe repairs documented by the preflight contract and stops the
orchestrator before expensive stages when it does so. The parallel smoke runner
may create and remove temporary scratch files under the system temp directory
for captured logs and statuses.

## Test surface

- **CLI-1: Stage-banner sequence.** The script defines the stage banners in the documented order: `=== CI preflight ===`, `=== ShellCheck ===`, `=== Smoke tests ===`, `=== Declared test command ===`, `=== Cross-reference validation ===`, `=== Contract coverage validation ===`, `=== Release gate ===`. No banner may appear before its predecessor.
- **CLI-2: fail-flag accumulation pattern.** Preflight failure exits before expensive stages. Every expensive blocking stage delegates its exit code to the `fail` flag either directly via `|| fail=1` or through a helper that sets `fail=1`.
- **CLI-3: Exit discipline.** Preflight failures stop before the expensive-stage accumulator. After preflight succeeds or is skipped, the script terminates with `exit $fail`. It does not `exit 0` or `exit 1` unconditionally for the expensive stages; their final exit code is the accumulated flag.
- **CLI-4: Smoke-test self-exclusion.** The smoke-test loop skips any file matching `*_smoke-test-ci-checks.sh` to prevent infinite recursion when the contract smoke test for ci-checks itself is present in `scripts/`.
- **CLI-5: Root resolution.** The script derives `ROOT` from its own path (`$(dirname "${BASH_SOURCE[0]}")/../`), not from `$PWD`, so it is location-independent and may be invoked from any directory.
- **CLI-6: ShellCheck capability gate.** The ShellCheck stage checks `command -v shellcheck` before invoking it. When present, ShellCheck runs with `--severity=warning` against the existing `scripts/`, `.claude/hooks/`, `skills/`, and `dev-tools/` roots, and its findings remain blocking. When absent, default mode prints a `SKIP` diagnostic and continues; `REQUIRE_SHELLCHECK=1` prints a `FAIL` diagnostic and sets `fail=1`.
- **CLI-7: Consumer-root applicability.** The ShellCheck stage builds its `find` root list from directories that actually exist. The smoke-test stage detects the Arboretum plugin-root layout; plugin roots run all smoke tests, while consumer roots run only smoke tests explicitly scoped `consumer` or `any`. Consumer roots skip `plugin-only`, owner-missing, and unscoped smoke tests with `SKIP` diagnostics. Plugin-only coverage and dev-only release-gate checks run when their scripts are installed; absent scripts fail in plugin roots and skip in consumer roots. The release gate path is `dev-tools/release/check-version-bump.sh`. Contract-coverage validation additionally requires its input layer: if a consumer root has the coverage validator installed but no `docs/contracts/`, the coverage stage prints a `SKIP` diagnostic and does not fail the gate. A plugin manifest root with missing `docs/contracts/` remains a blocking failure.
- **CLI-8: Empty smoke-test glob.** A root with no `scripts/_smoke-test-*.sh` files prints no `sed:` or missing-file diagnostic from the smoke loop.
- **CLI-9: Consumer declared test command.** In a consumer root with `docs/specs/test-infrastructure.spec.md`, `scripts/read-test-config.sh`, and `scripts/lib/yaml-lite.sh`, `ci-checks.sh` reads and runs the declared `default-command`. A fixture whose declared command exits 0 and whose plugin-only coverage/release-gate scripts are absent must exit 0, create the fixture's product-test marker, and print consumer skip diagnostics for those absent plugin-only scripts.
- **CLI-10: CI mode and tier selection.** Unset mode behaves as balanced: applicable smoke tests with no tier header run, while `# ci-tier: full` tests skip with a diagnostic. `ARBORETUM_CI_MODE=full` runs both default-tier and full-tier smoke tests. Invalid `ARBORETUM_CI_MODE`, invalid `# ci-tier:`, and invalid `# ci-parallel:` values fail closed. Selection is metadata-driven; `ci-checks.sh` must not hard-code individual full-only smoke-test paths.
- **CLI-11: Parallel smoke aggregation.** With `ARBORETUM_CI_JOBS` greater than `1`, only smoke tests marked `# ci-parallel: safe` run with bounded concurrency. Unmarked smoke tests run serially. Parallel batches print captured logs in stable selection order and any non-zero script exit contributes to the final `fail` flag. `ARBORETUM_CI_JOBS=1` preserves all-serial debug behavior.
- **CLI-12: Auto-full trigger paths.** `ARBORETUM_CI_MODE=auto` resolves to `full` when changed paths include CI/test executable surfaces or release-package surfaces, resolves to `balanced` when no trigger path changed, and resolves to `full` when changed-path detection fails.
- **CLI-13: Preflight gating.** `ci-checks.sh` runs
  `scripts/ci-preflight.sh --apply-safe-repairs` before ShellCheck. When
  `ARBORETUM_CI_PREFLIGHT_DONE=1`, it prints a skip line and does not rerun
  preflight. The old late `=== Health check (non-blocking) ===` drift tail is
  absent.
- **CLI-14: Quiet mode (default-quiet except CI).** The script resolves a `QUIET` flag from `${CI:-}` and `ARBORETUM_CI_VERBOSE`: quiet is the default, disabled when `$CI` is non-empty or `ARBORETUM_CI_VERBOSE=1`. In quiet mode a passing sub-process body is suppressed from stdout and routed to `.arboretum/ci-checks-last.log` via the `run_capture` helper (which prints `  ok` on success and replays the captured slice on failure); the smoke-test stage prints a `N passed · N skipped · N failed` summary; a failing smoke test replays only the failing item; the seven stage banners, the `CI mode:` line, and all `SKIP:`/`FAIL:` diagnostics still print; and the raw-log path is printed at the end. In verbose mode (`$CI` set or `ARBORETUM_CI_VERBOSE=1`) output is byte-for-byte the legacy behaviour and no raw log is written.

## Versioning

- **1.12** — add default-quiet output mode (`ARBORETUM_CI_VERBOSE`/`CI` trigger, `run_capture` body suppression, per-stage summary, failing-item replay, `.arboretum/ci-checks-last.log` raw log) so agent-invoked local runs do not dump green transcripts into model context; verbose mode unchanged (2026-06-06).
- **1.11** — add standard CI preflight as the first stop gate, remove the late
  non-blocking health-check tail, and document `ARBORETUM_CI_PREFLIGHT_DONE`
  hosted-job handoff (2026-06-06).
- **1.10** — guard contract-coverage validation on the presence of `docs/contracts/` in consumer roots, while keeping missing contracts blocking for plugin manifest roots (2026-06-04).
- **1.9** — include `dev-tools/` in ShellCheck roots so moved dev-only scripts keep the same lint coverage as their former `scripts/` location (2026-06-04).
- **1.8** — move the release gate invocation to the dev-only
  `dev-tools/release/check-version-bump.sh` path and document consumer-root
  skip behaviour for absent dev-only tooling (2026-06-04).
- **1.7** — add balanced/full/auto CI mode selection, full-only smoke-test metadata, opt-in bounded parallel smoke execution, and GitHub auto-full trigger path semantics (2026-06-03).
- **1.6** — rename the final stage to release gate and document release-intent environment seams (2026-06-03).
- **1.5** — consumer roots now run the declared `default-command` through `read-test-config.sh`; absent contract-coverage and version-bump scripts skip in consumer roots but remain required in plugin roots (2026-06-03).
- **1.4** — empty smoke-test globs are ignored silently instead of being passed to `sed` as literal paths (2026-06-02).
- **1.3** — consumer smoke-test applicability is scope-declared (`# scope: consumer` / `# scope: any`) so reserved seeded specs cannot leak plugin-only smoke tests into consumer roots (2026-06-02).
- **1.2** — ShellCheck filters missing roots, and consumer roots skip framework-owned smoke tests whose owning specs are not installed (2026-06-02).
- **1.1** — ShellCheck stage is capability-gated with default skip and `REQUIRE_SHELLCHECK=1` strict mode (2026-06-01).
- **1.0** — initial contract (2026-05-30).
