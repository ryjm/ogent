;;; ogent-agent-execution-tests.el --- Fluent tool API tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise structured execution through the real registry and policy owners.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-agent nil t)
(require 'ogent-tools)
(require 'ogent-ui-toolcalls)
(require 'ogent-tool-results nil t)

(defun ogent-agent-execution-tests--file (root name text)
  "Create fixture NAME containing TEXT under ROOT."
  (let ((file (expand-file-name name root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    file))

(ert-deftest ogent-agent-execution-read-structured-pages ()
  "Structured reads return exact positions, content and genuine JSON arrays."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-execution-tests--file root "read.txt" "alpha\nbeta\ngamma\n"))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (result (ogent-agent-call "read_file" (list :file_path file :limit 2)))
         (data (plist-get result :data)))
    (should (equal (plist-get result :status) "ok"))
    (should (equal (plist-get data :content) "alpha\nbeta"))
    (should (= (plist-get data :total_lines) 3))
    (should (= (plist-get data :next_offset) 3))
    (should (vectorp (plist-get data :lines)))
    (should (equal (plist-get (json-parse-string (ogent-tool--read-file file 3 2 'json)
                                                :object-type 'plist) :content) "gamma"))
    (should (string-match-p "1\talpha" (ogent-tool--read-file file 1 2)))))

(ert-deftest ogent-agent-execution-read-long-line-continuation ()
  "A bounded long-line page retains every character through continuation."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-execution-tests--file root "long.txt" "abcdefghij\nlast\n"))
         (ogent-tools-max-output-chars 4)
         (first (ogent-tool-results-read file 1 20))
         (second (ogent-tool-results-read file (plist-get first :next_offset) 20
                                           (plist-get first :next_column))))
    (should (equal (plist-get first :content) "abcd"))
    (should (= (plist-get first :next_offset) 1))
    (should (= (plist-get first :next_column) 5))
    (should (equal (plist-get second :content) "efgh"))
    (should (equal (plist-get first :snapshot) (plist-get second :snapshot)))))

(ert-deftest ogent-agent-execution-read-empty-and-invalid ()
  "Empty files have no invented lines, and invalid positions remain typed."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-execution-tests--file root "empty.txt" ""))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (data (plist-get (ogent-agent-call "read-file" (list :file_path file)) :data)))
    (should (equal (plist-get data :lines) []))
    (should (eq (plist-get data :has_more) :json-false))
    (should (equal (plist-get (ogent-agent-call "read-file" (list :file_path file :offset 2)) :status)
                   "error"))))

(ert-deftest ogent-agent-execution-glob-complete-pagination ()
  "File discovery exposes every result beyond the previous 100-file cap."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry)))
    (dotimes (index 105)
      (ogent-agent-execution-tests--file root (format "%03d.el" index) ""))
    (let* ((first (plist-get (ogent-agent-call "glob" (list :pattern "*.el" :path root)) :data))
           (last (plist-get (ogent-agent-call "glob" (list :pattern "*.el" :path root :offset 100)) :data)))
      (should (= (plist-get first :total_files) 105))
      (should (= (length (plist-get first :files)) 100))
      (should (= (length (plist-get last :files)) 5))
      (should (eq (plist-get last :has_more) :json-false))
      (should (equal (plist-get first :snapshot) (plist-get last :snapshot))))
    (should (string-match-p "Showing 100 of 105" (ogent-tool--glob "*.el" root)))))

(ert-deftest ogent-agent-execution-glob-json-empty-and-weird-paths ()
  "Empty arrays and paths containing newlines survive the JSON interface."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-execution-tests--file root "colon:new\nline.el" ""))
         (data (json-parse-string (ogent-tool--glob "*.el" root 'json) :object-type 'plist)))
    (should (equal (plist-get (aref (plist-get data :files) 0) :path) file))
    (should (equal (plist-get (ogent-tool-results-glob "*.txt" root) :files) []))
    (should-error (ogent-tool-results-glob "*.el" root 2) :type 'user-error)))

(ert-deftest ogent-agent-execution-next-freezes-path-and-follows-json ()
  "Continuation calls retain absolute targets when the working root changes."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (other (ogent-test--provision-store-directory 'tools))
         (ogent-tools-project-root root)
         (ogent-tool-registry (copy-tree ogent-tools-default-registry)))
    (ogent-agent-execution-tests--file root "data.txt" "a\nb\nc\n")
    (ogent-agent-execution-tests--file other "data.txt" "wrong\n")
    (let ((first (ogent-agent-call "read_file" '(:file_path "data.txt" :limit 1) 'json)))
      (let* ((ogent-tools-project-root other)
             (second (ogent-agent-next first))
             (third (ogent-agent-next second)))
        (should (equal (plist-get (plist-get second :data) :content) "b"))
        (should (equal (plist-get (plist-get third :data) :content) "c"))
        (should (equal (plist-get (ogent-agent-next third) :status) "done"))))))

(ert-deftest ogent-agent-execution-next-refuses-changed-snapshot ()
  "Changed file pages are discarded with an explicit restart instruction."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-execution-tests--file root "data.txt" "a\nb\n"))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (first (ogent-agent-call "read-file" (list :file_path file :limit 1))))
    (with-temp-file file (insert "a\nchanged\n"))
    (let ((result (ogent-agent-next first)))
      (should (equal (plist-get (plist-get result :error) :code) "snapshot_changed"))
      (should (eq (plist-get result :data) :json-null)))))

(ert-deftest ogent-agent-execution-next-retains-long-line-characters ()
  "Following pages reconstructs long lines without dropping characters."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-execution-tests--file root "data.txt" "abcdefghij"))
         (ogent-tools-max-output-chars 3)
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (page (ogent-agent-call "read-file" (list :file_path file)))
         (content ""))
    (while (equal (plist-get page :status) "ok")
      (setq content (concat content (plist-get (plist-get page :data) :content))
            page (ogent-agent-next page)))
    (should (equal content "abcdefghij"))))

(ert-deftest ogent-agent-execution-aliases-share-policy ()
  "Common verbs resolve exactly and cannot bypass a canonical denial."
  (let ((ogent-tool-registry (copy-tree ogent-tools-default-registry))
        (ogent-tool--denied-tools '("bash"))
        (ogent-tool-require-approval t))
    (should (eq (ogent-tool--name-symbol "read") 'read-file))
    (should (eq (ogent-tool--name-symbol "find") 'glob))
    (should (eq (ogent-tool--name-symbol "search") 'grep))
    (should (equal (plist-get (ogent-agent-call "shell" '(:command "printf unsafe")) :status) "denied"))
    (let ((error-data (plist-get (ogent-agent-call "shll" nil) :error)))
      (should (equal (plist-get error-data :code) "unknown_tool"))
      (should (string-match-p "did you mean shell" (plist-get error-data :message))))))

(ert-deftest ogent-agent-execution-aliases-exact-and-ambiguous ()
  "Exact registrations win and ambiguous declared aliases never execute."
  (let ((ogent-tool-registry
         '((:name alpha :aliases ["shared" "exact"])
           (:name beta :aliases ["shared"])
           (:name exact))))
    (should (eq (ogent-tool--name-symbol "exact") 'exact))
    (should-not (ogent-tool-spec-get "shared"))))

(ert-deftest ogent-agent-execution-process-grep-integration ()
  "Structured search participates in the same one-call pagination contract."
  (let* ((root (ogent-test--provision-store-directory 'tools))
         (file (ogent-agent-execution-tests--file root "colon:new\nline.txt" "needle\nneedle\nneedle\n"))
         (ogent-tool-registry (copy-tree ogent-tools-default-registry))
         (first (ogent-agent-call "search" (list :pattern "needle" :path root :limit 2)))
         (last (ogent-agent-next first)))
    (should (equal (plist-get first :status) "ok"))
    (should (= (plist-get (plist-get first :data) :total_matches) 3))
    (should (equal (plist-get (aref (plist-get (plist-get last :data) :matches) 0) :path) file))
    (should (= (plist-get (aref (plist-get (plist-get last :data) :matches) 0) :line) 3))
    (should (vectorp (plist-get (ogent-tool--grep "needle" file nil 0 'plist) :matches)))))

(ert-deftest ogent-agent-execution-process-shell-failures-retain-data ()
  "Nonzero exits and timeouts are typed failures with retained diagnostics."
  (let ((ogent-tool-registry (copy-tree ogent-tools-default-registry))
        (ogent-tool-require-approval nil))
    (let ((failed (ogent-agent-call "shell" '(:command "printf out; printf err >&2; exit 7")))
          (timed (ogent-agent-call "shell" '(:command "printf partial; sleep 2" :timeout 0.1))))
      (should (equal (plist-get (plist-get failed :error) :code) "command_failed"))
      (should (= (plist-get (plist-get failed :data) :exit_code) 7))
      (should (equal (plist-get (plist-get failed :data) :stderr) "err"))
      (should (equal (plist-get (plist-get timed :error) :code) "timeout"))
      (should (equal (plist-get (plist-get timed :data) :stdout) "partial")))))

(ert-deftest ogent-agent-execution-named-call-and-json ()
  "Named calls preserve values and return independently parseable JSON."
  (let ((ogent-tool-registry
         (list (list :name 'echo :function #'identity
                     :args '((:name "value" :type "string")))))
        (ogent-tool-require-approval nil))
    (let ((result (json-parse-string
                   (ogent-agent-call "echo" '(:value "Tool error: literal") 'json)
                   :object-type 'plist)))
      (should (equal (plist-get result :status) "ok"))
      (should (equal (plist-get (plist-get result :data) :value) "Tool error: literal"))
      (should (equal (plist-get result :contract_version) "1")))))

(ert-deftest ogent-agent-execution-validates-before-policy ()
  "Invalid arguments and formats cannot reach approval or execution."
  (let ((ogent-tool-registry
         (list (list :name 'echo :function #'identity
                     :args '((:name "value" :type "string")))))
        (calls 0))
    (cl-letf (((symbol-function 'ogent-tool-approval-check)
               (lambda (&rest _) (cl-incf calls) 'approved)))
      (should (equal (plist-get (plist-get (ogent-agent-call "echo" '(:value 5)) :error) :code)
                     "invalid_arguments"))
      (should-error (ogent-agent-call "echo" '(:value "x") 'yaml) :type 'user-error)
      (should (= calls 0)))))

(ert-deftest ogent-agent-execution-denial-and-approval-required ()
  "Denied and approval-required calls cannot mutate files or prompt."
  (let ((ogent-tool-registry (copy-tree ogent-tools-default-registry))
        (ogent-tool-allow-list nil)
        (ogent-tool--denied-tools nil)
        (ogent-tool-require-approval t)
        (root (ogent-test--provision-store-directory 'tools)))
    (cl-letf (((symbol-function 'ogent-tool--prompt-approval)
               (lambda (&rest _) (ert-fail "Programmatic calls must not prompt"))))
      (let ((file (expand-file-name "new.txt" root)))
        (should (equal (plist-get (ogent-agent-call "write_file" (list :file_path file :content "new")) :status)
                       "approval_required"))
        (should-not (file-exists-p file))
        (let ((ogent-tool--denied-tools '("write-file")))
          (should (equal (plist-get (ogent-agent-call "write_file" (list :file_path file :content "new")) :status)
                         "denied")))
        (should-not (file-exists-p file))))))

(ert-deftest ogent-agent-execution-failures-recorded ()
  "An execution failure is typed and records a failed ledger terminal."
  (let ((ogent-tool-registry
         (list (list :name 'fail :function (lambda () (user-error "Choose an existing file"))
                     :args nil)))
        (ogent-tool-require-approval nil)
        recorded)
    (cl-letf (((symbol-function 'ogent-ledger-record-tool-finish)
               (lambda (_call _result failure &rest _) (setq recorded failure))))
      (let ((result (ogent-agent-call "fail" nil)))
        (should (equal (plist-get result :status) "error"))
        (should (equal (plist-get (plist-get result :error) :code) "execution_failed"))
        (should (equal recorded "Choose an existing file"))))))

(provide 'ogent-agent-execution-tests)
;;; ogent-agent-execution-tests.el ends here
