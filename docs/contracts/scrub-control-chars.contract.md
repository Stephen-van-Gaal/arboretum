---
seam: scrub-control-chars
version: 1.0
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
the `.sh` scripts whose embedded `python3` heredocs need the same byte set. It
replaces the previously copy-pasted regex (`[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]`)
and its `tr` variants — the documented-but-unenforced "canonical pattern."

## Producer

`scripts/lib/scrub-control-chars.sh` — producer-type: `script`.

A sourceable library that:

- `export`s the canonical class `ARBO_CTRL_CHAR_CLASS` =
  `[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]` (single-quoted literal; the python-regex
  form; the single source of truth for the byte set).
- defines `scrub_control_chars` — strips the canonical class via
  `LC_ALL=C tr -d '\000-\010\013\014\016-\037\177-\237'` (preserves `\t \n \r`).
- defines `scrub_control_chars_oneline` — the canonical class **plus** `\t \n \r`
  (`LC_ALL=C tr -d '\000-\037\177-\237'`), for single-line display.

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

The input string with the relevant control-character set removed. Byte-for-byte
identical between the bash `tr` path and a python `re.sub(ARBO_CTRL_CHAR_CLASS,
"", x)` path for `scrub_control_chars`.

### Invariants

- `scrub_control_chars` and python-with-`ARBO_CTRL_CHAR_CLASS` produce
  **byte-identical** output over every input (the two representations are kept
  equivalent by an enforcement test, not by trust).
- `scrub_control_chars` preserves `\t \n \r`; `scrub_control_chars_oneline` also
  removes them.
- The canonical class covers `0x00–0x08, 0x0b, 0x0c, 0x0e–0x1f, 0x7f–0x9f`.
- No source file outside the lib (and its tests) re-inlines the raw class or the
  `tr` control set — guarded by SCC-3.

## Test surface

- **SCC-1: bash↔python byte-identity.** Over a fuzz corpus spanning every byte
  `0x00–0xff` plus sample strings, `scrub_control_chars` output equals
  `re.sub(os.environ["ARBO_CTRL_CHAR_CLASS"], "", x)` output, byte-for-byte.
- **SCC-2: oneline variant.** `scrub_control_chars_oneline` removes `\t \n \r`
  in addition to the canonical class; `scrub_control_chars` preserves them.
- **SCC-3: no re-inline (enforcement).** Grep guard asserts no source file
  (excluding the lib + this test) re-inlines the raw regex class or the `tr`
  control set — the line that retires the hollow doctrine.

## Versioning

- **1.0** — initial contract: env-bridge constant + two scrub functions, extracted
  from 16 inline copies; token-ledger converged up to canonical (2026-06-08, #634).
