;;; paired-sdk.el --- Independent real-runtime score evidence -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'subr-x)
(require 'jka-compr)
(setq load-suffixes (remove ".elc" load-suffixes))
(let ((elpa (getenv "TIEBREAKER_ELPA")))
  (dolist (directory (directory-files elpa t "^[^.].*"))
    (when (file-directory-p directory) (add-to-list 'load-path directory))))
;; Real gptel precedes the actual helper's optional fallbacks.
(require 'gptel)
(load-file "/work/test/ogent-test-helper.el")
;; The actual helper prepends current lisp: select the archived baseline AFTER it.
(when (getenv "TIEBREAKER_BASELINE")
  (add-to-list 'load-path "/work/agent_ergonomics_audit/audit/partial/baseline_pass_3/lisp")
  (add-to-list 'load-path "/work/agent_ergonomics_audit/audit/partial/baseline_pass_3/lisp/ui"))
(require 'ogent-models)
(require 'ogent-tools)
(require 'ogent-tool-execution)
(require 'ogent-ui-toolcalls)
(setq ogent-tool-registry (copy-tree ogent-tools-default-registry))
(defun tiebreaker-record (label thunk)
  (prin1
   (condition-case err
       (list :probe label :value (funcall thunk))
     (error (list :probe label :signal (car err) :message (error-message-string err)))))
  (terpri))
(defmacro tiebreaker-probe (label &rest body)
  `(tiebreaker-record ,label (lambda () ,@body)))
(tiebreaker-probe "runtime-source-identities"
  (list :emacs emacs-version :gptel (symbol-file 'gptel-make-tool)
        :helper (symbol-file 'ogent-test--provision-store-directory)
        :write (symbol-file 'ogent-tool--write-file)
        :edit (symbol-file 'ogent-tool--edit-file)
        :get (symbol-file 'ogent-tool-get)
        :wrapper (symbol-file 'ogent-tool-execution-wrapper)
        :ui (symbol-file 'ogent-ui--execute-tool)))
(tiebreaker-probe "actual-in-tool-discovery"
  (require 'ogent-agent)
  (let* ((json (ogent-agent-capabilities 'json))
         (data (json-parse-string json :object-type 'plist)))
    (list :contract_version (plist-get data :contract_version)
          :tools (mapcar (lambda (spec) (plist-get spec :name))
                         (append (plist-get data :tools) nil))
          :result_contract (plist-get data :result_contract)
          :guide (ogent-agent-guide))))
(let* ((root (ogent-test--provision-store-directory 'tools))
       (file (expand-file-name "score.txt" root))
       (ogent-tools-project-root root)
       (ogent-ledger-enabled nil))
  (tiebreaker-probe "raw-write-first-and-repeat"
    (let ((first (ogent-tool--write-file file "alpha\nbeta\n"))
          (second (ogent-tool--write-file file "alpha\nbeta\n")))
      (list :first first :second second :same-bytes (equal first second))))
  (tiebreaker-probe "raw-write-overwrites-without-approval"
    (let ((ogent-tool-require-approval t) (ogent-tool--denied-tools '(write-file)))
      (ogent-tool--write-file file "alpha beta")
      (with-temp-buffer (insert-file-contents file) (buffer-string))))
  (tiebreaker-probe "raw-write-invalid-path" (ogent-tool--write-file "" "x"))
  (tiebreaker-probe "raw-write-invalid-content" (ogent-tool--write-file file 3))
  (tiebreaker-probe "raw-edit-first" (ogent-tool--edit-file file "beta" "gamma"))
  (tiebreaker-probe "raw-edit-not-found" (ogent-tool--edit-file file "missing" "x"))
  (ogent-tool--write-file file "repeat repeat")
  (tiebreaker-probe "raw-edit-ambiguous" (ogent-tool--edit-file file "repeat" "x"))
  (tiebreaker-probe "raw-edit-ambiguity-preserved-content"
    (with-temp-buffer (insert-file-contents file) (buffer-string)))
  (tiebreaker-probe "raw-edit-invalid-boolean" (ogent-tool--edit-file file "repeat" "x" "yes"))
  (tiebreaker-probe "raw-edit-repeat-identical-initial-content"
    (let ((first (ogent-tool--edit-file file "repeat" "x" t)))
      (ogent-tool--write-file file "repeat repeat")
      (let ((second (ogent-tool--edit-file file "repeat" "x" t)))
        (list :first first :second second :same-bytes (equal first second)))))
  (tiebreaker-probe "raw-helper-method-aliases"
    (mapcar (lambda (name) (cons name (fboundp name)))
            '(ogent-tool--write-file ogent-tool--write_file ogent-tool--write
              ogent-tool--edit-file ogent-tool--edit_file ogent-tool--edit)))
  (tiebreaker-probe "registry-first-symbol-string-underscore-alias-typo"
    (let ((canonical (ogent-tool-get 'read-file)))
      (list :actual-object (gptel-tool-p canonical)
            :symbol-and-string-same (eq canonical (ogent-tool-get "read-file"))
            :underscore-same (eq canonical (ogent-tool-get "read_file"))
            :read-alias-same (eq canonical (ogent-tool-get "read"))
            :cat-alias-same (eq canonical (ogent-tool-get "cat"))
            :typo (ogent-tool-get "raed_file")
            :unknown (ogent-tool-get "no_such_tool"))))
  (tiebreaker-probe "sdk-docstrings"
    (mapcar (lambda (symbol) (cons symbol (documentation symbol)))
            '(ogent-tool--write-file ogent-tool--edit-file ogent-tool-get
              ogent-tool-execution-wrapper)))
  (ogent-tool--write-file file "alpha\nbeta\n")
  (tiebreaker-probe "raw-read-first-repeat-and-pagination"
    (let ((first (ogent-tool--read-file file 1 1))
          (second (ogent-tool--read-file file 1 1)))
      (list :first first :second second :same-bytes (equal first second))))
  (tiebreaker-probe "raw-read-invalid-offset" (ogent-tool--read-file file 0 2))
  (tiebreaker-probe "raw-read-method-aliases"
    (mapcar (lambda (name) (cons name (fboundp name)))
            '(ogent-tool--read-file ogent-tool--read_file ogent-tool--read)))
  (tiebreaker-probe "raw-glob-first-and-repeat"
    (let ((first (ogent-tool--glob "*.txt" root))
          (second (ogent-tool--glob "*.txt" root)))
      (list :first first :second second :same-bytes (equal first second))))
  (tiebreaker-probe "raw-glob-invalid-path" (ogent-tool--glob "*.txt" (concat root "/missing")))
  (tiebreaker-probe "raw-grep-first-and-repeat"
    (let ((first (ogent-tool--grep "alpha" file))
          (second (ogent-tool--grep "alpha" file)))
      (list :first first :second second :same-bytes (equal first second))))
  (tiebreaker-probe "raw-grep-invalid-regex" (ogent-tool--grep "[" file))
  (tiebreaker-probe "read-side-sdk-docstrings"
    (mapcar (lambda (symbol) (cons symbol (documentation symbol)))
            '(ogent-tool--read-file ogent-tool--glob ogent-tool--grep)))
  (when (memq 'format (help-function-arglist 'ogent-tool--read-file))
    (tiebreaker-probe "raw-read-json-repeat"
      (let ((first (ogent-tool--read-file file 1 1 'json))
            (second (ogent-tool--read-file file 1 1 'json)))
        (list :first first :second second :same-bytes (equal first second))))
    (tiebreaker-probe "raw-glob-json-repeat"
      (let ((first (ogent-tool--glob "*.txt" root 'json 0 1))
            (second (ogent-tool--glob "*.txt" root 'json 0 1)))
        (list :first first :second second :same-bytes (equal first second))))
    (tiebreaker-probe "raw-grep-json-repeat"
      (let ((first (ogent-tool--grep "alpha" file nil 0 'json 0 1))
            (second (ogent-tool--grep "alpha" file nil 0 'json 0 1)))
        (list :first first :second second :same-bytes (equal first second)))))
  (let* ((spec (ogent-tool-spec-get 'read-file))
         (has-json (memq 'result-format (help-function-arglist 'ogent-tool-execution-wrapper)))
         (wrapper (if has-json (ogent-tool-execution-wrapper spec 'json)
                    (ogent-tool-execution-wrapper spec))))
    (tiebreaker-probe "wrapper-first-and-repeat"
      (let ((first (funcall wrapper file 1 2))
            (second (funcall wrapper file 1 2)))
        (list :format (if has-json 'json 'text)
              :first first :second second :same-bytes (equal first second))))
    (tiebreaker-probe "wrapper-wrong-order" (funcall wrapper 1 file 2))
    (tiebreaker-probe "wrapper-missing-required" (funcall wrapper))
    (tiebreaker-probe "wrapper-excess" (funcall wrapper file 1 2 "extra" "extra"))
    (tiebreaker-probe "wrapper-no-method-alias"
      (list :arglist (help-function-arglist 'ogent-tool-execution-wrapper)
            :typo-method-exists (fboundp 'ogent-tool-execution-wraper)
            :alias-method-exists (fboundp 'ogent-tool-execution-wrap)))
    (tiebreaker-probe "wrapper-stale"
      (let ((ogent-tool-registry nil)) (funcall wrapper file))))
  (let* ((spec (ogent-tool-spec-get 'write-file))
         (has-json (memq 'result-format (help-function-arglist 'ogent-tool-execution-wrapper)))
         (wrapper (if has-json (ogent-tool-execution-wrapper spec 'json)
                    (ogent-tool-execution-wrapper spec)))
         (ogent-tool-require-approval t)
         (ogent-tool--denied-tools '(write-file)))
    (tiebreaker-probe "wrapper-actual-policy-denial"
      (list :result (funcall wrapper file "forbidden")
            :file-content (with-temp-buffer (insert-file-contents file) (buffer-string)))))
  (tiebreaker-probe "wrapper-edit-review-keeps-file"
    (let ((ogent-tool-require-approval nil)
          (spec (ogent-tool-spec-get 'write-file)))
      (with-temp-buffer
        (org-mode)
        (let ((result (funcall (ogent-tool-execution-wrapper spec) file "proposed")))
          (list :result result
                :file-content (with-temp-buffer (insert-file-contents file) (buffer-string))))))))
