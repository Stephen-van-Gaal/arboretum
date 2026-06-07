---
script: scripts/read-token-journey-config.sh
version: 1.0
invokers:
  - type: script
    name: scripts/token-report.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-07-token-journey-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-token-journey-config.sh`

## Surface

Reads the `token_journey:` block from `.arboretum.yml` (via the shared
`scripts/lib/yaml-lite.sh` parser) and emits `enabled`/`output_dir`/`format` as
`key=value` lines on stdout. An absent block or absent keys yield inert built-in
defaults (`enabled=false`, `output_dir=.arboretum/token-journey`, `format=md`) —
never an error. `enabled` gates only *automatic* journey-report generation; the
`token-report.sh journey` subcommand is always runnable by hand. Mirrors
`scripts/read-patch-lane-config.sh`.

## Protocol

### Arguments

```
read-token-journey-config.sh [<config-file>]
```

- `<config-file>` *(optional, default `.arboretum.yml`)* — path to the YAML-lite
  config file. An absent file yields all defaults.

### Exit codes

- `0` — config read (or defaulted); three `key=value` lines printed.
- `1` — config present but not valid YAML-lite, or `enabled` not `true|false`,
  or `format` not `md|json`, or the yaml-lite helper is missing.

### Side effects

Read-only. Spawns the `yaml-lite.sh` parser (`python3`) over the named config
file. Writes nothing to disk and makes no network calls.

## Test surface

- **CLI-1: defaults when key absent.** A config file without a `token_journey:`
  block emits `enabled=false`, `output_dir=.arboretum/token-journey`, `format=md`.
- **CLI-2: values when present.** A config file with a populated `token_journey:`
  block emits the configured `enabled`/`output_dir`/`format`.

Covered by `scripts/_smoke-test-token-journey.sh`.

## Versioning

- **1.0** — initial contract: token_journey config reader with inert defaults (2026-06-07).
