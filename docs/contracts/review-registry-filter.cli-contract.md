---
script: scripts/review-registry-filter.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-review-registry-filter.sh
  - type: skill
    name: arboretum:/finish
related-designs:
  - docs/superpowers/specs/2026-06-13-section-dispatch-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/review-registry-filter.sh`

## Surface

The dispatcher's **deterministic selection step** (#791 D3, section-dispatch element 2):
`registry.filter(altitude, artifact)` plus gate evaluation. Reads `reviewers.yml`, keeps
each worker whose `altitudes[]` contains the requested altitude AND `artifact[]` contains
the requested artifact, then for any worker carrying a `gate:` field defers to
`review-dispatch.sh`'s lane set (the gate **authority** — composed, never a second copy of
the AI-facing/code gates) computed over the changed files. Emits the selected workers as
JSONL; the actual parallel fan-out (skill drivers + runtime adapters) is orchestrated by
the caller (`/finish` Step 5), since spawning subagents is an agent-runtime concern. LLM-free.

## Protocol

### Arguments

```bash
bash scripts/review-registry-filter.sh <registry-file> --altitude <a> --artifact <art> \
                                       [--base <ref>] [--files-from <file|->]
```

- `<registry-file>` — the reviewer registry (canonical `reviewers.yml` shape).
- `--altitude` / `--artifact` — the request dimensions to filter on (required).
- `--base` — when given, substitutes `{base}` in each surviving row's `invoke` so it is
  directly runnable.
- `--files-from` — the changed-file list (file or `-`) used for gate evaluation; empty
  when omitted (gates then fail closed, as `review-dispatch.sh` does on empty input).

### Output

One JSONL record per surviving worker, in registry (= dispatch) order:
`{id, type, invoke, gate, normalizer}` (`gate`/`normalizer` are `null` when absent).

### Exit codes

- `0` — emitted the selected workers (possibly none matched the filter) on stdout.
- `2` — registry missing/not found, the registry parses but declares **no workers**
  (`no workers in <registry>`), `--altitude`/`--artifact` missing, an unknown flag, a
  `--files-from` file not found, a **selected row missing/with an invalid `type` or a
  missing `invoke`** (fails loud rather than emitting a malformed record), or a worker
  carries an **unknown `gate:` kind** (the gate→lane map fails loud rather than silently
  passing).

### Side effects

Reads the registry + an optional file list; shells out to `review-dispatch.sh` for gate
authority; writes JSONL to stdout. No mutation.

## Test surface

- **RRF-1:** finish/diff over an AI-facing + code change → all four lanes, registry order.
- **RRF-2:** design/doc → only the codex row (the skill lanes are finish-only).
- **RRF-3:** gate drop — a non-AI, non-code finish/diff drops `gate: ai-surface` + `gate: code` rows.
- **RRF-4:** `--base` substitutes `{base}` in the runtime row's `invoke`.
- **RRF-5:** artifact filter — finish/tree keeps only rows whose `artifact[]` includes `tree`.
- **RRF-6:** each emitted record carries `id`, `type`, `invoke`.
- **RRF-7:** a trailing `# comment` on a flow list does not corrupt the CSV membership test.
- **RRF-8:** a selected row missing/with an invalid `type` (or missing `invoke`) → exit 2.
- **RRF-9:** a `--base` carrying shell metacharacters is shell-quoted in the emitted `invoke`.

## Versioning

- **1.0** — initial: registry-driven worker selection for review-stage (#791).
