# owner: roadmap

# roadmap score record (v3)

One JSON object per open issue, stored in `.arboretum/score-cache.json` under the
issue-number key. Required fields and enums:

| Field | Type | Enum / shape |
|---|---|---|
| `value` | string | `high` \| `medium` \| `low` |
| `value_description` | string | one line, control-char scrubbed |
| `posture` | string | `live` \| `preventive` \| `mixed` |
| `hazard` | string | `blocks-legit` \| `permits-bad` \| `none` \| `na` |
| `complexity` | string | `bugfix` \| `design` \| `brainstorm` |
| `blocker` | string | `none` \| `one-decision` \| `spec` |
| `depends_on` | array | list of integers (issue numbers); may be empty |
| `disposition` | string | `keep` \| `combine` \| `delete` \| `decompose` |
| `class` | string | `work-unit` \| `orchestrator` |
| `body_sha` | string | 12 lowercase hex chars |
| `scored` | string | `YYYY-MM-DD` (UTC) |

When `disposition == combine`, two extra keys are REQUIRED: `anchor` (int) and
`priority_driver` (int). For `class == orchestrator`, `hazard` is `na` and `complexity`/`blocker`
still hold a valid enum value — the validator requires it and rejects null
or `—`. They are not-applicable context for scheduling purposes but must
satisfy the schema.

`agent_ready_candidate` is DERIVED, never stored:
`complexity == "bugfix" && blocker == "none" && disposition == "keep" && class == "work-unit"`.
