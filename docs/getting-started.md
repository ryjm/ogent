# Getting Started with ogent

ogent is an AI-powered assistant for Emacs that turns your Org-mode buffers into interactive agent workspaces. This guide covers installation, setup, and basic usage.

## Table of Contents

- [Installation](#installation)
  - [Doom Emacs](#doom-emacs)
  - [Vanilla Emacs](#vanilla-emacs)
  - [Spacemacs](#spacemacs)
- [API Key Setup](#api-key-setup)
- [Backends, Models, and Presets](#backends-models-and-presets)
- [Basic Workflow](#basic-workflow)
- [Keybindings Cheat Sheet](#keybindings-cheat-sheet)
- [Troubleshooting](#troubleshooting)

## Installation

ogent depends on [gptel](https://github.com/karthink/gptel) for LLM communication. Make sure gptel is installed before proceeding.

### Doom Emacs

1. Add to `~/.doom.d/packages.el`:

```elisp
;; gptel for LLM transport
(package! gptel)

;; ogent from local checkout
(package! ogent :recipe (:local-repo "~/path/to/ogent/lisp"
                         :files ("*.el" "ui/*.el")))
```

2. Add to `~/.doom.d/config.el`:

```elisp
(use-package! ogent
  :defer t
  :commands (ogent-mode ogent-prompt-dispatch ogent-run-subtree
             ogent-request ogent-ai-speed-edit ogent-onboard)
  :init
  (setq ogent-enable-doom-bindings t
        ogent-doom-prefix "o")
  :config
  (ogent-setup-doom-bindings)
  (ogent-global-mode 1))
```

3. Run `doom sync` to install packages.

### Vanilla Emacs

1. Clone the repository:

```bash
git clone https://github.com/ryjm/ogent.git ~/path/to/ogent
```

2. Add to your init file (`~/.emacs.d/init.el` or `~/.emacs`):

```elisp
;; Add ogent to load path
(add-to-list 'load-path "~/path/to/ogent/lisp")
(add-to-list 'load-path "~/path/to/ogent/lisp/ui")

;; Install gptel (via package.el or use-package)
(use-package gptel
  :ensure t)

;; Load ogent
(use-package ogent
  :after gptel
  :commands (ogent-mode ogent-prompt-dispatch ogent-run-subtree
             ogent-request ogent-ai-speed-edit ogent-onboard)
  :bind-keymap ("C-c ." . ogent-mode-map)
  :config
  ;; Optional: set default model
  (setq ogent-default-model "claude-sonnet-4-6"))
```

### Spacemacs

1. Add to `dotspacemacs-additional-packages` in `.spacemacs`:

```elisp
dotspacemacs-additional-packages
'((ogent :location (recipe :fetcher local
                           :path "~/path/to/ogent/lisp"
                           :files ("*.el" "ui/*.el")))
  gptel)
```

2. Add configuration in `dotspacemacs/user-config`:

```elisp
(defun dotspacemacs/user-config ()
  ;; ogent configuration
  (use-package ogent
    :commands (ogent-mode ogent-prompt-dispatch ogent-run-subtree
               ogent-request ogent-ai-speed-edit ogent-onboard)
    :init
    (spacemacs/declare-prefix "ae" "ogent")
    (spacemacs/set-leader-keys
      "aee" 'ogent-prompt-dispatch
      "aer" 'ogent-request
      "aev" 'ogent-ai-speed-edit
      "aeo" 'ogent-onboard
      "aec" 'ogent-context-preview)))
```

3. Restart Spacemacs or run `SPC f e R`.

## API Key Setup

ogent provides an interactive setup wizard that handles API key configuration for all supported providers.

### Using the Setup Wizard

Run `M-x ogent-onboard` to start the wizard:

1. **Select a provider:**
   - **Anthropic Claude Max/Pro (OAuth)** - Recommended for Claude subscribers. Uses the Claude Code-compatible OAuth flow.
   - **Anthropic (API Key)** - Use your own Anthropic API key.
   - **OpenAI (GPT)** - Use your OpenAI API key.
   - **OpenAI Codex / ChatGPT (OAuth)** - Reuse Codex CLI ChatGPT credentials.

2. **Configure authentication:**
   - For Claude OAuth: Your browser will open to authenticate with your Claude account.
   - For Codex OAuth: Run `M-x ogent-codex-login` first, or choose the Codex OAuth provider after your Codex CLI is already logged in.
   - For API keys: Enter your key when prompted. You can save it to `~/.authinfo.gpg` for future sessions.

3. **Select default model:**
   - Choose which model to use by default for completions.

4. **Verify connection:**
   - The wizard tests the connection before finishing.

### Manual API Key Setup

If you prefer manual configuration, add your API keys to `~/.authinfo.gpg`:

```
machine api.anthropic.com login apikey password sk-ant-your-key-here
machine api.openai.com login apikey password sk-your-key-here
```

Then configure gptel in your init file:

```elisp
(setq gptel-api-key #'gptel-api-key-from-auth-source)
```

### Environment Variables

You can also use environment variables:

```bash
export ANTHROPIC_API_KEY="sk-ant-your-key-here"
export OPENAI_API_KEY="sk-your-key-here"
```

## Backends, Models, and Presets

For detailed configuration and backend switching behavior, see
[docs/backends-and-presets.md](backends-and-presets.md). This includes
model registry setup, preset configuration, and troubleshooting tips.

## Basic Workflow

ogent works within Org-mode buffers, treating each heading as an addressable block of context.

### 1. Enable ogent-mode

Open an Org file and run `M-x ogent-mode` (or `M-x ogent-global-mode` to
enable it everywhere).

### 2. Write a Bullet

Under any heading, write a normal Org child heading or bullet. Parent headings become context; the current subtree becomes the prompt:

```org
* Project Overview
:PROPERTIES:
:OGENT_ID: overview
:END:

This project implements a REST API for user management.

* Implementation Task

Use the project conventions and keep the API small.

** Add user authentication

I need to add user authentication. Consider the context in @overview.
Please suggest an implementation approach.
```

### 3. Run the Current Bullet

With your cursor inside `Add user authentication`, run:
- `M-x ogent-run-subtree` or
- `SPC o RET` (Doom/Evil) or
- `C-c . RET` (vanilla Emacs)

ogent sends the bullet/subtree text as `# User Prompt`. Each parent bullet contributes its own body text under `# Parent Bullets`; children and earlier transcripts are trimmed out, so nothing in the payload is duplicated.


For repo-aware dogfooding, just say where to look:

```org
* Ogent Zen
Look in ~/vault/projects/ogent for the working code.

** Result headline design
*** Better way of displaying result headlines
Come up with implementation-aware ideas grounded in the code.
```

ogent infers the workspace from ordinary path prose. `Context:`, `Workspace:`, `Project:`, and `Repo:` labels still work, but are not required. The selected workspace creates a `# Workspace` section in the payload, makes ogent tool calls resolve relative paths from that root, stores workspace metadata on the generated request, and code-inspection wording directs gptel toward targeted read-only tool calls before it answers.

Inside the result, Zen headings act like small run cards without changing the stored Org transcript. Expanded requests stay prompt-first; folded completed requests become result-first indexes, add an optional muted preview line, and can use persisted `OGENT_RESULT_TITLE` values derived from the answer. Active tool work is promoted into the main title, multi-model runs show compact model chips, sibling reruns show lineage, and low-priority metadata can right-align in wide graphical windows. `ogent-zen-result-headline-density` switches between `minimal`, `balanced`, `rich`, and `debug`. Empty runs show `0 chars`; individual tool-call failures stay as inline metadata instead of turning the run card red, while request-level model/network/abort failures name the failing subsystem and use the error styling. Review is no longer just one legacy `OGENT_REVIEW` tag: Zen now persists structured review metadata (`OGENT_DECISION`, `OGENT_REVIEW_STATUS`, `OGENT_USEFULNESS`, `OGENT_LINEAGE`, `OGENT_OUTCOME`, timestamps, reviewer) and mirrors it into a visible `:REVIEW:` drawer plus the legacy alias for older transcripts.

It also works from *inside* a result: with point anywhere in a generated transcript, `C-c . RET` re-runs the owning bullet (a fresh run is appended and the previous one collapses). To **replace** the transcript at point instead, use `C-c . !` (`ogent-zen-rerun`) or just press `C-c C-c` on it: edit the bullet, re-run, compare. To reuse an answer elsewhere, use `C-c . w` / `SPC o w` (`ogent-zen-copy-response`) anywhere in the transcript; it copies only the response body, not the request, metadata, or Org heading.

Malleable editing splits context from the edit target. `C-c . C-r` / `SPC o C-r` (`ogent-zen-run-region`) asks about selected text while preserving parent bullet context. `C-c . C-e` / `SPC o C-e` (`ogent-zen-edit-dwim`) rewrites the active region, paragraph, sentence, or nearby Org element by asking the model for one SEARCH/REPLACE block; successful responses preview in-place with inline diff overlays. `C-c . C-a` / `SPC o C-a` (`ogent-zen-apply-last-edit`) reapplies the latest structured edit from a transcript when you need to retry validation manually. Accept with `ogent-zen-accept-edit` / `C-c C-c` in `inline-diff-mode`, or reject with `ogent-zen-reject-edit` / `C-c C-k`.

For more control, use the **prompt dispatcher**:
- `M-x ogent-prompt-dispatch` or
- `SPC o p` (Doom/Evil) or
- `C-c . p` (vanilla Emacs)

The dispatcher lets you:
- Select one or more models for comparison
- Choose prompt templates
- Review context before sending

### 4. Ask from the Current Subtree

Use `C-c . q` / `SPC o q` when you want to type a new minibuffer question about the current subtree instead of running the bullet text itself:
- `M-x ogent-ask-here` or
- `SPC o q` (Doom/Evil) or
- `C-c . q` (vanilla Emacs)

The minibuffer names the active scope, for example `Ask here about subtree "Implementation Task":`.
When point is on a folded or bodyless child heading, the ask scope climbs to the nearest expanded parent, keeping visible sibling tasks in context.
The response is inserted under that subtree as a normal folded `Request` / `Response` transcript.

If you are unsure what to press, run `C-c . ?` / `SPC o ?` for the ask menu. It shows the active scope and offers run-current-bullet, inline ask, popup ask, region ask, malleable rewrite, edit application, ask-context preview, and the full dispatcher.

### 5. Review Responses

Zen review has two layers:

- `C-c . u` / `SPC o u`: context-aware review menu for the current run or response
- `C-c ,`: backend-aware review prefix shared by completions and Zen transcripts

In Zen, review actions can target:

- the whole run
- one model response

Accepting a response selects its model on the parent request, records structured review metadata, and keeps the transcript readable as plain Org through a `:REVIEW:` drawer. `C-c , d` opens a review dashboard/queue for the current Org buffer, and `C-c , .` explains the current review target and metadata.

### 6. Preview Context

Before sending, preview what will be sent to the model:
- `M-x ogent-context-preview` or
- `SPC o c` (Doom/Evil) or
- `C-c . c` (vanilla Emacs)

This shows the hydrated payload that will be sent, including resolved handles, source context, and pinned items.

## Keybindings Cheat Sheet

ogent uses `C-c .` as the prefix for vanilla Emacs and `SPC o` for Doom/Evil.

| Key | Vanilla | Doom | Description |
|-----|---------|------|-------------|
| `p` | `C-c . p` | `SPC o p` | Prompt dispatcher |
| `r` | `C-c . r` | `SPC o r` | Send request |
| `a` | `C-c . a` | `SPC o a` | Abort request |
| `R` | `C-c . R` | `SPC o R` | Retry last request |
| `C-f` | `C-c . C-f` | `SPC o C-f` | Fan out to multiple models |
| `C-k` | `C-c . C-k` | `SPC o C-k` | Abort fan-out group |
| `C-d` | `C-c . C-d` | `SPC o C-d` | Compare fan-out responses |
| `w` | `C-c . w` | `SPC o w` | Copy Zen response body |
| `u` | `C-c . u` | `SPC o u` | Review Zen request/response |
| `C-r` | `C-c . C-r` | `SPC o C-r` | Ask about selected text |
| `C-e` | `C-c . C-e` | `SPC o C-e` | Rewrite region/paragraph/sentence |
| `C-a` | `C-c . C-a` | `SPC o C-a` | Re-preview latest structured edit |
| `c` | `C-c . c` | `SPC o c` | Preview context |
| `m` | `C-c . m` | `SPC o m` | Show codemap |
| `M` | `C-c . M` | `SPC o M` | Generate task codemap |
| `P` | `C-c . P` | `SPC o P` | Pin file/buffer/region |
| `U` | `C-c . U` | `SPC o U` | Unpin item |
| `l` | `C-c . l` | `SPC o l` | List pinned items |
| `v` | `C-c . v` | `SPC o v` | AI speed edit |
| `f` | `C-c . f` | `SPC o f` | Fix diagnostic at point |
| `F` | `C-c . F` | `SPC o F` | Fix buffer diagnostics |
| `k` | `C-c . k` | `SPC o k` | Quick inline edit |
| `e` | `C-c . e` | `SPC o e` | Edit menu |
| `E` | `C-c . E` | `SPC o E` | Request edit |
| `s` | `C-c . s` | `SPC o s` | Go to source |
| `n` | `C-c . n` | `SPC o n` | Navigation menu |
| `b` | `C-c . b` | `SPC o b` | Show backlinks |
| `i` | `C-c . i` | `SPC o i` | Issue tracker |
| `q` | `C-c . q` | `SPC o q` | Ask here; insert Request/Response |
| `?` | `C-c . ?` | `SPC o ?` | Contextual ask menu |
| `D` | `C-c . D` | `SPC o D` | Toggle debug mode |
| `C-o` | `C-c . C-o` | `SPC o C-o` | Provider setup wizard |
| `C-s` | `C-c . C-s` | `SPC o C-s` | Armory QL search |
| `C-v` | `C-c . C-v` | `SPC o C-v` | Armory QL saved view |
| `C-p` | `C-c . C-p` | `SPC o C-p` | Armory agenda control plane |
| `]` | `C-c . ]` | `SPC o ]` | Next completion |
| `[` | `C-c . [` | `SPC o [` | Previous completion |
| `z` | `C-c . z` | `SPC o z` | Accept completion |
| `x` | `C-c . x` | `SPC o x` | Reject completion |
| `*` | `C-c . *` | `SPC o *` | Rate response 1-5 |
| `C-x` | `C-c . C-x` | `SPC o C-x` | Export conversation to buffer |
| `C-w` | `C-c . C-w` | `SPC o C-w` | Copy conversation export |

Review prefix (`C-c ,`) works in both vanilla Emacs and Doom/Evil:

| Key | Command | Description |
|-----|---------|-------------|
| `C-c , n` | `ogent-review-next` | Next review item needing attention |
| `C-c , p` | `ogent-review-previous` | Previous review item needing attention |
| `C-c , a` | `ogent-review-accept` | Accept current completion or Zen item |
| `C-c , x` | `ogent-review-reject` | Reject current completion or Zen item |
| `C-c , u` | `ogent-review-useful` | Mark current Zen item useful |
| `C-c , m` | `ogent-review-defer` | Mark current Zen item needs review |
| `C-c , s` | `ogent-review-stale` | Mark current Zen item stale |
| `C-c , d` | `ogent-review-dashboard` | Open the Zen review queue |
| `C-c , .` | `ogent-review-describe` | Explain current review target/state |

Run `M-x ogent-describe-bindings` to see all bindings in a help buffer.

## Optional Features

### Org-capture templates for notes and prompt ideas

ogent ships capture templates so you can drop a note or a prompt idea from
any buffer. Register them once in your init:

```emacs-lisp
(ogent-notes-setup-capture)   ; idempotent, defers until org-capture loads
```

Then `M-x org-capture` offers `o` (ogent) with `o n` — quick note into the
Inbox of `ogent-capture-notes-file` — and `o p` — prompt idea into the
Prompt Ideas heading of `ogent-capture-companion-file`. Both files default
under `org-directory`; customize `ogent-capture-templates` to change keys or
targets (your own colliding keys always win).

### Exporting a conversation as a shareable document

With point anywhere inside an agent conversation subtree,
`M-x ogent-export-conversation` (`C-c . C-x` / `SPC o C-x`) exports it as
clean Markdown: `OGENT_*`
property drawers are stripped, request/response headlines become `## User` /
`## <model>` sections, and source blocks stay fenced. The result opens in a
buffer; with a prefix argument (`C-u`) it is written as a `.md` file beside
the Org file. Once `ox-ogent` is loaded, the regular `C-c C-e` export
dispatcher also offers `g m` (Markdown) and `g h` (HTML); both locate the
enclosing conversation subtree automatically, even from inside a
request/response child. To copy the export straight to the kill ring
instead, use `C-c . C-w` / `SPC o C-w`
(`ogent-export-conversation-to-kill-ring`).

### Armory extras

See [docs/armory.org](armory.org) for the control-plane agenda
(`ogent-armory-agenda-control-plane`), org-ql saved search views
(`ogent-armory-ql-view`, optional org-ql dependency), and the in-process
`gptel-native` agent runner.

## Troubleshooting

### "gptel not found" or backend errors

**Problem:** ogent can't communicate with the LLM.

**Solution:**
1. Ensure gptel is installed: `M-x package-install RET gptel`
2. Check gptel is configured: `M-x gptel RET` should open a chat buffer
3. Run `M-x ogent-onboard` to reconfigure providers

### "No API key found"

**Problem:** Authentication failing.

**Solution:**
1. Run `M-x ogent-onboard` to set up credentials interactively
2. Check `~/.authinfo.gpg` contains your key:
   ```
   machine api.anthropic.com login apikey password YOUR_KEY
   ```
3. Verify environment variables are set in your shell

### Responses not appearing

**Problem:** Request sent but no response shows.

**Solution:**
1. Check the `*Messages*` buffer for errors
2. Enable debug mode: `M-x ogent-debug-mode`
3. Ensure you're in an Org buffer with ogent-mode enabled
4. Try a simpler prompt to rule out context issues

### OAuth login issues

**Problem:** Browser-based login not working.

**Solution:**
1. For Claude Code, ensure your account includes Claude Code access, then try `M-x ogent-claude-code-logout` and log in again.
2. For Codex, run `M-x ogent-codex-login-device` if browser callback login is blocked or you are on a headless machine.
3. Confirm Codex has a file auth cache at `$CODEX_HOME/auth.json` or `~/.codex/auth.json`.
4. Fall back to API key authentication via `M-x ogent-onboard`.

### "Rate limit exceeded"

**Problem:** Too many requests to the API.

**Solution:**
1. Wait a few minutes before retrying
2. Consider using a different model (e.g., Claude Haiku is faster)
3. Check your API plan limits

### After updating ogent

**Problem:** Stale code or conflicts after `git pull`.

**Solution:**
1. Recompile: `M-x ogent-recompile`
2. Or just reload: `M-x ogent-reload`
3. For Doom users: `doom sync` then restart

### Getting Help

- Run `M-x ogent-describe-bindings` to see all available commands
- Check the [README](../README.org) for detailed feature documentation
- See [debugging.org](debugging.org) for advanced troubleshooting
- File issues on the project repository
