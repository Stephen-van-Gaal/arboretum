<!-- owner: pipeline-contracts-template -->
---
# Template — copy this to docs/contracts/<script-name>.cli-contract.md
# and fill in. Required fields per WS5 design §D2.
script: scripts/<name>.sh          # path to the script being contracted
version: 1.0                        # semver-light per WS3a §D7
invokers:                           # list of who invokes this script
  - type: skill                     # type+name pair for typed invokers
    name: /init
  - type: developer                 # bare 'type: developer' for human invocation
related-designs:
  - docs/superpowers/specs/<design-spec-filename>.md
---

# Contract for `scripts/<name>.sh`

## Surface

<One paragraph: what the script does, CLI signature, what it touches, when you'd run it.>

## Protocol

### Arguments

<Positional + named flags + variadic. Document each.>

### Exit codes

- `0` — success
- `1` — <documented failure mode>
- `2` — <documented failure mode>

### Side effects

<Files written or modified, processes spawned, network calls. Read-only scripts state "Read-only — no side effects.">

## Test surface

- **CLI-1:** <one observable invariant the contract test asserts>
- **CLI-2:** <another invariant>
- ...

## Versioning

- **1.0** — initial contract (<YYYY-MM-DD>)
