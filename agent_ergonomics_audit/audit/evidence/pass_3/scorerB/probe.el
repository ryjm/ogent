;;; probe.el --- Independent scorer B runtime probes -*- lexical-binding: t; -*-
(require 'json)
(require 'ogent-tools)
(require 'ogent-agent)
(require 'ogent-ui-toolcalls)
(setq ogent-tools-show-progress nil)
(defun scorerB-emit (id invocation function)
  (let ((result (condition-case err
                    (list :status "returned" :value (funcall function))
                  (error (list :status "signalled" :condition (format "%s" (car err))
                               :message (error-message-string err))))))
    (princ (concat (json-serialize
                   (list :probe id :invocation invocation :result result)
                   :null-object :json-null :false-object :json-false) "\n"))))
(defun scorerB-await (function)
  (let ((count 0) events process)
    (setq process (funcall function (lambda (&rest event) (push event events) (cl-incf count))))
    (let ((deadline (+ (float-time) 4)))
      (while (and (processp process) (process-live-p process) (< (float-time) deadline))
        (accept-process-output process .02)))
    (accept-process-output nil .03)
    (list :returned_process (if (processp process) t :json-false)
          :callbacks count :events (format "%S" (nreverse events)))))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (file (expand-file-name "example.txt" root))
       (edit (expand-file-name "edit.txt" root))
       (write (expand-file-name "write.txt" root))
       (ogent-tools-project-root root)
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-tool-require-approval t)
       (ogent-tool--denied-tools '(bash write-file edit-file)))
  (with-temp-file file (insert "alpha needle\nbeta\ngamma needle\n"))
  (with-temp-file edit (insert "same same"))
  (with-temp-file write (insert "original"))
  (dolist (number '(1 2))
    (scorerB-emit (format "read-json-%d" number) "(ogent-tool--read-file file 1 2 'json)"
                  (lambda () (ogent-tool--read-file file 1 2 'json)))
    (scorerB-emit (format "glob-json-%d" number) "(ogent-tool--glob \"*.txt\" root 'json 0 2)"
                  (lambda () (ogent-tool--glob "*.txt" root 'json 0 2)))
    (scorerB-emit (format "grep-json-%d" number) "(ogent-tool--grep \"needle\" file nil 0 'json 0 1)"
                  (lambda () (ogent-tool--grep "needle" file nil 0 'json 0 1)))
    (scorerB-emit (format "bash-json-%d" number) "(ogent-tool--bash \"printf out; printf err >&2; exit 7\" root 2 'json)"
                  (lambda () (ogent-tool--bash "printf out; printf err >&2; exit 7" root 2 'json))))
  (scorerB-emit "read-text" "(ogent-tool--read-file file)" (lambda () (ogent-tool--read-file file)))
  (scorerB-emit "read-invalid" "(ogent-tool--read-file file 0)" (lambda () (ogent-tool--read-file file 0)))
  (scorerB-emit "glob-invalid" "(ogent-tool--glob \"\" root)" (lambda () (ogent-tool--glob "" root)))
  (scorerB-emit "grep-invalid" "(ogent-tool--grep \"\" root)" (lambda () (ogent-tool--grep "" root)))
  (scorerB-emit "grep-async" "(ogent-tool--grep-async \"needle\" file nil 0 callback)"
                (lambda () (scorerB-await (lambda (callback) (ogent-tool--grep-async "needle" file nil 0 callback)))))
  (scorerB-emit "bash-text" "(ogent-tool--bash \"printf out; printf err >&2; exit 7\" root 2)"
                (lambda () (ogent-tool--bash "printf out; printf err >&2; exit 7" root 2)))
  (scorerB-emit "bash-invalid" "(ogent-tool--bash \"\" root)" (lambda () (ogent-tool--bash "" root)))
  (scorerB-emit "bash-async" "(ogent-tool--bash-async \"printf out; printf err >&2; exit 7\" root 2 callback)"
                (lambda () (scorerB-await (lambda (callback) (ogent-tool--bash-async "printf out; printf err >&2; exit 7" root 2 callback)))))
  (scorerB-emit "write-denied-wrapper" "(funcall (ogent-tool-execution-wrapper write-spec 'json) write \"new\")"
                (lambda () (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get 'write-file) 'json) write "new")))
  (scorerB-emit "write-raw" "(ogent-tool--write-file write \"new\") despite deny policy"
                (lambda () (list :response (ogent-tool--write-file write "new")
                                 :bytes (with-temp-buffer (insert-file-contents write) (buffer-string)))))
  (scorerB-emit "write-invalid" "(ogent-tool--write-file write 12)" (lambda () (ogent-tool--write-file write 12)))
  (dolist (number '(1 2))
    (scorerB-emit (format "write-repeat-%d" number) "(ogent-tool--write-file write \"new\")"
                  (lambda () (ogent-tool--write-file write "new"))))
  (scorerB-emit "edit-ambiguous" "(ogent-tool--edit-file edit \"same\" \"new\")"
                (lambda () (ogent-tool--edit-file edit "same" "new")))
  (scorerB-emit "edit-denied-wrapper" "(funcall (ogent-tool-execution-wrapper edit-spec 'json) edit \"same\" \"new\" t)"
                (lambda () (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get 'edit-file) 'json) edit "same" "new" t)))
  (dolist (number '(1 2))
    (with-temp-file edit (insert "same same"))
    (scorerB-emit (format "edit-raw-%d" number) "(ogent-tool--edit-file edit \"same\" \"new\" t) despite deny policy"
                  (lambda () (list :response (ogent-tool--edit-file edit "same" "new" t)
                                   :bytes (with-temp-buffer (insert-file-contents edit) (buffer-string))))))
  (dolist (name '(ogent-tool--read_file ogent-tool--edit-fiel ogent-tool--shell ogent-agent-coll))
    (scorerB-emit (format "method-name-%s" name) (format "(funcall '%s ...)" name)
                  (lambda () (funcall name))))
  (scorerB-emit "registry-spec-alias" "(ogent-tool-spec-get \"read\")" (lambda () (symbol-name (plist-get (ogent-tool-spec-get "read") :name))))
  (scorerB-emit "registry-spec-typo" "(ogent-tool-spec-get \"read-fiel\")" (lambda () (ogent-tool-spec-get "read-fiel")))
  (scorerB-emit "registry-get-no-constructor" "(ogent-tool-get \"read_file\") without loaded gptel constructor" (lambda () (ogent-tool-get "read_file")))
  (scorerB-emit "registry-enabled-invalid" "(let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))"
                (lambda () (let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))))
  (scorerB-emit "registry-enabled-empty" "(let ((ogent-tools-enabled nil)) (ogent-tools-enabled-list))"
                (lambda () (let ((ogent-tools-enabled nil)) (ogent-tools-enabled-list))))
  (scorerB-emit "named-read" "(ogent-agent-call \"read\" '(:file_path file :limit 1))"
                (lambda () (ogent-agent-call "read" (list :file_path file :limit 1))))
  (dolist (number '(1 2))
    (scorerB-emit (format "named-json-%d" number) "(ogent-agent-call \"read\" ... 'json)"
                  (lambda () (ogent-agent-call "read" (list :file_path file :limit 1) 'json)))
    (scorerB-emit (format "next-json-%d" number) "(ogent-agent-next (ogent-agent-call \"read\" ... :limit 1) 'json)"
                  (lambda () (ogent-agent-next (ogent-agent-call "read" (list :file_path file :limit 1)) 'json)))
    (scorerB-emit (format "batch-json-%d" number) "(ogent-agent-batch [read glob] 'json)"
                  (lambda () (ogent-agent-batch
                              (list (list :tool "read" :args (list :file_path file :limit 1))
                                    (list :tool "glob" :args (list :pattern "*.txt" :path root :limit 1))) 'json))))
  (scorerB-emit "named-typo" "(ogent-agent-call \"raed\" '(:file_path file))"
                (lambda () (ogent-agent-call "raed" (list :file_path file))))
  (scorerB-emit "named-key-typo" "(ogent-agent-call \"read\" '(:file_pth file))"
                (lambda () (ogent-agent-call "read" (list :file_pth file))))
  (scorerB-emit "named-approval" "(ogent-agent-call \"shell\" '(:command \"printf out\"))"
                (lambda () (let ((ogent-tool--denied-tools nil)) (ogent-agent-call "shell" '(:command "printf out")))))
  (scorerB-emit "named-denied" "(ogent-agent-call \"shell\" '(:command \"printf out\"))"
                (lambda () (ogent-agent-call "shell" '(:command "printf out"))))
  (scorerB-emit "next" "(ogent-agent-next (ogent-agent-call \"read\" ... :limit 1))"
                (lambda () (ogent-agent-next (ogent-agent-call "read" (list :file_path file :limit 1)))))
  (scorerB-emit "next-changed" "(ogent-agent-next first-page) after source file changes"
                (lambda () (let ((first (ogent-agent-call "read" (list :file_path file :limit 1))))
                             (with-temp-file file (insert "changed\nbeta\ngamma\n"))
                             (ogent-agent-next first))))
  (scorerB-emit "next-safety-owner" "(ogent-agent-next hand-built shell continuation) with denied shell policy"
                (lambda () (ogent-agent-next
                            '(:contract_version "1" :tool "bash" :status "ok" :data (:snapshot "test")
                              :next [(:tool "bash" :snapshot "test" :args (:command "printf unsafe"))]))))
  (with-temp-file file (insert "alpha needle\nbeta\ngamma needle\n"))
  (scorerB-emit "batch" "(ogent-agent-batch [read glob grep])"
                (lambda () (ogent-agent-batch
                            (list (list :tool "read" :args (list :file_path file :limit 1))
                                  (list :tool "glob" :args (list :pattern "*.txt" :path root :limit 1))
                                  (list :tool "grep" :args (list :pattern "needle" :path file :limit 1))))))
  (scorerB-emit "batch-unsafe" "(ogent-agent-batch [read shell])"
                (lambda () (ogent-agent-batch
                            (list (list :tool "read" :args (list :file_path file))
                                  (list :tool "shell" :args '(:command "printf unsafe"))))))
  (scorerB-emit "named-async" "(ogent-agent-call-async \"shell\" ... callback 'json) with explicit existing allow rule"
                (lambda () (let ((ogent-tool--denied-tools nil) (ogent-tool-allow-list '("bash")))
                             (scorerB-await (lambda (callback)
                                              (ogent-agent-call-async "shell" '(:command "printf out; printf err >&2; exit 7") callback 'json))))))
  (scorerB-emit "named-async-denied" "(ogent-agent-call-async \"shell\" ... callback) with deny policy"
                (lambda () (scorerB-await (lambda (callback) (ogent-agent-call-async "shell" '(:command "printf out") callback)))))
  (dolist (number '(1 2))
    (scorerB-emit (format "describe-%d" number) "(ogent-agent-describe \"read\" 'json)" (lambda () (ogent-agent-describe "read" 'json)))
    (scorerB-emit (format "schema-%d" number) "(ogent-agent-schema 'json)" (lambda () (ogent-agent-schema 'json))))
  (scorerB-emit "describe-typo" "(ogent-agent-describe \"raed\")" (lambda () (ogent-agent-describe "raed")))
  (scorerB-emit "schema-invalid" "(ogent-agent-schema 'jsno)" (lambda () (ogent-agent-schema 'jsno)))
  (scorerB-emit "capabilities" "(ogent-agent-capabilities 'json)" (lambda () (ogent-agent-capabilities 'json)))
  (scorerB-emit "guide" "(ogent-agent-guide)" #'ogent-agent-guide)
  (scorerB-emit "doctor-run" "(ogent-doctor-run) default checks, no opt-in network" (lambda () (ogent-doctor-data (ogent-doctor-run))))
  (dolist (number '(1 2))
    (scorerB-emit (format "doctor-batch-%d" number) "(ogent-doctor-batch nil 'json), same protected environment"
                  (lambda () (let (status)
                               (let ((output (with-output-to-string (setq status (ogent-doctor-batch nil 'json)))))
                                 (list :return_code status :stdout output))))))
  (scorerB-emit "doctor-batch-invalid" "(ogent-doctor-batch nil 'jsno)" (lambda () (ogent-doctor-batch nil 'jsno)))
  (delete-directory root t))
