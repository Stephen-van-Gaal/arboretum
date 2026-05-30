---
seam: write-escape-hatch
version: 1.0
producer-type: script
consumer-type: skill
consumes:
  - module-contract-template-file
produces: []
related-designs:
  - docs/superpowers/specs/2026-05-26-pipeline-overhaul-ws5-governance-script-contracts-design.md
owns:
  - scripts/write-escape-hatch.sh
---
<!-- owner: pipeline-contracts-template -->

# write-escape-hatch — `write-escape-hatch.sh` Escape-Hatch Producer Contract

The seam between `scripts/write-escape-hatch.sh` (which records a build-stage escape-hatch exit by appending an `escape-hatch:` block to a design spec's frontmatter) and its downstream consumers — `/build` (which writes it on a design-decision escape) and `/finish` (which reads the recorded escape via spec frontmatter). This contract pins the appended block's schema and the in-place idempotent-replace behaviour so a second escape never appends a duplicate block and the written YAML stays frontmatter-valid.

## Producer

`scripts/write-escape-hatch.sh` — producer-type: `script`.

Takes a design-spec path, a `<trigger-name>`, and a `<redirect-target>`, and appends an `escape-hatch:` block to the spec's **frontmatter** (the leading `---` … `---` block), immediately before the closing `---`. The block is a YAML mapping with two indented sub-keys:

```yaml
escape-hatch:
  trigger: <trigger-name>
  redirect-target: <redirect-target>
```

It is **idempotent**: a second invocation strips any existing `escape-hatch:` block (the `escape-hatch:` line plus its indented sub-lines, via a regex `re.sub`) before appending the new one — it replaces in place rather than appending a duplicate. The spec body and everything after the frontmatter are preserved verbatim. It exits 1 (usage/not-found) on bad args or a missing file, and exits 2 if the file has no frontmatter block.

## Consumer

Consumers, consumer-type: `skill`:

- **`skills/build/SKILL.md`** (skill, writer-side, ~line 151). `/build` invokes the script on a design-decision escape — when an agent-target task surfaces a real design decision — to record the escape on the design spec before exiting.
- **`skills/finish/SKILL.md`** (skill, reader-side). `/finish` reads the recorded escape via the design spec's frontmatter to learn that the build escaped and where it redirected.

**Consumer obligations:**

- The consumer MUST read `escape-hatch.trigger` and `escape-hatch.redirect-target` as nested frontmatter sub-keys (the same minimalist `key:` + indented-`sub-key:` shape `read-s2-frontmatter.sh` parses).
- The consumer MUST tolerate the absence of an `escape-hatch:` block (no escape recorded) — a spec without one is the normal case.
- The consumer MUST treat a re-written block (idempotent replace) as the single source of truth — there is never more than one `escape-hatch:` block.

## Protocol shape

### Inputs

`scripts/write-escape-hatch.sh` accepts exactly three positional arguments:

- **`<design-spec>`** — path to the design spec. Must exist and must start with a `---` frontmatter block.
- **`<trigger-name>`** — the escape trigger, written as `escape-hatch.trigger`.
- **`<redirect-target>`** — where the escape redirects, written as `escape-hatch.redirect-target`.

No stdin.

### Outputs

Rewrites `<design-spec>` in place. The frontmatter gains (or has replaced) an `escape-hatch:` block immediately before its closing `---`:

```yaml
escape-hatch:
  trigger: <trigger-name>
  redirect-target: <redirect-target>
```

Exit codes: `0` — block written/replaced; `1` — wrong arg count or spec not found; `2` — file has no frontmatter block.

### Invariants

- **Block schema.** The appended block is exactly an `escape-hatch:` key with two two-space-indented sub-keys, `trigger:` and `redirect-target:`, in that order. The sub-key indentation (2 spaces) matches what the frontmatter readers parse.
- **Frontmatter placement.** The block is written inside the leading `---` … `---` frontmatter, immediately before the closing `---` — never into the spec body.
- **Idempotent replace.** A second invocation replaces the existing `escape-hatch:` block in place. After any number of invocations the frontmatter contains exactly one `escape-hatch:` block, reflecting the most recent `trigger` / `redirect-target`.
- **Body preservation.** The opening `---`, the pre-existing frontmatter keys, the closing `---`, and the entire spec body after the frontmatter are preserved verbatim; only the `escape-hatch:` block is added/replaced.
- **Frontmatter-valid output.** The rewritten file still starts with a `---` block terminated by `---`, so downstream frontmatter parsers (e.g. `read-s2-frontmatter.sh`'s `^---\n(.*?\n)---\n` match) still find a frontmatter block.
- **No-frontmatter rejection.** A spec without a leading `---` frontmatter block exits 2 and is not modified.
- **Arg/existence guards.** Wrong arg count or a non-existent spec exits 1 and modifies nothing.

## Test surface

- **WEH-1:** Append — running against a spec with a minimal frontmatter writes an `escape-hatch:` block (with `trigger:` + `redirect-target:` sub-keys) inside the frontmatter, before the closing `---`; the file still starts with `---` and the body is preserved.
- **WEH-2:** Sub-key values — `escape-hatch.trigger` and `escape-hatch.redirect-target` carry the exact `<trigger-name>` / `<redirect-target>` arguments at 2-space indent.
- **WEH-3:** Idempotent replace — a second invocation with different values leaves exactly ONE `escape-hatch:` block carrying the second call's values (no duplicate block).
- **WEH-4:** Parseable — the rewritten frontmatter is still a valid `---`-delimited block; a minimalist frontmatter parser (the `^---\n…---\n` shape) finds the frontmatter and reads `escape-hatch.trigger` / `escape-hatch.redirect-target`.
- **WEH-5:** No-frontmatter — a file with no leading `---` block exits 2 and is left unmodified.
- **WEH-6:** Arg guards — wrong arg count exits 1; a non-existent spec path exits 1; neither modifies any file.

## Versioning

- **1.0** (2026-05-30) — initial contract. Producer shape as of `scripts/write-escape-hatch.sh` and consumers `skills/build/SKILL.md` + `skills/finish/SKILL.md` on `main`. Issue #303 (WS5 PR 7a).
