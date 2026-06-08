<!-- owner: extract-shared-component -->

# Catalog format

The catalog is the survey phase's output and the extract phase's input — one row
per duplication candidate, ranked, each carrying enough to decide *extract or not*
and to seed the extraction. It is written to
`.arboretum/extraction-catalog/<YYYY-MM-DD>.md`. The survey phase runs
`scripts/validate-catalog.sh <catalog>` against it before presenting candidates;
this document and that validator are the two halves of the format contract — keep
them in lockstep.

## Per-candidate schema

One candidate per `### <id> — <slug>` section. Each carries these fields as
`- **<field>:** <value>` lines. **All are required** (the validator rejects a
candidate missing any):

| Field | Meaning |
|---|---|
| `tier` | which detector surfaced it: `1` grep / `2` shingle / `3` semantic |
| `clone_type` | `1` exact / `2` renamed / `3` gapped / `4` semantic |
| `pattern` | the duplicated idiom/block/behaviour (one line) |
| `occurrences` | raw count |
| `distinct_files` | Rule-of-Three gate: **≥3 to qualify** |
| `languages` | `shell` / `python-in-shell` / `ts` / … |
| `rough_contract` | the signature a shared helper would expose (Tier-3 generates this) |
| `home` | proposed extraction target (e.g. `scripts/lib/<name>.sh`) |
| `worth_extracting` | `yes` / `no` / `needs-decision` — **+ one-clause why** |
| `notes` | variant drift, divergences, hazards |

## The `worth_extracting` verdict selects the governance lane

The enum is not just "extract or not" — it routes the extraction:

- **`yes`** → spec-exempt behaviour-preserving refactor lane. Extract per
  `extraction-rule.md`; characterization tests are the proof of preservation.
- **`needs-decision`** → **stop and route to `/design`.** The candidate cannot be
  unified without *choosing* canonical semantics (divergent implementations) — that
  is governed design work, not refactoring.
- **`no`** → recorded here so it is not re-surfaced; not extracted.

## Gates and judgments

- **Rule-of-Three gate.** Only candidates with `distinct_files >= 3` enter the
  ranked list. Record sub-gate pairs (2 files) under a short "watch" note rather
  than the main list — e.g. the S1 `fetch-PR-with-retry` (C5) and `gh pr checks`
  (C6) pairs, which also diverge on error semantics.
- **Count ≠ value.** A high `occurrences` count does not imply extractable. The
  `worth_extracting` judgment is mandatory: ambient building blocks (`mktemp`,
  `trap … EXIT`, `set -euo pipefail`) recur constantly but are not units to
  extract. Rule of Three is necessary, not sufficient.

## Ranking

Rank qualifying candidates by `distinct_files` (descending), then `occurrences`.

## Worked example

```markdown
### C1 — scrub-control-chars
- **tier:** 1
- **clone_type:** 1
- **pattern:** control-char scrub regex
- **occurrences:** 17
- **distinct_files:** 11
- **languages:** python-in-shell
- **rough_contract:** strip the control-char class before serialization
- **home:** scripts/lib/scrub-control-chars.sh
- **worth_extracting:** yes — documented-but-unenforced invariant (the canonical pattern)
- **notes:** log-stage.sh adds a tab variant; reconcile on extract
```
