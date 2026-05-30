---
seam: post-handoff-comment
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/post-handoff-comment.sh
---
<!-- owner: pipeline-contracts-template -->

# post-handoff-comment — `post-handoff-comment.sh` Handoff-Marker Contract

The seam between `scripts/post-handoff-comment.sh` (which posts a session-handoff comment to a GitHub issue, prefixed with an HTML-comment marker) and `scripts/refresh-next-cache.sh`, which scans an issue's comments for that marker, picks the newest marked comment, and parses its branch / posted-at / next-action / prose into the next-up cache. The contract is the **marker syntax and body shape**: the exact `<!-- arbo-handoff: <branch> <timestamp> -->` token, the `→ Next action:` line, and the prose layout. A format change here is a coordinated break with the cache parser.

## Producer

`scripts/post-handoff-comment.sh` — producer-type: `script`.

Invoked as `post-handoff-comment.sh <issue-number> <branch> <note-file> [project-dir]`. It builds a comment body by prepending the marker line `<!-- arbo-handoff: <branch> <ISO-8601-UTC> -->`, then a `**Session handoff** · branch \`<branch>\` · <date>` header line and a blank line, then the verbatim contents of `<note-file>` (the human-approved note: the `→ Next action:` line plus prose; the note file itself carries no marker). It posts the assembled body via `gh issue comment <issue> --body-file <tmp>` run from `[project-dir]` (defaulting to the git toplevel or `pwd`).

It depends on `gh` (installed; auth is the caller's concern) and writes only a private `mktemp` scratch body removed on exit. Exit codes: `0` posted; `1` bad args / note-file missing / `gh` missing; `2` the `gh issue comment` call failed.

## Consumer

Consumer-type: `script`. One downstream consumer:

- **`scripts/refresh-next-cache.sh`** (`latest_handoff`, ~line 311) fetches the issue's comments, selects those whose body (lstripped) starts with `<!-- arbo-handoff:`, sorts by `createdAt`, and takes the newest. It parses the marker with `re.search(r"<!--\s*arbo-handoff:\s*(\S+)\s+(\S+)\s*-->", body)` → group 1 = branch, group 2 = posted-at. It strips the marker line and the `**Session handoff**` header from the prose, reads the value after `→ Next action:` as `next_action`, and folds the following prose block into `body`. All extracted strings are control-char-scrubbed.

**Consumer obligations:**

- The consumer MUST match the marker as `<!-- arbo-handoff: <branch> <timestamp> -->` (whitespace-tolerant) and treat group 1 as branch, group 2 as posted-at.
- The consumer MUST select the **newest** marked comment by `createdAt` when multiple exist (handoffs accumulate; only the latest is authoritative).
- The consumer MUST recognise the `→ Next action:` line prefix to recover the next action, and MUST scrub all extracted strings of ASCII control characters before writing them into the cache (defense-in-depth; the marker carries author-controlled branch text).
- A format change to the marker or the `→ Next action:` prefix is a coordinated break: producer and `refresh-next-cache.sh` MUST change together.

## Protocol shape

### Inputs

- `<issue-number>` (required), `<branch>` (required), `<note-file>` (required; must exist), `[project-dir]` (optional, defaults to git toplevel or `pwd`).
- Reads `<note-file>` contents verbatim; posts via `gh issue comment` from `[project-dir]`. Requires `gh` on PATH.

### Outputs

- **GitHub side effect:** one issue comment whose body is exactly:
  ```
  <!-- arbo-handoff: <branch> <ISO-8601-UTC> -->
  **Session handoff** · branch `<branch>` · <YYYY-MM-DD>

  <verbatim note-file contents>
  ```
- stdout: `Posted handoff comment to issue #<n>.` on success.
- stderr (non-zero exit only): an arg/`gh`/post-failure diagnostic.
- Exit codes: `0` posted; `1` bad args / missing note-file / `gh` missing; `2` `gh issue comment` failed.

### Invariants

- **Marker syntax.** The first body line is exactly `<!-- arbo-handoff: <branch> <timestamp> -->`, where `<branch>` and `<timestamp>` are single whitespace-free tokens — matching the consumer's `(\S+)\s+(\S+)` capture. The branch is the second token, the posted-at timestamp the third.
- **Marker-first.** The marker is the very first line of the body (the consumer's `lstrip().startswith("<!-- arbo-handoff:")` selector depends on it).
- **Header line.** A `**Session handoff**`-prefixed header follows the marker; the consumer strips both the marker line and this header before extracting prose.
- **Note appended verbatim.** The note-file contents are appended unchanged; the producer prepends but never rewrites them. The `→ Next action:` line, if present, originates in the note file.
- **No mutation beyond the comment.** The script writes only a private mktemp scratch body (removed on exit); it does not edit the note file or any repo file.
- **gh-failure surfaces as exit 2.** A failed `gh issue comment` returns exit 2 (distinct from the exit-1 invocation errors), so a caller can distinguish "couldn't post" from "called wrong."

## Test surface

- **PHC-1:** Posts a comment whose body's first line matches `<!-- arbo-handoff: <branch> <timestamp> -->` with the supplied branch as group 1 (gh stub captures `--body-file`).
- **PHC-2:** The captured body, parsed by the *consumer's* regex `<!--\s*arbo-handoff:\s*(\S+)\s+(\S+)\s*-->`, yields branch == the supplied branch and a nonempty posted-at — i.e. producer output is round-trip-parseable by `refresh-next-cache.sh`'s parser.
- **PHC-3:** A `→ Next action:` line present in the note-file survives into the posted body verbatim and is recoverable by the consumer's prefix match.
- **PHC-4:** Missing note-file → exit 1 (no `gh` call).
- **PHC-5:** `gh` absent from PATH → exit 1 with a `requires the gh CLI` diagnostic.
- **PHC-6:** A failing `gh issue comment` (stub exits nonzero) → exit 2 with a `gh issue comment failed` diagnostic.

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/post-handoff-comment.sh` and consumer parser as of `scripts/refresh-next-cache.sh` on `main`. Issue #303 (WS5 PR 7a).
