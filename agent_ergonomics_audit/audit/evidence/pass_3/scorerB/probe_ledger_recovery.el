;;; probe_ledger_recovery.el --- Real ledger I/O recovery fixtures -*- lexical-binding: t; -*-
(require 'ogent-tools)
(require 'ogent-agent)
(require 'ogent-ui-toolcalls)
(require 'json)
(setq coding-system-for-write 'utf-8-unix)
(defun scorerB-fault-ledger-destination ()
  "Preserve the actual start ledger, then obstruct its captured destination."
  (let ((file (expand-file-name ogent-ledger-file)))
    (rename-file file (concat file ".started"))
    (make-directory file)))
(defun scorerB-ledger-emit (name function)
  (let ((result (condition-case error
                    (list :status "returned" :value (funcall function))
                  (error (list :status "signalled" :condition (format "%s" (car error))
                               :message (error-message-string error))))))
    (princ (concat (json-serialize (list :probe name :result result)
                                   :null-object :json-null :false-object :json-false) "\n"))))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (target (expand-file-name "completed.txt" root))
       (ogent-tools-project-root root)
       (ogent-ledger-enabled t)
       (ogent-ledger-file (expand-file-name "ledger.org" root))
       (ogent-tool-allow-list '("ledger-mutation" "ledger-immediate" "ledger-ui" "ledger-start"))
       (ogent-tool--denied-tools nil)
       (effects '((:kind write :target file :scope workspace :risk low))))
  (scorerB-ledger-emit
   "sync-completion-io-failure-retains-mutation"
   (lambda ()
     (let* ((calls 0)
            (spec (list :name 'ledger-mutation :description "One local fixture write"
                        :args nil :effects effects
                        :function (lambda ()
                                    (cl-incf calls)
                                    (with-temp-file target (insert "completed bytes"))
                                    (scorerB-fault-ledger-destination)
                                    "completed mutation")))
            (ogent-tool-registry (list spec))
            (result (ogent-agent-call "ledger-mutation" nil)))
       (list :calls calls :result result
             :bytes (with-temp-buffer (insert-file-contents target) (buffer-string))))))
  (setq ogent-ledger-file (expand-file-name "async-ledger.org" root))
  (scorerB-ledger-emit
   "immediate-async-io-failure-delivers-once-and-returns-nil"
   (lambda ()
     (let* ((calls 0) (callbacks 0) terminal
            (spec (list :name 'ledger-immediate :description "Immediate local completion"
                        :async t :args nil :effects effects
                        :function (lambda (callback)
                                    (cl-incf calls)
                                    (scorerB-fault-ledger-destination)
                                    (funcall callback "retained async bytes"
                                             '(user-error "fixture tool-specific failure"))
                                    (funcall callback "duplicate completion")
                                    "arbitrary non-process return")))
            (ogent-tool-registry (list spec))
            (returned (ogent-agent-call-async
                       "ledger-immediate" nil
                       (lambda (result) (cl-incf callbacks) (setq terminal result)))))
       (list :calls calls :callbacks callbacks :returned_nil (if (null returned) t :json-false)
             :terminal terminal))))
  (setq ogent-ledger-file (expand-file-name "ui-ledger.org" root))
  (scorerB-ledger-emit
   "legacy-ui-completion-retains-data-and-visible-warning"
   (lambda ()
     (let* ((calls 0)
            (spec (list :name 'ledger-ui :description "UI local fixture write"
                        :args nil :effects effects
                        :function (lambda ()
                                    (cl-incf calls)
                                    (with-temp-file target (insert "UI completed bytes"))
                                    (scorerB-fault-ledger-destination)
                                    "UI completed mutation")))
            (ogent-tool-registry (list spec))
            (reply (ogent-ui--execute-tool 'ledger-ui nil)))
       (list :calls calls :reply reply
             :bytes (with-temp-buffer (insert-file-contents target) (buffer-string))))))
  (setq ogent-ledger-file root)
  (scorerB-ledger-emit
   "start-io-failure-prevents-execution"
   (lambda ()
     (let* ((calls 0) (callbacks 0) terminal
            (spec (list :name 'ledger-start :description "Must never execute"
                        :async t :args nil :effects effects
                        :function (lambda (callback)
                                    (cl-incf calls)
                                    (funcall callback "unexpected execution"))))
            (ogent-tool-registry (list spec))
            (returned (ogent-agent-call-async
                       "ledger-start" nil
                       (lambda (result) (cl-incf callbacks) (setq terminal result)))))
       (list :calls calls :callbacks callbacks :returned_nil (if (null returned) t :json-false)
             :terminal terminal))))
  (delete-directory root t))
