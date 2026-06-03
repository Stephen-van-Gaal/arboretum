---
seam: refresh-next-cache
version: 1.3
producer-type: script
consumer-type: hook
consumes:
  - next-cache-schema
  - arbo-handoff-marker
  - module-contract-template-file
produces:
  - next-cache-json-schema
  - handoff-key-discriminated-union
related-designs:
  - docs/superpowers/specs/2026-05-28-pipeline-overhaul-ws5-pr4-refresh-next-cache-design.md
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/refresh-next-cache.sh
---
<!-- owner: pipeline-contracts-template -->

# refresh-next-cache — `refresh-next-cache.sh` Next-Up Cache Producer Contract

The seam between `scripts/refresh-next-cache.sh` (the producer of `.arboretum/next-cache.json` — the cached snapshot of the tracker item tagged `next-up`, refreshed on session start with a 1-hour TTL) and its sole downstream consumer `.claude/hooks/session-start.sh` (the `[Next-up]` block of the SessionStart hook's boot banner). One folded-in bug closes as non-recurrable: **#264** — the second of two comment-fetch calls (historically `gh issue view <N> --json comments` in the GitHub-only implementation) silently fell back to an empty comments file on failure, producing `handoff: null` indistinguishable from "no handoff comment exists." RNC-4 makes that conjunction a write-time impossibility — the contract test pins that any non-zero exit from the comment fetch produces the explicit error union variant.

## Producer

`scripts/refresh-next-cache.sh` — producer-type: `script`.

Refreshes the cache at `.arboretum/next-cache.json` by making up to two tracker calls through `scripts/roadmap/lib.sh`: one `roadmap_tracker_issue_list --label next-up --state open --limit 1 --json number,title,url,body,labels,updatedAt` (the primary list call) and, when an issue is found, one follow-up `roadmap_tracker_issue_show <N> --json comments` to extract the latest `arbo-handoff`-marked comment as the current session-handoff note (per `session-handoff` design §4.6). These neutral operations are implemented by the configured roadmap backend (`github` by default, `azure-devops` when selected).

Path resolution uses `PROJECT_DIR` (positional arg, defaults to `git rev-parse --show-toplevel` or `pwd`). The script writes the cache atomically via per-process `mktemp` + `mv` (the `write_cache()` helper at L73-84) — concurrent refreshes never produce truncated or interleaved content.

All author-controlled string fields written into the cache are scrubbed of ASCII control characters (`\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f`) before serialization (the `scrub()` function inside the python3 cache-builder, plus the `comment_fetch_err` scrub on the new error path).

The two tracker calls degrade in coordinated ways: the primary list call's failure sets the whole-cache `error` field (`gh-unavailable` / `gh-call-failed` for GitHub, `azure-devops-unavailable` / `azure-devops-call-failed` for Azure DevOps, or a generic backend/tracker fallback), invalidating the cache as a whole; the secondary comment-fetch call's failure sets a *scoped* error marker on the `handoff` field, preserving the valid item data above it.

## Consumer

One downstream consumer, consumer-type: `hook`:

- **`.claude/hooks/session-start.sh`** (hook). Reads `.arboretum/next-cache.json` on every session start and renders the `[Next-up]` block of the boot banner (the python3 reader at L108-162; sed fallback at L165-177 for environments without python3). The hook branches on the cache shape — whole-cache `error`, `no_gh_remote`, `issue is None`, or the issue-present branch which further branches on the `handoff` discriminated union.

**Consumer obligations:**

- The consumer MUST check `isinstance(handoff, dict) and handoff.get("error") == "fetch-failed"` BEFORE the existing truthy check `if handoff:`. Without that ordering, an error-union value would be truthy and fall through to the normal-handoff rendering path, where `.get("next_action", "")` returns `""` and the user sees no diagnostic — re-introducing the pre-#264 indistinguishable-from-no-handoff regression at the consumer.
- The consumer MUST apply ANSI scrubbing as defense-in-depth on any author-controlled string field rendered from the cache (the existing `_CTRL` regex at L122-124). The producer already scrubs at write time (RNC-6), but a hand-edited or older-version cache could carry control chars; double-scrubbing closes the gap.
- The sed fallback (no python3) is exempt from the handoff-discipline obligation — it doesn't render the handoff field at all in its current shape.

## Protocol shape

### Inputs

`scripts/refresh-next-cache.sh` accepts one optional CLI argument:

- **`[project-dir]`** — positional, defaults to `git rev-parse --show-toplevel` or `pwd`. Sets the root under which `.arboretum/next-cache.json` is written and the project's tracker repo context (via `cd $PROJECT_DIR` inside subshells) is established.

Reads (under the project-dir root):

- `git remote` — to detect whether any repo remote is configured at all (`no_gh_remote: true` legacy-field short-circuit when no remote is configured).
- `roadmap_backend [PROJECT_DIR]` — selects the configured backend (`github` by default).
- `roadmap_require_backend` — validates local prerequisites. For `github`, `gh` must be installed and authenticated. For `azure-devops`, Azure CLI, the Azure DevOps extension, readable defaults, and `jq` must be available. Absence or auth/setup failure sets a provider-specific whole-cache unavailable error and exits 1.
- `roadmap_tracker_issue_list --label next-up --state open --limit 1 --json number,title,url,body,labels,updatedAt` — the primary list call. Failure (other than "not a GH repo" on the GitHub adapter) sets a provider-specific whole-cache call-failed error and exits 2.
- `roadmap_tracker_issue_show <N> --json comments` — the secondary comment-fetch call, made only when the primary list returned an item. Failure sets `handoff: {"error": "fetch-failed", "detail": <stderr-first-line>}` and the script continues to exit 0.
- `python3` — used for body truncation and JSON assembly. Absence triggers the minimal-fallback cache shape with whole-cache `error: "python3 unavailable; issue details omitted in fallback cache"` and exits 0.

### Outputs

Writes to `.arboretum/next-cache.json` (atomic via mktemp + mv). Cache shape:

```json
{
  "fetched_at": "<ISO-8601 UTC>",
  "issue": null | {
    "number": <int>,
    "title": "<string, control-char-stripped>",
    "url": "<string>",
    "body_first_lines": ["<line, control-char-stripped>", ...],
    "body_empty": true | false,
    "labels": ["<string>", ...],
    "updated_at": "<ISO-8601 UTC>"
  },
  "handoff": null
            | { "posted_at": "<ISO-8601 UTC | branch-marker timestamp>",
                "branch":      "<branch name, control-char-stripped>",
                "next_action": "<string, control-char-stripped>",
                "body":        "<prose lines joined with spaces, control-char-stripped>" }
            | { "error": "fetch-failed",
                "detail": "<first line of tracker stderr, control-char-stripped>" },
  "no_gh_remote": true | false,
  "error": null | "gh-unavailable" | "gh-call-failed"
                | "azure-devops-unavailable" | "azure-devops-call-failed"
                | "backend-unavailable" | "tracker-call-failed"
                | "python3 unavailable; issue details omitted in fallback cache"
}
```

The `handoff` field is a discriminated three-way union — `null` (no `arbo-handoff`-marked comment found on the issue), a normal-dict (handoff fetched), or an error-dict (fetch attempted, failed).

Also writes diagnostic lines to `.arboretum/next-cache.err` via the `write_err()` helper for every failure path (whole-cache or scoped).

Exit codes:

- `0` — cache written successfully. Sub-cases: issue found and handoff fetched OK; issue found and no handoff comment exists; issue found and handoff fetch failed (error union recorded in cache); no issue carries the `next-up` label; no repo remote configured.
- `1` — selected backend unavailable. Whole-cache provider-specific unavailable error recorded.
- `2` — primary tracker list call failed for some other reason. Whole-cache provider-specific call-failed error recorded.

### Invariants

- **Output JSON shape.** The cache file is valid JSON with top-level keys `{fetched_at, issue, handoff, no_gh_remote, error}`. No other top-level keys. Adding or removing a key is a contract change requiring a coordinated consumer update.
- **Exit-code contract.** Comment-fetch failure is exit `0` (cache successfully written; failure is recorded *in* the cache, not *about* the cache). Whole-cache tracker failures are exit `1`/`2` per the table above.
- **Handoff-key discriminated union.** The `handoff` value is one of: `null`, a normal-dict with `{posted_at, branch, next_action, body}` keys, or an error-dict with `{error: "fetch-failed", detail: <string>}` keys. The discriminator between the two object shapes is the presence of an `error` key.
- **Comment-fetch failure discipline.** When tracker comment fetch exits non-zero, the cache records `handoff: {"error": "fetch-failed", "detail": ...}` — NEVER `handoff: null` (which would be indistinguishable from "no handoff comment exists").
- **Error-field scope.** The whole-cache `error` field is reserved for failures that invalidate the whole cache. Comment-fetch failure does NOT set this field — it sets the handoff-scoped marker instead.
- **ANSI-scrub invariant.** Author-controlled string fields scrubbed of `\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f` before being written to the cache: `issue.title`, `issue.body_first_lines[*]`, `handoff.posted_at`, `handoff.branch`, `handoff.next_action`, `handoff.body`, `handoff.detail`. Fields NOT scrubbed in this contract version (pre-existing producer behavior; framework-wide scrub coverage tracked under #249): `issue.url`, `issue.labels[*]`, `issue.updated_at`. Of these, `labels[*]` is the realistic attack surface — consumers should treat label rendering with their own scrub for now.
- **Atomic-write invariant.** The cache file is written via per-process `mktemp` + `mv` atomic rename. Concurrent refreshes never produce truncated or interleaved content.

## Test surface

- **RNC-1: Output-JSON-shape.** The cache file is valid JSON with top-level keys exactly `{fetched_at, issue, handoff, no_gh_remote, error}`. The smoke test asserts JSON parsability and the exact top-level key set in each producer case (A success, B no-handoff, C comment-fetch-fail, E gh-unavailable early-return, F gh-call-failed early-return). Cases E + F are especially important because they exercise the shell-level early-return printf blocks where the `"handoff": null` line was added in the X1 fix — without those assertions, a regression that drops the line in those blocks would pass CI.
- **RNC-2: Exit-code contract.** `bash scripts/refresh-next-cache.sh [dir]` exits 0 when the cache was successfully written (any of: issue found and handoff fetched OK; issue found and no handoff comment exists; issue found and comment fetch failed with the error-union recorded; no issue carries `next-up`; no repo remote), 1 when the configured backend is missing/unauthenticated, 2 when the primary tracker issue-list call fails. Comment-fetch failure is exit 0. The smoke test asserts the exit-code transition between the success-and-no-handoff case (0), the comment-fetch-failure case (0 — same), and any whole-cache failure (1 or 2) via GitHub-adapter stub manipulation.
- **RNC-3: Handoff-key-discriminated-union.** The `handoff` value matches one of three shapes: `null`, `{posted_at, branch, next_action, body}` object, or `{error: "fetch-failed", detail: <string>}` object. The smoke test exercises all three shapes via the three test cases and asserts each one's exact shape (presence/absence of `error` key, key set of the object).
- **RNC-4: Comment-fetch-failure discipline (closes #264).** A fixture where tracker issue-list succeeds but tracker issue-show comments exits non-zero produces a cache with `handoff: {"error": "fetch-failed", "detail": <stderr-first-line>}` — NOT `handoff: null`. The smoke test asserts both the error-dict shape and the `detail` value matches the stub's stderr first line.
- **RNC-5: Error-field-scope.** In the comment-fetch-failure case, the whole-cache `error` field MUST be `null` — the failure is scoped to `handoff`, not whole-cache. The smoke test asserts `cache["error"] is None` in the failure case alongside the handoff-scoped error.
- **RNC-6: ANSI-scrub-invariant.** All author-controlled string fields in the cache are control-char-stripped. The smoke test injects a synthetic ANSI escape (e.g. `\x1b[31m`) into the GitHub-adapter stub's comment-fetch stderr and asserts the cache's `handoff.detail` does not contain the raw escape sequence.
- **RNC-7: Atomic-write invariant.** The cache file is always valid JSON across rapid back-to-back refreshes. The smoke test asserts in two layers: (1) **behavioural** — runs the script twice in quick succession (sequential, not parallel — parallel would be flaky on shared CI runners) and asserts the final cache file is parseable. (2) **implementation-pattern** — extracts the `write_cache()` function body from the producer source and asserts it still contains both `mktemp "$CACHE_DIR/..."` and `mv "$tmp" "$CACHE_FILE"`. The behavioural layer catches truncation regressions visible under sequential load; the pattern layer catches regressions to a naive `printf > "$CACHE_FILE"` that would silently corrupt the cache when the session-start background refresh races `/handoff` (the actual concurrency hazard the atomic write defends against).

## Versioning

- **1.3** (2026-06-03) — adds provider-specific Azure DevOps whole-cache errors so SessionStart can render ADO diagnostics instead of GitHub install/auth guidance. Issue #485.
- **1.2** (2026-05-31) — contract wording is backend-neutral while retaining the legacy `gh-*` cache error values for schema compatibility.
- **1.1** (2026-05-31) — producer now calls the backend-neutral roadmap tracker helpers; cache schema and consumer protocol remain unchanged.
- **1.0** (2026-05-28) — initial contract. Producer + consumer shapes as of `scripts/refresh-next-cache.sh` post-Task-1 and `.claude/hooks/session-start.sh` post-Task-2 on `main`. Closes #264 (comment-fetch failure silently blanking the handoff) as "non-recurrable by construction" — RNC-4 asserts the failure path produces the explicit error union; any future regression to a silent-null fallback fails the smoke test.
