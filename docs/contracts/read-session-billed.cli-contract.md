---
script: scripts/read-session-billed.sh
version: 1.0
invokers:
  - type: script
    name: scripts/token-report.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-06-token-accounting-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/read-session-billed.sh`

## Surface

Billed-surface reader (D9). Parses a session transcript in JSONL form and
aggregates the *real* per-message token usage — fresh input, cache-creation
(write), cache-read, and output tokens — deduplicating by message id so a
transcript that repeats a message line never double-counts it. Computes an
estimated USD cost from the Opus per-1M rate table, the cache-creation share of
total input, and a crude cache-bust spike count. Read-only and advisory; used
by `token-report.sh billed` to surface the cache health and real cost of a
cycle.

## Protocol

### Arguments

```
read-session-billed.sh --transcript <file.jsonl> [--model <name>]
```

- `--transcript <file.jsonl>` *(required)* — path to the session transcript.
  Missing triggers a usage error to stderr and exit `2`.
- `--model <name>` *(optional, default `opus`)* — model hint; currently the
  reader prices against the Opus rate table.

### Exit codes

- `0` — transcript parsed and the aggregate summary printed.
- `2` — `--transcript` not supplied.

### Side effects

Read-only. Spawns `python3` to parse the transcript. Reads the named transcript
file; writes nothing to disk and makes no network calls.

## Test surface

- **CLI-1: dedupe by message id.** A transcript with a duplicated message line
  counts that message's tokens once; the printed `cache_read` total reflects the
  deduped sum, not the doubled sum.
- **CLI-2: cost + cache-health signal.** The summary prints an estimated USD
  cost, a cache-creation share, and a cache-bust spike count.
- **CLI-3: missing transcript exits 2.** Invocation without `--transcript`
  exits `2` with a usage diagnostic.

## Versioning

- **1.0** — initial contract: deduped billed surface with cost + cache-health (2026-06-06).
