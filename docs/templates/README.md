# Document Taxonomy and Templates

This directory contains document templates Arboretum projects use to keep
AI-assisted work understandable and maintainable. The taxonomy below answers
three questions:

- Which document should hold this information?
- Which document is authoritative at each point in the workflow?
- Is this document for arboretum-dev itself, child projects, or both?

Use this document as the entry point when creating or updating governance
documents. Each template is self-documenting: copy the template when Arboretum
owns the document shape, keep the section comments until the section is filled,
and delete only the comments that no longer help the reader.

Design specs and implementation plans are different: Arboretum delegates their
generation to build-support providers (currently Superpowers, possibly other
tooling later). The templates here are fallback and adapter guidance, not a
schema Arboretum owns end-to-end. Arboretum should be graceful about provider
output and consume only the fields or evidence its workflow contracts require.

## Optional Read Profiles

Documents may declare read profiles in frontmatter when a workflow or skill can
safely consume named sections instead of the whole file. Profiles are optional;
absence of a profile means callers should fall back to an explicit section read
or a whole-file read when that is still justified.

The v1 shape is deliberately small:

```yaml
read_profiles:
  compact:
    sections:
      - Purpose
      - Behaviour
      - 'Edge Cases: punctuation & symbols?'
```

Profile names are exact and case-sensitive. Section names are resolved by
document-access tooling through normalized heading matching: leading/trailing
whitespace is trimmed, internal whitespace is collapsed, and case is ignored;
punctuation remains significant. Quote section names that contain YAML
metacharacters such as `:` so the shared YAML-lite parser treats them as scalar
list items.

## Core Rule

Each document type answers one kind of question.

| Question | Document type |
|---|---|
| What are we building and why? | Vision |
| How is the system shaped? | Architecture overview |
| How do related modules fit together? | Group document |
| What does this module promise? | Governed spec |
| What does this shared noun mean? | Definition |
| How do producer and consumer agree? | Contract |
| How do we prove correctness? | Test infrastructure spec |
| What change are we about to make? | Design spec |
| How should an agent execute the change? | Implementation plan |
| Which external seams could make multi-agent work unreliable? | External interface reliability pass |
| Where does ownership live? | Register |

Keep stable intent in human-authored sections. Keep volatile facts in generated
or easily regenerated sections.

## Project Context

Arboretum uses some document types to build Arboretum itself, and child projects
use those same document types to build their own software. Keep that distinction
explicit:

- **Child-project documents** are what Arboretum scaffolds or maintains in
  adopter repositories.
- **arboretum-dev documents** govern this framework repository.
- **Cross-cutting templates** are reusable shapes. Arboretum may use the template
  to create a filled document for itself, and may also ship the template for
  child projects.
- **Provider-owned build documents** are produced by delegated tooling. Arboretum
  may route to them, validate a handoff contract, and harvest from them, but does
  not assume their full body shape.

## Document Types

| Type | Template | Typical path | Scope | Role | Update moment |
|---|---|---|---|---|---|
| Vision | `docs/templates/vision.md` | `docs/VISION.md` or project root | Cross-cutting | Durable product charter: users, job-to-be-done, success shape, non-goals. | Project start; major strategy revision. |
| Principles | `docs/templates/PRINCIPLES.md` | `PRINCIPLES.md` | Cross-cutting | Durable engineering values and constraints the agent should preserve. | Rarely; only when operating philosophy changes. |
| Agent workflow contract | `docs/templates/ARBORETUM.md` | `ARBORETUM.md` | Cross-cutting | Canonical common pipeline rules for every code agent: `/start`, stage handoff, review-before-build, and verified low-friction exceptions. | Framework upgrade; workflow contract change. |
| Agent adapter instructions | `docs/templates/{CLAUDE,AGENTS}.md` | `CLAUDE.md` / `AGENTS.md` | Cross-cutting | Thin tool-specific entrypoints that point to `ARBORETUM.md` and add project-local testing, git, and environment details. | Framework upgrade; local tool setup change. |
| Architecture overview | `docs/templates/architecture.md` | `docs/ARCHITECTURE.md` | Cross-cutting | System map: major groups, boundaries, data flow, cross-cutting decisions. | Project setup; major topology or boundary change. |
| Group document | `docs/templates/group.md` | `docs/groups/<group>.md` | Cross-cutting | Optional middle layer for subsystems. Explains child modules, integration, orchestration, shared schemas/contracts. | When a subsystem has enough modules that a map is needed. |
| Governed spec | `docs/templates/spec.md` | `docs/specs/<topic>.spec.md` | Cross-cutting | Module-level authority: purpose, behaviour, boundaries, dependencies, owned files, tests, decisions. | Created or reconciled by `/consolidate`; active by PR time. |
| Shared definition | `docs/templates/definition.md` | `docs/definitions/<name>.md` | Cross-cutting | Shared data or concept contract used by multiple specs. Defines fields, meanings, invariants, versioning. | During design before multiple modules consume the noun; bumped on stable changes. |
| Module contract | `docs/templates/module-contract.md` | `docs/contracts/<seam>.contract.md` | Cross-cutting | Producer/consumer seam contract across skills, scripts, hooks, plugins, repos, or modules. | When drift across a seam would break another component. |
| CLI contract | `docs/templates/cli-contract.md` | `docs/contracts/<script>.cli-contract.md` | Cross-cutting | Contract variant for standalone scripts invoked by humans, skills, or CI. | When a script has external callers or CI coverage expectations. |
| Test infrastructure spec | `docs/templates/test-infrastructure.spec.md` | `docs/specs/test-infrastructure.spec.md` | Child projects + arboretum-dev | Declares the default-safe test command, test tiers, fixture conventions, and opt-in test commands. | Project setup; test runner or suite-shape change. |
| Design spec | `docs/templates/design-spec.md` | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` | Provider-owned build support | Pre-build authority for non-trivial work. Arboretum requires only the handoff fields needed by `/build`; body shape may vary by provider. | Provider invoked by `/design`; before `/build`. |
| Implementation plan | `docs/templates/plan.md` | `docs/plans/YYYY-MM-DD-<topic>.md` | Provider-owned build support | Agent execution plan. Arboretum consumes checkboxes, test evidence, and references where available; body shape may vary by provider. | Provider invoked during `/design` plan fold-in; consumed by `/build`. |
| Patch brief | `docs/templates/patch-brief.md` | `.arboretum/patch-briefs/<issue>.md` | Arboretum-owned build support | S2-compatible brief proving a bug report is an authority-backed local patch that may enter `/build` without the everything-else design review. | Produced by `/start-bugfix`; consumed by `/build`. |
| External interface reliability pass | `docs/templates/plan.md` | Section inside a provider-owned plan | Provider-owned build support | Multi-agent reliability check: names external interfaces, contracts, fixtures/simulators, real-adapter tests, safety rules, and stop conditions. | Before a multi-agent plan is finalized. |
| Register | `docs/templates/register.md` | `docs/REGISTER.md` | Cross-cutting | Generated ownership index for definitions, specs, and owned files. Navigation surface, not design prose. | Regenerated by governance scripts or `/consolidate`. |
| Workflow profile | `docs/templates/workflow.md` | `workflows/<name>.md` | arboretum-dev | Workflow-as-component profile with job, boundaries, sequence, skills, tests, decisions. | Framework workflow changes. |

## How To Choose

- If the information explains a user outcome or product commitment, put it in
  the vision or a governed spec's Behaviour section.
- If it explains system topology, put it in architecture or a group document.
- If it names a shared framework concept or cross-document vocabulary, check
  `docs/definitions/concept-catalog.md` first. If the concept is new and can
  drift across specs, add or update a catalog row before scattering the term
  across templates, skills, or issue bodies. If it is a data structure or
  versioned noun consumed by multiple specs, put the detailed shape in its own
  definition and cite it from the catalog where useful.
- If it names a producer/consumer protocol, put it in a contract.
- If it explains why a change is being made now, put it in a provider-owned
  design spec or equivalent build-support artifact.
- If it explains the steps an agent should execute, put it in a provider-owned
  plan or equivalent execution artifact.
- If it explains why a bug report is safe to patch without the everything-else
  design review, put it in a patch brief.
- If a plan splits work across subagents or independent workstreams, include an
  External Interface Reliability Pass before the task list.
- If it is a volatile fact about current files, tests, or ownership, prefer an
  AUTO section or generated register entry.

## Minimum Set By Project Size

Small projects can start with:

- `CLAUDE.md` / `AGENTS.md`
- `PRINCIPLES.md`
- `docs/ARCHITECTURE.md`
- `docs/specs/test-infrastructure.spec.md`
- one governed spec per module that changes
- `docs/REGISTER.md`

Projects around the size of `conversations`, or a little larger, should add:

- group documents for major subsystems
- shared definitions for cross-module records and policy concepts
- seam contracts for risky producer/consumer boundaries
- retained design specs and implementation plans for non-trivial changes

Larger projects should treat group documents and contracts as first-class
navigation aids. If readers routinely need to load five specs to understand one
change, add or refresh the group document.

## Workflow Placement

Document work spans the workflow:

- `/design` delegates build-specific artifacts to the configured provider:
  currently a design spec and plan from Superpowers. Arboretum records or
  validates only the handoff contract and planning evidence it needs for later
  stages. For multi-agent plans, that evidence includes the external interface
  reliability pass described in the plan template.
- `/build` captures evidence: tests, RED/GREEN commands, changed files, changed
  seams, escape-hatch triggers.
- `/consolidate` makes the durable state current: governed specs, register,
  AUTO sections, decisions, and stale HUMAN-section flags.
- `/health-check` detects drift after the fact.

In short: providers author build intent, build produces evidence, consolidate
makes durable Arboretum docs current.
