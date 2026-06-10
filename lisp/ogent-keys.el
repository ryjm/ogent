;;; ogent-keys.el --- Unified keybinding system for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a unified keybinding system with feature parity between
;; vanilla Emacs and evil-mode bindings.
;;
;; All bindable actions are defined in `ogent-action-registry'.
;; Bindings are generated from this registry for both systems.

;;; Code:

;; Declare evil functions to avoid byte-compile warnings
(declare-function evil-define-key* "ext:evil-core")

;; Doom variables are optional; bind them dynamically when Doom is present.
(defvar doom-leader-map)
(defvar doom-leader-key)

;; Declare hydra commands (defined in ogent-ui-hydra.el)
(declare-function ogent-navigate "ogent-ui-hydra")
(declare-function ogent-edit-menu "ogent-ui-hydra")
(declare-function ogent-ai-speed-edit "ogent-edit")
(declare-function ogent-fix-buffer-diagnostics "ogent-edit")
(declare-function ogent-fix-diagnostic "ogent-edit")
(declare-function ogent-quick-edit "ogent-edit")
(declare-function ogent-request-edit "ogent-edit")

;; Declare completion commands (defined in ogent-completions.el)
(declare-function ogent-completion-next "ogent-completions")
(declare-function ogent-completion-prev "ogent-completions")
(declare-function ogent-completion-accept "ogent-completions")
(declare-function ogent-completion-reject "ogent-completions")
(declare-function ogent-review-accept "ogent-completions")

;; Declare analytics commands (defined in ogent-analytics.el)
(declare-function ogent-analytics-rate-up "ogent-analytics")
(declare-function ogent-analytics-rate-down "ogent-analytics")
(declare-function ogent-analytics-dashboard "ogent-analytics")


;; Declare Armory commands (defined in ogent-armory-status.el and UI files)
(declare-function ogent-armory-home "ogent-ui-armory")
(declare-function ogent-armory-status "ogent-armory-status")
(declare-function ogent-armory-agents "ogent-ui-armory")
(declare-function ogent-armory-agent "ogent-ui-armory")
(declare-function ogent-armory-org-chart "ogent-ui-armory")
(declare-function ogent-armory-tasks "ogent-ui-armory")
(declare-function ogent-armory-conversations "ogent-ui-armory")
(declare-function ogent-armory-data "ogent-armory-data")
(declare-function ogent-armory-actions "ogent-armory-actions")
(declare-function ogent-armory-schedule "ogent-armory-schedule")
(declare-function ogent-armory-agenda "ogent-armory-schedule")
(declare-function ogent-armory-git-status "ogent-armory-git")
(declare-function ogent-armory-command-palette "ogent-armory-palette")
(declare-function ogent-armory-settings "ogent-armory-settings")
(declare-function ogent-armory-help "ogent-armory-settings")
(declare-function ogent-armory-onboard "ogent-armory-settings")
(declare-function ogent-armory-registry-import "ogent-armory-settings")
(declare-function ogent-armory-backup "ogent-armory-settings")
(declare-function ogent-armory-search "ogent-ui-armory")
(declare-function ogent-armory-apps "ogent-ui-armory")
(declare-function ogent-armory-create-agent "ogent-ui-armory")
(declare-function ogent-armory-create-job "ogent-ui-armory")

(defgroup ogent-keys nil
  "Keybinding configuration for ogent."
  :group 'ogent)

;;; Customization

(defcustom ogent-vanilla-prefix "C-c ."
  "Prefix for vanilla Emacs keybindings.
This prefix is used for all ogent commands in standard Emacs."
  :type 'string
  :group 'ogent-keys)

(defcustom ogent-evil-prefix "SPC o"
  "Prefix for evil leader keybindings.
This prefix is used with evil-mode's normal and visual state maps.
The default mirrors Doom's leader convention: SPC o for ogent."
  :type 'string
  :group 'ogent-keys)

(defcustom ogent-enable-doom-bindings t
  "Whether to install Doom leader bindings when Doom is available.
Bindings are installed under `ogent-doom-prefix' in `doom-leader-map'."
  :type 'boolean
  :group 'ogent-keys)

(defcustom ogent-doom-prefix "o"
  "Doom leader prefix for ogent commands.
With Doom's default leader this makes commands available under SPC o."
  :type 'string
  :group 'ogent-keys)

(defcustom ogent-review-prefix "C-c o"
  "Prefix for ergonomic review keybindings.
This prefix provides quick access to completion review commands."
  :type 'string
  :group 'ogent-keys)

(defcustom ogent-enable-evil-bindings t
  "Whether to set up evil-mode keybindings when evil is available.
Set to nil to disable automatic evil binding setup."
  :type 'boolean
  :group 'ogent-keys)

;;; Action Registry

(defconst ogent-action-registry
  '(;; Core actions
    (prompt-dispatch  :key "p" :command ogent-prompt-dispatch
                      :desc "Open prompt dispatcher")
    (request          :key "r" :command ogent-request
                      :desc "Send request"
                      :visual t)
    (abort            :key "a" :command ogent-abort-request
                      :desc "Abort current request")
    (retry            :key "R" :command ogent-retry-request
                      :desc "Retry last request")
    ;; Context
    (context-preview  :key "c" :command ogent-context-preview
                      :desc "Preview context")
    (codemap          :key "m" :command ogent-codemap-buffer
                      :desc "Show static codemap")
    (codemap-task     :key "M" :command ogent-codemap-generate
                      :desc "Generate task codemap")
    ;; Pinned context
    (pin-dwim         :key "P" :command ogent-pin-dwim
                      :desc "Pin file/buffer/region"
                      :visual t)
    (unpin            :key "U" :command ogent-unpin-interactive
                      :desc "Unpin item")
    (list-pinned      :key "l" :command ogent-list-pinned
                      :desc "List pinned")
    ;; Editing (hydra menu)
    (edit-menu        :key "e" :command ogent-edit-menu
                      :desc "Edit hydra menu")
    (ai-speed-edit    :key "v" :command ogent-ai-speed-edit
                      :desc "AI speed edit"
                      :visual t)
    (fix-diagnostic   :key "f" :command ogent-fix-diagnostic
                      :desc "Fix diagnostic"
                      :visual t)
    (fix-buffer-diagnostics
     :key "F" :command ogent-fix-buffer-diagnostics
     :desc "Fix buffer diagnostics"
     :visual t)
    (quick-edit       :key "k" :command ogent-quick-edit
                      :desc "Quick inline edit"
                      :visual t)
    (request-edit     :key "E" :command ogent-request-edit
                      :desc "Request edit"
                      :visual t)
    (goto-source      :key "s" :command ogent-edit-goto-source
                      :desc "Go to source")
    (goto-companion   :key "C" :command ogent-edit-goto-companion
                      :desc "Go to companion")
    ;; Tools
    (tool-menu        :key "t" :command ogent-debug-tools-menu
                      :desc "Tools debug menu")
    (tool-rerun       :key "T" :command ogent-tool-rerun
                      :desc "Re-run tool at point")
    ;; Navigation (hydra menu)
    (navigate         :key "n" :command ogent-navigate
                      :desc "Navigation hydra")
    (backlinks        :key "b" :command ogent-show-backlinks
                      :desc "Show backlinks")
    (graph            :key "g" :command ogent-show-dependency-graph
                      :desc "Dependency graph")
    (open-block       :key "o" :command ogent-open-block
                      :desc "Open block")
    ;; Session & Issues
    (issues           :key "i" :command ogent-issues
                      :desc "Issue tracker")
    (session-save     :key "S" :command ogent-session-save
                      :desc "Save session")
    (session-load     :key "L" :command ogent-session-load
                      :desc "Load session")
    (session-list     :key "H" :command ogent-session-list
                      :desc "List sessions")
    ;; Misc
    (ask              :key "?" :command ogent-ask
                      :desc "Quick ask"
                      :visual t)
    (notes            :key "d" :command ogent-notes-capture
                      :desc "Capture notes")
    (debug-mode       :key "D" :command ogent-debug-mode
                      :desc "Toggle debug mode")
    (armory-home     :key "j" :command ogent-armory-home
                      :desc "Armory Home")
    (armory-status   :key "K" :command ogent-armory-status
                      :desc "Armory graph/status")
    (armory-agents   :key "y" :command ogent-armory-agents
                      :desc "Armory agents")
    (armory-agent-profile
     :key "Y" :command ogent-armory-agent
     :desc "Armory agent profile")
    (armory-org-chart
     :key "B" :command ogent-armory-org-chart
     :desc "Armory org chart")
    (armory-data     :key ";" :command ogent-armory-data
                      :desc "Armory data browser")
    (armory-tasks    :key "I" :command ogent-armory-tasks
                      :desc "Armory tasks")
    (armory-conversations
     :key "O" :command ogent-armory-conversations
     :desc "Armory conversations")
    (armory-actions  :key "N" :command ogent-armory-actions
                      :desc "Armory action approvals")
    (armory-schedule :key "J" :command ogent-armory-schedule
                      :desc "Armory schedule")
    (armory-agenda   :key "Q" :command ogent-armory-agenda
                      :desc "Armory agenda")
    (armory-git      :key ":" :command ogent-armory-git-status
                      :desc "Armory git status")
    (armory-palette  :key "/" :command ogent-armory-command-palette
                      :desc "Armory command palette")
    (armory-settings :key "," :command ogent-armory-settings
                      :desc "Armory settings")
    (armory-help     :key "." :command ogent-armory-help
                      :desc "Armory help")
    (armory-onboard  :key "'" :command ogent-armory-onboard
                      :desc "Onboard Armory")
    (armory-registry-import
     :key "=" :command ogent-armory-registry-import
     :desc "Import Armory registry")
    (armory-backup   :key "_" :command ogent-armory-backup
                      :desc "Back up Armory")
    (armory-search   :key "V" :command ogent-armory-search
                      :desc "Armory search")
    (armory-apps     :key "W" :command ogent-armory-apps
                      :desc "Armory apps")
    (armory-create-agent
     :key "X" :command ogent-armory-create-agent
     :desc "Create Armory agent")
    (armory-create-job
     :key "Z" :command ogent-armory-create-job
     :desc "Create Armory job")
    ;; Completion review
    (completion-next   :key "]" :command ogent-completion-next
                       :desc "Next completion")
    (completion-prev   :key "[" :command ogent-completion-prev
                       :desc "Previous completion")
    (completion-accept :key "z" :command ogent-completion-accept
                       :desc "Accept completion")
    (completion-reject :key "x" :command ogent-completion-reject
                       :desc "Reject completion")
    ;; Analytics
    (analytics-rate-up   :key "+" :command ogent-analytics-rate-up
                         :desc "Rate thumbs up")
    (analytics-rate-down :key "-" :command ogent-analytics-rate-down
                         :desc "Rate thumbs down")
    (analytics-dashboard :key "A" :command ogent-analytics-dashboard
                         :desc "Analytics dashboard"))
  "Registry of ogent actions with keys and commands.
Each entry is (NAME :key KEY :command CMD :desc DESC [:visual t]).
The :visual flag indicates the action should also be bound in visual state.")

(defconst ogent-review-action-registry
  '(;; Ergonomic review commands (C-c o prefix)
    (review-next   :key "n" :command ogent-completion-next
                   :desc "Next completion")
    (review-prev   :key "p" :command ogent-completion-prev
                   :desc "Previous completion")
    (review-accept :key "a" :command ogent-review-accept
                   :desc "Accept completion")
    (review-reject :key "x" :command ogent-completion-reject
                   :desc "Reject completion"))
  "Registry of review actions for the C-c o prefix.
These are ergonomic keybindings optimized for the review workflow.")

;;; Binding Generators

(defun ogent-action-get (action prop)
  "Get property PROP from ACTION entry in registry."
  (plist-get (cdr (assq action ogent-action-registry)) prop))

(defun ogent-setup-vanilla-bindings (keymap)
  "Set up vanilla Emacs keybindings in KEYMAP from action registry."
  (dolist (entry ogent-action-registry)
    (let* ((key (plist-get (cdr entry) :key))
           (cmd (plist-get (cdr entry) :command))
           (full-key (concat ogent-vanilla-prefix " " key)))
      (define-key keymap (kbd full-key) cmd))))

(defun ogent-setup-review-bindings (keymap)
  "Set up ergonomic review keybindings in KEYMAP from review action registry.
These use the `ogent-review-prefix' (C-c o by default)."
  (dolist (entry ogent-review-action-registry)
    (let* ((key (plist-get (cdr entry) :key))
           (cmd (plist-get (cdr entry) :command))
           (full-key (concat ogent-review-prefix " " key)))
      (define-key keymap (kbd full-key) cmd))))

(defun ogent-keys--bind-actions (keymap registry &optional prefix)
  "Bind REGISTRY actions into KEYMAP.
When PREFIX is non-nil, bind each action under PREFIX."
  (dolist (entry registry)
    (let* ((key (plist-get (cdr entry) :key))
           (cmd (plist-get (cdr entry) :command))
           (full-key (if prefix (concat prefix " " key) key)))
      (define-key keymap (kbd full-key) cmd))))

(defun ogent-setup-evil-bindings-now (keymap)
  "Install evil bindings into KEYMAP immediately."
  (when (and ogent-enable-evil-bindings
             (fboundp 'evil-define-key*))
    (dolist (entry ogent-action-registry)
      (let* ((_name (car entry))
             (props (cdr entry))
             (key (plist-get props :key))
             (cmd (plist-get props :command))
             (visual-p (plist-get props :visual)))
        ;; Normal state binding
        (evil-define-key* 'normal keymap
                          (kbd (concat ogent-evil-prefix " " key)) cmd)
        ;; Visual state for region-based actions
        (when visual-p
          (evil-define-key* 'visual keymap
                            (kbd (concat ogent-evil-prefix " " key)) cmd))))))

(defun ogent-setup-evil-bindings (keymap)
  "Set up evil keybindings in KEYMAP from action registry.
If evil is not loaded yet, defer installation until it loads."
  (when ogent-enable-evil-bindings
    (if (featurep 'evil)
        (progn
          (require 'evil)
          (ogent-setup-evil-bindings-now keymap))
      (with-eval-after-load 'evil
        (ogent-setup-evil-bindings-now keymap)))))

;;;###autoload
(defun ogent-setup-doom-bindings (&optional leader-map noerror)
  "Install Doom leader bindings for ogent.
LEADER-MAP defaults to `doom-leader-map'.  When NOERROR is non-nil,
return nil rather than signaling if Doom is unavailable."
  (interactive)
  (let ((map (or leader-map
                 (and (boundp 'doom-leader-map)
                      (keymapp doom-leader-map)
                      doom-leader-map))))
    (cond
     ((not ogent-enable-doom-bindings) nil)
     ((not (keymapp map))
      (unless noerror
        (user-error "Doom leader map is not available"))
      nil)
     (t
      (let ((prefix-map (make-sparse-keymap)))
        (ogent-keys--bind-actions prefix-map ogent-action-registry)
        (define-key map (kbd ogent-doom-prefix) prefix-map)
        (when (featurep 'which-key)
          (let ((leader (if (and (boundp 'doom-leader-key)
                                 (stringp doom-leader-key))
                            doom-leader-key
                          "SPC")))
            (which-key-add-key-based-replacements
             (concat leader " " ogent-doom-prefix) "ogent")))
        prefix-map)))))

(defun ogent-setup-which-key ()
  "Set up which-key descriptions for ogent prefixes and all commands."
  (when (featurep 'which-key)
    ;; Add prefix descriptions
    (which-key-add-key-based-replacements
     ogent-vanilla-prefix "ogent")
    (which-key-add-key-based-replacements
     ogent-review-prefix "ogent review")
    (when (and ogent-enable-evil-bindings (featurep 'evil))
      (which-key-add-key-based-replacements
       ogent-evil-prefix "ogent"))
    (when (and ogent-enable-doom-bindings
               (boundp 'doom-leader-key)
               (stringp doom-leader-key))
      (which-key-add-key-based-replacements
       (concat doom-leader-key " " ogent-doom-prefix) "ogent"))
    ;; Add descriptions for each command
    (dolist (entry ogent-action-registry)
      (let* ((props (cdr entry))
             (key (plist-get props :key))
             (desc (plist-get props :desc))
             (full-key (concat ogent-vanilla-prefix " " key)))
        (which-key-add-key-based-replacements full-key desc)
        (when (and ogent-enable-evil-bindings (featurep 'evil))
          (which-key-add-key-based-replacements
           (concat ogent-evil-prefix " " key) desc))))
    ;; Add descriptions for review commands
    (dolist (entry ogent-review-action-registry)
      (let* ((props (cdr entry))
             (key (plist-get props :key))
             (desc (plist-get props :desc))
             (full-key (concat ogent-review-prefix " " key)))
        (which-key-add-key-based-replacements full-key desc)))))

(defun ogent-setup-all-bindings (keymap)
  "Set up all keybindings in KEYMAP.
This sets up vanilla bindings, review bindings, evil bindings (if available),
and which-key integration."
  (ogent-setup-vanilla-bindings keymap)
  (ogent-setup-review-bindings keymap)
  (ogent-setup-evil-bindings keymap)
  (ogent-setup-doom-bindings nil t)
  (with-eval-after-load 'doom
    (ogent-setup-doom-bindings nil t))
  (with-eval-after-load 'which-key
    (ogent-setup-which-key)))

;;; Evil display-buffer integration

;; Canonical Evil integration for ogent's read-only display buffers
;; (Armory, Issues, history, tool history, edit diff, ...).  These
;; buffers advertise single-key
;; affordances in their header line ("g refresh", "n/p", "RET visit").
;; Under Doom/Evil those keys default to Evil normal-state motions and
;; shadow the buffer's own keymap, so the hints silently do nothing.
;;
;; The fix is the same pattern magit/dired use: mark the mode keymap as
;; an Evil *overriding* map.  Keys the mode binds win over Evil's state
;; keymap (so every advertised affordance fires), while keys the mode
;; does NOT bind keep their Evil motion meaning (so j/k/search/etc still
;; work).  This is strictly better than stripping bindings, which left
;; the on-screen hints lying to Evil users.

(declare-function evil-make-overriding-map "ext:evil-core")
(declare-function evil-make-intercept-map "ext:evil-core")
(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function evil-local-set-key "ext:evil-core")
(declare-function evil-define-key* "ext:evil-core")
(declare-function evil-goto-first-line "ext:evil-commands")
(declare-function evil-goto-line "ext:evil-commands")

(defun ogent-evil--keymap-command-bindings (keymap &optional prefix)
  "Return direct (KEYVEC . COMMAND) bindings of KEYMAP.
Parent keymaps are ignored; nested prefix keymaps are walked.
PREFIX is used internally while recursing."
  (let (bindings
        (entries (cdr keymap)))
    (while (and entries (not (eq (car entries) 'keymap)))
      (let ((entry (car entries)))
        (when (consp entry)
          (let* ((event (car entry))
                 (binding (cdr entry))
                 (key (vconcat (or prefix []) (vector event))))
            (cond
             ((commandp binding)
              (push (cons key binding) bindings))
             ((keymapp binding)
              (setq bindings
                    (nconc (nreverse
                            (ogent-evil--keymap-command-bindings binding key))
                           bindings)))))))
      (setq entries (cdr entries)))
    (nreverse bindings)))

(defun ogent-evil-display-mode-setup (mode mode-map mode-hook
                                            &optional refresh-fn refresh-force-fn)
  "Make MODE's read-only display buffer fully usable under Evil.

MODE is the major-mode symbol, MODE-MAP its keymap value, MODE-HOOK
its mode-hook symbol.  Effects:

  * the buffer opens in Evil `normal' state,
  * every command MODE-MAP binds is mirrored into Evil `normal' and
    `motion' auxiliary state (via `evil-define-key*', the mechanism
    evil-collection uses) so the single-key affordances shown in the
    buffer (`n'/`p', `RET', `q', `c', `a', `d', ...) fire exactly as
    advertised even over Doom's own custom normal-state operator keys,
  * MODE-MAP also overrides Evil `normal'/`motion' state as a
    belt-and-suspenders fallback, while keys MODE-MAP does not bind
    keep their Evil motion meaning (`j', `k', `/', search, ...),
  * refresh is exposed under `gr' (and force-refresh under `gR') with
    `gg'/`G' goto-first/last-line and `ZZ'/`ZQ' to quit -- the same
    convention evil-collection uses for magit/dired, which is the
    behaviour Doom users already have muscle memory for (bare `g'
    cannot be reclaimed: it is Evil's universal prefix and stays so
    even for magit in this configuration),
  * `evil-normalize-keymaps' runs on MODE-HOOK so it takes effect.

This is the exact pattern proven by `ogent-issues--setup-evil'.
Safe no-op when Evil is unavailable or
`ogent-enable-evil-bindings' is nil; vanilla Emacs uses MODE-MAP
directly (bare `g' refresh etc.) and is unaffected."
  (when (and ogent-enable-evil-bindings
             (fboundp 'evil-make-overriding-map)
             (fboundp 'evil-set-initial-state)
             (keymapp mode-map))
    (evil-set-initial-state mode 'normal)
    (evil-make-overriding-map mode-map 'normal)
    (evil-make-overriding-map mode-map 'motion)
    ;; Mirror the mode's own bindings into Evil normal+motion auxiliary
    ;; state.  This tier outranks Doom's custom operator bindings
    ;; (p/c/d/a/m/...), which a plain overriding map loses to, so every
    ;; advertised single-key affordance fires.  SPC is skipped so the
    ;; leader is never shadowed.
    (when (fboundp 'evil-define-key*)
      (dolist (b (ogent-evil--keymap-command-bindings mode-map))
        (let ((key (car b)) (cmd (cdr b)))
          (unless (member (key-description key) '("SPC" "<remap>"))
            (ignore-errors
              (evil-define-key* '(normal motion) mode-map key cmd))))))
    (add-hook mode-hook #'evil-normalize-keymaps)
    (let ((refresh refresh-fn)
          (refresh-force refresh-force-fn))
      (add-hook
       mode-hook
       (lambda ()
         (when (fboundp 'evil-local-set-key)
           (evil-local-set-key 'normal "gg" #'evil-goto-first-line)
           (evil-local-set-key 'normal "G" #'evil-goto-line)
           (evil-local-set-key 'normal "ZZ" #'quit-window)
           (evil-local-set-key 'normal "ZQ" #'quit-window)
           (when (commandp refresh)
             (evil-local-set-key 'normal "gr" refresh))
           (when (commandp refresh-force)
             (evil-local-set-key 'normal "gR" refresh-force))))))))

;;;###autoload
(defmacro ogent-evil-setup-display-mode (mode mode-map mode-hook &rest plist)
  "Defer canonical Evil display-buffer setup until Evil is loaded.
MODE and MODE-HOOK are quoted symbols; MODE-MAP is the keymap value.
PLIST accepts :refresh and :refresh-force commands bound to gr / gR.
See `ogent-evil-display-mode-setup'."
  `(with-eval-after-load 'evil
     (ogent-evil-display-mode-setup
      ,mode ,mode-map ,mode-hook
      ,(plist-get plist :refresh)
      ,(plist-get plist :refresh-force))))

;;; Utility Functions

(defun ogent-describe-bindings ()
  "Display all ogent keybindings in a help buffer."
  (interactive)
  (with-help-window "*Ogent Bindings*"
    (princ "Ogent Keybindings\n")
    (princ "=================\n\n")
    (princ (format "Vanilla prefix: %s\n" ogent-vanilla-prefix))
    (princ (format "Review prefix: %s\n" ogent-review-prefix))
    (when (featurep 'evil)
      (princ (format "Evil prefix: %s\n" ogent-evil-prefix)))
    (when (and ogent-enable-doom-bindings
               (boundp 'doom-leader-map)
               (keymapp doom-leader-map))
      (princ (format "Doom leader prefix: %s %s\n"
                     (if (and (boundp 'doom-leader-key)
                              (stringp doom-leader-key))
                         doom-leader-key
                       "SPC")
                     ogent-doom-prefix)))
    (princ "\n")
    (princ (format "%-12s %-8s %-30s %s\n" "Action" "Key" "Command" "Description"))
    (princ (make-string 70 ?-))
    (princ "\n")
    (dolist (entry ogent-action-registry)
      (let* ((name (car entry))
             (props (cdr entry))
             (key (plist-get props :key))
             (cmd (plist-get props :command))
             (desc (plist-get props :desc))
             (visual-p (plist-get props :visual)))
        (princ (format "%-12s %-8s %-30s %s%s\n"
                       name key cmd desc
                       (if visual-p " [visual]" "")))))
    ;; Review bindings
    (princ "\n")
    (princ "Review Keybindings (C-c o prefix)\n")
    (princ "----------------------------------\n")
    (dolist (entry ogent-review-action-registry)
      (let* ((name (car entry))
             (props (cdr entry))
             (key (plist-get props :key))
             (cmd (plist-get props :command))
             (desc (plist-get props :desc)))
        (princ (format "%-12s %-8s %-30s %s\n"
                       name key cmd desc))))))

(provide 'ogent-keys)

;;; ogent-keys.el ends here
