;;; ogent-org-compat.el --- Org compatibility hooks for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Compatibility helpers for stale Org capture builds and deferred Org Babel
;; registration.

;;; Code:

;; Older Org builds may not define this variable until `org-capture' loads.
(defvar org-capture-templates-contexts)

(defun ogent--ensure-org-capture-templates-contexts (&rest _)
  "Ensure stale Org capture builds define `org-capture-templates-contexts'."
  (unless (default-boundp 'org-capture-templates-contexts)
    (setq-default org-capture-templates-contexts nil))
  (unless (boundp 'org-capture-templates-contexts)
    (setq org-capture-templates-contexts
          (default-value 'org-capture-templates-contexts))))

(defun ogent--with-org-capture-templates-contexts (fn &rest args)
  "Call FN with ARGS and `org-capture-templates-contexts' safely bound."
  (ogent--ensure-org-capture-templates-contexts)
  (let ((org-capture-templates-contexts
         (if (boundp 'org-capture-templates-contexts)
             org-capture-templates-contexts
           nil)))
    (apply fn args)))

(defun ogent--advise-org-capture-contexts (symbol)
  "Advise SYMBOL to tolerate stale Org capture builds."
  (unless (advice-member-p #'ogent--with-org-capture-templates-contexts symbol)
    (advice-add symbol :around #'ogent--with-org-capture-templates-contexts)))

(ogent--ensure-org-capture-templates-contexts)

(eval-after-load 'org-capture
  '(progn
     (ogent--ensure-org-capture-templates-contexts)
     (ogent--advise-org-capture-contexts 'org-capture)
     (ogent--advise-org-capture-contexts 'org-capture-goto-target)
     (ogent--advise-org-capture-contexts 'org-capture-select-template)))

(eval-after-load 'org
  '(when (boundp 'org-babel-load-languages)
     (add-to-list 'org-babel-load-languages '(ogent . t))))

(provide 'ogent-org-compat)
;;; ogent-org-compat.el ends here
