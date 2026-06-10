## Issue Tracking with br (beads_rust)

This project uses **br (beads_rust)** for issue tracking:
https://github.com/Dicklesworthstone/beads_rust

**Note:** `br` is non-invasive and never executes git commands. After
`br sync --flush-only`, you must manually run `git add .beads/ && git commit`.

**Quick reference:**
- `br ready --json` - Find unblocked work
- `br create "Title" -t task -p 2` - Create an issue
- `br update <id> --claim` - Atomically claim work (assignee + in_progress)
- `br close <id> --reason "Done"` - Complete work
- `br dep add <child> <parent>` - Add a dependency
- `br dep cycles` - Must return empty
- `br doctor` - Check health

**Sync and commit (explicit, every session end):**
```bash
br sync --flush-only
git add .beads/
git commit -m "sync beads"
```

Legacy bd/Dolt data is archived under `.beads-legacy-bd/` (read-only;
includes a JSONL export of all 227 historical issues).

# Repository Guidelines

## Project Specs (Load On-Demand)

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

- `make lint` delegates to `makem.sh`, which runs byte-compilation, checkdoc, check-declare, and indentation lints across `lisp/` and `test/`.
- `make test` executes all `ert` suites (`(ert-run-tests-batch-and-exit)`), using the fixtures in `test/data/`.
- `make demo` launches a bare `emacs -Q` with the sandbox Org file (`sandbox/demo.org`); it does not load ogent itself, so load the package manually if you want to validate keybindings like `C-c . p` and `C-c . d`.
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

---

## br (beads_rust) Workflow

**Note:** `br` is non-invasive and never executes git commands. After
`br sync --flush-only`, you must manually run `git add .beads/ && git commit`.

### Workflow Pattern

1. **Find work**: `br ready --json` shows unblocked issues.
2. **Claim**: `br update <id> --claim` sets assignee and in_progress atomically.
3. **Implement, test, document.**
4. **Discover new work?** `br create "Title" -t task -p 2`, then
   `br dep add <new-id> <parent-id>` if it blocks/is blocked.
5. **Complete**: `br close <id> --reason "Done"`.
6. **Sync and commit**:
   ```bash
   br sync --flush-only
   git add .beads/
   git commit -m "sync beads"
   ```

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, chore
- **Blocking**: `br dep add <child> <parent>`; `br dep cycles` must stay empty
- **Storage**: `.beads/beads.db` (SQLite) is primary; `.beads/issues.jsonl` is the git-friendly export
- **Health**: `br doctor` after upgrades or odd behavior

### Session Protocol

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export DB to JSONL
git add .beads/         # Stage issue changes
git commit -m "..."     # Commit code + beads together
git push                # Push to remote
```
