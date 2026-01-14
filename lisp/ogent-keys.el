;;; ogent-keys.el --- Unified keybinding system for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a unified keybinding system with feature parity between
;; vanilla Emacs and evil-mode bindings.
;;
;; All bindable actions are defined in `ogent-action-registry'.
;; Bindings are generated from this registry for both systems.

;;; Code:

(require 'cl-lib)

;; Declare evil functions to avoid byte-compile warnings
(declare-function evil-define-key* "ext:evil-core")

;; Declare hydra commands (defined in ogent-ui-hydra.el)
(declare-function ogent-navigate "ogent-ui-hydra")
(declare-function ogent-edit-menu "ogent-ui-hydra")
(declare-function ogent-request-menu "ogent-ui-hydra")

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

;; Declare Gas Town commands (defined in ogent-gastown.el)
(declare-function ogent-gastown-dispatch "ogent-gastown")

(defgroup ogent-keys nil
  "Keybinding configuration for ogent."
  :group 'ogent)

;;; Customization

(defcustom ogent-vanilla-prefix "C-c ."
  "Prefix for vanilla Emacs keybindings.
This prefix is used for all ogent commands in standard Emacs."
  :type 'string
  :group 'ogent-keys)

(defcustom ogent-evil-prefix "SPC e"
  "Prefix for evil leader keybindings.
This prefix is used with evil-mode's leader key system."
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
    ;; Gas Town
    (gastown          :key "G" :command ogent-gastown-dispatch
                      :desc "Gas Town menu")
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

(defun ogent-setup-evil-bindings (keymap)
  "Set up evil keybindings in KEYMAP from action registry.
Requires evil-mode to be loaded. Uses leader key prefix."
  (when (and ogent-enable-evil-bindings
             (featurep 'evil))
    (require 'evil)
    ;; Use evil-define-key* (the function version) instead of the macro
    ;; to avoid compile-time expansion issues
    (when (fboundp 'evil-define-key*)
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
			      (kbd (concat ogent-evil-prefix " " key)) cmd)))))))

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
  (with-eval-after-load 'which-key
    (ogent-setup-which-key)))

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
