---
name: publish
owner: arboretum-as-plugin
description: Prepare and sync your project to a public GitHub repo — review what's included, strip process artifacts via .publishignore, and push. Use when your project is ready for others to see.
disable-model-invocation: false
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, AskUserQuestion
layer: 0
---

# Publish

Handles the publish workflow — review, strip, and sync your project to a public GitHub repo.

## When to use

- Your project is ready for public sharing
- User says "publish", "make it public", "sync to public repo"
- After significant milestones when the public repo should be updated

## Procedure

### Step 1: Check prerequisites

Verify the project is in a publishable state:

```bash
git rev-parse --abbrev-ref HEAD
git status --short
```

- Must be on `main` (publishing from a feature branch is risky)
- Working tree should be clean (uncommitted changes won't be published)

If not on main:
> "Publishing should be done from `main` to ensure you're publishing merged, reviewed code. Switch to main first?"

If working tree is dirty:
> "You have uncommitted changes. These won't be included in the publish. Commit or stash them first?"

### Step 2: Check for `.publishignore`

```bash
test -f .publishignore && echo "exists" || echo "missing"
```

If `.publishignore` doesn't exist, offer to create one from the default template:

> "No `.publishignore` found. This file controls what gets excluded from your public repo. Want me to create one with sensible defaults?"

If yes, create it from the template at `docs/templates/publishignore`. The defaults exclude:
- `docs/plans/` — ephemeral implementation plans
- `docs/superpowers/` — design-phase brainstorming artifacts
- `docs/templates/` — contributors don't need bootstrap templates

### Step 3: Determine target repo

Check if `.arboretum.yml` exists and has a `publish.target` field:

```bash
test -f .arboretum.yml && grep 'target:' .arboretum.yml || echo "no config"
```

If no target is configured, ask:

> "Where should this be published? I need a GitHub repo in `owner/name` format (e.g., `myuser/myproject`).
>
> If the repo doesn't exist yet, I can create it."

Save the target for future runs by writing/updating `.arboretum.yml`:

```yaml
publish:
  target: owner/repo-name
```

### Step 4: Review — what will be published?

Build the inclusion/exclusion picture and present it to the user.

**4a. Read `.publishignore` and list exclusions:**

```bash
# Show what will be excluded
grep -v '^#' .publishignore | grep -v '^$'
```

**4b. Check for sensitive files that aren't excluded:**

Scan for common sensitive patterns:
- `.env`, `.env.*` files
- Files containing `SECRET`, `TOKEN`, `PASSWORD`, `API_KEY` (case-insensitive)
- `credentials.json`, `*.pem`, `*.key`
- `.claude/projects/` (personal memory files)

If anything looks sensitive:
> "⚠ These files will be included in the public repo and may contain sensitive data:
> - `.env.production`
> - `config/secrets.json`
>
> Add them to `.publishignore`?"

**4c. Check documentation quality:**

- Does `docs/ARCHITECTURE.md` exist and have content?
- Does `CLAUDE.md` exist? (If there's a `CLAUDE.public.md`, note that it should be used as the public version)
- Do specs in `docs/specs/` have their Purpose and Behaviour sections filled in?

Report any gaps but don't block — the user decides what's ready.

**4d. Check for file renames:**

Look for `*.public.md` files that should replace their counterparts in the public repo:

```bash
find . -name "*.public.md" -not -path "./.git/*" 2>/dev/null
```

If found (e.g., `CLAUDE.public.md`, `README.public.md`), note them:
> "Found public-version files that will replace their counterparts:
> - `CLAUDE.public.md` → `CLAUDE.md`
> - `README.public.md` → `README.md`"

**4e. Present the summary and ask for confirmation:**

> "**Publish summary:**
> - Target: `owner/repo-name`
> - Excluded: [list from .publishignore]
> - Sensitive files: [none found / list]
> - File renames: [list or none]
> - Documentation gaps: [list or none]
>
> Ready to publish?"

Wait for explicit confirmation before proceeding.

### Step 5: Sync to public repo

**5a. Clone or fetch the target repo:**

```bash
# Work in a temp directory
WORK_DIR=$(mktemp -d)

# Check if repo exists
if gh repo view <target> &>/dev/null; then
  gh repo clone <target> "$WORK_DIR/target" -- --depth=1
else
  # Ask before creating
  echo "Repo <target> doesn't exist yet."
fi
```

If the repo doesn't exist, confirm with the user:
> "The repo `<target>` doesn't exist. Create it as a public repo?"

```bash
gh repo create <target> --public --clone "$WORK_DIR/target"
```

**5b. Sync files using rsync:**

Use `--exclude-from` to read exclusions directly from `.publishignore`:

```bash
rsync -av --delete \
  --exclude='.git/' \
  --exclude='.publishignore' \
  --exclude='.arboretum.yml' \
  --exclude='.graduateignore' \
  --exclude='.claude/projects/' \
  --exclude-from='.publishignore' \
  ./ "$WORK_DIR/target/"
```

**5c. Apply file renames:**

```bash
# Replace files with their .public.md versions
for public_file in $(find . -name "*.public.md" -not -path "./.git/*"); do
  base=$(echo "$public_file" | sed 's/\.public\.md$/.md/')
  target_path="$WORK_DIR/target/$base"
  cp "$public_file" "$target_path"
  # Remove the .public.md version from target (it shouldn't be there)
  rm -f "$WORK_DIR/target/$public_file"
done
```

**5d. Commit and push:**

```bash
cd "$WORK_DIR/target"
git add -A
if git diff --cached --quiet; then
  echo "No changes to publish."
else
  SHORT_SHA=$(git -C <source> rev-parse --short HEAD)
  git commit -m "Publish from source ($SHORT_SHA)"
  git push origin main
fi
```

**5e. Clean up:**

```bash
rm -rf "$WORK_DIR"
```

### Step 6: Report

> "Published to `<target>`.
>
> [link to repo]
>
> Next sync: run `/publish` again after your next set of changes lands on main."

## Important

- **Always confirm before publishing.** Publishing pushes code to a potentially public repo. Never auto-publish.
- **Never publish from a feature branch.** Only publish from `main`.
- **Clean working tree required.** Uncommitted changes create confusion about what was published.
- **`.publishignore` is the user's file.** The skill creates a sensible default but the user controls what's excluded.
- **File renames are convention-based.** `*.public.md` files replace their counterparts — this lets projects maintain separate internal/external versions of key docs.
- **One-way sync.** Changes flow private → public only. The public repo should never be edited directly.
- **Sensitive file scanning is best-effort.** The skill checks common patterns but can't guarantee it catches everything. The review step exists for the user to verify.
