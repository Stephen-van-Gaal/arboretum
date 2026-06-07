---
script: .claude/hooks/web-setup.sh
version: 1.0
invokers:
  - type: hook
    name: Claude SessionStart (startup, resume)
  - type: developer
related-designs:
  - docs/specs/arboretum-as-plugin.spec.md
---
<!-- owner: pipeline-contracts-template -->

# Contract for `.claude/hooks/web-setup.sh`

## Surface

`SessionStart` hook (matchers `startup` and `resume`), registered in
`.claude/settings.json` with a 180s timeout. On a Claude-Code-on-the-web
container boot it makes the in-repo arboretum skills available by installing
this repository's plugin from a locally staged copy of the working tree.

It is gated to do real work only when **both** hold:

- `CLAUDE_CODE_REMOTE=true` — web/remote container only; and
- `dogfood: true` in `$CLAUDE_PROJECT_DIR/.arboretum.yml` — arboretum-dev only
  (`.arboretum.yml` is excluded from the public sync, so the hook is inert in
  the public distribution and downstream adopter projects).

When either gate fails the hook is a silent no-op. The hook is best-effort and
unconditionally exits 0 — a failed bootstrap degrades to "skills not loaded",
never a startup error.

## Protocol

### Arguments

The hook takes no positional arguments and no flags. Claude Code's
`SessionStart` hook contract passes a JSON event on stdin, which this hook does
not read. It reads two environment variables — `CLAUDE_CODE_REMOTE` and
`CLAUDE_PROJECT_DIR` (falling back to `$(pwd)`) — and the `dogfood:` key of
`$CLAUDE_PROJECT_DIR/.arboretum.yml`. It is invoked as:

```
bash .claude/hooks/web-setup.sh
```

### Exit codes

- `0` — always. Every path exits 0: the two gate no-ops exit 0 with no output;
  the active path runs best-effort `claude plugin` commands (each wrapped in
  `timeout`, each `|| true`) and exits 0 regardless of their success.

### Side effects

- **Gate no-op paths** (remote-unset, or dogfood-absent/false): zero bytes to
  stdout and stderr, no filesystem writes, no subprocesses beyond reading
  `.arboretum.yml`.
- **Active path** (remote + dogfood, with `claude` and a plugin manifest
  present): writes a staged real-file copy of `skills/` + `hooks/` + the plugin
  manifest under `$CLAUDE_PROJECT_DIR/.arboretum/web-plugin/` (gitignored,
  sync-excluded; rebuilt each boot), registers that directory as a throwaway
  `source: "."` marketplace, installs/updates the `arboretum` plugin at **user**
  scope (mutating the ephemeral `~/.claude` config, never the tracked working
  tree), and emits one confirmation line to stdout (attached as
  `additionalContext`). Each `claude plugin` call is bounded by `timeout` so a
  hung CLI/cache lock cannot stall the synchronous hook past its budget.

## Test surface

- **WS-1: remote-unset gate.** With `CLAUDE_CODE_REMOTE` unset the hook exits 0,
  writes zero bytes to stdout and stderr, and creates no
  `$CLAUDE_PROJECT_DIR/.arboretum/web-plugin` staging directory.
- **WS-2: dogfood-absent gate.** With `CLAUDE_CODE_REMOTE=true` but a project
  whose `.arboretum.yml` lacks `dogfood: true`, the hook exits 0, writes zero
  bytes to stdout, and performs no install (no staging directory).
- **WS-3: exit-0 invariant.** Both gate paths exit 0; the hook never returns a
  non-zero status that Claude Code would surface as a startup warning.
- **WS-4: active path (out of deterministic smoke scope).** The remote+dogfood
  path stages a real-file copy and installs from a `source: "."` marketplace
  (verified: 26 skills materialized, no `.git`, no github clone). It is not
  exercised by the deterministic smoke because it requires the `claude` CLI and
  mutates `~/.claude`; it is covered by manual verification, mirroring how
  `prompt-timestamp` documents its `date`-absent edge as out of scope.

## Versioning

- **1.0** — initial contract (2026-06-06). Covers `.claude/hooks/web-setup.sh`
  as introduced for web-session skill availability (PR #606).
