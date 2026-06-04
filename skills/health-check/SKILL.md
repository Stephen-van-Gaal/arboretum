---
name: health-check
description: Run a full project health check — detects drift between register, contracts, definitions, and specs; reports Check 7 drift without mutating (use --reconcile or /consolidate to write status flips).
disable-model-invocation: false
allowed-tools: Bash(bash scripts/health-check.sh *), Bash(bash scripts/read-pipeline-flag.sh), Read, Edit
argument-hint: [project-dir]
layer: 0
owner: health-check
---

# Project Health Check

Run the project health check to detect drift across the spec-driven workflow.

## Procedure

### Step 0: Read the pipeline.workflow flag

Before running the health check, validate the active named pipeline:

```bash
PIPELINE=$(bash scripts/read-pipeline-flag.sh)
```

The reader must succeed before interpreting results.

### Numbered procedure

1. Run `bash scripts/health-check.sh` against the project root (or `$ARGUMENTS` if a directory is provided)
2. Present the results clearly, grouping by check type:
   - Check 1: Governed documents exist
   - Check 2: Register owned files vs. disk
   - Check 3: Unowned source files
   - Check 4: contracts.yaml vs. spec Requires tables
   - Check 5: contracts.yaml vs. definition versions (staleness)
   - Check 6: Spec status consistency (enum is one of `draft`, `active`, `stale`)
   - Check 7: Spec drift detection (reports which specs are out of sync with their owned files; **read-only by default** — pass `--reconcile` to write `active → stale` flips into `docs/REGISTER.md` and spec frontmatter)
   - Check 8: Plan files — Tests section (advisory)
   - Check 9: Strategic Anchor — section present in CLAUDE.md, time horizon future, in/out scope non-empty, cadence not overdue (silent pass when `roadmap.config.yaml` absent)
3. If the script exits with code 0 (healthy), confirm the project is in good shape
4. If the script exits with code 1 (drift detected), summarize the issues found and suggest specific fixes
5. For any spec with detected drift, surface that the user should run `/consolidate` to reconcile (which calls health-check with `--reconcile` automatically)
6. Interpret Check 7 drift using the unified workflow rule:
   - **Drift on a governed spec → run `/consolidate`.** `/consolidate` is the sole writer of governed specs. A Check 7 drift report means a governed spec's `# owner:`-mapped files have changed; the sanctioned remedy is `/consolidate` (which calls health-check with `--reconcile` automatically).
   - **Do not suggest hand-authoring governed specs to resolve drift.** Surface drift as a `/consolidate` request.
   - **`active → stale` flips** still come from `/health-check --reconcile` (or `/consolidate` which passes `--reconcile`). The skill itself remains read-only.

## Important

- Check 7 is **read-only by default** — drift is reported but no files are modified. Pass `--reconcile` to write status flips. `/consolidate` passes `--reconcile` automatically.
- Do NOT auto-fix the *advisory* findings (definition pins, unowned files, missing docs) — the architecture owner approves those changes.
- If version pins are stale, suggest reviewing the affected specs' Requires tables.
- If unowned files are found, suggest which spec should own them based on directory location.
- If the health-check script is not found, check that `scripts/health-check.sh` exists and is executable.
- Status transitions: `/consolidate` flips `draft → active` on successful reconciliation; `/consolidate` (via `--reconcile`) flips `active → stale` on drift. The `/health-check` skill itself never writes — it reports.
