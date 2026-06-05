<!--
  PRINCIPLES.md — adopter-editable template.

  This file ships from arboretum's docs/templates/ into the consumer
  project's repository root via /arboretum:init or scripts/bootstrap-project.sh.
  Treat it as starting material, not framework infrastructure:

  - The **Practices:** lines reference `docs/ARCHITECTURE.md §3 #N`. Those
    section anchors exist in *arboretum's* ARCHITECTURE doc, not yours.
    If your project has its own ARCHITECTURE.md, either replace those
    refs with anchors that exist there, or strip them entirely.
  - Add, remove, or reword principles to match your project's stance.
    The principles below are a starting set, not a fixed contract.

  arboretum-dev itself uses the in-repo copy at this same path
  (`docs/templates/PRINCIPLES.md`) as its authoritative principles
  document; the cross-refs resolve correctly within this repo.
-->

# Principles

Arboretum is an organizational framework for AI-assisted software development. These principles guide how projects are structured when an AI agent writes most of the code and the human is a domain expert steering the work.

## 1. Decide before you build, describe after you ship

Write down what you want and why before any code exists — that intent steers the agent. Once the work is shipped, generate the owning spec from the built state, not from the plan. Plans and brainstorms reflect starting-state assumptions; specs reflect what is.

**Practices:** Spec-first design (`docs/ARCHITECTURE.md` §3 #1).

## 2. Every code file has one owner

One spec owns each source-code file — no shared ownership, no orphans. Documentation files are standalone; they ARE the canonical statement, so a governing spec would be hat-on-a-hat.

When you didn't write every line yourself, this is how you answer "why does this exist?" — find the owning spec for code, or read the doc directly.

**Practices:** Bidirectional ownership (`docs/ARCHITECTURE.md` §3 #2).

## 3. Humans own the what and why. AI owns the how

The human writes purpose and behaviour. The AI derives implementation, cross-references, and boilerplate. This keeps the human in control of the decisions that matter.

**Practices:** Humans-own-what / AI-owns-how (`docs/ARCHITECTURE.md` §3 #3).

## 4. Make change safe by making it small

Single ownership, explicit dependencies, bounded specs — these exist so that changing one thing doesn't silently break another. The goal isn't to prevent change, it's to make change predictable.

**Practices:** Atomic commits / single-issue PRs (`docs/ARCHITECTURE.md` §3 #4).

## 5. Right-size the structure

A 500-line project doesn't need version-pinned contracts. Start with the minimum structure that keeps things traceable. Add governance when you feel the pain of not having it — not before.

**Practices:** Right-sized structure (`docs/ARCHITECTURE.md` §3 #5).

## 6. Use what exists

Arboretum is choreography. The hard work — brainstorming, planning, TDD, debugging, code review — belongs to specialists like superpowers. Workflows declare *abstract capabilities* they need; specific providers plug in to fill them. Capabilities are stable; providers are swappable. Do not reimplement what the ecosystem provides.

**Practices:** Capability slot abstraction (`docs/ARCHITECTURE.md` §3 #7).

## 7. Learn from each cycle

After shipping a change, capture what surprised you — what the AI got wrong, what the spec missed, what worked unexpectedly well. Domain expertise grows fastest when you reflect while context is fresh.

**Practices:** Reflective post-cycle capture (`docs/ARCHITECTURE.md` §3 #10).

## 8. Wrap external tools, don't invoke them naked

When arboretum integrates an external skill or tool, it wraps the call with three responsibilities: a project-aware brief encoding the project's conventions; captured user contributions for domain knowledge the AI cannot infer; post-delegation verification that the output meets the brief. Wrapping is what turns generic-correct work into project-correct work — without it, external skills produce outputs that need manual reconciliation against project conventions.

**Practices:** Wrapped delegation (`docs/ARCHITECTURE.md` §3 #6).

## 9. The LLM is a customer

Arboretum has two customers: the domain expert and the LLM that helps them. Every artifact arboretum produces must be readable and actionable by **both** (dual-audience). The LLM, lacking persistent memory, must be re-grounded in project state at every session start. Treat the LLM's needs as first-class — not as a side effect of serving the human.

**Practices:** Dual-audience artifacts (`docs/ARCHITECTURE.md` §3 #8); Session-start grounding (`docs/ARCHITECTURE.md` §3 #9).

## 10. Tests are classified on two axes

Test classification is two-dimensional, not one:

- **Scope** — `unit` (isolated) → `contract` (conformance to a shared definition) → `integration` (cross-spec interaction). Declared per change in each design spec's `test-tiers:` frontmatter; declare `N/A — <reason>` for inapplicable tiers.
- **Cost-class** — `default` (free, deterministic, always run) / `live` (hits real services, opt-in) / `costly` (incurs monetary cost, opt-in). Declared once per project in `test-infrastructure.spec.md`.

The two axes are independent: a unit-scope test can be `costly`; an integration-scope test can be `default` when it uses fakes. Automated gates run only the `default` cost-class; `live` and `costly` tiers are opt-in, run by a human on demand.

**Practices:** Two-axis test classification (`docs/specs/test-infrastructure.spec.md`; declared command read by `/build`, `/finish`, `/design` via `scripts/read-test-config.sh`).

---

## The unified workflow

Arboretum's current general-release pipeline, `unified`, has one development workflow — `build` — covering all changes to existing projects (features, bug fixes, refactors, documentation). The only structural fork is `/start`'s triage between agent-target (fast lane) and everything-else (design-spec lane). `/design` may create or edit approved durable intent/seam authority before `/build`; `/consolidate` reconciles generated/evidence authority from built state at `/finish` time. The workflow invariants are stated centrally in `workflows/README.md ## Workflow invariants`; this principle does not duplicate them.
