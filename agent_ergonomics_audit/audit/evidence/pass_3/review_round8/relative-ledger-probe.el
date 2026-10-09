;;; relative-ledger-probe.el --- Real process ledger destination probe -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-ui-toolcalls)
(let* ((origin (file-name-as-directory (ogent-test--provision-store-directory 'tools)))
       (other (file-name-as-directory (ogent-test--provision-store-directory 'tools)))
       (ogent-ledger-enabled t)
       (ogent-ledger-file "ledger.org")
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-tool-require-approval nil)
       (ogent-tools--active-processes nil)
       (ogent-tools-project-root origin)
       (callbacks 0) result process)
  (let ((default-directory origin))
    (setq process
          (ogent-agent-call-async "shell" '(:command "sleep 0.05; printf complete" :timeout 1)
                                  (lambda (value) (setq result value) (cl-incf callbacks)))))
  (let ((default-directory other) (deadline (+ (float-time) 3)))
    (while (and (process-live-p process) (< (float-time) deadline))
      (accept-process-output process 0.01))
    (accept-process-output nil 0.05))
  (princ (json-serialize
          (list :case "sdk-relative-ledger" :callbacks callbacks :result result
                :origin_ledger (with-temp-buffer
                                 (insert-file-contents (expand-file-name "ledger.org" origin))
                                 (buffer-string))
                :other_ledger (if (file-exists-p (expand-file-name "ledger.org" other))
                                  (with-temp-buffer
                                    (insert-file-contents (expand-file-name "ledger.org" other))
                                    (buffer-string)) "")
                :active_processes (length ogent-tools--active-processes))
          :null-object :json-null :false-object :json-false))
  (princ "\n"))
