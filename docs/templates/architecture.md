---
version: 1
---

# {{Project Name}} Architecture

<!-- The architecture overview is the map of the system. It helps a reader find
     the right group, spec, definition, or contract. It should explain topology
     and boundaries, not every module's implementation. -->

## Reading Guide

<!-- HUMAN - Who should read this document and which sections matter most for
     onboarding, planning, or implementation. -->

## Product Context

<!-- HUMAN - One or two paragraphs connecting the architecture to the project
     vision. What job does the system perform? What external world does it live
     inside? -->

## System Map

<!-- HUMAN - List the major groups/subsystems and their responsibilities.
     Include a small diagram when it helps. Keep details in group docs or specs. -->

| Group / subsystem | Responsibility | Primary docs |
|---|---|---|

## Boundaries

<!-- HUMAN - What is inside this project, what is outside, and where explicit
     handoffs occur. Call out stop-and-escalate boundaries for AI agents. -->

## Data And Control Flow

<!-- HUMAN - Describe the main flows through the system in execution order.
     Link to definitions for shared records and contracts for seams. -->

## External Systems

<!-- HUMAN - APIs, queues, databases, auth systems, file stores, vendor tools,
     humans-in-the-loop, and other dependencies outside the repository. -->

| External system | Used by | Contract / notes |
|---|---|---|

## Cross-Cutting Concerns

<!-- HUMAN - Security, privacy, observability, performance, error handling,
     portability, cost, migrations, and operational constraints that cut across
     multiple specs. -->

## Document Map

<!-- AUTO or HUMAN - Links to the main group docs, governed specs, shared
     definitions, and contracts. This is a navigation aid; keep module detail in
     the linked documents. -->

## Decisions

<!-- APPEND-AUTO or HUMAN - Durable architecture decisions. Use this table for
     decisions that affect more than one module. Module-local decisions belong in
     the module spec. -->

| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|
