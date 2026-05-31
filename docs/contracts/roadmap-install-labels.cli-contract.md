---
script: scripts/roadmap/install-labels.sh
version: 1.1
invokers:
  - type: skill
    name: arboretum:/roadmap
  - type: developer
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `scripts/roadmap/install-labels.sh`

## Surface

Idempotent label installer for `/roadmap`. Builds the framework-fixed label vocabulary (type:*, horizon:*, appetite:*, state markers) and any project-defined component:/audience: labels from `roadmap.config.yaml`, then creates missing labels through the configured tracker backend. The default GitHub adapter delegates to `gh label create`. Existing labels are skipped; no labels are deleted or modified. Outputs a summary line (`created=N  skipped=N  failed=N`) to stdout on completion. Invoked by a developer or by the `/roadmap instantiate` skill step to bootstrap a repo's label set.

Signature: `bash scripts/roadmap/install-labels.sh [--dry-run] [--config <path>] [--no-components]`

## Protocol

### Arguments

- `--dry-run` — (optional) Print the full label vocabulary as TSV (`name<TAB>color<TAB>description`) to stdout and exit 0 without making any tracker calls. Allows offline inspection of the vocabulary.
- `--config <path>` — (optional) Path to `roadmap.config.yaml`. Default: `./roadmap.config.yaml`. Used to read `component_values:` and `audience_values:` lists for project-defined labels.
- `--no-components` — (optional) Install only framework-fixed labels (type:*, horizon:*, appetite:*, state markers); skip component: and audience: labels regardless of config presence.
- `-h` / `--help` — Print usage and exit 0.

No positional arguments. Unknown flags cause exit 2 with an error message to stderr.

### Exit codes

- `0` — success. In live mode: all label-create operations completed with zero failures (individual skips are not failures). In `--dry-run` mode: vocabulary printed to stdout.
- `1` — one or more tracker label-create calls failed (partial install; `failed` count > 0 in summary). Also exits 1 when the configured backend is unavailable or unauthenticated. For the default GitHub adapter this means `gh` is absent from `$PATH` or `gh auth status` fails.
- `2` — bad arguments: an unrecognised flag was supplied; error message emitted to stderr.

### Side effects

Creates tracker labels/tags in the authenticated repository through the configured backend. The default GitHub adapter targets the repo inferred from the current working directory (the standard `gh` context). The operation is idempotent: labels that already exist are skipped without modification; no labels are removed or renamed. In `--dry-run` mode no tracker calls are made and no labels are created — the only side effect is stdout output.

## Test surface

- **CLI-1: `--dry-run` emits the framework-fixed label families.** Running `--dry-run` exits 0, produces no stderr, and the TSV output contains at least one `type:*` label, one `horizon:*` label, and one `appetite:*` label — confirming the three framework-fixed families are always present regardless of config.
- **CLI-2: `--dry-run` with `--no-components` omits component:/audience: labels.** When both flags are passed, none of the output lines begins with `component:` or `audience:`, even when a valid `roadmap.config.yaml` is present.
- **CLI-3: `--dry-run` vocabulary contains the full state-marker set.** The output includes `blocked`, `agent-ready`, `agent-prep:in-progress`, `provisionally-resolved`, and `provisionally-stale` label names.
- **CLI-4: backend guard.** When the configured backend is unavailable (for the default GitHub adapter: `gh` not on `$PATH`, simulated by a stripped PATH), the script exits 1 and emits a backend diagnostic to stderr before making any label-create calls.
- **CLI-5: Unknown flag → exit 2.** Passing an unrecognised flag (e.g. `--bogus`) exits 2 with a message to stderr and produces no stdout.

## Versioning

- **1.1** (2026-05-31) — label creation flows through the backend-neutral tracker helper; GitHub remains the default adapter.
- **1.0** — initial contract (2026-05-30).
