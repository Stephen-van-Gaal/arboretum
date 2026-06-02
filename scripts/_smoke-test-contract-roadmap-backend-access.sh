#!/usr/bin/env bash
# owner: pipeline-contracts-template
# _smoke-test-contract-roadmap-backend-access.sh — Contract test for the
# roadmap backend live-access probe. Exercises GitHub and Azure DevOps paths
# with stubbed provider CLIs only; no network and no real auth required.

set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/roadmap/lib.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
fail_case() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && { echo "--- detail ---" >&2; echo "$2" >&2; }; fail=1; }

run_probe() {
  local backend="$1"
  local root="${2:-}"
  (
    # shellcheck source=scripts/roadmap/lib.sh
    source "$LIB"
    if [ -n "$root" ]; then
      roadmap_probe_backend_access "$backend" "$root"
    else
      roadmap_probe_backend_access "$backend"
    fi
  )
}

make_gh_stub() {
  local bindir="$1"; mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")
    exit "${GH_AUTH_RC:-0}"
    ;;
  "api repos/{owner}/{repo}")
    if [ "${GH_API_RC:-0}" != 0 ]; then
      echo "${GH_API_ERR:-error connecting to api.github.com}" >&2
      exit "$GH_API_RC"
    fi
    printf 'owner/repo\n'
    exit 0
    ;;
  "api user")
    echo "gh stub: /user endpoint should not be used for repo access probe" >&2
    exit 98
    ;;
esac
echo "gh stub: unhandled args: $*" >&2
exit 99
STUB
  chmod +x "$bindir/gh"
}

make_az_stub() {
  local bindir="$1"; mkdir -p "$bindir"
  cat > "$bindir/az" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "devops -h"|"boards -h"|"repos -h")
    exit "${AZ_HELP_RC:-0}"
    ;;
  "devops configure")
    if [ "$3" = "--list" ]; then
      if [ "${AZ_CONFIG_RC:-0}" != 0 ]; then
        echo "defaults unavailable" >&2
        exit "$AZ_CONFIG_RC"
      fi
      if [ "${AZ_CONFIG_EMPTY:-0}" = 1 ]; then
        exit 0
      fi
      printf 'organization = %s\nproject = %s\n' "${AZ_ORG:-https://dev.azure.com/example}" "${AZ_PROJECT:-Example Project}"
      exit 0
    fi
    ;;
  "devops project")
    if [ "$3" = "show" ]; then
      if [ "${AZ_PROJECT_SHOW_RC:-0}" != 0 ]; then
        echo "${AZ_PROJECT_SHOW_ERR:-could not reach dev.azure.com}" >&2
        exit "$AZ_PROJECT_SHOW_RC"
      fi
      printf '{}\n'
      exit 0
    fi
    ;;
esac
echo "az stub: unhandled args: $*" >&2
exit 99
STUB
  chmod +x "$bindir/az"
}

GH_BIN="$TMP/gh-bin"; make_gh_stub "$GH_BIN"
AZ_BIN="$TMP/az-bin"; make_az_stub "$AZ_BIN"

# RBA-1 — GitHub success: auth and live API probe pass, no stdout/stderr.
out="$TMP/rba1.out"; err="$TMP/rba1.err"
PATH="$GH_BIN:$PATH" run_probe github >"$out" 2>"$err"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$out" ] && [ ! -s "$err" ]; then
  pass "RBA-1: github live probe succeeds quietly"
else
  fail_case "RBA-1" "rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
fi

# RBA-2 — GitHub auth passes but live API fails under Codex: diagnostic names
# Codex workspace-write network config and GitHub domains.
out="$TMP/rba2.out"; err="$TMP/rba2.err"
PATH="$GH_BIN:$PATH" CODEX_SANDBOX=seatbelt GH_API_RC=1 \
  run_probe github >"$out" 2>"$err"; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -q 'sandbox_workspace_write' "$err" \
   && grep -q '\*\*\.github.com' "$err" \
   && grep -q 'GH_TOKEN' "$err" \
   && [ ! -s "$out" ]; then
  pass "RBA-2: github auth-ok/live-failed emits Codex network guidance"
else
  fail_case "RBA-2" "rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
fi

# RBA-3 — Azure DevOps success: extension/defaults/live project read pass.
out="$TMP/rba3.out"; err="$TMP/rba3.err"
PATH="$AZ_BIN:$PATH" AZURE_DEVOPS_EXT_ORG="https://dev.azure.com/example" AZURE_DEVOPS_PROJECT="Example Project" \
  run_probe azure-devops >"$out" 2>"$err"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$out" ] && [ ! -s "$err" ]; then
  pass "RBA-3: azure-devops live probe succeeds quietly"
else
  fail_case "RBA-3" "rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
fi

# RBA-3b — Azure DevOps target-root config success: hooks may call the probe
# from another CWD, so org/project must resolve from the explicit project root.
PROJECT_ROOT="$TMP/ado-project"
mkdir -p "$PROJECT_ROOT"
cat > "$PROJECT_ROOT/.arboretum.yml" <<'YAML'
backend: azure-devops
azure_devops_organization: https://dev.azure.com/root-config
azure_devops_project: Root Project
YAML
out="$TMP/rba3b.out"; err="$TMP/rba3b.err"
(
  cd "$TMP" || exit
  PATH="$AZ_BIN:$PATH" AZ_CONFIG_EMPTY=1 run_probe azure-devops "$PROJECT_ROOT" >"$out" 2>"$err"
); rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$out" ] && [ ! -s "$err" ]; then
  pass "RBA-3b: azure-devops probe resolves org/project from target root"
else
  fail_case "RBA-3b" "rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
fi

# RBA-4 — Azure DevOps defaults pass but live read fails under Codex:
# diagnostic names Codex workspace-write network config and ADO domains.
out="$TMP/rba4.out"; err="$TMP/rba4.err"
PATH="$AZ_BIN:$PATH" CODEX_SANDBOX=seatbelt AZURE_DEVOPS_EXT_ORG="https://dev.azure.com/example" \
  AZURE_DEVOPS_PROJECT="Example Project" AZ_PROJECT_SHOW_RC=1 \
  run_probe azure-devops >"$out" 2>"$err"; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -q 'sandbox_workspace_write' "$err" \
   && grep -q 'dev.azure.com' "$err" \
   && grep -q 'login.microsoftonline.com' "$err" \
   && [ ! -s "$out" ]; then
  pass "RBA-4: azure-devops defaults-ok/live-failed emits Codex network guidance"
else
  fail_case "RBA-4" "rc=$rc stdout=$(cat "$out") stderr=$(cat "$err")"
fi

[ "$fail" -eq 0 ] && echo "roadmap backend access contract: ALL PASS" || exit 1
