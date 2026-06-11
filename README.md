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
- **Context scoping**: Invoking `M-x ogent-request` collects the current heading, all ancestor headings, and any `@handle` dependencies into a structured payload. Handles can point to other buffers or Org-roam files, letting the request include folders that "fill out" missing knowledge while still rooting the prompt in the active subtree.
- **Context preview**: Before dispatching, ogent renders the same hydrated payload it will send to the model, including the root subtree, resolved `@handle` content, source buffer or region, and pins.
- **Prompt templates**: Users can store reusable AI instructions inside dedicated "Prompt" subtrees. Because they are just Org nodes, the same `@handle` syntax applies.
- **Native Agent**: Each buffer acts as both the chat surface and the canonical plan. Responses appear inline, can be edited like any Org node, and remain linked to their source prompts, keeping the evolving document in sync with agent output. This is the most important concept of `ogent`: it should act as a homunculus that can be instantiated at any point in your Emacs workflow.
- **Codemaps**: ogent can scan the repository (or referenced folders) to synthesize "codemaps" that resemble Windsurf's maps. Each codemap is an Org subtree listing modules, entry points, and data flows with bullet links back to files (e.g., `[[file:lisp/ogent-context.el::ogent-context-build][context builder]]`). Use `C-c . m` to refresh the map, giving contributors a high-level architecture next to the agent transcript.
- **Model registry**: `lisp/ogent-models.el` lists every supported gptel backend (id, preset, stream support). The dispatcher and transport stack look up this registry so adding a provider is a data change plus tests, not a UI surgery.
- **Org Armory OS**: `ogent-armory-scaffold` creates Armory-style knowledge bases as Org files, then `ogent-armory-home` (`C-c . j`, `SPC o j`) opens the operational home view. From there a user can manage agents, jobs, tasks, conversations, search, generated app artifacts, and the graph/status projection. All durable records stay in Org, including personas, jobs, transcripts, imports, and metadata edits.

## Prompt Capture & Formatting
- **Command palette**: `C-c . p` (`ogent-prompt-dispatch`) opens a transient that lets you pick one or more models, select prompt templates, and send the current subtree context with a single keystroke. Doom/Evil users get the same surface under `SPC o`.
- **AI speed edit**: `C-c . v` (`SPC o v` in Doom/Evil) lets the model choose the highest-value small edit from the active selection, point context, and editor diagnostics, then routes the patch through the inline review flow.
- **Diagnostic repair**: `C-c . f` (`SPC o f` in Doom/Evil) grabs the Flymake or Flycheck diagnostic at point, builds a focused repair prompt, and applies the result through the inline edit review flow.
- **Buffer diagnostic sweep**: `C-c . F` (`SPC o F` in Doom/Evil) ranks every Flymake or Flycheck diagnostic in the current buffer and requests one reviewable repair patch.
- **Quick inline edit**: `C-c . k` (`SPC o k` in Doom/Evil) prompts for one instruction and targets the active region, current definition, or current line. Use a prefix argument for full-file edits.
- **Src block insertion**: Immediate completions land inside a language-aware `#+begin_src` block. Hit `C-c C-c` to execute or reify the block directly in place.
- **Notes capture**: Press `C-c . d` on a completion snippet to shunt it beneath the current subtree inside a collapsed `Notes` headline, keeping speculative ideas separate from canonical content.
- **Multi-model fan-out**: Selecting multiple providers triggers concurrent gptel requests via the registry; each response streams into its own src block tagged with model/backend metadata so you can compare answers side-by-side without blocking.
- **Ergonomic review**: `C-c o n` / `C-c o p` cycle through completions, `C-c o a` accepts the current one (deleting others), and `C-c o x` rejects it. Visual feedback dims non-current completions and optionally folds them.
- **Context hydration**: The dispatcher resolves referenced `@handles`, includes their content in the model payload, and offers a `C-c . c` preview of that payload before dispatch.

## Codemap Overview
- `M-x ogent-codemap-buffer` (bound to `C-c . m`) analyzes the repository or selected folders, extracts public definitions, and emits an Org subtree titled "Codemap". Each entry includes inline links such as `[[file:lisp/ogent-context.el::ogent-context-build][Context Builder]]` for direct jumps to the code.
- Codemaps update incrementally: rerun the command to refresh sections impacted by recent changes while preserving manual annotations.
- The codemap subtree doubles as a navigational aid and a prompt attachment. Mark it with an `OGENT_ID` (`OGENT_ID: codemap-core`) and reference it via `@codemap-core` whenever you want the model to understand the project layout.
- Inspired by Windsurf's codemaps, ogent surfaces data-flow descriptions ("`ogent-prompt-dispatch -> ogent-context-build -> gptel-send`") directly under each bullet, making the map read like an architecture digest next to your agent transcript.

## Planned Workflow
1. Author Org content as usual, tagging reusable sections with unique `OGENT_ID`s.
2. Reference needed sections inline (`The overview lives in @overview-block`) to shape the context hierarchy.
3. Run `M-x ogent-request` (or `C-c . p`) to send the current tree plus referenced blocks, and any attached external documents, to the selected model(s) via `gptel`, reviewing the hydrated payload before dispatch.
4. Evaluate each src block (`C-c C-c`) or archive it as a `Notes` child (`C-c C-d`), then promote accepted knowledge into the permanent subtree structure.

## Doom Emacs

For Doom Emacs users, ogent provides an idiomatic configuration with keybindings under `SPC o`. See the full guide at [docs/doom-emacs.md](docs/doom-emacs.md).

**Quick start** - add to `~/.doom.d/packages.el`:

```elisp
(package! ogent :recipe (:local-repo "~/path/to/ogent/lisp"
                         :files ("*.el" "ui/*.el")))
```

Then run `doom sync` and add this to `~/.doom.d/config.el`:

```elisp
(use-package! ogent
  :defer t
  :commands (ogent-mode ogent-prompt-dispatch ogent-request
             ogent-ai-speed-edit)
  :init
  (setq ogent-enable-doom-bindings t
        ogent-doom-prefix "o")
  :config
  (ogent-setup-doom-bindings)
  (ogent-global-mode 1))
```

## Armory Home

`M-x ogent-armory-home` is the Armory entry point. It opens a native Emacs dashboard backed by `index.org` and `.agents/**.org` records. The home view shows metadata, health counts, recent activity, failed work, stale jobs, missing persona fields, app artifacts, and navigation to the rest of the Armory.

`M-x ogent-armory-tasks` opens the Armory task board. Press `c` or `C-c c` there to capture a manual task into Inbox with a short TODO-style prompt path.

`M-x ogent-armory-compose` and `M-x ogent-armory-compose-buffer` run agents from a shared composer with `@agent:`, `@page:`, `@skill:`, `@job:`, and `@conversation:` mentions. Attachments are staged into the canonical conversation folder, and `M-x ogent-armory-skills` opens the Org-backed skill catalog. Agents now support local, global, and visible-armory resolution, department/type identity, skill selections, runtime inheritance, and lead action approvals through `M-x ogent-armory-actions`.

Common commands:

| Key | Command |
|-----|---------|
| `RET` | Visit the item at point |
| `TAB` | Collapse or expand the section at point |
| `M-n` / `M-p` | Move between sibling sections |
| `<backtab>` | Cycle section visibility |
| `C-c u` | Move to the parent section |
| `C-c m` | Open the Home transient menu |
| `C-c ?` | Open Home help |
| `C-c g` | Refresh |
| `q` | Quit |
| `C-c j` | Jobs |
| `C-c J` | Jobs related to the item at point |
| `C-c r` | Run or retry the selected job, agent, or conversation |
| `C-c E` | Edit the selected agent persona, job prompt, or source record |
| `C-c a` | Agents |
| `C-c t` | Tasks |
| `C-c c` | Conversations |
| `C-c s` | Search |
| `C-c A` | Apps |
| `C-c G` | Graph/status |
| `C-c e` | Edit Armory metadata |
| `C-c n` / `C-c p` | Move between actionable rows |

In Evil normal state, bare Vim navigation/search keys keep their Evil meanings. Armory display actions use the `C-c` chords above, while `RET`, `TAB`, `M-n`/`M-p`, `q`, `ZZ`, and `ZQ` remain available where documented.

The main ogent dispatch bindings include:

| Key | Command |
|-----|---------|
| `C-c . j` / `SPC o j` | `ogent-armory-home` |
| `C-c . K` / `SPC o K` | `ogent-armory-status` |
| `C-c . y` / `SPC o y` | `ogent-armory-agents` |
| `C-c . Y` / `SPC o Y` | `ogent-armory-agent` |
| `C-c . B` / `SPC o B` | `ogent-armory-org-chart` |
| `C-c . I` / `SPC o I` | `ogent-armory-tasks` |
| `C-c . O` / `SPC o O` | `ogent-armory-conversations` |
| `C-c . N` / `SPC o N` | `ogent-armory-actions` |
| `C-c . V` / `SPC o V` | `ogent-armory-search` |
| `C-c . W` / `SPC o W` | `ogent-armory-apps` |
| `C-c . X` / `SPC o X` | `ogent-armory-create-agent` |
| `C-c . Z` / `SPC o Z` | `ogent-armory-create-job` |

See [docs/armory.org](docs/armory.org) for the first-ten-minutes workflow and import limits.

## AI & Knowledge Sources
- **LLM backend**: ogent leans on `gptel`'s transport layer for streaming completions, credentials, and model selection.
- **Graph awareness**: Inspired by `org-roam`, ogent can query a local Org-roam database to resolve `@handle`s across files, making long-lived knowledge bases available to every buffer.

## gptel Integration Status
- Dynamic dispatcher buttons are generated from `ogent-models.el`, so contributors can define additional providers without editing UI code.
- `ogent-request` streams responses chunk-by-chunk through gptel callbacks, inserting placeholder `#+begin_src` blocks and closing them when completions finish or error.
- Specs live at `specs/gptel/overview.org` and `specs/gptel-integration.org` and describe how we bridge presets, backends, and streaming hooks. Read them before adjusting transport behavior.
- `ogent-ui--ensure-gptel` auto-loads every feature listed in `ogent-gptel-required-features`, so when you add a provider extend both the registry entry and that defcustom to guarantee the backend structs exist before dispatch.
- Tool execution, approval, and rendering live in the request callback (`ogent-ui.el`): each call is gated against the allow-list, session deny list, and effects policy, then executed, recorded to the proof ledger, and shown in a `:TOOL:` drawer.
- Backend/preset configuration is documented in [docs/backends-and-presets.md](docs/backends-and-presets.md) and the `ogent-onboard` wizard.
- Workspace presets allow per-project model and backend configuration via `.ogent-presets`.

## Backends, Models, and Presets
- `docs/backends-and-presets.md` walks through backend switching (gptel backend selection), model registry configuration, preset definition, and troubleshooting.
- Use the prompt dispatcher (`C-c . p`, or `SPC o p` in Doom/Evil) to pick a provider/model (`m`), apply a preset (`s`), or fan out across multiple models (`M`).

## Module Overview

ogent is organized into focused modules under `lisp/`:

| Module | Purpose |
|--------|---------|
| `ogent.el`, `ogent-core.el` | Entry points and core infrastructure |
| `ogent-keys.el` | Keybinding management |
| `ogent-models.el`, `ogent-presets.el` | Model registry and preset configuration |
| `ogent-context.el` | Context building from Org hierarchies |
| `ogent-prompts.el`, `ogent-prompts-yasnippet.el` | Prompt templates and snippet integration |
| `ogent-codemap.el` | Repository analysis and codemap generation |
| `ogent-completions.el`, `ogent-session.el` | Completion handling and session buffers |
| `ogent-edit*.el`, `inline-diff.el` | AI-powered code editing (diff, display, format, parse, word-level inline diff) |
| `ogent-tool*.el` | Tool system (approval, FSM, rendering) |
| `ogent-armory*.el`, `ui/ogent-ui-armory.el` | Org-native Armory storage, CLI runner, graph status, agents, profiles, tasks, search, and app opening |
| `ogent-issues*.el` | Beads (br) issue tracker integration |
| `ogent-onboard.el`, `ogent-anthropic-oauth.el` | Setup wizard and OAuth |
| `ogent-debug.el`, `ogent-mcp.el` | Debugging and MCP integration |

## Recent Additions

The following features were added recently:

- **Request Pause/Resume** (`ogent-ui.el`): Pause active requests and resume later with full context preservation. Commands `ogent-pause-request` and `ogent-resume-request`.
- **Tool Result Streaming** (`ogent-tools.el`): Async tool execution with streaming callbacks for bash, grep, and other long-running operations. Supports `:stream` and `:match` callback styles.
- **Inline Diff Display** (`inline-diff.el`): Word-level inline diff highlighting as an alternative to smerge. Toggle with `ogent-edit-toggle-display-method` (cycles smerge, overlay, inline-diff).
- **Beads Integration** (`ogent-issues.el`): Magit-style buffer for browsing and managing beads_rust (`br`) issues with inline filtering, transient menus, and dependency graph visualization.
- **Beads Org Agenda** (`ogent-issues-bd.el`): `M-x ogent-issues-agenda` projects open/in-progress/blocked `br` issues into a generated org file (cached under `user-emacs-directory/ogent/beads/`, or `ogent-issues-agenda-file`) and opens an `org-agenda` TODO view scoped to it. One-way: the file is regenerated on every invocation; state changes flow through the issue board, never back from the file.
- **Org Armory Foundation and Rich UI** (`ogent-armory.el`, `ogent-armory-runner.el`, `ogent-armory-status.el`, `ui/ogent-ui-armory.el`): Org-backed Armory roots, agents, jobs, CLI-backed Codex/Claude runs, saved Org transcripts, graph status with an Issues bridge, agent profile buffers, attention lanes, search, and app artifact opening.
- **Session Management** (`ogent-session.el`): Improved Org hierarchy with proper request/response threading and inline prompting.
- **Tool System** (`ogent-tool-*.el`): Complete tool approval UI, FSM status tracking, and inline rendering of tool calls/results.
- **Onboarding Wizard** (`ogent-onboard.el`): Interactive setup for API keys and provider configuration with OAuth support.
- **Default Prompts** (`ogent-prompts.el`): Reusable prompt templates with yasnippet integration.
- **Code Editing** (`ogent-edit.el`): AI-powered code editing with diff preview and apply/reject workflow.

## Roadmap

### Completed
- ✓ Tool result streaming with async callbacks
- ✓ Request pause/resume capability
- ✓ Inline-diff word-level display alternative
- ✓ Multi-model fan-out and comparison
- ✓ MCP server integration
- ✓ Magit-style diff preview UX
- ✓ Eval & analytics: inline completion rating (`C-c . +` / `C-c . -`) and a dashboard buffer (`C-c . A`) with per-project aggregation (`ogent-analytics.el`)

### In Progress
- **Incremental Codemap Refresh**: Detect changed files and update only affected sections while preserving manual annotations.
- **Prompt Template Library**: Expand built-in templates for code review, refactoring, documentation, and debugging workflows.

### Planned
- **Codemap Enhancements**
  - Link codemap nodes to specs/tests for full traceability.
  - Add data-flow annotations showing function call chains.
- **Testing Infrastructure**
  - Expand fixture coverage (streaming edge cases, error injection, preset application).
  - Exercise multi-model fan-out with mocked gptel streams.
  - Add integration tests for beads (br) coordination.
