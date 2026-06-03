---
seam: test-infrastructure
version: 1.3
producer-type: script
consumer-type: skill
consumes:
  - yaml-lite-line-protocol
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-30-testing-shape-design.md
  - docs/superpowers/specs/2026-06-01-runtime-portability-design.md
  - docs/superpowers/specs/2026-06-02-adopter-ci-boundary-design.md
owns:
  - scripts/read-test-config.sh
---
<!-- owner: test-infrastructure -->

# test-infrastructure — `read-test-config.sh` Test-Command Declaration Contract

The seam between `scripts/read-test-config.sh` (which reads a project's testing-shape declaration off `docs/specs/test-infrastructure.spec.md`) and the consumers that run a project's suite — `/build` (exit gate), `/finish` (pre-PR gate), `/design` (coverage-baseline mode), and consumer-installed `scripts/ci-checks.sh` (canonical local/CI entrypoint). The script's stdout is a `key=value` protocol; this contract pins the declared field set, the single required field, the closed enums, and the exit semantics so consumers never re-parse the spec's YAML.

## Producer

`scripts/read-test-config.sh` — producer-type: `script`.

Takes exactly one positional argument: the path to a `test-infrastructure.spec.md`. Reads the leading `---`-delimited frontmatter through `scripts/lib/yaml-lite.sh` (no PyYAML, yq, jq, or package install). On success prints one `key=value` line per present field to stdout and exits `0`; the nested `opt-in-commands` object is flattened to `opt-in-commands.<cost-class>=<command>` lines. On a missing required field, bad enum, or malformed/absent frontmatter it writes a `read-test-config: …` diagnostic to stderr and exits `2`. Usage errors (wrong arg count, missing file, missing helper) exit `1`.

Fields and rules:

- `default-command` — **required**; a non-empty string (surrounding quotes stripped). The default-safe test command; exit 0 == green.
- `runner` — optional; informational string.
- `layout` — optional; informational string (e.g. `by-feature`, `by-tier`).
- `tiers-via` — optional; one of `{markers, directories}`.
- `opt-in-commands` — optional; an object whose keys are a subset of the closed cost-class vocabulary `{live, costly}`. Values are the commands a human runs for that opt-in tier.

## Consumer

Consumer-type: `skill` in frontmatter for the primary workflow consumers. Four downstream consumers:

- **`skills/build/SKILL.md`** (exit gate) reads `default-command` to run the suite at build exit.
- **`skills/finish/SKILL.md`** (Step 5.5) reads `default-command` for the pre-PR local gate.
- **`skills/design/SKILL.md`** (coverage-baseline mode) reads `default-command` to baseline coverage before a refactor.
- **`scripts/ci-checks.sh`** (consumer local/CI entrypoint) reads `default-command` in non-plugin roots when both `docs/specs/test-infrastructure.spec.md` and `scripts/read-test-config.sh` are installed, then runs that command as the consumer content gate.

**Consumer obligations:**

- Consumers MUST run only `default-command` in automated gates — never the `opt-in-commands` (`live`/`costly`) tiers.
- Consumers MUST distinguish initialized-invalid from uninitialized roots:
  - A present but invalid declaration MUST fail closed. If `docs/specs/test-infrastructure.spec.md` exists and the reader exits non-zero, consumers surface the reader diagnostic and stop. They MUST NOT substitute Arboretum framework checks for the adopter's product suite.
  - An absent spec means the repo is uninitialized for testing-shape purposes. `/build` and `/design` coverage-baseline fall back to native product-test discovery: `package.json` with a `test` script, then `Makefile` with `test:`, then pytest config (`pytest.ini`, `pyproject.toml`, or `setup.cfg`).
  - `/finish` does not introduce native discovery. If the spec is absent, it skips its pre-PR local gate; `/build` remains the stage responsible for proving the product-test command before work exits.
- A non-zero exit from `default-command` *itself* (once obtained) is a real test failure and MUST block the gate.
- `scripts/ci-checks.sh` MUST skip its declared-command stage in the Arboretum plugin root, where the framework's own `default-command` is `bash scripts/ci-checks.sh`; this avoids recursive self-invocation while preserving `/finish`'s normal reader path.

## Protocol shape

### Inputs
- One positional argument: the path to a `test-infrastructure.spec.md`. No stdin.

### Outputs
- stdout (exit 0 only): one `key=value` line per present field, in the fixed order `default-command`, `runner`, `layout`, `tiers-via`, `opt-in-commands`. The `opt-in-commands` object expands to one `opt-in-commands.<cost-class>=<command>` line per key.
- stderr (exit 1 or 2 only): a `read-test-config: …` (or `Usage:`/not-found) diagnostic.
- Exit codes: `0` — valid, key=value printed; `1` — usage error (wrong arg count or file not found); `2` — schema failure (missing `default-command`, bad `tiers-via`, bad `opt-in-commands` key, malformed/absent frontmatter).

### Invariants
- **Required-field gate.** stdout on exit 0 always contains a `default-command=` line.
- **Optional fields are omitted when absent** — never emitted as empty lines.
- **Flattened nested object.** `opt-in-commands` is emitted as dot-notation lines — never a bare `opt-in-commands=` scalar.
- **Closed cost vocabulary.** `opt-in-commands` keys outside `{live, costly}` are rejected (exit 2).
- **Unfilled placeholders rejected.** A `default-command` that is an angle-bracket `<placeholder>` (the value the template ships before an adopter fills it) is treated as not-yet-declared → exit 2, so a scaffolded-but-unfilled spec blocks the initialized repo's product-test gate until the adopter fills the declaration.
- **Scalar-only enums.** A dict-shaped `tiers-via` is rejected (exit 2), never silently flattened to `tiers-via.<subkey>=` lines.
- **Coexists with governed-spec metadata.** `test-infrastructure.spec.md` is a governed spec; its frontmatter also carries `version`/`name`/`status`/`owner`/`owns` (read by `generate-register.sh`). The reader reads only the test-command keys and ignores the rest, so the two schemas share one block without collision.
- **Comment semantics.** Full-line comments are ignored. Inline comments are stripped by `yaml-lite.sh`, while `#` characters inside single-quoted or double-quoted values are preserved.
- **Bare-checkout portable.** The reader does not require PyYAML, yq, jq, or any package install; it shares parser behavior through `scripts/lib/yaml-lite.sh`.
- **No mutation.** Read-only — the script never writes the spec or any file.

## Test surface

- **TC-1:** Valid spec with all fields → exit 0; stdout includes `default-command=`, `runner=`, `layout=`, `tiers-via=`.
- **TC-2:** `opt-in-commands` flattened to `opt-in-commands.live=…` / `opt-in-commands.costly=…`; no bare `opt-in-commands=` line.
- **TC-3:** Missing `default-command` → exit 2, no stdout, stderr diagnostic.
- **TC-4:** `tiers-via` out of enum → exit 2.
- **TC-5:** `opt-in-commands` key out of enum (e.g. `eval`) → exit 2.
- **TC-6:** Missing file → exit 1; no frontmatter at all → exit 2.
- **TC-7:** Optional fields absent → only the `default-command` line emitted.
- **TC-8:** Read-only — the spec file's content is unchanged after invocation.
- **TC-9:** A quoted `default-command` is printed unquoted.
- **TC-10:** Full-line `#` comments interleaved with fields are ignored; value lines still parse and no `#` leaks into output.
- **TC-11:** An unfilled angle-bracket `<placeholder>` `default-command` → exit 2, no stdout.
- **TC-12:** A dict-shaped `tiers-via` → exit 2 (not flattened to `tiers-via.<subkey>=`).

## Versioning

- **1.3** (2026-06-03) - `scripts/ci-checks.sh` is now a script consumer in non-plugin roots: it runs the declared `default-command` when available and skips the stage in the plugin root to avoid recursive self-invocation.
- **1.2** (2026-06-02) - present-but-invalid declarations now fail closed; Arboretum `ci-checks.sh` is not a product-test fallback for initialized adopter repos. Design: adopter-ci-boundary.
- **1.1** (2026-06-01) - parser moved onto shared `yaml-lite.sh` helper for Issue #437.
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/read-test-config.sh` on this branch. Design: testing-shape.
