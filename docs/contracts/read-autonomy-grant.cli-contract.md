---
script: scripts/read-autonomy-grant.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-read-autonomy-grant.sh
  - type: skill
    name: skills/build/SKILL.md
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-28-autonomy-grant-foundation-design.md
---
<!-- owner: pipeline-state-tracking -->

# Contract for `scripts/read-autonomy-grant.sh`

## Surface

Resolves the current autonomy grant for a tracker issue (#915 slice 6 / #922 —
grant carriage). The grant rides the existing pipeline-state seam, no new
transport: the exclusive `autonomy:*` label is the authoritative current grant
(last-writer-wins, set at the design→build grant gate), and the journey-log
`grant=<tier>` entries are the audit trail. Downstream drivers call this to learn
their autonomy boundary.

## Protocol

### Arguments

```
read-autonomy-grant.sh <issue-number>
```

- `<issue-number>` (positional, required) — the tracker issue whose grant to
  resolve.
- `AUTONOMY_GRANT_LABELS_OVERRIDE` (environment, optional) — a
  whitespace/newline-separated label list that stands in for the issue's labels,
  bypassing the tracker call for tests and offline resolution.

Output is one newline-terminated record:

```
grant=<pause-at-land|pause-at-merge|auto-merge|design-only>
```

`design-only` is the absence of any `autonomy:*` label (today's default). The
live path reads labels from the configured roadmap backend
(`roadmap_tracker_issue_show <issue> --json labels`, requires `gh` for
`backend=github`).

The producer enforces:

- **Exclusive label.** More than one `autonomy:*` label on the issue is grant
  drift (the label is exclusive, LWW) — exit 2 with a diagnostic.
- **Closed vocabulary.** An `autonomy:*` value outside
  `pause-at-land|pause-at-merge|auto-merge` is rejected — exit 2.

Consumer obligations: recover the tier by matching the `grant=` prefix; treat
`grant=design-only` as "no autonomous reach granted — fully attended", distinct
from a non-zero exit (drift or tracker failure, not a grant value).

### Exit codes

- `0` — grant resolved; `grant=<tier>` printed to stdout.
- `1` — bad args (missing issue) or tracker read/parse failure.
- `2` — grant drift (multiple `autonomy:*` labels, or an out-of-vocabulary value).

### Side effects

Read-only with respect to the working tree and git. Reads tracker labels over the
network on the live path (skipped when `AUTONOMY_GRANT_LABELS_OVERRIDE` is set);
writes only to stdout/stderr; mutates no tracker state.

## Test surface

- **CLI-1: Tier resolution.** Each `autonomy:*` tier resolves to its
  `grant=<tier>` line.
- **CLI-2: design-only default.** An issue with no `autonomy:*` label (and an
  empty label set) resolves to `grant=design-only`.
- **CLI-3: Exclusivity drift.** Two `autonomy:*` labels exit 2 with an
  exclusivity diagnostic.
- **CLI-4: Vocabulary drift.** An out-of-vocabulary `autonomy:*` value exits 2.
- **CLI-5: Bad invocation.** A missing issue argument exits non-zero.

Covered by `scripts/_smoke-test-read-autonomy-grant.sh`.

## Versioning

- **1.0** — initial contract for the grant carriage resolver (#922, 2026-06-28).
