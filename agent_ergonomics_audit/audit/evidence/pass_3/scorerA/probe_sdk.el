;;; probe_sdk.el --- Independent scorer A probes -*- lexical-binding: t; -*-
(require 'ogent-agent)
(require 'ogent-tools)
(unless (equal (symbol-file 'ogent-tool--read-file 'defun) "/work/lisp/ogent-tools.el")
  (error "Current probe loaded unexpected source: %s" (symbol-file 'ogent-tool--read-file 'defun)))
(message "scorerA current source verified: %s" (symbol-file 'ogent-tool--read-file 'defun))
(require 'ogent-ui-toolcalls)
(setq ogent-tools-show-progress nil)
(defun scorerA-record (probe invocation thunk)
  (let ((record
         (condition-case err
             (let* ((value (funcall thunk))
                    (print-length nil) (print-level nil))
               (list :probe probe :invocation invocation :outcome "returned"
                     :result (if (stringp value) value (prin1-to-string value))))
           (error (list :probe probe :invocation invocation :outcome "condition"
                        :condition (symbol-name (car err)) :message (error-message-string err))))))
    (princ (json-serialize record)) (princ "\n")))
(defun scorerA-wait (process done)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall done)) (< (float-time) deadline))
      (accept-process-output nil .02))
    (when (and process (process-live-p process)) (delete-process process))))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (file (expand-file-name "data.txt" root))
       (ogent-tools-project-root root)
       (default-directory root)
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-tool-allow-list nil)
       (ogent-tool--denied-tools nil)
       (ogent-tool-require-approval t))
  (with-temp-file file (insert "alpha needle\nbeta needle\ngamma\n"))
  (dolist (index '(1 2))
    (scorerA-record (format "read-text-%d" index) "(ogent-tool--read-file FILE 1 2)"
                   (lambda () (ogent-tool--read-file file 1 2)))
    (scorerA-record (format "read-json-%d" index) "(ogent-tool--read-file FILE 1 2 'json)"
                   (lambda () (ogent-tool--read-file file 1 2 'json)))
    (scorerA-record (format "glob-json-%d" index) "(ogent-tool--glob \"*.txt\" ROOT 'json)"
                   (lambda () (ogent-tool--glob "*.txt" root 'json)))
    (scorerA-record (format "grep-json-%d" index) "(ogent-tool--grep \"needle\" ROOT nil 0 'json)"
                   (lambda () (ogent-tool--grep "needle" root nil 0 'json)))
    (scorerA-record (format "bash-json-%d" index) "(ogent-tool--bash \"printf out; printf err >&2; exit 7\" ROOT 2 'json)"
                   (lambda () (ogent-tool--bash "printf out; printf err >&2; exit 7" root 2 'json)))
    (scorerA-record (format "call-json-%d" index) "(ogent-agent-call \"read_file\" '(:file_path FILE :limit 1) 'json)"
                   (lambda () (ogent-agent-call "read_file" (list :file_path file :limit 1) 'json)))
    (scorerA-record (format "describe-json-%d" index) "(ogent-agent-describe \"read\" 'json)"
                   (lambda () (ogent-agent-describe "read" 'json)))
    (scorerA-record (format "schema-json-%d" index) "(ogent-agent-schema 'json)" (lambda () (ogent-agent-schema 'json)))
    (scorerA-record (format "capabilities-json-%d" index) "(ogent-agent-capabilities 'json)" (lambda () (ogent-agent-capabilities 'json)))
    (scorerA-record (format "batch-json-%d" index) "(ogent-agent-batch [FILES SEARCH READ] 'json)"
                   (lambda () (ogent-agent-batch
                               (vector (list :tool "files" :args (list :pattern "*.txt" :path root))
                                       (list :tool "search" :args (list :pattern "needle" :path root))
                                       (list :tool "read" :args (list :file_path file))) 'json))))
  (scorerA-record "read-invalid" "(ogent-tool--read-file FILE 0)" (lambda () (ogent-tool--read-file file 0)))
  (scorerA-record "glob-invalid" "(ogent-tool--glob \"\" ROOT)" (lambda () (ogent-tool--glob "" root)))
  (scorerA-record "grep-text" "(ogent-tool--grep \"needle\" FILE)" (lambda () (ogent-tool--grep "needle" file)))
  (scorerA-record "grep-invalid" "(ogent-tool--grep \"[\" FILE)" (lambda () (ogent-tool--grep "[" file)))
  (scorerA-record "bash-invalid" "(ogent-tool--bash \"pwd\" ROOT 0)" (lambda () (ogent-tool--bash "pwd" root 0)))
  (scorerA-record "write-invalid" "(ogent-tool--write-file FILE 42)" (lambda () (ogent-tool--write-file file 42)))
  (scorerA-record "edit-ambiguous" "(ogent-tool--edit-file FILE \"needle\" \"new\")" (lambda () (ogent-tool--edit-file file "needle" "new")))
  (scorerA-record "grep-async" "(ogent-tool--grep-async \"needle\" FILE nil 0 CALLBACK)"
                 (lambda () (let (events done)
                              (scorerA-wait (ogent-tool--grep-async "needle" file nil 0
                                             (lambda (type data) (push (list type data) events)
                                               (when (memq type '(done error)) (setq done t))))
                                            (lambda () done)) (nreverse events))))
  (scorerA-record "bash-async" "(ogent-tool--bash-async \"printf out; printf err >&2; exit 7\" ROOT 2 CALLBACK)"
                 (lambda () (let (events done)
                              (scorerA-wait (ogent-tool--bash-async "printf out; printf err >&2; exit 7" root 2
                                             (lambda (type data) (push (list type data) events)
                                               (when (memq type '(done error)) (setq done t))))
                                            (lambda () done)) (nreverse events))))
  (scorerA-record "bash-async-invalid" "(ogent-tool--bash-async \"pwd\" ROOT 0 CALLBACK)"
                 (lambda () (let (events) (ogent-tool--bash-async "pwd" root 0 (lambda (type data) (push (list type data) events))) events)))
  (scorerA-record "tool-get-alias" "(ogent-tool-get \"cat\") returns a registered object" (lambda () (and (ogent-tool-get "cat") t)))
  (scorerA-record "tool-get-typo" "(ogent-tool-get \"read-fiel\")" (lambda () (ogent-tool-get "read-fiel")))
  (scorerA-record "spec-get-alias" "(ogent-tool-spec-get \"cat\")" (lambda () (ogent-tool-spec-get "cat")))
  (scorerA-record "spec-get-typo" "(ogent-tool-spec-get \"read-fiel\")" (lambda () (ogent-tool-spec-get "read-fiel")))
  (scorerA-record "enabled" "(ogent-tools-enabled-list) tool names"
                 (lambda () (mapcar (lambda (tool) (gptel-tool-name tool)) (ogent-tools-enabled-list))))
  (scorerA-record "enabled-typo" "(let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))"
                 (lambda () (let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))))
  (scorerA-record "call-typo" "(ogent-agent-call \"read-fiel\" nil 'json)"
                 (lambda () (ogent-agent-call "read-fiel" nil 'json)))
  (scorerA-record "call-arg-typo" "(ogent-agent-call \"read\" '(:file_pat FILE) 'json)"
                 (lambda () (ogent-agent-call "read" (list :file_pat file) 'json)))
  (scorerA-record "describe-typo" "(ogent-agent-describe \"read-fiel\" 'json)" (lambda () (ogent-agent-describe "read-fiel" 'json)))
  (scorerA-record "schema-invalid" "(ogent-agent-schema 'yaml)" (lambda () (ogent-agent-schema 'yaml)))
  (let ((first (ogent-agent-call "read" (list :file_path file :limit 1))))
    (scorerA-record "next-json" "(ogent-agent-next FIRST 'json)" (lambda () (ogent-agent-next first 'json)))
    (scorerA-record "next-repeat-json" "(ogent-agent-next FIRST 'json)" (lambda () (ogent-agent-next first 'json)))
    (with-temp-file file (insert "changed\nbeta needle\ngamma\n"))
    (scorerA-record "next-changed" "(ogent-agent-next FIRST 'json)" (lambda () (ogent-agent-next first 'json))))
  (scorerA-record "next-invalid" "(ogent-agent-next nil)" (lambda () (ogent-agent-next nil)))
  (scorerA-record "batch-unsafe" "(ogent-agent-batch [SHELL] 'json)"
                 (lambda () (ogent-agent-batch '[(:tool "shell" :args (:command "pwd"))] 'json)))
  (let ((ogent-tool--denied-tools '("write_file")))
    (scorerA-record "wrapper-denied" "(funcall (ogent-tool-execution-wrapper WRITE-SPEC 'json) FILE \"new\")"
                   (lambda () (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get "write_file") 'json) file "new")))
    (scorerA-record "write-raw-denied-policy" "(ogent-tool--write-file FILE \"raw\") under denied write policy"
                   (lambda () (ogent-tool--write-file file "raw"))))
  (scorerA-record "edit-raw" "(ogent-tool--edit-file FILE \"raw\" \"edited\")" (lambda () (ogent-tool--edit-file file "raw" "edited")))
  (scorerA-record "call-shell-required" "(ogent-agent-call \"shell\" '(:command \"pwd\") 'json)"
                 (lambda () (ogent-agent-call "shell" '(:command "pwd") 'json)))
  (scorerA-record "call-async" "(ogent-agent-call-async \"shell\" ARGS CALLBACK 'json) with explicit bash allow rule"
                 (lambda () (let ((ogent-tool-allow-list '("bash")) (count 0) result)
                              (scorerA-wait (ogent-agent-call-async "shell" (list :command "printf out; printf err >&2; exit 7" :working_directory root)
                                             (lambda (value) (setq result value) (cl-incf count)) 'json)
                                            (lambda () (> count 0)))
                              (list :callback_count count :result result))))
  (scorerA-record "call-async-denied" "(ogent-agent-call-async \"shell\" ARGS CALLBACK 'json) under denied bash policy"
                 (lambda () (let ((ogent-tool--denied-tools '("bash")) (count 0) result)
                              (ogent-agent-call-async "shell" '(:command "pwd") (lambda (value) (setq result value) (cl-incf count)) 'json)
                              (list :callback_count count :result result))))
  (scorerA-record "call-async-invalid-callback" "(ogent-agent-call-async \"read\" nil nil)"
                 (lambda () (ogent-agent-call-async "read" nil nil)))
  (dolist (method '(ogent-tool--read_file ogent-tool--read-fiel ogent-tool--edit_file ogent-tool--edit-fiel ogent-tool--shell ogent-agent-calll))
    (scorerA-record (symbol-name method) (format "(funcall '%s)" method) (lambda () (funcall method))))
  (scorerA-record "doctor-run" "(ogent-doctor-run) status/remediation summary"
                 (lambda () (mapcar (lambda (check) (list :id (plist-get check :id) :status (plist-get check :status)
                                                        :remediation (plist-get check :remediation))) (ogent-doctor-run))))
  (scorerA-record "doctor-batch-invalid" "(ogent-doctor-batch nil 'jsno)" (lambda () (ogent-doctor-batch nil 'jsno)))
  (dotimes (index 2)
    (scorerA-record (format "doctor-json-%d" (1+ index)) "(with-output-to-string (ogent-doctor-batch nil 'json))"
                   (lambda () (with-output-to-string (ogent-doctor-batch nil 'json))))))
