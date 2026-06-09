---
seam: s2-design-to-build
version: 1.1
producer-type: skill
consumer-type: skill
consumes:
  - s2-input-contract
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-22-pipeline-overhaul-ws1-build-orchestrator-design.md
  - docs/superpowers/specs/2026-05-23-pipeline-overhaul-ws3a-pipeline-contracts-design.md
  - docs/superpowers/specs/2026-05-24-pipeline-overhaul-ws3b-pipeline-contracts-finalize-design.md
---
<!-- owner: pipeline-contracts-template -->

# S2 — `/design` → `/build` Contract

The seam between the `/design` stage skill and the `/build` stage skill. `/design` writes a design spec carrying five required frontmatter fields; `/build` reads them on entry and dispatches Branch 2 (test-driven-development tier) and Branch 3 (implementation mode) without re-deciding. Strict producer/consumer interface — any missing field on entry fails `/build`'s whole-schema gate; no self-heal.

## Producer

`/design` — `skills/design/SKILL.md`. Producer-type: `skill`.

In the current general-release pipeline, `/design`'s unified design phase
populates all five required frontmatter fields at exit: Branch 1 mode sets the
design path and triage context, and plan fold-in sets the `plan:` field. The
field definition lives in the `s2-input-contract` shared-concepts stub.

## Consumer

`/build` — `skills/build/SKILL.md`. Consumer-type: `skill`.

`/build`'s entry reads the positional design-spec path argument and the five required frontmatter fields, dispatches Branch 2 + Branch 3 from the field values, and refuses to run with an S2-contract-drift error if any required field is missing.

## Protocol shape

### Inputs

Positional argument `<design-spec-path>` (string, relative file path — explicit, never inferred).

Required frontmatter fields on the spec file at that path:

- **`related-issue`** — positive integer naming the GitHub issue this work tracks.
- **`test-tiers`** — object with at least the three keys `unit`, `contract`, `integration`. Each value is either `yes` or a single-line string starting `n/a — ` followed by a reason.
- **`implementation-mode`** — closed enum: `direct` | `executing-plans` | `subagent-driven-development`. The value determines Branch 3 dispatch (per WS1 §D3 enum-to-skill mapping: `direct` proceeds inline with no skill, `executing-plans` invokes `superpowers:executing-plans`, `subagent-driven-development` invokes `superpowers:subagent-driven-development`).
- **`triage`** — closed enum: `agent-target` | `everything-else`. The value comes from the design spec's frontmatter, **not** from the GitHub issue label or body — `/design` is responsible for transcribing the triage decision into the frontmatter at exit.
- **`plan`** — string (relative file path) or the literal `null`. When a path, the file must exist at `/design`'s exit time. When `null`, declares pure-TDD mode (Branch 3 = `executing-plans` is invalid against `plan: null`; `direct` or `subagent-driven-development` is the only valid mode).

Optional field:

- **`kind`** — closed enum `{buildable, shaping}`; **absent ⇒ `buildable`** (the default — no migration for existing docs). `kind: shaping` marks a non-buildable design artifact (an epic/shaping doc that stops after human review; its children build individually). On a shaping doc the five build-targeted fields above are **not required** and are ignored if present — the producer validator (`validate-design-spec.sh`) requires only `related-issue`, and the consumer gate (`read-s2-frontmatter.sh`) refuses the doc with a distinct exit code so `/build` never runs it. Any `kind` value outside the enum is a validation error naming the field. (#692)

### Outputs

`/build`'s normal execution proceeds when all five fields are present and valid:

- Branch 2 dispatches per `test-tiers:` — when ≥ 1 tier is `yes`, dispatches to `superpowers:test-driven-development`; when all tiers are `n/a — <reason>`, logs the skip and proceeds to Branch 3.
- Branch 3 dispatches per `implementation-mode:` — to one of the three modes per the WS1 §D3 enum-to-skill mapping above.

When any one required field is missing or violates its constraint, `/build` writes an S2-contract-drift error to stderr naming the missing or invalid field(s), exits non-zero, and **does not write any pipeline-state journey-log entry beyond a `/build entered` line followed by the failure** — the build is not considered to have run.

### Invariants

- **Strict whole-schema gate.** All five required fields are checked at entry. Any one missing field fails the gate; field-by-field tolerance is not permitted (a build with `triage:` present and `implementation-mode:` absent fails — `triage`'s presence does not redeem `implementation-mode`'s absence).
- **No self-heal.** `/build` never prompts the user for missing fields and never amends the design spec to backfill them. The user is directed back to `/design`.
- **Deterministic `plan:` derivation owned by `/design`.** The derivation rule (strip `-design` from the design-spec basename; resolve `docs/plans/<basename-minus-design>.md`; write the path if it exists, else write `null`) is enforced at `/design`'s exit. `/build` does not re-derive; it reads the field literally.
- **`triage:` is frontmatter-sourced, not label-sourced.** The triage value on the GitHub issue label is a hint to `/start`, not an authority for `/build`. `/build` reads from the frontmatter; if the label and frontmatter disagree, the frontmatter is authoritative.
- **`plan: null` constrains `implementation-mode:`.** When `plan: null`, the only valid `implementation-mode:` values are `direct` and `subagent-driven-development` — `executing-plans` requires a plan file to execute against. This invariant is checked at `/build`'s entry alongside the missing-field check; failure produces an S2-contract-drift error naming the conflict.
- **`kind: shaping` short-circuits both ends.** Producer side: `validate-design-spec.sh` validates only `related-issue` and skips the build-targeted schema (so a shaping doc passes `/design`'s self-check without masquerading as a `/build` input). Consumer side: `read-s2-frontmatter.sh` detects `kind: shaping` **before** the missing-field gate and exits **3** (distinct from the exit-2 drift code) with a specific non-buildable message; `/build` maps exit 3 to a clean refusal and does not run. The strict five-field gate is otherwise unchanged for buildable docs (`kind` absent/`buildable`). (#692)
- **`kind` is a closed enum on both ends (self-contained gates).** An out-of-enum `kind` is malformed drift, rejected independently by each gate without relying on the other having run first: `validate-design-spec.sh` exits 1 naming `kind`; `read-s2-frontmatter.sh` exits **2** (drift) — it does **not** fall through to exit 0 even when the five build fields are otherwise complete. (#692)

## Test surface

- **S2-1: Producer-completeness (buildable docs).** For a buildable design doc (`kind` absent or `buildable`), `/design`'s unified exit produces a spec with all five required frontmatter fields (`related-issue`, `test-tiers`, `implementation-mode`, `triage`, `plan`). A `kind: shaping` doc is exempt — it carries only `related-issue` (the build-targeted fields are omitted; see S2-8).
- **S2-2: Consumer-strict-gate.** `/build` refuses to run if any required S2 field is missing, naming which field(s) are absent.
- **S2-3: Consumer-no-self-heal.** `/build` does not prompt for or backfill missing fields; the exit on missing-field is non-zero and the user is redirected to `/design`.
- **S2-4: Enum-validity.** `/build` rejects `implementation-mode:` values outside the closed enum `{direct, executing-plans, subagent-driven-development}` and `triage:` values outside `{agent-target, everything-else}`.
- **S2-5: Deterministic plan-path derivation.** `/design`'s `plan:` field is either the exact path produced by the documented derivation rule (basename-minus-`-design` resolved against `docs/plans/`) or the literal `null`.
- **S2-6: Plan-path existence.** When `/design` writes `plan: <path>`, the path resolves to an existing file at the time `/design` exits.
- **S2-7: Binding — producer/consumer skills invoke the validator.** The `/design` and `/build` skills actually call `validate-design-spec.sh` (the gate is wired, not just documented). Test: `tests/contracts/s2/s2-7-binding-skills-invoke-validator.sh`.
- **S2-8: Shaping-doc accept-and-refuse.** A `kind: shaping` doc with only `related-issue` passes `validate-design-spec.sh` (exit 0); `read-s2-frontmatter.sh` refuses it with exit 3 and a non-buildable message. An out-of-enum `kind` value is rejected independently by both gates — `validate-design-spec.sh` exit 1 naming the field, and `read-s2-frontmatter.sh` exit 2 (drift) even with otherwise-complete fields. Buildable-path behaviour (`kind` absent/`buildable`) is unchanged. (#692)

## Versioning

- **1.1** (2026-06-08) — additive: optional `kind: {buildable, shaping}` field (absent ⇒ buildable). `kind: shaping` lets a non-buildable epic/shaping design doc pass producer validation without the build-targeted fields and be refused by `/build` (read-s2 exit 3). Backward-compatible — existing docs unchanged. Adds invariant + S2-8; also backfills the previously-undocumented S2-7 binding bullet (its test shipped in WS4 but was never listed here) (#692).
- **1.0** (2026-05-24) — initial contract; producer + consumer shapes per WS1 §D3, with the producer side reflecting the unified `/design` behaviour from PR #329 and the consumer side reflecting `/build` from PR #321 (WS1 build).
