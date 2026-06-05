---
script: scripts/resolve-workflow-slot.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/cleanup
  - type: script
    name: scripts/_smoke-test-resolve-workflow-slot.sh
related-designs:
  - docs/superpowers/specs/2026-06-05-workflow-skill-slots-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/resolve-workflow-slot.sh`

## Surface

`scripts/resolve-workflow-slot.sh` resolves a known Arboretum-owned workflow skill slot to a slash-style skill target. It is the translation layer between repo policy in `.arboretum.yml` and workflow skill handoffs. The resolver does not execute the configured value; it treats the value as a skill identifier, resolves the corresponding `SKILL.md`, and requires that skill to declare compatibility through `implements-slots`.

The first supported slot is `ship-tail.reflect`, whose default target is `/reflect`.

## Protocol

### Arguments

```bash
bash scripts/resolve-workflow-slot.sh <slot> [--config <path>] [--repo-root <path>]
```

- `<slot>` - Required. Arboretum-owned workflow slot ID. Unknown slots fail closed.
- `--config <path>` - Optional. YAML-lite config file to read. Defaults to `<repo-root>/.arboretum.yml`. A missing default config is allowed; a missing explicit config is an invocation error.
- `--repo-root <path>` - Optional. Root used to resolve project-local skill files. Defaults to the current git toplevel, or current working directory outside a git repo.
- `--help` - Prints usage and exits 0.

Unknown options, missing option values, missing slot, and extra positional arguments exit 2.

### Config

The resolver reads the YAML-lite key `workflow.skill_slots.<slot>`.

Example:

```yaml
workflow:
  skill_slots:
    ship-tail.reflect: /reflect-dev
```

If the config entry is absent, the slot default is used. If the config entry is present, the configured value must pass all target validation checks. Invalid configured values never fall back to the default.

Targets must match slash-style lowercase kebab syntax:

```text
/[a-z][a-z0-9-]*
```

### Target lookup

The slash target `/name` resolves to the first matching skill file in this order:

1. `<repo-root>/skills/name/SKILL.md`
2. `<repo-root>/.claude/skills/name/SKILL.md`
3. `$CLAUDE_PLUGIN_ROOT/skills/name/SKILL.md`, when `CLAUDE_PLUGIN_ROOT` is set

The target skill frontmatter must contain:

```yaml
implements-slots:
  - <slot>
```

### Output

On success, stdout contains only stable key-value lines:

```text
slot=ship-tail.reflect
target=/reflect
source=default
status=resolved
skill_path=skills/reflect/SKILL.md
```

With a configured target, `source=.arboretum.yml`.

### Exit codes

- `0` - Slot resolved and target skill declares compatibility.
- `1` - Known slot failed validation or target resolution: invalid target syntax, missing skill file, invalid skill frontmatter, or missing `implements-slots` entry.
- `2` - Invocation/setup problem: missing arguments, unknown options, missing explicit config, missing repo root, or missing YAML-lite helper.

### Side effects

The resolver is read-only. It does not mutate config, skills, tracker state, generated docs, or repository metadata. It does not execute configured target strings.

## Test surface

- **CLI-1: Default target.** With no config override, `ship-tail.reflect` resolves to `/reflect`, `source=default`, and the public `skills/reflect/SKILL.md` target.
- **CLI-2: Dev-only configured target.** With `workflow.skill_slots.ship-tail.reflect: /reflect-dev`, the resolver finds `.claude/skills/reflect-dev/SKILL.md` and emits `source=.arboretum.yml`.
- **CLI-3: Bad target syntax.** A configured target without a leading slash fails non-zero and names slash-style syntax.
- **CLI-4: Empty target.** A present config key with an empty value fails non-zero and names slash-style syntax instead of falling back to the default.
- **CLI-5: Missing target.** A configured slash target with no matching skill file fails non-zero and names the missing target.
- **CLI-6: Incompatible target.** A configured skill whose frontmatter lacks `implements-slots: ship-tail.reflect` fails non-zero and names the missing metadata.
- **CLI-7: Unknown slot.** An unrecognized slot ID fails non-zero and names the unknown workflow skill slot.

These assertions are covered by `scripts/_smoke-test-resolve-workflow-slot.sh`.

## Versioning

- **1.0** - Initial workflow slot resolver contract for issue #555 (2026-06-05).
