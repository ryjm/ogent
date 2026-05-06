;;; ogent-armory-evil.el --- Evil integration for Armory buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers for keeping Armory display keymaps active in Evil normal and
;; motion states.

;;; Code:

(require 'cl-lib)

(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-make-overriding-map "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function evil-local-set-key "ext:evil-core")
(declare-function evil-next-line "ext:evil-commands")
(declare-function evil-previous-line "ext:evil-commands")

(defconst ogent-armory-evil-display-states '(normal motion)
  "Evil states that should expose Armory display-buffer commands.")

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
Each result is a list of the form (KEY COMMAND). Parent keymaps are ignored.
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

(defun ogent-armory-evil--key-bound-p (keymap key)
  "Return non-nil when KEYMAP has an effective binding for KEY."
  (let ((binding (lookup-key keymap key)))
    (and binding
         (not (numberp binding)))))

(defun ogent-armory-evil--binding-key-p (bindings key)
  "Return non-nil when BINDINGS already contains KEY."
  (cl-some (lambda (binding)
             (equal (car binding) key))
           bindings))

(defun ogent-armory-evil--install-fallback-navigation (keymap bindings states)
  "Install Evil movement keys for KEYMAP when Armory leaves them free."
  (unless (or (ogent-armory-evil--binding-key-p bindings (kbd "j"))
              (ogent-armory-evil--key-bound-p keymap (kbd "j")))
    (ogent-armory-evil-bind-local (kbd "j") #'evil-next-line states))
  (unless (or (ogent-armory-evil--binding-key-p bindings (kbd "k"))
              (ogent-armory-evil--key-bound-p keymap (kbd "k")))
    (ogent-armory-evil-bind-local (kbd "k") #'evil-previous-line states)))

(defun ogent-armory-evil-install-local-bindings (keymap &optional states)
  "Mirror KEYMAP command bindings into Evil STATES for the current buffer."
  (let ((target-states (or states ogent-armory-evil-display-states))
        (bindings (or (gethash keymap ogent-armory-evil--keymap-bindings)
                      (ogent-armory-evil-keymap-command-bindings keymap))))
    (dolist (binding bindings)
      (ogent-armory-evil-bind-local (car binding) (cadr binding) target-states))
    (ogent-armory-evil--install-fallback-navigation
     keymap bindings target-states)
    (ogent-armory-evil-bind-local (kbd "ZZ") #'quit-window target-states)
    (ogent-armory-evil-bind-local (kbd "ZQ") #'quit-window target-states)))

(defun ogent-armory-evil-setup-mode (mode keymap hook local-keys)
  "Set up Evil integration for MODE using KEYMAP, HOOK, and LOCAL-KEYS."
  (puthash keymap
           (ogent-armory-evil-keymap-command-bindings keymap)
           ogent-armory-evil--keymap-bindings)
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state mode 'normal)
    (when (fboundp 'evil-make-overriding-map)
      (evil-make-overriding-map keymap 'all))
    (add-hook hook local-keys)
    (when (fboundp 'evil-normalize-keymaps)
      (add-hook hook #'evil-normalize-keymaps))))

(provide 'ogent-armory-evil)

;;; ogent-armory-evil.el ends here
