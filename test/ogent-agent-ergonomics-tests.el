;;; ogent-agent-ergonomics-tests.el --- Agent interface regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Pin observable search, edit, argument, and automation contracts.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-tools)
(require 'ogent-models)
(require 'ogent-doctor)
(require 'ogent-ui-toolcalls)
(require 'ogent-tool-execution)
(require 'ogent-mcp)
(require 'ogent-agent nil t)

(defun ogent-agent-ergonomics-tests--file (root name content)
  "Create NAME with CONTENT under fixture ROOT and return its path."
  (let ((file (expand-file-name name root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert content))
    file))

(ert-deftest ogent-agent-ergonomics-grep-errors-invalid-regex ()
  "An invalid regex signals failure rather than returning match prose."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "data.txt" "needle\n"))
         (ogent-tools-show-progress nil)
         (err (should-error (ogent-tool--grep "[" file) :type 'user-error)))
    (should (string-match-p "grep failed" (error-message-string err)))
    (should (string-match-p "pattern" (error-message-string err)))
    (should-not (string-match-p "Process ogent-grep" (error-message-string err)))))

(ert-deftest ogent-agent-ergonomics-grep-errors-no-match-is-success ()
  "A valid empty search returns a stable no-match result."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "data.txt" "needle\n"))
         (ogent-tools-show-progress nil))
    (should (equal (ogent-tool--grep "absent" file) "No matches found"))))

(ert-deftest ogent-agent-ergonomics-grep-arguments-leading-dash ()
  "A pattern beginning with a dash is data, not a search option."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file
                root "data.txt" "ordinary needle\n-needle\n"))
         (ogent-tools-show-progress nil)
         (result (ogent-tool--grep "-needle" file)))
    (should (string-match-p "2:-needle" result))
    (should-not (string-match-p "ordinary needle" result))))

(ert-deftest ogent-agent-ergonomics-grep-arguments-quoted-filter ()
  "Quotes and shell syntax in a glob filter remain literal data."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (marker (expand-file-name "injection-marker" root))
         (ogent-tools-show-progress nil))
    (ogent-agent-ergonomics-tests--file root "data.el" "needle\n")
    (ogent-tool--grep "needle" root
                      "*.el'; printf injected > injection-marker; #")
    (should-not (file-exists-p marker))))

(ert-deftest ogent-agent-ergonomics-glob-recursive-and-stable ()
  "Recursive glob includes zero and multiple directory depths with stable ties."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (files (list
                 (ogent-agent-ergonomics-tests--file root "root.el" "")
                 (ogent-agent-ergonomics-tests--file root "one/near.el" "")
                 (ogent-agent-ergonomics-tests--file root "one/two/deep.el" ""))))
    (ogent-agent-ergonomics-tests--file root "one/two/other.txt" "")
    (dolist (file files) (set-file-times file (encode-time 0 0 0 1 1 2020)))
    (should (equal (split-string (ogent-tool--glob "**/*.el" root) "\n" t)
                   (sort files #'string<)))))

(ert-deftest ogent-agent-ergonomics-glob-recursive-invalid-root ()
  "An invalid glob root gives a corrective path hint."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (err (should-error
               (ogent-tool--glob "**/*.el" (expand-file-name "missing" root))
               :type 'user-error)))
    (should (string-match-p "path" (error-message-string err)))))

(ert-deftest ogent-agent-ergonomics-read-pagination-next-offset ()
  "Read pages name the next offset and omit a phantom trailing line."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "data.txt" "a\nb\nc\nd\n"))
         (first (ogent-tool--read-file file 1 2))
         (last (ogent-tool--read-file file 3 2)))
    (should (string-match-p "offset=3" first))
    (should-not (string-match-p "More lines" last))
    (should-not (string-match-p "5\\t" (ogent-tool--read-file file)))))

(ert-deftest ogent-agent-ergonomics-read-pagination-invalid-bounds ()
  "Invalid read bounds fail with precise correction hints."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "data.txt" "a\n")))
    (dolist (bounds '((0 2) (1 0) ("2" 1) (1 -1)))
      (let ((err (should-error (apply #'ogent-tool--read-file file bounds)
                               :type 'user-error)))
        (should (string-match-p "use" (error-message-string err)))))))

(ert-deftest ogent-agent-ergonomics-edit-contract-ambiguous-before-write ()
  "Ambiguous matches are refused before the file changes, including JSON false."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "data.txt" "same same")))
    (dolist (flag '(nil :json-false :false))
      (let ((err (should-error (ogent-tool--edit-file file "same" "new" flag)
                               :type 'user-error)))
        (should (string-match-p "replace_all true" (error-message-string err)))
        (should (equal (with-temp-buffer
                         (insert-file-contents file) (buffer-string))
                       "same same"))))
    (ogent-tool--edit-file file "same" "new" t)
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "new new"))))

(ert-deftest ogent-agent-ergonomics-edit-contract-empty-and-review ()
  "Empty matches fail promptly and inline review obeys the same uniqueness rule."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "data.txt" "same same")))
    (should-error (ogent-tool--edit-file file "" "new" t) :type 'user-error)
    (with-temp-buffer
      (insert "same same")
      (should-error
       (ogent-ui--tool-edits-for-inline-diff
        "edit-file" (list :file_path file :old_string "same" :new_string "new"
                          :replace_all :json-false) (current-buffer))
       :type 'user-error))))

(ert-deftest ogent-agent-ergonomics-argument-contract-write-before-validation ()
  "Invalid content cannot overwrite files or create parent directories."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "data.txt" "original"))
         (missing (expand-file-name "missing/data.txt" root)))
    (should-error (ogent-tool--write-file file 42) :type 'user-error)
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                   "original"))
    (should-error (ogent-tool--write-file missing 42) :type 'user-error)
    (should-not (file-exists-p (file-name-directory missing)))))

(ert-deftest ogent-agent-ergonomics-argument-contract-wrapper-arity ()
  "Excess positional values are rejected before approval or execution."
  (let* ((spec '(:name contract-fixture :function ignore
                       :args ((:name "value" :type "string"))))
         (ogent-tool-registry (list spec))
         (wrapper (ogent-tool-execution-wrapper spec))
         approval-called)
    (cl-letf (((symbol-function 'ogent-tool-approval-check)
               (lambda (&rest _) (setq approval-called t) 'approved)))
      (should (string-match-p "accepts 1" (funcall wrapper "first" "excess")))
      (should-not approval-called))))

(ert-deftest ogent-agent-ergonomics-argument-contract-values-and-hints ()
  "Validation preserves false, zero and nested objects, and teaches typo repair."
  (let* ((nested (make-hash-table :test #'equal))
         (spec '(:name contract-fixture
                       :args ((:name "file_path" :type "string")
                              (:name "flag" :type "boolean" :optional t)
                              (:name "count" :type "integer" :optional t)
                              (:name "data" :type "object" :optional t))))
         (values (ogent-ui--extract-tool-args
                  spec (list :file-path "data.txt" :flag :json-false
                             :count 0 :data nested))))
    (should (equal (seq-take values 3) '("data.txt" nil 0)))
    (should (eq (nth 3 values) nested))
    (let ((err (should-error (ogent-ui--extract-tool-args
                              spec '(:file_pth "data.txt")) :type 'user-error)))
      (should (string-match-p "did you mean file_path" (error-message-string err))))))

(ert-deftest ogent-agent-ergonomics-argument-contract-async-failure-once ()
  "An invalid async argument produces one result without starting the tool."
  (let* ((called nil)
         (spec (list :name 'contract-fixture :async t
                     :function (lambda (&rest _) (setq called t))
                     :args '((:name "count" :type "integer"))))
         (ogent-tool-registry (list spec))
         results)
    (funcall (ogent-tool-execution-wrapper spec)
             (lambda (result) (push result results)) "wrong")
    (should-not called)
    (should (= (length results) 1))
    (should (string-match-p "count requires integer" (car results)))))

(ert-deftest ogent-agent-ergonomics-tool-names-exact-and-wire-alias ()
  "Lookup accepts strings and wire aliases while preserving exact custom names."
  (let* ((read '(:name read-file :function ignore :args nil))
         (wire '(:name custom_name :function ignore :args nil))
         (other '(:name custom-name :function ignore :args nil))
         (ogent-tool-registry (list read wire other)))
    (should (eq (ogent-tool-spec-get "read_file") read))
    (should (eq (ogent-tool-spec-get 'read_file) read))
    (should (eq (ogent-tool-spec-get "custom_name") wire))
    (should (eq (ogent-tool-spec-get "custom-name") other))
    (should (equal (ogent-tool--name-string "read_file") "read-file"))))

(ert-deftest ogent-agent-ergonomics-tool-names-typo-refuses-with-hint ()
  "Unknown configured tools give a suggestion and never execute a fuzzy match."
  (let ((ogent-tool-registry '((:name read-file :function ignore :args nil)))
        (ogent-tools-enabled '(read-fiel)))
    (should-not (ogent-tool-spec-get 'read-fiel))
    (let ((err (should-error (ogent-tools-enabled-list) :type 'user-error)))
      (should (string-match-p "did you mean read-file" (error-message-string err))))
    (should (string-match-p "did you mean read-file"
                            (ogent-ui--execute-tool "read-fiel" nil)))))

(ert-deftest ogent-agent-ergonomics-doctor-json-severity-and-schema ()
  "JSON batch output is data-only and preserves the 0/1/2 severity dictionary."
  (dolist (severity '((ok . 0) (warn . 1) (error . 2)))
    (let ((results (list (list :id 'fixture :label "Fixture" :category 'environment
                               :status (car severity) :detail "local check")))
          exit)
      (cl-letf (((symbol-function 'ogent-doctor-run)
                 (lambda (&optional opt-in) (should-not opt-in) results)))
        (let* ((output (with-output-to-string
			 (setq exit (ogent-doctor-batch nil 'json))))
	       (data (json-parse-string output :object-type 'plist)))
	  (should (= exit (cdr severity)))
	  (should (= (plist-get data :exit_code) exit))
	  (should (equal (plist-get data :contract_version) "1"))
	  (should (equal (plist-get data :status) (symbol-name (car severity))))
	  (should (vectorp (plist-get data :checks)))
	  (should (equal output (ogent-doctor-format-json results))))))))

(ert-deftest ogent-agent-ergonomics-doctor-json-invalid-format ()
  "Invalid formats are rejected before running even opt-in probes."
  (let (called)
    (cl-letf (((symbol-function 'ogent-doctor-run)
               (lambda (&optional _) (setq called t) nil)))
      (should-error (ogent-doctor-batch t 'jsno) :type 'user-error)
      (should-not called))))

(ert-deftest ogent-agent-ergonomics-capabilities-live-stable-and-pure ()
  "Discovery exposes live contracts without construction or registry mutation."
  (let* ((ogent-tool-registry
          '((:name z :description "Z" :args nil)
            (:name read-file :description "Read" :args
                   ((:name "file_path" :type "string")
                    (:name "mode" :type "string" :optional t :enum ("a" "b")))
                   :effects ((:kind read)))
            (:name write-file :confirm t :args nil)))
         (ogent-tools-enabled '("read_file"))
         (before (copy-tree ogent-tool-registry)))
    (cl-letf (((symbol-function 'gptel-make-tool)
               (lambda (&rest _) (ert-fail "Discovery constructed a gptel tool"))))
      (let* ((text (ogent-agent-capabilities 'json))
	     (data (json-parse-string text :object-type 'plist))
	     (tools (plist-get data :tools))
	     (read (aref tools 0)))
        (should (equal (plist-get data :contract_version) "1"))
        (should (equal (plist-get read :name) "read-file"))
        (should (eq (plist-get read :enabled) t))
        (should (eq (plist-get read :confirmation_required) :false))
        (should (eq (plist-get (aref tools 1) :confirmation_required) t))
        (should (equal (plist-get (aref (plist-get read :arguments) 1) :enum)
		       ["a" "b"]))
        (should (equal before ogent-tool-registry))
        (setq ogent-tool-registry (reverse ogent-tool-registry))
        (should (equal text (ogent-agent-capabilities 'json)))))))

(ert-deftest ogent-agent-ergonomics-capabilities-guide-and-local-triage ()
  "The handbook and triage are usable without provider or opt-in probes."
  (let ((ogent-tool-registry nil)
        called)
    (cl-letf (((symbol-function 'ogent-doctor-run)
               (lambda (&optional opt-in)
                 (should-not opt-in)
                 (setq called t)
                 '((:id fixture :label "Fixture" :category environment
			:status warn :detail "missing" :remediation "Install fixture")))))
      (let* ((data (json-parse-string (ogent-agent-triage 'json) :object-type 'plist))
	     (health (plist-get data :project_health)))
        (should called)
        (should (equal (plist-get (plist-get data :quick_ref) :tools) []))
        (should (equal (plist-get health :exit_code) 1))
        (should (equal (plist-get (aref (plist-get data :recommendations) 0) :action)
		       "Install fixture"))
        (should (string-match-p "ogent-agent-capabilities 'json" (ogent-agent-guide))))
      (setq called nil)
      (should-error (ogent-agent-triage 'jsno) :type 'user-error)
      (should-not called))))

(ert-deftest ogent-agent-ergonomics-bash-contract-invalid-before-spawn ()
  "Invalid shell inputs cannot spawn a process or produce two terminal events."
  (let ((events nil)
        spawned
        (ogent-tools-show-progress nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (setq spawned t) (error "Unexpected spawn"))))
      (should-error (ogent-tool--bash "pwd" nil 0) :type 'user-error)
      (should-not (ogent-tool--bash-async
		   "pwd" nil "bad"
		   (lambda (type data) (push (list type data) events))))
      (should-not spawned)
      (should (= (length events) 1))
      (should (eq (caar events) 'error))
      (should (string-match-p "timeout=120" (cadar events))))))

(ert-deftest ogent-agent-ergonomics-bash-contract-exit-survives-truncation ()
  "The shell exit remains visible after body truncation and stderr has no sentinel."
  (let* ((ogent-tools-max-output-chars 10)
         (ogent-tools-show-progress nil)
         (result (ogent-tool--bash "printf 12345678901234567890; exit 42")))
    (should (string-prefix-p "1234567890" result))
    (should (string-match-p "Output truncated" result))
    (should (string-suffix-p "Exit code: 42" result))
    (let ((ogent-tools-max-output-chars 1000))
      (should-not (string-match-p "Process ogent-bash" (ogent-tool--bash "printf err >&2"))))))

(ert-deftest ogent-agent-ergonomics-bash-contract-async-chunk-boundaries ()
  "Exact and oversized chunks keep their prefix and finish exactly once."
  (dolist (command '("printf 1234567890" "printf 12345678901234567890"))
    (let ((ogent-tools-max-output-chars 10)
          (ogent-tools-show-progress nil)
          (events nil)
          proc)
      (unwind-protect
          (progn
            (setq proc (ogent-tool--bash-async
                        command nil 3
                        (lambda (type data) (push (list type data) events))))
            (let ((deadline (+ (float-time) 5)))
              (while (and (not (seq-find (lambda (event) (memq (car event) '(done error))) events))
                          (< (float-time) deadline))
                (accept-process-output (and (process-live-p proc) proc) 0.01)))
            (should (= 1 (cl-count 'done events :key #'car)))
            (should (= 0 (cl-count 'error events :key #'car)))
            (should (string-prefix-p
                     "1234567890"
                     (mapconcat #'cadr
                                (seq-filter (lambda (event) (eq (car event) 'stdout))
                                            (reverse events)) ""))))
        (when (and proc (process-live-p proc)) (delete-process proc))))))

(defun ogent-agent-ergonomics-tests--make-fixture ()
  "Return an isolated directory with the audited Makefile and a failing compiler."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (source (or (getenv "OGENT_AUDIT_SOURCE") ogent-project-root)))
    (make-directory (expand-file-name "lisp" root) t)
    (make-directory (expand-file-name "test" root) t)
    (copy-file (expand-file-name "Makefile" source) (expand-file-name "Makefile" root))
    (let ((script (ogent-agent-ergonomics-tests--file
                   root "makem.sh" "#!/bin/sh\nprintf '%s\\n' 'fixture compile failure' >&2\nexit 23\n")))
      (set-file-modes script #o700))
    root))

(ert-deftest ogent-agent-ergonomics-make-contract-recompile-failure ()
  "Recompile preserves a failed compilation rather than announcing success."
  (let* ((default-directory (ogent-agent-ergonomics-tests--make-fixture))
         (fake (ogent-agent-ergonomics-tests--file
                default-directory "emacs-fixture" "#!/bin/sh\nprintf '%s\\n' 'fixture compile failure' >&2\nexit 23\n")))
    (set-file-modes fake #o700)
    (with-temp-buffer
      (should-not (zerop (call-process "make" nil t nil "recompile" (concat "EMACS=" fake))))
      (should (string-match-p "fixture compile failure" (buffer-string)))
      (should-not (string-match-p "Recompiled all" (buffer-string))))))

(ert-deftest ogent-agent-ergonomics-make-contract-clean-and-help ()
  "Clean covers test bytecode and help exposes provider-free discovery."
  (let ((default-directory (ogent-agent-ergonomics-tests--make-fixture)))
    (ogent-agent-ergonomics-tests--file default-directory "lisp/source.elc" "fixture")
    (ogent-agent-ergonomics-tests--file default-directory "test/test.elc" "fixture")
    (should (zerop (call-process "make" nil nil nil "clean")))
    (should-not (file-exists-p (expand-file-name "test/test.elc")))
    (with-temp-buffer
      (should (zerop (call-process "make" nil t nil "help")))
      (should (string-match-p "ogent-agent-triage" (buffer-string)))
      (should (string-match-p "1 warning, 2 error" (buffer-string))))))

(ert-deftest ogent-agent-ergonomics-tool-names-approval-aliases ()
  "Allow and deny rules resolve registered wire aliases with the same precedence."
  (let ((ogent-tool-registry '((:name write-file :confirm t)))
        (ogent-tool-allow-list '("write_file(*)"))
        (ogent-tool--denied-tools '("write_file"))
        (ogent-tool-require-approval t))
    (should (ogent-tool--allowed-p 'write-file nil))
    (should (ogent-tool--denied-p 'write-file))
    (should (eq (ogent-tool-approval-check 'write-file nil) 'denied))
    ;; An exact custom name wins, so its rule cannot grant its hyphen neighbor.
    (push '(:name write_file :confirm t) ogent-tool-registry)
    (should-not (ogent-tool--allowed-p 'write-file nil))
    (should-not (ogent-tool--denied-p 'write-file))
    (should (ogent-tool--denied-p 'write_file))))

(ert-deftest ogent-agent-ergonomics-edit-contract-ui-preview-ambiguity ()
  "Default diff previews reject ambiguous matches before proposing a change."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-ergonomics-tests--file root "edit.txt" "same same"))
         (ogent-ui-edit-preview-style 'diff-block)
         (ogent-ui--pending-diffs (make-hash-table :test 'equal)))
    (with-temp-buffer
      (should-error (ogent-ui--show-diff-for-tool
                     "edit-file" (list :file_path file :old_string "same"
                                       :new_string "new" :replace_all :json-false))
                    :type 'user-error)
      (should (zerop (hash-table-count ogent-ui--pending-diffs)))
      (should (equal (buffer-string) ""))
      (should (ogent-ui--show-diff-for-tool
               "edit-file" (list :file_path file :old_string "same"
                                 :new_string "new" :replace_all t))))))

(ert-deftest ogent-agent-ergonomics-edit-contract-ui-accept-error ()
  "Failed execution is never labeled applied, including bulk acceptance."
  (let ((ogent-ui--pending-diffs (make-hash-table :test 'equal)))
    (with-temp-buffer
      (puthash "fixture" (list :status 'pending :buffer (current-buffer)
                               :tool-name "edit-file" :tool-args nil)
               ogent-ui--pending-diffs)
      (cl-letf (((symbol-function 'ogent-ui--diff-at-point) (lambda () "fixture"))
                ((symbol-function 'ogent-ui--execute-tool)
                 (lambda (&rest _) "Tool error: file changed"))
                ((symbol-function 'ogent-ui--update-diff-status) #'ignore))
        (ogent-diff-accept)
        (should (eq (plist-get (gethash "fixture" ogent-ui--pending-diffs) :status) 'error))
        (ogent-accept-all-diffs)
        (should-not (eq (plist-get (gethash "fixture" ogent-ui--pending-diffs) :status) 'applied))
        (should (eq (ogent-ui--tool-result-status "Tool error: file changed") 'error))))))

(ert-deftest ogent-agent-ergonomics-argument-contract-symbol-types ()
  "Standard gptel symbol types receive the same validation as string types."
  (let ((spec '(:name typed :args ((:name "count" :type integer)
                                   (:name "flag" :type boolean)))))
    (should-error (ogent-tool-contract-validate-values spec '("bad" t)) :type 'user-error)
    (should (equal (ogent-tool-contract-validate-values spec '(0 :json-false)) '(0 nil)))))

(ert-deftest ogent-agent-ergonomics-argument-contract-mcp-false-and-absence ()
  "MCP serialization preserves optional false separately from omission."
  (let* ((ogent-tool-registry nil)
         (ogent--tools-registered nil)
         (ogent--tool-specs-registered nil)
         (ogent-tool-allow-list '("mcp-ergo-optional" "mcp-ergo-required"))
         (conn (make-ogent-mcp-connection :name "ergo"))
         (optional '((name . "optional")
                     (inputSchema . ((properties . ((flag . ((type . "boolean")))))))))
         (required '((name . "required")
                     (inputSchema . ((properties . ((flag . ((type . "boolean")))))
                                     (required . ["flag"])))))
         captured)
    (unwind-protect
        (progn
          (ogent-mcp--register-tools conn (list optional required))
          (cl-letf (((symbol-function 'ogent-mcp--call-tool)
                     (lambda (_conn _name args) (setq captured args) "ok")))
	    (let ((wrapper (ogent-tool-execution-wrapper (ogent-tool-spec-get 'mcp-ergo-optional))))
	      (funcall wrapper :json-false)
	      (should (equal captured '(:flag :json-false)))
	      (funcall wrapper nil)
	      (should-not captured)
	      (should (equal (ogent-tool-contract-values
			      (ogent-tool-spec-get 'mcp-ergo-optional) '(:flag nil))
			     '(:json-false))))
	    (funcall (ogent-tool-execution-wrapper (ogent-tool-spec-get 'mcp-ergo-required)) nil)
	    (should (equal (json-encode (ogent-mcp--args-to-alist captured)) "{\"flag\":false}"))))
      (ogent-mcp--unregister-tools "ergo"))))

(ert-deftest ogent-agent-ergonomics-offline-contract-missing-dependencies ()
  "Missing offline prerequisites fail before fixtures, with data-free stdout."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (source (or (getenv "OGENT_AUDIT_SOURCE") ogent-project-root))
         (dest (expand-file-name "test/offline" root))
         (process-environment (seq-remove (lambda (entry)
                                            (string-match-p "\\`OGENT_\\(?:ELPA\\|GPTEL\\)_DIR=" entry))
                                          process-environment))
         (stderr (expand-file-name "stderr" root)))
    (make-directory dest t)
    (dolist (name '("run.sh" "boot.el.in" "workflows.el.in" "http-fixture.py"))
      (copy-file (expand-file-name (concat "test/offline/" name) source)
                 (expand-file-name name dest)))
    (with-temp-buffer
      (should-not (zerop (call-process "bash" nil (list t stderr) nil
                                       (expand-file-name "run.sh" dest))))
      (should (equal (buffer-string) "")))
    (with-temp-buffer
      (insert-file-contents stderr)
      (should (string-match-p "OGENT_ELPA_DIR" (buffer-string)))
      (should (string-match-p "make offline-test" (buffer-string)))
      (should-not (string-match-p "Backtrace\\|Error:" (buffer-string))))))

(ert-deftest ogent-agent-ergonomics-edit-contract-reviewed-target-stable ()
  "A reviewed relative file target becomes absolute for subsequent execution."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (ogent-tools-project-root root)
         (ogent-ui-edit-preview-style 'diff-block)
         (ogent-ui--pending-diffs (make-hash-table :test 'equal)))
    (ogent-agent-ergonomics-tests--file root "target.txt" "before")
    (with-temp-buffer
      (let* ((id (ogent-ui--show-diff-for-tool
                  "write-file" '(:file_path "target.txt" :content "after")))
             (info (gethash id ogent-ui--pending-diffs)))
        (should (equal (plist-get info :file-path) (expand-file-name "target.txt" root)))
        (should (equal (plist-get (plist-get info :tool-args) :file_path)
                       (expand-file-name "target.txt" root)))))))

(provide 'ogent-agent-ergonomics-tests)
;;; ogent-agent-ergonomics-tests.el ends here
