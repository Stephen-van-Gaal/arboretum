---
seam: roadmap-lib
version: 1.0
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/roadmap/lib.sh
---
<!-- owner: pipeline-contracts-template -->

# roadmap-lib — `roadmap/lib.sh` Shared Roadmap-Helper Contract

The seam between `scripts/roadmap/lib.sh` (the sourceable shared-helper library for the roadmap subsystem) and the scripts/skills that source it — `scripts/roadmap/render-run.sh`, `nag.sh`, `build-orientation.sh`, and the `/roadmap` + `/idea` skills. The library is never executed directly; each helper echoes a scalar (or a newline-delimited list) consumed by callers. This contract pins the output protocol of the load-bearing functions — root/config resolution, the YAML scalar/list getters, and the pulse-file read/write helpers — so a caller never re-parses `roadmap.config.yaml` or the pulse JSON by hand.

## Producer

`scripts/roadmap/lib.sh` — producer-type: `script`.

A side-effect-free-by-default sourceable library (the pulse-*write* helpers mutate `.arboretum/roadmap-pulse.json`; the readers and config getters are pure). Key exported functions:

- **`roadmap_project_root`** — echoes the project root: git toplevel of CWD (worktree-aware), else `$CLAUDE_PROJECT_DIR`, else `pwd`.
- **`roadmap_config_path`** — echoes the absolute path to `roadmap.config.yaml` if it exists under the root; echoes nothing otherwise.
- **`roadmap_config_get KEY`** — echoes a top-level scalar from `roadmap.config.yaml`. Prefers `yq`; falls back to a stdlib-only `python3` parser (no PyYAML). Returns nonzero when the config is absent or the key name is malformed.
- **`roadmap_config_list KEY`** — echoes a top-level list, one element per line; handles both block (`- item`) and flow (`[a, b, c]`) style.
- **`roadmap_pulse_path`** — echoes `<root>/.arboretum/roadmap-pulse.json` (echoes nothing if root unknown).
- **`roadmap_pulse_bootstrap`** — idempotently seeds the pulse file (no-op if present); bootstrap-as-today so no nag fires on install day.
- **`roadmap_pulse_get_field KEY`** / **`roadmap_pulse_get_nag NAME`** — echo a scalar pulse field / `nag_last_fired[NAME]`; empty string when absent/null/file-missing.
- **`roadmap_pulse_set_nag_fired NAME`** / **`roadmap_pulse_update_field KEY VALUE`** — atomically (`.tmp` + `mv`) update the pulse JSON; fail-silent on any error.

The config/pulse helpers degrade gracefully: missing tooling (`yq`/`python3`/`jq`) prints a diagnostic and returns nonzero for the config getters, while the pulse helpers are uniformly fail-silent (missing file → empty return, never an error).

## Consumer

Consumer-type: `script`. Downstream consumers source the lib and capture function stdout:

- **`scripts/roadmap/render-run.sh`, `nag.sh`, `build-orientation.sh`** source the lib for root/config/pulse access.
- **`/roadmap` and `/idea` skills** invoke roadmap scripts that depend on these helpers (e.g. `roadmap_config_list component_values` for the component vocabulary).

**Consumer obligations:**

- Consumers MUST source the lib (it is not directly executable) and capture function output via command substitution.
- Consumers MUST treat an empty `roadmap_config_path` / `roadmap_pulse_path` as "absent," distinct from a populated value — and MUST NOT assume `origin`-style defaults.
- Consumers MUST read `roadmap_config_list` output as one element per line (the list contract), and `roadmap_config_get` as a single scalar line.
- Consumers MUST tolerate the fail-silent pulse readers: an empty return means absent/null, not error.

## Protocol shape

### Inputs

- `roadmap_project_root` — none (reads CWD git state + `$CLAUDE_PROJECT_DIR`).
- `roadmap_config_path` — none.
- `roadmap_config_get KEY` / `roadmap_config_list KEY` — one arg: a top-level key name (must match `^[a-zA-Z_][a-zA-Z0-9_]*$`).
- `roadmap_pulse_get_field KEY`, `roadmap_pulse_get_nag NAME`, `roadmap_pulse_set_nag_fired NAME` — one arg.
- `roadmap_pulse_update_field KEY VALUE` — two args.
- All resolve their target file relative to `roadmap_project_root`; no stdin.

### Outputs

- **`roadmap_project_root`** — one line: an absolute path. Always nonempty.
- **`roadmap_config_path`** — one line (absolute path) when the config exists; empty stdout + return 0 when it does not.
- **`roadmap_config_get KEY`** — one line: the scalar value, surrounding quotes stripped, inline `# comment` stripped; empty line for null/`~`/absent value. Returns 1 (no stdout value) when config absent or key malformed.
- **`roadmap_config_list KEY`** — zero or more lines, one list element each (quotes stripped). Returns 1 when config absent or key malformed.
- **`roadmap_pulse_path`** — one line: the pulse JSON path; empty when root unknown.
- **`roadmap_pulse_get_field KEY`** / **`roadmap_pulse_get_nag NAME`** — one line: the field/nag value; empty string when absent, null, or file missing. Always returns 0.
- **`roadmap_pulse_set_nag_fired` / `roadmap_pulse_update_field`** — no stdout; side effect is an atomic rewrite of the pulse JSON. Always returns 0 (fail-silent).
- The config getters print a tooling diagnostic to stderr and return nonzero when neither `yq` nor `python3` is available.

### Invariants

- **Root always resolves.** `roadmap_project_root` always echoes a nonempty absolute path (git toplevel → `$CLAUDE_PROJECT_DIR` → `pwd`), worktree-aware.
- **Config-path emptiness signals absence.** `roadmap_config_path` echoes the path only when the file exists; an empty echo means "no config," never a default path.
- **Key-name guard.** `roadmap_config_get`/`roadmap_config_list` reject keys not matching `^[a-zA-Z_][a-zA-Z0-9_]*$` with a stderr diagnostic and nonzero return — no shell-injection surface into the parser.
- **Scalar normalization.** `roadmap_config_get` strips matched surrounding quotes and a trailing inline comment, and maps `''`/`null`/`~` to an empty line.
- **List line-protocol.** `roadmap_config_list` emits exactly one element per line for both block and flow YAML styles, quotes stripped (via the python3 path — see the list-getter yq-path gap below).
- **Pulse fail-silence.** All pulse readers return 0 with empty stdout when the file/field is missing; writers are atomic (`.tmp` + `mv`) and never error out the caller.
- **Tooling parity (with one known gap).** The `yq`/`jq` paths and the `python3` fallbacks are intended to produce equivalent output regardless of which tool is installed. **Known gap (#412):** `roadmap_config_list`'s yq path uses jq-syntax (`.${key}[]? // empty`) that mikefarah `yq` rejects (`lexer: invalid input text "empty"`), so on any machine with `yq` installed the list getter returns empty — parity holds for the scalar getter (`// ""`, quoted) but not the list getter. The python3 fallback is correct on every platform. RL-5 pins the python3-path behaviour (it hides `yq` to force the fallback) until #412 fixes the yq expression; the list getter's yq path is therefore *not* asserted by this contract today.

## Test surface

- **RL-1:** `roadmap_project_root` inside a git repo echoes the repo toplevel (nonempty absolute path).
- **RL-2:** `roadmap_config_path` echoes the config path when `roadmap.config.yaml` exists under the root; echoes nothing when it is absent.
- **RL-3:** `roadmap_config_get wip_limit` against a fixture config returns the scalar with quotes/inline-comment stripped; a quoted value is unquoted.
- **RL-4:** `roadmap_config_get badkey$(touch x)` (malformed key) returns nonzero with no value echoed (key-name guard).
- **RL-5:** `roadmap_config_list component_values` against a block-style fixture returns one element per line; a flow-style `[a, b, c]` fixture returns the same three elements. Asserted via the **python3 path** (the test hides `yq` to dodge the #412 list-getter yq-path gap).
- **RL-6:** `roadmap_pulse_get_field` / `roadmap_pulse_get_nag` against a missing pulse file return empty stdout and exit 0 (fail-silent).
- **RL-7:** `roadmap_pulse_update_field` followed by `roadmap_pulse_get_field` round-trips a value through the atomically-rewritten pulse JSON.

## Versioning

- **1.0** (2026-05-30) — initial contract. Library shape as of `scripts/roadmap/lib.sh` on `main`. Issue #303 (WS5 PR 7a).
