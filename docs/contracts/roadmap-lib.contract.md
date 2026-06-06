---
seam: roadmap-lib
version: 1.14
producer-type: script
consumer-type: script
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
  - docs/superpowers/specs/2026-06-03-ado-closure-verification-design.md
  - docs/superpowers/specs/2026-06-06-handoff-exclusive-label-helper-design.md
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
- **`roadmap_backend [ROOT]`** — echoes the configured tracker backend. `.arboretum.yml backend:` takes precedence, `roadmap.config.yaml backend:` is accepted for compatibility, `roadmap.backend` is accepted as a nested compatibility alias, and missing/empty defaults to `github`. Normalizes `azure`/`ado`/`azure-devops` to `azure-devops`.
- **`roadmap_backend_config_get KEY [ROOT]`** — echoes backend-specific scalar config. For Azure DevOps, accepts both legacy flat `azure_devops_*` keys and the preferred namespaced `azure_devops:` block (`organization`, `project`, `default_work_item_type`, `done_state`, `closed_states`, etc.).
- **`roadmap_require_backend [BACKEND]`** — validates the selected backend's local prerequisites. `github` requires authenticated `gh`; `azure-devops` requires Azure CLI, the Azure DevOps CLI extension surfaces used by Arboretum (`az devops`, `az boards`, and `az repos`), readable Azure DevOps defaults, and `jq` for JSON normalization.
- **`roadmap_probe_backend_access [BACKEND] [ROOT]`** — validates that the current agent process can perform one live read through the selected backend after local prerequisites pass. `github` probes `gh api repos/{owner}/{repo} --jq .full_name` from the target repository root so GitHub Enterprise hosts and repo-scoped tokens follow the same repo context as the guarded operation; `azure-devops` probes `az devops project show` using organization/project resolved from the target root before falling back to Azure CLI defaults. On Codex-flavoured network failures, stderr includes scoped `sandbox_workspace_write.network_access` and `features.network_proxy` guidance for the selected provider.
- **`roadmap_tracker_issue_list`, `roadmap_tracker_issue_show`, `roadmap_tracker_issue_comment`, `roadmap_tracker_issue_update`, `roadmap_tracker_issue_close`, `roadmap_tracker_issue_create`, `roadmap_tracker_issue_comments`, `roadmap_tracker_label_list`, `roadmap_tracker_label_create`, `roadmap_tracker_pr_list`, `roadmap_tracker_pr_show`, `roadmap_tracker_pr_closure_status`** — backend-neutral tracker operations. The `github` adapter delegates to the corresponding `gh` subcommand for issue/label/PR operations and classifies PR-body closure intent for a specific issue. The `azure-devops` adapter maps issues/labels to Azure Boards work items/tags, returns the GitHub-shaped JSON fields consumed by existing roadmap scripts, supports a normalized PR-show subset, and verifies whether the target work item linked to a completed PR is already in a configured closed state without mutating it.
- **`roadmap_pulse_path`** — echoes `<root>/.arboretum/roadmap-pulse.json` (echoes nothing if root unknown).
- **`roadmap_pulse_bootstrap`** — idempotently seeds the pulse file (no-op if present); bootstrap-as-today so no nag fires on install day.
- **`roadmap_pulse_get_field KEY`** / **`roadmap_pulse_get_nag NAME`** — echo a scalar pulse field / `nag_last_fired[NAME]`; empty string when absent/null/file-missing.
- **`roadmap_pulse_set_nag_fired NAME`** / **`roadmap_pulse_update_field KEY VALUE`** — atomically (`.tmp` + `mv`) update the pulse JSON; fail-silent on any error.
- **`roadmap_set_globally_exclusive_label TARGET-ISSUE LABEL`** — makes LABEL globally exclusive across open issues: removes it from every open holder that is not TARGET-ISSUE, bare-ensures the label exists, then applies it to TARGET-ISSUE. The cross-issue counterpart to within-issue prefix exclusivity (e.g. `stage:*`); `/handoff` uses it for the single-open-holder `next-up` invariant. Honors `DRY_RUN=1` (prints the plan, mutates nothing). Composes the neutral `roadmap_tracker_*` helpers + `roadmap_label_exists`; rich label metadata (description/color) stays the caller's responsibility.

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
- `roadmap_backend [ROOT]` — optional project root. Reads `<root>/.arboretum.yml` first, then `<root>/roadmap.config.yaml`; accepts top-level `backend` and nested `roadmap.backend`.
- `roadmap_backend_config_get KEY [ROOT]` — backend-specific config key, with Azure DevOps flat-key and namespaced-block aliases.
- `roadmap_require_backend [BACKEND]` — optional backend string; defaults to `roadmap_backend`.
- `roadmap_probe_backend_access [BACKEND] [ROOT]` — optional backend string and project root. Backend defaults to `roadmap_backend`; root defaults to `roadmap_project_root`.
- `roadmap_tracker_issue_list ARGS...`, `roadmap_tracker_issue_show ISSUE ARGS...`, `roadmap_tracker_issue_comment ISSUE ARGS...`, `roadmap_tracker_issue_update ISSUE ARGS...`, `roadmap_tracker_issue_close ISSUE ARGS...`, `roadmap_tracker_issue_create ARGS...`, `roadmap_tracker_issue_comments ISSUE ARGS...`, `roadmap_tracker_label_list ARGS...`, `roadmap_tracker_label_create ARGS...`, `roadmap_tracker_pr_list ARGS...`, `roadmap_tracker_pr_show PR ARGS...`, `roadmap_tracker_pr_closure_status PR ISSUE` — pass-through args shaped for the neutral operation. The GitHub adapter preserves existing `gh`-compatible flags. The Azure DevOps adapter supports the subset used by roadmap scripts/skills: `--state`, `--limit`, `--label`, `--search`, `--json`, `--jq`, body/title edits, add/remove label, close/comment/create, label list/create, comment list, PR list, and normalized PR show.
- `roadmap_pulse_get_field KEY`, `roadmap_pulse_get_nag NAME`, `roadmap_pulse_set_nag_fired NAME` — one arg.
- `roadmap_pulse_update_field KEY VALUE` — two args.
- `roadmap_set_globally_exclusive_label TARGET-ISSUE LABEL` — two required args (the sole-holder issue number and the label name); reads `DRY_RUN` from the environment.
- All resolve their target file relative to `roadmap_project_root`; no stdin.

### Outputs

- **`roadmap_project_root`** — one line: an absolute path. Always nonempty.
- **`roadmap_config_path`** — one line (absolute path) when the config exists; empty stdout + return 0 when it does not.
- **`roadmap_config_get KEY`** — one line: the scalar value, surrounding quotes stripped, inline `# comment` stripped; empty line for null/`~`/absent value. Returns 1 (no stdout value) when config absent or key malformed.
- **`roadmap_config_list KEY`** — zero or more lines, one list element each (quotes stripped). Returns 1 when config absent or key malformed.
- **`roadmap_backend [ROOT]`** — one line: `github`, `azure-devops`, or a caller-visible unsupported backend string. Never empty.
- **`roadmap_backend_config_get KEY [ROOT]`** — one scalar value when configured; empty when absent. For Azure DevOps organization values, the adapter normalizes bare organization slugs to `https://dev.azure.com/<org>` before invoking Azure CLI.
- **`roadmap_require_backend`** — no stdout on success; stderr diagnostic + nonzero on missing tools/auth or unsupported backend.
- **`roadmap_probe_backend_access`** — no stdout on success; stderr diagnostic + nonzero on missing tools, auth/config setup, unsupported backend, or live API read failure. If local prerequisites pass but the live read fails while running under Codex (`CODEX_SANDBOX` or `CODEX_SHELL` present), stderr includes a concrete Codex network configuration snippet for the selected backend. GitHub diagnostics mention `GH_TOKEN` / `GITHUB_TOKEN` precedence because stale token env vars can mask keychain auth.
- **`roadmap_tracker_*` helpers** — stdout/stderr/exit code of the selected backend adapter. For `github`, this is the corresponding `gh` subcommand except `roadmap_tracker_pr_closure_status`, which emits the neutral closure-status protocol below. For `azure-devops`, issue/work-item responses normalize to objects with `number`, `title`, `url`, `body`, `labels[].name`, `createdAt`, `updatedAt`, `closedAt`, `state`, and `comments[]` when requested; PR-show responses normalize to `number`, `title`, `body`, `state`, and `mergedAt`. Azure DevOps body writes render the Arboretum-authored Markdown subset to HTML before writing `System.Description`; reads expose the backend's canonical stored body.
- **`roadmap_tracker_pr_closure_status PR ISSUE`** — four newline-delimited key/value lines:
  - `provider=<github|azure-devops>`
  - `intent=close|reference|none|unknown`
  - `verification=supported|unsupported|unknown`
  - `evidence=<controlled string>`
  For GitHub, `Closes #N` / `Fixes #N` / `Resolves #N` variants classify as `intent=close`; a bare `#N` classifies as `intent=reference`; no mention classifies as `intent=none`. For Azure DevOps, the helper lists PR-linked work items, finds the requested issue/work-item, reads its current state, and returns `intent=close` / `verification=supported` only when that work item is already in the configured closed-state set. Linked-but-open work items return `intent=unknown` / `verification=unknown`; absent links and provider read failures also return non-close results with controlled evidence.
- **`roadmap_pulse_path`** — one line: the pulse JSON path; empty when root unknown.
- **`roadmap_pulse_get_field KEY`** / **`roadmap_pulse_get_nag NAME`** — one line: the field/nag value; empty string when absent, null, or file missing. Always returns 0.
- **`roadmap_pulse_set_nag_fired` / `roadmap_pulse_update_field`** — no stdout; side effect is an atomic rewrite of the pulse JSON. Always returns 0 (fail-silent).
- **`roadmap_set_globally_exclusive_label`** — no stdout on success; returns 0. Returns 2 with a stderr diagnostic when either argument is missing. Side effect: the label is removed from every open non-target holder, ensured to exist, and applied to the target. With `DRY_RUN=1`, prints one `would remove '<label>' from #<n>` line per cleared holder plus a final `would add '<label>' to #<target>` line, and performs no tracker mutation. A failed clear does not abort the sweep (every holder is still attempted, then the target applied), but it is not ignored: the helper returns nonzero if holder enumeration (`roadmap_tracker_issue_list`) fails, any holder `--remove-label` fails, or the target `--add-label` fails — so a caller never reads success while exclusivity was not actually achieved. On a list failure no clear is attempted (no holders are known), but the target is still applied.
- The config getters print a tooling diagnostic to stderr and return nonzero when neither `yq` nor `python3` is available.

### Invariants

- **Root always resolves.** `roadmap_project_root` always echoes a nonempty absolute path (git toplevel → `$CLAUDE_PROJECT_DIR` → `pwd`), worktree-aware.
- **Config-path emptiness signals absence.** `roadmap_config_path` echoes the path only when the file exists; an empty echo means "no config," never a default path.
- **Key-name guard.** `roadmap_config_get`/`roadmap_config_list` reject keys not matching `^[a-zA-Z_][a-zA-Z0-9_]*$` with a stderr diagnostic and nonzero return — no shell-injection surface into the parser.
- **Scalar normalization.** `roadmap_config_get` strips matched surrounding quotes and a trailing inline comment, and maps `''`/`null`/`~` to an empty line.
- **List line-protocol.** `roadmap_config_list` emits exactly one element per line for both block and flow YAML styles, quotes stripped.
- **Backend selection precedence.** `.arboretum.yml backend:` wins over `roadmap.config.yaml backend:`. Nested `roadmap.backend` is accepted only when the top-level key is absent. Missing/empty backend defaults to `github` for backward compatibility.
- **Azure DevOps config aliases.** The preferred ADO shape is the namespaced `azure_devops:` block. Legacy flat keys remain accepted aliases, and bare organization slugs normalize to `https://dev.azure.com/<org>`.
- **Sourceable shell portability.** Skill snippets may source this library from bash or zsh. Backend selection, CSV helper parsing, ADO closed-state parsing, and pulse read/write helpers MUST preserve the same output contract under both shells.
- **GitHub adapter preservation.** With `backend: github`, the tracker helpers delegate to `gh` and preserve the existing GitHub output shape for migrated consumers.
- **Azure DevOps adapter normalization.** With `backend: azure-devops`, work item IDs are exposed as `number`, Azure tags are exposed as `labels[].name`, comments are exposed with `authorAssociation: "MEMBER"`, label creation is a no-op because ADO tags materialize on first use, PR show normalizes Azure Repos fields to the neutral PR shape, and PR list returns an empty array so maintain flows degrade gracefully when merged-PR evidence is unavailable.
- **ADO rich-text description writes.** Azure DevOps `System.Description` is an HTML-rich field. The ADO adapter renders the Markdown subset Arboretum emits in issue bodies (`##` / `###` headings, paragraphs, unordered lists, fenced code blocks, inline code, bold spans, and escaped literal text) to HTML before create/update description writes. Existing ADO HTML block/comment lines are preserved so read-modify-write flows (including pipeline-state marker rewrites) do not corrupt already-rendered descriptions. Unsupported Markdown degrades as escaped text; GitHub body writes remain raw Markdown.
- **ADO tag merge output is raw.** The Azure DevOps tag-merge helper emits the semicolon-delimited `System.Tags` scalar as raw text, never as a JSON-encoded string. Callers may pass the value directly to `System.Tags=...` without stripping quotes.
- **Closure evidence is controlled.** `roadmap_tracker_pr_closure_status` MUST NOT echo raw PR titles or body text. Evidence strings are generated from provider, PR number, issue number, and classification only.
- **ADO closure verification is read-only.** Azure DevOps closure-status verification MUST NOT transition or close work items. It may report supported close evidence only for the specific linked work item whose current state is already in the configured closed-state set.
- **ADO linkage is not closure.** A linked Azure DevOps work item whose current state is not closed MUST return `intent=unknown` / `verification=unknown`; callers MUST surface the manual follow-up instead of assuming PR linkage closed the tracker item.
- **ADO closed-state config reuse.** Azure DevOps closure verification MUST compare trimmed `System.State` values against trimmed `azure_devops.closed_states` / `azure_devops_closed_states` entries with the existing default `Closed,Done,Removed`. If the configured value is effectively empty after CSV splitting and trimming, the helper falls back to that default set.
- **Cheap setup vs live reachability are distinct.** `roadmap_require_backend` is the cheap local prerequisite guard and may run frequently. `roadmap_probe_backend_access` performs a provider API read and should be used at workflow edges where a clear "this process can reach the backend" diagnostic is worth the extra call; neutral `roadmap_tracker_*` helpers do not call the probe internally.
- **Pulse fail-silence.** All pulse readers return 0 with empty stdout when the file/field is missing; writers are atomic (`.tmp` + `mv`) and never error out the caller.
- **Global label exclusivity.** `roadmap_set_globally_exclusive_label` MUST remove the label from every open holder except the target, MUST ensure the label exists before applying, and MUST apply it to the target. The target is never cleared. `DRY_RUN=1` MUST perform no tracker mutation (no remove, no create, no add) and instead print the planned operations. Rich label metadata (description/color) is the caller's responsibility; the helper's ensure-exists is bare.
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
- **RL-8b:** `roadmap_ado_merge_tags` emits raw semicolon-delimited `System.Tags` text in the normal bash path: no JSON quote characters, both expected tags present, and at least one semicolon separator.
- **RL-8z:** When zsh is available, sourcing `roadmap/lib.sh` from zsh preserves backend selection from `roadmap.config.yaml`, `.arboretum.yml` precedence, custom Azure DevOps closed-state parsing, CSV field detection, raw ADO tag merging, and pulse read/write helpers.
- **RL-9:** `roadmap_tracker_issue_list` on `backend: github` delegates to `gh issue list` and returns its JSON unchanged.
- **RL-10:** Additional GitHub adapter wrappers (`roadmap_tracker_issue_close`, `roadmap_tracker_issue_comments`, `roadmap_tracker_pr_list`) delegate to the expected `gh` subcommands and return their output unchanged.
- **RL-11:** `roadmap_require_backend azure-devops` accepts a stubbed Azure CLI with the Azure DevOps extension surface and readable defaults.
- **RL-12:** `roadmap_tracker_issue_list` on `backend: azure-devops` calls `az boards query`, normalizes work item fields/tags to the expected issue JSON shape, and honors `--json`.
- **RL-13:** `roadmap_tracker_issue_show --json ...comments` fetches Azure work item comments through `az devops invoke` and normalizes trusted comments with `authorAssociation: "MEMBER"`.
- **RL-14:** `roadmap_tracker_issue_update --add-label/--remove-label` reads current ADO tags and patches `System.Tags` with a JSON Patch replace operation rather than relying on a naive CLI add.
- **RL-15:** `roadmap_tracker_issue_comment`, `roadmap_tracker_issue_close`, and `roadmap_tracker_pr_list` map to ADO discussion/state updates and empty PR-list degradation.
- **RL-16:** `roadmap_tracker_label_list` synthesizes the framework/configured label vocabulary for ADO tags.
- **RL-17:** `roadmap_tracker_issue_create` creates an Azure Boards work item and normalizes the created item response.
- **RL-18:** `roadmap_probe_backend_access github [ROOT]` delegates to `gh auth status` through `roadmap_require_backend`, then probes `gh api repos/{owner}/{repo} --jq .full_name` from `ROOT`; an auth-ok/live-call-failed Codex path emits GitHub network guidance and mentions token env precedence.
- **RL-19:** `roadmap_probe_backend_access azure-devops [ROOT]` delegates to `roadmap_require_backend`, resolves organization/project from `ROOT` before CLI defaults/env fallbacks, then probes `az devops project show`; a defaults-ok/live-call-failed Codex path emits Azure DevOps network guidance.
- **RL-20:** Cedar-shaped Azure DevOps config with no `.arboretum.yml`, root-level `backend: azure-devops`, and a namespaced `azure_devops:` block resolves backend, organization URL, project, and default work-item type.
- **RL-21:** `roadmap_tracker_pr_show` delegates to `gh pr view` on GitHub and normalizes `az repos pr show` output on Azure DevOps.
- **RL-22:** `roadmap_tracker_pr_closure_status` on GitHub classifies merged PR bodies as `intent=close`, `intent=reference`, or `intent=none`, with `verification=supported` and controlled evidence.
- **RL-23:** `roadmap_tracker_pr_closure_status` on Azure DevOps returns `intent=unknown` / `verification=unknown` for a PR-linked target work item whose current state is still open.
- **RL-24:** The same helper returns `intent=close` / `verification=supported` only when the linked target work item is already in a configured closed state.
- **RL-25:** The same helper returns `intent=none` / `verification=unknown` when the PR has linked work items but not the requested target issue.
- **RL-26:** The same helper returns `intent=unknown` / `verification=unknown` when ADO PR work-item lookup fails.
- **RL-27:** ADO closure verification trims work item states and falls back to default closed states when `azure_devops.closed_states` / `azure_devops_closed_states` is effectively empty.
- **RL-28:** `roadmap_tracker_issue_update --body` on Azure DevOps renders the supported Markdown subset from stdin-fed converter input, preserves existing ADO HTML block/comment lines, and patches `System.Description`.
- **RL-29:** `roadmap_tracker_issue_create --body` on Azure DevOps sends the same rendered HTML description to Azure Boards while preserving the normalized created-item response shape.
- **RL-35:** `roadmap_set_globally_exclusive_label 574 next-up`, with the tracker primitives overridden to report open holders `{11, 22, 574}` and the label absent, removes the label from `11` and `22` (never `574`), creates the label, and adds it to `574`.
- **RL-35b:** the same helper with `DRY_RUN=1` performs no tracker mutation and prints the exact plan lines (`would remove 'next-up' from #11`, `would add 'next-up' to #574`).
- **RL-35c:** when a holder's `--remove-label` fails, the helper still applies the label to the target (best-effort) but returns nonzero — a failed clear is surfaced, never silently swallowed.
- **RL-35d:** when the holder enumeration (`roadmap_tracker_issue_list`) fails, the helper attempts no clear, still applies the label to the target, and returns nonzero — an unverifiable sweep is not reported as success.

## Versioning

- **1.14** (2026-06-06) — adds `roadmap_set_globally_exclusive_label`, the cross-issue exclusive-label helper extracted from `/handoff` Step 4–5, with RL-35/35b/35c/35d pinning the clear-others / bare ensure-exists / apply-to-target sequence, the `DRY_RUN` plan output, and nonzero-return on failed clear or failed holder-enumeration (no silent exclusivity breach). Issue #574.
- **1.13** (2026-06-04) — renders Arboretum-authored Markdown bodies to HTML for Azure DevOps `System.Description` create/update writes, preserves existing ADO HTML during read-modify-write updates, and keeps GitHub raw Markdown unchanged. Issue #540.
- **1.12** (2026-06-03) — pins raw Azure DevOps `System.Tags` merge output so ADO labels created through `/idea` and roadmap helper paths do not store JSON quote characters. Issue #506.
- **1.11** (2026-06-03) — implements read-only Azure DevOps closure-status verification for the target linked work item and pins open/closed/missing/failure/defaulted-state cases. Issue #489.
- **1.10** (2026-06-03) — adds neutral PR detail and closure-status helpers so the ship tail can record and verify tracker closure intent without embedding provider-specific tracker commands in skills. Issue #484.
- **1.9** (2026-06-03) — accepts Cedar-shaped namespaced Azure DevOps config and bare organization slugs while retaining flat `azure_devops_*` aliases. Issue #485.
- **1.8** (2026-06-02) — pins zsh-sourced roadmap helper behaviour after issue #469 exposed backend fallback from zsh special-parameter and Bash-only CSV parsing gaps.
- **1.7** (2026-06-02) — changes the GitHub probe to the repo-scoped `repos/{owner}/{repo}` endpoint and adds the optional project-root argument so Azure DevOps config resolves from the target project. PR #468 review feedback.
- **1.6** (2026-06-02) — adds `roadmap_probe_backend_access` so workflow edges can distinguish local CLI setup from live provider reachability in Codex and other agent environments. Issue #465.
- **1.5** (2026-05-31) — extends the Azure DevOps backend guard to verify the `az repos` surface used by backend-aware PR shipping. Issue #338.
- **1.4** (2026-05-31) — makes `roadmap_config_list` fall back to python3 when an installed `yq` rejects the list expression.
- **1.3** (2026-05-31) — implements the Azure DevOps tracker adapter behind the neutral roadmap helper surface.
- **1.2** (2026-05-31) — extends the helper surface for close, comment-list, and PR-list operations used by maintain, stage-cache, and stage-log scripts.
- **1.1** (2026-05-31) — adds backend selection and the first backend-neutral tracker helper surface, with GitHub implemented and Azure DevOps recognized-but-not-implemented.
- **1.0** (2026-05-30) — initial contract. Library shape as of `scripts/roadmap/lib.sh` on `main`. Issue #303 (WS5 PR 7a).
