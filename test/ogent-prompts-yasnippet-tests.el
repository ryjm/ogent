;;; ogent-prompts-yasnippet-tests.el --- Tests for yasnippet integration -*- lexical-binding: t; -*-

;;; Commentary:
;; Test coverage for yasnippet integration with ogent prompts.
;; Core snippet generation tests run without yasnippet.
;; Mode integration tests require yasnippet and are skipped if unavailable.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-prompts)
(require 'ogent-prompts-yasnippet)

;;; Snippet Generation Tests (no yasnippet required)

(ert-deftest ogent-prompt-to-snippet-basic ()
  "Convert a prompt to yasnippet format."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "test-prompt"
                           :title "Test Prompt"
                           :content "Do the thing.")
    (let ((snippet (ogent-prompt-to-snippet "test-prompt")))
      (should snippet)
      (should (string-match-p "# name: Test Prompt" snippet))
      (should (string-match-p "# key: @test-prompt" snippet))
      (should (string-match-p "Do the thing" snippet)))))

(ert-deftest ogent-prompt-to-snippet-with-placeholders ()
  "Snippet includes tab stops for customization."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "review"
                           :title "Review"
                           :content "Review this code:\n${1:code here}")
    (let ((snippet (ogent-prompt-to-snippet "review")))
      (should (string-match-p "\\${1:" snippet)))))

(ert-deftest ogent-prompt-to-snippet-returns-nil-for-unknown ()
  "Return nil for unknown prompt IDs."
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (should (null (ogent-prompt-to-snippet "nonexistent")))))

;;; Snippet Installation Tests (no yasnippet required for file operations)

(ert-deftest ogent-prompts-snippet-dir-customizable ()
  "Snippet directory is customizable."
  (should (boundp 'ogent-prompts-snippet-dir)))

(ert-deftest ogent-prompts-install-snippets-creates-files ()
  "Installing snippets creates snippet files."
  (let* ((temp-dir (make-temp-file "ogent-snippets" t))
         (ogent-prompts-snippet-dir temp-dir)
         (ogent-prompt-registry (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (ogent-prompt-register "test-one" :title "Test One" :content "One")
          (ogent-prompt-register "test-two" :title "Test Two" :content "Two")
          (ogent-prompts-install-snippets)
          ;; Check that snippet files were created
          (should (file-exists-p (expand-file-name "test-one" temp-dir)))
          (should (file-exists-p (expand-file-name "test-two" temp-dir))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-prompts-install-snippets-content-correct ()
  "Installed snippet files have correct content."
  (let* ((temp-dir (make-temp-file "ogent-snippets" t))
         (ogent-prompts-snippet-dir temp-dir)
         (ogent-prompt-registry (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (ogent-prompt-register "my-prompt"
                                 :title "My Prompt"
                                 :content "Do something useful.")
          (ogent-prompts-install-snippets)
          (let ((content (with-temp-buffer
                           (insert-file-contents
                            (expand-file-name "my-prompt" temp-dir))
                           (buffer-string))))
            (should (string-match-p "# name: My Prompt" content))
            (should (string-match-p "# key: @my-prompt" content))
            (should (string-match-p "Do something useful" content))))
      (delete-directory temp-dir t))))

;;; Mode Integration Tests

(ert-deftest ogent-prompts-yasnippet-mode-available ()
  "Yasnippet mode function is available."
  (skip-unless (featurep 'yasnippet))
  (should (fboundp 'ogent-prompts-yasnippet-mode)))

(ert-deftest ogent-prompts-yasnippet-mode-adds-to-path ()
  "Enabling mode adds snippet dir to yas-snippet-dirs."
  (skip-unless (featurep 'yasnippet))
  (let* ((temp-dir (make-temp-file "ogent-snippets" t))
         (ogent-prompts-snippet-dir temp-dir)
         (yas-snippet-dirs nil))
    (unwind-protect
        (with-temp-buffer
          (ogent-prompts-yasnippet-mode 1)
          (should (member temp-dir yas-snippet-dirs)))
      (delete-directory temp-dir t))))

;;; Completion Tests

(ert-deftest ogent-prompts-yasnippet-expands-handle ()
  "Typing @handle and TAB expands the snippet."
  (skip-unless (featurep 'yasnippet))
  ;; This is more of an integration test - just verify the mechanism exists
  (should (fboundp 'ogent-prompts-expand-at-point)))

(provide 'ogent-prompts-yasnippet-tests)
;;; ogent-prompts-yasnippet-tests.el ends here
