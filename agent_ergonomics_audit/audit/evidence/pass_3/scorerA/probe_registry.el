;;; probe_registry.el --- Real local gptel registry probes -*- lexical-binding: t; -*-
(load "/tmp/ogent-fixdeps/30.2/elpa/gptel-20261007.432/gptel-request.el" nil nil t)
(require 'ogent-agent)
(require 'ogent-tools)
(unless (equal (symbol-file 'ogent-tool--read-file 'defun) "/work/lisp/ogent-tools.el")
  (error "Current probe loaded unexpected source: %s" (symbol-file 'ogent-tool--read-file 'defun)))
(message "scorerA current source verified: %s" (symbol-file 'ogent-tool--read-file 'defun))
(defun scorerA-registry-record (probe invocation thunk)
  (let ((record (condition-case err
                    (let ((print-length nil) (print-level nil))
                      (list :probe probe :invocation invocation :outcome "returned" :result (prin1-to-string (funcall thunk))))
                  (error (list :probe probe :invocation invocation :outcome "condition" :condition (symbol-name (car err)) :message (error-message-string err))))))
    (princ (json-serialize record)) (princ "\n")))
(let ((ogent-tool-registry (copy-tree ogent-tools-default-registry))
      (ogent--tools-registered nil) (ogent--tool-specs-registered nil)
      (ogent--tool-formats-registered nil) (gptel--known-tools nil))
  (dotimes (index 2)
    (scorerA-registry-record (format "get-alias-%d" index) "(gptel-tool-name (ogent-tool-get \"cat\"))"
                            (lambda () (gptel-tool-name (ogent-tool-get "cat"))))
    (scorerA-registry-record (format "spec-alias-%d" index) "(ogent-tool-spec-get \"cat\")"
                            (lambda () (ogent-tool-spec-get "cat")))
    (scorerA-registry-record (format "enabled-%d" index) "(mapcar #'gptel-tool-name (ogent-tools-enabled-list))"
                            (lambda () (mapcar #'gptel-tool-name (ogent-tools-enabled-list)))))
  (scorerA-registry-record "get-typo" "(ogent-tool-get \"read-fiel\")" (lambda () (ogent-tool-get "read-fiel")))
  (scorerA-registry-record "spec-typo" "(ogent-tool-spec-get \"read-fiel\")" (lambda () (ogent-tool-spec-get "read-fiel")))
  (scorerA-registry-record "enabled-typo" "(let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))"
                          (lambda () (let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))))

)
