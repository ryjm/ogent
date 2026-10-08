;;; probe_edit_intent.el --- Paired direct SDK name recovery -*- lexical-binding: t; -*-
(require 'json)
(require 'ogent-tools)
(let ((post-function (symbol-function 'ogent-tool--edit-file)))
  (unwind-protect
      (progn
        (load "/work/agent_ergonomics_audit/audit/partial/tiebreaker-baseline/lisp/ogent-tools.el" nil t)
        (dolist (stage '("baseline" "post"))
          (when (equal stage "post") (fset 'ogent-tool--edit-file post-function))
          (dolist (name '(ogent-tool--edit_file ogent-tool--edit-fiel ogent-tool--patch-file))
            (let ((record
                   (condition-case err
                       (list :stage stage :candidate (symbol-name name)
                             :fboundp (if (fboundp name) t :json-false)
                             :result (funcall name "/unused/no-mutation" "old" "new"))
                     (error (list :stage stage :candidate (symbol-name name)
                                  :fboundp (if (fboundp name) t :json-false)
                                  :error_type (symbol-name (car err))
                                  :error_message (error-message-string err))))))
              (princ (json-encode record)) (princ "\n")))))
    (fset 'ogent-tool--edit-file post-function)))
