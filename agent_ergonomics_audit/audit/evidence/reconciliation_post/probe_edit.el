;;; probe_edit.el --- Direct mutation and approval boundary evidence -*- lexical-binding: t; -*-
(require 'json)
(require 'ogent-tools)
(require 'ogent-agent)
(require 'ogent-tool-execution)
(defun reconciliation--emit (stage label thunk)
  (let ((record
         (condition-case err
             (list :stage stage :probe label :result (funcall thunk))
           (error (list :stage stage :probe label :error_type (symbol-name (car err))
                        :error_message (error-message-string err))))))
    (princ (json-encode record)) (princ "\n")))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (path (expand-file-name "reconcile-edit.txt" root))
       (ogent-tools-show-progress nil)
       (post-function (symbol-function 'ogent-tool--edit-file))
       (post-registry ogent-tools-default-registry))
  (unwind-protect
      (progn
        (load "/work/agent_ergonomics_audit/audit/partial/tiebreaker-baseline/lisp/ogent-tools.el" nil t)
        (dolist (stage '("baseline" "post"))
          (when (equal stage "post")
            (fset 'ogent-tool--edit-file post-function)
            (setq ogent-tools-default-registry post-registry))
          (dotimes (_ 2)
            (with-temp-file path (insert "before unique after"))
            (reconciliation--emit stage "unique-first-try"
                                  (lambda () (ogent-tool--edit-file path "unique" "changed"))))
          (with-temp-file path (insert "same same"))
          (reconciliation--emit stage "ambiguous-default"
                                (lambda () (ogent-tool--edit-file path "same" "new")))
          (reconciliation--emit stage "ambiguous-default-file"
                                (lambda () (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (with-temp-file path (insert "same same"))
          (reconciliation--emit stage "json-false"
                                (lambda () (ogent-tool--edit-file path "same" "new" :json-false)))
          (reconciliation--emit stage "json-false-file"
                                (lambda () (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (with-temp-file path (insert "same same"))
          (reconciliation--emit stage "explicit-replace-all"
                                (lambda () (ogent-tool--edit-file path "same" "new" t)))
          (reconciliation--emit stage "missing-old-context"
                                (lambda () (ogent-tool--edit-file path "absent" "new")))
          (when (equal stage "post")
            (reconciliation--emit stage "empty-context"
                                  (lambda () (ogent-tool--edit-file path "" "new" t)))
            (reconciliation--emit stage "wrong-boolean"
                                  (lambda () (ogent-tool--edit-file path "same" "new" "false")))))
        (reconciliation--emit "post" "method-docstring" (lambda () (documentation 'ogent-tool--edit-file)))
        (let* ((spec (cl-find 'edit-file post-registry :key (lambda (s) (plist-get s :name))))
               (ogent-tool-registry (list spec))
               (ogent-tool-require-approval t)
               (ogent-tool--denied-tools '("edit-file"))
               (ogent-tool-allow-list nil))
          (with-temp-file path (insert "unique"))
          (reconciliation--emit "post" "registered-wrapper-denied"
                                (lambda () (funcall (ogent-tool-execution-wrapper spec) path "unique" "new")))
          (reconciliation--emit "post" "registered-wrapper-file"
                                (lambda () (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (reconciliation--emit "post" "raw-call-under-deny-policy"
                                (lambda () (ogent-tool--edit-file path "unique" "new")))
          (reconciliation--emit "post" "raw-call-file"
                                (lambda () (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (reconciliation--emit "post" "live-capabilities" (lambda () (ogent-agent-capabilities 'json)))
          (reconciliation--emit "post" "handbook" #'ogent-agent-guide)))
    (fset 'ogent-tool--edit-file post-function)
    (setq ogent-tools-default-registry post-registry)))
