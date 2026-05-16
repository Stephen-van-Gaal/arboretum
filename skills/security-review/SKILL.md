---
name: security-review
owner: git-workflow-tooling
description: Analyze AI-facing code for prompt injection and instruction hijacking risks. Use before PRs that modify hooks, skills, scripts, or agent instruction files.
disable-model-invocation: false
allowed-tools: Bash, Read, Grep, Glob
argument-hint: [--full]
layer: 2
---

# Security Review — Prompt Injection Analysis

Analyze AI-facing code for prompt injection, instruction hijacking, and permission escalation risks.

This skill focuses on risks that require reasoning about intent and context — not mechanical pattern matching (secrets are handled by the pre-commit hook).

## Scope

Files that influence agent behavior:
- `.claude/skills/**`, `skills/**` — slash skills (project-local and plugin-provided)
- `.claude/hooks/**` — Claude Code hooks
- `.githooks/**` — git hooks
- `scripts/**` — automation scripts
- `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` — agent instruction files
- Files containing system prompts, tool definitions, or instruction templates

## Procedure

### 1. Determine scope

Parse `$ARGUMENTS` for `--full`. If present, scan all AI-facing files in the project. Otherwise, scan only files changed on this branch.

Detect the base branch:
```bash
BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
BASE="${BASE:-main}"
```

**Default mode:** Get changed files and filter to AI-facing paths:
```bash
git diff $BASE...HEAD --name-only
```

Filter to files matching the scope paths above. If no AI-facing files were changed, report "No AI-facing files in diff" and exit.

**Full mode (`--full`):** Use Glob to find all files matching the scope paths, regardless of diff.

### 2. Read each file in full context

Read each in-scope file completely — not just the diff. Prompt injection often depends on surrounding context (e.g., a template that becomes dangerous when variable-substituted).

### 3. Analyze for risks

For each file, check for these risk categories:

**Instruction override:**
- Phrases like "ignore previous instructions", "you are now", "forget everything above"
- System prompt overrides or attempts to redefine the agent's role
- `<system>`, `<instructions>`, or similar XML-like tags that mimic system messages

**Hidden instructions:**
- HTML comments (`<!-- -->`) containing directives
- Zero-width characters (U+200B, U+FEFF, U+200C, U+200D)
- Base64-encoded strings that decode to instructions
- Unicode homoglyph tricks (characters that look like ASCII but aren't)

**Role manipulation:**
- "act as", "pretend you are", "you are a" directives
- Role-play scenarios designed to bypass safety guidelines
- Persona-switching instructions

**Tool abuse vectors:**
- Unescaped variable interpolation in shell commands (e.g., `$USER_INPUT` in a `bash -c`)
- Path traversal patterns (`../`, `~/.claude/`)
- Dynamic tool invocation based on untrusted input
- Crafted inputs that could cause a skill to execute unintended tools

**Permission escalation:**
- Instructions to modify `settings.json` or hook configuration
- Attempts to grant additional tool permissions
- Instructions to disable or bypass safety hooks
- `--no-verify`, `--force`, or similar flags in automated scripts

### 4. Present summary report

Format findings as:

```
## Security Review: [branch-name or "Full Scan"]

**Files reviewed:** N
**Findings:** N (critical: N, warning: N, info: N)

---

### [severity] [file:line] — [concern type]

**Snippet:**
> [relevant code with 2-3 lines of surrounding context]

**Analysis:** [why this is a concern, what could go wrong]

**Recommendation:** [specific action to take]

---

[repeat for each finding]
```

If no findings: "No prompt injection or instruction hijacking risks detected in N files reviewed."

## Important

- **Do NOT auto-fix.** Present findings for the user to evaluate and act on.
- **Read files in full.** A diff-only review misses context that makes patterns dangerous.
- **Severity guide:**
  - **Critical:** Likely exploitable — unescaped interpolation in shell commands, direct instruction overrides in user-facing templates
  - **Warning:** Suspicious pattern that warrants review — hidden characters, base64 blobs in instruction files, overly permissive tool grants
  - **Info:** Worth noting but low risk — HTML comments in templates (common, usually benign), `--force` flags with clear justification
- **False positives are OK.** This is a review aid, not a gate. It's better to flag something benign than miss something real.
- **No persistent state.** Each review starts fresh. Do not create or update any tracking files.

$ARGUMENTS
