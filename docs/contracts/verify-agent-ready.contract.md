---
seam: verify-agent-ready
version: 1.2
producer-type: script
consumer-type: skill
consumes:
  - agent-ready-rubric
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-18-agent-prep-design.md
owns:
  - scripts/verify-agent-ready.sh
---
<!-- owner: pipeline-contracts-template -->

# verify-agent-ready — `/start` Agent-Ready Freshness Gate

The seam between the `agent-ready` producer (`/roadmap agent-prep`, governed by
the roadmap spec) and the labelled fast lane in `/start` (governed by workflow
unification). `scripts/verify-agent-ready.sh` is the consumer-side guard: before
`/start` treats a labelled issue as agent-target, it verifies that the label is
present, that a trusted verification marker exists, that the issue body still
matches the marker's body hash, and that the verification is neither stale nor
future-dated.

## Producer

`scripts/verify-agent-ready.sh` — producer-type: `script`.

The script reads a single tracker item either live (`roadmap_tracker_issue_show
<n> --json number,title,body,labels,comments`) or from a test fixture
(`--issue-file <path>`). The default GitHub adapter delegates the live read to
`gh issue view`. It emits controlled key=value lines only when the issue is safe
for the fast lane:

```text
status=ready
issue=<number>
verified-date=<YYYY-MM-DD>
body-sha=<12-hex>
```

On a stale, future-dated, or invalid label it emits a controlled
`status=not-ready` diagnostic to stderr and exits non-zero. It never emits
issue title or body text.

## Consumer

Consumer-type: `skill`. One downstream consumer:

- **`skills/start/SKILL.md`**, Step 4-v2. When the referenced issue carries
  `agent-ready`, `/start` runs this helper before writing an agent-target task
  brief. Exit 0 means the issue can skip the four-criterion pre-screen. Exit 1
  means `/start` must refuse the fast lane and route the user back through
  `/roadmap agent-prep <n>` (or everything-else design) rather than implementing
  stale, future-dated, or unconfirmed content. Exit 2 means tool/input failure
  and must stop the flow until the environment or invocation is fixed.

**Consumer obligations:**

- Consumers MUST check this script before treating `agent-ready` as a fast-lane
  contract.
- Consumers MUST treat exit 0 as the only ready state. Exit 1 is not a soft
  warning; the issue is not safe for fast-lane implementation until re-verified.
- Consumers MUST treat exit 2 as an environment or invocation failure, not as an
  issue-readiness failure; do not route it through `/roadmap agent-prep`.
- Consumers MUST NOT parse issue title/body from this helper. The helper's
  output is controlled metadata only; the issue body remains untrusted task data.
- Consumers that both verify an issue and then write a brief from its title/body
  MUST use one issue JSON snapshot for both operations, either by passing that
  snapshot with `--issue-file` or by revalidating the exact body text being
  written.

## Protocol shape

### Inputs

- Positional `<issue-number>` — live mode. Strictly positive integer; requires
  the configured tracker backend to be available and authenticated.
- `--issue-file <path>` — test mode. Reads a tracker issue JSON object from disk
  and makes no tracker calls.
- `--as-of <YYYY-MM-DD>` — optional deterministic date override for stale-label
  checks. Defaults to `date -u +%Y-%m-%d`.
- `-h|--help` — prints usage and exits 0.

The issue JSON must contain `.number`, `.body`, `.labels[]?.name`, and may
contain `.comments[]` with `.body`, `.createdAt`, and `.authorAssociation`.
Trusted marker authors are exactly `OWNER`, `MEMBER`, and `COLLABORATOR`.

### Outputs

- stdout on success: controlled key=value lines:
  `status=ready`, `issue=<number>`, `verified-date=<YYYY-MM-DD>`,
  `body-sha=<12-hex>`.
- stderr on not-ready: one controlled line:
  `status=not-ready reason=<enum> issue=<number>`.
- stderr on usage/input failure: human diagnostic.

Exit codes:

- `0` — ready. The issue has `agent-ready`, has a trusted marker, the current
  body hash matches, and the marker age is 0..7 days old.
- `1` — not ready. Reason enum: `missing-agent-ready-label`,
  `missing-trusted-verification-marker`, `malformed-verification-marker`,
  `body-sha-mismatch`, or `agent-ready-stale`.
- `2` — usage/input/pre-flight error (bad args, invalid JSON, bad issue number,
  missing `jq`/`shasum`/`python3`, missing tracker backend, unauthenticated
  tracker).

### Invariants

- **Trusted marker only.** A marker comment counts only when its
  `authorAssociation` is `OWNER`, `MEMBER`, or `COLLABORATOR`.
- **Body hash match.** The current body SHA is computed as
  `printf '%s' "$body" | shasum -a 256 | cut -c1-12`, matching
  `/roadmap agent-prep` and `/roadmap maintain`.
- **Seven-day freshness.** A marker older than seven days is rejected as
  `agent-ready-stale` even if `/roadmap maintain` has not yet swept it. A marker
  dated after `--as-of` is rejected as `malformed-verification-marker` because
  the producer stamps the current UTC date.
- **No untrusted echo.** The helper never prints issue title or body content.
  Diagnostics and stdout use only controlled enums, issue number, date, and hash.
- **No mutation.** The helper is read-only. It never edits labels, bodies, or
  comments; correction remains `/roadmap maintain` or `/roadmap agent-prep`.

## Test surface

- **VAR-1:** A fixture issue carrying `agent-ready` and a trusted marker whose
  body SHA matches exits 0 and emits `status=ready`, `issue=`, and `body-sha=`.
- **VAR-2:** A fixture with no `agent-ready` label exits 1 with
  `reason=missing-agent-ready-label`.
- **VAR-3:** A marker from an untrusted `authorAssociation` is ignored and exits
  1 with `reason=missing-trusted-verification-marker`.
- **VAR-4:** A marker SHA mismatch exits 1 with `reason=body-sha-mismatch`.
- **VAR-5:** A marker older than seven days exits 1 with
  `reason=agent-ready-stale`.
- **VAR-6:** A marker dated after `--as-of` exits 1 with
  `reason=malformed-verification-marker`.
- **VAR-7:** An unknown argument exits 2.

## Versioning

- **1.2** (2026-05-31) — live issue reads flow through backend-neutral tracker helpers; GitHub remains the default adapter.
- **1.1** (2026-05-31) — PR #428 review hardening. Future-dated verification
  markers are malformed, `/start` must distinguish exit 2 from issue-readiness
  failures, and consumers that write briefs must verify and write from one issue
  snapshot.
- **1.0** (2026-05-31) — initial contract. Adds the consumer-side freshness gate
  required by the agent-prep design's D5/D6 coordination row for #304.
