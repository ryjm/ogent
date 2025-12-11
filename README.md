# ogent

ogent is an experimental Emacs extension for building technical knowledge bases inside Org-mode. Think of it as a Cursor clone for Emacs where the Org buffer is simultaneously the agent panel and the reified plan document. It borrows prompting ergonomics from `gptel` and structural ideas from `org-roam`, but keeps the mental model of Org subtrees front and center so contributors can curate hierarchical context before sending it to a model.

## Mission
- Treat every Org subtree as an addressable, shareable block of technical knowledge.
- Allow writers to compose prompts by referencing those blocks with an `@handle`.
- Organize prompt context explicitly as Org hierarchies so contributors can reason about scope before querying a model.
- Expand context beyond the current document by referencing other buffers, files, or folders, while keeping the final payload grounded in the subtree you are editing.
- Translate the curated hierarchy into the full context for completions and clearly summarize what will be sent to the model.
- Every buffer in which we invoke `ogent` should either be in `org-mode` or linked to a corresponding `org-mode` buffer. Again, think of the `org-mode` buffer `ogent` is operating in as both the agent panel and plan document ala Cursor. 

## Key Concepts
- **Atomic subtrees**: Any subtree can declare an `OGENT_ID` or use the headline title as its handle. Within sibling or descendant headings, reference another subtree by typing `@handle`. ogent resolves the reference, injects its content into the prompt, and keeps backlinks so you can audit provenance.
- **Context scoping**: Invoking `M-x ogent-request` collects the current heading, all ancestor headings, and any `@handle` dependencies into a structured payload. Handles can point to other buffers or Org-roam files, so the request can include folders that “fill out” missing knowledge while still rooting the prompt in the active subtree.
- **Context summary**: Before dispatching, ogent renders a collapsible Org summary (e.g., `ogent-context-preview`) showing the headings, referenced files, and character counts being sent. Contributors can expand subtrees to audit what the model will see without having to read the entire payload.
- **Prompt templates**: Users can store reusable AI instructions inside dedicated “Prompt” subtrees. Because they are just Org nodes, the same `@handle` syntax applies.
- **Native Agent**: Each buffer acts as both the chat surface and the canonical plan—responses appear inline, can be edited like any Org node, and remain linked to their source prompts so the evolving document stays in sync with agent output. This is the most important concept of `ogent` - it should act as a homunculus that can be instantiated at any point in your Emacs workflow. 
- **Codemaps**: ogent can scan the repository (or referenced folders) to synthesize “codemaps” that resemble Windsurf’s maps. Each codemap is an Org subtree listing modules, entry points, and data flows with bullet links back to files (e.g., `[[file:lisp/ogent-context.el::ogent-context-build][context builder]]`). Use `C-c o m` to refresh the map so contributors always see a high-level architecture next to the agent transcript.
- **Model registry**: `lisp/ogent-models.el` lists every supported gptel backend (id, preset, stream support). The dispatcher and transport stack look up this registry so adding a provider is a data change plus tests, not a UI surgery.

## Prompt Capture & Formatting
- **Command palette**: `C-c o p` (`ogent-prompt-dispatch`) opens a transient that lets you pick one or more models, select prompt templates, and send the current subtree context with a single keystroke.
- **Src block insertion**: Immediate completions land inside a language-aware `#+begin_src` block (`ogent-src-backend`). Hit `C-c C-c` to execute or reify the block directly in place.
- **Notes capture**: Press `C-c C-d` on a completion snippet to shunt it beneath the current subtree inside a collapsed `Notes` headline, keeping speculative ideas separate from canonical content.
- **Multi-model fan-out**: Selecting multiple providers triggers concurrent gptel requests via the registry; each response streams into its own src block tagged with model/backend metadata so you can compare answers side-by-side without blocking.
- **Ergonomic review**: `C-c o n` cycles focus across pending completions, while `C-c o a` accepts the highlighted block and automatically removes transient metadata drawers.
- **Context hydration**: The dispatcher remembers which external documents, folders, or handles you attached to the current subtree and offers a `C-c o c` toggle to reuse or clear that context when issuing follow-up prompts.

## Codemap Overview
- `M-x ogent-codemap-buffer` (bound to `C-c o m`) analyzes the repository or selected folders, extracts public definitions, and emits an Org subtree titled “Codemap”. Each entry includes inline links such as `[[file:lisp/ogent-context.el::ogent-context-build][Context Builder]]` so you can jump straight to the code.
- Codemaps update incrementally: rerun the command to refresh sections impacted by recent changes while preserving manual annotations.
- The codemap subtree doubles as a navigational aid and a prompt attachment—mark it with an `OGENT_ID` (`OGENT_ID: codemap-core`) and reference it via `@codemap-core` whenever you want the model to understand the project layout.
- Inspired by Windsurf’s codemaps, ogent surfaces data-flow descriptions (“`ogent-prompt-dispatch -> ogent-context-build -> gptel-send`”) directly under each bullet, so the map reads like an architecture digest next to your agent transcript.

## Planned Workflow
1. Author Org content as usual, tagging reusable sections with unique `OGENT_ID`s.
2. Reference needed sections inline (`The overview lives in @overview-block`) to shape the context hierarchy.
3. Run `M-x ogent-request` (or `C-c o p`) to send the current tree plus referenced blocks—and any attached external documents—to the selected model(s) via `gptel`, reviewing the context summary before dispatch.
4. Evaluate each src block (`C-c C-c`) or archive it as a `Notes` child (`C-c C-d`), then promote accepted knowledge into the permanent subtree structure.

## Doom Emacs

For Doom Emacs users, ogent provides an idiomatic configuration with keybindings under `SPC e`. See the full guide at [docs/doom-emacs.md](docs/doom-emacs.md).

**Quick start** - add to `~/.doom.d/packages.el`:

```elisp
(package! ogent :recipe (:local-repo "~/path/to/ogent/lisp"
                         :files ("*.el" "ui/*.el")))
```

Then run `doom sync` and add keybindings to `~/.doom.d/config.el`:

```elisp
(use-package! ogent
  :defer t
  :commands (ogent-mode ogent-prompt-dispatch ogent-request)
  :init
  (map! :leader
        (:prefix ("e" . "ogent")
         :desc "Prompt dispatch" "e" #'ogent-prompt-dispatch
         :desc "Send request"    "r" #'ogent-request
         :desc "Toggle mode"     "t" #'ogent-mode)))
```

## AI & Knowledge Sources
- **LLM backend**: ogent leans on `gptel`'s transport layer for streaming completions, credentials, and model selection.
- **Graph awareness**: Inspired by `org-roam`, ogent can query a local Org-roam database to resolve `@handle`s across files, making long-lived knowledge bases available to every buffer.

## gptel Integration Status
- Dynamic dispatcher buttons are generated from `ogent-models.el`, so contributors can define additional providers without editing UI code.
- `ogent-request` now streams responses chunk-by-chunk through gptel callbacks, inserting placeholder `#+begin_src` blocks and closing them when completions finish or error.
- Specs live under `specs/gptel/` (`overview.org`, `gptel-integration.org`) and describe how we bridge presets, backends, and streaming hooks. Read them before adjusting transport behavior.
- `ogent-ui--ensure-gptel` auto-loads every feature listed in `ogent-gptel-required-features`, so when you add a provider extend both the registry entry and that defcustom to guarantee the backend structs exist before dispatch.
- Remaining tasks (tracked in docs and roadmap):
  - Surface gptel’s FSM status/latency inside the Org buffer header line.
  - Wire gptel highlight + tool-call UI so reasoning/tool blocks render inline.
  - Support cancellation/resume controls and richer error reporting.
  - Document backend/preset configuration in the user-facing guides.

## Roadmap
- **Core UX**
  - Flesh out minor-mode affordances (`ogent-ask`, `ogent-open-block`, richer `ogent-context-preview` interactions).
  - Expand codemap coverage (link UI nodes back to specs/tests, expose incremental refresh APIs).
  - Ship a default prompt schema plus reusable Org snippets for common AI workflows.
- **gptel Transport**
  - Expose preset toggles + per-backend settings in the dispatcher (read/edit `ogent-models.el`).
  - Bubble up gptel FSM status (waiting/typing/errored) and cancellation commands inside Org buffers.
  - Render reasoning/tool-call blocks using the same markers as `gptel-mode`, including highlight overlays.
  - Provide docs covering API key management, `gptel-make-preset` usage, and how to register custom providers.
- **Testing**
  - Continue expanding fixture coverage (streaming edge cases, error injection, preset application).
  - Exercise multi-model fan-out with mocked gptel streams to guard against regressions.
