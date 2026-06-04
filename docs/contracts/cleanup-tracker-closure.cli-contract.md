---
script: scripts/cleanup-tracker-closure.sh
version: 1.0
invokers:
  - type: skill
    name: /cleanup
related-designs:
  - docs/superpowers/specs/2026-06-04-interactive-tracker-close-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/cleanup-tracker-closure.sh`

## Surface

Non-interactive helper for `/cleanup` tracker closure. It classifies supplied
tracker candidates after a merged/completed PR, and it closes exactly one issue
only when invoked with `close --confirm-close`.

## Protocol

### Arguments

- `classify --pr <pr-number> --issue <issue-number> [--issue <issue-number>...]`
- `close --pr <pr-number> --issue <issue-number> --confirm-close`

### Outputs

- `classify` prints a JSON array to stdout. Each object has `status`,
  `provider`, `intent`, `verification`, `issue_number`, `issue_title`,
  `issue_state`, `issue_url`, `pr_number`, `evidence`, and `reason`.
- `close` prints the final single classification object to stdout after a
  successful close.
- Fatal invocation errors print diagnostics to stderr.

### Exit codes

- `0` - classification succeeded, or close succeeded.
- `1` - helper reached a decision that must not mutate, such as not closeable,
  already closed, unsupported, unknown, missing confirmation, or multiple issues
  supplied to `close`.
- `2` - invocation error or malformed helper output.

### Side effects

`classify` is read-only. `close` may close exactly one tracker item through
`roadmap_tracker_issue_close` when the re-run classification is `closeable` and
`--confirm-close` is present.

## Invariants

- `classify` never mutates tracker state.
- `close` re-runs classification immediately before mutation.
- `close` requires exactly one `--issue` and the literal `--confirm-close` flag.
- Unsupported or unknown verification never closes.
- The close mutation calls `roadmap_tracker_issue_close`, never raw provider
  commands.
- Evidence comments include the PR number and the controlled evidence string
  from `roadmap_tracker_pr_closure_status`.

## Test surface

- **CTC-1:** GitHub close intent plus open issue classifies as `closeable`.
- **CTC-2:** Confirmed close calls `roadmap_tracker_issue_close` with an
  evidence comment.
- **CTC-3:** Missing confirmation exits 1 and does not close.
- **CTC-4:** Already-closed issue classifies as `already-closed`.
- **CTC-5:** Reference-only or no intent classifies as `ambiguous`.
- **CTC-6:** Azure DevOps unsupported verification classifies as `unsupported`.
- **CTC-7:** Multiple closeable classifications return multiple objects; `close`
  with multiple issues exits 1.

## Versioning

- **1.0** (2026-06-04) - initial contract for issue #500.
