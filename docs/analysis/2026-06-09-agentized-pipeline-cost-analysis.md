# Restructuring the Arboretum Pipeline for Cost & Context Discipline

**An analysis of the agentized-pipeline opportunity**

Date: 2026-06-09
Status: analysis (not governed) — input to `/start` on the conductor/driver epic (#516) and the cost-reduction epic (#467)
Author: prepared with Claude Code, grounded in a five-thread codebase audit

---

## 1. Executive summary

Arboretum's build pipeline is, structurally, **one long inline session**. From `/design` through `/land`, a single growing context window carries every stage, re-reading the same register, diff, base-ref, and health-check repeatedly, and running every dispatched subagent on whatever frontier model the parent inherited. The project has now *measured* what that costs, and the numbers are unambiguous:

- **Context intake is ~68% of total spend** — it dominates generative ("operation") cost roughly 2:1 in two measured full-cycle sessions.
- **Subagent model inheritance is the dominant hidden cost** — one `general-purpose` subagent ran 409 Opus turns for ~$27.70, making a session's real cost **42% higher than it appeared** to parent accounting.
- **`/land` is the measured #1 cost stage** (not `/consolidate`, as previously assumed), and the *context-tax ratio* (carried-context $ ÷ generative $) is a better driver-targeting signal than raw dollars — it surfaces high-tax mechanical tail stages (`/handoff` at 8.4×, `/consolidate` at 4.2×, `/security-review` at 4.9×) that raw dollars bury.

The good news: the **target architecture is already partly built and proven**. Two stages — `/cleanup` (the cleanup driver) and the B4 review lanes — already run their read-heavy work in fresh-context subagents and return only a structured manifest, bounding main-thread cost. The reusable contract behind them (the **brief/manifest file seam**) is the single mechanism that answers four of the five questions in this report at once. And the substrate you suspected might help — **selective section retrieval** — is not aspirational: it shipped (`document-access.spec.md`, active), is used by nine skills, and validated **~85% context reduction** on the largest spec.

The opportunity is therefore not "invent an agentized pipeline" but **finish and systematize one that already has working exemplars**: convert the remaining inline hotspots to drivers, make per-stage model choice a first-class field, enforce bounded reads as the default, and stamp cost back into the loop so selection and accounting close.

This report covers (2) how the pipeline is built today, (3) what's already been built under Slipstream, (4) the selective-retrieval finding, then (5) recommendations organized around your five questions, and (6) a prioritized sequence.

---

## 2. How the pipeline is built today

### 2.1 The shape

The build workflow is a linear chain of slash-skills, each invoked in the **main agent context** unless it explicitly delegates:

```
/start → [/design] → /build → /finish → review (B4) → /pr → /land → /cleanup → /reflect
```

Skill sizes (lines of SKILL.md) gauge inline weight: `consolidate` 493, `land` 487, `pr` 388, `finish` 370, `start` 338, `cleanup` 300, `design` 287, `build` 277. The heaviest build-path skills are exactly the ship tail — `/consolidate`, `/land`, `/pr`, `/finish` — and they run **inline**.

Only three skills even carry the `Task` tool in their frontmatter (`cleanup`, `design`, `design-package`). That is the ground truth for "can shed work into a subagent." Everything else executes in the one main context.

### 2.2 Where the money goes (measured)

From `spikes/2026-06-08-pipeline-context-flow/FINDINGS.md`, two real full-cycle sessions, priced per-model-family by the journey tooling:

| Session | context $ | operation $ | total $ | context share |
|---|---|---|---|---|
| PR-638 | 19.40 | 9.19 | 28.59 | **68%** |
| full cycle | 32.86 | 15.63 | 48.49 | **68%** |

Per-stage (representative full cycle), with the **context-tax ratio** (ctx$ ÷ op$) as the key column — high tax = carrying a lot of resident context while doing little generative work, which is precisely the signature a fresh-context driver erases:

| Stage | total $ | tax | mode |
|---|---|---|---|
| **land** | 16.25 | 2.0× | inline |
| build | 10.60 | 4.1× | executing-plans (delegated) |
| pr | 6.10 | 1.2× | inline |
| design | 5.87 | 1.1× | brainstorm+plan (delegated) |
| consolidate | 3.99 | **4.2×** | inline |
| handoff | 2.30 | **8.4×** | inline |
| security-review | 1.53 | 4.9× | driver (isolated) |
| start | 0.38 | 1.2× | inline |

> Absolute dollars are *relative* estimates from a dated Opus-family rate table via a `chars/4` heuristic — trust the **ranking**, not the billing. The load-bearing measured figures are the ratios: 68% context share, 42% hidden-subagent inflation, 12.5× cache-bust penalty, 85% cache-read steady state.

### 2.3 The re-read tax

The clearest argument for restructuring is duplication. The same artifacts are pulled into context again and again down the ship tail:

- **REGISTER "Spec Index"** is read in four stages (`/finish`, `/consolidate`, `/pr`, `/cleanup`).
- **`workspace-context.sh` / base-ref** is sourced ~20 times across finish/consolidate/pr/ai-surface/cleanup/land — each stage independently re-derives the base ref and re-runs `git diff $BASE...HEAD`.
- **The git diff** is recomputed in `/finish`, `/consolidate`, every B4 lane, and `/pr`.
- **`health-check.sh`** (the largest script in the repo, ~59 KB) runs at minimum three times per cycle in the main thread.
- **`concept-catalog.md`** (~2.2k tokens) was re-read on *every commit*.

A partial fix already shipped — the **pipeline-context ledger** (#665, merged): a single SHA-keyed JSON cache (`.arboretum/pipeline-context-cache.json`) that lets `/finish`→`/consolidate`→`/pr` read a cached spec-index/issue-snapshot/diff instead of re-resolving. It self-invalidates on any HEAD advance and is read-through and self-healing. But it is **slice-1 only**: it covers the pre-merge same-HEAD cluster, the spec-index field, and deliberately excludes health-check (which must recompute to catch drift). `/cleanup` and `/reflect` run post-merge where HEAD has advanced and the cache is structurally cold; base-ref derivation and the full diff aren't ledgered at all. So the re-read tax is dented, not eliminated.

### 2.4 The hidden subagent cost

When a skill dispatches a subagent without naming a model, the subagent **inherits the parent model — typically Opus**. A grep across `skills/` and `workflows/` confirms **zero** explicit `model=` parameters are passed anywhere; every model reference is prose. So a mechanical `/cleanup` survey and a hard `/design` reasoning task run on the same frontier model purely because nobody set the parameter — and because subagent burn is invisible in the parent context, the cost isn't felt until allotment limits hit.

---

## 3. What's already been built (the Slipstream foundations)

The restructuring you're contemplating has a name and an in-flight epic: **Slipstream (#516)**, pivoting the monolithic session into a thin coordinator that dispatches stage-work to fresh-context subagents. Critically, **the superstructure is designed but unshipped**, while **two exemplar stages are shipped and proven**. Knowing which is which keeps the recommendations honest.

### 3.1 The control hierarchy (designed, on `feat/pipeline-conductor`)

| Tier | Sequences | Term | Lifetime |
|---|---|---|---|
| Epic | order of work across many issues/PRs | **orchestrator** | many sessions |
| Pipeline | one issue through start→reflect | **conductor** | one issue's journey |
| Stage | one stage's internal sub-steps | **driver** | one stage |

The **conductor** owns one issue's journey and *stays thin*. The design states the entire cost thesis in one sentence: *"The conductor session holds only file-seam artifacts (the brief it wrote, the report it read back), never a driver's working transcript… if the conductor retains driver transcripts, it becomes the new 500k-token mega-session and the refactor loses money instead of saving it."* Per design decision D8, `/start` *becomes* the conductor after triage — there is no separate `/conduct` skill.

The **arrangement** is the machine-readable recipe the conductor performs: *"which stages run, in what order, in which dispatch mode, on which default model, across which seam contracts."* This single abstraction is where dispatch-mode and model decisions live — which is why it answers several of your questions at once.

Three **dispatch modes** let each stage declare *how* the conductor runs it (a driver runs headless and can't stop to ask a human mid-run):

- **`dispatched`** — conductor writes a brief, hands the whole stage to a fresh-context driver, reads back a report. Best cost profile: full context-shed + model routing.
- **`resident`** — stage runs in the conductor's own session (it's a dialogue). Worst: conductor carries the stage's tokens. This is *exactly today's behavior* — so the migration is a graceful "mixed fleet" where unconverted stages stay resident and converted ones dispatch.
- **`split`** — *elicit* runs resident (cheap dialogue), *produce* dispatches to a driver (expensive, routable generation). Captures most of the win on interactive stages like `/design`.

### 3.2 The brief/manifest seam (the key reusable contract)

This is the most important thing already invented, because it is the answer to "how do I match a plugin to a task *and* give it the context it needs *and* route its model." The conductor↔driver contract is **two files**:

- A **brief** (conductor → driver) carries: the stage + dispatch mode + **selected model**; an **authority bundle** — resolver-selected *current-promise + required-seam* sections only, never full specs; inputs from the upstream seam; and an **exit contract** (exactly what to produce for the next seam, plus escape-hatch conditions).
- A **report/manifest** (driver → conductor) carries: outcome (success / escape-hatch / blocked + artifacts); **seam outputs** (the frontmatter/contract fields the *next* stage reads, so the conductor composes the next brief *without re-reading the driver's transcript*); and a **cost stamp** (stage, model, token counts).

Two design principles make this generalize:

1. **"Briefs are seam-specific in body, common in envelope."** `scripts/write-agent-brief.sh` is not a universal brief — it's the S2-seam brief for one specific lane. What generalizes is the *pattern* (validated input → seam-conformant brief file), not one brief shape. It also already models untrusted-input discipline: it writes the task statement via `printf` with no shell expansion, structurally isolating author-controlled text.
2. **"Inject narrowly."** The brief's authority bundle is built by a context-resolver — *discover broadly, inject narrowly* — current promise + relevant seams, not full history.

### 3.3 The two shipped exemplars

**B4 review lanes** (PR #677, governed by `review-stage.spec.md`, active). The B4 gate dispatches, as fresh-context drivers in order: the homegrown `/ai-surface-review` lane, an always-on `general-security` backend (default `/security-review`), and a code-gated `correctness` backend (default `/code-review`). Each lane is *replaceable behind a brief/manifest seam* and degrades to the `/land` reviewers (Copilot/Codex) when its backend is absent — an explicit "deferred to /land reviewers" note, never a silent skip. The manifest schema is enforced by `scripts/validate-review-manifest.sh` (required keys: `lane`, `files_reviewed`, `surface_identified`, `coverage[]` with status ∈ evaluated|cleared, `findings[]` with severity ∈ critical|warning|info). A clean result is `findings: []` *with* a full `coverage[]` — "checked + safe" is distinguishable from "didn't look."

**Cleanup driver** (#644, PR #653). `/cleanup` asks its single human question (close the tracker?) *before* dispatch, then dispatches a driver so the mechanical orchestration runs in fresh context; the main thread holds only the file-seam results. It also established a reusable boundary: *a subagent must never remove the worktree it is standing in* — the driver reports `ready-active` and the **main thread** performs the terminal action.

### 3.4 The dispatch-idiom bug worth internalizing (#720)

When #677's dispatch was first exercised for real, it failed: `/finish` said "dispatch a subagent → `/ai-surface-review` driver," which read literally as naming `ai-surface-review` as the *subagent type* — but it's a skill, not a registered agent type, so the call errored. The fix codified the idiom once in a new governed spec (`skill-and-agent-authoring.spec.md`):

> The main thread dispatches a **generic** subagent (`general-purpose`) and briefs it. When the work is a slash-command skill, the brief instructs the subagent to **invoke that skill**; when it's a procedure, the brief inlines the steps. **Invariant:** the skill/lane name is *what the subagent runs* — it is never passed as `subagent_type`. The subagent type is always generic. The subagent returns only its structured result, never its transcript.

This matters for plugin matching: it's *why* the seam can mix homegrown arboretum skills, built-in Claude skills (`/security-review`, `/code-review`), and future third-party plugin skills identically — the backend is just a **string in the brief**, not a registered type. They explicitly rejected a per-lane agent registry because the built-in backends can't be wrapped as custom agents.

---

## 4. Selective section retrieval — you were right, and it's shipped

You flagged document structure + selective section retrieval as "potentially useful, not sure if it'll be a big saver." The audit answer: **it's implemented, governed, active, and measured — and it is a big saver on exactly the documents that get read repeatedly.**

`docs/specs/document-access.spec.md` (status active) owns four read-only, **zero-LLM, deterministic** scripts:

- `explore-doc.sh` — discovers a doc's shape and retrievable section keys *without reading bodies*.
- `read-doc-section.sh` — extracts one section by normalized heading, omitting frontmatter.
- `read-doc-sections.sh` — multiple named keys in order, all-or-nothing.
- `read-doc-profile.sh` — reads named `read_profiles.<profile>.sections[]` bundles from frontmatter.

The enabling substrate is mature: `docs/templates/document-shapes.yaml` declares a stable section taxonomy with semantic keys per document type (a governed spec has 10 fixed keys: purpose, boundaries, behaviour, quality-attributes, customer-experience, requires, provides, tests, implementation-notes, decisions). The template binds instances via `document-shape: governed-spec` frontmatter, so specs have stable, named, addressable anchors. Nine skills already call this toolchain (design, consolidate, pr, extract-component, cleanup, architect, finish, design-package, build) — e.g. `/design` surveys the 1078-line `ARCHITECTURE.md` via `explore-doc.sh` → `read-doc-section.sh`, falling back to whole-file only when discovery is insufficient.

**Is it a big saver?** Concentrated, not uniform — which is correct. The validated number is **~85% context reduction** on `roadmap.spec.md` (449 lines), where **~28% of its 40-row decision table is dead** (superseded/historical). Mature specs carry 40–76 decision rows; a typical single-subsystem task needs ~4–5. But `document-access.spec.md` itself is 155 lines / 6 rows — the design *threshold-gates* the scaffolding so it's a no-op on small specs. The mechanism is cheap and safe: deterministic, byte-exact, token-ledgered, no model round-trip.

**The unbuilt frontier** is *intra-section* retrieval — selecting *within* the Decisions section, where the unbounded growth actually lives. Epic #680 (spec-for-specs, design merged via PR #690) frames selective retrieval as the reconciler between "richer specs (#671)" and "cheaper context (#516)": *store the full tree durably, retrieve sub-trees on demand.* Child **#682** (designed, **unbuilt** — the worktree has zero #682-specific commits) proposes a Status column (load active-only by default), a two-altitude decision record (always-cheap summary line + on-demand detail keyed by stable decision ID), and area tags for scoped retrieval — *"serve via existing machinery… extend `read_profiles` to understand decision IDs and the summary/detail split. No new infrastructure."* Spike **#667** (unexecuted) defines the boundary between document-access (deterministic, in-context, cross-tool-portable, governance-exact) and Explore subagents (context-isolation, model-inference, Claude-Code-only) — concluding they're *complementary*: Explore for breadth-discovery-where-you-only-need-the-conclusion; document-access for targeted retrieval of known content the skill must act on.

**Bottom line:** the addressable-document substrate exists and is proven. The remaining cost recovery is (a) *enforcing* bounded reads as the default rather than the advised path, and (b) shipping #682's row/area-level retrieval for the large decision tables.

---

## 5. Recommendations, organized around your five questions

### Q1 — How to structure decisions so we match the right plugin to the task

**The match is already a seam, not a lookup.** Because a lane backend is just a string in a brief that a generic subagent invokes, "matching a plugin to a task" reduces to three decisions the conductor's *arrangement* should encode per stage:

1. **What capability does this stage need?** (AI-surface scrutiny, general security, correctness, design judgment, mechanical cleanup.) This is the *lane*, defined by the spec that owns the stage — not by which plugin happens to be installed.
2. **What's the default backend, and what's the degradation?** Follow the review-stage pattern exactly: each capability has a *default* backend (homegrown or built-in) and an explicit *degrade* target when absent. Never silent-skip; emit "deferred to X."
3. **Is the backend gated?** B4 already shows two gates worth generalizing: `ai-surface` runs only when AI-facing globs matched; `correctness` runs only when the change classifies as `code`. Gating is the cheapest possible "model selection" — *not running a lane at all* beats running it cheaply.

**Recommendation:** make the lane→backend→gate→degrade mapping a declared table per stage (the arrangement's seam-contract column), with backends expressed as invocable skill-name strings. This is the structure that lets you slot a third-party plugin in without touching the conductor: register its skill name as a lane's default, define its brief inputs and its manifest schema, and the seam does the rest. The selection criteria themselves (which plugin for which capability) should live in the **owning spec's Boundaries/Provides sections**, so the decision is governed and reviewable, not ad hoc per session.

> A concrete near-term win: the inline plugin-discovery bash block in `/start` (lines 245–308) is exactly the kind of capability-detection that belongs in the arrangement layer as data, not re-executed prose.

### Q2 — How to structure plugin calls to give them the context they need

**Use the brief contract, and resolve the brief with document-access — don't hand over a transcript.** The two design principles already established are the whole answer:

- **Inject narrowly.** A brief carries the *authority bundle* (resolver-selected current-promise + required-seam sections), the upstream seam inputs, and an explicit exit contract — not the conductor's history. This is where selective retrieval (§4) becomes load-bearing: the brief's authority bundle should be *built from `read-doc-section.sh` / `read_profiles` slices*, not whole specs. A driver that needs the `behaviour` and `requires` sections of one spec should receive exactly those, byte-exact, with provenance — never the whole file and never a paraphrase (governance operations need exactness Explore can't guarantee).
- **Seam-specific body, common envelope.** Don't build one universal brief. Build a *family* of per-seam brief writers (the `write-agent-brief.sh` pattern), each validating its inputs and emitting a seam-conformant file. Standardize the *envelope* (stage, mode, model, exit contract, escape hatches) and the *manifest schema* the backend must return.
- **Treat brief inputs as untrusted.** Carry forward the `printf`-no-expansion discipline and the CLAUDE.md control-char scrubbing for anything author-controlled flowing into a brief.

**Recommendation:** define a brief envelope schema and a manifest schema as governed contracts (you already have `validate-review-manifest.sh` as the prototype), then make every driver dispatch go through a per-seam brief writer that populates the authority bundle via document-access slices. The payoff compounds: narrow briefs are *both* cheaper (less context shipped) *and* higher-quality (the backend isn't distracted by irrelevant history) — which is the "more precise use of context" you're after.

### Q3 — How to leverage agents to make our own methods more efficient and effective with context

**Convert the inline hotspots to drivers, prioritized by context-tax, not raw dollars.** The measured per-stage table (§2.2) is your target list. Raw dollars say "fix `/land` and `/build`"; the tax ratio says the *mechanical tail* is where context-shed is almost pure win:

- **`/consolidate` (4.2× tax, runs up to twice per cycle)** — the single heaviest build-path skill, reads and regenerates every touched spec inline, and can fire again mid-`/land`. Highest-value driver extraction. The spec-read/regenerate work is mechanical and seam-bounded — ideal for a dispatched driver returning a reconciliation manifest.
- **`/land` (#1 raw cost, 2.0× tax)** — the per-cycle review/CI poll-and-fix loop. Measurement *reprioritized this up* alongside `/consolidate`. The split is natural: keep the human-facing triage decisions resident; dispatch the read-heavy comment-ingestion and fix-application to drivers.
- **`/handoff` (8.4× tax)** — the cheapest fix with the most absurd ratio: it runs at *peak end-of-session context* to write one tracker label. Delegate it to a tiny subagent (or Haiku) that takes only an issue number and a flag. Near-free to build, immediate saving.
- **`/security-review` (4.9× tax)** — already a driver; verify it's actually shedding and not re-deriving the diff.

**The pattern to copy is `/design`'s** — it delegates brainstorm + writing-plans and measures at 0.6–1.3× tax (near-zero overhead). That's proof the isolation works when done right.

**Two cross-cutting agent levers the spike flagged:**
- **Bash exploration output is a first-class context cost** — in the measured sessions the #2 intake source was resident `sed`/`grep`/`cat` script-inspection output (104 reads, 6.9 MB·turn), not spec reads. Delegate exploration to read-only subagents (the `Explore` agent) and adopt bounded/quiet Bash-output discipline so the main thread never holds raw inspection dumps.
- **Default `/build` to subagent-driven-development** (strongest isolation) over direct mode.

**Recommendation:** sequence driver extraction as `/consolidate` → `/land` (split) → `/handoff` (trivial) behind the conductor seam primitive (#629), reusing the cleanup/review exemplars verbatim. Each is independently shippable in the mixed-fleet model — unconverted stages stay resident and behave exactly as today.

### Q4 — How to incorporate automated model selection

**Make per-stage default model a first-class field of the arrangement, with a family-level floor and an optional runtime layer.** This is already the committed design (D8/D9) — it just isn't built. The structure:

- **Per-stage default model family** as data in the arrangement recipe (alongside `workflow.skill_slots` in `.arboretum.yml`, *data only, never evaluated as shell*). Express it as a **family** (cheap/capable, reusing the existing `token-rates.sh` vocabulary) rather than a concrete model id, so it survives model releases.
- **The conductor selects the model at dispatch and stamps `stage + model` into the brief, the manifest, and the token ledger** — so selection and accounting become the *same loop* (design D7). This directly closes the 42%-hidden-cost gap: once the model is chosen and stamped, subagent cost is no longer invisible.
- **The mapping** follows #174's tiers and the conductor's provisional assignment:
  - *Cheap (Haiku-class):* `/cleanup`, `/handoff`, test execution + triage, REGISTER regen, applying a known patch, codebase surveys, extract-component Tier-3 confirm (already Haiku-class in prose), roadmap NL translation (already Haiku in prose), `/pr` body generation.
  - *Middle (Sonnet):* routine implementation following an approved plan.
  - *Frontier (Opus):* `/design`-produce, planning, code review, debugging from scratch, `/land` triage judgment.

**The open question** (deferred to spike #628) is whether static per-stage floors are enough or you also need a **runtime decision layer** — the conductor escalating/downgrading at dispatch based on signals (issue size, plan length, prior escape-hatches), and whether ledger data should tune the defaults empirically. My read: **ship static family-floors first** (most of the win, low risk), instrument with the cost stamp, then let the #628 spike decide whether runtime escalation pays for its complexity using *real* stamped data rather than speculation.

**Recommendation:** the fastest credible first step is to *wire the two existing prose intentions* (extract-component Tier-3 and roadmap NL → both say "Haiku" but pass no parameter) as the proof-of-mechanism, then generalize to an arrangement `default-model` field with the conductor stamping it through. Today there is genuine *intent* and full *accounting* but zero *enforcement* — the gap is purely mechanical.

### Q5 — Is there ever a role for compaction, or do you build so you don't need it?

**Build thin so you rarely need it; treat compaction as a fallback for the irreducibly-resident stages, not a strategy.** The architecture answers this for you: the entire conductor thesis is that the *conductor never accumulates* — it holds only briefs and manifests, sheds every driver transcript, and so never climbs toward the 500k-token wall where compaction becomes necessary. If you've done the restructuring, the main session simply doesn't grow large enough to need compacting, because the growth was *moved into ephemeral drivers that are discarded*.

Compaction is lossy and non-deterministic — it summarizes context you can no longer audit, which is hostile to governance operations that need byte-exact content (the same reason `/consolidate` can't use Explore excerpts). So it's the wrong default for a governed pipeline.

Where it *does* have a residual role:
- **Genuinely interactive, irreducibly-resident stages** that can't be split — a long `/design` dialogue that must stay in one human-facing session might compact its *early elicitation* once the design doc is written, since the doc is now the durable artifact and the chat history is redundant. But note `split` mode is the better answer here: dispatch the *produce* half to a driver and the resident half stays short by construction.
- **Cross-stage handoff is already "compaction done right"** — the ledger (#665) and the manifest seam are a *deterministic, auditable* form of the same idea: instead of summarizing a transcript with a model, you carry forward exactly the seam fields the next stage needs. That's strictly better than LLM compaction and you've already built the spine of it.

**Recommendation:** don't invest in compaction as a lever. Invest the same effort in (a) extending the ledger to the post-merge stages and base-ref/diff fields, and (b) `split`-mode for the interactive stages. Those keep context thin *by construction* and *auditably*, which compaction can't. Reserve compaction strictly as a safety net for any stage that resists isolation — and treat needing it as a signal that the stage hasn't been decomposed yet.

---

## 6. Prioritized sequence

Ordered by (value × proven-ness ÷ risk). Each item is independently shippable in the mixed-fleet model.

**Tier 1 — finish what's started, low risk, measured payoff:**
1. **Extend the pipeline-context ledger (#665)** to the post-merge stages and to the base-ref + diff fields. The re-read tax is the most duplicated cost and the mechanism already exists and is self-healing.
2. **Enforce bounded reads as the default.** Document-access is shipped and used by nine skills *as advice* ("fall back to whole-file"). Flip the default: bounded read first, whole-file only with a stated reason. Cheapest big-doc saver available.
3. **Wire the two existing Haiku intentions** (extract-component Tier-3, roadmap NL) as real model parameters — proof-of-mechanism for model selection with zero design risk.

**Tier 2 — convert the inline hotspots (reuse the cleanup/review exemplars):**
4. **`/handoff` → tiny delegated/Haiku call** (8.4× tax, trivial build).
5. **`/consolidate` → dispatched driver** (heaviest build-path skill, runs up to 2×/cycle).
6. **`/land` → split mode** (resident triage + dispatched ingestion/fix).

**Tier 3 — systematize, behind the conductor primitive (#629):**
7. **Land the conductor seam (#629)** so the brief envelope + manifest schema are governed contracts, and absorb the #720 prose dispatch idiom into it (#724).
8. **Arrangement `default-model` field** with conductor stamping `stage + model` into brief/manifest/ledger (closes the 42% hidden-cost gap).
9. **Run spike #628** with real stamped data to decide static-floor-only vs. runtime escalation.
10. **Ship #682** (decision-row / area-level retrieval) for the large decision tables — the highest-leverage unbuilt retrieval piece.

---

## 7. Risks and open questions

- **Driver attribution accuracy.** The journey view captured a usable report in only ~1 of ~10 sessions, with a fragile `parentUuid` join and transcript-inferred (not authoritative) stage labels. The push-based live ledger (#719, design-only) addresses this. Until cost is reliably stamped per driver, model-selection tuning is flying partially blind — which is the argument for the conductor stamping cost *at dispatch* rather than reconstructing it after.
- **Enforcement vs. capability.** Both document-access and model intent exist but are *advised*, not *enforced*. The live gap is discipline. A bounded-read default and a wired model parameter are the enforcement.
- **The conductor is design-only.** Don't let the elegance of the arrangement abstraction stall the independently-shippable Tier-1/Tier-2 wins. The two shipped exemplars (cleanup, review) prove the seam without the conductor; lean on them.
- **Mixed-fleet correctness.** As stages convert, the resident↔dispatched boundary must preserve human-review stops (a driver can't ask mid-run) and terminal-action carve-outs (a driver can't remove its own worktree). Both patterns are already established — reuse them verbatim rather than re-deriving.
- **Plugin replaceability is governed, not free.** Slotting a third-party plugin as a lane backend requires defining its brief inputs and manifest schema. The seam makes it *possible*; the owning spec makes it *reviewable*. Keep that gate.

---

## Appendix — key evidence map

| Claim | Source |
|---|---|
| Context = 68% of cost; per-stage table; tax ratio | `spikes/2026-06-08-pipeline-context-flow/FINDINGS.md` (#662) |
| Subagent inheritance = 42% hidden cost; $27.70/409 turns | conductor design §Context; #627 body |
| Conductor/driver model, arrangement, 3 dispatch modes | `docs/superpowers/specs/2026-06-07-pipeline-conductor-design.md` (`feat/pipeline-conductor`) |
| Brief/manifest seam; inject-narrowly; seam-specific briefs | same design §The Driver Seam; `scripts/write-agent-brief.sh` |
| B4 review lanes shipped; replaceable backends; manifest schema | `docs/specs/review-stage.spec.md`; `scripts/validate-review-manifest.sh`; `skills/ai-surface-review/SKILL.md` |
| Cleanup driver; terminal-action carve-out | `skills/cleanup/SKILL.md` (#644, PR #653) |
| Generic-subagent dispatch invariant | `docs/specs/skill-and-agent-authoring.spec.md` (#720) |
| Selective retrieval shipped; ~85% reduction; 28% dead rows | `docs/specs/document-access.spec.md`; `docs/templates/document-shapes.yaml`; #680/#682/#667 |
| Pipeline-context ledger; SHA-keyed; slice-1 scope | `docs/superpowers/specs/2026-06-08-pipeline-context-ledger-design.md` (#665, merged) |
| Model-routing intent (Haiku tiers); zero wired params | #174; #628; `skills/extract-component/references/detection.md`; `skills/roadmap/SKILL.md` |
| Cost accounting substrate (rate table, journey) | `docs/specs/token-accounting.spec.md`; `scripts/lib/token-rates.sh`; `scripts/token-report.sh` |
