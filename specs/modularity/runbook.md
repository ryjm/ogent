# ogent Modularity Runbook

How to execute a façade split safely, and how to keep modules small going forward. Pairs with
`phase8_decomposition_plan.md` (the per-file designs) and the `ogent-xlo` bead graph.

## The elisp isomorphism gate (run after every mechanical move)

```bash
cd ~/vault/projects/ogent
# 1. Behavior — must match the frozen baseline exactly:
make test            # expect exit 0, "Ran 2583 tests, 2576 results as expected, 0 unexpected, 7 skipped"
# 2. Byte-compile — no NEW warning vs baseline (pre-existing: project-root@ogent-zen.el:2390,
#    ogent-tools-project-root free var in zen tests, ui-tests indentation):
make recompile 2>&1 | grep -iE "warning|error" | grep -v <known-baseline-lines>
# 3. Surface — union of new siblings must define the SAME symbol set + autoload set as baseline:
emacs -Q --batch -l ../ogent__demonolith_workspace/scan-surface.el \
  -f ogent-scan-surface lisp/<new-sibling>.el /tmp/sib.scan
#    then diff the UNION of all post-split sibling .scan def lines against
#    ../ogent__demonolith_workspace/phase3_surface/<file>.scan.txt (definitions + autoloads sections)
# 4. Autoload target — regenerate loaddefs and confirm each cookied symbol still loads the FAÇADE:
#    diff the generated autoloads before/after; targets must be "ogent-<base>", not a submodule.
```
CI (`.github/workflows/ci.yml`) runs only the ert suite across Emacs 29.1/30.2/snapshot — step 1 is
the CI-aligned gate. Steps 2–4 are local correctness checks `make lint` does not fully cover.

## The façade move (one new sibling = one commit)

1. `git mv`-style: create `lisp[/ui]/ogent-<base>-<concern>.el`; move the cluster's top-level forms
   **verbatim** (no reformat, no rename) — keep blame; cut/paste the exact line ranges.
2. Header: `;;; ogent-<base>-<concern>.el --- … -*- lexical-binding: t; -*-`, the cluster's own
   `(require …)` lines, and `(provide 'ogent-<base>-<concern>)` + `;;; … ends here`.
3. Autoloads: for each command whose `;;;###autoload` you moved, REMOVE the cookie from the moved
   defun and add a redirect in the façade: `;;;###autoload (autoload 'CMD "ogent-<base>" nil t)`
   (drop `t` for non-commands). This keeps cold `M-x CMD` loading the façade (so its load-time side
   effects + all sibling requires still run). [zen is the exception — it has no façade side effects,
   but keep the rule uniform.]
4. Façade: add `(require 'ogent-<base>-<concern>)` in dependency order (core first; bootstrap/
   load-time forms after all parts).
5. Run the gate above. If green, `git commit -m "refactor(<base>): extract ogent-<base>-<concern>"`.
   One move per commit. Never combine a move with a rename or reformat.

## Hard rules (cycle + load-order safety)

- **Macros before use.** A macro invoked at top level (`ogent-cabinet-ui--define-section-mode`,
  `ogent-issues--define-mode`) and `cl-defstruct` accessors are needed at *compile time* → put the
  macro/struct in a sibling the consumer `(require)`s at top level (byte-compile runs top-level
  requires). Missing require = compile error, not a load error.
- **Never create a require cycle.** zen ↔ ui couple only via `declare-function` + `fboundp`/`featurep`
  guards — NEVER add `(require 'ogent-ui)` to a zen sibling or `(require 'ogent-zen)` to a ui sibling.
  For issues-B satellites, `declare-function` the façade's helpers; the façade is the only `require`
  site (requires satellites at EOF). For cabinet leaf-peel, emit `(provide 'ogent-cabinet)` *before*
  the trailing submodule requires.
- **Keep each owned `defgroup` + its `defcustom`/`defface` in the core/first sibling** (zen, ui-cabinet,
  issues). `ogent-ui` borrows `ogent-mode` from ogent-core → its core must `(require 'ogent-core)`.
- **Don't reorder `ogent.el`.** Feature names are preserved by the façade, so the loader is untouched.
- **load-path is `lisp/` + `lisp/ui/` only.** New siblings stay flat in the façade's directory.

## Recommended execution order (independent; by safety/ROI)

1. `ogent-ui-cabinet` (Candidate A) — cleanest (no shared view state, acyclic), biggest LOC win.
2. `ogent-issues` (Candidate B) — lowest risk (core untouched in place).
3. `ogent-zen` (Candidate A) — peel core+tools+workspace+edit.
4. `ogent-ui` (Candidate A) — layered; autoloads MUST route through façade (2 hard load-time forms).
5. (later, optional) zen→B (extract review then render), ui→B (relocate `handle-tool-calls`), issues→A.
If both zen and ui are split, do the cosmetic zen↔ui `declare-function` file-hint sync afterward.

`ogent-cabinet.el` is left alone (B11). Do not size-split it; the deferred kernel-extraction option
(`ogent-cabinet-store.el`, ~318 LOC) is bead `ogent-xlo.7`, backlog only.

## Keeping modules small going forward

- New cabinet view UI → new `lisp/ui/ogent-ui-cabinet-<view>.el` requiring `-core`, not appended to a
  view file.
- New zen concern → new `lisp/ogent-zen-<concern>.el` requiring `ogent-zen-core`.
- A file approaching ~1.5–2k LOC or mixing a second concern → run `scripts`-style census (wc + the
  reader scan) and peel the new concern before it fuses in. The façade pattern is the standing idiom.
