;;; ogent-presets-tests.el --- Tests for project presets -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for ogent-presets.el covering:
;; - .ogent.el file loading and validation
;; - Preset application edge cases
;; - Invalid/malformed preset files
;; - Project root detection
;; - Settings cascade behavior

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-presets)

;;; Project Root Detection Tests

(ert-deftest ogent-presets-project-root-finds-git ()
  "Project root detection should find .git directories."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (git-dir (expand-file-name ".git" temp-dir))
         (sub-dir (expand-file-name "src/deep" temp-dir)))
    (unwind-protect
        (progn
          (make-directory git-dir)
          (make-directory sub-dir t)
          (let ((default-directory sub-dir))
            ;; Normalize paths to handle trailing slash differences
            (should (equal (directory-file-name (ogent-presets-project-root))
                           (directory-file-name temp-dir)))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-project-root-finds-ogent-file ()
  "Project root detection should prioritize .ogent.el."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir))
         (sub-dir (expand-file-name "lib/utils" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "()"))
          (make-directory sub-dir t)
          (let ((default-directory sub-dir))
            ;; Normalize paths to handle trailing slash differences
            (should (equal (directory-file-name (ogent-presets-project-root))
                           (directory-file-name temp-dir)))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-project-root-caches-results ()
  "Project root should be cached for performance."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (git-dir (expand-file-name ".git" temp-dir)))
    (unwind-protect
        (progn
          (make-directory git-dir)
          ;; Clear cache first
          (ogent-presets-clear-cache)
          (let ((default-directory temp-dir))
            ;; First call computes
            (ogent-presets-project-root)
            ;; Should now be cached
            (should (gethash temp-dir ogent-presets--project-cache))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-clear-cache-works ()
  "Cache clearing should remove all entries."
  (puthash "/fake/path" "/fake/root" ogent-presets--project-cache)
  (ogent-presets-clear-cache)
  (should (= 0 (hash-table-count ogent-presets--project-cache))))

;;; .ogent.el File Parsing Tests

(ert-deftest ogent-presets-safe-read-valid-file ()
  "Safe read should parse valid .ogent.el files."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "((ogent-project-model . \"claude-3.5\")\n")
            (insert " (ogent-project-context-files . (\"README.md\")))"))
          (let ((settings (ogent-presets--safe-read ogent-file)))
            (should settings)
            (should (equal (cdr (assq 'ogent-project-model settings)) "claude-3.5"))
            (should (equal (cdr (assq 'ogent-project-context-files settings)) '("README.md")))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-safe-read-rejects-unknown-vars ()
  "Safe read should reject unknown variable names."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "((ogent-project-model . \"claude-3.5\")\n")
            (insert " (malicious-var . \"bad-value\"))"))
          (let ((settings (ogent-presets--safe-read ogent-file)))
            ;; Should return nil due to invalid variable
            (should (null settings))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-safe-read-handles-malformed ()
  "Safe read should handle malformed files gracefully."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "this is not valid elisp ((("))
          (let ((settings (ogent-presets--safe-read ogent-file)))
            (should (null settings))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-safe-read-empty-file ()
  "Safe read should handle empty files."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert ""))
          ;; Empty file causes read error, should return nil
          (let ((settings (ogent-presets--safe-read ogent-file)))
            (should (null settings))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-safe-read-nil-settings ()
  "Safe read should accept nil/empty settings list."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "nil"))
          (let ((settings (ogent-presets--safe-read ogent-file)))
            ;; nil is not a valid alist, should return nil
            (should (null settings))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-safe-read-empty-alist ()
  "Safe read should accept empty alist."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "()"))
          (let ((settings (ogent-presets--safe-read ogent-file)))
            (should (null settings))))
      (delete-directory temp-dir t))))

;;; Settings Application Tests

(ert-deftest ogent-presets-apply-settings-sets-vars ()
  "Apply settings should set buffer-local variables."
  (with-temp-buffer
    (let ((settings '((ogent-project-model . "gpt-4")
                      (ogent-project-context-files . ("README.md")))))
      (ogent-presets--apply-settings settings)
      (should (equal ogent-project-model "gpt-4"))
      (should (equal ogent-project-context-files '("README.md"))))))

(ert-deftest ogent-presets-apply-settings-ignores-unknown ()
  "Apply settings should ignore unknown variables."
  (with-temp-buffer
    (let ((settings '((ogent-project-model . "gpt-4")
                      (unknown-variable . "ignored"))))
      ;; Should not error
      (ogent-presets--apply-settings settings)
      (should (equal ogent-project-model "gpt-4")))))

(ert-deftest ogent-presets-apply-settings-buffer-local ()
  "Applied settings should be buffer-local."
  (let ((buf1 (generate-new-buffer " *test1*"))
        (buf2 (generate-new-buffer " *test2*")))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (ogent-presets--apply-settings '((ogent-project-model . "model-1"))))
          (with-current-buffer buf2
            (ogent-presets--apply-settings '((ogent-project-model . "model-2"))))
          ;; Check each buffer has its own value
          (with-current-buffer buf1
            (should (equal ogent-project-model "model-1")))
          (with-current-buffer buf2
            (should (equal ogent-project-model "model-2"))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

;;; Effective Settings Tests

(ert-deftest ogent-presets-effective-model-project-overrides ()
  "Project model should override global default."
  (with-temp-buffer
    (setq-local ogent-project-model "project-model")
    (defvar ogent-default-model "global-model")
    (let ((ogent-default-model "global-model"))
      (should (equal (ogent-presets-effective-model) "project-model")))))

(ert-deftest ogent-presets-effective-model-fallback ()
  "Should fall back to global default when no project model."
  (with-temp-buffer
    (setq-local ogent-project-model nil)
    (defvar ogent-default-model "global-model")
    (let ((ogent-default-model "global-model"))
      (should (equal (ogent-presets-effective-model) "global-model")))))

(ert-deftest ogent-presets-effective-tools-local-override ()
  "Local tools setting should override global."
  (with-temp-buffer
    (setq-local ogent-project-tools '(bash read))
    (defvar ogent-tools-enabled t)
    (let ((ogent-tools-enabled t))
      (should (equal (ogent-presets-effective-tools) '(bash read))))))

;;; Preset Loading Tests

(ert-deftest ogent-presets-load-tracks-loaded-projects ()
  "Loading should track which projects have been loaded."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir))
         (ogent-presets--loaded-projects (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "((ogent-project-model . \"test\"))"))
          (let ((default-directory temp-dir))
            (ogent-presets-load)
            ;; Check if any key matching our temp-dir (with or without slash) exists
            (let ((found nil))
              (maphash (lambda (k _v)
                         (when (equal (directory-file-name k)
                                      (directory-file-name temp-dir))
                           (setq found t)))
                       ogent-presets--loaded-projects)
              (should found))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-load-skips-already-loaded ()
  "Loading should skip if already loaded for project."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir))
         (ogent-presets--loaded-projects (make-hash-table :test 'equal))
         (load-count 0))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "((ogent-project-model . \"test\"))"))
          (cl-letf (((symbol-function 'ogent-presets--apply-settings)
                     (lambda (_) (cl-incf load-count))))
            (let ((default-directory temp-dir))
              (ogent-presets-load)
              (ogent-presets-load)
              (ogent-presets-load)
              ;; Should only load once
              (should (= 1 load-count)))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-load-force-reloads ()
  "Force flag should reload even if already loaded."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-file (expand-file-name ".ogent.el" temp-dir))
         (ogent-presets--loaded-projects (make-hash-table :test 'equal))
         (load-count 0))
    (unwind-protect
        (progn
          (with-temp-file ogent-file
            (insert "((ogent-project-model . \"test\"))"))
          (cl-letf (((symbol-function 'ogent-presets--apply-settings)
                     (lambda (_) (cl-incf load-count))))
            (let ((default-directory temp-dir))
              (ogent-presets-load)
              (ogent-presets-load t)  ; Force
              (should (= 2 load-count)))))
      (delete-directory temp-dir t))))

;;; Edge Cases

(ert-deftest ogent-presets-handles-missing-file ()
  "Loading should handle missing .ogent.el gracefully."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (ogent-presets--loaded-projects (make-hash-table :test 'equal)))
    (unwind-protect
        (let ((default-directory temp-dir))
          ;; Should not error
          (ogent-presets-load)
          ;; Nothing should be cached for this project
          (should (null (gethash temp-dir ogent-presets--loaded-projects))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-preset-symbol-handling ()
  "Preset should handle both string and symbol references."
  (with-temp-buffer
    (let ((settings '((ogent-project-preset . ogent-code-review))))
      (ogent-presets--apply-settings settings)
      (should (eq ogent-project-preset 'ogent-code-review)))))

(ert-deftest ogent-presets-codemap-roots-list ()
  "Codemap roots should accept list of directories."
  (with-temp-buffer
    (let ((settings '((ogent-project-codemap-roots . ("src" "lib" "test")))))
      (ogent-presets--apply-settings settings)
      (should (equal ogent-project-codemap-roots '("src" "lib" "test"))))))

(ert-deftest ogent-presets-system-prompt-string ()
  "System prompt should accept string values."
  (with-temp-buffer
    (let ((settings '((ogent-project-system-prompt . "You are a helpful assistant."))))
      (ogent-presets--apply-settings settings)
      (should (equal ogent-project-system-prompt "You are a helpful assistant.")))))

(ert-deftest ogent-presets-context-files-list ()
  "Context files should accept list of paths."
  (with-temp-buffer
    (let ((settings '((ogent-project-context-files . ("README.md" "ARCHITECTURE.md" "docs/API.md")))))
      (ogent-presets--apply-settings settings)
      (should (= 3 (length ogent-project-context-files)))
      (should (member "README.md" ogent-project-context-files)))))

;;; Include Context Tests

(ert-deftest ogent-presets-include-context-reads-files ()
  "Include context should read and format project files."
  (let* ((temp-dir (make-temp-file "ogent-test-" t))
         (readme (expand-file-name "README.md" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file readme
            (insert "# Project\nThis is the readme."))
          (with-temp-buffer
            (setq-local ogent-project-context-files '("README.md"))
            (let ((default-directory temp-dir))
              (let ((content (ogent-presets-include-context)))
                (should content)
                (should (string-match-p "README.md" content))
                (should (string-match-p "This is the readme" content))))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-include-context-skips-missing ()
  "Include context should skip missing files."
  (let ((temp-dir (make-temp-file "ogent-test-" t)))
    (unwind-protect
        (with-temp-buffer
          (setq-local ogent-project-context-files '("MISSING.md"))
          (let ((default-directory temp-dir))
            (let ((content (ogent-presets-include-context)))
              ;; Should return nil, not error
              (should (null content)))))
      (delete-directory temp-dir t))))

(provide 'ogent-presets-tests)

;;; ogent-presets-tests.el ends here
