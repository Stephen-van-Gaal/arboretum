---
seam: review-dispositions
version: 1.0
producer-type: skill
consumer-type: skill
consumes:
  - collect-review-normalized-records
produces:
  - review-dispositions-ledger
related-designs:
  - docs/superpowers/specs/2026-06-06-review-loop-closeout-design.md
owns:
  - scripts/validate-review-dispositions.sh
  - .arboretum/land/<pr>/dispositions.json
---
<!-- owner: pipeline-contracts-template -->

# review-dispositions - Review Decision Ledger Contract

`dispositions.json` records the model-reviewed decision for each collected
review item before any provider-visible closeout mutation happens.

## Producer

`skills/review-evaluate/SKILL.md` - producer-type: `skill`.

The skill reads `.arboretum/land/<pr>/comments.json`, applies receive-review
discipline, classifies actionable review records, and writes
`.arboretum/land/<pr>/dispositions.json`.

## Consumer

Consumer-type: `skill`. Downstream consumers:

- `skills/land/SKILL.md` reads the ledger to group fix clusters and surface
  judgment calls.
- `skills/review-closeout/SKILL.md` validates the ledger before provider-visible
  closeout.
- `scripts/post-review-closeout.sh` consumes the ledger through
  `scripts/validate-review-dispositions.sh`.

## Protocol shape

### Inputs

- `.arboretum/land/<pr>/comments.json` from `scripts/collect-review.sh`.
- Pull request number `<pr>`.

### Outputs

Required top-level fields in `.arboretum/land/<pr>/dispositions.json`:

- `schema` - must be `review-dispositions.v1`.
- `pr` - positive integer pull request number.
- `items` - array of disposition records.

Each item requires:

- `comment_id` - id of a collected review record in `comments.json`.
- `disposition` - closed enum below.
- `severity` - closed enum below.
- `action` - closed enum below.
- `resolve_after_closeout` - boolean.
- `reply` - string, possibly empty only when no reply will be posted.
- `reason` - non-empty string explaining the decision.

Closed enums:

- `disposition`: `fix`, `already-addressed`, `defer`, `wont-fix`,
  `judgment-call`, `duplicate`, `outdated`, `informational`
- `severity`: `substantive`, `nit`, `none`
- `action`: `fix-in-batch`, `no-code-change`, `ask-human`,
  `manual-follow-up`

Optional fields:

- `cluster` - required and non-empty when `disposition` is `fix`.
- `fix_commits` - array of commit SHAs that addressed the item, populated by
  the fix loop or closeout preparation rather than by initial evaluation.

### Invariants

- Evaluation is read-only with respect to GitHub and Azure DevOps.
- Every `comment_id` must match a record in
  `.arboretum/land/<pr>/comments.json`.
- `fix` dispositions require a non-empty `cluster`.
- `resolve_after_closeout=true` requires a non-empty `reply`.
- `action=ask-human` must not set `resolve_after_closeout=true`.

## Test surface

- **RD-1:** Unknown `comment_id` is rejected.
- **RD-2:** Unknown enum value is rejected.
- **RD-3:** `fix` requires a non-empty `cluster`.
- **RD-4:** `resolve_after_closeout=true` requires a non-empty `reply`.
- **RD-5:** `action=ask-human` cannot request closeout resolution.

## Versioning

- **1.0** (2026-06-06) - initial contract for issue #580 review evaluation and closeout design.
