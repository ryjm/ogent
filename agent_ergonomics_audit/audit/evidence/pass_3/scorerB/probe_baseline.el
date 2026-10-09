;;; probe_baseline.el --- Independent paired baseline -*- lexical-binding: t; -*-
(defconst scorerB-baseline-root "/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerB/baseline-source/")
(setq load-path (append (list (concat scorerB-baseline-root "lisp")
                             (concat scorerB-baseline-root "lisp/ui")) load-path))
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
    (princ (concat (json-serialize (list :probe id :invocation invocation :result result)
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
       (file (expand-file-name "example.txt" root)) (edit (expand-file-name "edit.txt" root))
       (write (expand-file-name "write.txt" root))
       (ogent-tools-project-root root) (ogent-tool-registry (copy-tree ogent-tools-default-registry))
       (ogent-tool-require-approval t) (ogent-tool--denied-tools '(bash write-file edit-file)))
  (with-temp-file file (insert "alpha needle\nbeta\ngamma needle\n"))
  (with-temp-file edit (insert "same same"))
  (with-temp-file write (insert "original"))
  (dolist (number '(1 2))
    (scorerB-emit (format "read-text-%d" number) "(ogent-tool--read-file file 1 2)"
                  (lambda () (ogent-tool--read-file file 1 2)))
    (scorerB-emit (format "glob-text-%d" number) "(ogent-tool--glob \"*.txt\" root)"
                  (lambda () (ogent-tool--glob "*.txt" root)))
    (scorerB-emit (format "grep-text-%d" number) "(ogent-tool--grep \"needle\" file nil 0)"
                  (lambda () (ogent-tool--grep "needle" file nil 0)))
    (scorerB-emit (format "bash-text-%d" number) "(ogent-tool--bash \"printf out; printf err >&2; exit 7\" root 2)"
                  (lambda () (ogent-tool--bash "printf out; printf err >&2; exit 7" root 2))))
  (scorerB-emit "read-invalid" "(ogent-tool--read-file file 0)" (lambda () (ogent-tool--read-file file 0)))
  (scorerB-emit "glob-invalid" "(ogent-tool--glob \"\" root)" (lambda () (ogent-tool--glob "" root)))
  (scorerB-emit "grep-invalid" "(ogent-tool--grep \"\" root)" (lambda () (ogent-tool--grep "" root)))
  (scorerB-emit "bash-invalid" "(ogent-tool--bash \"\" root)" (lambda () (ogent-tool--bash "" root)))
  (scorerB-emit "grep-async" "(ogent-tool--grep-async \"needle\" file nil 0 callback)"
                (lambda () (scorerB-await (lambda (callback) (ogent-tool--grep-async "needle" file nil 0 callback)))))
  (scorerB-emit "bash-async" "(ogent-tool--bash-async \"printf out; printf err >&2; exit 7\" root 2 callback)"
                (lambda () (scorerB-await (lambda (callback) (ogent-tool--bash-async "printf out; printf err >&2; exit 7" root 2 callback)))))
  (scorerB-emit "write-denied-wrapper" "(funcall (ogent-tool-execution-wrapper write-spec) write \"new\")"
                (lambda () (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get 'write-file)) write "new")))
  (scorerB-emit "write-raw" "(ogent-tool--write-file write \"new\") despite deny policy"
                (lambda () (list :response (ogent-tool--write-file write "new")
                                 :bytes (with-temp-buffer (insert-file-contents write) (buffer-string)))))
  (scorerB-emit "write-invalid" "(ogent-tool--write-file write 12)" (lambda () (ogent-tool--write-file write 12)))
  (dolist (number '(1 2))
    (scorerB-emit (format "write-repeat-%d" number) "(ogent-tool--write-file write \"new\")"
                  (lambda () (ogent-tool--write-file write "new"))))
  (scorerB-emit "edit-ambiguous" "(ogent-tool--edit-file edit \"same\" \"new\")"
                (lambda () (ogent-tool--edit-file edit "same" "new")))
  (scorerB-emit "edit-denied-wrapper" "(funcall (ogent-tool-execution-wrapper edit-spec) edit \"same\" \"new\" t)"
                (lambda () (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get 'edit-file)) edit "same" "new" t)))
  (dolist (number '(1 2))
    (with-temp-file edit (insert "same same"))
    (scorerB-emit (format "edit-raw-%d" number) "(ogent-tool--edit-file edit \"same\" \"new\" t) despite deny policy"
                  (lambda () (list :response (ogent-tool--edit-file edit "same" "new" t)
                                   :bytes (with-temp-buffer (insert-file-contents edit) (buffer-string))))))
  (dolist (name '(ogent-tool--read_file ogent-tool--edit-fiel ogent-tool--shell))
    (scorerB-emit (format "method-name-%s" name) (format "(funcall '%s ...)" name) (lambda () (funcall name))))
  (scorerB-emit "registry-spec-alias" "(ogent-tool-spec-get \"read_file\")"
                (lambda () (symbol-name (plist-get (ogent-tool-spec-get "read_file") :name))))
  (scorerB-emit "registry-spec-typo" "(ogent-tool-spec-get \"read-fiel\")" (lambda () (ogent-tool-spec-get "read-fiel")))
  (scorerB-emit "registry-enabled-invalid" "(let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))"
                (lambda () (let ((ogent-tools-enabled '(read-fiel))) (ogent-tools-enabled-list))))
  (scorerB-emit "wrapper-arity" "(funcall (ogent-tool-execution-wrapper read-spec) file 1 2 3)"
                (lambda () (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get 'read-file)) file 1 2 3)))
  (scorerB-emit "capabilities" "(ogent-agent-capabilities 'json)" (lambda () (ogent-agent-capabilities 'json)))
  (scorerB-emit "guide" "(ogent-agent-guide)" #'ogent-agent-guide)
  (scorerB-emit "doctor-run" "(ogent-doctor-run) default checks, no opt-in network" (lambda () (ogent-doctor-data (ogent-doctor-run))))
  (dolist (number '(1 2))
    (scorerB-emit (format "doctor-batch-%d" number) "(ogent-doctor-batch nil 'json), same protected environment"
                  (lambda () (let (status)
                               (let ((output (with-output-to-string (setq status (ogent-doctor-batch nil 'json)))))
                                 (list :return_code status :stdout output))))))
  (scorerB-emit "doctor-batch-invalid" "(ogent-doctor-batch nil 'jsno)" (lambda () (ogent-doctor-batch nil 'jsno)))
  (dolist (dir (directory-files "/tmp/ogent-fixdeps/30.2/elpa" t "\\`[^.]"))
    (when (file-directory-p dir) (add-to-list 'load-path dir)))
  (add-to-list 'load-path "/tmp/gptel-minimum")
  (load "/tmp/gptel-minimum/gptel.el" nil t)
  (require 'gptel-request)
  (setq ogent--tools-registered nil ogent--tool-specs-registered nil)
  (let ((tool (ogent-tool-get "read_file")))
    (scorerB-emit "actual-constructor" "(ogent-tool-get \"read_file\") with actual gptel constructor"
                  (lambda () (list :constructor_source (symbol-file 'gptel-make-tool)
                                   :name (gptel-tool-name tool)
                                   :same_cached_object (if (eq tool (ogent-tool-get 'read-file)) t :json-false)
                                   :result (funcall (gptel-tool-function tool) file 1 2)))))
  (dolist (number '(1 2))
    (scorerB-emit (format "enabled-tools-%d" number) "(ogent-tools-enabled-list) with actual gptel objects"
                  (lambda () (vconcat (mapcar #'gptel-tool-name (ogent-tools-enabled-list))))))
  (scorerB-emit "loaded-source" "symbol-file for every scored Lisp method"
                (lambda () (vconcat (mapcar (lambda (symbol) (list :method (symbol-name symbol) :file (symbol-file symbol)))
                                            '(ogent-tool--read-file ogent-tool--glob ogent-tool--grep ogent-tool--grep-async ogent-tool--bash
                                              ogent-tool--bash-async ogent-tool--write-file ogent-tool--edit-file ogent-tool-get
                                              ogent-tool-spec-get ogent-tools-enabled-list ogent-tool-execution-wrapper
                                              ogent-doctor-run ogent-doctor-batch)))))
  (delete-directory root t))
