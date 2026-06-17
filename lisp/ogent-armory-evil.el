;;; ogent-armory-evil.el --- Evil integration for Armory buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers for keeping Armory display keymaps active in Evil normal and
;; motion states.
;;
;; Historically this module *stripped* every alphabetic/digit key from Evil
;; states ("vim-safe"), which made the single-key affordances printed in every
;; Armory header line silently dead for Evil users.  Armory now uses the
;; canonical overriding-map integration in `ogent-keys.el'
;; (`ogent-evil-display-mode-setup', the magit/dired pattern): keys the mode
;; binds win over Evil, keys it does not bind keep their Evil motion meaning.
;; The legacy mirroring/reserved-key helpers below are retained for callers and
;; tests but are no longer used to drive Armory Evil setup.

;;; Code:

(require 'seq)
(require 'ogent-keys)

(declare-function ogent-evil-display-mode-setup "ogent-keys")
(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function evil-local-set-key "ext:evil-core")

(defconst ogent-armory-evil-display-states '(normal motion)
  "Evil states that should expose Armory `display-buffer' commands.")

(defconst ogent-armory-evil-reserved-normal-key-descriptions
  (append
   (delq nil
         (mapcar (lambda (code)
                   (let ((key (char-to-string code)))
                     (unless (equal key "q")
                       key)))
                 (number-sequence ?a ?z)))
   (mapcar #'char-to-string (number-sequence ?A ?Z))
   (mapcar #'number-to-string (number-sequence 0 9))
   '("SPC" "DEL" "ESC"
     "!" "\"" "#" "$" "%" "&" "'" "(" ")" "*" "+" "," "-" "." "/"
     ":" ";" "<" "=" ">" "?" "@" "[" "\\" "]" "^" "_" "`"
     "{" "|" "}" "~"))
  "Bare normal-state keys that Armory must not mirror into Evil.

Armory buffers use these keys freely for vanilla Emacs users, but Evil users
need the normal-state movement, search, repeat, text-object, and edit command
surface to remain predictable.  Armory actions should use RET, TAB, q, M-*
navigation, or explicit prefix-key chords in Evil states.")

(defvar ogent-armory-evil--keymap-bindings (make-hash-table :test 'eq)
  "Direct Armory command bindings captured before Evil rewrites keymaps.")

(defun ogent-armory-evil--direct-keymap-entries (keymap)
  "Return KEYMAP entries before any parent keymap."
  (let ((entries (cdr keymap))
        direct)
    (while (and entries
                (not (eq (car entries) 'keymap)))
      (when (consp (car entries))
        (push (car entries) direct))
      (setq entries (cdr entries)))
    (nreverse direct)))

(defun ogent-armory-evil--canonical-key (key)
  "Return KEY in a form accepted by `evil-local-set-key'."
  (kbd (key-description key)))

(defun ogent-armory-evil-keymap-command-bindings (keymap &optional prefix)
  "Return direct command bindings from KEYMAP.
Each result is a list of the form (KEY COMMAND).  Parent keymaps are ignored.
PREFIX is used internally while walking prefix maps."
  (let (bindings)
    (dolist (entry (ogent-armory-evil--direct-keymap-entries keymap))
      (let* ((event (car entry))
             (binding (cdr entry))
             (key (vconcat (or prefix []) (vector event))))
        (cond
         ((commandp binding)
          (setq bindings
                (nconc bindings
                       (list (list (ogent-armory-evil--canonical-key key)
                                   binding)))))
         ((keymapp binding)
          (setq bindings
                (nconc bindings
                       (ogent-armory-evil-keymap-command-bindings
                        binding key)))))))
    bindings))

(defun ogent-armory-evil-bind-local (key command &optional states)
  "Bind KEY to COMMAND locally for Evil STATES."
  (when (and (fboundp 'evil-local-set-key)
             (commandp command))
    (dolist (state (or states ogent-armory-evil-display-states))
      (evil-local-set-key state key command))))

(defun ogent-armory-evil-reserved-key-p (key)
  "Return non-nil when KEY should keep its Evil normal-state meaning."
  (member (key-description key)
          ogent-armory-evil-reserved-normal-key-descriptions))

(defun ogent-armory-evil-state-command-bindings (keymap)
  "Return KEYMAP command bindings that are safe to mirror into Evil states."
  (seq-remove
   (lambda (binding)
     (ogent-armory-evil-reserved-key-p (car binding)))
   (ogent-armory-evil-keymap-command-bindings keymap)))

(defun ogent-armory-evil-install-local-bindings (keymap &optional states)
  "Mirror KEYMAP command bindings into Evil STATES for the current buffer."
  (let ((target-states (or states ogent-armory-evil-display-states))
        (bindings (or (gethash keymap ogent-armory-evil--keymap-bindings)
                      (ogent-armory-evil-keymap-command-bindings keymap))))
    (setq bindings
          (seq-remove
           (lambda (binding)
             (ogent-armory-evil-reserved-key-p (car binding)))
           bindings))
    (dolist (binding bindings)
      (ogent-armory-evil-bind-local (car binding) (cadr binding) target-states))
    (ogent-armory-evil-bind-local (kbd "ZZ") #'quit-window target-states)
    (ogent-armory-evil-bind-local (kbd "ZQ") #'quit-window target-states)))

(defun ogent-armory-evil--refresh-command (keymap)
  "Return the refresh command bound to `g' in KEYMAP, if any.
Armory display maps bind `g' to their `*-refresh' command; this is
re-exposed under the Evil-idiomatic `gr'."
  (let ((cmd (lookup-key keymap "g")))
    (and (commandp cmd) cmd)))

(defun ogent-armory-evil-setup-mode (mode keymap hook local-keys)
  "Set up Evil integration for MODE using KEYMAP and HOOK.

LOCAL-KEYS (legacy: a function mirroring bindings into Evil local
maps) is accepted for backward compatibility but no longer used.
Armory display maps now override Evil `normal' and `motion' state
directly via `ogent-evil-display-mode-setup', so every single-key
affordance shown in the buffer fires under Evil exactly as in vanilla
Emacs, while unbound keys keep their Evil motion meaning."
  (ignore local-keys)
  (puthash keymap
           (ogent-armory-evil-keymap-command-bindings keymap)
           ogent-armory-evil--keymap-bindings)
  (ogent-evil-display-mode-setup
   mode keymap hook
   (ogent-armory-evil--refresh-command keymap)))

(provide 'ogent-armory-evil)

;;; ogent-armory-evil.el ends here
