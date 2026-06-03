---
script: scripts/read-release-intent.sh
version: 1.0
invokers:
  - type: script
    name: scripts/check-release-gate.sh
  - type: script
    name: scripts/prepare-release-package.sh
  - type: skill
    name: /pr
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-03-release-intent-lane-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-release-intent.sh`

## Surface

Parses the `## Release Intent` section from a pull request body or from a
GitHub pull-request event JSON file and emits a stable key/value protocol.
Usage:
`scripts/read-release-intent.sh (--body-file <path> | --github-event <path>)`.
The parser is read-only and is the authoritative interpretation of
`release-impact` and `release-state` for release gates, PR creation, and
Release Package preparation.

## Protocol

### Arguments

- `--body-file <path>` - reads Markdown body text from `<path>`.
- `--github-event <path>` - reads JSON from `<path>` and parses
  `.pull_request.body`.

Exactly one input mode is required. `--help` prints usage and exits 0. Unknown
flags, missing flag values, multiple input modes, or missing input files are
invocation errors.

### Exit codes

- `0` - a valid Release Intent section was parsed and emitted.
- `1` - the input was readable but semantically invalid: missing section,
  malformed line, duplicate key, missing required key, unknown key, invalid
  value, invalid impact/state combination, invalid JSON, or missing
  `pull_request.body`.
- `2` - invocation problem: missing arguments, unknown flags, multiple input
  modes, unsupported internal mode, or missing input file.

### Side effects

Read-only. The script reads the supplied file, parses text with embedded
Python 3, and writes only to stdout/stderr. It performs no git operations, no
network calls, and no filesystem writes.

## Test surface

- **CLI-1: Valid pending impact.** A body containing `release-impact: patch`
  and `release-state: pending` exits 0 and emits `release-impact=patch`,
  `release-state=pending`, and `source=body`.
- **CLI-2: Explicit none.** A body containing `release-impact: none` and
  `release-state: not-needed` exits 0 and emits `release-impact=none`.
- **CLI-3: Missing section.** A body without `## Release Intent` exits 1 and
  emits `release intent section missing`.
- **CLI-4: Invalid impact.** A body with an impact outside
  `none|patch|minor|major` exits 1 and emits `invalid release-impact`.
- **CLI-5: Invalid state.** A body with a state outside
  `not-needed|pending|materialized` exits 1 and emits `invalid release-state`.
- **CLI-6: Duplicate key.** A body with duplicate `release-impact` or
  `release-state` exits 1 and names the duplicate key.
- **CLI-7: GitHub event body.** A GitHub event JSON file with
  `.pull_request.body` containing valid release intent exits 0 and emits
  `source=github-event`.

## Versioning

- **1.0** - initial release-intent parser contract (2026-06-03).
