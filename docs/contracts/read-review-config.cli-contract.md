---
script: scripts/read-review-config.sh
version: 1.0
invokers:
  - type: script
    name: scripts/request-review.sh
  - type: skill
    name: arboretum:/request-review
  - type: script
    name: scripts/_smoke-test-read-review-config.sh
  - type: script
    name: scripts/_smoke-test-contract-review-config.sh
related-designs:
  - docs/superpowers/specs/2026-06-04-request-review-config-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-review-config.sh`

## Surface

Read-only normaliser for the `review:` block in `.arboretum.yml`. Parses the
block via the shared YAML-lite helper and prints one `key=value` line per
field, re-keying the `ai_reviewers` sequence-of-maps from the parser's
`review.ai_reviewers[N].<field>` form into `ai_reviewer.<name>.<field>`. It is
the single producer of the reviewer-config key form that `request-review.sh`
consumes; the coupling is guarded by `_smoke-test-contract-review-config.sh`.

## Protocol

### Arguments

```
read-review-config.sh
```

No arguments. Reads `./.arboretum.yml` from the current working directory.

### Output

`key=value` lines on stdout:

- `default_request_policy=<always|never|complexity-gated>`
- `re_review_condition=<never|unresolved-only|substantive-only|always>`
- `ai_reviewer.<name>.<request|re_request|cadence>=<value>` (per enabled reviewer)
- `human_reviewers=<comma-separated logins or empty>`
- `design_doc_policy.reviewers=<comma-separated names>` — reviewers requested
  for the design-doc PR class (`#935`); empty when unset.
- `design_doc_policy.bypass_complexity_gate=<true|false>` — default `false`.

When the `review:` block is absent, prints only the two policy defaults and a
single `warn:` line to stderr.

### Exit codes

- `0` — block parsed, or block absent (graceful defaults printed; stderr warn).
- `1` — `.arboretum.yml` missing, YAML-lite helper missing, invalid YAML, or an
  invalid enum value (the error names the offending key).

### Side effects

Read-only. Writes only stdout/stderr. No git, no network.

## Test surface

- **CLI-1: Full block.** A complete `review:` block emits the policy lines plus
  `ai_reviewer.<name>.<field>` lines for each reviewer, with values preserved.
- **CLI-2: Graceful absence.** A config with no `review:` block exits `0`,
  prints the two policy defaults, and warns on stderr.
- **CLI-3: Invalid enum.** An out-of-enum value (e.g. `re_review_condition`)
  exits non-zero with an error naming the key.
- **CLI-4: Missing config.** A missing `.arboretum.yml` exits non-zero rather
  than crashing.
