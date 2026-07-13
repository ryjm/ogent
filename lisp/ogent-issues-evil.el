;;; ogent-issues-evil.el --- Evil integration for ogent-issues -*- lexical-binding: t; -*-

;;; Commentary:
;; Optional Evil keybinding integration for ogent-issues, extracted from the
;; ogent-issues facade.  Required by the facade at load time; it self-registers
;; through `with-eval-after-load' so the bindings install once Evil is present.

;;; Code:

;; Core ogent-issues entry points and keymaps referenced below live in the
;; facade (`ogent-issues') and the detail satellite (`ogent-issues-detail').
;; Declare them here so this file byte-compiles on its own; it deliberately
;; avoids requiring the facade to keep the load graph acyclic.
(declare-function ogent-issues-refresh "ogent-issues")
(declare-function ogent-issues-refresh-force "ogent-issues")
(declare-function ogent-issues-next-section "ogent-issues")
(declare-function ogent-issues-prev-section "ogent-issues")
(declare-function ogent-issues-detail-refresh "ogent-issues-detail")
(defvar ogent-issues-mode-map)
(defvar ogent-issues-detail-mode-map)

;; Evil motions referenced in the optional Evil integration (fileonly:
;; defined via `evil-define-motion').
(declare-function evil-goto-line "ext:evil" t t)
(declare-function evil-goto-first-line "ext:evil" t t)
(declare-function evil-local-set-key "ext:evil" t t)

;;; Evil Integration
;; When evil is loaded, set up proper evil keybindings.
;; j/k are NOT bound in the mode map so evil users get normal line movement.
;; Use n/p for issue-to-issue navigation, gj/gk for section navigation.
;; This section must be at the end of the file, after all keymaps are defined.

;; Declare evil functions to avoid byte-compile warnings
(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-make-overriding-map "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")

(defun ogent-issues--setup-evil ()
  "Set up evil keybindings for ogent-issues modes.
Called after evil is loaded."
  (when (fboundp 'evil-set-initial-state)
    ;; Set initial state to normal for ogent-issues modes
    (evil-set-initial-state 'ogent-issues-mode 'normal)
    (evil-set-initial-state 'ogent-issues-detail-mode 'normal)
    ;; The structured editor is a text-editing buffer: drop straight into
    ;; insert state so typing works immediately.  C-c C-c / C-c C-k stay
    ;; reachable in every state, and the pill controls bind through a
    ;; `keymap' text property, which outranks Evil's state maps.
    (evil-set-initial-state 'ogent-issues-edit-mode 'insert)
    
    ;; Make our keymaps override evil's state maps for non-movement keys.
    ;; j/k are intentionally NOT in the mode map so evil handles them.
    (evil-make-overriding-map ogent-issues-mode-map 'all)
    (evil-make-overriding-map ogent-issues-detail-mode-map 'all)
    
    ;; Add evil-specific navigation using define-key on evil's state maps
    ;; This avoids the evil-define-key macro which causes load-order issues
    (when (boundp 'evil-normal-state-local-map)
      (add-hook 'ogent-issues-mode-hook
                (lambda ()
                  (evil-local-set-key 'normal "gg" #'evil-goto-first-line)
                  (evil-local-set-key 'normal "G" #'evil-goto-line)
                  (evil-local-set-key 'normal "gr" #'ogent-issues-refresh)
                  (evil-local-set-key 'normal "gR" #'ogent-issues-refresh-force)
                  (evil-local-set-key 'normal "gj" #'ogent-issues-next-section)
                  (evil-local-set-key 'normal "gk" #'ogent-issues-prev-section)
                  (evil-local-set-key 'normal "ZZ" #'quit-window)
                  (evil-local-set-key 'normal "ZQ" #'quit-window)))
      (add-hook 'ogent-issues-detail-mode-hook
                (lambda ()
                  (evil-local-set-key 'normal "gg" #'evil-goto-first-line)
                  (evil-local-set-key 'normal "G" #'evil-goto-line)
                  (evil-local-set-key 'normal "gr" #'ogent-issues-detail-refresh)
                  (evil-local-set-key 'normal "ZZ" #'quit-window)
                  (evil-local-set-key 'normal "ZQ" #'quit-window))))
    
    ;; Normalize keymaps when entering these modes
    (add-hook 'ogent-issues-mode-hook #'evil-normalize-keymaps)
    (add-hook 'ogent-issues-detail-mode-hook #'evil-normalize-keymaps)))

(with-eval-after-load 'evil
  (ogent-issues--setup-evil))

(provide 'ogent-issues-evil)

;;; ogent-issues-evil.el ends here
