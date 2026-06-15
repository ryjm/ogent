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
             ogent-run-subtree
             ogent-ai-speed-edit
             ogent-fix-buffer-diagnostics
             ogent-fix-diagnostic
             ogent-quick-edit
             ogent-request-edit
             ogent-context-preview
             ogent-companion-display
             ogent-edit-menu
             ogent-armory-home
             ogent-armory-status
             ogent-armory-agents
             ogent-armory-agent
             ogent-armory-org-chart
             ogent-armory-data
             ogent-armory-tasks
             ogent-armory-conversations
             ogent-armory-actions
             ogent-armory-schedule
             ogent-armory-agenda
             ogent-armory-git-status
             ogent-armory-command-palette
             ogent-armory-settings
             ogent-armory-help
             ogent-armory-onboard
             ogent-armory-registry-import
             ogent-armory-backup
             ogent-armory-search
             ogent-armory-apps
             ogent-armory-create-agent
             ogent-armory-create-job)
  :init
  ;; Set ogent source directory for development/recompilation
  (setq ogent-source-directory "~/path/to/ogent")
  ;; First-class Doom leader bindings under SPC o.
  (setq ogent-enable-doom-bindings t
        ogent-doom-prefix "o")

  ;; ogent can install the full command surface itself. Keep explicit map!
  ;; calls only if you want to override individual keys.
  (ogent-setup-doom-bindings)

  ;; Optional explicit overrides. NOTE: several keys below intentionally
  ;; differ from the registry defaults installed by `ogent-setup-doom-bindings'
  ;; (the defaults bind t to the tools menu, g to the dependency graph, s to
  ;; goto-source, and O to Armory conversations). Omit this block entirely to
  ;; keep the defaults.
  (map! :leader
        (:prefix ("o" . "ogent")
         :desc "Prompt dispatch"     "p" #'ogent-prompt-dispatch
         :desc "Run current bullet"  "RET" #'ogent-run-subtree
         :desc "Re-run at point"     "!" #'ogent-zen-rerun
         :desc "Send request"        "r" #'ogent-request
         :desc "Ask here"           "q" #'ogent-ask-here
         :desc "Ask menu"           "?" #'ogent-ask-menu
         :desc "Ask region"            "C-r" #'ogent-zen-run-region
         :desc "Rewrite here"          "C-e" #'ogent-zen-edit-dwim
         :desc "Apply last edit"       "C-a" #'ogent-zen-apply-last-edit
         :desc "AI speed edit"       "v" #'ogent-ai-speed-edit
         :desc "Fix diagnostic"      "f" #'ogent-fix-diagnostic
         :desc "Fix buffer diags"     "F" #'ogent-fix-buffer-diagnostics
         :desc "Quick edit"          "k" #'ogent-quick-edit
         :desc "Request edit"        "E" #'ogent-request-edit
         :desc "Edit menu"           "e" #'ogent-edit-menu
         :desc "Toggle mode"         "t" #'ogent-mode
         :desc "Global mode"         "g" #'ogent-global-mode
         :desc "Onboard/setup"       "u" #'ogent-onboard
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

`ogent-ask-here` and `ogent-ask-menu` name the active ask scope in the minibuffer or menu. On a folded or bodyless child heading, that scope climbs to the nearest expanded parent, keeping visible sibling tasks in context.

| Key       | Command                    | Description                          |
|-----------|----------------------------|--------------------------------------|
| `SPC o p` | `ogent-prompt-dispatch`    | Open transient menu (main entry)     |
| `SPC o RET` | `ogent-run-subtree`       | Run current bullet/subtree as prompt |
| `SPC o !` | `ogent-zen-rerun`          | Re-run transcript at point           |
| `SPC o r` | `ogent-request`            | Send request with current context    |
| `SPC o v` | `ogent-ai-speed-edit`      | AI chooses a small reviewable edit   |
| `SPC o f` | `ogent-fix-diagnostic`     | Fix diagnostic at point              |
| `SPC o F` | `ogent-fix-buffer-diagnostics` | Fix buffer diagnostics           |
| `SPC o k` | `ogent-quick-edit`         | Quick inline edit                    |
| `SPC o E` | `ogent-request-edit`       | Request code edits for buffer/region |
| `SPC o e` | `ogent-edit-menu`          | Edit operations transient menu       |
| `SPC o c` | `ogent-context-preview`    | Preview what will be sent to model   |
| `SPC o P` | `ogent-pin-dwim`           | Pin file/buffer/region               |
| `SPC o U` | `ogent-unpin-interactive`  | Unpin context item                   |
| `SPC o l` | `ogent-list-pinned`        | List pinned context                  |
| `SPC o a` | `ogent-abort-request`      | Abort in-progress request            |
| `SPC o R` | `ogent-retry-request`      | Retry last request                   |
| `SPC o q` | `ogent-ask-here`           | Ask at point; insert Request/Response |
| `SPC o ?` | `ogent-ask-menu`           | Show contextual ask menu              |
| `SPC o C-r` | `ogent-zen-run-region`    | Ask about selected text               |
| `SPC o C-e` | `ogent-zen-edit-dwim`     | Rewrite region/paragraph/sentence     |
| `SPC o C-a` | `ogent-zen-apply-last-edit` | Re-preview latest structured edit   |
| `SPC o m` | `ogent-codemap-buffer`     | Show project codemap                 |
| `SPC o j` | `ogent-armory-home`       | Armory Home                         |
| `SPC o K` | `ogent-armory-status`     | Armory graph/status                 |
| `SPC o y` | `ogent-armory-agents`     | Armory agents                       |
| `SPC o Y` | `ogent-armory-agent`      | Armory agent profile                |
| `SPC o B` | `ogent-armory-org-chart`  | Armory org chart                    |
| `SPC o ;` | `ogent-armory-data`       | Armory data browser                 |
| `SPC o I` | `ogent-armory-tasks`      | Armory task board                   |
| `SPC o O` | `ogent-armory-conversations` | Armory conversations             |
| `SPC o N` | `ogent-armory-actions`    | Armory action approvals             |
| `SPC o J` | `ogent-armory-schedule`   | Armory schedule                     |
| `SPC o Q` | `ogent-armory-agenda`     | Armory Org agenda                   |
| `SPC o :` | `ogent-armory-git-status` | Armory git status                   |
| `SPC o /` | `ogent-armory-command-palette` | Ranked command palette          |
| `SPC o ,` | `ogent-armory-settings`   | Armory settings                     |
| `SPC o .` | `ogent-armory-help`       | Armory help                         |
| `SPC o '` | `ogent-armory-onboard`    | Onboard Armory                      |
| `SPC o =` | `ogent-armory-registry-import` | Import Armory template        |
| `SPC o _` | `ogent-armory-backup`     | Back up Armory                      |
| `SPC o V` | `ogent-armory-search`     | Armory-wide search                  |
| `SPC o W` | `ogent-armory-apps`       | Armory app artifacts                |
| `SPC o X` | `ogent-armory-create-agent` | Create Armory agent               |
| `SPC o Z` | `ogent-armory-create-job` | Create Armory job                   |

Review workflow keeps its own punctuation prefix in Doom/Evil as well:

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

The issue board's detail view (`*ogent-issue: …*`) deliberately does
**not** go through Doom's popup system: selecting an issue opens a
magit-style side-by-side split via `display-buffer-overriding-action`,
which outranks Doom's `"^\\*"` bottom-popup catch-all. Customize
`ogent-issues-detail-display-action` (`right`/`below`/`other-window`)
to change the layout, or set it to `default` if you want your own
`set-popup-rule!`/`display-buffer-alist` rules to govern that buffer.

## Mode-Specific Keybindings

For org-mode specific commands, use localleader (`SPC m`):

```elisp
(map! :after org
      :map org-mode-map
      :localleader
      (:prefix ("o" . "ogent")
       :desc "Send subtree" "s" #'ogent-request
       :desc "Ask here" "q" #'ogent-ask-here
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
             ogent-ai-speed-edit
             ogent-fix-buffer-diagnostics
             ogent-fix-diagnostic
             ogent-quick-edit
             ogent-request-edit
             ogent-context-preview
             ogent-companion-display
             ogent-edit-menu
             ogent-armory-home
             ogent-armory-status
             ogent-armory-agents
             ogent-armory-agent
             ogent-armory-org-chart
             ogent-armory-data
             ogent-armory-tasks
             ogent-armory-conversations
             ogent-armory-actions
             ogent-armory-schedule
             ogent-armory-agenda
             ogent-armory-git-status
             ogent-armory-command-palette
             ogent-armory-settings
             ogent-armory-help
             ogent-armory-onboard
             ogent-armory-registry-import
             ogent-armory-backup
             ogent-armory-search
             ogent-armory-apps
             ogent-armory-create-agent
             ogent-armory-create-job)
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
         :desc "AI speed edit"       "v" #'ogent-ai-speed-edit
         :desc "Fix diagnostic"      "f" #'ogent-fix-diagnostic
         :desc "Fix buffer diags"     "F" #'ogent-fix-buffer-diagnostics
         :desc "Quick edit"          "k" #'ogent-quick-edit
         :desc "Request edit"        "E" #'ogent-request-edit
         :desc "Edit menu"           "e" #'ogent-edit-menu
         :desc "Toggle mode"         "t" #'ogent-mode
         :desc "Global mode"         "g" #'ogent-global-mode
         :desc "Onboard/setup"       "u" #'ogent-onboard
         :desc "Preview context"     "c" #'ogent-context-preview
         :desc "Show companion"      "s" #'ogent-companion-display
         :desc "Abort request"       "a" #'ogent-abort-request
         :desc "Codemap"             "M" #'ogent-codemap-buffer
         :desc "Armory home"        "j" #'ogent-armory-home
         :desc "Armory graph"       "K" #'ogent-armory-status
         :desc "Armory agents"      "y" #'ogent-armory-agents
         :desc "Armory agent"       "Y" #'ogent-armory-agent
         :desc "Armory org chart"   "B" #'ogent-armory-org-chart
         :desc "Armory data"        ";" #'ogent-armory-data
         :desc "Armory tasks"       "I" #'ogent-armory-tasks
         :desc "Armory conversations" "O" #'ogent-armory-conversations
         :desc "Armory actions"     "N" #'ogent-armory-actions
         :desc "Armory schedule"    "J" #'ogent-armory-schedule
         :desc "Armory agenda"      "Q" #'ogent-armory-agenda
         :desc "Armory git"         ":" #'ogent-armory-git-status
         :desc "Armory palette"     "/" #'ogent-armory-command-palette
         :desc "Armory settings"    "," #'ogent-armory-settings
         :desc "Armory help"        "." #'ogent-armory-help
         :desc "Onboard Armory"     "'" #'ogent-armory-onboard
         :desc "Import Armory"      "=" #'ogent-armory-registry-import
         :desc "Back up Armory"     "_" #'ogent-armory-backup
         :desc "Armory search"      "V" #'ogent-armory-search
         :desc "Armory apps"        "W" #'ogent-armory-apps
         :desc "Create agent"        "X" #'ogent-armory-create-agent
         :desc "Create job"          "Z" #'ogent-armory-create-job))

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
