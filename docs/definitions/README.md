---
name: definitions-index
version: v1
status: active
read_profiles:
  compact:
    sections:
      - Description
      - Controlled Vocabulary Inventory
      - Consumption Rules
      - Distribution Constraints
      - Related Access Tools
---

# Definitions

## Status
active

## Version
v1

## Description

This directory is the primary entry point for Arboretum shared definitions and
controlled vocabularies. Use it to decide which vocabulary exists, what job it
does, and where the canonical values live before loading a whole spec or
inventing a parallel term.

This README is an index. It points to vocabulary owners; it does not duplicate
their full value sets.

## Controlled Vocabulary Inventory

| Vocabulary | Job | Canonical values live in | How to consume |
|---|---|---|---|
| Concept anchors | Name cross-cutting Arboretum concepts, aliases, owner authorities, and drift rules. | `docs/definitions/concept-catalog.md` | Read the `compact` profile for naming context, then read the owner surface before changing behavior. |
| Document section keys and shapes | Give agents predictable semantic keys for bounded document discovery and retrieval. | `docs/definitions/document-section-schema.md` and `docs/templates/document-shapes.yaml` | Run `scripts/explore-doc.sh` first, then `scripts/read-doc-sections.sh` for specific keys. |
| Read profiles | Name compact bundles of sections declared in document frontmatter. | `docs/contracts/read-doc-profile.cli-contract.md` | Run `scripts/read-doc-profile.sh <document> <profile>` only when the document declares that profile. |
| Spec statuses | Define governance lifecycle states and status mutation rules. | `docs/definitions/spec-status-state-machine.md` and project `.arboretum.yml` overrides | Follow the vocabulary of the surface being edited; do not introduce a third enum. |
| Roadmap labels and readiness states | Classify tracker work, horizons, components, audiences, and agent-ready routing state. | `docs/templates/roadmap.config.yaml`, `skills/roadmap/SKILL.md`, `scripts/roadmap/lib.sh`, and `scripts/verify-agent-ready.sh` | Use roadmap helper scripts rather than hand-mutating labels or states. |
| Workflow routes, stages, and modes | Name build/ship pipeline routing, stage handoffs, Branch 1 modes, and implementation modes. | `workflows/`, `skills/`, `docs/contracts/s2-design-to-build.contract.md`, and `docs/contracts/s3-build-to-finish.contract.md` | Use stage skills and S2/S3 validators as the executable boundary. |
| Stage-log actions | Define the closed action vocabulary for pipeline-state log comments. | `docs/contracts/s9-stage-to-log-helper.contract.md` | Emit log rows through `scripts/log-stage.sh`; do not write raw provider comments. |
| Autonomy grants | Define the closed `autonomy:*` tier vocabulary and the `.arboretum.yml autonomy:` gate parameters set at the design→build grant gate. | `scripts/roadmap/install-labels.sh`, `scripts/read-autonomy-config.sh`, `scripts/read-autonomy-grant.sh`, `docs/contracts/read-autonomy-config.cli-contract.md`, and `docs/contracts/read-autonomy-grant.cli-contract.md` | Set the grant via the design-gate affordance (exclusive `autonomy:*` label); read gate parameters through `read-autonomy-config.sh`. Unlabelled = design-only. |
| Release intent | Declare dev-only release-package impact and state. | Authority unavailable in public/adopter checkouts. | Keep release materialization in dev release tooling; public PR bodies and public/adopter checkouts do not own this vocabulary. |
| Review configuration and cadence | Configure reviewer request mechanisms and timing expectations. | `.arboretum.yml`, `docs/contracts/read-review-config.cli-contract.md`, `docs/contracts/request-review.cli-contract.md`, `docs/contracts/collect-review.cli-contract.md`, `scripts/read-review-config.sh`, `scripts/request-review.sh`, and `scripts/collect-review.sh` | Request and collect review through the configured review scripts. |
| Install manifests | Track framework-managed files during plugin upgrade. | `docs/definitions/install-manifest-schema.md` and `docs/contracts/upgrade-sync.cli-contract.md` | Let `scripts/upgrade-sync.sh` read and write manifest state. |

## Consumption Rules

- Read this index first when a change touches shared vocabulary, controlled
  states, document section keys, workflow routes, labels, release intent, or
  review cadence.
- Read the canonical owner for exact values. This index describes jobs and
  ownership; it is not the source of every allowed value.
- Do not duplicate a controlled value list in a second document unless the
  owner explicitly says that surface is generated from or synchronized with the
  canonical owner.
- When adding a new vocabulary, create or update the canonical owner first,
  then add an inventory row here with the consumption rule agents should follow.

## Distribution Constraints

This index is shipped to public/adopter checkouts, while arboretum-dev specs,
plans, design docs, register files, and dev release contracts are filtered from
public sync. The compact inventory above intentionally names shipped authorities
only. Treat repo-relative owner paths as read targets only when those paths exist
in the current checkout.

When a dev-only owner is absent, use the public surfaces named in the inventory:
skills, workflows, templates, contracts, helper scripts, and local project
configuration. If no public surface exists for a vocabulary, surface an
authority-unavailable warning and do not claim the missing owner was consulted.

## Related Access Tools

| Tool | Use |
|---|---|
| `scripts/explore-doc.sh <document>` | Discover a document's shape and available semantic keys without retrieving content. |
| `scripts/read-doc-sections.sh <document> <key> [...]` | Retrieve selected sections by semantic key or alias. |
| `scripts/read-doc-profile.sh <document> <profile>` | Retrieve a named compact section bundle from frontmatter metadata. |
| `scripts/read-doc-section.sh <document> <heading>` | Retrieve one uniquely matching Markdown heading by normalized heading text. |

## Arboretum-Dev Supplemental Authorities

These references are not part of the compact profile because they are filtered
from public/plugin-shaped checkouts. Read them only in arboretum-dev checkouts
where the path exists.

| Vocabulary | Dev-only supplement |
|---|---|
| Read profiles | `docs/specs/document-access.spec.md` |
| Roadmap labels and readiness states | `docs/specs/roadmap.spec.md` |
| Workflow routes, stages, and modes | `docs/specs/workflow-unification.spec.md` |
| Release intent | `docs/specs/arboretum-as-plugin.spec.md` and `docs/dev-contracts/release/release-intent.cli-contract.md` |
| Review configuration and cadence | `docs/specs/git-workflow-tooling.spec.md` |

## Consumers And Providers

| Spec | Role | Notes |
|---|---|---|
| document-taxonomy | Provider | Owns this directory index and the definition/document-shape taxonomy. |
| document-access | Consumer | Uses definition and shape metadata to support bounded document reads. |
| workflow-unification | Consumer | Reads the compact profile during `/design` for vocabulary-sensitive survey work. |

## Changelog

| Date | Version | Change | Affected Specs |
|---|---|---|---|
| 2026-06-06 | v1 | Added the definitions directory entry point, controlled vocabulary inventory, and public/adopter distribution constraints. | document-taxonomy, document-access, workflow-unification |
