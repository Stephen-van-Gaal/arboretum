<!-- owner: extract-shared-component -->

# Extraction rule (extract phase)

Generic refactoring assumes one runtime. In a bash + inline-python corpus a single
logical helper can have consumers in two runtimes: bash consumers can
`source scripts/lib/<helper>.sh`; the `python3` heredocs embedded in `.sh` scripts
cannot source a bash lib. So "extract one helper" is two parallel decisions. The
rule is keyed on **what is shared.**

## The rule

1. **Shared atom is a constant / value** → **canonical bash var + env bridge.**
   Define once in `scripts/lib/<name>.sh` as a single-quoted literal (literal
   backslashes), `export` it. Bash consumers `source` it and use `$VAR`; python
   heredocs read it via `os.environ["VAR"]` (bash exports it before the heredoc).
   Proven byte-identical to an inline literal; no new architecture. *Gotcha:* the
   bash-side *display/use* of the var is `echo`-sensitive (zsh `echo` interprets
   `\x`) and a bash `grep`/`sed` consumer needs a `\x`-aware engine (GNU `grep -P`);
   env transmission to python is clean regardless.
2. **Shared atom is substantial logic** (not a one-liner) → **python module** for
   that helper; accept the `PYTHONPATH` plumbing. Escalate from (1) to (2) only
   when (1)'s residual boilerplate is itself the duplication worth removing. The
   (1)-vs-(2) threshold is a judgment, not a bright line.
3. **Never bare dual-source as a default** → always pair any retained duplication
   with an **enforcement contract test** (e.g. grep the tree, assert no site
   re-inlines the shared atom). This turns "matches the canonical pattern" prose
   into enforcement — closing the hollow contract.
4. **Codegen** only when a value must exist pre-computed in a committed artifact
   consumed without a runtime. Overkill otherwise.

`scripts/lib/` is the established home for single-owner shared helpers
(`yaml-lite.sh`, `token-ledger.sh`, `upgrade-classify.sh`).

## The mechanics (after the home + shape are chosen)

Apply in order — each is a small, reviewable step:

1. **Seam** (Feathers) — name the requires/provides contract the shared helper
   exposes.
2. **Characterization tests** (Feathers) — pin *current* behaviour before any
   extraction. They pass against the pre-extraction code and must stay green
   throughout.
3. **Structural extraction commit** (Beck, *Tidy First?*) — introduce the helper
   with **no behaviour change**; tests green. Keep this commit free of behaviour
   change (structural ≠ behavioural).
4. **Parallel Change** (Fowler) — migrate call sites incrementally behind the
   stable interface, tests green throughout. "One-at-a-time vs all-at-once" is a
   false binary: the *interface* lands all-at-once, *call-site migration* is
   incremental.
5. **Enforcement test** — add the contract test from rule 3.
6. **Ownership** — add an `# owner:` header to each new file; flag if no existing
   spec fits (a governance decision to surface, not to guess).

## Governance routing

- Behaviour-preserving extraction (characterization tests pass byte-identically)
  = **spec-exempt refactor** under arboretum's "implementation-detail refactoring"
  exemption. No fresh design cycle.
- A `needs-decision` catalog candidate (divergent implementations, no single
  canonical behaviour) = **stop and route to `/design`.** Choosing semantics is
  governed work. Surface *why* (the divergence) and route out.
