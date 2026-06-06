---
script: scripts/pr-readiness.sh
owner: pipeline-contracts-template
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/pr-readiness.sh`

## Surface

Classifies local and remote pull-request readiness for the Arboretum ship tail.
It emits one line of space-separated `KEY=VALUE` tokens and exits `0` after
every successful classification, including blocked, waiting, and unknown
states. Non-zero exits are reserved for invocation errors or missing required
tools.

The default output is provider-neutral and decision-oriented for AI agents. Raw
provider fields are diagnostic only and must not be required by workflow
consumers.

## Protocol

### Arguments

```text
pr-readiness.sh local <base-ref>
pr-readiness.sh remote <pr-number> [--allow-draft]
```

### Environment

- `SHIP_BACKEND=<backend>` — override backend detection. Supported values in
  this slice: `github`, `azure-devops`.
- `READINESS_RETRY_SLEEP=<seconds>` — sleep between bounded mergeability fetches.
  Tests set this to `0`.
- `READINESS_DEBUG=1` — may append raw provider fields such as
  `raw_mergeable=<value>` and `raw_merge_state=<value>`. Consumers must ignore
  these fields.

### Output

Required default keys:

```text
readiness=<value> reason=<value> next_action=<value> ci=<value>
```

Remote GitHub output also includes:

```text
head_sha=<sha> base_sha=<sha>
```

Optional keys:

- `backend=<backend>` — present when backend identity matters, such as
  unsupported backends.
- `failing_checks=<comma-list>` — present only when `reason=ci-failing`.
- `conflict_paths=<comma-list>` — present when a local or remote probe can
  identify specific conflicted paths.
- `raw_mergeable=<value>` and `raw_merge_state=<value>` — debug-only provider
  evidence when `READINESS_DEBUG=1`.

`readiness` is one of:

- `ready`
- `draft-clean`
- `blocked`
- `waiting`
- `unknown`

`reason` is one of:

- `clean`
- `draft-only`
- `merge-conflict`
- `merge-state-blocked`
- `mergeability-unknown`
- `ci-failing`
- `ci-pending`
- `ci-absent`
- `ci-unavailable`
- `local-dirty`
- `local-conflict`
- `local-behind`
- `local-unknown`
- `unsupported-backend`

`next_action` is one of:

- `proceed`
- `mark-ready`
- `repair-conflicts`
- `repair-local`
- `fix-ci`
- `wait-ci`
- `retry-readiness`
- `configure-ci`
- `escalate`

`ci` is one of:

- `pass`
- `fail`
- `pending`
- `absent`
- `not-checked`
- `unknown`

### Exit codes

- `0` — classification succeeded, including blocked, waiting, or unknown output.
- `2` — invocation error, missing argument, unsupported flag, or missing required
  local tool for the requested backend.

### Consumer rules

Consumers must:

- key off `readiness`, `reason`, `next_action`, and `ci`, not raw provider fields;
- stop before expensive CI, reviewer request/collection, review-thread
  resolution, or merge handoff when `readiness=blocked` or `readiness=unknown`;
- treat unknown output values as hard stops;
- treat skipped or absent checks on a ready PR as unknown, not green.

## Test surface

- **PRR-1: Existence.** The script exists and is executable by `bash`.
- **PRR-2: Output shape.** `remote` output starts with `readiness=` and includes
  contract-listed `reason`, `next_action`, and `ci` values.
- **PRR-3: Mergeability first.** Conflicting, dirty, behind, or unknown
  mergeability emits `ci=not-checked` without reading checks. Broader provider
  blockers such as GitHub `BLOCKED` may still inspect checks when
  `mergeable=MERGEABLE`, so failing CI is not hidden behind a generic merge-state
  blocker.
- **PRR-4: Draft handling.** `--allow-draft` maps clean draft PRs to
  `readiness=draft-clean reason=draft-only next_action=mark-ready`.
- **PRR-5: CI classification.** Clean ready PRs classify failing, pending,
  passing, skipped, absent, and unavailable checks distinctly.
- **PRR-6: Invocation failures.** Unexpected subcommands exit non-zero.
- **PRR-7: Backend seam.** Azure DevOps emits
  `readiness=unknown reason=unsupported-backend next_action=escalate` without
  calling `gh`.
- **PRR-8: Debug fields.** Default output omits raw provider keys; debug mode may
  append them.
