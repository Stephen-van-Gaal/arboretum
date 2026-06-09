---
name: review-stage
status: active
owner: architecture
document-shape: governed-spec
areas:
  - name: dispatch
    summary: the lane plan — which lanes run, in what order, gated how
  - name: seam
    summary: brief-in / manifest-out — the replaceable-backend boundary
  split-assessment: "One component, two areas. Both change for a single reason — how the B4 pre-PR review is dispatched. The seam serves dispatch only; no second consumer reads brief/manifest, so neither area evolves independently. Not a group (#681): the lane backends are external and replaceable — this spec owns only their orchestration."
owns:
  - skills/ai-surface-review/SKILL.md
  - scripts/review-dispatch.sh
  - scripts/validate-review-manifest.sh
---

<!-- ILLUSTRATIVE FIXTURE for #671 (component-spec content model). Demonstrates the
     mandatory core at token-accounting density: self-contained Behaviour (the
     promise; seam referenced to a contract, not inlined), areas: + split-assessment,
     Quality Attributes, Customer Experience, a provenance changelog, and Decisions
     carrying Alternatives + Rationale. Authorship markers absent (schema-driven).
     Frontmatter leads (document-access requires it). NOT the live
     docs/specs/review-stage.spec.md. Seed for #685's validators. -->

# Review stage

## Purpose

The pipeline's mandatory B4 pre-PR review gate. It shifts review left — before
the PR exists — so prompt-injection, security, and correctness defects are caught
on the local branch rather than in /land's post-PR loop. Serves the solo author
who wants team-grade multi-reviewer coverage without waiting on remote reviewers.
Owns the dispatch and the replaceability seam — not the reviewers themselves.

## Boundaries (non-goals)

- General-purpose SAST/correctness *implementation* — delegated to the replaceable
  backends (/security-review, /code-review); this spec owns dispatch + seam.
- The post-PR AI-reviewer loop (Copilot/Codex), PR mechanics, review-config —
  remain owned by git-workflow-tooling.
- Severity→ship-tail auto-halt and a persisted findings ledger — deferred
  (#661 improvements 5–6).

## Behaviour

The mandatory B4 gate runs inside /finish. At entry the dispatcher
(review-dispatch.sh) computes diff_scope once — `git diff <base>...HEAD
--name-only`, regenerated every invocation and never carried as cross-stage state
(the branch advances between stages) — and produces a lane plan. Up to three lanes
run as fresh-context drivers (each a subagent with its own context, so a lane's
reading cost is not paid by the main thread), in fixed order: (1) ai-surface,
gated on any AI-facing path, running the homegrown /ai-surface-review driver —
first because least-tested; (2) general-security, always-on, default
/security-review; (3) correctness, gated to runs where classify-pr-change.sh
returns `code`, default /code-review. Every lane is replaceable behind the
brief/manifest seam, whose field schema is pinned in review-dispatch.contract.md
(a durable peer; not inlined here). A lane whose backend is absent degrades to the
/land reviewers rather than failing the gate; no lane carries a hard `requires:`.
Each lane emits a manifest entry even on a clean pass, so "0 findings" is
auditable; validate-review-manifest.sh enforces the manifest schema. This is the
local, shift-left counterpart to /land's post-PR loop, decomposed out of
git-workflow-tooling as the first Slipstream per-segment governed spec.

## Quality Attributes

- Cost-bounded: the correctness lane is code-gated, not always-on, capping spend
  on docs-only changes. Verified: dispatch smoke-test docs-only ⇒ no correctness lane.
- Auditable zero: a clean lane still emits a manifest entry. Verified: validate-review-manifest.
- Graceful under absence: a missing backend degrades to /land, never aborts /finish.
  Verified: dispatch smoke-test absent-backend case.

## Customer Experience

At /finish the author sees the gate announce its lane plan ("AI-surface +
general-security; correctness skipped — docs-only"), each lane run as a
fresh-context driver, and a coverage manifest — including an explicit "0 findings"
when a lane ran clean. A missing backend is reported as degraded-to-/land, never
silently skipped. The gate is mandatory but advisory in outcome.

## Requires

| Dependency | Source | Definition |
|------------|--------|------------|
| classify-pr-change.sh | scripts/ | classify-pr-change.contract.md — the code-gate (contract is the authority; referenced, not restated) |
| brief/manifest seam | this spec | review-dispatch.contract.md — stable multi-lane interface ⇒ contract, not inline |
| /security-review, /code-review | plugins | inline: default lane backends invoked via brief; replaceable + degrading; single-consumer ⇒ no separate contract |

## Provides

| Export | Type | Definition |
|--------|------|------------|
| review-dispatch.sh | CLI | diff_scope → ordered lane plan (review-dispatch.contract.md) |
| validate-review-manifest.sh | CLI | manifest schema accept/reject; per-entry key enforcement |
| /ai-surface-review | skill | the homegrown ai-surface lane backend |

## Tests

| Test file | Tier | Covers |
|-----------|------|--------|
| _smoke-test-review-dispatch.sh | unit | lane-plan ordering + gating; absent-backend degradation (7 cases) |
| _smoke-test-validate-review-manifest.sh | contract | manifest schema accept/reject incl. per-entry keys (5 cases) |
| Integration | N/A | verified end-to-end via the /finish B4 step on each branch's own diff |

## Implementation Notes

review-dispatch.sh computes the plan; lane backends are invoked as fresh-context
subagents by the /finish B4 step. The brief/manifest contract is the swap
boundary — adding a lane means a new conformant backend, no dispatcher change.

### Design record

| Date | Artifact | Sections changed | Summary |
|------|----------|------------------|---------|
| 2026-06-08 | review-stage-design.md | Behaviour, Decisions, Seam, Customer Experience | Initial promotion: 3-lane B4 dispatch + brief/manifest seam |
| 2026-06-08 | review-stage.md (plan) | Tests | Implementation record: dispatch + manifest validator |

## Decisions

| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|
| D1 | Driver-dispatch on the /cleanup precedent, not the #629 conductor core | Build on #629's conductor | #629 is OPEN, not on main; /cleanup's subagent+report pattern is merged and proven | 2026-06-08 | review-stage-design D1 |
| D3 | Lane order ai-surface → general-security → correctness | Any other ordering | Run least-tested homegrown first (fail fast on the novel surface); security before correctness | 2026-06-08 | review-stage-design D3 |
| D4 | Default general-security = /security-review, degrade to /land | Hard `requires:` on a backend | Zero-install; the rename unlocks it; graceful degradation beats a hard dependency that blocks the gate | 2026-06-08 | review-stage-design D4 |
| D9 | Correctness lane code-gated; default /code-review; replaceable+degrading | Always-on correctness; or no correctness lane | Always-on burns tokens on docs-only PRs; gating caps cost while shifting correctness left | 2026-06-08 | review-stage-design D9 |
| D7 | New per-segment governed spec; no git-workflow-tooling absorption | Absorb into git-workflow-tooling | First Slipstream one-spec-per-segment testbed; keeps dispatch ownership crisp | 2026-06-08 | review-stage-design D7 |
