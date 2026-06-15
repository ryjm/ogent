# Phase 8 — Decomposition Plan (ogent, elisp, façade pattern)

Base `5c206b9` · Emacs 30.1 · plan + beads only (no code moved). Inputs: the 5
`phase2_findings_*.md`, `phase4_synthesis.md`, `phase4_native_idiom.md`, `phase3_baselines.md`.

## Contract recap (applies to every split)

- **Shape:** original `lisp[/ui]/ogent-<base>.el` → thin **façade** that `require`s new
  same-directory siblings `ogent-<base>-<concern>.el` (each `(provide …)`), keeps
  `(provide 'ogent-<base>)`, and hosts any hard load-time side effects + all-parts bootstrap.
  `ogent.el` and every external `(require 'ogent-<base>)` are untouched.
- **Proof gate (run after each mechanical move; the elisp `isomorphism-gate`):**
  1. `make test` → exit 0, **2583 / 2576 expected / 0 unexpected / 7 skipped** (Phase 3 baseline).
  2. No **new** byte-compile warning vs the Phase 3 lint baseline (`project-root`@zen:2390,
     the zen-tests free-var, and ui-tests indentation are the only pre-existing items).
  3. Post-move **union** `scan.txt` def set == baseline def set (per-file `phase3_surface/*.scan`),
     identical `;;;###autoload` cookied-symbol set, AND identical autoload *load target* (see
     Autoload preservation) — diff the regenerated loaddefs.
  4. `git mv`-preserved blame; one mechanical move per commit; no reformat in a move commit.
- **Autoload preservation (elisp landmine — corrected per fresh-eyes audit).** A generated autoload
  loads the FILE its `;;;###autoload` form names. The isomorphic rule is **preserve every existing
  autoloaded symbol's CURRENT load target verbatim** — NOT "route everything through the base
  façade". Two existing cookie shapes, handled differently:
  - **Manual redirect form** already present (e.g. ui-cabinet `;;;###autoload (autoload
    'ogent-cabinet-home-dispatch "ogent-ui-cabinet" nil t)` @1227; ui `(autoload 'ogent-request
    "ogent" …)` @2528, `'ogent-ask-menu`/`'ogent-prompt-dispatch` → `"ogent"` @1068/@1152): **keep
    the form verbatim in the façade**, and move the defun to its submodule WITHOUT a cookie. Target
    unchanged (some intentionally point at `"ogent"`, i.e. load the whole package — do NOT change to
    the submodule or even to `"ogent-<base>"`).
  - **Plain `;;;###autoload` on the defun** (target = the original file): removing the defun changes
    the target, so REMOVE the cookie from the moved defun and add a façade redirect
    `;;;###autoload (autoload 'CMD "ogent-<base>" nil t)` so the target stays the original filename.
  Gate item 3 below diffs the regenerated loaddefs: the cookied-symbol SET and each symbol's load
  TARGET must be byte-identical to baseline. Per file: zen keeps 34/39 cookies in the façade (5 moved
  → redirect to `"ogent-zen"`); ui-cabinet's 17 view commands keep their current targets (the manual
  `"ogent-ui-cabinet"` redirects stay in the façade, cookies off the moved defuns); ui's **14 cookied
  symbols** keep their exact current targets (`ogent-request`/`ogent-ask-menu`/`ogent-prompt-dispatch`
  → `"ogent"`; `ogent-navigate`/`ogent-ask-here`/file-target cookies → `"ogent-ui"`) — distinct from
  the **11 runtime `(autoload …)`** prelude forms (lines 69–79) which travel to whichever submodule
  references the external symbol; issues keeps its single `ogent-issues` cookie in the façade.
- **One move per commit:** create sibling file, move a cluster's defs verbatim, apply the autoload
  rule above, add `(provide)`, add the façade `(require)` in dependency order, regenerate autoloads,
  run gate, commit. Never combine a move with a rename/reformat.

## Scoring rubric (1–5, 5 = best); elisp notes

| Axis | Meaning here |
|------|--------------|
| **Iso-risk** | confidence the move is behavior/surface/load-order identical (5 = trivially safe) |
| **Perf** | runtime delta — elisp UI code, no hot loops → ~always 5 (façade adds only load-time `require`s) |
| **Compile-res** | byte-compile time + peak; many small files = same total, better *incremental* recompile |
| **Ergonomics** | agent/human navigability: file size, 1 concern/file, greppability |
| **Blast radius** | size/containment of each move's diff |
| **Reviewability** | how easily a reviewer verifies a move is mechanical |
| **Maintainability** | long-term: where new code obviously goes, test locality |

---

## 1. ogent-ui-cabinet.el → WINNER: Candidate A (core + 9 view siblings + façade; 10 buffer surfaces)

3670 LOC / 273 defs / 17 autoloads → 11 files (lisp/ui/). Decisive fact: **no per-view
`defvar-local` is shared across views**; cross-view wiring is autoloaded symbols ⇒ acyclic
core→view→façade. Matches the project's flat-sibling idiom 1:1 (like the `ogent-cabinet-*` family).

| New file (lisp/ui/) | Clusters | ~LOC | provide | requires | autoloads |
|---|---|---|---|---|---|
| `ogent-ui-cabinet-core.el` | prelude+custom+const+state+helpers (3 macros, magit gate, section nav, insert helpers) | ~870 | `ogent-ui-cabinet-core` | external only (cl-lib, org, magit-section eval-and-compile, ogent-cabinet*, tabulated-list, transient) | — |
| `ogent-ui-cabinet-home.el` | Home cockpit + transient | ~414 | …`-home` | core | home, home-dispatch |
| `ogent-ui-cabinet-agents.el` | AgentList | ~131 | …`-agents` | core | agents |
| `ogent-ui-cabinet-org-chart.el` | OrgChart | ~73 | …`-org-chart` | core | org-chart |
| `ogent-ui-cabinet-agent.el` | AgentProfile + AgentMgmt | ~427 | …`-agent` | core | agent, create-agent, clone-agent, archive-agent |
| `ogent-ui-cabinet-jobs.el` | Jobs | ~261 | …`-jobs` | core | jobs, create-job |
| `ogent-ui-cabinet-tasks.el` | Tasks | ~493 | …`-tasks` | core | tasks, create-task |
| `ogent-ui-cabinet-conversations.el` | ConvList + ConvDetail (kept together — bidirectional) | ~714 | …`-conversations` | core | conversations, conversation |
| `ogent-ui-cabinet-search.el` | Search | ~84 | …`-search` | core | search |
| `ogent-ui-cabinet-apps.el` | Apps | ~111 | …`-apps` | core | apps, open-app |
| `ogent-ui-cabinet.el` (façade) | Bootstrap (setup-section-keymaps + evil/magit quartet) + provide | ~90 | `ogent-ui-cabinet` | core + all 9 views | — |

Autoload tally moved: 2+1+1+4+2+2+2+1+2 = **17** (unchanged set).

**Façade structure:** `(require 'ogent-ui-cabinet-core)` → 9 view requires (any order; all need only
core) → move `ogent-cabinet-ui--section-keymaps`/`--setup-section-keymaps` + evil quartet
(`--evil-mode-map`/`--evil-local-keys`/`--evil-mode-specs`/`--setup-evil`) into façade (they enumerate
ALL modes) → top-level `(setup-section-keymaps)` + both `with-eval-after-load` → `(provide)`.

**Migration order (one move per commit):**
1. Extract `-core` (must be first — every view requires it; the `define-section-mode`/`with-section`
   macros + magit-availability `eval-and-compile` defvar must be compile-visible). Façade
   `(require 'ogent-ui-cabinet-core)`. Gate.
2–10. Extract each view (agents, org-chart, search, apps, jobs, tasks, agent, home, conversations).
   Smallest/leaf-first (search, apps, agents, org-chart) → larger (jobs, tasks, agent, home) →
   conversations last (largest, keeps ConvList+ConvDetail together). Add façade `require`; gate each.
11. Move bootstrap + evil/magit quartet to façade; verify `(setup-section-keymaps)` runs after all
    view requires; gate.

**Top risks (from findings §6):** (a) every view file must `(require 'ogent-ui-cabinet-core)` at top
level so `define-section-mode` expands with the right parent mode (magit-availability read at
expansion — wrong → section folding silently lost); (b) the hand-written transient autoload literal at
**line 1227** already targets the façade `"ogent-ui-cabinet"` — **keep it verbatim in the façade**
(move `ogent-cabinet-home-dispatch`'s defun to the home sibling WITHOUT a cookie; do NOT retarget to
`"ogent-ui-cabinet-home"`, which would skip the façade bootstrap on cold invoke);
`ogent-ui-cabinet-conversations` must not collide with external `ogent-cabinet-conversations`;
(d) views never `require` each other (keep autoload+`fboundp` guard on `jobs--goto`@1183);
(e) keep `defgroup ogent-ui-cabinet` + 11 customs + 4 faces in core.

**Runner-up: Candidate B (core + 4 domain groups + façade)** — agents(List+OrgChart+Profile+Mgmt) /
work(Jobs+Tasks) / conversations / home(+Search+Apps). Fewer files + fewer `declare-function` edges,
larger units. Choose B if file-count is a concern; A chosen for 1:1 view↔file ergonomics + smallest
blast radius, matching the existing idiom.

| Candidate | Iso-risk | Perf | Compile-res | Ergonomics | Blast | Review | Maint | Notes |
|---|---|---|---|---|---|---|---|---|
| **A (winner)** | 5 | 5 | 5 | 5 | 5 | 5 | 5 | acyclic, no shared state, 1 concern/file |
| B (runner-up) | 5 | 5 | 5 | 4 | 4 | 4 | 4 | coarser; fewer edges but bigger files |

---

## 2. ogent-zen.el → WINNER: Candidate A (core + 3 leaves + façade), evolve to B

3897 LOC / 303 defs / 39 autoloads → 5 files (lisp/). zen has **no top-level side effects** (only
`declare-function`), so load-time placement is trivial; the only ordering rule is `cl-defstruct`
compile-visibility. A peels the 3 concerns with distinct *external* deps; the cohesive
presentation+review engine stays in the façade for a low-risk first pass.

| New file (lisp/) | Clusters | ~LOC | provide | requires | autoloads |
|---|---|---|---|---|---|
| `ogent-zen-core.el` | base tower: predicates, status-parse, formatters, generic render utils, title helpers, scope primitives; `defgroup`+21 customs+4 faces; `cl-defstruct ogent-zen-scope` | ~600 | `ogent-zen-core` | cl-lib, org, org-element, subr-x | — |
| `ogent-zen-tools.el` | tool-call store + `cl-defstruct ogent-zen-tool-record` + inspection buffer/major-mode + store-readers | ~290 | `ogent-zen-tools` | `ogent-zen-core` (+`declare-function ogent-zen-refresh-at`) | show-tool-calls (1) |
| `ogent-zen-workspace.el` | workspace/context inference | ~286 | `ogent-zen-workspace` | `ogent-zen-core`, `ogent-context` | — |
| `ogent-zen-edit.el` | inline-edit + `cl-defstruct ogent-zen-edit-preview` | ~280 | `ogent-zen-edit` | `ogent-zen-core`, `inline-diff` | apply-last-edit, accept-edit, reject-edit, copy-response (4) |
| `ogent-zen.el` (façade) | render bulk+overlay+animation+folding+quiet-bullets+margins+minor-mode+scope cmds+transcript+review read/write/dashboard+run | ~2400 | `ogent-zen` | core, tools, workspace, edit, ogent-ui-theme | 34 (kept in façade) |

**Façade require order:** core → tools → workspace → edit → ogent-ui-theme; then façade defuns; then
`(provide 'ogent-zen)`. `cl-defstruct`: scope→core, edit-preview→edit, tool-record→tools (each in a
file its users `require`). The one upward edge (tools `--refresh-request-safe` → façade `refresh-at`)
stays a `declare-function` (façade loaded before any tool call). **Autoloads:** 34 stay in the façade
(cookies unmoved); the 5 moved (tools 1 + edit 4) take façade redirect forms per the contract —
strictly, zen has no façade side effects so changed targets would also be safe, but redirects keep
the rule uniform and the loaddef target stable.

**Migration order (one move per commit):** 1) core (first — everything requires it; scope struct +
customs/faces). 2) tools (new feature; cleanest seam — its own buffer/mode/state). 3) workspace.
4) edit. 5) façade cleanup (requires + redirect forms + provide). Gate after each.

**Cycle landmine:** NEVER `(require 'ogent-ui)`/`(require 'ogent-completions)` in any zen sibling —
keep `declare-function` (`ogent-ui--dispatch-request`, `ogent-status--get-face`, `ogent-completion-*`).

**Runner-up: Candidate B (8 files)** — additionally extract `ogent-zen-review.el` (~700 LOC, 22
autoloads, self-contained OGENT_* state machine + dashboard) and `ogent-zen-render.el` (~930 LOC).
Best ROI evolution: after A lands, extract review (highest value), then render. Cost: render↔tools and
folding→review become `declare-function` edges; title helpers must sit in core.

| Candidate | Iso-risk | Perf | Compile-res | Ergonomics | Blast | Review | Maint | Notes |
|---|---|---|---|---|---|---|---|---|
| **A (winner, pass 1)** | 5 | 5 | 5 | 3 | 5 | 5 | 4 | façade still ~2400 LOC (engine+review remain) |
| B (evolution) | 4 | 5 | 5 | 5 | 4 | 4 | 5 | full modularity; +2 cross-module declare edges |

---

## 3. ogent-ui.el → WINNER: Candidate A (8-file layered), evolve to B

3637 LOC / 245 defs / 14 autoloads → 8 files (lisp/ui/). **2 HARD load-time side effects** (response-
function migration @1644; gptel hook @2148) → both in the façade. CORE = one small state contract
(request table/seq/history, dispatcher selections, transient-prompt, response-function indirection).

| New file (lisp/ui/) | Clusters | ~LOC | provide | requires (intra) | autoloads |
|---|---|---|---|---|---|
| `ogent-ui.el` (façade) | — (hosts both load-time forms) | ~135 | `ogent-ui` | core, format, toolcalls, engine, send, preview, dispatch | redirect forms for all moved cmds |
| `ogent-ui-core.el` | CORE: request struct, central state, cross-cut customs/consts, render-prompt, scope helpers | ~150 | `ogent-ui-core` | cl-lib, ogent-core; **+ `declare-function` stubs** for `ogent-ui-insert-response-block` (format) & `ogent-ui-prepare-response-block` (engine) — function-quoted by `ogent-response-function`/`--set-response-function` but cannot be `require`d (cycle) | — |
| `ogent-ui-format.el` | E org-formatting + D window/scroll | ~180 | `ogent-ui-format` | core, org (zen via declare) | — |
| `ogent-ui-toolcalls.el` | F tool-exec + G tool-drawer + H inline-diff (kept whole) | ~930 | `ogent-ui-toolcalls` | core, format, ogent-tool-approval, ogent-ledger, ogent-edit-format | — |
| `ogent-ui-engine.el` | C conversation engine + J errors + K cancel/pause/retry | ~925 | `ogent-ui-engine` | core, format, toolcalls, ogent-context, ogent-models, ogent-gptel, ogent-ledger, ogent-provider-fallback, ogent-ui-status | abort/pause/resume/retry, show-errors, clear-errors |
| `ogent-ui-send.el` | B request build & send | ~275 | `ogent-ui-send` | core, engine, ogent-context, ogent-models, ogent-gptel | ogent-request |
| `ogent-ui-preview.el` | I context preview | ~325 | `ogent-ui-preview` | core, format, ogent-context, ogent-core | context-preview(+toggle), ask-context-preview-toggle |
| `ogent-ui-dispatch.el` | A dispatcher/transient + provider eieio class | ~510 | `ogent-ui-dispatch` | core, send, preview, ogent-ui-theme, transient | ask-menu, prompt-dispatch, navigate + 14 top external autoloads |

**Façade require order:** core → format → toolcalls → engine → send → preview → dispatch; THEN
load-time form 1 (needs core+format+engine) and form 2 (needs engine); THEN provide. **Autoloads MUST
route through the façade** here (the 2 hard side effects make a cold `M-x ogent-request` that loads
only `ogent-ui-send` wrong): use redirect forms `;;;###autoload (autoload 'CMD "ogent-ui" …)` in the
façade for every moved command.

**Migration order:** core → format → toolcalls (keep F+G+H together — dodges the F↔H question) →
engine → send → preview → dispatch → façade (forms + redirects). Gate each.

**Runner-up: Candidate B (13 files)** — splits tools 3-way (drawer/tools/diff), peels errors, control,
scroll. Requires relocating the test-only orphan `ogent-ui--handle-tool-calls` (2243–2298, no
production caller) into the diff module to make `drawer←tools←diff` acyclic. Best long-term cohesion;
+~30 redistributed `declare-function`s. Evolve to B after A if smaller modules are wanted.

| Candidate | Iso-risk | Perf | Compile-res | Ergonomics | Blast | Review | Maint | Notes |
|---|---|---|---|---|---|---|---|---|
| **A (winner, pass 1)** | 5 | 5 | 5 | 3 | 4 | 4 | 4 | engine(~925)+toolcalls(~930) stay large |
| B (evolution) | 4 | 5 | 5 | 5 | 4 | 4 | 5 | needs handle-tool-calls relocation (cycle break) |

---

## 4. ogent-issues.el → WINNER: Candidate B (conservative 3-satellite), evolve to A

2091 LOC / 154 defs / 1 autoload → 4 files (lisp/). The list-buffer core is irreducibly cohesive
(4 shared `defvar-local` state vars: `--current-view/--filters/--issues/--loading*` + the 3
magit-section eieio classes). B peels only the 3 genuinely low-coupling satellites and leaves the
state-coupled core **byte-for-byte in place** (no `defvar-local` re-plumbing) — lowest risk, ~30%
reduction.

| New file (lisp/) | Clusters | ~LOC | provide | requires (intra) | autoloads |
|---|---|---|---|---|---|
| `ogent-issues.el` (façade + list core) | C0–C11, C15–C18 (state quartet, eieio classes, mode, keymap, header, format, render, nav, refresh, filter, commands, views) | ~1460 | `ogent-issues` | ogent-issues-bd, ogent-ops-style, magit-section (soft); requires the 3 satellites at EOF | keeps `ogent-issues` cookie (unmoved) + dispatch/create/filter external autoloads |
| `ogent-issues-detail.el` | C12 detail mode/render + C13 detail utils + C14 detail actions | ~434 | `ogent-issues-detail` | `cl-lib`, `subr-x`, `iso8601`, `ogent-ops-style`, `ogent-issues-bd`; `declare-function` for façade C9 helpers (`--issue-ready-p`, `--priority-indicator`, `--status-label/-face`, `--ready-indicator`); `defvar` declares for core-owned specials/customs it reads (`ogent-issues-use-unicode`, `-detail-auto-refresh`, `-detail-display-action`) + the `ogent-issues-*` faces it uses | — |
| `ogent-issues-kanban.el` | C19 kanban board + C20 graph hand-off | ~210 | `ogent-issues-kanban` | `cl-lib`, `subr-x`, `ogent-issues-bd`; `declare-function` for C9/C10/C11/C15 helpers (`--group-by-status`, `--status-face`, `--current-issue`, `ogent-issues-refresh`, `--start/stop-loading`); `defvar` declares for any core state it reads | graph-view (external autoload travels here) |
| `ogent-issues-evil.el` | C21 evil setup (self-registers via `with-eval-after-load 'evil`) | ~55 | `ogent-issues-evil` | `declare-function` mode-maps/hooks from core (`ogent-issues-mode-map`, `-detail-mode-map`, + hooks); no hard require (callback fires after evil loads) | — |

**Cycle break (decisive):** satellites must NOT `(require 'ogent-issues)` (mutual require with the
façade's EOF requires). Per findings, the clean break: **satellites `declare-function` the façade's
C9 format helpers** they call; the façade is the only `require` site (requires satellites at EOF,
after all C9 defuns + keymaps exist). All satellite refs to core are inside `defun`/hook bodies
(runtime), so EOF requires are safe.

**Load-time / eieio:** the 3 `defclass` (magit-section subclasses) + `eval-and-compile`
`--magit-section-available` stay in the façade core (consumed at macro-expansion by `magit-insert-
section` sites). `(ogent-issues--define-mode)` macro+call + `(add-hook 'ogent-issues-mode-hook …)`
stay together in core. The single `;;;###autoload (ogent-issues)` STAYS in the façade (no redirect
needed — target unchanged). Preserve the deliberate `(eq (eieio-object-class-name …) '…-issue-section)`
pattern (do NOT modernize to `cl-typep`).

**Migration order (each satellite move is ONE gated commit that ALSO adds its own façade EOF
`require` + the façade's `declare-function` for that satellite's entry point — so `(require
'ogent-issues)` loads the moved code and its load-time side effect runs at every gate, not only at
the end):** 1) evil (smallest, self-registering leaf; its `with-eval-after-load 'evil` registration
must be reachable on feature load → add `(require 'ogent-issues-evil)` to the façade EOF in the same
commit). 2) kanban (+graph autoload; add façade EOF require + declares same commit). 3) detail (single
inbound `-visit`→`--show-detail` via façade `declare-function`; add façade EOF require same commit).
4) final pass: verify the full façade `declare-function` set + loaddefs target diff. Gate each commit.

**Runner-up: Candidate A (6 modules: common/sections/core/detail/kanban/evil)** — true modularity
(largest file ~770 LOC) but moves C9 Format utils into a shared `common` to break the core↔detail
cycle and adds two `eval-and-compile (require 'ogent-issues-sections)` edges. Evolve to A only if the
list core itself must be modularized.

| Candidate | Iso-risk | Perf | Compile-res | Ergonomics | Blast | Review | Maint | Notes |
|---|---|---|---|---|---|---|---|---|
| **B (winner, pass 1)** | 5 | 5 | 5 | 3 | 5 | 5 | 4 | core untouched in place; ~1460 LOC façade remains |
| A (evolution) | 4 | 5 | 5 | 5 | 3 | 3 | 5 | needs `common` layer + C9 relocation + eval-and-compile edges |

---

## 5. ogent-cabinet.el → LEAVE-ALONE (B11 justified monolith)

1743 LOC / 109 defs / 25 requirers. **Do not split.** Grounded positively: 100% of defs are Cabinet
Org-file storage operations (agent 28% / kernel 20% / job 15% / index+root 9% / session 9% / search
8% / app+graph 6% / import 4%); **no internal mutable state, no macros, no eieio**; coupling is
*essential* via a universal helper kernel (C1) + one directory-layout schema (C2) every record model
is defined in terms of, and consumers reach 68× into private `--` helpers. Aggregators (overview,
build-graph) exist to bind all models → cannot be lifted out. No clean 600–800 LOC carve-out exists
(the most-shared subset, kernel+path+root, is only ~318 LOC). Size alone is the only split argument,
and the contract forbids line count as justification.

**Deferred option (NOT scheduled):** if a split is ever forced, the single most-justified seam is
Candidate A′ — extract C1+C2+C3 (~318 LOC) into `ogent-cabinet-store.el` behind the façade (façade
requires it first; move only the `global-agents-root` defcustom with it to avoid a cycle; keep
`defgroup` + other customs + both autoloads + the `with-eval-after-load 'org` form in the façade).
Recorded as a backlog bead, not part of this de-monolithization.

---

## Summary

| File | LOC | Verdict | Files after (winner) | Largest after | Risk |
|------|-----|---------|----------------------|---------------|------|
| ogent-ui-cabinet.el | 3670 | should-split | 11 (core+10 views+façade) | ~870 (core) | low (acyclic, no shared state) |
| ogent-zen.el | 3897 | should-split | 5 (A); →8 (B) | ~2400 façade (A) | low (A), med (B) |
| ogent-ui.el | 3637 | should-split | 8 (A); →13 (B) | ~930 (toolcalls/engine) | low (A), med (B) |
| ogent-issues.el | 2091 | should-split | 4 (B); →6 (A) | ~1460 façade (B) | very low (B) |
| ogent-cabinet.el | 1743 | **leave-alone (B11)** | 1 (unchanged) | 1743 | n/a |

Total new sibling files (winners): 10 (ui-cabinet) + 4 (zen) + 7 (ui) + 3 (issues) = **24 new files**,
4 façades rewritten, `ogent.el` untouched. Cross-file work: cosmetic zen↔ui `declare-function`
hint-sync if both are split. Every move gated by `make test` (2583/7-skip) + no-new-byte-compile-
warning + union-surface-diff + autoload-target-diff.

Order of execution (independent; recommended by ROI/safety): **ui-cabinet (cleanest, highest LOC win)
→ issues-B (lowest risk) → zen-A → ui-A**, then optional evolutions (zen-B review/render, ui-B,
issues-A) as separate follow-ups. cabinet untouched.
