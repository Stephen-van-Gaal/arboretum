---
name: register-schema
version: v1
status: active
---

# Register Schema

## Status
active

## Version
v1

## Description

`docs/REGISTER.md` is the generated index of every governed spec, its
status, owner group, and owned source files — plus an index of shared
definitions. It is produced by `scripts/generate-register.sh` and consumed
by `scripts/health-check.sh` (Checks 2, 3, 7) and
`scripts/validate-cross-refs.sh` (Check 2). This definition formalises the
file's structure so producer and consumers cannot silently drift — the
hazard class that caused bug #124.

## Schema

`REGISTER.md` contains five sections in fixed order:

1. `## Definitions Index` — table header
   `| Name | Version | Status | Provided By | Required By |`. One row per
   `docs/definitions/*.md`. When the directory is absent or empty the
   header is still emitted, followed by `<!-- No shared definitions yet. -->`.
2. `## Spec Index` — table header
   `| Spec | Status | Owner | Owns (files/directories) |`. One row per
   `docs/specs/*.spec.md`. `Owns` is a comma-separated list of
   backtick-wrapped paths; an empty list renders as the em-dash `—`.
3. `## Status Summary` — table `| Status | Count |`. Canonical states
   (`draft`, `active`, `stale`) in lifecycle order first, then extras
   alphabetically.
4. `## Unowned Code` — should always be empty.
5. `## Dependency Resolution Order` — topological spec order.

## Constraints

- The `Spec Index` header is the schema contract: exactly four columns,
  ordered `Spec | Status | Owner | Owns`. Consumers parse positionally.
- Spec rows begin `| ` and a filename ending `.spec.md`.
- The `Status` column value is the mutation target for `health-check.sh`
  Check 7 — see the `spec-status-state-machine` definition.
- `Owns` paths are backtick-wrapped; consumers strip backticks before
  path comparison. Glob patterns end in `**`.

## Changelog

| Date | Version | Change | Affected Specs |
|------|---------|--------|----------------|
| 2026-05-16 | v1 | Initial definition — formalises the existing REGISTER.md schema (issue #143). | project-infrastructure |
