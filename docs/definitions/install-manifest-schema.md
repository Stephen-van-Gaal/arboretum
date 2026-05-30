---
name: install-manifest-schema
version: v1
status: active
---

# Install Manifest Schema

## Version
v1

## Purpose
`.arboretum/install-manifest.json` records every framework-owned file vendored
into a project, the framework version it shipped from, and its content hash as
shipped. It is the 3-way merge *base* a vendored copy otherwise lacks. Produced
by `/init` and rewritten by `/upgrade`. Project-local, sync-excluded.

## Shape

```json
{
  "schema_version": 1,
  "framework_version": "0.18.3",
  "updated_at": "2026-05-29T00:00:00Z",
  "files": {
    "scripts/health-check.sh": { "version": "0.18.3", "sha256": "<64-hex>" }
  }
}
```

## Fields
- `schema_version` (int) — this schema's version; currently `1`.
- `framework_version` (string, semver) — plugin version the project was last synced *to*. The staleness signal compares this against the installed plugin version.
- `updated_at` (string, ISO-8601 UTC) — last write time.
- `files` (object) — keys are repo-root-relative POSIX paths; each value is
  `{ "version": <semver synced-from>, "sha256": <64-char lowercase hex of the
  file content as the framework shipped it> }`.

## Invariants
- Every `files` key is relative, uses `/`, and never starts with `/` or `.arboretum/`.
- `sha256` is the hash of the *plugin-cache* content at `version`, not the project copy.
- Consumers MUST treat a missing or malformed manifest as "pre-manifest" (bootstrap), never as "no files installed".
