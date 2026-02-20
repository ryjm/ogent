BEFORE ANYTHING ELSE: run 'bd onboard' and follow the instructions

## Issue Tracking

This project uses **bd (beads)** for issue tracking.
Run `bd prime` for workflow context, or install hooks (`bd hooks install`) for auto-injection.

**Quick reference:**
- `bd ready` - Find unblocked work
- `bd create "Title" --type task --priority 2` - Create issue
- `bd close <id>` - Complete work
- `bd sync` - Sync with git (run at session end)

For full workflow details: `bd prime`

# Repository Guidelines

## Knowledge Files (Load On-Demand)

Reference these when relevant - don't preload everything:

- **Emacs Lisp**: @knowledge/elisp-patterns.org - Package dev handbook, async, testing, UI patterns
- **TDD Discipline**: @knowledge/tdd-patterns.md - Red-Green-Refactor cycle (MANDATORY for all changes)
- **Testing Patterns**: @knowledge/testing-patterns.md - Testing trophy, mocking, fixtures, async testing
- **Git Workflows**: @knowledge/git-patterns.md - Rebase vs merge, recovery, bisect, conventional commits
- **Error Debugging**: @knowledge/error-patterns.md - Check FIRST when hitting errors

### When to Load

| Situation                 | Load                                                            |
| ------------------------- | --------------------------------------------------------------- |
| Writing/modifying elisp   | `@knowledge/elisp-patterns.org`                                 |
| Adding tests or TDD work  | `@knowledge/tdd-patterns.md` + `@knowledge/testing-patterns.md` |
| Git conflicts or recovery | `@knowledge/git-patterns.md`                                    |
| Debugging errors          | `@knowledge/error-patterns.md`                                  |

### Project-Specific Specs (In-Repo)

These live in the repo and take precedence over global knowledge:

- `specs/architecture.org` - Context pipeline, model registry, tool FSM, testing expectations
- `specs/feature-playbooks.org` - Where to put code for each feature type
- `specs/style-guide.org` - Elisp coding conventions for this project
- `specs/gptel-integration.org` - Transport layer design, streaming, error handling

---

## Project Structure & Module Organization

- `lisp/` holds the ogent minor-mode, handle-resolution utilities, and integrations with `gptel`/`org-roam`. Split files by concern (`ogent-core.el`, `ogent-context.el`, etc.) to keep autoloads lean.
- `lisp/ui/` contains UI affordances (transients, context preview buffer, src-block renderers).
- `test/` mirrors the `lisp/` tree with `*-tests.el` suites plus Org fixtures under `test/data/` to exercise subtree hydration and multi-model fan-out.
- `docs/` stores narrative guides such as prompt templates and interaction recipes. Images or GIFs documenting keybindings belong in `docs/assets/`.

## Build, Test, and Development Commands

- `make lint` runs `emacs --batch -l ert -l lint.el -f ogent-lint` to catch byte-compile warnings and `checkdoc` issues.
- `make test` executes all `ert` suites (`(ert-run-tests-batch-and-exit)`), using the fixtures in `test/data/`.
- `make demo` launches Emacs with a sandbox Org file (`sandbox/demo.org`) so you can validate keybindings like `C-c o p`, `C-c C-c`, and `C-c C-d`.
- Use `direnv` or `.envrc` to export API tokens for `gptel`; avoid committing credentials.

## Coding Style & Naming Conventions

- Emacs Lisp uses two-space indents and `setq-local` over `setq` inside functions. Prefix every public symbol with `ogent-` (`ogent-request`, `ogent-context-preview`).
- Keep function docstrings imperative (“Return…”, “Display…”). Favor plist arguments over alists for context payloads.
- Apply `M-x checkdoc` before pushing and ensure `byte-compile` runs cleanly; warnings gate merges.

## Doom Emacs Compatibility

- Ship a lightweight `(package! ogent)` recipe and document a `(use-package! ogent :after org :config (map! :leader :desc "Prompt" "o p" #'ogent-prompt-dispatch))` example so the package drops cleanly into Doom configurations.
- Wrap keybindings with `general`/`map!` only when Doom is detected; otherwise expose a vanilla `ogent-mode-map`. Avoid redefining Doom’s defaults—prefer leader-prefixed chords (`SPC o p`, `SPC o n`) over global bindings.
- Follow Doom best practices: declare autoload cookies for interactive commands, respect `doom-leader-alt-key`, and ensure customization options live under the `ogent` customization group.

## Testing Guidelines

- Write `ert-deftest` cases in files ending with `-tests.el`; mimic the production namespace (`ogent-context-tests.el`).
- Cover handle resolution, context preview summaries, async multi-model routing, and keybinding regressions. Target ≥90% coverage for `ogent-context.el`.
- Run `make test` locally before every PR; CI rejects failures automatically.
- After any merge or push to `master`/`main`, verify CI passes before ending the session:
  `gh run list --limit 1` then `gh run watch <run-id>` (or check the run URL) and confirm success.

## Commit & Pull Request Guidelines

- Always use Conventional Commits for every commit (`feat:`, `fix:`, `docs:`, etc.). Reference Org features, e.g., `feat: add ogent-context-preview buffer`.
- Each PR must include: problem statement, testing evidence (`make test` output), screenshots or GIFs for UI tweaks, and links to any related issues or design docs.
- Keep PRs narrow (≤500 LOC diff) so reviewers can reason about prompt-context impacts.

## Agent-Specific Practices

- Document any reusable prompt subtrees in `docs/prompts.org` and register them with `ogent-prompt-dispatch` so future agents inherit good defaults.
- When experimenting with new handle syntaxes or multi-model layouts, record the Org transcript under `docs/experiments/` for reproducibility.

<!-- bv-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_viewer](https://github.com/Dicklesworthstone/beads_viewer) for issue tracking. Issues are stored in `.beads/` and tracked in git.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
bd ready              # Show issues ready to work (no blockers)
bd list --status=open # All open issues
bd show <id>          # Full issue details with dependencies
bd create --title="..." --type=task --priority=2
bd update <id> --status=in_progress
bd close <id> --reason="Completed"
bd close <id1> <id2>  # Close multiple issues at once
bd sync               # Commit and push changes
```

### Workflow Pattern

1. **Start**: Run `bd ready` to find actionable work
2. **Claim**: Use `bd update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `bd close <id>`
5. **Sync**: Always run `bd sync` at session end

### Key Concepts

- **Dependencies**: Issues can block other issues. `bd ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, question, docs
- **Blocking**: `bd dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
bd sync                 # Commit beads changes
git commit -m "..."     # Commit code
bd sync                 # Commit any new beads changes
git push                # Push to remote
```

### Best Practices

- Check `bd ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `bd create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always `bd sync` before ending session

<!-- end-bv-agent-instructions -->
