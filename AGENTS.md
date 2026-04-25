BEFORE ANYTHING ELSE: run 'bd onboard' and follow the instructions

## Issue Tracking

This project uses **bd (Beads)** with the current Gas Town worker workflow.
Run `bd prime` for workflow context. In a Gas Town role, run `gt prime`
after compaction, clear, or a new session.

**Quick reference:**
- `gt mol status` - Check hooked work; if present, execute it
- `gt mail inbox` - Check messages when the hook is empty
- `gt sling <bead> [target]` - Hook work and start execution
- `bd ready` - Find unblocked Beads work
- `bd create "Title" --type task --priority 2` - Create an issue
- `bd update <id> --claim` - Atomically claim Beads-only work
- `bd close <id>` - Complete Beads work
- `bd doctor` - Check Beads health
- `bd vc status` - Inspect Dolt-backed Beads database state

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

<!-- gastown-beads-instructions-v2 -->

---

## Gas Town / Beads Workflow Integration

This repo uses the Dolt-backed Beads workflow exposed by `bd`, with Gas Town
commands layered on top when the checkout is inside a town. The tracked
`.beads/` files are configuration and metadata; the runtime Dolt database and
lock files stay local.

### Essential Commands

```bash
# Gas Town worker startup
gt prime              # Restore full role context
gt mol status         # Check current hook
gt mail inbox         # Check messages when hook is empty
gt sling <id> [target] # Dispatch work and start now
gt done               # Polecat completion signal and merge queue handoff

# Beads issue tracking
bd prime              # Print agent workflow context
bd ready              # Show unblocked issues
bd list --status=open # List open issues
bd show <id>          # Show issue details and audit trail
bd create --title="..." --type=task --priority=2
bd update <id> --claim
bd close <id> --reason="Completed"

# Beads maintenance
bd doctor             # Health checks
bd hooks install --force
bd worktree info      # Verify worktree redirect state
bd vc status          # Inspect Dolt database changes
```

### Workflow Pattern

1. **Start or recover**: Run `bd prime`; use `gt prime` inside a Gas Town role.
2. **Check hook**: Run `gt mol status`. Hooked work is the assignment.
3. **Check mail**: Run `gt mail inbox` only when the hook is empty.
4. **Find work**: Use `bd ready` for unblocked Beads work.
5. **Claim or dispatch**: Use `bd update <id> --claim` for Beads-only work, or `gt sling <id> [target]` when the work should land on an agent hook.
6. **Complete**: Commit and push code changes, close the Bead when applicable, and run `gt done` from polecat sessions.

### Key Concepts

- **Dependencies**: Issues can block other issues. `bd ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, chore, decision; this repo also enables Gas Town custom types
- **Blocking**: `bd dep add <issue> <depends-on>` to add dependencies
- **Dolt storage**: Current Beads state lives in the Dolt database. JSONL files are compatibility/export surfaces.
- **Worktrees**: Prefer `bd worktree create`. In manually-created worktrees, run `bd worktree info` and keep `BEADS_NO_DAEMON=1` for direct access.

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
git commit -m "..."     # Commit code
git push                # Push to remote
bd vc status            # Check Beads database state if Beads changed
gt done                 # Polecats only: submit completion to Gas Town
```

`bd sync` is retained by the CLI for compatibility and is a no-op under the
Dolt backend. Use `bd dolt commit`, `bd dolt pull`, and `bd dolt push` only when
you are explicitly managing Beads database history.

### Best Practices

- Let `gt mol status` drive active Gas Town work
- Check `bd ready` for available Beads work when the hook is empty
- Claim with `bd update <id> --claim` to set assignee and in-progress atomically
- Create new issues with `bd create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Run `bd doctor` after Beads upgrades or hook changes
- Run `bd hooks install --force` after updating the `bd` CLI

<!-- end-gastown-beads-instructions -->
