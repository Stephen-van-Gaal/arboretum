---
name: roadmap-view-spec
version: v1
status: active
---

# Roadmap View Query-Spec

## Status
active

## Version
v1

## Description

The **query-spec** is the constrained JSON filter object that `/roadmap view`
produces and `scripts/roadmap/view.sh` consumes. It is the safety seam for the
feature: a natural-language query is translated (by a preset or a subagent) into
this structured object — never into a raw shell/tracker command — so untrusted
text cannot inject. `view.sh` validates it fail-closed before any fetch.

This definition is the single source of truth for the schema. Three surfaces
bind to it and MUST agree: the validator in `scripts/roadmap/view.sh`
(`--validate-spec`), the `/roadmap view` subagent prompt in
`skills/roadmap/SKILL.md`, and the consumer contract
`docs/contracts/roadmap-view.contract.md`.

## Schema

```json
{
  "state":      "open|closed|all",
  "label_any":  ["<label>", "..."],
  "label_all":  ["<label>", "..."],
  "text_match": ["<term>", "..."],
  "epic":       <positive-int> | null,
  "group_by":   "horizon|none",
  "limit":      <int 1..200>
}
```

All keys are optional. An empty object `{}` is valid and means: open issues,
no filters, `group_by:none`, `limit:50`.

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `state` | enum `open`/`closed`/`all` | `open` | Issue state. Mapped per backend (GitHub `open/closed`; ADO via `azure_devops_closed_states`). |
| `label_any` | array of strings | `[]` | Match issues carrying **any** of these labels. |
| `label_all` | array of strings | `[]` | Match issues carrying **all** of these labels. |
| `text_match` | array of strings | `[]` | Match issues whose **title** contains any term (case-insensitive). Applied as a jq/text post-filter — never interpolated into a command. |
| `epic` | positive int or `null` | `null` | When set, render that epic's tree (the epic + its children via `roadmap_epic_graph`) instead of a flat/grouped list. |
| `group_by` | enum `horizon`/`none` | `none` | Flat list, or bucket the result set under `horizon:*` headers. Result-set `group_by: epic` is **deferred to v2** — use the `epic` field for the single-epic tree. |
| `limit` | int in `[1, 200]` | `50` | Max issues fetched. |

## Validation (fail-closed)

`view.sh --validate-spec` reads the spec on stdin and exits:

- `0` — valid.
- `3` — invalid, with `view: invalid query-spec — <field>: <reason>` on stderr.

Rejections: unknown top-level key; `state`/`group_by` outside its enum;
`label_any`/`label_all`/`text_match` not an array of strings; `epic` not a
positive integer or `null`; `limit` not an integer in `[1, 200]`; malformed
JSON. No silent coercion — an invalid spec is surfaced, never repaired.

## Consumers

- `scripts/roadmap/view.sh` — validator + renderer (owner).
- `skills/roadmap/SKILL.md` §5 — preset builders and the free-form subagent prompt.
- `docs/contracts/roadmap-view.contract.md` — the producer↔consumer seam.
