---
seam: upgrade-classify
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/lib/upgrade-classify.sh
---
<!-- owner: pipeline-contracts-template -->

# upgrade-classify — `upgrade-classify.sh` File-Classification Helper Contract

The seam between `scripts/lib/upgrade-classify.sh` (a pure, sourceable helper that classifies each managed file into an upgrade action) and `scripts/upgrade-sync.sh`, which sources the lib and consumes the echoed action token to drive `/upgrade`'s plan. The helper's contract is its single function `classify_file`: a fixed-arity signature in, one action token on stdout. This contract pins the argument order and the closed set of returned tokens so a caller never has to re-derive the base/ours/theirs precedence logic.

## Producer

`scripts/lib/upgrade-classify.sh` — producer-type: `script`.

A side-effect-free library, sourced (never executed directly). It defines one function:

- **`classify_file BASE OURS THEIRS IN_PLUGIN IN_TREE`** — echoes exactly one action token to stdout. `BASE` is the install-manifest SHA (empty when the file was never tracked), `OURS` the working-tree file SHA (empty when absent in tree), `THEIRS` the plugin file SHA (empty when absent in plugin), and `IN_PLUGIN`/`IN_TREE` are the literal strings `yes`/`no` recording presence in each location.

The classification is base-aware to avoid two historical bugs: untracked user-owned files (empty base) absent from the plugin are left alone rather than flagged removed, and a tracked file the user intentionally deleted is not silently re-added. The function performs no I/O beyond the single `echo`.

## Consumer

Consumer-type: `script`. One downstream consumer:

- **`scripts/upgrade-sync.sh`** sources the lib (`source "$HERE/lib/upgrade-classify.sh"`, ~line 8) and calls `action="$(classify_file "$base" "$ours" "$theirs" "$in_plugin" "$in_tree")"` (~line 121) inside its per-file loop. It then routes on the token: `unchanged` files are skipped; everything else is recorded into the actions/policy JSON maps that drive the upgrade plan (add / overwrite-safe / keep-local / conflict / converged / report-removed).

**Consumer obligations:**

- Consumers MUST pass all five positional args in order; `IN_PLUGIN`/`IN_TREE` MUST be the literal `yes` or `no`.
- Consumers MUST treat the echoed token as a closed set and route every member; an unrecognised token is a contract break, not a default-to-skip.
- Consumers MUST source the lib (it is not executable as a standalone command) and MUST NOT rely on any side effects — the only output is the action token on stdout.

## Protocol shape

### Inputs

- `classify_file BASE OURS THEIRS IN_PLUGIN IN_TREE` — five positional string args:
  - `BASE` — manifest/base SHA, or empty (never-tracked).
  - `OURS` — working-tree SHA, or empty (absent in tree).
  - `THEIRS` — plugin SHA, or empty (absent in plugin).
  - `IN_PLUGIN` — `yes` | `no`.
  - `IN_TREE` — `yes` | `no`.
- No stdin, no files, no env dependence.

### Outputs

- stdout: exactly one action token, one of the closed set:
  - **`add`** — in plugin, not in tree, never tracked (empty base) → genuinely new from plugin.
  - **`keep-local`** — (a) in plugin not in tree, tracked, plugin unchanged vs base (user deleted it intentionally); or (b) present both sides, ours diverged from base but theirs == base (user-local edit, plugin idle).
  - **`conflict`** — (a) in plugin not in tree, tracked, plugin changed vs base; or (b) present both sides, ours and theirs both diverged from base and from each other.
  - **`converged`** — present both sides, ours and theirs both diverged from base but are now equal to each other.
  - **`overwrite-safe`** — present both sides, ours == base but theirs != base (only the plugin moved).
  - **`unchanged`** — present both sides with ours == theirs == base; OR not in plugin, in tree, never tracked (empty base — user-owned, leave alone).
  - **`report-removed`** — not in plugin, in tree, and previously tracked (non-empty base).
- Exit status: `0` (the function always echoes and returns; it never errors on valid inputs).

### Invariants

- **Single-token output.** Exactly one of `{add, keep-local, conflict, converged, overwrite-safe, unchanged, report-removed}` is echoed — never empty, never two tokens.
- **Base-aware presence rules.** Absence-from-plugin maps to `report-removed` only when base is non-empty; an empty-base file absent from the plugin is `unchanged` (user-owned, untouched). Absence-from-tree with empty base is `add`; with non-empty base it is `keep-local` (plugin idle) or `conflict` (plugin moved).
- **Both-present precedence.** When both `IN_PLUGIN` and `IN_TREE` are `yes`: ours==base → (`unchanged` if theirs==base else `overwrite-safe`); ours!=base → (`keep-local` if theirs==base; else `converged` if ours==theirs; else `conflict`).
- **Purity.** No file reads/writes, no network, no global-state mutation — output depends solely on the five args.

## Test surface

- **UC-1:** `add` — `classify_file "" "" SHA yes no` (empty base, plugin-only, never tracked).
- **UC-2:** `keep-local` (deletion respected) — `classify_file SHA "" SHA yes no` (tracked, plugin == base, user deleted).
- **UC-3:** `conflict` (plugin moved on deleted file) — `classify_file SHA "" NEW yes no`.
- **UC-4:** `report-removed` — `classify_file SHA SHA "" no yes` (tracked, vanished from plugin).
- **UC-5:** `unchanged` (untracked, plugin-absent) — `classify_file "" SHA "" no yes` (empty base, user-owned).
- **UC-6:** both-present matrix: `unchanged` (`A A A`), `overwrite-safe` (`A A B`), `keep-local` (`A B A`), `converged` (`A B B`), `conflict` (`A B C`).

## Versioning

- **1.0** (2026-05-30) — initial contract. Helper shape as of `scripts/lib/upgrade-classify.sh` on `main`. Issue #303 (WS5 PR 7a).
