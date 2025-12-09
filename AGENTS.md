BEFORE ANYTHING ELSE: run 'bd onboard' and follow the instructions

# Repository Guidelines

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

## Commit & Pull Request Guidelines
- Follow conventional commits (`feat:`, `fix:`, `docs:`). Reference Org features, e.g., `feat: add ogent-context-preview buffer`.
- Each PR must include: problem statement, testing evidence (`make test` output), screenshots or GIFs for UI tweaks, and links to any related issues or design docs.
- Keep PRs narrow (≤500 LOC diff) so reviewers can reason about prompt-context impacts.

## Agent-Specific Practices
- Document any reusable prompt subtrees in `docs/prompts.org` and register them with `ogent-prompt-dispatch` so future agents inherit good defaults.
- When experimenting with new handle syntaxes or multi-model layouts, record the Org transcript under `docs/experiments/` for reproducibility.
