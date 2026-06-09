---
seam: write-agent-brief
version: 1.1
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/write-agent-brief.sh
---
<!-- owner: pipeline-contracts-template -->

# write-agent-brief — `write-agent-brief.sh` Agent-Brief Producer Contract

The seam between `scripts/write-agent-brief.sh` (the producer of `.arboretum/agent-briefs/<issue>.md` — the minimal task brief that **replaces the design spec for agent-target work**) and its downstream consumer `scripts/read-s2-frontmatter.sh` (the S2 input gate `/build` runs on its design-spec-or-brief). This contract pins the brief's frontmatter schema so the brief is, by construction, a valid S2 input — a frontmatter field add/remove on either side is a contract change.

## Producer

`scripts/write-agent-brief.sh` — producer-type: `script`.

Takes a positive-integer `<issue>` argument and a task statement on stdin, and writes `.arboretum/agent-briefs/<issue>.md` (relative to the current working directory). The brief has three structurally-isolated blocks: (1) a frontmatter heredoc carrying the exact S2 schema `/build` enforces, expanding only controlled values (`$ISSUE` is validated numeric, `$(date)` is local); (2) the untrusted task statement written via `printf '%s\n'` so `$VAR` / `$(…)` inside it are never evaluated; (3) a quoted-heredoc footer describing the escape-hatch reclassification path. On success it prints the brief path to stdout and exits 0.

The `<issue>` argument must be a strictly positive integer — no `0`, no leading zeros, no non-digits — matching `read-s2-frontmatter.sh`'s downstream `related-issue > 0` gate. A missing/invalid issue, or an empty stdin task statement, exits 1 with a stderr diagnostic and writes nothing.

## Consumer

Consumers, consumer-type: `script`:

- **`scripts/read-s2-frontmatter.sh`** (script, primary). `/build` runs it on the brief as the S2 input gate. It parses the brief's frontmatter and validates the whole S2 schema strictly: `related-issue` (positive int), `test-tiers` (object with ≥1 of unit/contract/integration), `implementation-mode` ∈ {direct, executing-plans, subagent-driven-development}, `triage` ∈ {agent-target, everything-else}, `plan` (null or non-empty relative path). The brief MUST parse clean and exit 0.
- **`skills/build/SKILL.md`** (skill, indirect, ~line 146). Treats the brief as the design-spec substitute for agent-target dispatch.

**Consumer obligations:**

- `read-s2-frontmatter.sh` MUST accept the brief produced by `write-agent-brief.sh` with no missing-field or invalid-enum error (exit 0).
- The consumer MUST treat the brief's frontmatter as the authoritative S2 input — `triage: agent-target`, `implementation-mode: direct`, `plan: null` are the producer's fixed values.

## Protocol shape

### Inputs

`scripts/write-agent-brief.sh` accepts:

- **`<issue>`** — positional, required. A strictly positive integer (no `0`, no leading zeros, no non-digits).
- **stdin** — the task statement. Must be non-empty. Read literally (quoted-heredoc-friendly usage); never shell-expanded into the written brief.

### Outputs

Writes `.arboretum/agent-briefs/<issue>.md` (relative to CWD; `.arboretum/agent-briefs/` is created if absent). Brief shape:

```markdown
---
date: <YYYY-MM-DD, UTC>
related-issue: <issue>
triage: agent-target
implementation-mode: direct
plan: null
test-tiers:
  unit: yes
  contract: yes
  integration: yes
---

# Agent-target task brief — #<issue>

<task statement, verbatim>

> This brief replaces the design spec for agent-target work per WS2 D2.
> If a real design decision surfaces during build, /build's escape hatch
> reclassifies into everything-else and re-enters at SURVEY.
```

stdout: the written brief path. Exit codes: `0` — brief written; `1` — missing/invalid `<issue>` or empty stdin (nothing written).

### Invariants

- **Frontmatter S2-schema completeness.** The brief frontmatter carries exactly the five required S2 fields plus `date`: `date`, `related-issue`, `triage`, `implementation-mode`, `plan`, `test-tiers`. The five S2 fields are exactly what `read-s2-frontmatter.sh` requires. Removing or renaming any is a contract change requiring a coordinated reader update.
- **Fixed S2 values.** The producer always emits `triage: agent-target`, `implementation-mode: direct`, `plan: null`. These are the defining values of an agent-target brief — not configurable.
- **test-tiers is an object, defaulting to applicable.** `test-tiers` is always a YAML mapping with `unit`, `contract`, and `integration` sub-keys. The producer emits each as `yes` (all tiers applicable) — never `n/a` by default (#695). `n/a` is an enforced claim ("no test of this tier belongs here") that `/build`'s exit guard invalidates the moment the build touches a test of that tier, so an `n/a` default under-declares and trips the guard; `yes` is permissive scope with no converse penalty, leaving real tier applicability to the build-time TDD cycle (`workflow-unification` D6: all-tiers-N/A is a rare logged skip, never the default). It is never a scalar — `read-s2-frontmatter.sh` rejects a scalar test-tiers.
- **related-issue echoes the validated issue.** `related-issue` is the `<issue>` argument verbatim — a strictly positive integer, so the reader's `related-issue > 0` gate always passes.
- **Strict issue validation.** `<issue>` matching `''|*[!0-9]*|0|0[0-9]*` (empty, non-digit, zero, or leading-zero) exits 1 and writes nothing.
- **Empty-stdin rejection.** An empty task statement exits 1 and writes nothing.
- **Literal task statement.** The task statement is written via `printf '%s\n'` — `$VAR` / `$(…)` / backticks inside it are never expanded into the brief.
- **Round-trip with reader.** A brief produced for any valid issue MUST pass `read-s2-frontmatter.sh` with exit 0, and the reader's printed `related-issue=`, `triage=agent-target`, `implementation-mode=direct`, `plan=null` lines reflect the brief's values.

## Test surface

- **WAB-1:** Happy path — `write-agent-brief.sh 12345` with a task statement on stdin writes `.arboretum/agent-briefs/12345.md`, prints the path, exits 0.
- **WAB-2:** Frontmatter schema — the written brief carries `related-issue: 12345`, `triage: agent-target`, `implementation-mode: direct`, `plan: null`, and a `test-tiers:` object with `unit`/`contract`/`integration` sub-keys.
- **WAB-3:** Round-trip — `read-s2-frontmatter.sh <brief>` exits 0 and prints `related-issue=12345`, `triage=agent-target`, `implementation-mode=direct`, `plan=null` (the brief is a valid S2 input by construction).
- **WAB-4:** Literal task statement — a task statement containing `$(touch pwned)` / backticks is written verbatim into the brief and NOT shell-expanded (no side-effect file created).
- **WAB-5:** Invalid issue — `0`, `01`, `abc`, and empty all exit 1 with a stderr diagnostic and write no brief.
- **WAB-6:** Empty stdin — a non-empty issue with empty stdin exits 1 and writes no brief.

## Versioning

- **1.1** (2026-06-09) — `test-tiers` default flipped from all-`n/a` to all-`yes` (#695). No schema change — `test-tiers` is still an object with `unit`/`contract`/`integration` sub-keys, each `yes` or `n/a — …`; only the producer's emitted default values changed. Restores `workflow-unification` D6 ("never the default").
- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/write-agent-brief.sh` and consumer `scripts/read-s2-frontmatter.sh` on `main`. Issue #303 (WS5 PR 7a).
