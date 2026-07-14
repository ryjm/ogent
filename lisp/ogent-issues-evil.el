;;; ogent-issues-evil.el --- Evil integration for ogent-issues -*- lexical-binding: t; -*-

;;; Commentary:
;; Optional Evil keybinding integration for ogent-issues, extracted from the
;; ogent-issues facade.  Required by the facade at load time; it self-registers
;; through `with-eval-after-load' so the bindings install once Evil is present.
;;
;; The list and detail display modes delegate to the canonical
;; `ogent-evil-display-mode-setup' helper in `ogent-keys' (the magit/dired
;; overriding-map pattern): Evil `normal' initial state, the mode map
;; overriding Evil normal/motion state, and the gg/G/gr/gR/ZZ/ZQ local keys.
;; Only what the helper does not cover stays bespoke here: the structured
;; editor's `insert' initial state and the list buffer's gj/gk
;; section-navigation keys.

;;; Code:

(require 'ogent-keys)

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

;; Evil functions referenced below; only called once Evil is loaded.
(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-local-set-key "ext:evil" t t)

(defun ogent-issues--setup-evil ()
  "Set up Evil keybindings for ogent-issues modes.
Called after Evil is loaded.  Route the list and detail modes through
`ogent-evil-display-mode-setup', which sets the `normal' initial
state, marks the mode map as overriding Evil normal/motion state, and
installs the gg/G/gr/gR/ZZ/ZQ local keys.  j/k are NOT bound in the
mode maps so Evil users get normal line movement; use n/p for
issue-to-issue navigation and gj/gk for section navigation."
  (ogent-evil-display-mode-setup
   'ogent-issues-mode ogent-issues-mode-map 'ogent-issues-mode-hook
   #'ogent-issues-refresh #'ogent-issues-refresh-force)
  (ogent-evil-display-mode-setup
   'ogent-issues-detail-mode ogent-issues-detail-mode-map
   'ogent-issues-detail-mode-hook
   #'ogent-issues-detail-refresh)
  ;; The structured editor is a text-editing buffer: drop straight into
  ;; insert state so typing works immediately.  C-c C-c / C-c C-k stay
  ;; reachable in every state, and the pill controls bind through a
  ;; `keymap' text property, which outranks Evil's state maps.
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'ogent-issues-edit-mode 'insert))
  ;; Section navigation is specific to the list buffer and outside the
  ;; canonical helper's key surface; install it the same buffer-local way.
  (when (boundp 'evil-normal-state-local-map)
    (add-hook 'ogent-issues-mode-hook
              (lambda ()
                (when (fboundp 'evil-local-set-key)
                  (evil-local-set-key 'normal "gj" #'ogent-issues-next-section)
                  (evil-local-set-key 'normal "gk" #'ogent-issues-prev-section))))))

(with-eval-after-load 'evil
  (ogent-issues--setup-evil))

(provide 'ogent-issues-evil)

;;; ogent-issues-evil.el ends here
