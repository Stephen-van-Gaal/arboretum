# owner: inflight-work-classifier
"""Shared classification core. Imported by epic-walk.sh and inflight.sh.
No I/O — pure functions over a {nodes, ...} graph dict (nodes keyed by int)."""
import os
import re

STAGE_RANK = {"/start": 1, "/design": 2, "/build": 3, "/finish": 4, "/pr": 5, "/land": 6, "/cleanup": 7, "/reflect": 8}
ACTIVE_MIN = STAGE_RANK["/design"]
DEPTH_CAP = 5

_CTRL = re.compile(os.environ["ARBO_CTRL_CHAR_CLASS"])  # env bridge — scripts/lib/scrub-control-chars.sh


def scrub(s):
    return _CTRL.sub("", s) if isinstance(s, str) else s


def is_active(n):
    s = n.get("stage")
    return bool(s) and STAGE_RANK.get(s, 0) >= ACTIVE_MIN


def is_blocked(n):
    return "blocked" in (n.get("labels") or [])


def epic_of(nodes, num):
    """Walk parent pointers up to the nearest type:epic ancestor."""
    seen, depth, cur = set(), 0, nodes.get(num)
    while cur is not None and depth < DEPTH_CAP:
        if cur["number"] in seen:
            break
        seen.add(cur["number"])
        if cur.get("is_epic"):
            return cur["number"]
        p = cur.get("parent")
        cur = nodes.get(p) if p is not None else None
        depth += 1
    return None


def is_epic_complete(nodes, num):
    """True when a sub-epic is open but has no open children (functionally done)."""
    n = nodes.get(num)
    if n is None or not n.get("is_epic"):
        return False
    kids = [nodes[c] for c in n.get("children", []) if c in nodes]
    return bool(kids) and all(k["state"] == "closed" for k in kids)


def brief(n):
    return {"number": n["number"], "title": scrub(n["title"]), "stage": n.get("stage")}


def classify_epic(nodes, epic_num):
    """Returns the epic-walk per-epic dict {number,title,done,total,active,next,blocked}."""
    epic = nodes[epic_num]
    kids = [nodes[c] for c in epic.get("children", []) if c in nodes]
    closed = [k for k in kids if k["state"] == "closed"]
    openk = [k for k in kids if k["state"] == "open"]
    active = [brief(k) for k in openk if is_active(k)]
    result = {
        "number": epic_num, "title": scrub(epic["title"]),
        "done": len(closed), "total": len(kids),
        "active": active, "next": None, "blocked": [],
    }
    if active:
        return result
    # No active: readiness-then-native. First ready child = next.
    # Skip open sub-epics that are functionally complete (all children closed).
    nxt = None
    blocked_before = []
    for k in openk:                       # openk preserves native (children-list) order
        if is_epic_complete(nodes, k["number"]):
            continue                       # complete sub-epic — treat as done, skip
        if is_blocked(k):
            blocked_before.append(brief({**k, "stage": None}))
            continue
        nxt = brief({**k, "stage": None})
        break
    if nxt is not None:
        result["next"] = {"number": nxt["number"], "title": nxt["title"]}
        result["blocked"] = [{"number": b["number"], "title": b["title"]} for b in blocked_before]
    else:
        # all-blocked: show the blockers, no false next
        result["blocked"] = [{"number": k["number"], "title": scrub(k["title"])} for k in openk if is_blocked(k)]
    return result
