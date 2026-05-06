;;; ogent-cabinet-evil.el --- Evil integration for Cabinet buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers for keeping Cabinet display keymaps active in Evil normal and
;; motion states.

;;; Code:

(require 'seq)

(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function evil-local-set-key "ext:evil-core")

(defconst ogent-cabinet-evil-display-states '(normal motion)
  "Evil states that should expose Cabinet display-buffer commands.")

(defconst ogent-cabinet-evil-reserved-normal-key-descriptions
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
  "Bare normal-state keys that Cabinet must not mirror into Evil.

Cabinet buffers use these keys freely for vanilla Emacs users, but Evil users
need the normal-state movement, search, repeat, text-object, and edit command
surface to remain predictable.  Cabinet actions should use RET, TAB, q, M-*
navigation, or explicit C-c chords in Evil states.")

(defvar ogent-cabinet-evil--keymap-bindings (make-hash-table :test 'eq)
  "Direct Cabinet command bindings captured before Evil rewrites keymaps.")

(defun ogent-cabinet-evil--direct-keymap-entries (keymap)
  "Return KEYMAP entries before any parent keymap."
  (let ((entries (cdr keymap))
        direct)
    (while (and entries
                (not (eq (car entries) 'keymap)))
      (when (consp (car entries))
        (push (car entries) direct))
      (setq entries (cdr entries)))
    (nreverse direct)))

(defun ogent-cabinet-evil--canonical-key (key)
  "Return KEY in a form accepted by `evil-local-set-key'."
  (kbd (key-description key)))

(defun ogent-cabinet-evil-keymap-command-bindings (keymap &optional prefix)
  "Return direct command bindings from KEYMAP.
Each result is a list of the form (KEY COMMAND). Parent keymaps are ignored.
PREFIX is used internally while walking prefix maps."
  (let (bindings)
    (dolist (entry (ogent-cabinet-evil--direct-keymap-entries keymap))
      (let* ((event (car entry))
             (binding (cdr entry))
             (key (vconcat (or prefix []) (vector event))))
        (cond
         ((commandp binding)
          (setq bindings
                (nconc bindings
                       (list (list (ogent-cabinet-evil--canonical-key key)
                                   binding)))))
         ((keymapp binding)
          (setq bindings
                (nconc bindings
                       (ogent-cabinet-evil-keymap-command-bindings
                        binding key)))))))
    bindings))

(defun ogent-cabinet-evil-bind-local (key command &optional states)
  "Bind KEY to COMMAND locally for Evil STATES."
  (when (and (fboundp 'evil-local-set-key)
             (commandp command))
    (dolist (state (or states ogent-cabinet-evil-display-states))
      (evil-local-set-key state key command))))

(defun ogent-cabinet-evil-reserved-key-p (key)
  "Return non-nil when KEY should keep its Evil normal-state meaning."
  (member (key-description key)
          ogent-cabinet-evil-reserved-normal-key-descriptions))

(defun ogent-cabinet-evil-state-command-bindings (keymap)
  "Return KEYMAP command bindings that are safe to mirror into Evil states."
  (seq-remove
   (lambda (binding)
     (ogent-cabinet-evil-reserved-key-p (car binding)))
   (ogent-cabinet-evil-keymap-command-bindings keymap)))

(defun ogent-cabinet-evil-install-local-bindings (keymap &optional states)
  "Mirror KEYMAP command bindings into Evil STATES for the current buffer."
  (let ((target-states (or states ogent-cabinet-evil-display-states))
        (bindings (or (gethash keymap ogent-cabinet-evil--keymap-bindings)
                      (ogent-cabinet-evil-keymap-command-bindings keymap))))
    (setq bindings
          (seq-remove
           (lambda (binding)
             (ogent-cabinet-evil-reserved-key-p (car binding)))
           bindings))
    (dolist (binding bindings)
      (ogent-cabinet-evil-bind-local (car binding) (cadr binding) target-states))
    (ogent-cabinet-evil-bind-local (kbd "ZZ") #'quit-window target-states)
    (ogent-cabinet-evil-bind-local (kbd "ZQ") #'quit-window target-states)))

(defun ogent-cabinet-evil-setup-mode (mode keymap hook local-keys)
  "Set up Evil integration for MODE using KEYMAP, HOOK, and LOCAL-KEYS."
  (puthash keymap
           (ogent-cabinet-evil-keymap-command-bindings keymap)
           ogent-cabinet-evil--keymap-bindings)
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state mode 'normal)
    (add-hook hook local-keys)
    (when (fboundp 'evil-normalize-keymaps)
      (add-hook hook #'evil-normalize-keymaps))))

(provide 'ogent-cabinet-evil)

;;; ogent-cabinet-evil.el ends here
