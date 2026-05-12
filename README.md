# Arboretum

**Arboretum is choreography. Superpowers does the work.**

An organizational framework for building software with AI code agents.

Arboretum gives domain experts a repeatable way to create projects that are well-organized, maintainable, and understandable — even when the human didn't write most of the code.

It externalizes the practices that experienced software engineers carry intuitively — project structure, work sequencing, safe evolution — into a process that anyone can follow with an AI code agent.

## Who This Is For

Domain experts building software with AI code agents. If you have deep knowledge in your field but limited experience structuring software projects, this framework gives you opinionated guidance on how to organize what you're building, how to sequence the work, and how to evolve your project safely.

## What This Is Not

- **Not a library or framework you import** — no runtime dependencies. Arboretum is documents, templates, and AI skills.
- **Not a replacement for Claude Code** — it's the organizational layer on top.
- **Not language-specific** — works with any language or stack.

## Principles

See `PRINCIPLES.md` for the full set. The short version:

1. **Decide before you build** — the spec is the steering wheel
2. **Every file has one owner** — traceability through ownership
3. **Humans own the what and why, AI owns the how** — domain knowledge stays with you
4. **Make change safe by making it small** — bounded specs, explicit dependencies
5. **Right-size the structure** — don't overbuild for your scale
6. **Use what exists** — integrate, don't reinvent
7. **Learn from each cycle** — reflect while context is fresh

## Four Pillars

| Pillar | What it is | Where it lives |
|---|---|---|
| **Principles** | How software should be organized | `PRINCIPLES.md` |
| **Workflows** | Best-practice sequences for common scenarios | `workflows/` |
| **Skills** | Discrete operations (arboretum + external) | `.claude/skills/` |
| **Templates** | Standardized formats that skills use | `docs/templates/` |

## Workflows

Seven workflows cover the full development lifecycle:

```
new-project      Start from nothing → architecture → spike-spec cycles → build
feature          Planned work → survey → design → plan → build → ship
bug-fix          Investigate → classify → fix → ship
explore          Spike → learn → decide (build, spike again, or abandon)
publish          Prepare your project for public sharing
refactor         Restructure without changing behaviour
documentation    Docs-only changes
```

See `workflows/README.md` for detailed stage-by-stage guides.

## Progressive Governance

Arboretum scales with your project through three layers:

- **Layer 0 (Foundation)** — `CLAUDE.md`, specs, core skills. Every project starts here. Simple enough that it feels like "just good organization."
- **Layer 1 (Structure)** — File ownership tracking, shared definitions. Activates when you have 3+ specs.
- **Layer 2 (Governance)** — Branch protection, version pins, post-commit validation. Activates for team or production work.

Start simple. Add governance only when you feel the pain of not having it.

## Prerequisites

- **macOS or Linux** (Windows: use [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install))
- [Git](https://git-scm.com/)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (CLI)
- [superpowers](https://github.com/anthropics/superpowers) skills package

## Getting Started

Arboretum installs as a Claude Code plugin and scaffolds projects via the `/arboretum:init` skill — no separate `git clone` of arboretum required.

```bash
# In any Claude Code session, install superpowers (arboretum's required peer):
/plugin marketplace add anthropics/claude-plugins-official
/plugin install superpowers@anthropics-claude-plugins-official

# Install arboretum:
/plugin marketplace add stvangaal/arboretum
/plugin install arboretum@arboretum

# Then in any new project directory, scaffold the governed structure:
/arboretum:init
```

`/arboretum:init` creates `CLAUDE.md`, `PRINCIPLES.md`, `docs/`, `workflows/`, hooks, and git config; verifies `superpowers` is installed; and hands off to `/architect` for the project-shape interview. The plugin updates from upstream automatically on subsequent `/plugin install` runs — projects don't carry frozen framework copies.

### Troubleshooting

**`Permission denied (publickey)` during install** — Claude Code clones plugins via SSH by default. If you haven't added an SSH key to GitHub, run this once in your terminal to switch to HTTPS instead:

```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

Then retry the `/plugin install` command.

## Sample Project

See `examples/rule-flow-engine/` for a fully governed sample with architecture, definitions, specs, register, and version pins.

## Contributing

Arboretum is maintained at [arboretum-dev](https://github.com/stvangaal/arboretum-dev). If you'd like to contribute, open an issue there.
