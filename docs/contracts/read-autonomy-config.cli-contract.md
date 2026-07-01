---
script: scripts/read-autonomy-config.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-read-autonomy-config.sh
  - type: skill
    name: skills/design/SKILL.md
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-28-autonomy-grant-foundation-design.md
---
<!-- owner: autonomy-grants -->

# Contract for `scripts/read-autonomy-config.sh`

## Surface

Reads the `autonomy:` block of `.arboretum.yml` (the autonomy-grant gate
configuration, #915 D7) and emits the gate parameters as a flat `key=value`
protocol on stdout. The single authoritative source for every gate parameter;
#915 slices 2–5 read their thresholds through this reader rather than embedding
defaults in skill prose.

## Protocol

### Arguments

```
read-autonomy-config.sh [<config-file>]
```

- `<config-file>` (positional, optional) — path to the YAML config; defaults to
  `.arboretum.yml` in the current directory. Parsed via `scripts/lib/yaml-lite.sh`.

Output is six newline-delimited `key=value` records, in this order:

```
default_grant=<pause-at-land|pause-at-merge|auto-merge>
ci_hard_fail_attempts=<positive integer>
thrash_window_rounds=<positive integer>
cost_ceiling_tokens=<positive integer>
cost_ceiling_overridable=<true|false>
auto_merge_enabled=<true|false>
```

When the block, or any individual key, is absent, the documented conservative
defaults are applied: `default_grant=pause-at-merge`, `ci_hard_fail_attempts=2`,
`thrash_window_rounds=3`, `cost_ceiling_tokens=500000`,
`cost_ceiling_overridable=true`, `auto_merge_enabled=false`.

The producer enforces these obligations before emitting:

- **Trigger floor — tunable, not removable (#915 D3/D7).** Each of
  `ci_hard_fail_attempts`, `thrash_window_rounds`, `cost_ceiling_tokens` must be a
  positive integer; `0`, negative, or non-numeric is rejected (exit 1) with a
  diagnostic naming "positive integer".
- **`default_grant` closed vocabulary.** Must be one of
  `pause-at-land|pause-at-merge|auto-merge`; `design-only` (the absence of a
  grant) and any other value are rejected (exit 1).
- **Booleans.** `cost_ceiling_overridable` and `auto_merge_enabled` must be
  `true` or `false`.

Consumer obligations: recover a parameter by matching the `<key>=` prefix; treat
a non-zero exit as "configuration invalid — stop", never as "use defaults".

### Exit codes

- `0` — config read and validated; the six parameters printed to stdout.
- `1` — config not found, invalid YAML-lite (fail closed — never read as
  "absent → defaults"), or a validation failure (the offending key named on
  stderr).

### Side effects

Read-only. Writes only to stdout/stderr, performs no git operations, makes no
network calls, and mutates no tracker state.

## Test surface

- **CLI-1: Conservative defaults.** An `.arboretum.yml` with no `autonomy:` block
  emits all six documented defaults, including `auto_merge_enabled=false`.
- **CLI-2: Full + partial blocks.** A fully-specified block round-trips its
  values; a partial block defaults only the unspecified keys.
- **CLI-3: Floor guarantee.** A trigger threshold of `0`, negative, or
  non-numeric is rejected (exit 1) with a "positive integer" diagnostic, for
  every trigger key.
- **CLI-4: Closed vocabulary.** A `default_grant` outside the three tiers
  (including `design-only`) is rejected.
- **CLI-5: Boolean validation.** A non-`true`/`false` `auto_merge_enabled` /
  `cost_ceiling_overridable` is rejected.
- **CLI-6: Fail closed / missing.** Malformed YAML-lite and a missing config
  file both exit 1 with a named diagnostic.

Covered by `scripts/_smoke-test-read-autonomy-config.sh`.

## Versioning

- **1.0** — initial contract for the `.arboretum.yml autonomy:` reader (#917, 2026-06-28).
