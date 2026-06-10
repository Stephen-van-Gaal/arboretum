---
version: 1
name: {{spec-name}}
status: draft
owner: {{group-name or "architecture"}}
document-shape: governed-spec
owns: []
# areas:                       # OPTIONAL — declare intra-spec facets (retrieval-only).
#   - name: <slug>             # If ≥1 area is declared, split-assessment is REQUIRED.
#     summary: <one line>      # Forcing rule: ≥2 distinct ### Behaviour facets ⇒ declare + assess.
#   split-assessment: "Run the Area-vs-split gate (docs/specs/document-taxonomy.spec.md § Area-vs-split gate): areas of ONE component, or split into specs under a group? State the call."
#   # split-assessment is a single-line string — the frontmatter parser does not accept `|` block scalars.
# governs-narrative: docs/ARCHITECTURE.md §X.Y    # optional; required when status=active and owns:[] — cites the narrative section this spec governs inside a shared document
---

# {{Spec Name}}

<!-- Section authorship (human / auto / append-auto) is declared once in
     docs/templates/document-shapes.yaml (the `authorship:` field per section) —
     not repeated inline. /consolidate regenerates auto sections, preserves human
     sections, and appends to append-auto sections. -->

## Purpose

<!-- Why does this exist? What problem does it solve? One paragraph. -->

## Boundaries (non-goals)

<!-- What this module deliberately does NOT own. Use this to keep specs from
     becoming junk drawers. Each non-goal should point to the spec, group,
     external system, or future issue that does own the concern. -->

## Behaviour

<!-- What should the system do? Be as detailed as you want — this is how you steer
     the AI. INVARIANT: this section must be implementable without opening any
     ephemeral doc. Links to design specs are provenance only, never substitution
     — no "see the design spec" pointers. "Self-contained" means the PROMISE:
     reference shared peers (contracts, definitions, architecture cross-cutting
     concepts) rather than inlining them. State invariants (always-true
     properties) inline here; promote testable ones to Quality Attributes. -->

## Quality Attributes

<!-- OPTIONAL — component NFRs as testable scenarios (latency, token-cost, safety,
     idempotency); each names how it is verified. Declare "N/A — [reason]" when the
     component inherits project NFRs or has none. Project-wide NFRs live in
     ARCHITECTURE, not here. -->

N/A — declare component NFRs as testable scenarios, or state why none apply.

## Customer Experience

<!-- OPTIONAL-PROMOTED — REQUIRED when the component is user/operator-facing: the
     normal path, the failure/unknown path, and the user's decision points.
     Declare "N/A — non-interactive" otherwise. The full journey stays in the
     design-spec / vision. -->

N/A — non-interactive (or describe what the human sees, what they decide, and the
confidence Arboretum is claiming).

## Requires

<!-- Inbound seam (= a contract's `consumes`). Shared definitions, contracts,
     specs, or external systems this spec depends on; one row per dependency. The
     Definition column names the AUTHORITY: a cited docs/contracts/*.contract.md
     when one exists (referenced, never restated), else the inline schema. A
     contract file is required for (i) any script/CLI surface and (ii) a stable
     multi-consumer interface where cross-consumer drift is a real risk; otherwise
     the row IS the contract (inline).

     For shared definitions, cite the parser-visible pin `definitions/<name>.md@vN`
     (no `docs/` prefix) — sync-contracts.sh and validate-cross-refs.sh scan for
     that exact form. For spec-to-spec dependencies, cite the spec path. If there
     are no dependencies, write "N/A — no inbound dependencies." -->

| Dependency | Source | Definition |
|------------|--------|------------|

## Provides

<!-- Outbound seam (= a contract's `produces`). Public surfaces this spec provides
     to other specs or external consumers: exported functions, commands, events,
     files, schemas, adapters, or behaviours. Same Definition-names-authority +
     inline-vs-contract rule as Requires.

     For shared definitions, use the exact pin `definitions/<name>.md@vN` in the
     Definition column. If the module has no public surface beyond its own
     behaviour, write "N/A — no outbound contracts." -->

| Export | Type | Definition |
|--------|------|------------|

## Tests

<!-- Regenerated from test files. Lists each test by name with tier
     (unit/contract/integration). Declare "N/A — [reason]" for inapplicable tiers. -->

## Implementation Notes

<!-- Free-text implementation guidance plus the Design record changelog below.
     File locations, constraints, and guidance for implementation. -->

### Design record

<!-- Dated provenance changelog — one row per design spec / plan referenced by this
     spec's history. Provenance only (distinct from Decisions); no embedded design
     content. Idempotency key: Artifact. Example row:
     | 2026-04-20 | docs/superpowers/specs/2026-04-20-topic-design.md | Behaviour, Decisions | Initial promotion of <topic>. | -->

| Date | Artifact | Sections changed | Summary |
|------|----------|------------------|---------|

## Decisions

<!-- /consolidate harvests new rows from design specs and plans. Existing rows are
     never modified or removed. The Source column is the idempotency key —
     /consolidate does not re-add a decision whose source artifact + decision ID is
     already cited. The human can also add rows manually with Source: human (or a
     free-text citation). Every row carries Alternatives Considered + Rationale —
     never a reduced ID·Decision·Source schema. -->

| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|
