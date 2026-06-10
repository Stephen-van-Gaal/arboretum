---
date: YYYY-MM-DD
topic: {{topic}}
status: design
related-issue: {{issue-number}}
triage: everything-else
document-shape: design-spec
implementation-mode: direct
plan: docs/plans/YYYY-MM-DD-{{topic}}.md
test-tiers:
  unit: yes
  contract: n/a - no shared definitions or seam contracts touched
  integration: n/a - no cross-module workflow touched
---

# {{Topic}} Design

<!-- Compatibility/fallback template for an AI-facing session document.

     Arboretum delegates design-spec generation to the configured build-support
     provider (currently Superpowers). Future providers may produce a different
     body shape. Arboretum must be graceful about that. The frontmatter fields
     above are the current /design -> /build handoff contract when this artifact
     is passed to /build; the body sections below are helpful guidance, not a
     full schema Arboretum owns.

     The human-facing review packet is produced by design-package from this
     session artifact. Design specs are retained as historical records and may
     be harvested by /consolidate. Durable intent/seam authority may be edited
     during /design when implementation must obey it; generated/evidence
     authority is reconciled after build. -->

## Context

<!-- HUMAN - What prompted this change? Link the tracker issue and any relevant
     existing specs, definitions, contracts, architecture sections, or prior
     design specs. -->

## Problem

<!-- HUMAN - What is wrong, missing, confusing, risky, or newly required? -->

## Intended Behaviour

<!-- HUMAN - What should be true after the change? When present, /consolidate
     may use this or equivalent behaviour-shaped provider output when it prompts
     for governed Behaviour updates. -->

## Customer Experience

<!-- HUMAN - Required when the change affects workflow steps, ship-tail
     behaviour, error or warning states, user decisions or confirmations, or
     trust boundaries where Arboretum might otherwise overclaim. Cover the
     normal path, failure or unknown path, user decision points, confidence
     claims, and what happens when Arboretum cannot know. -->

## Out Of Scope

<!-- HUMAN - What this change explicitly will not do. Include boundaries that
     agents must not cross without escalation. -->

## Existing Authority

<!-- HUMAN - Relevant governed specs, definitions, contracts, architecture
     sections, and files discovered during SURVEY. -->

| Artifact | Why it matters |
|---|---|

## Proposed Document Changes

<!-- HUMAN - Source section for design-package's Durable Document Change Set.
     List specific durable documents, operation, high-level change, why it
     matters, and phase. Phase should distinguish pre-build intent authority,
     pre-build seam authority, and finish-reconciled generated/evidence
     authority. -->

| Document | Operation | High-Level Change | Why It Matters | Phase |
|---|---|---|---|---|

## Implementation Shape

<!-- HUMAN - High-level implementation approach. Do not put a task checklist
     here; detailed execution steps belong in docs/plans/. -->

## Test Strategy

<!-- HUMAN - Explain the test tiers declared in frontmatter. Include any domain
     test cases the AI cannot infer from code alone.

     For work likely to use subagent-driven-development, or an executing-plans
     plan split into multiple independent workstreams, name external interface
     reliability concerns that planning must settle: shared input shapes,
     protected upstream schemas, adapter seams, golden fixtures, deterministic
     simulators, real-adapter contract tests, interfaces that should not be
     simulated, and stop conditions. -->

## Open Questions

<!-- HUMAN - Questions that block or constrain implementation. Mark each as
     blocking, non-blocking, or deferred. -->

| Question | Status | Proposed default |
|---|---|---|

## Decisions

<!-- APPEND-AUTO or HUMAN - Durable decisions made during design. /consolidate
     may harvest these into governed specs. A decision may lead its Decision cell
     with an optional [facet] token (e.g. "[seam] Use a single table") which
     /consolidate reads to populate the governed-spec Tags column (#682);
     otherwise Tags is left blank for human fill. Do not widen this table. -->

| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|

## Build Handoff

<!-- HUMAN - Brief instructions for /build. Name the plan path, required
     evidence, and any escape-hatch triggers. -->

- Plan: `docs/plans/YYYY-MM-DD-{{topic}}.md`
- Required evidence:
  - External Interface Reliability Pass for `subagent-driven-development` plans
    and multi-workstream `executing-plans` plans
  - RED command and expected failure for each code-bearing workstream
  - GREEN command and passing result
  - tests added or changed
  - refactor note
- Escape hatch:
  - Return to `/design` if implementation reveals a real design decision that
    this document does not settle.
