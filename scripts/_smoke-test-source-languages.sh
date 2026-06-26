#!/usr/bin/env bash
# owner: project-infrastructure
# scope: plugin-only
# ci-parallel: serial
# _smoke-test-source-languages.sh — Unit-tier tests for language-aware
# Check 3 ownership: source_languages enforcement (#859), owns:-only Half B
# (#865), in-file marker DETECTION via ownership-aware Half C discovery (#865),
# and Half C undeclared-source-type discovery (#859, ownership-aware #865).
# Picked up automatically by ci-checks.sh's === Smoke tests === loop.
#
# Capture-then-grep is used throughout (never `if cmd | grep`): health-check
# exits 2 on advisory findings, which `set -o pipefail` would propagate as the
# pipeline status and mask the grep result (a false-pass class fixed under #865).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HC="$ROOT/scripts/health-check.sh"
FAILED=0
pass() { echo "  PASS: $1"; }
fail_case() { echo "  FAIL: $1"; FAILED=1; }

# Minimal Check-1-complete fixture rooted at a fresh mktemp dir. Echoes the dir.
make_fixture() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/docs/specs" "$d/docs/definitions" "$d/src" "$d/workflows"
  touch "$d/CLAUDE.md" "$d/contracts.yaml" "$d/docs/ARCHITECTURE.md" "$d/workflows/README.md"
  (cd "$d" && git init -q && git config user.email t@t && git config user.name t)
  printf '%s\n' "# Project Register" "" "## Spec Index" "" \
    "| Spec | Status | Owner | Owns (files/directories) |" \
    "|------|--------|-------|--------------------------|" > "$d/docs/REGISTER.md"
  printf '%s\n' "$d"
}

# Append a spec + REGISTER row owning a file/dir pattern.
add_spec_owning() {  # <dir> <spec-name> <owns-pattern>
  local d="$1" name="$2" owns="$3"
  cat > "$d/docs/specs/$name.spec.md" <<INNER
---
name: $name
status: active
owner: architecture
owns:
  - $owns
---

# $name
INNER
  echo "| $name.spec.md | active | architecture | $owns |" >> "$d/docs/REGISTER.md"
}

# --- backward-compat default + opt-in enforcement (#859) ---

test_default_does_not_scan_ts() {
  local d; d="$(make_fixture)"
  add_spec_owning "$d" alpha "src/alpha.py"
  echo "# owner: alpha" > "$d/src/alpha.py"
  echo "// not owned by anything" > "$d/src/stray.ts"   # unowned .ts
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "Unowned:.*stray.ts"; then
    fail_case "default config flagged stray.ts (should scan only .py)"
  else
    pass "default source_languages=[py] does not scan .ts"
  fi
  rm -rf "$d"
}

test_optin_flags_unowned_ts() {
  local d; d="$(make_fixture)"
  printf 'source_languages:\n  - py\n  - ts\n' > "$d/.arboretum.yml"
  add_spec_owning "$d" alpha "src/alpha.py"
  echo "# owner: alpha" > "$d/src/alpha.py"
  echo "// not owned by anything" > "$d/src/stray.ts"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "Unowned:.*stray.ts"; then
    pass "source_languages:[py,ts] flags unowned .ts"
  else
    fail_case "opt-in did not flag unowned stray.ts"
  fi
  rm -rf "$d"
}

# --- Half B is owns:-only for all languages (#865) ---

test_marker_only_unowned_in_halfb() {
  local d; d="$(make_fixture)"
  printf 'source_languages:\n  - py\n  - sql\n' > "$d/.arboretum.yml"
  add_spec_owning "$d" qsql "src/q.sql"
  echo "-- owner: qsql" > "$d/src/q.sql"     # owns-governed (keeps Check 2 happy)
  # NOT under any owns: pattern, carrying only a resolvable in-file marker:
  cat > "$d/src/loose.sql" <<'INNER'
-- owner: qsql
SELECT 1;
INNER
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  # #865: an in-file marker is NOT a Half B ownership source — loose.sql is Unowned.
  if echo "$out" | grep -q "Unowned:.*loose.sql"; then
    pass "marker-only file is Unowned in Half B (owns:-only, #865)"
  else
    fail_case "marker-only loose.sql not flagged — Half B must be owns:-only (#865)"
  fi
  # The owns-governed q.sql is NOT flagged.
  if echo "$out" | grep -q "Unowned:.*src/q.sql"; then
    fail_case "owns-governed q.sql flagged Unowned"
  else
    pass "owns-glob ownership still honoured under owns:-only Half B"
  fi
  rm -rf "$d"
}

test_bad_marker_still_unowned() {
  local d; d="$(make_fixture)"
  printf 'source_languages:\n  - py\n  - sql\n' > "$d/.arboretum.yml"
  cat > "$d/src/orphan.sql" <<'INNER'
-- owner: nonexistent-spec
SELECT 3;
INNER
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "Unowned:.*orphan.sql"; then
    pass "marker to nonexistent spec is still unowned"
  else
    fail_case "orphan.sql with unresolvable owner was not flagged"
  fi
  rm -rf "$d"
}

# --- in-file marker DETECTION via ownership-aware Half C discovery (#865) ---
# Marker detection (leading_block_owner_marker) is no longer a Half B signal,
# but it IS how ownership-aware discovery decides a file is governed. Each case
# below places a tricky-marker file under an UNDECLARED language (discovery
# territory); the spec exists, so a correctly-detected marker means the file is
# governed and must NOT trip the Half C nudge. A detection miss → the file is
# counted → a nudge fires → the assertion fails.

test_banner_marker_detected_in_discovery() {
  local d; d="$(make_fixture)"   # default [py]; sql undeclared → discovery
  add_spec_owning "$d" qsql "src/q.sql"
  echo "-- owner: qsql" > "$d/src/q.sql"
  # owner: line follows a DO-NOT-EDIT banner — leading-block scan must find it.
  cat > "$d/src/gen.sql" <<'INNER'
-- DO NOT EDIT — generated by build.py
-- owner: qsql
-- generated-at: abc123
SELECT 2;
INNER
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "sql.*not declared"; then
    fail_case "generated banner owner line not detected (gen.sql nudged, #865)"
  else
    pass "generated banner owner line detected in leading block (#865)"
  fi
  rm -rf "$d"
}

test_crlf_marker_detected_in_discovery() {
  local d; d="$(make_fixture)"
  add_spec_owning "$d" qsql "src/q.sql"
  echo "-- owner: qsql" > "$d/src/q.sql"
  # CRLF line endings (Windows-authored): the marker must still resolve (#859 B4).
  printf -- '-- owner: qsql\r\nSELECT 1;\r\n' > "$d/src/crlf.sql"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "sql.*not declared"; then
    fail_case "CRLF-terminated owner marker not detected (\\r not stripped, #865)"
  else
    pass "CRLF-terminated owner marker resolves in discovery (\\r stripped, #865)"
  fi
  rm -rf "$d"
}

test_php_opener_marker_detected_in_discovery() {
  local d; d="$(make_fixture)"   # php undeclared → discovery
  add_spec_owning "$d" papp "src/p.php"
  printf '<?php\n// owner: papp\necho 0;\n' > "$d/src/p.php"
  # PHP files open with <?php before the // owner: line (#859 B4 / Copilot).
  printf '<?php\n// owner: papp\necho 1;\n' > "$d/src/loose.php"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "php.*not declared"; then
    fail_case "// owner: after <?php opener not detected (loose.php nudged, #865)"
  else
    pass "PHP <?php opener skipped; // owner: marker detected (#865)"
  fi
  rm -rf "$d"
}

test_php_cli_shebang_opener_marker_detected_in_discovery() {
  local d; d="$(make_fixture)"
  add_spec_owning "$d" papp "src/p.php"
  printf '<?php\n// owner: papp\necho 0;\n' > "$d/src/p.php"
  # PHP CLI: shebang line 1, <?php opener line 2, // owner: line 3 (#859 B4 / Codex).
  printf '#!/usr/bin/env php\n<?php\n// owner: papp\necho 1;\n' > "$d/src/cli.php"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "php.*not declared"; then
    fail_case "PHP opener after shebang not skipped; // owner: missed (cli.php nudged, #865)"
  else
    pass "PHP shebang+<?php opener skipped; // owner: detected (#865)"
  fi
  rm -rf "$d"
}

# --- no-prefix enforced language is clean under owns:-only (#865) ---
# The #859 "no comment prefix" diagnostic was removed in #865: with Half B
# owns:-only, marker detection never runs in Half B for any language, so a
# no-prefix enforced language is governed by owns: coverage with no diagnostic.

test_no_prefix_language_clean() {
  local d; d="$(make_fixture)"
  printf 'source_languages:\n  - py\n  - xyz\n' > "$d/.arboretum.yml"
  add_spec_owning "$d" xspec "src/thing.xyz"
  echo "data" > "$d/src/thing.xyz"     # owned via owns: glob (no marker needed)
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -qi "no comment prefix"; then
    fail_case "stale unknown-prefix diagnostic still emitted (#865 removed it)"
  else
    pass "no stale prefix diagnostic for a no-prefix enforced language (#865)"
  fi
  if echo "$out" | grep -q "Unowned:.*thing.xyz"; then
    fail_case "owns-governed .xyz flagged Unowned"
  else
    pass "no-prefix language governed by owns: works cleanly (#865)"
  fi
  rm -rf "$d"
}

# --- Half C undeclared-source-type discovery (advisory, ownership-aware) ---

test_halfc_warns_undeclared_sql() {
  local d; d="$(make_fixture)"   # no .arboretum.yml → default [py]
  echo "SELECT 1;" > "$d/src/a.sql"
  echo "SELECT 2;" > "$d/src/b.sql"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  local n; n="$(echo "$out" | grep -c "not declared in source_languages")"
  if echo "$out" | grep -q "sql.*not declared in source_languages" && [ "$n" -eq 1 ]; then
    pass "Half C warns once for undeclared .sql with a count"
  else
    fail_case "Half C did not emit exactly one undeclared-.sql nudge (got $n)"
  fi
  rm -rf "$d"
}

test_halfc_silenced_by_ignore() {
  local d; d="$(make_fixture)"
  printf 'source_languages_ignore:\n  - sql\n' > "$d/.arboretum.yml"
  echo "SELECT 1;" > "$d/src/a.sql"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "sql.*not declared"; then
    fail_case "ignore-list did not silence Half C"
  else
    pass "source_languages_ignore silences Half C"
  fi
  rm -rf "$d"
}

test_halfc_discovers_ungoverned_sh() {
  local d; d="$(make_fixture)"   # default [py]; sh undeclared → discovery
  add_spec_owning "$d" alpha "src/alpha.py"
  echo "# owner: alpha" > "$d/src/alpha.py"
  printf '#!/usr/bin/env bash\necho hi\n' > "$d/src/helper.sh"   # ungoverned sh
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  # #865: sh is now discoverable (Half A only walks framework dirs, not src/).
  if echo "$out" | grep -q "sh.*not declared in source_languages"; then
    pass "Half C discovers ungoverned .sh under a source root (#865)"
  else
    fail_case "Half C did not nudge an ungoverned .sh (sh must be discoverable, #865)"
  fi
  rm -rf "$d"
}

test_directory_owns_covers_contents() {
  local d; d="$(make_fixture)"   # default [py]; sh undeclared → discovery
  # A spec that owns a DIRECTORY (trailing slash) covers files under it (#865 P2-1).
  add_spec_owning "$d" fixtures "tests/fixtures/"
  mkdir -p "$d/tests/fixtures"
  printf '#!/usr/bin/env bash\necho fixture\n' > "$d/tests/fixtures/sample.sh"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "sh.*not declared"; then
    fail_case "directory owns: entry did not cover its contents (sample.sh nudged, #865 P2-1)"
  else
    pass "directory owns: entry covers its contents in discovery (#865 P2-1)"
  fi
  rm -rf "$d"
}

test_midpattern_glob_owns_covers_contents() {
  local d; d="$(make_fixture)"   # default [py]; sh undeclared → discovery
  # A mid-pattern `**` glob (`tests/**/*.sh`) must cover matching files (#865 codex P2).
  add_spec_owning "$d" shtests "tests/**/*.sh"
  mkdir -p "$d/tests/contracts"
  printf '#!/usr/bin/env bash\necho t\n' > "$d/tests/contracts/owned.sh"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "sh.*not declared"; then
    fail_case "mid-pattern ** glob did not cover its contents (owned.sh nudged, #865 codex P2)"
  else
    pass "mid-pattern ** glob covers its contents in discovery (#865 codex P2)"
  fi
  rm -rf "$d"
}

test_halfc_silent_for_governed_sh() {
  local d; d="$(make_fixture)"
  add_spec_owning "$d" alpha "src/alpha.py"
  echo "# owner: alpha" > "$d/src/alpha.py"
  # marker-governed sh → ownership-aware discovery stays silent.
  printf '#!/usr/bin/env bash\n# owner: alpha\necho hi\n' > "$d/src/helper.sh"
  (cd "$d" && git add -A && git commit -qm init)
  local out; out="$(bash "$HC" "$d" 2>&1)"
  if echo "$out" | grep -q "sh.*not declared"; then
    fail_case "Half C nudged a marker-governed .sh (must be ownership-aware, #865)"
  else
    pass "Half C silent for a marker-governed .sh (ownership-aware, #865)"
  fi
  rm -rf "$d"
}

test_default_does_not_scan_ts
test_optin_flags_unowned_ts
test_marker_only_unowned_in_halfb
test_bad_marker_still_unowned
test_banner_marker_detected_in_discovery
test_crlf_marker_detected_in_discovery
test_php_opener_marker_detected_in_discovery
test_php_cli_shebang_opener_marker_detected_in_discovery
test_no_prefix_language_clean
test_halfc_warns_undeclared_sql
test_halfc_silenced_by_ignore
test_halfc_discovers_ungoverned_sh
test_directory_owns_covers_contents
test_midpattern_glob_owns_covers_contents
test_halfc_silent_for_governed_sh

[ "$FAILED" -eq 0 ] && echo "ALL PASS" || exit 1
