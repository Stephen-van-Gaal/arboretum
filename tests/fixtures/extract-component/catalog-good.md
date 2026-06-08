# Duplication catalog — 2026-06-07

### C1 — scrub-control-chars
- **tier:** 1
- **clone_type:** 1
- **pattern:** control-char scrub regex
- **occurrences:** 17
- **distinct_files:** 11
- **languages:** python-in-shell
- **rough_contract:** strip the control-char class before serialization
- **home:** scripts/lib/scrub-control-chars.sh
- **worth_extracting:** yes — documented-but-unenforced invariant
- **notes:** log-stage.sh adds a tab; reconcile on extract
