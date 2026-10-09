;;; probe_identity.el --- Paired source-form identity -*- lexical-binding: t; -*-
(require 'cl-lib)
(defun scorerB-definitions (file)
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (listp form) (eq (car form) 'defun))
                (push (cons (cadr form) form) forms))))
        (end-of-file forms)))))
(let ((baseline "/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerB/baseline-source/"))
  (dolist (item '(("lisp/ogent-tools.el" ogent-tool--grep-async ogent-tool--bash-async
                  ogent-tool--write-file ogent-tool--edit-file)
                 ("lisp/ogent-models.el" ogent-tool-get ogent-tool-spec-get ogent-tools-enabled-list)
                 ("lisp/ogent-doctor.el" ogent-doctor-run ogent-doctor-batch)))
    (let ((current (scorerB-definitions (concat "/work/" (car item))))
          (old (scorerB-definitions (concat baseline (car item)))))
      (dolist (method (cdr item))
        (princ (format "%s %s\n" method
                       (and (assq method current) (assq method old)
                            (equal (cdr (assq method current)) (cdr (assq method old))))))))))
