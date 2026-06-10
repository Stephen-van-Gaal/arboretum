---
script: scripts/validate-group-membership.sh
version: 1.0
invokers:
  - type: developer
  - type: ci
related-designs:
  - docs/superpowers/specs/2026-06-09-group-spec-layer-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/validate-group-membership.sh`

## Surface

Validates the group-spec layer's structural invariants over `docs/groups/*.md` and the
specs/groups they reference. Enforces (1) bidirectional `parent:`/`contains:` integrity and
(2) the group `owns:` ⇄ declared-owner round-trip for thin orchestration glue (D7). Glue may
be a `.sh` (line-2 `# owner:`) or a `skills/*/SKILL.md` umbrella dispatcher (YAML frontmatter
`owner:`); both shapes are validated forward and reverse. Frontmatter is parsed by the shared
`scripts/lib/yaml-lite.sh` (flow **and** block lists); an unparseable group doc or referenced
child is a violation, not a mid-run abort. Read-only.

## Protocol

### Arguments

```
bash scripts/validate-group-membership.sh [project-dir]
```

- `[project-dir]` — optional project root; defaults to `git rev-parse --show-toplevel` else `pwd`.

No flags, no stdin.

### Exit codes

- `0` — all group-membership invariants hold (including the vacuous case: no `docs/groups/` or no group docs).
- `1` — one or more violations: orphan `contains:` (child doc missing), missing `parent:` (child does not back-declare), dangling `parent:` (named group missing), or a group-owned glue file whose `# owner:` does not match / is absent from the group's `owns:`.

### Side effects

None. Emits one `FAIL:` line per violation to stderr and a summary to stdout.

## Test surface

`scripts/_smoke-test-group-membership.sh` — fixtures under `scripts/_fixtures/group-membership/`: valid group+child pair; orphan contains; missing parent; dangling parent; D7 glue (owner resolves + round-trips; glue absent from `owns:` fails).
