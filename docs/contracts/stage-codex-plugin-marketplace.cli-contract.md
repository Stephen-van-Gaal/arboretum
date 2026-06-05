---
script: scripts/stage-codex-plugin-marketplace.sh
version: 1.0
invokers:
  - type: script
    name: scripts/_smoke-test-plugin-manifest.sh
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-06-05-codex-local-plugin-cache-hygiene-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/stage-codex-plugin-marketplace.sh`

## Surface

Local staging helper for Codex plugin install smoke tests. Given an empty
destination directory outside the source checkout, materializes a public-shaped
Arboretum marketplace root from tracked files in the current checkout. The
staged tree keeps the checked-in Codex marketplace metadata and
`plugins/arboretum` wrapper path, but filters dev-only and generated source
directories before Codex installs from it.

The helper exists so local Codex install tests exercise the same distribution
boundary as public sync without committing a duplicated plugin tree under
`plugins/arboretum`.

## Protocol

### Arguments

```
stage-codex-plugin-marketplace.sh <empty-destination-dir>
```

- `<empty-destination-dir>` *(required, positional $1)* — destination directory
  to populate. It may already exist, but it must be empty. If it does not exist,
  its parent directory must already exist; the helper creates only the
  destination directory itself.

### Exit codes

- `0` — the staged marketplace root was written successfully and stdout names
  the destination.
- `1` — runtime or precondition failure: `rsync` is unavailable, destination is
  a non-directory path, destination is inside the source checkout, destination
  parent directory does not exist, destination is not empty, `git` is
  unavailable, or a required copy/regeneration operation fails.
- `2` — invocation error, currently any argument count other than one.

Unexpected subcommand failures may propagate their native exit codes through
`set -euo pipefail`; those are outside the documented contract.

### Side effects

On success, writes only under `<empty-destination-dir>`. The helper enumerates
tracked source files with `git ls-files`, copies only those tracked files with
the public-sync dev-only exclusions, including `.git`, `.arboretum`,
`.worktrees`, `customer-testbeds`, design specs, plans, dev contracts, review
docs, release tooling, and local project config. It overlays public-facing
`CLAUDE.md` and `README.md` from `CLAUDE.public.md` / `README.public.md` when
those files exist, and falls back to already-public `CLAUDE.md` / `README.md`
when run from the public repo. It copies the public Arboretum report issue forms
when present. After filtering, it regenerates `docs/contracts/_coverage.md` in
the staged root when the coverage generator is present, mirroring the public
sync workflow's post-filter coverage step.

The helper performs no network calls and no writes to the source checkout.

## Test surface

- **CLI-1: Empty destination required.** Missing arguments exit `2`; non-empty
  destinations exit non-zero before any staging copy is attempted.
- **CLI-2: Public-shaped staging.** A dev checkout stages without `.git`,
  `.arboretum`, `.worktrees`, `customer-testbeds`, `docs/specs`, `docs/plans`,
  or `docs/superpowers`.
- **CLI-3: Wrapper preserved.** The staged tree preserves
  `plugins/arboretum -> ..` so the Codex marketplace path resolves to the
  staged public-shaped root.
- **CLI-4: Public adapter docs present.** The staged tree contains `CLAUDE.md`
  and `README.md`, using the dev repo's `*.public.md` sources when available and
  public-root files otherwise.
- **CLI-5: Codex install smoke.** `scripts/_smoke-test-plugin-manifest.sh` uses
  the staged root with an isolated `CODEX_HOME`, installs
  `arboretum@arboretum`, verifies forbidden dev-only paths are absent from the
  cache, and verifies the cache contains exactly one `scripts/roadmap/lib.sh`.
- **CLI-6: Source-checkout isolation.** Destinations inside the source checkout
  are rejected before the helper writes inside the checkout.
- **CLI-7: Tracked-file boundary.** Untracked local-only files are not copied
  into the staged root.
- **CLI-8: Public coverage regeneration.** The staged root and installed Codex
  cache contain a fresh public-shaped `docs/contracts/_coverage.md`.

## Versioning

- **1.0** — initial contract for Codex local plugin cache hygiene (2026-06-05).
