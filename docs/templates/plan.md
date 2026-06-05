---
version: 1
document-shape: plan
---

# [Spec Name] — Implementation Plan

<!-- Compatibility/fallback template.

     Arboretum delegates implementation-plan generation to the configured
     build-support provider (currently Superpowers). Future providers may
     produce a different body shape. Arboretum should consume plans gracefully:
     checkboxes, test evidence, and verification commands are useful when
     present, but the full body shape is not an Arboretum-owned schema.

     Plans are retained as permanent historical records (not deleted by
     /consolidate). They are not governed artifacts — they don't appear in
     REGISTER.md or carry a status state machine — but they may be cited from
     the governed spec's "Implementation Notes → Design record" subsection.
     After the spec reaches "active", the plan becomes historical context (the
     spec is the current-state authority). -->

**Spec:** `docs/specs/[spec-name].spec.md`

**Goal:** <!-- One sentence: what does implementing this spec achieve? -->

**Prerequisites:**
<!-- What must exist before implementation can begin?
     - Required specs that must be implemented or stubbed
     - Required definitions that must exist (at least at v0)
     - External dependencies (libraries, data, access) -->

**Architecture:** <!-- 2-3 sentences on the implementation approach -->

**Tech stack:** <!-- Key technologies and libraries -->

## External Interface Reliability Pass

<!-- Required when the plan uses subagent-driven-development, or when an
     executing-plans plan decomposes work into multiple independent workstreams.
     Optional but encouraged for any plan with risky external seams.

     Purpose: prevent independent agents from inventing private local shapes for
     shared inputs, silently crossing protected boundaries, or postponing adapter
     reliability until after module design is already baked.

     Contract form should choose one of:
     - structured data shape (dataclass, record type, schema, or language
       equivalent) for shared payloads
     - Protocol/interface type (or language equivalent) for true adapter seams
     - existing contract document or shared definition
     - no new code contract, with reason

     Test strategy should choose one of:
     - golden fixture
     - tiny deterministic simulator
     - real adapter contract test
     - integration test against a fixture-backed pipeline
     - explicit no-test reason

     Simulators must stay tiny and contract-shaped. They should prove pipeline
     behavior, not reimplement external systems. Stop and escalate if a
     workstream wants to change upstream schema or cross a protected boundary
     declared out of scope. -->

| Interface | Owner | Consumer workstream(s) | Schema/source of truth | Contract form | Test strategy | Fixture/simulator | Failure behavior | Privacy/safety rule | Stop condition |
|---|---|---|---|---|---|---|---|---|---|

## Tests

<!-- Required for test-prudent plans. State the test tiers this plan exercises
     and the exact evidence each code-bearing task must produce.

     For TDD work, every code-bearing task should report:
     - RED command
     - expected failure
     - GREEN command
     - passing result
     - tests added or changed
     - refactor note

     Declare "N/A — [reason]" only for docs-only or genuinely test-inapplicable
     plans. -->

---

## File Structure

```
<!-- List all files that will be created or modified -->
```

---

## Task 1: [Component/Feature Name]

**Files:**
- Create: `exact/path/to/file.py`
- Create: `tests/exact/path/to/test_file.py`

### Step 1: Write failing tests

<!-- Complete test code — not pseudocode. Every assertion specific. -->

### Step 2: Verify tests fail

```bash
# Exact command to run
```

Expected: <!-- Exact error -->

### Step 3: Implement

<!-- Complete implementation code — not pseudocode. -->

### Step 4: Verify tests pass

```bash
# Exact command to run
```

Expected: PASS

### Step 5: Commit

```bash
git add [specific files]
git commit -m "[message]"
```

---

<!-- Repeat Task sections as needed -->

## Final Verification

- [ ] All tests pass: `pytest tests/ -v`
- [ ] Register updated with owned files
- [ ] contracts.yaml updated (if definition pins changed)
- [ ] Spec status is `active` (auto-flipped by `/consolidate`)
