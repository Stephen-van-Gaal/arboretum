---
seam: validate-cli-contract
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/validate-cli-contract.sh
---
<!-- owner: pipeline-contracts-template -->

# validate-cli-contract — `validate-cli-contract.sh` CLI-Contract Schema-Validator Contract

The enforcement validator that checks a `*.cli-contract.md` file against the WS5 CLI-contract schema (design §D4) — the schema for the lighter-weight CLI-shape contracts that govern hooks, scripts, and developer-facing entry points (peer to the full module-contract schema). This contract pins the validator's own protocol — the exact `CLI-CONTRACT-DRIFT:` message format and exit codes — so its consumers (the CLI-contract smoke test and `tests/contracts/cli/` fixtures) can assert on its output without re-deriving the CLI-contract field and section rules. Standalone validator contract per design decision D-7a-2: it governs the *script that checks the CLI-contract schema*, distinct from any individual `*.cli-contract.md` it validates.

## Producer

`scripts/validate-cli-contract.sh` — producer-type: `script`.

Validates the `*.cli-contract.md` file at the positional path argument. A thin bash wrapper handles arg parsing and file existence; an embedded python3 + PyYAML block runs every structural check:

- **Frontmatter delimiters** — the file must start with `---` and carry a closing `---`; the leading region before the first delimiter must be empty.
- **Frontmatter YAML** — must parse as a YAML mapping.
- **Required fields** — `script`, `version`, `invokers`, `related-designs` must each be present and non-empty.
- **version** — must be semver-light `major.minor` (e.g. `1.0`); a bare integer (`1`) is drift.
- **invokers** — must be a YAML list; each entry a mapping with a `type:` field in the closed enum `{skill, script, hook, plugin, developer}`.
- **Body sections** — `## Surface`, `## Protocol`, `## Test surface`, `## Versioning` must all be present, plus the `## Protocol` sub-sections `### Arguments`, `### Exit codes`, `### Side effects`.
- **Test surface** — the `## Test surface` section must contain at least one `- ` bullet assertion.

Emits one summary `CLI-CONTRACT-DRIFT:` line plus one indented `  - <message>` bullet per issue to stderr; never mutates the contract file.

## Consumer

Consumer-type: `script`. Two consumer classes assert on this validator's output:

- **CLI-contract smoke test** — `scripts/_smoke-test-validate-cli-contract.sh` invokes the validator against the six fixtures under `tests/contracts/cli/`: `good-001.cli-contract.md` must exit 0, and each of `bad-missing-frontmatter-field`, `bad-invalid-invoker-type`, `bad-missing-body-section`, `bad-empty-test-surface`, `bad-malformed-version` must exit non-zero.
- **`tests/contracts/cli/` fixtures** — the good/bad fixture set is the shared corpus the validator is exercised against; each bad fixture isolates exactly one schema violation so the validator's per-issue message wording is pinned.

**Consumer obligations:** consumers MUST treat any non-zero exit as drift and MUST NOT swallow it; they MUST match the `CLI-CONTRACT-DRIFT:` summary and `  - <message>` bullet shape rather than re-implementing the CLI-contract schema rules.

## Protocol shape

### Inputs

- Positional argument 1: `<path-to-cli-contract.md>` (a `*.cli-contract.md` file with leading YAML frontmatter). No stdin. Exactly one argument; zero or more-than-one is an invocation error.

### Outputs

- **stdout:** none.
- **stderr (drift only):** a summary line `CLI-CONTRACT-DRIFT: <N> issue(s) in <path>` followed by one indented bullet per issue, `  - <message>` (e.g. `  - missing required frontmatter field: version`, `  - version must be semver-light (major.minor); got '1'`, `  - invokers[0]: type 'cyborg' not in closed enum (expected one of: developer, hook, plugin, script, skill)`, `  - missing required body section: ## Versioning`, `  - ## Test surface has no bullet-list assertions`).
- **stderr (invocation error):** `Usage: <script> <path-to-cli-contract.md>` (wrong arg count) or `Not a file: <path>` (path missing/not a regular file).
- **Exit codes:** `0` — contract valid; `1` — one or more schema violations (issues on stderr); `2` — invocation problem (wrong arg count, file missing/unreadable).

### Invariants

- **Drift goes to stderr, never stdout.** stdout stays empty so callers can capture it separately; the `CLI-CONTRACT-DRIFT:` block is stderr-only.
- **Whole-schema report, not first-fail.** All frontmatter fields, the enum/version checks, every required body section and sub-section, and the test-surface bullet check are evaluated; the summary `<N>` is the total issue count.
- **Closed invoker-type enum.** `invokers[].type` must be one of `{skill, script, hook, plugin, developer}`; any other value is drift.
- **Semver-light version.** `version` must match `<major>.<minor>` exactly; a bare integer or a three-segment version is drift.
- **No mutation.** Read-only — never writes the contract file.
- **Exit-2 is distinct from exit-1.** An invocation problem (missing file, wrong arg count) exits `2` with a `Usage:`/`Not a file:` message and does NOT emit a `CLI-CONTRACT-DRIFT:` line; schema drift exits `1` and does.

## Test surface

- **VCC-1:** good fixture (`tests/contracts/cli/good-001.cli-contract.md`) → exit 0, no `CLI-CONTRACT-DRIFT:` on stderr.
- **VCC-2:** missing-frontmatter-field fixture (`bad-missing-frontmatter-field.cli-contract.md`) → exit 1, stderr `CLI-CONTRACT-DRIFT:` summary + `  - missing required frontmatter field: version`.
- **VCC-3:** invalid-invoker-type fixture (`bad-invalid-invoker-type.cli-contract.md`) → exit 1, stderr `  - invokers[0]: type '…' not in closed enum`.
- **VCC-4:** malformed-version fixture (`bad-malformed-version.cli-contract.md`) → exit 1, stderr `  - version must be semver-light`.
- **VCC-5:** missing-body-section fixture (`bad-missing-body-section.cli-contract.md`) → exit 1, stderr `  - missing required body section: ## Versioning`.
- **VCC-6:** empty-test-surface fixture (`bad-empty-test-surface.cli-contract.md`) → exit 1, stderr `  - ## Test surface has no bullet-list assertions`.
- **VCC-7:** invocation error — non-existent path → exit 2, stderr `Not a file:`, no `CLI-CONTRACT-DRIFT:` line.

## Versioning

- **1.0** (2026-05-30) — initial contract. Validator shape as of `scripts/validate-cli-contract.sh` on `main` (CLI-CONTRACT-DRIFT stderr format, exit 0/1/2). Issue #303 (WS5 PR 7a).
