;;; source_identity.el --- Compare actual top-level definitions -*- lexical-binding: t; -*-
(require 'json)
(defun scorerA-definition (path name)
  (with-temp-buffer
    (insert-file-contents path)
    (let (found)
      (condition-case nil
          (while (not found)
            (let ((form (read (current-buffer))))
              (when (and (listp form) (eq (car form) 'defun) (eq (cadr form) name)) (setq found form))))
        (end-of-file nil))
      (unless found (error "Missing %s in %s" name path)) found)))
(let ((base "/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerA/baseline_sources/")
      (post "/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerA/paired_sources_final/"))
  (dolist (group '(("lisp/ogent-tools.el" ogent-tool--read-file ogent-tool--glob ogent-tool--grep ogent-tool--grep-async ogent-tool--bash ogent-tool--bash-async ogent-tool--write-file ogent-tool--edit-file)
                   ("lisp/ogent-models.el" ogent-tool-get ogent-tool-spec-get ogent-tools-enabled-list)
                   ("lisp/ogent-tool-execution.el" ogent-tool-execution-wrapper)
                   ("lisp/ogent-doctor.el" ogent-doctor-run ogent-doctor-batch)))
    (dolist (name (cdr group))
      (let* ((b (scorerA-definition (concat base (car group)) name))
             (p (scorerA-definition (concat post (car group)) name))
             (print-length nil) (print-level nil))
        (princ (json-serialize
                (list :method (symbol-name name) :baseline_sha "b3caf9300c7336ef812ed061158f851c5a47ccf7"
                      :current_sha "9ac13b23032f40eccb9a627a824be45656292056" :file (car group)
                      :definition_equal (if (equal b p) t :false)
                      :baseline_definition_sha256 (secure-hash 'sha256 (prin1-to-string b))
                      :current_definition_sha256 (secure-hash 'sha256 (prin1-to-string p)))))
        (princ "\n")))))
