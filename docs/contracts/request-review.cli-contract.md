---
script: scripts/request-review.sh
version: 1.0
invokers:
  - type: skill
    name: arboretum:/request-review
  - type: skill
    name: arboretum:/pr
  - type: script
    name: scripts/_smoke-test-request-review.sh
related-designs:
  - docs/superpowers/specs/2026-06-04-request-review-config-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/request-review.sh`

## Surface

Requests (or re-requests) the reviewers declared in `.arboretum.yml`'s `review:`
block, each via its configured mechanism, dispatched on the project's repo
backend. On `github` it fires live mechanisms (`ready-for-review` flip,
`@reviewer` trigger comment, or `requested_reviewers` API). On `azure-devops`
the AI-reviewer request is a stub (no native bot); human reviewers are added via
the Azure CLI directly. `REVIEW_DRY_RUN=1` prints intended actions without
touching the network.

## Protocol

### Arguments

```
request-review.sh <pr> [--reviewer <name>] [--re-request]
```

- `<pr>` (positional, required) — the pull request number (positive integer).
- `--reviewer <name>` — restrict the request to one configured reviewer.
- `--re-request` — use each reviewer's `re_request` mechanism instead of `request`.

### Environment

- `REVIEW_DRY_RUN=1` — print the per-reviewer action plan; perform no network calls.

### Output

One line per reviewer acted on: `requested: <name> via <mechanism>` (or
`re-requested: <name> via <mechanism>` with `--re-request`). On `azure-devops`,
a single `stub: ADO ...` notice.

### Exit codes

- `0` — reviewers requested (or the ADO stub notice printed), or no AI reviewers configured.
- `2` — missing/invalid `<pr>` (non-integer), unknown flag, `<pr>` is not a pull
  request (live mode), or unsupported backend.

### Side effects

`github` live mode posts via `gh` (PR ready-flip, comment, or reviewer API).
`azure-devops` performs no AI request. `REVIEW_DRY_RUN=1` performs no network
calls. No git history mutation.

## Test surface

- **CLI-1: GitHub dispatch.** With a `github` config (dry-run), emits one
  `requested: <name> via <mechanism>` line per enabled reviewer.
- **CLI-2: Re-request mechanism.** `--re-request` selects each reviewer's
  `re_request` mechanism and emits `re-requested:` lines.
- **CLI-3: Reviewer filter.** `--reviewer <name>` requests only the named reviewer.
- **CLI-4: ADO stub.** On `azure-devops`, emits the AI-request stub notice and exits `0`.
