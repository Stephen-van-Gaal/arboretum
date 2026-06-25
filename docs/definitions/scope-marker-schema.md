---
name: scope-marker-schema
version: v1
status: active
---

# Scope Marker Schema

## Status
active

## Version
v1

## Purpose

`# scope:` declares a file's **governance scope** — which root's governance owns it.
It is the primary signal every consumer-facing check consults before demanding an
owning spec, `owns:` coverage, or smoke execution. It is independent of
`.arboretum/install-manifest.json`, so it holds even when the manifest is absent.

## Placement

- `.sh` scripts and `bin/*` executables: a `# scope: <value>` comment line within
  the first 8 lines (conventionally line 3, immediately after `# owner:`).
- `skills/*/SKILL.md`: a `scope: <value>` key in the YAML frontmatter.

## Vocabulary

| Value | Consumer root | Plugin root |
|-------|---------------|-------------|
| `plugin-only` | Framework-governed — ownership / `owns:` / smoke checks SKIP the file. | Ignored; full enforcement. |
| `consumer` | Adopter-governed — enforce normally. | Full enforcement. |
| `any` | Applicable everywhere — enforce. | Full enforcement. |
| *(absent)* | Fall back to manifest membership, then owner-resolution. | Full enforcement. |

## Invariants

- Governance scope, not runtime scope: `plugin-only` files still run in adopters.
- A plugin root (`is_plugin_root`) ignores the marker entirely.
- Reading is single-sourced in `scripts/lib/scope-resolve.sh`; consumers
  (`ci-checks.sh`, `health-check.sh`) MUST NOT re-inline the `# scope:` regex.
