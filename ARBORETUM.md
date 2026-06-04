# ARBORETUM.md - Agent Workflow Contract

This file is the canonical workflow contract for code agents working in an
Arboretum-governed project. Tool-specific instruction files can adapt this
contract to their loader format, but they do not replace it.

## COMMON

These rules apply to every agent surface.

File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.

Examples of explicit read-only or skip-pipeline overrides:

- "answer only"
- "just inspect"
- "run this command only"
- "do not start the pipeline"

Casual implementation requests such as "can you fix this?", "build this", or
"update the docs" are file-changing requests and enter `/start`.

Stage handoff is explicit; do not proceed to the next stage silently. A stage
may finish with a handoff prompt, a logged exit, or an instruction to invoke the
next stage, but the agent should not treat the whole pipeline as one continuous
coding sprint.

Everything-else work stops after `/design` for human review before `/build`.
The review covers goals, requirements, done criteria, design decisions, test
approach, and implementation plan before coding begins.

Only verified `agent-ready` work and verified patch-lane briefs produced by
`/start-bugfix` skip the review-before-build pause. A cheap or inferred
`agent-target` classification is not enough; `agent-ready` issues must pass the
freshness and verification path designated for `agent-ready`, and patch-lane
briefs must pass `/start-bugfix`'s patchability gate.

The pipeline-state tracking remains the observable state layer. This contract
does not add a runtime guardrail, a blocking hook, or a second stage-state
mechanism.

## CODEX

This section is a thin adapter, not a second contract. Codex should read
`ARBORETUM.md ## COMMON` as the source of truth, then use the local `AGENTS.md`
file for project-specific engineering, testing, and git conventions.

Recommended `AGENTS.md` snippet:

```markdown
## Arboretum Contract

The canonical workflow contract is `ARBORETUM.md`. Follow
`ARBORETUM.md ## COMMON` before applying tool-specific or project-specific
instructions.

File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.

Everything-else work stops after `/design` for human review before `/build`.
Only verified `agent-ready` work and verified patch-lane briefs produced by `/start-bugfix` skip the review-before-build pause.
```

## CLAUDE

This section is a thin adapter, not a second contract. Claude should read
`ARBORETUM.md ## COMMON` as the source of truth, then use the local `CLAUDE.md`
file for project-specific engineering, testing, and git conventions.

Recommended `CLAUDE.md` snippet:

```markdown
## Arboretum Contract

The canonical workflow contract is `ARBORETUM.md`. Follow
`ARBORETUM.md ## COMMON` before applying tool-specific or project-specific
instructions.

File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.

Everything-else work stops after `/design` for human review before `/build`.
Only verified `agent-ready` work and verified patch-lane briefs produced by `/start-bugfix` skip the review-before-build pause.
```

## DATABRICKS

This section is a thin adapter, not a second contract. Databricks workspace,
notebook, or assistant instructions should point to `ARBORETUM.md ## COMMON`
as the source of truth, then add only the local execution details needed for
that workspace.

Recommended Databricks instruction snippet:

```markdown
## Arboretum Contract

The canonical workflow contract is `ARBORETUM.md`. Follow
`ARBORETUM.md ## COMMON` before applying workspace-specific instructions.

File-changing work enters `/start` unless the user explicitly asks for read-only work or explicitly asks to skip the pipeline.

Everything-else work stops after `/design` for human review before `/build`.
Only verified `agent-ready` work and verified patch-lane briefs produced by `/start-bugfix` skip the review-before-build pause.
```
