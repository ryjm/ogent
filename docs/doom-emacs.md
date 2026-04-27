# Doom Emacs Configuration Guide

This guide covers setting up ogent in [Doom Emacs](https://github.com/doomemacs/doomemacs) with idiomatic configuration patterns.

## Installation

### packages.el

Add ogent to your `~/.doom.d/packages.el`:

```elisp
;; From a local directory (recommended for development)
(package! ogent :recipe (:local-repo "~/path/to/ogent/lisp"
                         :files ("*.el" "ui/*.el")))

;; Or from GitHub (when published)
;; (package! ogent :recipe (:host github :repo "username/ogent"))
```

### doom sync

After adding the package declaration, run:

```bash
doom sync
```

This installs ogent and regenerates Doom's autoloads.

## Configuration

Add to your `~/.doom.d/config.el`:

```elisp
(use-package! ogent
  :defer t
  :commands (ogent-mode
             ogent-global-mode
             ogent-onboard
             ogent-prompt-dispatch
             ogent-request
             ogent-quick-edit
             ogent-request-edit
             ogent-context-preview
             ogent-companion-display
             ogent-edit-menu)
  :init
  ;; Set ogent source directory for development/recompilation
  (setq ogent-source-directory "~/path/to/ogent")
  ;; First-class Doom leader bindings under SPC o.
  (setq ogent-enable-doom-bindings t
        ogent-doom-prefix "o")

  ;; ogent can install the full command surface itself. Keep explicit map!
  ;; calls only if you want to override individual keys.
  (ogent-setup-doom-bindings)

  ;; Optional explicit bindings, equivalent to the defaults:
  (map! :leader
        (:prefix ("o" . "ogent")
         :desc "Prompt dispatch"     "p" #'ogent-prompt-dispatch
         :desc "Send request"        "r" #'ogent-request
         :desc "Quick edit"          "k" #'ogent-quick-edit
         :desc "Request edit"        "E" #'ogent-request-edit
         :desc "Edit menu"           "e" #'ogent-edit-menu
         :desc "Toggle mode"         "t" #'ogent-mode
         :desc "Global mode"         "g" #'ogent-global-mode
         :desc "Onboard/setup"       "O" #'ogent-onboard
         :desc "Preview context"     "c" #'ogent-context-preview
         :desc "Show companion"      "s" #'ogent-companion-display
         :desc "Abort request"       "a" #'ogent-abort-request
         :desc "Codemap"             "M" #'ogent-codemap-buffer))

  :config
  ;; Optional: Set default model after gptel loads
  ;; (setq ogent-default-model "claude-sonnet-4-6")
  )
```

## Keybindings Reference

All ogent commands are bound under `SPC o`:

| Key       | Command                    | Description                          |
|-----------|----------------------------|--------------------------------------|
| `SPC o p` | `ogent-prompt-dispatch`    | Open transient menu (main entry)     |
| `SPC o r` | `ogent-request`            | Send request with current context    |
| `SPC o k` | `ogent-quick-edit`         | Quick inline edit                    |
| `SPC o E` | `ogent-request-edit`       | Request code edits for buffer/region |
| `SPC o e` | `ogent-edit-menu`          | Edit operations transient menu       |
| `SPC o c` | `ogent-context-preview`    | Preview what will be sent to model   |
| `SPC o P` | `ogent-pin-dwim`           | Pin file/buffer/region               |
| `SPC o U` | `ogent-unpin-interactive`  | Unpin context item                   |
| `SPC o l` | `ogent-list-pinned`        | List pinned context                  |
| `SPC o a` | `ogent-abort-request`      | Abort in-progress request            |
| `SPC o R` | `ogent-retry-request`      | Retry last request                   |
| `SPC o ?` | `ogent-ask`                | Quick ask                            |
| `SPC o m` | `ogent-codemap-buffer`     | Show project codemap                 |

## API Key Configuration

ogent uses gptel for LLM communication. Configure your API keys:

### Using auth-source (recommended)

Add to `~/.authinfo` or `~/.authinfo.gpg`:

```
machine api.anthropic.com login apikey password sk-ant-xxxxx
machine api.openai.com login apikey password sk-xxxxx
```

Then in your config:

```elisp
(use-package! gptel
  :config
  (setq gptel-api-key #'gptel-api-key-from-auth-source))
```

### Using password-store (pass)

```elisp
(use-package! gptel
  :config
  (setq gptel-api-key (lambda ()
                        (string-trim
                         (shell-command-to-string "pass show anthropic/api-key")))))
```

### Direct configuration (not recommended for shared configs)

```elisp
(setq gptel-api-key "sk-ant-xxxxx")
```

## Popup Configuration

Configure the ogent companion buffer as a Doom popup:

```elisp
;; Right side panel (recommended)
(set-popup-rule! "^\\*ogent:"
  :side 'right
  :width 0.4
  :quit nil
  :select nil
  :ttl nil)

;; Or bottom panel
(set-popup-rule! "^\\*ogent:"
  :side 'bottom
  :height 0.3
  :quit nil
  :select nil
  :ttl nil)
```

Options explained:
- `:side` - Which side to display (`'right`, `'left`, `'bottom`, `'top`)
- `:width` / `:height` - Size as fraction of frame (0.4 = 40%)
- `:quit` - Whether `q` closes the popup (`nil` = no, `t` = yes)
- `:select` - Whether to select the popup when shown
- `:ttl` - Time to live (`nil` = never auto-close)

## Mode-Specific Keybindings

For org-mode specific commands, use localleader (`SPC m`):

```elisp
(map! :after org
      :map org-mode-map
      :localleader
      (:prefix ("o" . "ogent")
       :desc "Send subtree" "s" #'ogent-request
       :desc "Preview context" "p" #'ogent-context-preview))
```

## Complete Example Configuration

Here's a full, copy-paste ready configuration:

```elisp
;; In ~/.doom.d/packages.el
(package! ogent :recipe (:local-repo "~/projects/ogent/lisp"
                         :files ("*.el" "ui/*.el")))

;; In ~/.doom.d/config.el
(use-package! ogent
  :defer t
  :commands (ogent-mode
             ogent-global-mode
             ogent-onboard
             ogent-prompt-dispatch
             ogent-request
             ogent-quick-edit
             ogent-request-edit
             ogent-context-preview
             ogent-companion-display
             ogent-edit-menu)
  :init
  (setq ogent-source-directory "~/projects/ogent")

  ;; Main keybindings under SPC o
  (setq ogent-enable-doom-bindings t
        ogent-doom-prefix "o")
  (ogent-setup-doom-bindings)

  ;; Optional explicit overrides.
  (map! :leader
        (:prefix ("o" . "ogent")
         :desc "Prompt dispatch"     "p" #'ogent-prompt-dispatch
         :desc "Send request"        "r" #'ogent-request
         :desc "Quick edit"          "k" #'ogent-quick-edit
         :desc "Request edit"        "E" #'ogent-request-edit
         :desc "Edit menu"           "e" #'ogent-edit-menu
         :desc "Toggle mode"         "t" #'ogent-mode
         :desc "Global mode"         "g" #'ogent-global-mode
         :desc "Onboard/setup"       "O" #'ogent-onboard
         :desc "Preview context"     "c" #'ogent-context-preview
         :desc "Show companion"      "s" #'ogent-companion-display
         :desc "Abort request"       "a" #'ogent-abort-request
         :desc "Codemap"             "M" #'ogent-codemap-buffer))

  :config
  ;; Companion buffer as right-side popup
  (set-popup-rule! "^\\*ogent:"
    :side 'right
    :width 0.4
    :quit nil
    :select nil
    :ttl nil))

;; gptel API key configuration (choose one method)
(use-package! gptel
  :defer t
  :config
  ;; Using auth-source
  (setq gptel-api-key #'gptel-api-key-from-auth-source)

  ;; Or using password-store
  ;; (setq gptel-api-key (lambda ()
  ;;                       (string-trim
  ;;                        (shell-command-to-string "pass show anthropic/api-key"))))
  )
```

## Troubleshooting

### "Cannot open load file: ogent-ui"

This error occurs when Doom's autoloads point to individual module files rather than the main package. This was fixed in ogent. Ensure you have the latest version and run `doom sync`.

### gptel backend not found

Ensure gptel is loaded before using ogent:

```elisp
(use-package! gptel
  :commands (gptel gptel-send gptel-menu)
  :config
  ;; Your gptel configuration
  )
```

### Keybindings not showing in which-key

Make sure your `map!` calls are in the `:init` section of `use-package!`, not `:config`. Keybindings defined in `:config` only load after the package loads.

### Companion buffer not appearing as popup

Verify your `set-popup-rule!` pattern matches the buffer name. ogent companion buffers are named `*ogent:<filename>*`. Test with:

```elisp
M-: (get-buffer-create "*ogent:test*")
```

## Development

For ogent development with Doom:

```elisp
;; Reload after changes
M-x ogent-reload

;; Recompile and reload
M-x ogent-recompile

;; Enable debug output
M-x ogent-debug-enable
M-x ogent-debug-show
```
