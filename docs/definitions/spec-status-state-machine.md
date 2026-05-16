---
name: spec-status-state-machine
version: v1
status: active
---

# Spec Status State Machine

## Status
active

## Version
v1

## Description

Every governed spec carries a `status:` field in its YAML frontmatter.
The value moves through a three-state machine. The transitions are
implemented across `/consolidate` and `scripts/health-check.sh` (Check 7);
this definition formalises the machine so those surfaces cannot drift on
the state vocabulary or the mutation contract.

## Schema

States: `draft`, `active`, `stale`.

Transitions:

| From | To | Trigger | Automatic? |
|------|----|---------|-----------|
| (none) | `draft` | spec first created | n/a — birth state |
| `draft` | `active` | `/consolidate` reconciles spec against built code | yes |
| `stale` | `active` | `/consolidate` reconciles after drift is repaired | yes |
| `active` | `stale` | `health-check.sh` Check 7 detects an owned file committed after the spec | yes |

There is no manual transition. `draft` is written by hand only when the
spec file is first authored; every later transition is automatic.

The status lives in frontmatter as `status: <state>`. Some pre-Path-B
specs carried a legacy `## Status` markdown block instead; Check 7's
mutation supports both shapes, but new specs MUST use the frontmatter
form and the legacy block is deprecated.

## Constraints

- Check 7's mutation is a `sed` substitution on the `Status` column of
  `REGISTER.md` and on `status:` in spec frontmatter. The state tokens
  must remain `sed`-safe (`[A-Za-z0-9_-]+`) — see the status-enum
  validation in `project-infrastructure.spec.md`.
- A project may override the vocabulary via `.arboretum.yml`
  `status_enum:` (`states:`, `active_states:`, `stale_state:`). The
  canonical machine above is the default when no override is present.
- Check 6 warns on any spec whose `status:` is outside the active
  vocabulary — the typo signal.

## Changelog

| Date | Version | Change | Affected Specs |
|------|---------|--------|----------------|
| 2026-05-16 | v1 | Initial definition — formalises the draft/active/stale machine (issue #143). | project-infrastructure |
