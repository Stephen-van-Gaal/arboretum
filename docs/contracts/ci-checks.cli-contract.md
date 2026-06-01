---
script: scripts/ci-checks.sh
version: 1.1
invokers:
  - type: skill
    name: /finish
  - type: script
    name: .github/workflows/ci.yml
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/ci-checks.sh`

## Surface

CI orchestrator and pre-PR local gate. Runs six stages in sequence — capability-gated ShellCheck linting, smoke-test loop, cross-reference validation, contract-coverage validation, non-blocking health check, and version-bump check — accumulating a `fail` flag, then exits `$fail`. Invoked by `/finish` before opening a pull request and by `.github/workflows/ci.yml` on every PR and push to main, ensuring the local gate and CI cannot drift. Takes no arguments and exposes no `ROOT` override — the repository root is recomputed unconditionally from the script's own location (`BASH_SOURCE[0]`), so a caller-supplied `ROOT` is ignored and the checks always run against the script's own tree.

## Protocol

### Arguments

No positional arguments and no flags. The script determines the repository root automatically:

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

The `REQUIRE_SHELLCHECK` environment variable controls the ShellCheck stage when the `shellcheck` binary is absent. Unset or any value other than `1` means the ShellCheck stage prints a `SKIP` diagnostic and remains non-blocking. `REQUIRE_SHELLCHECK=1` makes the missing binary a blocking failure.

The `BASE_REF` environment variable is consumed transitively by `scripts/check-version-bump.sh` (the version-bump stage). When called from `.github/workflows/ci.yml`, `BASE_REF` is set to `origin/<base_ref>` for pull-request events or `origin/main` for push events. When called locally without `BASE_REF`, `check-version-bump.sh` applies its own fallback.

### Exit codes

- `0` — all blocking stages passed (ShellCheck when available or required, smoke tests, cross-ref validation, contract-coverage validation, and version-bump check all reported clean). If `shellcheck` is absent and `REQUIRE_SHELLCHECK` is not `1`, the ShellCheck stage is skipped and does not affect the exit code.
- `1` — one or more blocking stages set `fail=1`. The failing stage(s) print their own diagnostics to stdout/stderr before the orchestrator exits.

The health-check stage is non-blocking: a non-zero return from `scripts/health-check.sh` is absorbed by the orchestrator (`|| echo "(health-check reported issues — non-blocking)"`) and does not contribute to `$fail`.

### Side effects

Spawns subprocesses — one per stage:

1. `command -v shellcheck` gates the ShellCheck stage. If present, `find … -exec shellcheck …` runs ShellCheck against all `*.sh` files under `scripts/`, `.claude/hooks/`, and `skills/`, excluding `_archived/` subtrees; findings remain blocking. If absent, the stage prints `SKIP: shellcheck not found on PATH …` and continues by default, or prints `FAIL: shellcheck is required but was not found on PATH` and sets `fail=1` when `REQUIRE_SHELLCHECK=1`. Read-only.
2. `bash "$f"` for each `scripts/_smoke-test-*.sh` file (excluding `_smoke-test-ci-checks.sh` by name to prevent self-referential recursion). Each smoke-test script may create and clean up its own temporary fixtures; the orchestrator does not manage them.
3. `bash scripts/validate-cross-refs.sh` — read-only cross-reference check.
4. `bash scripts/validate-coverage-manifest.sh` — read-only contract-coverage check.
5. `bash scripts/health-check.sh "$ROOT"` — non-blocking; may emit diagnostic output.
6. `bash scripts/check-version-bump.sh` — read-only version-bump diff check.

No files are written or modified by the orchestrator itself. The repository working tree is effectively read-only from the orchestrator's perspective.

## Test surface

- **CLI-1: Stage-banner sequence.** The script defines the six stage banners in the documented order: `=== ShellCheck ===`, `=== Smoke tests ===`, `=== Cross-reference validation ===`, `=== Contract coverage validation ===`, `=== Health check (non-blocking) ===`, `=== Version bump check ===`. No banner may appear before its predecessor.
- **CLI-2: fail-flag accumulation pattern.** Every blocking stage delegates its exit code to the `fail` flag via `|| fail=1`. The health-check stage is the sole exception: its non-zero return is absorbed by `|| echo "(health-check reported issues — non-blocking)"` and does not set `fail`.
- **CLI-3: Exit discipline.** The script terminates with `exit $fail`. It does not `exit 0` or `exit 1` unconditionally; the final exit code is always the accumulated flag.
- **CLI-4: Smoke-test self-exclusion.** The smoke-test loop skips any file matching `*_smoke-test-ci-checks.sh` to prevent infinite recursion when the contract smoke test for ci-checks itself is present in `scripts/`.
- **CLI-5: Root resolution.** The script derives `ROOT` from its own path (`$(dirname "${BASH_SOURCE[0]}")/../`), not from `$PWD`, so it is location-independent and may be invoked from any directory.
- **CLI-6: ShellCheck capability gate.** The ShellCheck stage checks `command -v shellcheck` before invoking it. When present, ShellCheck runs with `--severity=warning` and its findings remain blocking. When absent, default mode prints a `SKIP` diagnostic and continues; `REQUIRE_SHELLCHECK=1` prints a `FAIL` diagnostic and sets `fail=1`.

## Versioning

- **1.1** — ShellCheck stage is capability-gated with default skip and `REQUIRE_SHELLCHECK=1` strict mode (2026-06-01).
- **1.0** — initial contract (2026-05-30).
