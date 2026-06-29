# Project Context (ogent)

ogent is an Emacs package: org-first AI prompting and multi-agent coding
on top of gptel. Source lives in `lisp/` (+ `lisp/ui/`), tests in `test/`
(ERT via `make test`), specs in `specs/`, user docs in `docs/`.

## Issue tracking

Use **br (beads_rust)**; see AGENTS.md for the workflow. br never runs
git: after `br sync --flush-only`, `git add .beads/ && git commit`
yourself. Legacy bd/Dolt data is archived in `.beads-legacy-bd/`.

## Build & verify

- `make test`: full ERT suite (silent on success at default verbosity;
  use `./makem.sh -vv test` to see the summary)
- `make lint`: byte-compile, checkdoc, check-declare, indentation
- Byte-compile warnings gate merges; keep the tree warning-free.
