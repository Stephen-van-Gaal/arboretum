---
version: 1
name: workspace-isolation
status: active
document-shape: group
parent: arboretum
contains:
  - workspace-context
  - collision-detection
  - session-heartbeat
  - workspace-skill
owns: []
---

# Workspace Isolation

## Job (JTBD)

<!-- HUMAN -->
Keep each line of work physically isolated in its own branch + worktree so
concurrent sessions cannot collide, and make the resulting set of worktrees
legible to a beginner. This group owns the **worktrees-always policy** (every
file-changing session gets its own worktree as the *primary* collision guard,
leaning on git's one-branch-per-worktree enforcement), the collision-verdict
model that surfaces a second line of work before it forks, per-machine liveness
that lets dead claims expire, and the "where am I / switch to X" affordance.

Robustness lives in git's structural one-branch-per-worktree invariant +
filesystem isolation rather than in fragile per-skill branch checks (epic #622).

## Boundaries (non-goals)

<!-- HUMAN -->
- Does NOT orient the *next* session to its next task — that's `session-handoff`
  (a sibling; "what comes next" is a different reason to change).
- Does NOT own the boot banner's non-worktree blocks — that's
  `session-start-cycle-state` (a sibling). This group contributes only the
  worktree-map block, as cross-boundary integration the banner host renders.
- Does NOT gather raw workspace signals — that's `refresh-workspace-cache.sh`;
  this group's children *consume* the cache, they do not rebuild signal-gathering.
- Does NOT own commit guards — that's `git-workflow-tooling`.

## Children

<!-- HUMAN -->
| Name | Kind | One-line purpose |
|------|------|------------------|
| `workspace-context` | component (spec) | L0 sourced resolver: tree-root / branch / base-ref / cache handle, worktree-correct; hosts the `is_session_worktree` predicate. |
| `collision-detection` | component (spec) | L1 advisory verdict ladder (`clear`/`warn-reclaim`/`warn-reattach`/`warn-crosstool`/`block`). |
| `session-heartbeat` | component (spec) | Per-machine liveness sentinel so dead-session branch claims expire (TTL). |
| `workspace-skill` | component (spec) | The `/workspace` skill + helper: list active worktrees (enriched) and switch between them. |

## Integration

<!-- HUMAN -->
Layered: `workspace-context` (L0) is the read-only foundation every other child
sources for worktree-correct resolution. `collision-detection` (L1) consumes L0 +
the cache to compute its verdict; `session-heartbeat` feeds the verdict's
reattach/reclaim split. `workspace-skill` and the banner-map block both consume
L0 + the cache to render orientation. Data flows one way: signals → cache → (L0
resolution / L1 verdict / liveness) → orientation surfaces.

## Orchestration

<!-- HUMAN -->
The worktrees-always lifecycle threads through the build workflow: a worktree is
created at `/start` (strong, overridable default) when file-changing work begins;
`/design` and `/build` carry an idempotent create-if-absent guard (gated on
`workspace-context`'s `is_session_worktree` predicate) so skipped-`/start` entry
is still isolated; `/cleanup` removes the worktree post-merge. `/workspace`
provides on-demand list/switch between lifecycles.

## Shared Contracts

<!-- HUMAN -->
- `workspace-context.sh` sourced API (tree-root / branch / base-ref / cache
  handle / `is_session_worktree`) — the shared resolution grammar every child
  obeys.
- The workspace cache (`.arboretum/workspace-cache.json`) shape produced by
  `refresh-workspace-cache.sh` — read by L0, L1, the banner, and `/workspace`.

## Shared Schemas

<!-- HUMAN -->
The workspace-cache JSON (`current_branch`, `worktrees[]`, `local_branches[]`,
`open_pr`, drift) is the schema shared across `collision-detection`, the banner
block, and `workspace-skill`. All children scrub author-controlled fields via
`scripts/lib/scrub-control-chars.sh` before rendering into Claude's context.

## Implementation Notes

<!-- HUMAN -->
Worktrees-always is the group's owned **policy**, not a single component's
behaviour — it describes how the children compose into one user-facing model.
Native path convention: `.claude/worktrees/<branch>` (`EnterWorktree`'s home);
enumeration everywhere is path-agnostic via `git worktree list`. The 6 legacy
top-level `.worktrees/` worktrees remain valid and enumerable; no migration.

### Design record

<!-- AUTO -->
- `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` — worktrees-always default + this group (L2 of #622).

## Decisions

<!-- APPEND-AUTO -->
| ID | Decision | Alternatives Considered | Rationale | Date | Source |
|----|----------|------------------------|-----------|------|--------|
| D1 | Worktree creation triggers at `/start` on file-changing work ("every file-changing session", not "every session") | Session-boot hook; lazy at first write; per-skill | Boot spawns dirs for read-only sessions; lazy is diffuse; `/start` keeps dir-count == active work. | 2026-06-12 | `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` (D1) |
| D2 | Affordance = enhanced banner (passive) + thin `/workspace` skill (list + switch) | `/workspace`-only; banner+statusline; full `/worktree` CRUD | Discoverable + one-command action; CRUD overlaps `/start`+`/cleanup`. | 2026-06-12 | `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` (D2) |
| D3 | Harness-native `.claude/worktrees/` path; enumerate via `git worktree list` | Keep top-level `.worktrees/` + helper | gitignore/cleanup/banner already path-agnostic; native path = one harness step; no re-wiring. | 2026-06-12 | `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` (D3) |
| D4 | Strong-but-overridable default (decline → plain branch) | Hard default, no opt-out | `/start` is "guidance, not a gate"; the structural guard still applies whenever a worktree IS used. | 2026-06-12 | `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` (D4) |
| D5 | Single creation seam at `/start` + idempotent `create-if-absent` guard in `/design`/`/build` (gated on `workspace_is_session_worktree`) | Spread create-if-absent across all three; hook-driven auto-create | One owner; the predicate makes skipped-`/start` entry safe; spread re-introduces per-skill fragility. | 2026-06-12 | `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` (D5) |
| D6 | Lift the #622 cluster into this `workspace-isolation` group as a Task-0 precursor (first #742 group instance) | Separate precursor PR; ship then lift; separate group epic | The worktrees-always policy is group-altitude and homeless in any component spec; #716 is the honest trigger. | 2026-06-12 | `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` (D6) |
| D7 | Narrow group boundary (workspace isolation); session-continuity specs stay siblings | Wide group incl. `session-handoff`/`session-start-cycle-state` | Continuity changes for a different axis-C reason; groups forbid lumping two reasons-to-change. | 2026-06-12 | `docs/superpowers/specs/2026-06-12-worktrees-always-default-design.md` (D7) |
