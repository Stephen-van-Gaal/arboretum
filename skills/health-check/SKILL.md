---
name: health-check
description: Run a full project health check — detects drift between register, contracts, definitions, and specs; auto-flips spec status active → stale when drift is detected.
disable-model-invocation: false
allowed-tools: Bash(bash scripts/health-check.sh *), Read, Edit
argument-hint: [project-dir]
layer: 0
owner: health-check
---

# Project Health Check

Run the project health check to detect drift across the spec-driven workflow.

## Procedure

1. Run `bash scripts/health-check.sh` against the project root (or `$ARGUMENTS` if a directory is provided)
2. Present the results clearly, grouping by check type:
   - Check 1: Governed documents exist
   - Check 2: Register owned files vs. disk
   - Check 3: Unowned source files
   - Check 4: contracts.yaml vs. spec Requires tables
   - Check 5: contracts.yaml vs. definition versions (staleness)
   - Check 6: Spec status consistency (enum is one of `draft`, `active`, `stale`)
   - Check 7: Spec drift detection (**auto-flips `active → stale`** when owned files were modified after the spec's last commit; writes the flip into `docs/REGISTER.md` and the spec status field, supporting both YAML frontmatter `status:` and the legacy `## Status` markdown section)
   - Check 8: Plan files — Tests section (advisory)
   - Check 9: Strategic Anchor — section present in CLAUDE.md, time horizon future, in/out scope non-empty, cadence not overdue (silent pass when `roadmap.config.yaml` absent)
3. If the script exits with code 0 (healthy), confirm the project is in good shape
4. If the script exits with code 1 (drift detected), summarize the issues found and suggest specific fixes
5. For any spec freshly flipped to `stale`, surface that the user should run `/consolidate` to reconcile (this is the baseline help flow — the richer guided-reconciliation UX is tracked in #108)

## Important

- Check 7 **mutates state** — it writes status changes to REGISTER and spec frontmatter. This is the only mutation this skill performs; all other findings are advisory.
- Do NOT auto-fix the *advisory* findings (definition pins, unowned files, missing docs) — the architecture owner approves those changes. Only the spec status field is auto-mutated.
- If version pins are stale, suggest reviewing the affected specs' Requires tables.
- If unowned files are found, suggest which spec should own them based on directory location.
- If the health-check script is not found, check that `scripts/health-check.sh` exists and is executable.
- Status auto-flips: `/consolidate` flips `draft → active` on successful reconciliation; `/health-check` flips `active → stale` on drift detection. The user is never asked to confirm transitions — the state machine is fully automatic.
