#!/usr/bin/env bash
# owner: token-accounting
# scope: plugin-only
# Per-1M-token USD rates. As of 2026-06-06 (claude-api Appendix). Re-verify on change.
token_rate() { # token_rate <model> <input|output|cache_write|cache_read>
  case "$1:$2" in
    *opus*:input) echo 5.00;; *opus*:output) echo 25.00;;
    *opus*:cache_write) echo 6.25;; *opus*:cache_read) echo 0.50;;
    *sonnet*:input) echo 3.00;; *sonnet*:output) echo 15.00;;
    *sonnet*:cache_write) echo 3.75;; *sonnet*:cache_read) echo 0.30;;
    *haiku*:input) echo 1.00;; *haiku*:output) echo 5.00;;
    *haiku*:cache_write) echo 1.25;; *haiku*:cache_read) echo 0.10;;
    *) echo 0;;
  esac
}
