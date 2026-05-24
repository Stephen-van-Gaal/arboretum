---
seam: s3-build-to-finish
version: 1.0
producer-type: skill
consumer-type: skill
consumes:
  - s3-output-contract
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-22-pipeline-overhaul-ws1-build-orchestrator-design.md
  - docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws3a-pipeline-contracts-design.md
  - docs/superpowers/specs/2026-05-24-pipeline-overhaul-ws3b-pipeline-contracts-finalize-design.md
---
<!-- owner: pipeline-contracts-template -->

# S3 — `/build` → `/finish` Contract

The seam between the `/build` stage skill and the `/finish` stage skill. `/build`'s exit carries an explicit `exit-status:` value in its journey-log line — one of `success` or `escape-hatch` — plus state-specific post-conditions. `/finish` reads the value and routes: success continues the ship tail; escape-hatch returns control to `/design`. Two distinct states with exclusive post-conditions; one consumer.

## Producer

`/build` — `skills/build/SKILL.md`. Producer-type: `skill`.

`/build`'s exit emits a journey-log entry carrying an explicit `exit-status:` value (one of `success` | `escape-hatch`) plus state-specific post-conditions. The journey-log entry is written via `scripts/log-stage.sh` per the S9 contract (`docs/contracts/s9-stage-to-log-helper.contract.md`).

## Consumer

`/finish` — `skills/finish/SKILL.md`. Consumer-type: `skill`.

`/finish` reads the most recent `/build exited` journey-log entry's `exit-status:` value and routes:

- `success` → continue the ship tail (`/security-review`, then `/pr` → `/land` → `/cleanup` → `/reflect` → `/handoff`).
- `escape-hatch` → return control to `/design` (the design spec needs amendment before `/build` re-enters).

## Protocol shape

### Inputs

None at the seam level. `/finish` is invoked by the workflow continuation after `/build` exits, not by `/build` directly. The seam carrier is the journey-log entry `/build` writes via the S9 helper (`scripts/log-stage.sh`); `/finish` reads the entry from the issue's comment stream.

### Outputs

Two distinct exit states keyed by `exit-status:` in `/build`'s exit log line.

**`success` state post-conditions:**

- **Plan resolution** — when the design spec's `plan:` field names a file, every checkbox in that file is either checked (`- [x] <item>`) or explicitly skipped with a reason on the same line (`- [x] (skipped: <reason>) <item>` or `- [ ] (skipped: <reason>) <item>`).
- **Plan exemption** — when the design spec's `plan:` field is `null`, the plan-checkbox condition is N/A by construction (pure-TDD mode). `/build` does not look for a plan file or treat its absence as a failure.
- **Test suite green** — running the project's tests produces a passing result.
- **Test surface discipline** — no existing test file was modified or deleted during build without an accompanying entry in the design spec's `test-surface-changes:` block naming the file and reason. `all-tiers-N/A` in `test-tiers:` is only valid when no test files were added, modified, *or* deleted during build (any test mutation invalidates the N/A claim).
- **No escape-hatch fired** — the escape-hatch trigger conditions (WS2 §D2 mid-build reclassification criteria) did not fire during the build.
- **Exit log line** — `/build` writes a journey-log entry via `scripts/log-stage.sh` with action `exited` and context key `exit-status: success`, e.g. `/build exited, exit-status: success, plan: resolved, tests: green, next: /finish`.

**`escape-hatch` state post-conditions:**

- **Trigger recorded** — the design spec is amended with an `escape-hatch:` block naming the trigger condition (which WS2 §D2 escape-hatch criterion fired) and what the user must reconsider.
- **Plan and test conditions do not apply** — by definition, the build was abandoned before reaching them. The S3 contract does not assert plan-resolution or tests-green for this state.
- **Exit log line** — `/build` writes a journey-log entry via `scripts/log-stage.sh` with action `exited` and context keys `exit-status: escape-hatch`, `next: /finish` (the immediate S3 consumer, per the single-consumer invariant), `redirect-target: /design` (the stage `/finish` will route to after reading the exit-status), `trigger: <name>` (the escape-hatch criterion that fired).

### Invariants

- **Exclusive states.** Every `/build` exit produces exactly one of the two `exit-status:` values. No third value; no concurrent values. The journey-log line either says `exit-status: success` or `exit-status: escape-hatch`, never both, never neither.
- **Single consumer.** `/finish` is the sole consumer on both states. `/build` does not branch the handoff (per WS1 §D2 step 6 — keeping the handoff single-target makes the S3 seam unambiguously template-able).
- **State-determines-routing.** `/finish` reads `exit-status:` and dispatches accordingly. There is no fall-through default — an absent `exit-status:` is itself a contract violation (S3-1) and `/finish` must surface it loudly rather than silently route.
- **`plan: null` exempts plan-checkbox condition.** When the design spec declares `plan: null` (pure-TDD mode), the plan-resolution post-condition for the `success` state is N/A by construction.
- **`all-tiers-N/A` ⇒ no test mutation.** When `test-tiers:` declares all three tiers as `n/a — <reason>`, the build must not add, modify, or delete any test file. Any test-surface change during such a build invalidates the N/A declaration and fails the success-state gate.
- **Reading the right exit line.** `/finish` reads the *most recent* `/build exited` journey-log entry. If multiple `/build exited` entries exist on the issue (e.g. after an escape-hatch round-trip and a subsequent successful build), the latest one is authoritative.

## Test surface

- **S3-1: Exit-status-emitted.** Every `/build` exit produces a journey-log entry whose line includes `exit-status: <value>`.
- **S3-2: Exit-status-enum.** The `exit-status:` value is exactly one of `success` | `escape-hatch`; no other value is accepted by `/finish`.
- **S3-3: Success-plan-resolved (path mode).** When the design spec's `plan:` field names a file, every checkbox in that file is either checked (`- [x]`) or explicitly skipped with a reason on the same line (`- [x] (skipped: <reason>) <original>` or `- [ ] (skipped: <reason>) <original>`).
- **S3-4: Success-plan-NA (null mode).** When the design spec's `plan:` field is `null`, the plan-checkbox condition is not applied — `/build` does not look for a plan file or report missing plans as a failure.
- **S3-5: Success-tests-green.** On success exit, the test suite passes.
- **S3-6: Success-test-surface-discipline.** On success exit, any test file modified or deleted during build is named in the design spec's `test-surface-changes:` block with a reason. `all-tiers-N/A` in `test-tiers:` is only valid when no test files were added, modified, or deleted during build.
- **S3-7: Escape-hatch-trigger-recorded.** On escape-hatch exit, the design spec carries an `escape-hatch:` block naming the triggering WS2 §D2 criterion and what to reconsider.
- **S3-8: Finish-routes-correctly.** `/finish` reads the most recent `/build exited` journey-log entry's `exit-status:` value and routes: `success` → continue ship tail; `escape-hatch` → return to `/design`.

## Versioning

- **1.0** (2026-05-24) — initial contract; producer + consumer shapes per WS1 §D4, with producer behaviour from PR #321 (WS1 build) and consumer behaviour from PR #329 (v2 cutover — `/finish` v2 surface).
