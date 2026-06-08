#!/usr/bin/env bash
# owner: shared-components
# scrub-control-chars.sh - Single source of the control-char scrub primitive.
#
# Strips ASCII/C1 control characters from author-controlled content (branch
# names, issue titles, PR metadata, paths) before it enters Claude's context,
# blocking ANSI/terminal-escape injection (CLAUDE.md § Defense in depth).
#
# Sourced, never executed. Two runtimes share one canonical byte set:
#   - bash consumers source this file and pipe through the functions below.
#   - python heredocs embedded in .sh scripts read ARBO_CTRL_CHAR_CLASS via
#     os.environ and compile it (the env bridge — extraction-rule.md rule 1).
#
# Canonical byte set: 0x00-0x08, 0x0b, 0x0c, 0x0e-0x1f, 0x7f-0x9f
# (preserves \t \n \r). The `_oneline` variant additionally removes \t \n \r
# for single-line display (e.g. the boot banner).
#
# The bash `tr` octal sets and the python `\x` regex class are two
# representations of the same byte set; their equivalence is enforced (not
# trusted) by _smoke-test-contract-scrub-control-chars.sh (SCC-1).

# Canonical class in python-regex form — the single source of truth, env-bridged
# to python consumers. Single-quoted: literal backslashes.
export ARBO_CTRL_CHAR_CLASS='[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]'

# Security scrub: strip control chars, preserve \t \n \r. Reads stdin, writes
# stdout. Usage: printf '%s' "$x" | scrub_control_chars
scrub_control_chars() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177-\237'
}

# Display scrub: the canonical class PLUS \t \n \r, for single-line output.
# Usage: printf '%s' "$x" | scrub_control_chars_oneline
scrub_control_chars_oneline() {
  LC_ALL=C tr -d '\000-\037\177-\237'
}
