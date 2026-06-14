---
seam: scrub-control-chars
version: 1.1
producer-type: script
consumer-type: script
consumes: []
produces:
  - scrubbed-string
  - canonical-control-char-class
related-designs:
  - docs/superpowers/specs/2026-06-08-scrub-control-chars-extraction-design.md
owns:
  - scripts/lib/scrub-control-chars.sh
---
<!-- owner: pipeline-contracts-template -->

# scrub-control-chars — Control-Character Scrub Primitive Contract

`scripts/lib/scrub-control-chars.sh` is the single source of the control-char
scrub used across the framework to keep author-controlled content (branch names,
issue titles, PR metadata, paths) from carrying ANSI/terminal-escape bytes into
Claude's context. It is **sourced, never executed**, by both bash consumers and
the `.sh` scripts whose embedded `python3` heredocs need the same control set. It
replaces the previously copy-pasted regex (`[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]`)
and its `tr` variants — the documented-but-unenforced "canonical pattern."

## Codepoint model (#799)

The scrub is **codepoint-aware, not byte-wise**. It strips the C0/C1 control
*codepoints* while preserving every other valid UTF-8 codepoint, so non-ASCII
author content (em dash U+2014, en/en-dashes, smart quotes, accented letters,
emoji) round-trips intact.

The original implementation stripped the canonical class **byte-wise** with
`LC_ALL=C tr -d`, including the raw `0x7f-0x9f` byte range. Because `0x80-0x9f`
is also the UTF-8 *continuation-byte* range, that deleted bytes mid-codepoint and
corrupted any multibyte text (e.g. `do — thing`, em dash `e2 80 94`, lost its
`80` and `94` → mojibake).

**Why not `tr`/`sed`.** The security model requires stripping a C1 control BOTH
when it appears as the valid 2-byte UTF-8 sequence (`c2 8x/9x`) AND as a raw
orphan byte `0x80-0x9f` — an 8-bit/Latin-1 terminal treats a bare `0x9b` as CSI
(this is the workspace-context WSC-10 case). But a `0x80-0x9f` byte must be
**preserved** when it is a legitimate continuation byte of a multibyte codepoint
(em dash, NBSP `c2 a0`, emoji). Telling an orphan C1 byte apart from a
continuation byte is context-sensitive across the whole sequence — 3- and 4-byte
codepoints have continuation bytes whose immediate predecessor is itself a
continuation byte — which a `tr`/`sed` byte pipeline cannot track. Real UTF-8
parsing is required.

**Implementation (primary path, python3 present).** Both bash functions run a
single `python3` pass that:

1. decodes stdin as UTF-8 with `errors="surrogateescape"` (invalid bytes survive
   as lone surrogates `U+DC00 + byte`, so nothing is lost or crashes),
2. strips the canonical control-codepoint class `ARBO_CTRL_CHAR_CLASS` (removes
   valid C0/C1/`U+007F` codepoints, e.g. `c2 9b` → gone),
3. strips its surrogate twin `ARBO_CTRL_CHAR_CLASS_SURROGATE` (removes raw orphan
   control bytes, e.g. a bare `0x9b` → gone), and
4. re-encodes with `errors="surrogateescape"` (surviving invalid bytes round-trip
   byte-identically).

Legitimate continuation bytes decode to real (non-control) codepoints, so they
are never matched by either class and survive intact.

**Fallback path (python3 absent).** `session-start.sh`'s boot-banner update block
has an explicit no-`python3` branch (it still calls `scrub_control_chars_oneline`
on plugin version strings; guarded by contract test SSB-5c). The framework's other
fallbacks are `sed`-based and the project takes no `perl` dependency, so the
scrub's fallback is `tr`-only: a byte-wise `LC_ALL=C tr -d` over the raw control
ranges **including** `0x80-0x9f`. This still strips every dangerous control byte
(no ESC/CSI reaches the banner — the security floor) but does **not** preserve
multibyte UTF-8 — the #799 corruption persists only in this rare degraded mode.
Acceptable because the sole no-`python3` caller scrubs short ASCII version
strings, and any environment that routes real UTF-8 author content through the
bash functions (the codex review adapter, git-metadata scrubs) has `python3`.
SCC-1c covers the fallback's security floor by masking `python3` off `PATH`.

Python env-bridge consumers (the `.sh` heredocs that read `ARBO_CTRL_CHAR_CLASS`)
operate on already-UTF-8-decoded `str` (via `json.load` /
`open(encoding="utf-8")` / `os.environ`), so the regex class matches codepoints
directly and was already correct — the regression was bash-only.

### Performance rationale

No per-prompt hot path uses the bash functions. The boot banner
(`session-start.sh`, once per session) and the statusline (`statusline.sh`) scrub
via their own `python3` env-bridge heredocs, which are unchanged. The
bash-function callers are infrequent git-metadata scrubs — branch/remote names in
`workspace-context.sh` (used by health-check / collision-check / workspace-list),
the codex review adapter, the token ledger, and the pre-commit hook (once per
commit). One `python3` process per call is acceptable there, and is the only
correct option given the UTF-8-parsing requirement above.

### Invalid-/non-UTF-8 input policy

Author-controlled content may carry arbitrary, non-UTF-8 bytes (e.g. a malformed
branch name). The policy is **strip-controls, passthrough-other-bytes**: control
bytes/codepoints (C0, `U+007F`, C1) are stripped whether they arrive as valid
codepoints or as raw orphan bytes; every non-control byte (including invalid
bytes like a lone `0xff`) passes through unchanged via surrogate-escape
round-tripping; the scrub never crashes. This preserves the security intent (no
escape/ANSI/CSI vector — valid or raw — reaches Claude's context) without
attempting lossy UTF-8 repair of unrelated bytes.

## Producer

`scripts/lib/scrub-control-chars.sh` — producer-type: `script`.

A sourceable library that:

- `export`s the canonical class `ARBO_CTRL_CHAR_CLASS` =
  `[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]` (single-quoted literal; the python-regex
  form; the single source of truth for the control **codepoint** set). It matches
  codepoints in UTF-8-decoded `str` on the python side.
- `export`s `ARBO_CTRL_CHAR_CLASS_SURROGATE` =
  `[\udc00-\udc08\udc0b\udc0c\udc0e-\udc1f\udc7f-\udc9f]` — the surrogate-escape
  twin of the canonical class (same offsets `+0xDC00`). It matches raw orphan
  control bytes that a `surrogateescape` decode mapped to lone surrogates. It is
  **derived from** the canonical class, not an independent source of truth.
- defines `scrub_control_chars` — codepoint-aware strip, preserves `\t \n \r`.
  Primary: a single `python3` pass (`decode("utf-8","surrogateescape")` →
  `re.sub` the canonical class → `re.sub` the surrogate twin →
  `encode("utf-8","surrogateescape")`). Fallback when `python3` is absent:
  byte-wise `LC_ALL=C tr -d '\000-\010\013\014\016-\037\177-\237'` (degraded —
  see *Codepoint model* below).
- defines `scrub_control_chars_oneline` — same primary pass, then additionally
  removes `\t \n \r`; fallback `LC_ALL=C tr -d '\000-\037\177-\237'`.

SCC-3 forbids re-inlining the canonical `\x` class anywhere but the helper and
this contract's test; the surrogate twin uses `\udc…` escapes (not `\x…`) and is
single-sourced in the helper. The canonical class remains authoritative and the
bash↔python equivalence is enforced by SCC-1.

## Consumer

Bash consumers `source` the lib and call the functions. Python consumers (the
`python3` heredocs embedded in `.sh` scripts) read the env-bridged constant:
`re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])`. No consumer re-inlines the byte
set; the producer is the sole source.

## Protocol shape

### Inputs

`scrub_control_chars` / `scrub_control_chars_oneline` read from **stdin** and
write the scrubbed string to stdout (no positional arguments); callers pipe in,
e.g. `printf '%s' "$x" | scrub_control_chars`. Python consumers
read `ARBO_CTRL_CHAR_CLASS` from the environment (the sourcing `.sh` exports it
before the heredoc).

### Outputs

The input string with the control **codepoints** removed and all other valid
UTF-8 preserved. For valid UTF-8 the bash `scrub_control_chars` (python
surrogate-escape pass) and a python `re.sub(ARBO_CTRL_CHAR_CLASS, "", text)` path
(on UTF-8-decoded `str`) produce equivalent output.

### Invariants

- `scrub_control_chars` (bash) and python-with-`ARBO_CTRL_CHAR_CLASS` produce
  **equivalent** output over a UTF-8 corpus that mixes multibyte codepoints with
  the C0/C1 control codepoints (kept equivalent by an enforcement test, not by
  trust). The codepoint model replaces the prior byte-identity invariant, which
  was incompatible with UTF-8 preservation (#799).
- Valid UTF-8 multibyte content (em dash, smart quotes, NBSP, CJK, emoji)
  round-trips intact.
- `scrub_control_chars` preserves `\t \n \r`; `scrub_control_chars_oneline` also
  removes them. Neither appends a trailing newline.
- The canonical control set covers the codepoints `U+0000–U+0008, U+000B, U+000C,
  U+000E–U+001F, U+007F` (C0 + DEL) and `U+0080–U+009F` (C1).
- Invalid/non-UTF-8 input: control bytes/codepoints are stripped (valid or raw
  orphan); non-control bytes pass through unchanged via surrogate-escape; never
  crashes.
- A raw orphan C1 byte (e.g. a bare `0x9b` CSI, valid neither as UTF-8 nor as the
  `c2 9b` sequence) IS stripped — 8-bit/Latin-1-terminal defense.
- No source file outside the lib (and its tests) re-inlines the raw class or the
  `tr` control set — guarded by SCC-3.

## Test surface

- **SCC-1: bash↔python equivalence over a UTF-8 corpus (codepoint model).** Over
  a corpus mixing ASCII, `\t \n \r`, the full C0+DEL set, the full C1 set
  (`U+0080–U+009F`), and valid multibyte codepoints (em dash, en dash, smart
  quotes, NBSP, CJK, emoji), `scrub_control_chars` output equals
  `re.sub(os.environ["ARBO_CTRL_CHAR_CLASS"], "", text)` output where both sides
  encode/decode as UTF-8. Preserves the prior intent (the two runtimes must agree)
  under the codepoint model.
- **SCC-1c: codepoint preservation + control stripping.** Direct assertions:
  em-dash round-trip, smart-quote/emoji round-trip, NBSP preserved, C0 stripped,
  C1 (incl. U+009B CSI) stripped as 2-byte sequences, invalid-UTF-8 passthrough,
  no trailing newline, oneline codepoint-aware.
- **SCC-2: oneline variant.** `scrub_control_chars_oneline` removes `\t \n \r`
  in addition to the canonical set; `scrub_control_chars` preserves them.
- **SCC-3: no re-inline (enforcement).** Grep guard asserts no source file
  (excluding the lib + this test) re-inlines the raw regex class or the `tr`
  control set — the line that retires the hollow doctrine.

## Versioning

- **1.0** — initial contract: env-bridge constant + two scrub functions, extracted
  from 16 inline copies; token-ledger converged up to canonical (2026-06-08, #634).
- **1.1** — codepoint-aware scrub (#799). Bash path changed from byte-wise
  `tr -d '…\177-\237'` (which corrupted UTF-8 by deleting continuation bytes) to a
  single `python3` surrogate-escape pass that strips the canonical control
  codepoints plus their surrogate twins (raw orphan control bytes). Adds the
  derived `ARBO_CTRL_CHAR_CLASS_SURROGATE` constant. SCC-1 redesigned from latin-1
  byte-identity to UTF-8 codepoint equivalence; added SCC-1c (em-dash/smart-quote/
  emoji/NBSP round-trip, C0/C1 strip, raw-orphan-C1 strip, invalid-byte
  passthrough, no-trailing-newline). Canonical class unchanged (python consumers
  were already codepoint-correct).
