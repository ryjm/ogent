;;; ogent-keys.el --- Unified keybinding system for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a unified keybinding system with feature parity between
;; vanilla Emacs and evil-mode bindings.
;;
;; All bindable actions are defined in `ogent-action-registry'.
;; Bindings are generated from this registry for both systems.

;;; Code:

(require 'cl-lib)

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
                      :desc "Show codemap")
    ;; Editing
    (edit-menu        :key "e" :command ogent-edit-menu
                      :desc "Edit menu")
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
    ;; Navigation
    (backlinks        :key "b" :command ogent-show-backlinks
                      :desc "Show backlinks")
    (graph            :key "g" :command ogent-show-dependency-graph
                      :desc "Dependency graph")
    (open-block       :key "o" :command ogent-open-block
                      :desc "Open block")
    ;; Misc
    (ask              :key "?" :command ogent-ask
                      :desc "Quick ask"
                      :visual t)
    (notes            :key "d" :command ogent-notes-capture
                      :desc "Capture notes"))
  "Registry of ogent actions with keys and commands.
Each entry is (NAME :key KEY :command CMD :desc DESC [:visual t]).
The :visual flag indicates the action should also be bound in visual state.")

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

(defun ogent-setup-evil-bindings (keymap)
  "Set up evil keybindings in KEYMAP from action registry.
Requires evil-mode to be loaded. Uses leader key prefix."
  (when (and ogent-enable-evil-bindings
             (featurep 'evil))
    (require 'evil)
    (dolist (entry ogent-action-registry)
      (let* ((name (car entry))
             (props (cdr entry))
             (key (plist-get props :key))
             (cmd (plist-get props :command))
             (visual-p (plist-get props :visual)))
        ;; Normal state binding
        (evil-define-key 'normal keymap
          (kbd (concat ogent-evil-prefix " " key)) cmd)
        ;; Visual state for region-based actions
        (when visual-p
          (evil-define-key 'visual keymap
            (kbd (concat ogent-evil-prefix " " key)) cmd))))))

(defun ogent-setup-which-key ()
  "Set up which-key descriptions for ogent prefixes."
  (when (featurep 'which-key)
    (which-key-add-key-based-replacements
      ogent-vanilla-prefix "ogent")
    (when (and ogent-enable-evil-bindings (featurep 'evil))
      (which-key-add-key-based-replacements
        ogent-evil-prefix "ogent"))))

(defun ogent-setup-all-bindings (keymap)
  "Set up all keybindings in KEYMAP.
This sets up vanilla bindings, evil bindings (if available),
and which-key integration."
  (ogent-setup-vanilla-bindings keymap)
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
                       (if visual-p " [visual]" "")))))))

(provide 'ogent-keys)

;;; ogent-keys.el ends here
