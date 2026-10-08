;;; ogent-agent-ergonomics-tests.el --- Agent interface regressions -*- lexical-binding: t; -*-

;;; Commentary:
;; Pin observable search, edit, argument, and automation contracts.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-tools)
(require 'ogent-models)
(require 'ogent-doctor)
(require 'ogent-ui-toolcalls)

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

(provide 'ogent-agent-ergonomics-tests)
;;; ogent-agent-ergonomics-tests.el ends here
