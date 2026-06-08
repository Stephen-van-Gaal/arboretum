#!/usr/bin/env bash
set -euo pipefail
greeting() { echo "hi from b"; }
scrub() { python3 -c "import re,sys; print(re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]','',sys.argv[1]))" "$1"; }
write_cache() {
  local tmp
  tmp=$(mktemp "$CACHE_DIR/x.json.XXXXXX")
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$CACHE_FILE"
}
echo b
