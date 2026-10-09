;;; probe_boundary.el --- Independent freeze followups -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-tools)
(unless (equal (symbol-file 'ogent-tool--read-file 'defun) "/work/lisp/ogent-tools.el")
  (error "Current probe loaded unexpected source: %s" (symbol-file 'ogent-tool--read-file 'defun)))
(message "scorerA current source verified: %s" (symbol-file 'ogent-tool--read-file 'defun))
(defun scorerA-boundary-record (probe invocation thunk)
  (let ((print-level nil) (print-length nil))
    (princ (json-serialize (condition-case err
                              (list :probe probe :invocation invocation :outcome "returned" :result (prin1-to-string (funcall thunk)))
                            (error (list :probe probe :invocation invocation :outcome "condition" :condition (symbol-name (car err)) :message (error-message-string err))))))
    (princ "\n")))
(let ((ogent-tool-require-approval nil) (ogent-tools-show-progress nil))
  (scorerA-boundary-record
   "batch-canonical-and-string-freeze" "(ogent-agent-batch [first, read]) while first mutates the caller's later :tool and nested string"
   (lambda ()
     (let* ((wrote nil) (value (copy-sequence "original"))
            (later-call (list :tool "later-reader" :args (list :value (vector value))))
            (reader (list :name 'later-reader :args '((:name "value" :type "array")) :effects '((:kind read)) :function (lambda (v) (aref v 0))))
            (writer (list :name 'later-writer :args '((:name "value" :type "array")) :effects '((:kind write)) :function (lambda (_) (setq wrote t))))
            (first (list :name 'caller-mutator :args nil :effects '((:kind read)) :function (lambda () (setf (plist-get later-call :tool) "later-writer") (aset value 0 ?X) "prepared")))
            (ogent-tool-registry (list first reader writer))
            (result (ogent-agent-batch (list (list :tool "caller-mutator" :args nil) later-call))))
       (list :wrote wrote :second-value (plist-get (plist-get (aref (plist-get (plist-get result :data) :results) 1) :data) :value) :result result))))
  (scorerA-boundary-record
   "batch-object-freeze" "(ogent-agent-batch [first, reader]) while first changes a nested caller-owned hash-table object"
   (lambda ()
     (let* ((object (make-hash-table :test #'equal))
            (later (list :name 'object-reader :args '((:name "payload" :type "object")) :effects '((:kind read)) :function (lambda (o) (gethash "selection" o))))
            (first (list :name 'object-mutator :args nil :effects '((:kind read)) :function (lambda () (puthash "selection" "changed" object) "prepared")))
            (ogent-tool-registry (list first later)))
       (puthash "selection" "original" object)
       (ogent-agent-batch (list (list :tool "object-mutator" :args nil) (list :tool "object-reader" :args (list :payload object)))))))
  (let* ((root (ogent-test--provision-store-directory 'tools)) (default-directory root)
         (ogent-tools-project-root root) (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (ogent-tools-max-file-lines 1) (file (expand-file-name "pages.txt" root)))
    (with-temp-file file (insert "one\ntwo\nthree\n"))
    (scorerA-boundary-record "configured-read-limit" "(let ((ogent-tools-max-file-lines 1)) (ogent-agent-call \"read\" (:file_path FILE)))"
                            (lambda () (ogent-agent-call "read" (list :file_path file))))))
