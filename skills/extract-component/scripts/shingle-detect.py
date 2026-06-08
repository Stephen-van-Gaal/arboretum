#!/usr/bin/env python3
# owner: extract-shared-component
# Tier-2 detector — normalized k-line shingle detector for a bash+python corpus.
#
# Reads a newline-separated file list on stdin. For each file: keep meaningful
# lines (drop blank + comment), normalize whitespace, slide a window of W
# meaningful lines, hash. Windows recurring across >= MIN_FILES distinct files
# are candidates (Rule of Three -> default 3). Overlapping windows of the same
# block sharing the same distinct-file set are CLUSTERED into one region.
#
# Usage: shingle-detect.py [WINDOW] [MIN_FILES] [--mask]   (file list on stdin)
import sys, re, hashlib, json
from collections import defaultdict

WINDOW = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 4
MIN_FILES = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 3
MASK = "--mask" in sys.argv[1:]

paths = [l.strip() for l in sys.stdin if l.strip()]

STRUCTURAL = {
    "fi", "done", "esac", "then", "else", "do", "}", "{", ")", "(", ";;",
    "EOF", "PY", "'EOF'", "'PY'", "*)", "return", "exit 0", "exit 1",
}
COMMENT = re.compile(r"^\s*#")
WS = re.compile(r"\s+")
STR_LIT = re.compile(r"""("([^"\\]|\\.)*"|'([^'\\]|\\.)*')""")
NUM_LIT = re.compile(r"\b\d+\b")

def normalize(line):
    line = WS.sub(" ", line.strip())
    if MASK:
        line = STR_LIT.sub('"X"', line)
        line = NUM_LIT.sub("N", line)
    return line

# hash -> {"text": [...], "hits": [(file, start_index_in_meaningful, lineno)]}
windows = defaultdict(lambda: {"text": None, "hits": []})
for path in paths:
    try:
        raw = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except (IsADirectoryError, FileNotFoundError):
        continue
    meaningful = []
    for i, ln in enumerate(raw, 1):
        if not ln.strip() or COMMENT.match(ln):
            continue
        meaningful.append((normalize(ln), i))
    for s in range(len(meaningful) - WINDOW + 1):
        win = meaningful[s:s + WINDOW]
        norm_lines = [w[0] for w in win]
        if all(l in STRUCTURAL for l in norm_lines):
            continue
        key = hashlib.sha1("\n".join(norm_lines).encode()).hexdigest()
        rec = windows[key]
        if rec["text"] is None:
            rec["text"] = norm_lines
        rec["hits"].append((path, s, win[0][1]))

# Build raw candidates over the Rule-of-Three gate.
raw_candidates = []
for key, rec in windows.items():
    distinct = sorted({h[0] for h in rec["hits"]})
    if len(distinct) >= MIN_FILES:
        cand = {
            "fileset": tuple(distinct),
            "files": len(distinct),
            "occurrences": len(rec["hits"]),
            "text": rec["text"],
            # per-file start indices in the meaningful-line stream, for clustering
            "starts": defaultdict(list),
        }
        for (p, s, _ln) in rec["hits"]:
            cand["starts"][p].append(s)
        raw_candidates.append(cand)

# Cluster: two candidates with the SAME distinct-file set whose windows are
# adjacent/overlapping in every shared file (start indices within WINDOW of each
# other) are the same logical block — merge into one region.
def overlap(a, b):
    if a["fileset"] != b["fileset"]:
        return False
    for p in a["fileset"]:
        sa, sb = sorted(a["starts"][p]), sorted(b["starts"][p])
        if not any(abs(x - y) < WINDOW for x in sa for y in sb):
            return False
    return True

# Union-find over candidates connected by overlap, so clustering is the full
# transitive closure (A~B and B~C ⇒ {A,B,C}) regardless of candidate ordering —
# a single forward pass could miss transitive links.
parent = list(range(len(raw_candidates)))

def find(x):
    while parent[x] != x:
        parent[x] = parent[parent[x]]  # path compression
        x = parent[x]
    return x

def union(a, b):
    ra, rb = find(a), find(b)
    if ra != rb:
        parent[rb] = ra

for a in range(len(raw_candidates)):
    for b in range(a + 1, len(raw_candidates)):
        if overlap(raw_candidates[a], raw_candidates[b]):
            union(a, b)

groups = defaultdict(list)
for idx in range(len(raw_candidates)):
    groups[find(idx)].append(raw_candidates[idx])

clustered = []
for members in groups.values():
    # Represent the cluster by its longest-text member.
    rep = max(members, key=lambda c: len(c["text"]))
    clustered.append({
        "files": rep["files"],
        "occurrences": max(c["occurrences"] for c in members),
        "file_list": list(rep["fileset"]),
        "text": rep["text"],
    })

clustered.sort(key=lambda c: (c["files"], c["occurrences"]), reverse=True)
json.dump(clustered, sys.stdout, indent=2)
print()
sys.stderr.write(f"\n{len(clustered)} clustered candidate(s) "
                 f"(W={WINDOW}, MIN_FILES={MIN_FILES}, mask={MASK})\n")
