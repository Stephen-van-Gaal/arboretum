---
name: concept-catalog
version: v1
status: active
---

# Concept Catalog

## Status
active

## Version
v1

## Description

The concept catalog defines shared Arboretum concept anchors: stable names for
framework ideas that appear across issues, specs, templates, skills, scripts,
and git history. It helps humans and agents find the canonical authority before
adding new terminology.

## Schema

Each catalog row uses these fields:

- Concept ID - stable lowercase identifier with words separated by hyphens.
- Meaning - short definition of the concept.
- Owner - governed spec or authority document that owns detailed behaviour.
- Canonical surface - the primary document section or file to read first.
- Related terms - aliases or near-neighbor phrases that should not become
  separate authorities without a design decision.
- Drift rule - what must stay synchronized when the concept changes.

## Catalog

| Concept ID | Meaning | Owner | Canonical surface | Related terms | Drift rule |
|---|---|---|---|---|---|
| roadmap-idea | Low-ceremony captured work that is not yet shaped or prioritized. | roadmap | `docs/specs/roadmap.spec.md` `/idea` section | work-later, horizon:later | Issue templates and `/idea` prose must preserve the same capture-only meaning. |
| tracker-label | Label vocabulary used to classify tracker work and state. | roadmap | `docs/specs/roadmap.spec.md` label vocabulary | type labels, horizon labels, component labels, state markers | Label docs, templates, and roadmap helper behavior must not redefine label families independently. |
| readiness-state | State marker that changes how workflow routing treats a tracker item. | roadmap | `docs/specs/roadmap.spec.md` `/roadmap agent-prep` section | agent-ready, agent-prep:in-progress, blocked | `/start`, `/roadmap agent-prep`, and issue templates must agree on readiness semantics. |
| workflow-route | Named path through Arboretum's build workflow. | workflow-unification | `workflows/build.md` and `skills/start/SKILL.md` | agent-target, everything-else, patch lane, Branch 1 mode | Workflow docs and stage skills must agree on routing vocabulary. |
| document-shape | Cataloged document structure with semantic section keys. | document-taxonomy | `docs/templates/document-shapes.yaml` | semantic key, read profile, bounded read | Shape metadata and document-access retrieval must preserve the same keys and aliases. |
| customer-operator-experience | The human-facing experience of workflow states, failures, claims, and decision points. | document-taxonomy | `skills/design/SKILL.md` customer/operator experience check | customer experience, operator experience, trust boundary | Design specs that affect workflow behavior should describe normal path, failure path, decisions, and confidence claims. |
| public-report | Reporter-facing public issue used to capture Arboretum problems or enhancements before dev-side triage. | intake-report | `docs/specs/intake-report.spec.md` | problem report, enhancement report, public intake | Public issue templates, report skill prose, and dev-bridge rules must preserve the same trust boundary. |
| shared-definition | Versioned cross-spec noun or data structure. | document-taxonomy | `docs/templates/README.md` shared definition row | definition, shared noun, concept contract | Specs that depend on a shared definition should cite `definitions/<name>.md@vN`. |
| concept-catalog | Shared definition that indexes canonical concept anchors. | document-taxonomy | `docs/definitions/concept-catalog.md` | concept anchor, concept taxonomy | New concept-anchor slices must update this definition before adding trace links or resolver tooling. |

## Constraints

- Concept IDs are stable API for future trace-link and resolver tooling.
- A catalog row points to authority; it does not replace the authority.
- Related terms are aliases or neighbors, not independent concept definitions.
- Trace Links and Resolver Tooling are deferred follow-up slices from issue #547.
- Adding a new concept ID requires a meaningful owner and canonical surface.

## Consumers And Providers

| Spec | Role | Notes |
|---|---|---|
| document-taxonomy | Provider | Owns the catalog definition and drift-prevention smoke test. |
| roadmap | Consumer | Uses concept rows for tracker ideas, labels, and readiness states. |
| intake-report | Consumer | Uses concept rows for public report and trust-boundary vocabulary. |
| workflow-unification | Consumer | Uses concept rows for workflow route vocabulary. |

## Changelog

| Date | Version | Change | Affected Specs |
|---|---|---|---|
| 2026-06-05 | v1 | Initial concept-anchor catalog for issue #551. | document-taxonomy, roadmap, intake-report, workflow-unification |
