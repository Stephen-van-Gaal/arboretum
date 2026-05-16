---
name: contracts-yaml-schema
version: v1
status: active
---

# contracts.yaml Schema

## Status
active

## Version
v1

## Description

`contracts.yaml` (repo root) maps each spec to the shared-definition
versions it depends on or provides. It is produced by
`scripts/sync-contracts.sh` from spec `## Requires` / `## Provides`
sections and consumed by `scripts/health-check.sh` (Check 4 — pins vs.
spec tables; Check 5 — pins vs. definition `## Version`) and
`scripts/validate-cross-refs.sh` (Check 3). This definition promotes the
header-comment block in `docs/templates/contracts.yaml` to a first-class
contract.

## Schema

A single top-level `specs:` map. Each key is a spec name **without** the
`.spec.md` suffix. Each spec entry may contain:

- `requires:` — a map of `<definition-path>: <version>`.
- `provides:` — a map of `<definition-path>: <version>`.

`<definition-path>` is repo-relative-to-`docs/`, e.g.
`definitions/register-schema.md`. `<version>` is a `v<N>` token.

When no spec references any definition, the `specs:` mapping is empty —
rendered as `specs: {}` — preceded by the auto-generated header comment
block that `sync-contracts.sh` always emits.

Example:

```yaml
specs:
  project-infrastructure:
    requires:
      definitions/register-schema.md: v1
    provides:
      definitions/register-schema.md: v1
```

## Constraints

- The file is auto-generated. Hand edits are overwritten by the next
  `sync-contracts.sh` run; edit spec `## Requires`/`## Provides` sections
  instead.
- A `requires:` pin must match the spec's `## Requires` reference and the
  definition's `## Version` — Check 4 and Check 5 enforce both halves.
- Indentation is two spaces per level; consumers grep by indentation.

## Changelog

| Date | Version | Change | Affected Specs |
|------|---------|--------|----------------|
| 2026-05-16 | v1 | Initial definition — promotes the contracts.yaml template comment block (issue #143). | project-infrastructure |
