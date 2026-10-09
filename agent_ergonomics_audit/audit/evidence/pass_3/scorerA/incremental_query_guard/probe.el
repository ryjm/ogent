;;; probe.el --- Bounded structured search query validation -*- lexical-binding: t; -*-
;; Fresh query checks; earlier ff4 and b7 probes retain their original execution targets.
(require 'cl-lib)
(require 'jka-compr)
(setq load-suffixes (remove ".elc" load-suffixes))
(dolist (directory (directory-files (getenv "REFRESH_ELPA") t "^[^.].*"))
  (when (file-directory-p directory) (add-to-list 'load-path directory)))
(add-to-list 'load-path "/tmp/gptel-minimum")
(load-file "/tmp/gptel-minimum/gptel.el")
(require 'gptel-request)
(load-file "/work/test/ogent-test-helper.el")
(require 'ogent-agent)
(require 'ogent-tools)
(require 'ogent-tool-results)
(require 'ogent-tool-process)
(load-file "/work/lisp/ogent-tool-results.el")
(load-file "/work/lisp/ogent-tool-process.el")
(setq ogent-tools-show-progress nil)
(defun root-assert (condition description)
  (unless condition (error "Root validation failed: %s" description)))
(defun root-log-text (value)
  (cond ((stringp value) (if (multibyte-string-p value) value
                         (decode-coding-string value 'utf-8-unix)))
        ((consp value) (mapcar #'root-log-text value))
        ((vectorp value) (vconcat (mapcar #'root-log-text value)))
        (t value)))
(defun root-record (label invocation thunk)
  (let* ((value (funcall thunk))
         (encoded (json-serialize
                   (list :probe label :invocation invocation :passed t :value (root-log-text value))
                   :null-object :json-null :false-object :json-false))
         (coding-system-for-write 'utf-8-unix))
    (princ (if (multibyte-string-p encoded) encoded
             (decode-coding-string encoded 'utf-8-unix)))
    (terpri)))
(defun root-native (value)
  (if (stringp value)
      (json-parse-string value :object-type 'plist
                         :null-object :json-null :false-object :json-false)
    value))
(defun root-definitions (filename)
  (with-temp-buffer
    (insert-file-contents filename)
    (let (forms)
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (memq (car-safe form) '(defun cl-defun)) (push form forms))))
        (end-of-file nil))
      (nreverse forms))))
(root-record
 "runtime-source-identities" "explicit changed-module source load; protected helper and actual gptel"
 (lambda ()
   (let ((result (list :emacs emacs-version
                       :results (symbol-file 'ogent-tool-results-glob)
                       :process (symbol-file 'ogent-tool-process-grep-async)
                       :execution (symbol-file 'ogent-tool-execution-json)
                       :gptel (symbol-file 'gptel-make-tool))))
     (root-assert (equal (plist-get result :results) "/work/lisp/ogent-tool-results.el") "results source")
     (root-assert (equal (plist-get result :process) "/work/lisp/ogent-tool-process.el") "process source")
     (root-assert (equal (plist-get result :gptel) "/tmp/gptel-minimum/gptel-request.el") "real gptel source")
     result)))
(root-record
 "b7-to-current-definition-identities" "parse b7/current source signatures and executable bodies"
 (lambda ()
   (vconcat
    (cl-loop for module in '("ogent-agent" "ogent-tool-results" "ogent-tool-process"
                            "ogent-tool-execution" "ogent-tool-contract" "ogent-tools"
                            "ogent-models" "ogent-ledger" "ogent-doctor")
             append
             (let ((old (root-definitions
                         (format "/work/agent_ergonomics_audit/audit/evidence/pass_3/scorerA/incremental_query_guard/%s.b7b966c.source.txt" module)))
                   (new (root-definitions (format "/work/lisp/%s.el" module))))
               (mapcar
                (lambda (form)
                  (let* ((name (nth 1 form)) (current (cl-find name new :key #'cadr))
                         (old-body (nthcdr (if (stringp (nth 3 form)) 4 3) form))
                         (new-body (nthcdr (if (stringp (nth 3 current)) 4 3) current)))
                    (list :file (concat "lisp/" module ".el") :method (symbol-name name)
                          :signature_equal (if (equal (nth 2 form) (nth 2 current)) t :json-false)
                          :body_equal (if (and current (equal old-body new-body)) t :json-false)
                          :previous_body_sha256 (secure-hash 'sha256 (prin1-to-string old-body))
                          :current_body_sha256 (secure-hash 'sha256 (prin1-to-string new-body))))) old))))))

(defun query-call (args format async)
  (if (not async) (ogent-agent-call "search" args format)
    (let* ((count 0) result
          (returned (ogent-agent-call-async
                     "search" args
                     (lambda (value) (setq result value) (cl-incf count)) format))
          (deadline (+ (float-time) 5)))
      (while (and (= count 0) (< (float-time) deadline))
        (accept-process-output nil 0.05))
      (root-assert (= count 1) "async callback once")
      (root-assert (or (null returned) (processp returned)) "async return contract")
      (list :value result :callback_count count
            :returned_process (if (processp returned) t :json-false)))))
(defun query-value (args format async)
  (let ((call (query-call args format async)))
    (if async (plist-get call :value) call)))
(defun query-errors (variants path async)
  (vconcat
   (cl-loop for args in variants append
            (cl-loop for format in '(nil json) collect
                     (let* ((call (query-call (append args (list :path path :limit 1)) format async))
                            (value (if async (plist-get call :value) call))
                            (native (root-native value)))
                       (root-assert (and (equal (plist-get native :status) "error")
                                         (equal (plist-get (plist-get native :error) :code) "unsupported_output"))
                                    "raw query returns unsupported_output in both formats")
                       (when async
                         (root-assert (not (eq (plist-get call :returned_process) t)) "raw query fails before process spawn"))
                       (list :format (if format "json" "native")
                             :status (plist-get native :status)
                             :error_code (plist-get (plist-get native :error) :code)
                             :callback_count (if async (plist-get call :callback_count) :json-null)
                             :returned_process (if async (plist-get call :returned_process) :json-null)))))))
(defun query-success-page (args format async)
  (let* ((value (query-value args format async)) (native (root-native value))
         (next (plist-get native :next)) (entry (aref next 0))
         (next-args (plist-get entry :args)) result)
    (root-assert (equal (plist-get native :status) "ok") "valid Unicode query succeeds")
    (root-assert (= (length (plist-get (plist-get native :data) :matches)) 1) "first query page one match")
    (root-assert (and (= (length next) 1)
                      (equal (plist-get next-args :pattern) (plist-get args :pattern))
                      (equal (plist-get next-args :glob_filter) (plist-get args :glob_filter)))
                 "continuation retains actual Unicode query fields")
    (setq result (ogent-agent-next value format))
    (let ((continued (root-native result)))
      (root-assert (equal (plist-get continued :status) "ok") "Unicode continuation succeeds")
      (root-assert (= (length (plist-get (plist-get continued :data) :matches)) 1) "continuation one match")
      (list :format (if format "json" "native") :first_status (plist-get native :status)
            :continued_status (plist-get continued :status)
            :pattern (plist-get next-args :pattern) :glob_filter (plist-get next-args :glob_filter)))))
(let* ((parent (ogent-test--provision-store-directory 'tools))
       (raw (decode-coding-string (unibyte-string 255) 'utf-8-unix))
       (raw-unibyte (unibyte-string 255))
       (unicode-root (expand-file-name "café λ 😀" parent))
       (ogent-tools-project-root parent) (default-directory parent)
       (ogent-ledger-enabled nil)
       (ogent-tool-registry (copy-tree ogent-tools-default-registry)))
  (unwind-protect
      (progn
        (with-temp-file (expand-file-name "a.el" parent) (insert "needle\nneedle\n"))
        (make-directory unicode-root)
        (with-temp-file (expand-file-name "café λ 😀.el" unicode-root)
          (insert "needle λ 😀\nneedle λ 😀\n"))
        (root-record "raw-search-pattern-format-consistency"
                     "actual SDK native/JSON search raw unibyte and decoded raw-byte patterns"
                     (lambda () (query-errors (list (list :pattern raw) (list :pattern raw-unibyte)) parent nil)))
        (root-record "raw-matching-filter-cannot-enter-continuation"
                     "actual SDK native/JSON raw bracket filter matches a.el with two hits and limit 1"
                     (lambda () (query-errors (list (list :pattern "needle" :glob_filter (concat "[a" raw "]*.el"))
                                                    (list :pattern "needle" :glob_filter (concat "[a" raw-unibyte "]*.el"))) parent nil)))
        (root-record "raw-no-match-filter-refused-up-front"
                     "actual SDK native/JSON raw filters excluding all ordinary files"
                     (lambda () (query-errors (list (list :pattern "needle" :glob_filter (concat raw "*.absent"))
                                                    (list :pattern "needle" :glob_filter (concat raw-unibyte "*.absent"))) parent nil)))
        (root-record "raw-query-async-one-callback-no-process"
                     "actual named async SDK, both fields and byte representations, native/JSON"
                     (lambda () (query-errors (list (list :pattern raw) (list :pattern raw-unibyte)
                                                    (list :pattern "needle" :glob_filter (concat "[a" raw "]*.el"))
                                                    (list :pattern "needle" :glob_filter (concat "[a" raw-unibyte "]*.el"))) parent t)))
        (root-record "unicode-query-continuation-sync"
                     "actual native/JSON SDK Unicode search pattern and filter, first and continuation pages"
                     (lambda () (vconcat (mapcar (lambda (format)
                                                  (query-success-page (list :pattern "needle λ 😀" :glob_filter "*λ 😀.el"
                                                                            :path unicode-root :limit 1) format nil)) '(nil json)))))
        (root-record "unicode-query-async-and-continuation"
                     "actual native/JSON async SDK Unicode query, one callback, then ogent-agent-next"
                     (lambda () (vconcat (mapcar (lambda (format)
                                                  (query-success-page (list :pattern "needle λ 😀" :glob_filter "*λ 😀.el"
                                                                            :path unicode-root :limit 1) format t)) '(nil json)))))
        (root-record "nil-filter-positive-control"
                     "native/JSON search explicit nil optional filter remains valid"
                     (lambda () (vconcat (mapcar (lambda (format)
                                                  (let* ((value (ogent-agent-call "search" (list :pattern "needle" :path parent :glob_filter nil :limit 1) format))
                                                         (native (root-native value)))
                                                    (root-assert (equal (plist-get native :status) "ok") "nil filter accepted")
                                                    (list :format (if format "json" "native") :status (plist-get native :status)))) '(nil json)))))
        (root-record "query-type-errors-remain-invalid-arguments"
                     "native/JSON SDK nonstring query fields retain argument-error classification"
                     (lambda ()
                       (vconcat (cl-loop for args in (list (list :pattern 42) (list :pattern "needle" :glob_filter 42)) append
                                         (cl-loop for format in '(nil json) collect
                                                  (let ((native (root-native (ogent-agent-call "search" (append args (list :path parent)) format))))
                                                    (root-assert (and (equal (plist-get native :status) "error")
                                                                      (equal (plist-get (plist-get native :error) :code) "invalid_arguments"))
                                                                 "nonstring query type validation preserved")
                                                    (list :format (if format "json" "native") :status (plist-get native :status)
                                                          :error_code (plist-get (plist-get native :error) :code)))))))))
    (delete-directory parent t)))
