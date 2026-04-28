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
  :commands (ogent-mode ogent-prompt-dispatch ogent-request
             ogent-ai-speed-edit ogent-onboard)
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
git clone https://github.com/your-org/ogent.git ~/path/to/ogent
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
  :commands (ogent-mode ogent-prompt-dispatch ogent-request
             ogent-ai-speed-edit ogent-onboard)
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
    :commands (ogent-mode ogent-prompt-dispatch ogent-request
               ogent-ai-speed-edit ogent-onboard)
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

Run `M-x ogent-onboard` (or `SPC o O` in Doom/Evil) to start the wizard:

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

Open an Org file and run:
- `M-x ogent-mode` or
- `SPC o t` (Doom/Evil) or
- `C-c . t` (vanilla Emacs)

### 2. Write Your Prompt

Under any heading, write your prompt as regular text. You can reference other headings using `@handle` syntax:

```org
* Project Overview
:PROPERTIES:
:OGENT_ID: overview
:END:

This project implements a REST API for user management.

* Implementation Task

I need to add user authentication. Consider the context in @overview.
Please suggest an implementation approach.
```

### 3. Send a Request

With your cursor in the heading you want to send:
- `M-x ogent-request` or
- `SPC o r` (Doom/Evil) or
- `C-c . r` (vanilla Emacs)

For more control, use the **prompt dispatcher**:
- `M-x ogent-prompt-dispatch` or
- `SPC o p` (Doom/Evil) or
- `C-c . p` (vanilla Emacs)

The dispatcher lets you:
- Select one or more models for comparison
- Choose prompt templates
- Review context before sending

### 4. Review Responses

Responses stream inline as Org source blocks:

```org
* Implementation Task
...your prompt...

** Response
#+begin_src text :model claude-sonnet-4-6
Here's my suggested approach for user authentication...
#+end_src
```

### 5. Preview Context

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
| `?` | `C-c . ?` | `SPC o ?` | Quick ask |
| `D` | `C-c . D` | `SPC o D` | Toggle debug mode |
| `]` | `C-c . ]` | `SPC o ]` | Next completion |
| `[` | `C-c . [` | `SPC o [` | Previous completion |
| `z` | `C-c . z` | `SPC o z` | Accept completion |
| `x` | `C-c . x` | `SPC o x` | Reject completion |

Run `M-x ogent-describe-bindings` to see all bindings in a help buffer.

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
- Check the [README](../README.md) for detailed feature documentation
- See [debugging.org](debugging.org) for advanced troubleshooting
- File issues on the project repository
