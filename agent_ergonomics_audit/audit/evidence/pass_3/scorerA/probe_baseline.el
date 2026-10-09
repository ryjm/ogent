;;; probe_baseline.el --- Paired baseline observation -*- lexical-binding: t; -*-
;; The protected helper prepends current lisp paths.  Select exact archived
;; git-show sources AFTER that helper has established its store guards.
(setq load-path
      (append '("/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerA/baseline_sources/lisp"
                "/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerA/baseline_sources/lisp/ui")
              (cl-remove-if (lambda (path) (member path '("/work/lisp" "/work/lisp/ui"))) load-path)))
(load "/tmp/ogent-fixdeps/30.2/elpa/gptel-20261007.432/gptel-request.el" nil nil t)
(require 'ogent-agent)
(require 'ogent-tools)
(require 'ogent-ui-toolcalls)
(unless (string-match-p "/baseline_sources/lisp/ogent-tools\\.el$"
                        (symbol-file 'ogent-tool--read-file 'defun))
  (error "Baseline probe loaded the wrong source: %s" (symbol-file 'ogent-tool--read-file 'defun)))
(message "scorerA baseline source verified: %s" (symbol-file 'ogent-tool--read-file 'defun))
(setq ogent-tools-show-progress nil)
(defun scorerA-baseline-record (probe invocation thunk)
  (let ((record
         (condition-case err
             (let* ((value (funcall thunk)) (print-length nil) (print-level nil))
               (list :probe probe :invocation invocation :outcome "returned" :result (if (stringp value) value (prin1-to-string value))))
           (error (list :probe probe :invocation invocation :outcome "condition" :condition (symbol-name (car err)) :message (error-message-string err))))))
    (princ (json-serialize record)) (princ "\n")))
(defun scorerA-baseline-wait (process done)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall done)) (< (float-time) deadline)) (accept-process-output nil .02))
    (when (and process (process-live-p process)) (delete-process process))))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (file (expand-file-name "data.txt" root)) (ogent-tools-project-root root) (default-directory root)
       (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent--tools-registered nil) (ogent--tool-specs-registered nil)
       (ogent-tool-require-approval t) (ogent-tool-allow-list nil) (ogent-tool--denied-tools nil))
  (with-temp-file file (insert "alpha needle\nbeta needle\ngamma\n"))
  (dotimes (i 2)
    (scorerA-baseline-record (format "read-text-%d" i) "(ogent-tool--read-file FILE 1 2)" (lambda () (ogent-tool--read-file file 1 2)))
    (scorerA-baseline-record (format "glob-text-%d" i) "(ogent-tool--glob \"*.txt\" ROOT)" (lambda () (ogent-tool--glob "*.txt" root)))
    (scorerA-baseline-record (format "grep-text-%d" i) "(ogent-tool--grep \"needle\" FILE)" (lambda () (ogent-tool--grep "needle" file)))
    (scorerA-baseline-record (format "bash-text-%d" i) "(ogent-tool--bash \"printf out; printf err >&2; exit 7\" ROOT 2)"
                             (lambda () (ogent-tool--bash "printf out; printf err >&2; exit 7" root 2)))
    (scorerA-baseline-record (format "get-wire-%d" i) "(gptel-tool-name (ogent-tool-get \"read_file\"))" (lambda () (gptel-tool-name (ogent-tool-get "read_file"))))
    (scorerA-baseline-record (format "spec-wire-%d" i) "(ogent-tool-spec-get \"read_file\")" (lambda () (ogent-tool-spec-get "read_file")))
    (scorerA-baseline-record (format "enabled-%d" i) "(mapcar #'gptel-tool-name (ogent-tools-enabled-list))" (lambda () (mapcar #'gptel-tool-name (ogent-tools-enabled-list)))))
  (scorerA-baseline-record "read-invalid" "(ogent-tool--read-file FILE 0)" (lambda () (ogent-tool--read-file file 0)))
  (scorerA-baseline-record "glob-invalid" "(ogent-tool--glob \"\" ROOT)" (lambda () (ogent-tool--glob "" root)))
  (scorerA-baseline-record "grep-invalid" "(ogent-tool--grep \"[\" FILE)" (lambda () (ogent-tool--grep "[" file)))
  (scorerA-baseline-record "bash-invalid" "(ogent-tool--bash \"pwd\" ROOT 0)" (lambda () (ogent-tool--bash "pwd" root 0)))
  (scorerA-baseline-record "write-invalid" "(ogent-tool--write-file FILE 42)" (lambda () (ogent-tool--write-file file 42)))
  (scorerA-baseline-record "edit-ambiguous" "(ogent-tool--edit-file FILE \"needle\" \"new\")" (lambda () (ogent-tool--edit-file file "needle" "new")))
  (scorerA-baseline-record "read-json-unavailable" "(ogent-tool--read-file FILE 1 2 'json)" (lambda () (ogent-tool--read-file file 1 2 'json)))
  (scorerA-baseline-record "grep-async" "(ogent-tool--grep-async \"needle\" FILE nil 0 CALLBACK)"
                           (lambda () (let (events done)
                                        (scorerA-baseline-wait (ogent-tool--grep-async "needle" file nil 0
                                                               (lambda (type data) (push (list type data) events) (when (memq type '(done error)) (setq done t))))
                                                              (lambda () done)) (nreverse events))))
  (scorerA-baseline-record "bash-async" "(ogent-tool--bash-async \"printf out; printf err >&2; exit 7\" ROOT 2 CALLBACK)"
                           (lambda () (let (events done)
                                        (scorerA-baseline-wait (ogent-tool--bash-async "printf out; printf err >&2; exit 7" root 2
                                                               (lambda (type data) (push (list type data) events) (when (memq type '(done error)) (setq done t))))
                                                              (lambda () done)) (nreverse events))))
  (scorerA-baseline-record "get-cat-unavailable" "(ogent-tool-get \"cat\")" (lambda () (ogent-tool-get "cat")))
  (scorerA-baseline-record "spec-cat-unavailable" "(ogent-tool-spec-get \"cat\")" (lambda () (ogent-tool-spec-get "cat")))
  (scorerA-baseline-record "get-typo" "(ogent-tool-get \"read-fiel\")" (lambda () (ogent-tool-get "read-fiel")))
  (scorerA-baseline-record "spec-typo" "(ogent-tool-spec-get \"read-fiel\")" (lambda () (ogent-tool-spec-get "read-fiel")))
  (scorerA-baseline-record "enabled-typo" "(let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))"
                           (lambda () (let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))))
  (let ((ogent-tool--denied-tools '("write_file")))
    (scorerA-baseline-record "wrapper-denied" "(funcall (ogent-tool-execution-wrapper WRITE-SPEC) FILE \"new\")"
                             (lambda () (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get "write_file")) file "new")))
    (scorerA-baseline-record "write-raw-denied-policy" "(ogent-tool--write-file FILE \"raw\") under denied policy" (lambda () (ogent-tool--write-file file "raw"))))
  (scorerA-baseline-record "edit-raw" "(ogent-tool--edit-file FILE \"raw\" \"edited\")" (lambda () (ogent-tool--edit-file file "raw" "edited")))
  (dolist (method '(ogent-tool--read_file ogent-tool--read-fiel ogent-tool--edit_file ogent-tool--edit-fiel ogent-tool--shell))
    (scorerA-baseline-record (symbol-name method) (format "(funcall '%s)" method) (lambda () (funcall method))))
  (scorerA-baseline-record "doctor-run" "(ogent-doctor-run) status/remediation summary"
                           (lambda () (mapcar (lambda (check) (list :id (plist-get check :id) :status (plist-get check :status) :remediation (plist-get check :remediation))) (ogent-doctor-run))))
  (scorerA-baseline-record "doctor-batch-invalid" "(ogent-doctor-batch nil 'jsno)" (lambda () (ogent-doctor-batch nil 'jsno)))
  (dotimes (i 2)
    (scorerA-baseline-record (format "doctor-json-%d" i) "(with-output-to-string (ogent-doctor-batch nil 'json))"
                             (lambda () (with-output-to-string (ogent-doctor-batch nil 'json)))))
  (scorerA-baseline-record "capabilities" "(ogent-agent-capabilities 'json)" (lambda () (ogent-agent-capabilities 'json))))
