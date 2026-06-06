---
seam: trust-config
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-06-06-prompt-injection-hardening-design.md
owns:
  - scripts/read-trust-config.sh
  - scripts/manage-trust.sh
---
<!-- owner: pipeline-contracts-template -->

# trust-config — Journey-Log Author Allowlist Read/Write Contract

The seam around the `.arboretum.yml` `trust.journey_log_authors` allowlist (#249): the list of GitHub login handles trusted as authors of pipeline-state journey-log comments. `scripts/read-trust-config.sh` reads the allowlist for consumers (chiefly `scripts/read-journey-log.sh`, which gates which comment authors contribute rows); `scripts/manage-trust.sh` writes it (seeded at `init` by `bootstrap-project.sh`, curated interactively by `/upgrade`). This contract pins the reader's emit protocol, the writer's subcommand semantics, the additive-only invariant, and the login-validation rule so consumers and callers never re-parse `.arboretum.yml` directly.

## Producer

Two scripts own this seam.

`scripts/read-trust-config.sh` — producer-type: `script`. Takes an optional config path (default `.arboretum.yml`). Resolves presence textually (a line-anchored `journey_log_authors:` grep) because `scripts/lib/yaml-lite.sh` cannot distinguish an explicit empty list `[]` from an absent key — both yield no value lines. Emits `present=yes|no` on the first line, then zero or more `author=<login>` lines (one per allowlisted handle, parsed from yaml-lite's `trust.journey_log_authors[]=` rows). Exits `0` on success; `1` on missing config file or invalid YAML.

`scripts/manage-trust.sh` — producer-type: `script`. Lifecycle writer with two subcommands:
- `instantiate <config> [<login>...]` — **additive-only**. Writes the trust block ONLY when the key is absent; a no-op (exit 0) when a block already exists, so it NEVER overwrites an existing allowlist. With no explicit logins it defaults to `gh api user --jq .login` + `github-actions[bot]` (best-effort; on `gh` failure it writes a hinted placeholder + bot and warns).
- `set <config> <login>...` — authoritative replace: write exactly the given logins (create the block if absent, replace the list in place if present). Human-driven (the `/upgrade` curation path).

Both write paths validate each login against the GitHub handle charset (`^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$`) and refuse (exit 1, no write) on any non-conforming handle, so a crafted login cannot inject YAML structure.

## Consumer

Consumer-type: `script` / `skill`.

- **`scripts/read-journey-log.sh`** invokes `read-trust-config.sh` to resolve the allowlist + presence flag, then surfaces journey-log rows only from allowlisted authors when present (strict), or from all authors with a single stderr warning when absent (permissive migration bridge). See `docs/contracts/read-journey-log.contract.md` v1.1.
- **`scripts/bootstrap-project.sh`** calls `manage-trust.sh instantiate` at `init`.
- **`skills/upgrade/SKILL.md`** offers `manage-trust.sh set` interactively when the key is absent.

**Consumer obligations:**
- Consumers MUST treat `present=no` as "allowlist unconfigured" (permissive/migration), distinct from `present=yes` with zero `author=` lines ("explicit trust-nobody").
- Callers of the write subcommands MUST NOT assume `instantiate` overwrites — to replace an existing list, use `set`.

## Protocol shape

### Inputs
- `read-trust-config.sh [<config>]` — optional config path (default `.arboretum.yml`).
- `manage-trust.sh {instantiate|set} <config> [<login>...]`.

### Outputs
- `read-trust-config.sh` stdout: `present=yes|no` then zero or more `author=<login>` lines.
- `manage-trust.sh`: mutates `<config>` in place; diagnostics to stderr. No stdout protocol.
- Exit codes: `read-trust-config.sh` — `0` success, `1` missing/invalid config. `manage-trust.sh` — `0` success (including additive no-op), `1` bad args / missing config / invalid login.

### Invariants
- **Presence is textual.** `present=yes` iff a `journey_log_authors:` key line exists; an empty list `[]` is `present=yes` with zero authors.
- **Additive-only instantiate.** `instantiate` never overwrites an existing allowlist; only `set` replaces.
- **Login validation.** Every written login matches `^[A-Za-z0-9][A-Za-z0-9-]*(\[bot\])?$`; non-conforming handles are refused with no write.
- **No mutation on read.** `read-trust-config.sh` is read-only.

## Test surface

- **TC-1:** populated list → `present=yes` + one `author=` line per handle.
- **TC-2:** empty list `[]` → `present=yes`, zero `author=` lines.
- **TC-3:** absent key → `present=no`.
- **TC-4:** `read-trust-config.sh` on a missing file → exit 1.
- **TC-5:** `instantiate` on an absent key appends the block; preserves existing config.
- **TC-6:** `instantiate` on a present key is a byte-identical no-op (additive-only).
- **TC-7:** `set` replaces the list (add + remove); creates the block when absent.
- **TC-8:** default `instantiate` (no logins) seeds `github-actions[bot]` at minimum.
- **TC-9:** a login outside the GitHub handle charset (e.g. containing `:`) is refused with no write; a valid `name[bot]` handle is accepted.

(Covered by `scripts/_smoke-test-read-trust-config.sh` and `scripts/_smoke-test-manage-trust.sh`.)

## Versioning

- **1.0** (2026-06-06) — initial contract. Producer shape as of `scripts/read-trust-config.sh` + `scripts/manage-trust.sh` on this branch. Issue #249.
