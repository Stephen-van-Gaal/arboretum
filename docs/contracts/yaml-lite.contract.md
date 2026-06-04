---
seam: yaml-lite
version: 1.2
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces:
  - yaml-lite-line-protocol
related-designs:
  - docs/superpowers/specs/2026-06-01-runtime-portability-design.md
owns:
  - scripts/lib/yaml-lite.sh
---
<!-- owner: pipeline-contracts-template -->

# yaml-lite - Shared YAML/frontmatter Parser Contract

`scripts/lib/yaml-lite.sh` is the shared parser for Arboretum governance
scripts that need a deliberately small YAML subset without requiring PyYAML,
yq, jq, or any package installation.

## Producer

`scripts/lib/yaml-lite.sh` - producer-type: `script`.

The helper is both callable and sourceable. As a CLI it accepts either `file`
mode, which parses the entire input file, or `frontmatter` mode, which parses
the leading `---` delimited frontmatter block from a Markdown file. It uses
Python 3 standard library only.

Supported syntax:

- Top-level scalar keys, including quoted keys.
- One-level mappings such as `pipeline.workflow` and `test-tiers.unit`.
- Block lists such as `owns:`.
- One-level list-of-mapping entries such as `invokers:`.
- Simple flow mappings such as `pipeline: { workflow: unified }`.
- Simple flow lists such as `owns: [scripts/foo.sh]`.
- Simple flow list-of-mapping entries such as `invokers: [{type: hook}, {type: developer}]`.
- Inline comments, preserving `#` characters inside single-quoted or double-quoted strings.
- Bounded double-quoted spans inside plain scalars, preserving `#` characters in shell-command fragments such as `pytest -k "unit#fast"`.
- Simple quoted scalar unwrapping.

Unsupported or unsafe syntax exits non-zero with a `yaml-lite:` stderr
diagnostic. The helper does not silently repair syntax it cannot safely
normalize.

## Consumer

Consumer-type: `script`.

Consumers read the normalized line protocol and apply their own schema:

- `scripts/read-pipeline-flag.sh` reads `pipeline.workflow`.
- `scripts/read-s2-frontmatter.sh` reads S2 input frontmatter and emits build-dispatch fields.
- `scripts/read-test-config.sh` reads the governed test-command declaration.
- `scripts/validate-design-spec.sh` reads S2 frontmatter fields and emits `S2-DRIFT:` diagnostics.
- `scripts/validate-cli-contract.sh` reads CLI-contract frontmatter fields and emits `CLI-CONTRACT-DRIFT:` diagnostics.
- `scripts/generate-coverage.sh` reads `owns[]` and `script` fields when regenerating `docs/contracts/_coverage.md`.

Consumers must not reimplement comment stripping, quote stripping, block-list
parsing, one-level mapping parsing, or list-of-mapping parsing.

## Protocol shape

### Inputs

- CLI mode `file`: positional argument 2 is a YAML-lite file.
- CLI mode `frontmatter`: positional argument 2 is a Markdown file with leading frontmatter.
- No stdin.

### Outputs

stdout line protocol:

- `key=value` for scalar fields.
- `key[]=value` for block-list entries.
- `key.subkey=value` for one-level mappings.
- `key[0].subkey=value` for one-level list-of-mapping entries.

stderr:

- `yaml-lite: ...` diagnostics on invocation, missing file, missing frontmatter, or unsupported syntax.

Exit codes:

- `0` - parsed successfully.
- `1` - input exists but cannot be parsed safely.
- `2` - invocation problem or missing file.

### Invariants

- No external Python packages are imported.
- Output order is deterministic and follows source order.
- Comment stripping preserves `#` inside quotes.
- Quoted scalars are emitted without surrounding quotes.
- Apostrophes inside unquoted plain scalars are literal content.
- Indented keys require a mapping/list-mapping parent at the immediately preceding indent level.
- The helper is read-only.

## Test surface

- **YL-1:** full-file block mapping `pipeline.workflow: unified` emits `pipeline.workflow=unified`.
- **YL-2:** flow mapping `pipeline: { workflow: 'unified' }` emits `pipeline.workflow=unified`.
- **YL-3:** inline comments are stripped, but `#` inside quotes is preserved.
- **YL-4:** frontmatter block lists emit `owns[]=...` lines.
- **YL-5:** frontmatter nested mappings emit `test-tiers.unit=yes` style lines.
- **YL-6:** list-of-mapping entries emit `invokers[0].type=skill` style lines.
- **YL-7:** missing frontmatter in `frontmatter` mode exits non-zero with `yaml-lite:`.
- **YL-8:** the helper still passes when `import yaml` is blocked by a `sitecustomize.py` import hook.
- **YL-9:** unquoted plain scalars may contain apostrophes without opening quote mode.
- **YL-10:** `#` inside a bounded double-quoted span within a plain scalar is preserved.
- **YL-11:** flow-style lists emit the same line protocol as block lists and list-of-mapping entries.
- **YL-12:** an indented key below a scalar parent exits non-zero with `yaml-lite:`.

## Versioning

- **1.2** (2026-06-01) - preserve quoted hashes inside command scalars, normalize flow-style lists, and reject indented keys without mapping parents. Issue #437.
- **1.1** (2026-06-01) - treat apostrophes inside plain scalars as literal content. Issue #437.
- **1.0** (2026-06-01) - initial contract. Issue #437.
