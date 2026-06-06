---
name: concept-catalog
version: v2
status: active
read_profiles:
  compact:
    sections:
      - Description
      - Schema
      - Catalog
      - Constraints
---

# Concept Catalog

## Status
active

## Version
v2

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
| roadmap-idea | Low-ceremony captured work that is not yet shaped or prioritized. | roadmap | `docs/specs/roadmap.spec.md` `/idea` section; public fallback `skills/idea/SKILL.md` and `docs/templates/issue-templates/work-later.md` | work-later, horizon:later | Issue templates and `/idea` prose must preserve the same capture-only meaning. |
| tracker-label | Label vocabulary used to classify tracker work and state. | roadmap | `docs/specs/roadmap.spec.md` label vocabulary; public fallback `docs/templates/roadmap.config.yaml` and `scripts/roadmap/lib.sh` | type labels, horizon labels, component labels, state markers | Label docs, templates, and roadmap helper behavior must not redefine label families independently. |
| readiness-state | State marker that changes how workflow routing treats a tracker item. | roadmap | `docs/specs/roadmap.spec.md` `/roadmap agent-prep` section; public fallback `skills/roadmap/SKILL.md` and `scripts/verify-agent-ready.sh` | agent-ready, agent-prep:in-progress, blocked | `/start`, `/roadmap agent-prep`, and issue templates must agree on readiness semantics. |
| workflow-route | Named path through Arboretum's build workflow. | workflow-unification | `workflows/build.md` and `skills/start/SKILL.md` | agent-target, everything-else, patch lane, Branch 1 mode | Workflow docs and stage skills must agree on routing vocabulary. |
| pipeline-stage | Named lifecycle step in the unified build workflow and ship tail. | workflow-unification | `docs/specs/workflow-unification.spec.md` `The unified workflow shape` section; public fallback `workflows/build.md` and stage skills under `skills/` | /start, /design, /build, /finish, /security-review, /pr, /land, /cleanup, /reflect | Workflow docs, stage skills, and pipeline-state logs must agree on stage names. |
| branch-mode | Mode dispatch inside `/design` or `/build` that changes how the shared workflow executes without creating a top-level workflow fork. | workflow-unification | `docs/specs/workflow-unification.spec.md` Branch 1 and Branch 3 sections; public fallback `skills/design/SKILL.md`, `skills/build/SKILL.md`, `docs/contracts/s2-design-to-build.contract.md`, and `docs/contracts/s3-build-to-finish.contract.md` | brainstorm, investigate, coverage-baseline, none, direct, executing-plans, subagent-driven-development | Mode names in S2 frontmatter, workflow prose, and skill dispatch must stay synchronized. |
| agent-ready | Tracker readiness state proving a human has prepared an issue for autonomous agent pickup and freshness verification. | roadmap | `docs/specs/roadmap.spec.md` agent-ready sections; public fallback `skills/roadmap/SKILL.md` and `scripts/verify-agent-ready.sh` | agent-target, readiness-state, agent-prep:in-progress | `/roadmap agent-prep`, `/start`, issue labels, and decay checks must preserve the same meaning. |
| patch-lane | Experimental `/start-bugfix` front half for authority-backed local bug reports that can produce a verified patch brief. | workflow-unification | `docs/specs/workflow-unification.spec.md` `Experimental patch lane` section; public fallback `skills/start-bugfix/SKILL.md` and `docs/templates/patch-brief.md` | start-bugfix, patch brief, patchability gate | Patch-lane prose, patch brief template, and build handoff validation must agree on the exception boundary. |
| design-session-document | AI-facing design artifact that carries S2 frontmatter, implementation context, plan handoff, tests, and operational notes. | document-taxonomy | `docs/templates/design-spec.md` | design spec, session document, AI-facing session artifact | `/design`, `design-package`, and design-spec templates must preserve the split from human review packets. |
| design-package | Slipstream skill inside `/design` that turns a recognized session artifact into the human review packet and Durable Document Change Set. | workflow-unification | `skills/design-package/SKILL.md` | session overview, review packet, durable-doc diff | `/design` and smoke tests must keep plan fold-in before design-package validation. |
| durable-document-change-set | File-specific review list of durable documents to create, modify, or retire, with phase and reason. | document-taxonomy | `docs/templates/design-spec.md` `Proposed Document Changes` section | durable-doc diff, pre-build intent authority, seam authority | Design templates, `design-package`, and workflow review gates must preserve the same columns and phase boundary. |
| document-shape | Cataloged document structure with semantic section keys. | document-taxonomy | `docs/templates/document-shapes.yaml` | semantic key, read profile, bounded read | Shape metadata and document-access retrieval must preserve the same keys and aliases. |
| customer-operator-experience | The human-facing experience of workflow states, failures, claims, and decision points. | document-taxonomy | `skills/design/SKILL.md` customer/operator experience check | customer experience, operator experience, trust boundary | Design specs that affect workflow behavior should describe normal path, failure path, decisions, and confidence claims. |
| bounded-read | Read-only retrieval of selected document sections instead of whole-file context injection. | document-access | `docs/specs/document-access.spec.md` `Behaviour` section; public fallback `scripts/explore-doc.sh`, `scripts/read-doc-sections.sh`, and `docs/contracts/document-access-format.contract.md` | section read, compact read, inject narrowly | Document-access scripts and workflow survey guidance must prefer discovery and semantic retrieval before whole-file reads. |
| read-profile | Named frontmatter recipe listing sections that can be read as a compact bundle. | document-access | `docs/contracts/read-doc-profile.cli-contract.md` | compact profile, read_profiles.compact.sections | Read-profile metadata, parser contracts, and consumers must use the same profile shape. |
| semantic-section-key | Stable section identifier used by document shape metadata and document-access retrieval. | document-taxonomy | `docs/definitions/document-section-schema.md` | section key, shape key, alias | Shape metadata, templates, and read-doc-sections consumers must preserve keys and aliases. |
| public-report | Reporter-facing public issue used to capture Arboretum problems or enhancements before dev-side triage. | intake-report | `docs/specs/intake-report.spec.md`; public fallback `skills/report/SKILL.md`, `skills/report/templates/problem.md`, `skills/report/templates/enhancement.md`, and public report issue forms | problem report, enhancement report, public intake | Public issue templates, report skill prose, and dev-bridge rules must preserve the same trust boundary. |
| release-intent | Dev-only declaration of public release impact consumed by Arboretum release-package tooling. | arboretum-as-plugin | `docs/specs/arboretum-as-plugin.spec.md` release materialization sections; dev-only fallback `docs/dev-contracts/release/release-intent.cli-contract.md` when present | Release Intent, release package, release-impact | Public workflow prose must not imply release materialization; public/adopter checkouts should treat release materialization as unavailable. |
| review-cadence | Configured timing or cadence expectation for strategic review or PR reviewer re-request behavior. | git-workflow-tooling | `docs/specs/git-workflow-tooling.spec.md` reviewer configuration decisions; public fallback `.arboretum.yml`, `scripts/read-review-config.sh`, `scripts/request-review.sh`, and `scripts/collect-review.sh` | reviewer cadence, re-review, strategic review cadence | Review config, request-review, collect-review, and health/roadmap cadence language must not redefine cadence independently. |
| controlled-vocabulary-inventory | Directory-level index of controlled vocabularies, their jobs, owners, and consumption rules. | document-taxonomy | `docs/definitions/README.md` `Controlled Vocabulary Inventory` section | vocabulary index, definitions index, glossary inventory | New controlled vocabularies should update the canonical owner first, then add or update the inventory row without duplicating the value list. |
| shared-definition | Versioned cross-spec noun or data structure. | document-taxonomy | `docs/templates/README.md` shared definition row | definition, shared noun, concept contract | Specs that depend on a shared definition should cite `definitions/<name>.md@vN`. |
| concept-catalog | Shared definition that indexes canonical concept anchors. | document-taxonomy | `docs/definitions/concept-catalog.md` | concept anchor, concept taxonomy | New concept-anchor slices must update this definition before adding trace links or resolver tooling. |

## Constraints

- Concept IDs are stable API for future trace-link and resolver tooling.
- A catalog row points to authority; it does not replace the authority.
- Related terms are aliases or neighbors, not independent concept definitions.
- Trace Links and Resolver Tooling are deferred follow-up slices from issue #547.
- Adding a new concept ID requires a meaningful owner and canonical surface.
- Public/adopter checkouts may not contain arboretum-dev `docs/specs/`,
  `docs/plans/`, `docs/superpowers/`, or `docs/dev-contracts/` paths. Read
  repo-relative owner and canonical paths only when those paths exist in the
  current checkout; otherwise use the public fallback surfaces named in the row
  and surface an authority-unavailable warning before relying on a missing
  owner.

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
| 2026-06-05 | v2 | Added compact serving profile, controlled-vocabulary inventory anchor, public/adopter fallback guidance, and broader curated concept anchors for Slipstream design-context loading. | document-taxonomy, roadmap, intake-report, workflow-unification, document-access, git-workflow-tooling, arboretum-as-plugin |
| 2026-06-05 | v1 | Initial concept-anchor catalog for issue #551. | document-taxonomy, roadmap, intake-report, workflow-unification |
