---
script: scripts/resolve-codex-companion.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/finish
  - type: script
    name: scripts/_smoke-test-contract-resolve-codex-companion.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-14-codex-reviewer-path-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/resolve-codex-companion.sh`

## Surface

Prints the absolute path to the installed codex plugin's
`scripts/codex-companion.mjs`, resolved version-independently by scanning plugin
manifests under the plugin cache for the plugin whose declared `"name"` is
`codex`. Used by the `reviewers.yml` codex runtime row so its `invoke` resolves
to a real path regardless of cached plugin version. Read-only; no network.

## Protocol

### Arguments

```
resolve-codex-companion.sh
```

No positional arguments.

### Environment

- `ARBO_PLUGIN_CACHE` (optional) — override the plugin-cache root scanned.
  Defaults to `$HOME/.claude/plugins/cache`. Used by tests for hermetic fixtures.

### Exit codes

- `0` — a codex companion was found; its absolute path is printed to stdout
  (single line). When multiple cached versions match, the highest version wins
  (`sort -V`).
- `1` — no codex plugin / companion found; stdout empty, one-line diagnostic on
  stderr. Callers degrade (the section-dispatch "codex deferred" path).

### Side effects

Read-only. Writes only stdout/stderr; creates no files, no git, no network.

## Test surface

- **CLI-1: Found.** A cache fixture containing a plugin whose top-level `name`
  is `codex` with a `scripts/codex-companion.mjs` resolves to that companion's
  absolute path and exits 0.
- **CLI-2: Not found.** A cache fixture with no codex plugin exits non-zero with
  empty stdout.
- **CLI-3: Highest version wins.** When multiple cached versions match, the
  highest version (`sort -V`) is returned (e.g. `1.10.0` over `1.2.0`).
- **CLI-4: Top-level name only.** A plugin whose top-level `name` is not `codex`
  but whose nested `author.name` is `codex` is NOT selected — only the top-level
  key matches.

Assertions live in `scripts/_smoke-test-contract-resolve-codex-companion.sh`.

## Versioning

Schema version `1.0`. Resolves the codex companion by top-level plugin name from
the plugin-cache manifests. Additive, backward-compatible changes (e.g. an extra
fallback discovery source) bump the minor version. Changes to the output
contract (what is printed, exit-code semantics, or the selection rule) bump the
major version and update the CLI-N test surface in lockstep.
