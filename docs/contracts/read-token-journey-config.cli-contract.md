---
script: scripts/read-token-journey-config.sh
version: 1.1
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
`key=value` lines on stdout. An absent block or absent keys yield built-in
defaults (`enabled=false`, `format=md`, and a device-stable
`output_dir=<state-dir>/token-journey` resolved via `scripts/lib/state-dir.sh`
— the main checkout's `.arboretum`, not the invoking worktree's, #673/D27) —
never an error. An explicit `token_journey.output_dir` overrides the default verbatim. `enabled` gates only *automatic* journey-report generation; the
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
  block emits `enabled=false`, `format=md`, and a device-stable
  `output_dir=<main-checkout>/.arboretum/token-journey` (absolute, resolved via
  `state-dir.sh`), not the bare cwd-relative `.arboretum/token-journey`.
- **CLI-2: values when present.** A config file with a populated `token_journey:`
  block emits the configured `enabled`/`output_dir`/`format`.

Covered by `scripts/_smoke-test-token-journey.sh`.

## Versioning

- **1.0** — initial contract: token_journey config reader with inert defaults (2026-06-07).
- **1.1** — default `output_dir` is now device-stable, anchored at the main
  checkout via `state-dir.sh` (#673/D27); explicit config still overrides verbatim (2026-06-08).
