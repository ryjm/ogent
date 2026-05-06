;;; ogent-cabinet-evil.el --- Evil integration for Cabinet buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers for keeping Cabinet display keymaps active in Evil normal and
;; motion states.

;;; Code:

(require 'cl-lib)

(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-make-overriding-map "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function evil-local-set-key "ext:evil-core")
(declare-function evil-next-line "ext:evil-commands")
(declare-function evil-previous-line "ext:evil-commands")

(defconst ogent-cabinet-evil-display-states '(normal motion)
  "Evil states that should expose Cabinet display-buffer commands.")

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

(defun ogent-cabinet-evil--key-bound-p (keymap key)
  "Return non-nil when KEYMAP has an effective binding for KEY."
  (let ((binding (lookup-key keymap key)))
    (and binding
         (not (numberp binding)))))

(defun ogent-cabinet-evil--binding-key-p (bindings key)
  "Return non-nil when BINDINGS already contains KEY."
  (cl-some (lambda (binding)
             (equal (car binding) key))
           bindings))

(defun ogent-cabinet-evil--install-fallback-navigation (keymap bindings states)
  "Install Evil movement keys for KEYMAP when Cabinet leaves them free."
  (unless (or (ogent-cabinet-evil--binding-key-p bindings (kbd "j"))
              (ogent-cabinet-evil--key-bound-p keymap (kbd "j")))
    (ogent-cabinet-evil-bind-local (kbd "j") #'evil-next-line states))
  (unless (or (ogent-cabinet-evil--binding-key-p bindings (kbd "k"))
              (ogent-cabinet-evil--key-bound-p keymap (kbd "k")))
    (ogent-cabinet-evil-bind-local (kbd "k") #'evil-previous-line states)))

(defun ogent-cabinet-evil-install-local-bindings (keymap &optional states)
  "Mirror KEYMAP command bindings into Evil STATES for the current buffer."
  (let ((target-states (or states ogent-cabinet-evil-display-states))
        (bindings (or (gethash keymap ogent-cabinet-evil--keymap-bindings)
                      (ogent-cabinet-evil-keymap-command-bindings keymap))))
    (dolist (binding bindings)
      (ogent-cabinet-evil-bind-local (car binding) (cadr binding) target-states))
    (ogent-cabinet-evil--install-fallback-navigation
     keymap bindings target-states)
    (ogent-cabinet-evil-bind-local (kbd "ZZ") #'quit-window target-states)
    (ogent-cabinet-evil-bind-local (kbd "ZQ") #'quit-window target-states)))

(defun ogent-cabinet-evil-setup-mode (mode keymap hook local-keys)
  "Set up Evil integration for MODE using KEYMAP, HOOK, and LOCAL-KEYS."
  (puthash keymap
           (ogent-cabinet-evil-keymap-command-bindings keymap)
           ogent-cabinet-evil--keymap-bindings)
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state mode 'normal)
    (when (fboundp 'evil-make-overriding-map)
      (evil-make-overriding-map keymap 'all))
    (add-hook hook local-keys)
    (when (fboundp 'evil-normalize-keymaps)
      (add-hook hook #'evil-normalize-keymaps))))

(provide 'ogent-cabinet-evil)

;;; ogent-cabinet-evil.el ends here
