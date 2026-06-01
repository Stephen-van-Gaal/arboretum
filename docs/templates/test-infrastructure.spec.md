---
# This is a GOVERNED SPEC. Its frontmatter carries TWO disjoint schemas in one
# block: (a) governed-spec metadata read by scripts/generate-register.sh
# (version/name/status/owner/owns), and (b) the testing-shape declaration read
# by scripts/read-test-config.sh (default-command + optionals). The two parsers
# read non-overlapping keys and ignore each other's.
#
# NOTE: keep explanatory notes on their OWN comment lines for readability.
# The shared yaml-lite parser strips trailing inline comments unless `#` is
# inside quotes.
#
# ── (a) governed-spec metadata ──
version: 1
name: test-infrastructure
status: draft
owner: <governing owner, e.g. architecture>
owns: []
# ── (b) testing-shape declaration — only default-command is required ──
default-command: <command that runs the default-safe suite; exit 0 == green>
# Optional fields are COMMENTED OUT so an unfilled optional enum never trips the
# parser's enum validation. Uncomment and fill only what applies:
# runner: pytest
# layout: by-feature
# tiers-via: markers
# opt-in-commands:
#   live: <command for tests that hit real external services; needs creds>
#   costly: <command for tests that incur monetary cost (paid API / LLM)>
---

# Test Infrastructure

## Status
draft

## Owner
<!-- Who is responsible for this spec's correctness and currency. -->

## Target Phase
Phase 0

## Purpose

Define the test framework, runner configuration, directory layout, and shared utilities that all other specs' tests depend on. This is one of two reserved specs and must be created before any feature specs are implemented.

## Requires (Inbound Contracts)

| Dependency | Source | Definition |
|------------|--------|------------|
| — | — | No inbound contracts — this is a foundational spec |

## Provides (Outbound Contracts)

| Export | Type | Definition |
|--------|------|------------|
| Test runner | Tool | inline — <!-- e.g. pytest, jest, bats-core, go test --> installed and configured |
| Test helper library | Library | inline — `tests/helpers/` or equivalent with common fixtures and assertions |
| Test directory structure | Convention | inline — `tests/unit/`, `tests/contract/`, `tests/integration/` |
| Test entry point | Command | inline — single command that runs all tiers in order |

## Behaviour

### Test Framework

<!-- Choose the test framework appropriate for your project's language/stack.
     Record the choice and rationale in the Decisions table below.

     Examples:
     - Python: pytest with pytest-cov
     - JavaScript/TypeScript: jest or vitest
     - Bash: bats-core with bats-assert
     - Go: go test with testify
     - Rust: cargo test
     - Multi-language: one framework per language, unified entry point -->

### Test Directory Layout

<!-- Define the directory structure. Adapt the subdirectory naming to your stack.

     Standard layout:
     tests/
     ├── unit/           # Tier 1: isolated, mocked dependencies
     ├── contract/       # Tier 2: verify conformance to shared definitions
     ├── integration/    # Tier 3: cross-spec interaction
     ├── helpers/        # Shared fixtures, factories, utilities
     └── fixtures/       # Test data, sample files, golden outputs
-->

### Test Entry Point

<!-- Define a single command that runs all applicable tiers in order,
     stopping on failure at any tier. This command is what CI and
     pre-push hooks invoke.

     Requirements:
     - Must run tiers in order: unit → contract → integration
     - A failure at any tier must block the next tier
     - Must return exit code 0 on success, non-zero on failure
     - Should support running a single tier (e.g., `./run-tests.sh unit`)

     Examples:
     - Bash: ./run-tests.sh
     - Python: pytest tests/unit && pytest tests/contract && pytest tests/integration
     - Makefile: make test
     - npm: npm test (with script that chains tiers)

     This command is what the frontmatter `default-command:` declares — the
     single source `/build`, `/finish`, and `/design` read via
     scripts/read-test-config.sh. -->

### Cost-class (opt-in) tiers

<!-- Scope tiers (unit/contract/integration) above are the WHAT axis. Cost-class
     is the orthogonal HOW axis — does a test hit a real service or cost money?

     - default — free, deterministic, no external services. Always run by
       `default-command`. (No declaration needed; it IS the default suite.)
     - live    — hits real external services; opt-in. Declare the command in
       frontmatter `opt-in-commands.live` (e.g. `pytest -m live`).
     - costly  — incurs monetary cost (paid API / LLM); opt-in. Declare in
       frontmatter `opt-in-commands.costly` (e.g. `pytest -m eval`).

     Automated gates run ONLY default-command. live/costly are run by a human on
     demand. Most projects have no opt-in tiers and leave those fields commented. -->

### Shared Test Helpers

<!-- Define common utilities that multiple specs' tests will use.
     These prevent duplication and ensure consistent test patterns.

     Typical helpers:
     - Setup/teardown: create and clean up temp directories, databases, etc.
     - Factories: generate test data conforming to shared definitions
     - Custom assertions: domain-specific pass/fail checks
     - Mock builders: reusable mocks for common dependencies
-->

### Installation and Dependencies

<!-- How are test dependencies installed?

     Examples:
     - Python: listed in pyproject.toml [test] extras or requirements-test.txt
     - Node: devDependencies in package.json
     - Bash: git submodules for bats-core
     - Go: no extra deps (go test is built-in)

     The installation method should be documented in CLAUDE.md and
     reproducible in CI without manual steps. -->

## Decisions

| ID | Decision | Alternatives Considered | Rationale | Date |
|----|----------|------------------------|-----------|------|
| T1 | <!-- Test framework choice --> | <!-- What else was considered --> | <!-- Why this one --> | <!-- Date --> |
| T2 | <!-- Test dependency installation method --> | <!-- Alternatives --> | <!-- Rationale --> | <!-- Date --> |

## Tests

### Unit Tests
<!-- The test infrastructure itself should be tested:
     - Entry point correctly runs tiers in order and stops on failure
     - Shared helpers produce valid fixtures
     - Custom assertions report correct pass/fail -->

### Contract Tests
N/A — no shared definition references. This is a foundational spec with no inbound contracts.

### Integration Tests
N/A — no cross-spec dependencies at Phase 0. Integration tests will be added when feature specs depend on the test harness.

## Environment Requirements

<!-- Declare runtime requirements for running tests.

     Examples:
     - "Python 3.10+ with venv"
     - "Node 18+ with npm"
     - "Bash 4+ and git"
     - "Docker for integration tests"
-->

## Implementation Notes

<!-- Guidance for the implementer:
     - Each test should be independent — setup creates fresh state, teardown cleans up
     - Tests must not mutate the project repo; all side effects in temp directories
     - Document the primary test command in CLAUDE.md's "Running Tests" section
     - Keep test dependencies minimal — don't add a test framework heavier than the project
-->
