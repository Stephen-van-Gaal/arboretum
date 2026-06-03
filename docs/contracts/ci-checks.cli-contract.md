---
script: scripts/ci-checks.sh
version: 1.6
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
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/ci-checks.sh`

## Surface

CI orchestrator and pre-PR local gate. Runs seven stages in sequence — capability-gated ShellCheck linting, smoke-test loop, declared default test command, cross-reference validation, optional contract-coverage validation, non-blocking health check, and optional release gate — accumulating a `fail` flag, then exits `$fail`. Invoked by `/finish` before opening a pull request and by `.github/workflows/ci.yml` on every PR and push to main, ensuring the local gate and CI cannot drift. Takes no arguments and exposes no `ROOT` override — the repository root is recomputed unconditionally from the script's own location (`BASH_SOURCE[0]`), so a caller-supplied `ROOT` is ignored and the checks always run against the script's own tree. The orchestrator is layout-aware: Arboretum plugin roots run the full framework self-check set directly, while consumer roots run the declared `default-command` when `docs/specs/test-infrastructure.spec.md` and `scripts/read-test-config.sh` are installed, skip framework-owned smoke tests whose owning specs are not installed in the host project, and skip absent plugin-only coverage/release-gate scripts.

## Protocol

### Arguments

No positional arguments and no flags. The script determines the repository root automatically:

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

The `REQUIRE_SHELLCHECK` environment variable controls the ShellCheck stage when the `shellcheck` binary is absent. Unset or any value other than `1` means the ShellCheck stage prints a `SKIP` diagnostic and remains non-blocking. `REQUIRE_SHELLCHECK=1` makes the missing binary a blocking failure.

The `BASE_REF`, `RELEASE_INTENT_EVENT`, and `RELEASE_INTENT_BODY_FILE` environment variables are consumed transitively by `scripts/check-version-bump.sh` and the delegated release gate. When called from `.github/workflows/ci.yml`, `BASE_REF` is set to `origin/<base_ref>` for pull-request events or `origin/main` for push events. `RELEASE_INTENT_EVENT` may point at the GitHub event JSON file, and `RELEASE_INTENT_BODY_FILE` may point at a local PR-body draft. When called locally without these variables, the release-gate scripts apply their own fallbacks.

### Exit codes

- `0` — all blocking stages passed (ShellCheck when available or required, smoke tests, the declared default command when applicable, cross-ref validation, contract-coverage validation when installed or required in plugin roots, and release gate when installed or required in plugin roots all reported clean). If `shellcheck` is absent and `REQUIRE_SHELLCHECK` is not `1`, the ShellCheck stage is skipped and does not affect the exit code.
- `1` — one or more blocking stages set `fail=1`. The failing stage(s) print their own diagnostics to stdout/stderr before the orchestrator exits.

The health-check stage is non-blocking: a non-zero return from `scripts/health-check.sh` is absorbed by the orchestrator (`|| echo "(health-check reported issues — non-blocking)"`) and does not contribute to `$fail`.

### Side effects

Spawns subprocesses — one per stage:

1. `command -v shellcheck` gates the ShellCheck stage. If present, `find … -exec shellcheck …` runs ShellCheck against all `*.sh` files under the existing roots among `scripts/`, `.claude/hooks/`, and `skills/`, excluding `_archived/` subtrees; findings remain blocking. Missing roots are not passed to `find`, so consumer repositories without top-level `skills/` do not fail this stage solely because the plugin development tree is absent. If absent, the stage prints `SKIP: shellcheck not found on PATH …` and continues by default, or prints `FAIL: shellcheck is required but was not found on PATH` and sets `fail=1` when `REQUIRE_SHELLCHECK=1`. Read-only.
2. `bash "$f"` for each applicable `scripts/_smoke-test-*.sh` file (excluding `_smoke-test-ci-checks.sh` by name to prevent self-referential recursion). If the glob has no matches, the loop continues silently; an unmatched literal `scripts/_smoke-test-*.sh` is never passed to `smoke_test_applicable`. A root is treated as an Arboretum plugin root when it has top-level `skills/`, top-level `hooks/`, `docs/contracts/`, `tests/contracts/`, `scripts/_fixtures/roadmap/`, and `.github/ISSUE_TEMPLATE/agent-ready.md`; plugin roots run every smoke test. In non-plugin roots, smoke tests run only when their first eight lines include `# scope: consumer` or `# scope: any`. `# scope: plugin-only`, missing owning specs, or no consumer-applicable scope produce `SKIP` diagnostics. This prevents reserved seeded specs (for example `project-infrastructure`) from making plugin-only smoke tests look consumer-applicable. Each smoke-test script may create and clean up its own temporary fixtures; the orchestrator does not manage them.
3. `bash scripts/read-test-config.sh docs/specs/test-infrastructure.spec.md` in consumer roots that have a testing-shape declaration, followed by `bash -c "$default_command"` for the emitted `default-command`. Missing declarations print `SKIP: docs/specs/test-infrastructure.spec.md not found`; plugin roots print `SKIP: plugin root runs framework checks directly` to avoid recursively invoking `ci-checks.sh` as arboretum-dev's own declared default command. Nested invocations with `ARBORETUM_CI_CHECKS_RUNNING_DEFAULT=1` print `SKIP: declared default-command already running`, preventing recursion when a consumer explicitly declares `bash scripts/ci-checks.sh`. A present declaration with no reader, an invalid declaration, a reader that omits `default-command`, or a non-zero declared command sets `fail=1`.
4. `bash scripts/validate-cross-refs.sh` — read-only cross-reference check.
5. `bash scripts/validate-coverage-manifest.sh` when the script exists. If absent in a plugin root, the orchestrator fails with `FAIL: scripts/validate-coverage-manifest.sh missing in plugin root`; if absent in a consumer root, it prints `SKIP: scripts/validate-coverage-manifest.sh not installed in this root`.
6. `bash scripts/health-check.sh "$ROOT"` — non-blocking; may emit diagnostic output.
7. `bash scripts/check-version-bump.sh` when the script exists. This compatibility entrypoint delegates to the release gate. If absent in a plugin root, the orchestrator fails with `FAIL: scripts/check-version-bump.sh missing in plugin root`; if absent in a consumer root, it prints `SKIP: scripts/check-version-bump.sh not installed in this root`.

No files are written or modified by the orchestrator itself. The repository working tree is effectively read-only from the orchestrator's perspective.

## Test surface

- **CLI-1: Stage-banner sequence.** The script defines the seven stage banners in the documented order: `=== ShellCheck ===`, `=== Smoke tests ===`, `=== Declared test command ===`, `=== Cross-reference validation ===`, `=== Contract coverage validation ===`, `=== Health check (non-blocking) ===`, `=== Release gate ===`. No banner may appear before its predecessor.
- **CLI-2: fail-flag accumulation pattern.** Every blocking stage delegates its exit code to the `fail` flag either directly via `|| fail=1` or through a helper that sets `fail=1`. The health-check stage is the sole exception: its non-zero return is absorbed by `|| echo "(health-check reported issues — non-blocking)"` and does not set `fail`.
- **CLI-3: Exit discipline.** The script terminates with `exit $fail`. It does not `exit 0` or `exit 1` unconditionally; the final exit code is always the accumulated flag.
- **CLI-4: Smoke-test self-exclusion.** The smoke-test loop skips any file matching `*_smoke-test-ci-checks.sh` to prevent infinite recursion when the contract smoke test for ci-checks itself is present in `scripts/`.
- **CLI-5: Root resolution.** The script derives `ROOT` from its own path (`$(dirname "${BASH_SOURCE[0]}")/../`), not from `$PWD`, so it is location-independent and may be invoked from any directory.
- **CLI-6: ShellCheck capability gate.** The ShellCheck stage checks `command -v shellcheck` before invoking it. When present, ShellCheck runs with `--severity=warning` and its findings remain blocking. When absent, default mode prints a `SKIP` diagnostic and continues; `REQUIRE_SHELLCHECK=1` prints a `FAIL` diagnostic and sets `fail=1`.
- **CLI-7: Consumer-root applicability.** The ShellCheck stage builds its `find` root list from directories that actually exist. The smoke-test stage detects the Arboretum plugin-root layout; plugin roots run all smoke tests, while consumer roots run only smoke tests explicitly scoped `consumer` or `any`. Consumer roots skip `plugin-only`, owner-missing, and unscoped smoke tests with `SKIP` diagnostics. Plugin-only coverage and release-gate checks run when their scripts are installed; absent scripts fail in plugin roots and skip in consumer roots.
- **CLI-8: Empty smoke-test glob.** A root with no `scripts/_smoke-test-*.sh` files prints no `sed:` or missing-file diagnostic from the smoke loop.
- **CLI-9: Consumer declared test command.** In a consumer root with `docs/specs/test-infrastructure.spec.md`, `scripts/read-test-config.sh`, and `scripts/lib/yaml-lite.sh`, `ci-checks.sh` reads and runs the declared `default-command`. A fixture whose declared command exits 0 and whose plugin-only coverage/release-gate scripts are absent must exit 0, create the fixture's product-test marker, and print consumer skip diagnostics for those absent plugin-only scripts.

## Versioning

- **1.6** — rename the final stage to release gate and document release-intent environment seams (2026-06-03).
- **1.5** — consumer roots now run the declared `default-command` through `read-test-config.sh`; absent contract-coverage and version-bump scripts skip in consumer roots but remain required in plugin roots (2026-06-03).
- **1.4** — empty smoke-test globs are ignored silently instead of being passed to `sed` as literal paths (2026-06-02).
- **1.3** — consumer smoke-test applicability is scope-declared (`# scope: consumer` / `# scope: any`) so reserved seeded specs cannot leak plugin-only smoke tests into consumer roots (2026-06-02).
- **1.2** — ShellCheck filters missing roots, and consumer roots skip framework-owned smoke tests whose owning specs are not installed (2026-06-02).
- **1.1** — ShellCheck stage is capability-gated with default skip and `REQUIRE_SHELLCHECK=1` strict mode (2026-06-01).
- **1.0** — initial contract (2026-05-30).
