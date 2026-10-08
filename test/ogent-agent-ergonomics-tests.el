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

(provide 'ogent-agent-ergonomics-tests)
;;; ogent-agent-ergonomics-tests.el ends here
