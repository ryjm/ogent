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
    (should (string-match-p "pattern" (error-message-string err)))))

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

(provide 'ogent-agent-ergonomics-tests)
;;; ogent-agent-ergonomics-tests.el ends here
