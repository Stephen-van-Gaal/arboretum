---
version: 1
---

# Project Infrastructure

## Status
draft

## Owner
<!-- Who is responsible for this spec's correctness and currency. -->

## Target Phase
Phase 0

## Purpose

Own all project-level configuration that no feature spec should claim: CI/CD pipelines, git hooks, build configuration, dependency management, and the project skeleton. This is one of two reserved specs and is the single place where test-pass enforcement is defined.

## Requires (Inbound Contracts)

| Dependency | Source | Definition |
|------------|--------|------------|
| Test entry point | test-infrastructure.spec | inline — single command that runs all test tiers |

## Provides (Outbound Contracts)

| Export | Type | Definition |
|--------|------|------------|
| CI workflow | CI/CD config | inline — <!-- e.g. .github/workflows/ci.yml, .gitlab-ci.yml --> |
| Pre-push hook | Git hook | inline — `.githooks/pre-push` |
| Project skeleton | Convention | inline — directory structure, build config, entry points |

## Behaviour

### CI Pipeline

<!-- Define the CI workflow for your platform. The workflow must:
     1. Run validation scripts (cross-refs, health check)
     2. Run the test entry point from test-infrastructure.spec
     3. Fail the build on any failure — blocking merge

     Choose your CI platform and adapt:

     GitHub Actions (.github/workflows/ci.yml):
       - Trigger: pull_request + push to main
       - Steps: checkout (with submodules/deps), install, validate, test

     GitLab CI (.gitlab-ci.yml):
       - Stages: validate, test
       - Rules: merge requests + main branch

     Other: adapt to your platform, preserving the validate-then-test order.

     Key requirements:
     - Validation scripts run BEFORE tests (catch doc drift early)
     - Test tiers run in order via the single entry point
     - Any failure blocks the PR/MR from merging
-->

### Branch Protection

<!-- Document the intended branch protection rules for your main branch.
     These are applied manually in your Git hosting platform, not by code.

     Recommended rules:
     - Require CI status check to pass before merge
     - Require branch to be up to date before merging
     - Require pull request reviews (optional, team-dependent)

     Record the chosen rules and any deviations in the Decisions table. -->

### Pre-push Hook

<!-- Define a pre-push hook that runs tests locally before code is shared.
     This gives fast feedback without waiting for CI.

     The hook should:
     1. Run validation scripts (cross-refs at minimum)
     2. Run the test entry point
     3. Exit non-zero on any failure (blocking the push)
     4. Print clear messages about what failed

     Location: .githooks/pre-push (executable)
     Requires: git config core.hooksPath .githooks

     Example structure:
     #!/usr/bin/env bash
     set -euo pipefail
     echo "[pre-push] Running validation..."
     <validation command> || { echo "Validation failed."; exit 1; }
     echo "[pre-push] Running tests..."
     <test entry point> || { echo "Tests failed."; exit 1; }
     echo "[pre-push] All checks passed."
-->

### Existing Post-commit Hook

<!-- The post-commit hook (.githooks/post-commit) runs cross-reference
     validation after commits that touch doc files. It is ADVISORY only —
     it does not block commits. This gives quick feedback on doc consistency
     without slowing down iterative commits.

     The layered enforcement model:
     - Post-commit: advisory, fast, doc-changes only
     - Pre-push: blocking, thorough, all validation + tests
     - CI on PR: blocking, authoritative, runs on clean checkout
-->

### Owned Files

<!-- List all files this spec owns. These are project-level files
     that don't belong to any feature spec.

     Typical ownership:
     - Build config: pyproject.toml, package.json, Cargo.toml, Makefile, etc.
     - CI/CD: .github/workflows/, .gitlab-ci.yml, etc.
     - Git hooks: .githooks/
     - Dev config: .gitignore, .editorconfig, .pre-commit-config.yaml, etc.
     - Dependency management: requirements.txt, package-lock.json, etc.
     - Project docs: CLAUDE.md, docs/ structure
     - Version pins: contracts.yaml
     - Claude Code config: .claude/
-->

### Runtime Portability

Generated governance scripts should run from a bare checkout with Bash,
POSIX-ish shell tools, and Python 3 standard library only. Contextual
dependencies such as `git` or a configured provider CLI are acceptable when the
operation inherently needs them. Optional helpers must have portable fallbacks
or documented capability-gated diagnostics.

For YAML/frontmatter shapes inside Arboretum's supported YAML-lite subset,
scripts should share `scripts/lib/yaml-lite.sh` for parsing and keep
script-specific schema validation in the consumer.

## Decisions

| ID | Decision | Alternatives Considered | Rationale | Date |
|----|----------|------------------------|-----------|------|
| P1 | <!-- CI platform choice --> | <!-- Alternatives --> | <!-- Rationale --> | <!-- Date --> |
| P2 | Pre-push hook (not pre-commit) for local test enforcement | Pre-commit hook, no local enforcement | Pre-commit slows iterative commits and encourages `--no-verify`. Pre-push catches problems at the right boundary — before sharing with others. | <!-- Date --> |
| P3 | Advisory post-commit + blocking pre-push | Single blocking hook, no hooks | Layered approach: post-commit gives immediate doc feedback (fast, advisory). Pre-push gives comprehensive validation (thorough, blocking). | <!-- Date --> |
| P4 | <!-- Branch protection rules --> | <!-- Alternatives --> | <!-- Rationale --> | <!-- Date --> |
| P5 | Bare-checkout runtime portability for generated governance scripts | Require a package install step before governance scripts run | New projects should be able to run the governance framework immediately after checkout/bootstrap, before any project-specific dependency setup. | 2026-06-01 |

## Tests

### Unit Tests
<!-- Tests for infrastructure behaviour:
     - Pre-push hook runs validation and tests in correct order
     - Pre-push hook blocks on validation failure
     - Pre-push hook blocks on test failure
     - Pre-push hook passes when everything is clean
     - CI config is valid (lint the workflow file) -->

### Contract Tests
N/A — no shared definition references. The only dependency is on test-infrastructure's entry point, which is verified via integration.

### Integration Tests
<!-- - Pre-push hook correctly invokes the test entry point from
       test-infrastructure.spec and propagates its exit code
     - CI pipeline and pre-push produce consistent results
       (same inputs → same pass/fail) -->

## Environment Requirements

<!-- Declare what's needed to run the CI pipeline and hooks:
     - CI runner requirements (OS, language runtimes)
     - Local requirements for git hooks (bash version, etc.)
     - git with core.hooksPath configured -->

## Implementation Notes

<!-- Guidance for the implementer:
     - Keep CI minimal at first — no caching, matrix builds, or artifacts
       unless test times justify the complexity
     - Pre-push hook must be executable (chmod +x)
     - bootstrap-project.sh handles git hook installation
     - Update CLAUDE.md's "Running Tests" section with the primary test command
     - When the project has a REGISTER.md, add health-check.sh to CI
-->
