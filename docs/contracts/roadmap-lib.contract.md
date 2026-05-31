---
seam: roadmap-lib
version: 1.4
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

The seam between `scripts/roadmap/lib.sh` (the sourceable shared-helper library for the roadmap subsystem) and the scripts/skills that source it — `scripts/roadmap/render-run.sh`, `nag.sh`, `build-orientation.sh`, session-continuity scripts, and the `/roadmap` + `/idea` skills. The library is never executed directly; each helper echoes a scalar (or a newline-delimited list) consumed by callers. This contract pins the output protocol of the load-bearing functions — root/config resolution, the YAML scalar/list getters, backend selection, tracker-adapter dispatch, and the pulse-file read/write helpers — so a caller never re-parses project config or shells out to vendor-specific tracker commands by hand.

## Producer

`scripts/roadmap/lib.sh` — producer-type: `script`.

A side-effect-free-by-default sourceable library (the pulse-*write* helpers mutate `.arboretum/roadmap-pulse.json`; the readers and config getters are pure). Key exported functions:

- **`roadmap_project_root`** — echoes the project root: git toplevel of CWD (worktree-aware), else `$CLAUDE_PROJECT_DIR`, else `pwd`.
- **`roadmap_config_path`** — echoes the absolute path to `roadmap.config.yaml` if it exists under the root; echoes nothing otherwise.
- **`roadmap_config_get KEY`** — echoes a top-level scalar from `roadmap.config.yaml`. Prefers `yq`; falls back to a stdlib-only `python3` parser (no PyYAML). Returns nonzero when the config is absent or the key name is malformed.
- **`roadmap_config_list KEY`** — echoes a top-level list, one element per line; handles both block (`- item`) and flow (`[a, b, c]`) style.
- **`roadmap_backend [ROOT]`** — echoes the configured tracker backend. `.arboretum.yml backend:` takes precedence, `roadmap.config.yaml backend:` is accepted for compatibility, and missing/empty defaults to `github`. Normalizes `azure`/`ado`/`azure-devops` to `azure-devops`.
- **`roadmap_require_backend [BACKEND]`** — validates the selected backend's local prerequisites. `github` requires authenticated `gh`; `azure-devops` requires Azure CLI, the Azure DevOps CLI extension, readable Azure DevOps defaults, and `jq` for JSON normalization.
- **`roadmap_tracker_issue_list`, `roadmap_tracker_issue_show`, `roadmap_tracker_issue_comment`, `roadmap_tracker_issue_update`, `roadmap_tracker_issue_close`, `roadmap_tracker_issue_create`, `roadmap_tracker_issue_comments`, `roadmap_tracker_label_list`, `roadmap_tracker_label_create`, `roadmap_tracker_pr_list`** — backend-neutral tracker operations. The `github` adapter delegates to the corresponding `gh` subcommand. The `azure-devops` adapter maps issues/labels to Azure Boards work items/tags and returns the GitHub-shaped JSON fields consumed by existing roadmap scripts.
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
- Consumers MUST call the `roadmap_tracker_*` helpers for tracker operations instead of calling `gh` directly when an equivalent helper exists.
- Consumers MUST tolerate the fail-silent pulse readers: an empty return means absent/null, not error.

## Protocol shape

### Inputs

- `roadmap_project_root` — none (reads CWD git state + `$CLAUDE_PROJECT_DIR`).
- `roadmap_config_path` — none.
- `roadmap_config_get KEY` / `roadmap_config_list KEY` — one arg: a top-level key name (must match `^[a-zA-Z_][a-zA-Z0-9_]*$`).
- `roadmap_backend [ROOT]` — optional project root. Reads `<root>/.arboretum.yml` first, then `<root>/roadmap.config.yaml`.
- `roadmap_require_backend [BACKEND]` — optional backend string; defaults to `roadmap_backend`.
- `roadmap_tracker_issue_list ARGS...`, `roadmap_tracker_issue_show ISSUE ARGS...`, `roadmap_tracker_issue_comment ISSUE ARGS...`, `roadmap_tracker_issue_update ISSUE ARGS...`, `roadmap_tracker_issue_close ISSUE ARGS...`, `roadmap_tracker_issue_create ARGS...`, `roadmap_tracker_issue_comments ISSUE ARGS...`, `roadmap_tracker_label_list ARGS...`, `roadmap_tracker_label_create ARGS...`, `roadmap_tracker_pr_list ARGS...` — pass-through args shaped for the neutral operation. The GitHub adapter preserves existing `gh`-compatible flags. The Azure DevOps adapter supports the subset used by roadmap scripts/skills: `--state`, `--limit`, `--label`, `--search`, `--json`, `--jq`, body/title edits, add/remove label, close/comment/create, label list/create, comment list, and PR list.
- `roadmap_pulse_get_field KEY`, `roadmap_pulse_get_nag NAME`, `roadmap_pulse_set_nag_fired NAME` — one arg.
- `roadmap_pulse_update_field KEY VALUE` — two args.
- All resolve their target file relative to `roadmap_project_root`; no stdin.

### Outputs

- **`roadmap_project_root`** — one line: an absolute path. Always nonempty.
- **`roadmap_config_path`** — one line (absolute path) when the config exists; empty stdout + return 0 when it does not.
- **`roadmap_config_get KEY`** — one line: the scalar value, surrounding quotes stripped, inline `# comment` stripped; empty line for null/`~`/absent value. Returns 1 (no stdout value) when config absent or key malformed.
- **`roadmap_config_list KEY`** — zero or more lines, one list element each (quotes stripped). Returns 1 when config absent or key malformed.
- **`roadmap_backend [ROOT]`** — one line: `github`, `azure-devops`, or a caller-visible unsupported backend string. Never empty.
- **`roadmap_require_backend`** — no stdout on success; stderr diagnostic + nonzero on missing tools/auth or unsupported backend.
- **`roadmap_tracker_*` helpers** — stdout/stderr/exit code of the selected backend adapter. For `github`, this is the corresponding `gh` subcommand. For `azure-devops`, issue/work-item responses normalize to objects with `number`, `title`, `url`, `body`, `labels[].name`, `createdAt`, `updatedAt`, `closedAt`, `state`, and `comments[]` when requested.
- **`roadmap_pulse_path`** — one line: the pulse JSON path; empty when root unknown.
- **`roadmap_pulse_get_field KEY`** / **`roadmap_pulse_get_nag NAME`** — one line: the field/nag value; empty string when absent, null, or file missing. Always returns 0.
- **`roadmap_pulse_set_nag_fired` / `roadmap_pulse_update_field`** — no stdout; side effect is an atomic rewrite of the pulse JSON. Always returns 0 (fail-silent).
- The config getters print a tooling diagnostic to stderr and return nonzero when neither `yq` nor `python3` is available.

### Invariants

- **Root always resolves.** `roadmap_project_root` always echoes a nonempty absolute path (git toplevel → `$CLAUDE_PROJECT_DIR` → `pwd`), worktree-aware.
- **Config-path emptiness signals absence.** `roadmap_config_path` echoes the path only when the file exists; an empty echo means "no config," never a default path.
- **Key-name guard.** `roadmap_config_get`/`roadmap_config_list` reject keys not matching `^[a-zA-Z_][a-zA-Z0-9_]*$` with a stderr diagnostic and nonzero return — no shell-injection surface into the parser.
- **Scalar normalization.** `roadmap_config_get` strips matched surrounding quotes and a trailing inline comment, and maps `''`/`null`/`~` to an empty line.
- **List line-protocol.** `roadmap_config_list` emits exactly one element per line for both block and flow YAML styles, quotes stripped.
- **Backend selection precedence.** `.arboretum.yml backend:` wins over `roadmap.config.yaml backend:`. Missing/empty backend defaults to `github` for backward compatibility.
- **GitHub adapter preservation.** With `backend: github`, the tracker helpers delegate to `gh` and preserve the existing GitHub output shape for migrated consumers.
- **Azure DevOps adapter normalization.** With `backend: azure-devops`, work item IDs are exposed as `number`, Azure tags are exposed as `labels[].name`, comments are exposed with `authorAssociation: "MEMBER"`, label creation is a no-op because ADO tags materialize on first use, and PR list returns an empty array so maintain flows degrade gracefully when merged-PR evidence is unavailable.
- **Pulse fail-silence.** All pulse readers return 0 with empty stdout when the file/field is missing; writers are atomic (`.tmp` + `mv`) and never error out the caller.
- **Tooling parity.** The `yq`/`jq` paths and the `python3` fallbacks are intended to produce equivalent output regardless of which tool is installed. `roadmap_config_list` captures `yq` output first and falls through to the python3 parser if the installed `yq` rejects the expression dialect, so runners with mikefarah `yq` and machines without `yq` keep the same list protocol.

## Test surface

- **RL-1:** `roadmap_project_root` inside a git repo echoes the repo toplevel (nonempty absolute path).
- **RL-2:** `roadmap_config_path` echoes the config path when `roadmap.config.yaml` exists under the root; echoes nothing when it is absent.
- **RL-3:** `roadmap_config_get wip_limit` against a fixture config returns the scalar with quotes/inline-comment stripped; a quoted value is unquoted.
- **RL-4:** `roadmap_config_get badkey$(touch x)` (malformed key) returns nonzero with no value echoed (key-name guard).
- **RL-5:** `roadmap_config_list component_values` against a block-style fixture returns one element per line; a flow-style `[a, b, c]` fixture returns the same three elements; an installed-but-failing `yq` falls back to the same python3 output.
- **RL-6:** `roadmap_pulse_get_field` / `roadmap_pulse_get_nag` against a missing pulse file return empty stdout and exit 0 (fail-silent).
- **RL-7:** `roadmap_pulse_update_field` followed by `roadmap_pulse_get_field` round-trips a value through the atomically-rewritten pulse JSON.
- **RL-8:** `roadmap_backend` defaults to `github`, reads `backend: azure-devops` from `roadmap.config.yaml`, and lets `.arboretum.yml backend: github` override the roadmap config.
- **RL-9:** `roadmap_tracker_issue_list` on `backend: github` delegates to `gh issue list` and returns its JSON unchanged.
- **RL-10:** Additional GitHub adapter wrappers (`roadmap_tracker_issue_close`, `roadmap_tracker_issue_comments`, `roadmap_tracker_pr_list`) delegate to the expected `gh` subcommands and return their output unchanged.
- **RL-11:** `roadmap_require_backend azure-devops` accepts a stubbed Azure CLI with the Azure DevOps extension surface and readable defaults.
- **RL-12:** `roadmap_tracker_issue_list` on `backend: azure-devops` calls `az boards query`, normalizes work item fields/tags to the expected issue JSON shape, and honors `--json`.
- **RL-13:** `roadmap_tracker_issue_show --json ...comments` fetches Azure work item comments through `az devops invoke` and normalizes trusted comments with `authorAssociation: "MEMBER"`.
- **RL-14:** `roadmap_tracker_issue_update --add-label/--remove-label` reads current ADO tags and patches `System.Tags` with a JSON Patch replace operation rather than relying on a naive CLI add.
- **RL-15:** `roadmap_tracker_issue_comment`, `roadmap_tracker_issue_close`, and `roadmap_tracker_pr_list` map to ADO discussion/state updates and empty PR-list degradation.
- **RL-16:** `roadmap_tracker_label_list` synthesizes the framework/configured label vocabulary for ADO tags.
- **RL-17:** `roadmap_tracker_issue_create` creates an Azure Boards work item and normalizes the created item response.

## Versioning

- **1.4** (2026-05-31) — makes `roadmap_config_list` fall back to python3 when an installed `yq` rejects the list expression.
- **1.3** (2026-05-31) — implements the Azure DevOps tracker adapter behind the neutral roadmap helper surface.
- **1.2** (2026-05-31) — extends the helper surface for close, comment-list, and PR-list operations used by maintain, stage-cache, and stage-log scripts.
- **1.1** (2026-05-31) — adds backend selection and the first backend-neutral tracker helper surface, with GitHub implemented and Azure DevOps recognized-but-not-implemented.
- **1.0** (2026-05-30) — initial contract. Library shape as of `scripts/roadmap/lib.sh` on `main`. Issue #303 (WS5 PR 7a).
