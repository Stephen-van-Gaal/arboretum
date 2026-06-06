---
seam: review-closeout
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - collect-review-normalized-records
  - review-dispositions-ledger
  - review-fixes-ledger
produces:
  - review-closeout-ledger
related-designs:
  - docs/superpowers/specs/2026-06-06-review-loop-closeout-design.md
owns:
  - scripts/post-review-closeout.sh
  - .arboretum/land/<pr>/closeout.json
---
<!-- owner: pipeline-contracts-template -->

# review-closeout - PR Review Closeout Contract

`scripts/post-review-closeout.sh` is the deterministic provider-write boundary
for `/land` after fixes have been committed and pushed.

## Producer

`scripts/post-review-closeout.sh` - producer-type: `script`.

The helper validates review ledgers, verifies closeout safety, writes provider
comments/resolutions on GitHub, and emits `.arboretum/land/<pr>/closeout.json`
after successful live writes.

## Consumer

Consumer-type: `skill`. Downstream consumers:

- `skills/review-closeout/SKILL.md` invokes the helper first with `--dry-run`,
  then live after `/land` safety checks have passed.
- `skills/land/SKILL.md` treats the helper's `closeout.json` as the provider
  closeout evidence and merge-readiness input.

## Protocol shape

### Inputs

Invocation:

```bash
post-review-closeout.sh <pr> [--dry-run]
```

- `<pr>` - required positive integer pull request number.
- `--dry-run` - validate inputs, safety gates, and planned writes, then print
  the mutation plan without provider writes and without writing `closeout.json`.

All input ledgers live under `.arboretum/land/<pr>/`:

- `comments.json` from `scripts/collect-review.sh`
- `dispositions.json` from `skills/review-evaluate/SKILL.md`
- `fixes.json` from the `/land` fix loop

`fixes.json` uses `schema: review-fixes.v1`, `pr`, optional `head_sha`, and an
`items[]` array keyed by `comment_id` with `commits[]` containing pushed fix
SHAs.

### Outputs

Live mode writes in this order:

1. Per-thread reply for each item that has `resolve_after_closeout=true`.
2. GraphQL `resolveReviewThread` for the addressed GitHub thread.
3. One top-level PR summary comment.
4. `.arboretum/land/<pr>/closeout.json`.

GitHub endpoints:

```bash
gh api "repos/{owner}/{repo}/pulls/$PR/comments/$COMMENT_ID/replies" -f body="$BODY"
gh api graphql -f threadId="$THREAD_ID" -f query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}'
gh pr comment "$PR" --body-file "$SUMMARY_FILE"
```

`closeout.json` is written only after successful live writes:

```json
{
  "schema": "review-closeout.v1",
  "pr": 580,
  "head_sha": "<local-head>",
  "actions": [],
  "remaining_open": []
}
```

`remaining_open` lists substantive items that were not resolved during closeout.

Exit codes:

- `0` - complete, or dry-run plan produced.
- `1` - validation or safety failure.
- `2` - invocation error or missing required input.
- `3` - provider write failure after validation passed.

### Invariants

Before any provider mutation, the helper must verify:

- `dispositions.json` passes `scripts/validate-review-dispositions.sh <pr>`.
- `fixes.json` is present, matches `<pr>`, and any `head_sha` matches local
  `HEAD`.
- Every cited commit SHA is reachable from local `HEAD`.
- The provider PR is still open and its head matches local `HEAD`.

Failure at any safety gate leaves provider threads untouched and does not write
`closeout.json`.

Azure DevOps mutation is not automated in version 1.0; unsupported provider
write targets must fail before mutation with manual guidance.

## Test surface

- **RC-1:** Dry-run prints planned reply, resolve, and summary writes without
  calling `gh`.
- **RC-2:** Live mode writes reply, resolve, and summary in order.
- **RC-3:** Unreachable cited commits fail before provider writes.
- **RC-4:** `closeout.json` is written only after successful live writes.

## Versioning

- **1.0** (2026-06-06) - initial contract for issue #580 review closeout design.
