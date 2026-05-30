---
seam: refresh-update-cache
version: 1.0
producer-type: script
consumer-type: hook
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/refresh-update-cache.sh
---
<!-- owner: pipeline-contracts-template -->

# refresh-update-cache — `refresh-update-cache.sh` Update-Cache Producer Contract

The seam between `scripts/refresh-update-cache.sh` (the producer of `.arboretum/update-cache.json` — the cached "is a newer arboretum plugin release available?" result) and its downstream consumer `.claude/hooks/session-start.sh` (which renders the one-line `[Arboretum] Update available: …` boot-banner notice). This contract pins the cache JSON schema, the closed `error` enum, and the exit-code semantics so the renderer can never silently mis-parse a shape change.

## Producer

`scripts/refresh-update-cache.sh` — producer-type: `script`.

Scans the plugin cache root (`$ARBORETUM_PLUGIN_CACHE`, default `$HOME/.claude/plugins/cache`) for `plugin.json` manifests whose `"name"` is `"arboretum"`, extracts each `"version"`, and takes the highest by `sort -V` as the installed version. It then queries the latest public release (`gh release view --repo stvangaal/arboretum --json tagName --jq '.tagName'`), strips a leading `v`, and computes `update_available` = (latest is the higher of the two AND they differ). The result is written to `.arboretum/update-cache.json`.

Path resolution uses a positional `[project-dir]` arg (defaults to `git rev-parse --show-toplevel` or `pwd`). The cache is written atomically via per-process `mktemp` + `mv` (safe for concurrent calls — the session-start hook may fire a background refresh).

Degraded paths write a valid cache carrying a closed-set `error` code: `manifest-not-found` (no installed arboretum plugin), `gh-unavailable` (`gh` not on PATH), `gh-call-failed` (the release query failed), `no-release` (no release found / empty tag). The cache JSON is built with `printf` (not python3) — version values come from `plugin.json` and the release tag, not free-form author input, so there is **no control-char scrubbing at the producer**; the consumer re-scrubs as defense-in-depth.

## Consumer

Consumer, consumer-type: `hook`:

- **`.claude/hooks/session-start.sh`** (hook, ~line 429). Reads `.arboretum/update-cache.json` and renders `[Arboretum] Update available: v<installed> → v<latest> — run /plugin update arboretum to upgrade.` only when `update_available` is `true`. It refreshes the cache when absent (synchronously, first run) or older than a 24 h TTL (background, `disown`ed). It has a python3 path (preferred) and a `grep`/`sed` fallback path; both gate the notice on `update_available == true`. The python3 path re-scrubs `installed_version` and `latest_version` with the `_CTRL` regex before render.

**Consumer obligations:**

- The consumer MUST render the notice ONLY when `update_available` is `true`. Any `error` value, or `update_available: false`, renders nothing.
- The consumer MUST treat a missing or unparseable cache as "no notice" — never error (the python3 path wraps the read in try/except and `sys.exit(0)` on failure).
- The consumer MUST re-scrub `installed_version` / `latest_version` before render (mirror of the `_CTRL` regex) as belt-and-braces against a hand-edited cache.
- The consumer MUST tolerate the full closed `error` enum (`manifest-not-found`, `gh-unavailable`, `gh-call-failed`, `no-release`, `null`).

## Protocol shape

### Inputs

`scripts/refresh-update-cache.sh` accepts one optional CLI argument:

- **`[project-dir]`** — positional, defaults to `git rev-parse --show-toplevel` or `pwd`. Root under which `.arboretum/update-cache.json` is written.

Environment:

- **`ARBORETUM_PLUGIN_CACHE`** — overrides the plugin cache root (default `$HOME/.claude/plugins/cache`). Used by tests to point at a fixture cache.

Reads:

- `<plugin-cache-root>/**/plugin.json` — for the installed arboretum version (content-matched on `"name": "arboretum"`).
- `gh release view --repo stvangaal/arboretum --json tagName --jq '.tagName'` — latest release tag.
- `command -v gh` — capability gate.

### Outputs

Writes `.arboretum/update-cache.json` (atomic via mktemp + mv). Shape:

```json
{
  "fetched_at": "<ISO-8601 UTC>",
  "installed_version": "<semver>" | null,
  "latest_version":    "<semver>" | null,
  "update_available":  true | false,
  "error": null | "manifest-not-found" | "gh-unavailable" | "gh-call-failed" | "no-release"
}
```

Exit codes:

- `0` — cache written in every state EXCEPT gh-unavailable. Sub-cases: full success (`error: null`); `manifest-not-found`; `gh-call-failed`; `no-release`.
- `1` — `gh` CLI not found. The cache IS still written first (with `error: "gh-unavailable"`, `installed_version` populated) — only then does the script exit 1.

### Invariants

- **Output JSON shape.** The cache is valid JSON with exactly the top-level keys `{fetched_at, installed_version, latest_version, update_available, error}`. No other keys. Adding or removing a key is a contract change requiring a coordinated `session-start.sh` update.
- **Closed error enum.** `error` is exactly one of `null`, `manifest-not-found`, `gh-unavailable`, `gh-call-failed`, `no-release`. No other value is ever written.
- **Always-writes-valid-JSON contract.** Every path — including the two non-success exit behaviours — writes a complete, parseable cache before exiting. The cache is never empty.
- **gh-unavailable exits 1 (the one non-zero path).** When `gh` is absent the script writes a cache with `error: "gh-unavailable"`, `installed_version` populated, `latest_version: null`, `update_available: false`, THEN exits 1. Every other path exits 0. The consumer does not branch on the exit code — it reads the cache — but a caller MUST NOT treat exit 1 as "no cache written."
- **update_available semantics.** `update_available` is `true` only when a latest version was successfully fetched AND it is strictly higher than the installed version by `sort -V`. Any `error != null` forces `update_available: false`.
- **manifest-not-found nulls.** When no installed arboretum plugin is found, both `installed_version` and `latest_version` are `null`, `update_available: false`, `error: "manifest-not-found"`, exit 0 (gh is never queried).
- **No producer-side scrub.** The producer does NOT control-char-scrub version strings (they derive from plugin.json / release tags, not free-form author input). The consumer re-scrubs `installed_version` / `latest_version` before render as defense-in-depth.
- **Atomic-write invariant.** The cache is written via per-process `mktemp` + `mv` atomic rename. Concurrent refreshes never produce truncated or interleaved content.

## Test surface

- **RUC-1:** `manifest-not-found` path — empty/absent plugin cache (`ARBORETUM_PLUGIN_CACHE` → empty dir) → exit 0, cache with `error: "manifest-not-found"`, `installed_version: null`, `latest_version: null`, `update_available: false`, all five top-level keys present.
- **RUC-2:** JSON shape — the written cache has exactly the keys `{fetched_at, installed_version, latest_version, update_available, error}` and is parseable.
- **RUC-3:** `gh-unavailable` path — a fixture plugin cache with an installed arboretum manifest + `gh` stripped from PATH → cache with `error: "gh-unavailable"`, `installed_version` populated, `update_available: false`, AND the script exits 1 (the documented one non-zero path) while still having written the cache.
- **RUC-4:** Update-available happy path — fixture installed version `0.1.0` + a `gh` stub returning tag `v0.2.0` → `installed_version: "0.1.0"`, `latest_version: "0.2.0"`, `update_available: true`, `error: null`, exit 0.
- **RUC-5:** Up-to-date path — fixture installed version equal to the stubbed latest → `update_available: false`, `error: null`.
- **RUC-6:** `no-release` / `gh-call-failed` path — a `gh` stub that errors (or returns empty) → `error` is one of `{no-release, gh-call-failed}`, `update_available: false`, exit 0.
- **RUC-7:** Atomic-write — `write_cache()` uses `mktemp` + `mv` (pattern assertion against the script source).

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/refresh-update-cache.sh` and consumer `.claude/hooks/session-start.sh` on `main`. Issue #303 (WS5 PR 7a).
