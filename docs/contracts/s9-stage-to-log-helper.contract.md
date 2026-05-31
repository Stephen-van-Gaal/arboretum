---
seam: s9-stage-to-log-helper
version: 1.1
producer-type: skill
consumer-type: script
consumes:
  - pipeline-state-helper-api
  - journey-log-line-format
  - hybrid-state-schema
  - CWD-1
  - CWD-2
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws9-state-tracking-design.md
  - docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws3a-pipeline-contracts-design.md
  - docs/superpowers/specs/2026-05-24-pipeline-overhaul-ws3b-pipeline-contracts-finalize-design.md
owns:
  - scripts/log-stage.sh
---
<!-- owner: pipeline-contracts-template -->

# S9 — Stage Skill → `scripts/log-stage.sh` Contract

The seam between any pipeline-stage skill (the producer set canonized by WS2 at PR #329) and the pipeline-state helper script. Each invocation performs two **independent** tracker operations — a body edit overwriting the current-stage header marker block (LWW) and a comment post carrying one journey-log entry. Per CWD-1, the two operations have no atomicity guarantee; partial failure surfaces loudly. The action vocabulary is the seven-entry set CWD-2 finalized. The default GitHub adapter delegates the tracker operations to `gh issue view/edit/comment`.

## Producer

Any stage skill writing pipeline-state events. The canonical set, as canonized by WS2 at PR #329:

- `/start` — `skills/start/SKILL.md`
- `/design` — `skills/design/SKILL.md`
- `/build` — `skills/build/SKILL.md`
- `/finish` — `skills/finish/SKILL.md`
- `/pr` — `skills/pr/SKILL.md`
- `/land` — `skills/land/SKILL.md`
- `/cleanup` — `skills/cleanup/SKILL.md`
- `/reflect` — `skills/reflect/SKILL.md`
- `/handoff` — `skills/handoff/SKILL.md`

Producer-type: `skill` (each member of the producer set is a slash-invokable arboretum skill).

The producer set is closed at any given moment but **expandable**: new stage skills introduced later automatically join the set by invoking the helper with their stage name. WS9 §D3 designed the stage-name field as open-set kebab-case slash-prefixed, so the contract accommodates expansion without schema change. The S9-1 test-surface assertion (producer-coverage) checks the *current* canonical set on `main`; it is amended whenever WS2 (or a successor workstream) changes the canonical set.

## Consumer

`scripts/log-stage.sh`. Consumer-type: `script`.

The script performs two independent tracker operations per invocation per WS9 §D2: a body edit (header overwrite) via `roadmap_tracker_issue_update`, and a comment post (log entry) via `roadmap_tracker_issue_comment`.

## Protocol shape

### Inputs

Bash CLI invocation form:

```
bash scripts/log-stage.sh <issue-number> <stage-name> <action> [<key>=<value>]...
```

Positional arguments:

- **`<issue-number>`** — positive integer naming the tracker item whose pipeline-state surfaces (body header + comment log) will be updated.
- **`<stage-name>`** — kebab-case slash-prefixed string naming the stage that is the subject of this log entry (e.g. `/build`, `/handoff`).
- **`<action>`** — one of the seven-entry closed enum (per Invariants below).

Variadic arguments:

- **`<key>=<value>`** — zero or more context key-value pairs. Callers pass bare-name keys joined to values with `=` (e.g. `branch=feat/foo`, `exit-status=success`). Conventional key names (in CLI form): `branch`, `spec`, `plan`, `exit-status`, `next`, `redirect-target`, `trigger`, `summary`, `completion-mode`, `event`, `target`, `reason`. The script transforms each `<key>=<value>` pair into the colon-suffixed render form (`<key>: <value>`) when emitting the comment body — see `### Outputs` for the rendered shape. Values are either bare strings (no `, ` substring) or double-quoted (when containing `, `). The script applies the double-quoting when emitting the comment body — callers pass raw values; the wrapping is the script's responsibility.

### Outputs

Two independent tracker operations.

**Operation 1 — body edit (header write).** `roadmap_tracker_issue_update --body-file <file>` rewrites the marker-delimited current-stage block at the top of the item body. The block shape is:

```
<!-- pipeline-state:current-stage -->
**Current stage:** <stage-name>
<!-- /pipeline-state:current-stage -->
```

Non-marker body content (everything after the closing `<!-- /pipeline-state:current-stage -->` marker) is preserved byte-for-byte. The block is always placed at the top of the body. If the markers are malformed (e.g. unclosed block, orphan opening marker), the script repairs them per WS9 OQ2 and posts a separate journey-log comment with action `repair`.

**Operation 2 — comment post (log entry).** `roadmap_tracker_issue_comment --body-file <file>` posts a new comment whose body has the exact shape:

```
<!-- pipeline-state:log -->
- <ISO-8601-UTC timestamp> — <stage-name> <action>, <key>: <value>, <key>: <value>, ...
```

The marker (`<!-- pipeline-state:log -->`) identifies the comment as a journey-log entry — aggregate readers filter on it. The timestamp is full ISO 8601 with explicit UTC zulu suffix and second resolution (e.g. `2026-05-24T14:03:00Z`).

**Script exit codes** (per WS9 §D2 commentary and the live `scripts/log-stage.sh` implementation):

- **`0`** — both operations succeeded.
- **`1`** — bad args, configured tracker backend missing, or tracker authentication failure.
- **`2`** — body-edit operation failed.
- **`3`** — comment-post operation failed.

### Invariants

**Non-atomicity (CWD-1 verbatim).**

> The header body-edit and the journey-log comment-post are independent operations. Each succeeds or fails on its own. The script exits non-zero if either fails; partial-success states are observable. Consumers (stage skills calling the helper) must surface partial failure to the user — no automatic recovery.

**Action vocabulary (seven entries, per CWD-2 extending WS9 §D5).** The `<action>` value is exactly one of:

- `entered` — stage skill began execution on this ticket.
- `exited` — stage skill finished execution (for `/build`, see the S3 contract's two-state `exit-status:` value).
- `skipped` — stage skill explicitly skipped (e.g. agent-target fast lane skips `/design`).
- `re-entered` — non-linear flow; stage skill was entered again after a prior `entered`/`exited` pair.
- `summary` — `/handoff` session-narrative line (per WS9 §D8).
- `repair` — script-emitted maintenance entry when marker-block repair fires (per WS9 OQ2).
- `dispatched` — stage skill handed control to a non-stage sub-skill (e.g. `superpowers:test-driven-development` for Branch 2, `superpowers:executing-plans` or `superpowers:subagent-driven-development` for Branch 3, per WS1 §D2). The dispatched-to sub-skill is named via the `target:` context key.

No other action value is permitted. WS4's contract test for the action vocabulary asserts this exact seven-entry set.

**No hash-based dedupe.** Tracker adapters may retry internally; accidental duplicate invocations produce a visible duplicate log comment. The model is honest-rather-than-silent: a visible duplicate is strictly less harmful than a silently-dropped legitimate re-entry (per WS9 §D9 and the rejected-alternative in WS9 §D2).

**Header LWW is intentional.** Re-running with the same stage value produces the same body. Older header values are uninteresting by definition — only the latest stage matters.

**Body preservation.** The body edit rewrites only the content between the current-stage markers. All other body content (frontmatter, original issue body, any non-marker text) is preserved byte-for-byte. Marker-block repair (per WS9 OQ2) is the only exception, and even then the script posts a `repair` log comment recording what was fixed.

**Comment serialization (tracker-side).** Comment creation is serialized by the configured tracker backend. No two writers create "the same comment"; the journey log is append-only by construction with no concurrency conflict possible at the per-entry level.

**Quoted-value escaping.** Values containing the structural `, ` delimiter are wrapped in double quotes. Within quoted values, three escape sequences are defined: `\"` (literal double-quote), `\\` (literal backslash), `\n` (newline; collapsed to a single space on read for single-sentence `summary:` values, preserved as-is for other values). No other escapes are permitted — values containing characters outside the format vocabulary must be rejected at write time rather than emitted ambiguously.

## Test surface

- **S9-1: Producer-coverage.** Every stage skill in the canonical set (`/start`, `/design`, `/build`, `/finish`, `/pr`, `/land`, `/cleanup`, `/reflect`, `/handoff`) invokes `bash scripts/log-stage.sh` on entry and on exit.
- **S9-2: Action-vocabulary.** Every action value passed to the helper is one of the seven entries (`entered`, `exited`, `skipped`, `re-entered`, `summary`, `repair`, `dispatched`). No other value appears in any callsite or in any emitted journey-log comment on `main`.
- **S9-3: Header-body-preservation.** The body edit preserves all non-marker body content byte-for-byte; the body never loses any pre-existing line, frontmatter, or rendered Markdown outside the current-stage marker block.
- **S9-4: Header-LWW.** Repeated invocations with the same `<stage-name>` produce the same body (LWW collapses identical writes naturally; idempotency on the header is automatic).
- **S9-5: Comment-marker-conformance.** Every comment the helper posts begins with `<!-- pipeline-state:log -->\n- ` followed by a parseable journey-log line per WS9 §D5's format (ISO-8601-UTC zulu timestamp, stage, action, context kv pairs).
- **S9-6: Partial-failure-loud.** If the body edit succeeds and the comment post fails (or vice versa), the script exits non-zero with an error naming the failed operation; the calling stage skill surfaces the error to the user.
- **S9-7: Quoted-value-escaping.** Context values containing `, ` are double-quoted in the emitted comment; within quoted values, the three escape sequences (`\"`, `\\`, `\n`) are applied at write time and un-applied at read time by the documented parsers (boot banner + status-footer cache).

## Versioning

- **1.1** (2026-05-31) — issue reads/updates/comments flow through backend-neutral tracker helpers; GitHub remains the default adapter.
- **1.0** (2026-05-24) — initial contract per WS9 §D1–D2; embeds CWD-1 (non-atomicity) verbatim in `### Invariants` and the seven-entry action vocabulary from CWD-2. Producer + consumer behaviour from PR #314 (WS9 build) + PR #320 (statusline-default fix).
