---
script: scripts/resolve-stage-model.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-contract-resolve-stage-model.sh
  - type: skill
    name: skills/cleanup/SKILL.md
  - type: skill
    name: skills/land/SKILL.md
  - type: skill
    name: skills/ai-surface-review/SKILL.md
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-28-pipeline-model-routing-design.md
---
<!-- owner: skill-and-agent-authoring -->

# Contract for `scripts/resolve-stage-model.sh`

## Surface

Resolves a stage's effective model in fixed precedence and emits the concrete
model id (or the literal `SESSION_DEFAULT` when no floor applies). The four
shipped read-only drivers run it at their dispatch site and pass the emitted id
as the dispatch tool's `model` parameter, omitting the parameter when
`SESSION_DEFAULT`. Reads frontmatter/config through the shared
`scripts/lib/yaml-lite.sh` parser and sources `scripts/lib/model-families.sh`
for the family→id mapping.

## Protocol

### Arguments

```
resolve-stage-model.sh <skill-name> [--skills-root DIR] [--config FILE]
```

- `<skill-name>` (positional, required) — the dispatching stage's skill name
  (e.g. `cleanup`). Missing → exit 2 with a usage diagnostic.
- `--skills-root DIR` (optional) — skills directory root; defaults to the
  repo `skills/`.
- `--config FILE` (optional) — config file to read overrides from; defaults to
  the repo `.arboretum.yml`.

### Precedence

1. **Override** — `workflow.stage_models.<skill-name>` in the config file.
2. **Floor** — the skill's frontmatter `default-model`.
3. **Fallback** — `SESSION_DEFAULT` (the caller omits the `model` param).

### Output

A single line on stdout: the concrete model id (via `model-families.sh`) or
`SESSION_DEFAULT`.

## Invariants

- Precedence is override ?? floor ?? `SESSION_DEFAULT`.
- An invalid family at any layer fails loud (propagates the `model-families.sh`
  non-zero exit), never silently falling back to session default.
- A **present** config or skill file that cannot be parsed fails loud (exit 2) —
  only a grep no-match (key absent) is a legitimate empty layer. A malformed
  `.arboretum.yml` must not silently drop the override.
- The skill name is constrained to `[a-z0-9_-]+`; anything else exits 2 (keeps
  the override grep pattern literal and closes the regex-metachar/ReDoS surface).
- No new YAML dependency — frontmatter/config parsing reuses `yaml-lite.sh`.
