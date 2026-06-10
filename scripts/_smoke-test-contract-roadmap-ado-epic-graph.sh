#!/usr/bin/env bash
# owner: roadmap
# _smoke-test-contract-roadmap-ado-epic-graph.sh — Contract test for the
# azure-devops branch of roadmap_epic_graph (docs/contracts/roadmap-view.contract.md
# § Epic-tree ADO hierarchy / EWA-1). PATH-shadows `az` with a stub that returns
# canned work-item JSON, so the relations->graph transform is exercised with
# no network. Auto-discovered by ci-checks.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/roadmap/lib.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }
fail=0
pass() { echo "PASS: $1"; }
failc() { echo "FAIL: $1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; fail=1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Stub `az`: respond to `boards work-item show --id N --query Q -o json`.
# If the query projects relations (root call) return the epic with two
# Hierarchy-Forward children + one Hierarchy-Reverse parent; otherwise return
# the simple child projection. State 135/118=Active(open), 127=Closed(done).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/az" <<'AZ'
#!/usr/bin/env bash
id=""; query=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id) id="$2"; shift 2 ;;
    --query) query="$2"; shift 2 ;;
    *) shift ;;
  esac
done
emit() { printf '%s' "$1"; }
case "$query" in
  *rels:relations*)   # root projection: two Hierarchy-Forward children (#118,#127),
                      # one Hierarchy-Reverse parent (#100), one Related (#152, ignored).
    case "$id" in
      135) emit '{"id":135,"title":"Epic: clinical-event silver","state":"Active","type":"Epic","tags":"","rels":[{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/o/p/_apis/wit/workItems/118"},{"rel":"System.LinkTypes.Hierarchy-Forward","url":"https://dev.azure.com/o/p/_apis/wit/workItems/127"},{"rel":"System.LinkTypes.Related","url":"https://dev.azure.com/o/p/_apis/wit/workItems/152"},{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"https://dev.azure.com/o/p/_apis/wit/workItems/100"}]}' ;;
      *)   emit '{"id":'"$id"',"title":"x","state":"Active","type":"Issue","tags":"","rels":[]}' ;;
    esac ;;
  *)                  # child/parent projection (no relations; includes System.Tags)
    case "$id" in
      100) emit '{"id":100,"title":"Grand epic","state":"Active","type":"Epic","tags":""}' ;;
      118) emit '{"id":118,"title":"Child A","state":"Active","type":"Issue","tags":"blocked; horizon:now"}' ;;
      127) emit '{"id":127,"title":"Child B done","state":"Closed","type":"Issue","tags":""}' ;;
      *)   emit '{"id":'"$id"',"title":"x","state":"Active","type":"Issue","tags":""}' ;;
    esac ;;
esac
AZ
chmod +x "$TMP/bin/az"

# Drive roadmap_ado_epic_graph 135 with the stub az on PATH.
graph=$(PATH="$TMP/bin:$PATH" bash -c "source '$LIB'; ROADMAP_BACKEND=azure-devops roadmap_epic_graph 135" 2>/dev/null)

# EWA-1: graph has the epic + its two hierarchy children wired (related #152 excluded)
printf '%s' "$graph" | python3 -c '
import json,sys
g=json.load(sys.stdin); n=g["nodes"]
assert g["next_up"]==135, g
assert n["135"]["is_epic"] is True
assert n["135"]["children"]==[118,127], n["135"]["children"]
assert "152" not in n, "Related link must not become a child"
assert n["118"]["state"]=="open" and n["127"]["state"]=="closed", (n["118"]["state"],n["127"]["state"])
assert n["118"]["parent"]==135 and n["127"]["parent"]==135
' && pass "EWA-1 ADO relations -> graph (children wired, state mapped, Related excluded)" \
  || failc "EWA-1 ADO epic graph wrong" "$graph"

# EWA-2: the Hierarchy-Reverse parent (#100) is fetched and inserted, with #135 as its child
printf '%s' "$graph" | python3 -c '
import json,sys
n=json.load(sys.stdin)["nodes"]
assert n["135"]["parent"]==100, n["135"]["parent"]
assert "100" in n, "parent node must be inserted so the classifier can resolve nodes.get(parent)"
assert n["100"]["children"]==[135] and n["100"]["is_epic"] is True, n["100"]
' && pass "EWA-2 parent node inserted (F3)" || failc "EWA-2 parent node missing" "$graph"

# EWA-3: child labels populated from System.Tags (J1)
printf '%s' "$graph" | python3 -c '
import json,sys
n=json.load(sys.stdin)["nodes"]
assert n["118"]["labels"]==["blocked","horizon:now"], n["118"]["labels"]
assert n["127"]["labels"]==[], n["127"]["labels"]
assert n["118"]["stage"] is None, "ADO stage stays null (no stage signal) — v1 limitation"
' && pass "EWA-3 child labels from System.Tags; stage null (J1)" || failc "EWA-3 child labels wrong" "$graph"

exit $fail
