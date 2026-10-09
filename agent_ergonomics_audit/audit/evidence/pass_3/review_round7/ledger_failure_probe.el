;;; ledger_failure_probe.el --- Review-only callback probe -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-tool-process)
(let* ((root (expand-file-name
              "agent_ergonomics_audit/audit/evidence/pass_3/review_round7/ledger-probe/"
              "/work/"))
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-tool-require-approval nil)
       (ogent-ledger-enabled t)
       (ogent-ledger-file (expand-file-name "ledger.org" root))
       ;; Preserve this review's filesystem failure evidence in its owned tree.
       (ogent-test-tripwire-allowed-roots (cons root ogent-test-tripwire-allowed-roots))
       (callbacks 0) result process)
  (make-directory root t)
  (setq process
        (ogent-agent-call-async
         "shell" '(:command "sleep 0.05; printf success" :timeout 1)
         (lambda (data) (cl-incf callbacks) (setq result data))))
  ;; Start recording succeeds; completion recording now hits a directory.
  (setq ogent-ledger-file root)
  (let ((deadline (+ (float-time) 1)))
    (while (and (processp process) (process-live-p process)
                (< (float-time) deadline))
      (accept-process-output process 0.01)))
  (accept-process-output nil 0.05)
  (princ (format "process=%S exit=%S callbacks=%S result=%S callback_error=%S active=%S\n"
                 (and (processp process) (process-status process))
                 (and (processp process) (process-exit-status process))
                 callbacks result
                 (and (processp process) (process-get process 'ogent-callback-error))
                 ogent-tools--active-processes)))
