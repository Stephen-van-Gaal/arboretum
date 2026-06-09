---
seam: design-to-spec-promotion
version: 1.0
producer-type: skill
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-06-08-671-component-spec-richness-design.md
---
<!-- owner: pipeline-contracts-template -->

# Promotion — `/design` → governed-spec Promotion Contract

The seam between `/design` (which authors durable intent) and the permanent
governed-spec it creates. At design→spec creation, `/design` promotes design-spec
intent into the permanent spec's HUMAN sections; the permanent spec must then
stand alone. This contract pins **what** crosses the seam. The **when/how** —
pipeline timing, the design-time-vs-build-time boundary, and the concrete
`/design` + `/consolidate` skill steps — is owned by **#686**; the enforcement
validators by **#685**.

## Producer

`/design` — `skills/design/SKILL.md`. Producer-type: `skill`. Promotes design-spec
intent into the permanent governed-spec's HUMAN sections at creation.

## Consumer

`/consolidate` — `skills/consolidate/SKILL.md`. Consumer-type: `skill`.
`/consolidate` reconciles the generated/evidence sections around the promoted
HUMAN content and must not overwrite it. (The promoted spec is also read
downstream by humans and agents, who rely on it being self-contained — but
`/consolidate` is the contractual consumer of this seam.)

## Protocol shape

### Inputs

The producer reads the **durable** content of the ephemeral design spec
(`docs/superpowers/specs/*-design.md`): its Intended Behaviour / Behaviour prose,
its Decisions (with Alternatives + Rationale), and its seam declarations.

### Outputs

At design→spec creation the producer writes, into the permanent governed-spec's
HUMAN sections, the four **must-promote** items:

- **Self-contained Behaviour** — the durable promise, implementable without
  opening any ephemeral doc. "Self-contained" means the promise: shared peers
  (seam contracts, definitions, architecture cross-cutting concepts) are
  referenced, never inlined.
- **Decisions with Alternatives + Rationale** — never a reduced
  `ID · Decision · Source` schema; the rationale carries the traps, not just the
  choice.
- **Seam** — `Requires`/`Provides`, escalated to a cited
  `docs/contracts/*.contract.md` per the spec template's inline-vs-contract rule
  (a contract is required for script/CLI surfaces and stable multi-consumer
  interfaces; otherwise the row carries the schema inline).
- **Provenance** — a `### Design record` changelog entry
  (Date / Artifact / Sections changed / Summary).

### Invariants

- **Provenance only, never substitution.** Links from the permanent spec to
  ephemeral design specs are provenance only — no "see the design spec" pointers.
  The permanent spec must be comprehensible and implementable without opening any
  ephemeral document.
- **Promotion is additive to HUMAN authority.** The producer writes HUMAN
  sections; `/consolidate` preserves them and reconciles only the
  generated/evidence sections around them.
- **WHAT vs WHEN/HOW boundary.** This contract is the shared seam between #671
  (the content model: what a rich spec carries and what crosses) and #686 (the
  mechanics: when promotion runs and how the skills execute it). #671 owns this
  WHAT; #686 owns the WHEN/HOW; #685 owns the validators that enforce it.

## Test surface

The checks below are the named enforcement surface (#685 owns their
implementation; #671 names them so the contract is not hollow-by-accident):

- **P-1: No-pointer Behaviour.** A promoted Behaviour contains no
  "see the design spec"-style substitution pointer.
- **P-2: Decisions carry rationale.** Every Decisions row has non-empty
  Alternatives Considered + Rationale.
- **P-3: Seam captured.** `Requires`/`Provides` either cite a contract or carry
  an inline schema; a script/CLI surface cites a contract.
- **P-4: Provenance present.** A `### Design record` changelog row exists for the
  source design spec.
- **P-5: Self-contained.** The Behaviour does not inline a peer contract's field
  schema (referenced, not restated).

## Versioning

- **1.0** (2026-06-08) — initial contract; the design→spec promotion seam for the
  component-spec content model (#671). Producer `/design`; consumer
  `/consolidate` + spec readers.
