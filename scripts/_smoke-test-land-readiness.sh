#!/usr/bin/env bash
# owner: git-workflow-tooling
# scope: plugin-only
# Smoke test: #497 land readiness ordering in skill prose and CI workflow.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "Error: requires bash. Run: bash $0" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
note() { echo "FAIL: $1" >&2; fail=1; }
pass() { echo "PASS: $1"; }

python3 - "$ROOT" <<'PY' || fail=1
from pathlib import Path
import sys

root = Path(sys.argv[1])
finish = (root / "skills/finish/SKILL.md").read_text()
pr = (root / "skills/pr/SKILL.md").read_text()
land = (root / "skills/land/SKILL.md").read_text()
ci = (root / ".github/workflows/ci.yml").read_text()

fail = False

def check(label, cond, detail=""):
    global fail
    if cond:
        print(f"PASS: {label}")
    else:
        print(f"FAIL: {label}{': ' + detail if detail else ''}", file=sys.stderr)
        fail = True

def before(text, a, b):
    ia, ib = text.find(a), text.find(b)
    return ia != -1 and ib != -1 and ia < ib

check(
    "/finish local readiness before local CI",
    before(finish, 'bash scripts/pr-readiness.sh local "$BASE_REF"', 'eval "$TEST_CMD"'),
)
check(
    "/finish refreshes base before local readiness",
    # base refresh is now the workspace-context helper's bounded --fetch (#623)
    finish.count('workspace_base_ref --fetch') >= 2
    and before(finish, 'workspace_base_ref --fetch', 'bash scripts/pr-readiness.sh local "$BASE_REF"'),
)
check(
    "/finish invokes /pr --draft for GitHub ship tail",
    "/pr --draft" in finish and "draft-candidate" in finish,
)
check(
    "/pr skips request-review.sh for drafts",
    "If `--draft` is present, skip `request-review.sh` entirely in `/pr`." in pr,
)
check(
    "/pr remote readiness before request-review",
    before(pr, 'bash scripts/pr-readiness.sh remote "$PR_NUMBER"', 'bash scripts/request-review.sh "$PR_NUMBER"'),
)
check(
    "/pr guards remote readiness to GitHub",
    "On `github`, run the remote readiness gate" in pr
    and "On `azure-devops`, do not run `scripts/pr-readiness.sh remote`" in pr,
)
check(
    "/pr captures first remote readiness snapshot",
    "initial_remote_readiness=<value>" in pr and "conflict-at-instantiation" in pr,
)
check(
    "/land remote readiness before collect-review",
    before(land, 'bash scripts/pr-readiness.sh remote "$PR" --allow-draft', 'bash scripts/collect-review.sh <N>'),
)
check(
    "/land handles draft-clean by marking ready and requesting review",
    "readiness=draft-clean" in land and 'gh pr ready "$PR"' in land and 'bash scripts/request-review.sh "$PR"' in land,
)
check(
    "/land handles ci-failing before reviewer triage",
    before(land, "reason=ci-failing", "Before classifying, invoke `Skill arboretum:receive-review`"),
)
check(
    "/land recomputes readiness before resolving threads",
    "wait for mergeability recomputation before resolving addressed review threads" in land
    and "Do not resolve addressed threads until" in land,
)
check(
    "/land batches ready-PR fixes",
    "Batch one review/CI round, push once" in land
    and "`pull_request` `synchronize`" in land,
)
check(
    "/land reports metrics",
    "ci_turns=<count|unknown>" in land and "final_remote_readiness=<value>" in land,
)
check(
    "/land logs metrics through log-stage, not local log",
    'bash scripts/log-stage.sh "$ISSUE" /land summary' in land
    and "not a local `.arboretum` log file" in land,
)
check("workflow includes ready_for_review", "ready_for_review" in ci)
check("workflow skips draft PR CI job", "github.event.pull_request.draft == false" in ci)
check("workflow keeps stale-run cancellation", "cancel-in-progress: true" in ci)
check("workflow has preflight job", "preflight:" in ci)
check("workflow gates expensive CI on preflight", "needs: preflight" in ci)
check("workflow skips duplicate preflight in expensive CI", 'ARBORETUM_CI_PREFLIGHT_DONE: "1"' in ci)
check(
    "workflow runs PR preflight with read-only token",
    "permissions:\n      contents: read\n      pull-requests: read" in ci
    and "--repair-commit-mode same-branch" not in ci
    and "--push-safe-repairs" not in ci,
)

sys.exit(1 if fail else 0)
PY

if [ "$fail" -eq 0 ]; then
  echo "PASS: land readiness prose/workflow"
else
  exit 1
fi
