;;; ogent-presets-tests.el --- Tests for ogent-presets -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-presets)

;;; Project Root Detection Tests

(ert-deftest ogent-presets-project-root-uses-cache ()
  "Project root should be cached for performance."
  (let ((ogent-presets--project-cache (make-hash-table :test 'equal))
        (default-directory "/tmp/test-project/"))
    ;; Pre-populate cache
    (puthash "/tmp/test-project/" "/tmp/test-project/" ogent-presets--project-cache)
    ;; Should return cached value
    (should (equal (ogent-presets-project-root) "/tmp/test-project/"))))

(ert-deftest ogent-presets-clear-cache-empties-cache ()
  "ogent-presets-clear-cache should empty the project cache."
  (let ((ogent-presets--project-cache (make-hash-table :test 'equal)))
    (puthash "/some/path" "/some/root" ogent-presets--project-cache)
    (ogent-presets-clear-cache)
    (should (= 0 (hash-table-count ogent-presets--project-cache)))))

(ert-deftest ogent-presets-project-root-respects-dir-argument ()
  "Project root should use provided directory argument."
  (let ((ogent-presets--project-cache (make-hash-table :test 'equal)))
    ;; Mock locate-dominating-file to return the directory itself
    (cl-letf (((symbol-function 'locate-dominating-file)
               (lambda (dir _file) dir))
              ((symbol-function 'project-current)
               (lambda (&rest _) nil)))
      (let ((result (ogent-presets-project-root "/custom/path/")))
        (should (equal result "/custom/path/"))))))

;;; Safe Read Tests

(ert-deftest ogent-presets--safe-read-returns-alist-from-valid-file ()
  "Safe read should parse valid .ogent.el file."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "((ogent-project-model . \"claude-3.5\")\n")
            (insert " (ogent-project-preset . ogent-code-review))"))
          (let ((result (ogent-presets--safe-read temp-file)))
            (should (listp result))
            (should (equal (cdr (assq 'ogent-project-model result)) "claude-3.5"))
            (should (equal (cdr (assq 'ogent-project-preset result)) 'ogent-code-review))))
      (delete-file temp-file))))

(ert-deftest ogent-presets--safe-read-rejects-disallowed-variables ()
  "Safe read should reject files with disallowed variables."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "((evil-variable . \"bad-value\"))"))
          (let ((result (ogent-presets--safe-read temp-file)))
            (should (null result))))
      (delete-file temp-file))))

(ert-deftest ogent-presets--safe-read-handles-read-error ()
  "Safe read should handle malformed lisp gracefully."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "(((malformed"))
          (let ((result (ogent-presets--safe-read temp-file)))
            (should (null result))))
      (delete-file temp-file))))

(ert-deftest ogent-presets--safe-read-handles-empty-file ()
  "Safe read should handle empty file gracefully."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert ""))
          ;; Empty file causes read error (end of file during parsing)
          (let ((result (ogent-presets--safe-read temp-file)))
            (should (null result))))
      (delete-file temp-file))))

(ert-deftest ogent-presets--safe-read-allows-all-valid-variables ()
  "Safe read should allow all variables in allowed list."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "((ogent-project-model . \"model\")\n")
            (insert " (ogent-project-preset . preset)\n")
            (insert " (ogent-project-context-files . (\"a.md\" \"b.md\"))\n")
            (insert " (ogent-project-codemap-roots . (\"src\"))\n")
            (insert " (ogent-project-prompts . ((\"id\" . \"content\")))\n")
            (insert " (ogent-project-tools . (tool1 tool2))\n")
            (insert " (ogent-project-system-prompt . \"prompt\"))"))
          (let ((result (ogent-presets--safe-read temp-file)))
            (should (= 7 (length result)))))
      (delete-file temp-file))))

;;; Apply Settings Tests

(ert-deftest ogent-presets--apply-settings-sets-local-variables ()
  "Apply settings should set buffer-local variables."
  (with-temp-buffer
    (let ((settings '((ogent-project-model . "test-model")
                      (ogent-project-preset . test-preset))))
      (ogent-presets--apply-settings settings)
      (should (equal ogent-project-model "test-model"))
      (should (equal ogent-project-preset 'test-preset)))))

(ert-deftest ogent-presets--apply-settings-ignores-disallowed ()
  "Apply settings should ignore variables not in allowed list."
  (with-temp-buffer
    (let ((settings '((ogent-project-model . "valid")
                      (some-other-variable . "ignored"))))
      (ogent-presets--apply-settings settings)
      (should (equal ogent-project-model "valid"))
      (should-not (boundp 'some-other-variable)))))

(ert-deftest ogent-presets--apply-settings-handles-empty-settings ()
  "Apply settings should handle empty settings list."
  (with-temp-buffer
    (ogent-presets--apply-settings nil)
    ;; Should not error, buffer-local vars remain default
    (should (null ogent-project-model))))

(ert-deftest ogent-presets--apply-settings-sets-list-values ()
  "Apply settings should correctly set list values."
  (with-temp-buffer
    (let ((settings '((ogent-project-context-files . ("README.md" "ARCH.md"))
                      (ogent-project-codemap-roots . ("src" "lib")))))
      (ogent-presets--apply-settings settings)
      (should (equal ogent-project-context-files '("README.md" "ARCH.md")))
      (should (equal ogent-project-codemap-roots '("src" "lib"))))))

;;; Effective Value Accessor Tests

(ert-deftest ogent-presets-effective-model-returns-project-model ()
  "Effective model should return project model when set."
  (with-temp-buffer
    (setq-local ogent-project-model "project-model")
    (should (equal (ogent-presets-effective-model) "project-model"))))

(ert-deftest ogent-presets-effective-model-falls-back-to-global ()
  "Effective model should fall back to global default."
  (with-temp-buffer
    ;; Don't set the local variable at all - let it remain unbound locally
    (defvar ogent-default-model)
    (let ((ogent-default-model "global-default"))
      (should (equal (ogent-presets-effective-model) "global-default")))))

(ert-deftest ogent-presets-effective-model-returns-nil-when-unset ()
  "Effective model should return nil when neither is set."
  (with-temp-buffer
    (setq-local ogent-project-model nil)
    (when (boundp 'ogent-default-model)
      (makunbound 'ogent-default-model))
    (should (null (ogent-presets-effective-model)))))

(ert-deftest ogent-presets-effective-preset-returns-project-preset ()
  "Effective preset should return project preset."
  (with-temp-buffer
    (setq-local ogent-project-preset 'my-preset)
    (should (equal (ogent-presets-effective-preset) 'my-preset))))

(ert-deftest ogent-presets-effective-preset-returns-nil-when-unset ()
  "Effective preset should return nil when unset."
  (with-temp-buffer
    (should (null (ogent-presets-effective-preset)))))

(ert-deftest ogent-presets-effective-codemap-roots-returns-project-roots ()
  "Effective codemap roots should return project-specific roots."
  (with-temp-buffer
    (setq-local ogent-project-codemap-roots '("custom/src"))
    (should (equal (ogent-presets-effective-codemap-roots) '("custom/src")))))

(ert-deftest ogent-presets-effective-codemap-roots-falls-back ()
  "Effective codemap roots should fall back to global setting."
  (with-temp-buffer
    ;; Don't set the local variable - let it remain unbound locally
    (defvar ogent-codemap-source-directories)
    (let ((ogent-codemap-source-directories '("default/src")))
      (should (equal (ogent-presets-effective-codemap-roots) '("default/src"))))))

(ert-deftest ogent-presets-effective-tools-returns-local-when-set ()
  "Effective tools should return local value when explicitly set."
  (with-temp-buffer
    (setq-local ogent-project-tools '(tool1 tool2))
    (should (equal (ogent-presets-effective-tools) '(tool1 tool2)))))

(ert-deftest ogent-presets-effective-tools-handles-t-value ()
  "Effective tools should handle t value (enable all)."
  (with-temp-buffer
    (setq-local ogent-project-tools t)
    (should (eq (ogent-presets-effective-tools) t))))

(ert-deftest ogent-presets-effective-tools-falls-back-to-global ()
  "Effective tools should fall back to global when not locally set."
  (with-temp-buffer
    ;; Don't set local variable - should fall back to global
    (defvar ogent-tools-enabled)
    (let ((ogent-tools-enabled '(default-tool)))
      (should (equal (ogent-presets-effective-tools) '(default-tool))))))

(ert-deftest ogent-presets-effective-tools-respects-explicit-nil ()
  "Effective tools should respect explicit nil (disable all) when locally set."
  (with-temp-buffer
    ;; Explicitly set to nil - should return nil, not fall back
    (setq-local ogent-project-tools nil)
    (defvar ogent-tools-enabled)
    (let ((ogent-tools-enabled '(should-not-see-this)))
      (should (null (ogent-presets-effective-tools))))))

;;; Context Inclusion Tests

(ert-deftest ogent-presets-include-context-returns-nil-when-no-files ()
  "Include context should return nil when no files configured."
  (with-temp-buffer
    (setq-local ogent-project-context-files nil)
    (should (null (ogent-presets-include-context)))))

(ert-deftest ogent-presets-include-context-reads-configured-files ()
  "Include context should read and format configured files."
  (let ((temp-dir (make-temp-file "ogent-project" t))
        (readme-content "# Test Project\n\nThis is a test."))
    (unwind-protect
        (progn
          ;; Create a test file
          (with-temp-file (expand-file-name "README.md" temp-dir)
            (insert readme-content))
          (with-temp-buffer
            (let ((default-directory temp-dir))
              (setq-local ogent-project-context-files '("README.md"))
              ;; Mock project root
              (cl-letf (((symbol-function 'ogent-presets-project-root)
                         (lambda () temp-dir)))
                (let ((result (ogent-presets-include-context)))
                  (should (stringp result))
                  (should (string-match-p "README.md" result))
                  (should (string-match-p "Test Project" result)))))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-include-context-handles-missing-files ()
  "Include context should skip unreadable files."
  (let ((temp-dir (make-temp-file "ogent-project" t)))
    (unwind-protect
        (with-temp-buffer
          (let ((default-directory temp-dir))
            (setq-local ogent-project-context-files '("NONEXISTENT.md"))
            (cl-letf (((symbol-function 'ogent-presets-project-root)
                       (lambda () temp-dir)))
              ;; Should return nil since no files were readable
              (should (null (ogent-presets-include-context))))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-include-context-formats-multiple-files ()
  "Include context should format multiple files with separators."
  (let ((temp-dir (make-temp-file "ogent-project" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "FILE1.md" temp-dir)
            (insert "Content 1"))
          (with-temp-file (expand-file-name "FILE2.md" temp-dir)
            (insert "Content 2"))
          (with-temp-buffer
            (let ((default-directory temp-dir))
              (setq-local ogent-project-context-files '("FILE1.md" "FILE2.md"))
              (cl-letf (((symbol-function 'ogent-presets-project-root)
                         (lambda () temp-dir)))
                (let ((result (ogent-presets-include-context)))
                  (should (string-match-p "--- FILE1.md ---" result))
                  (should (string-match-p "--- FILE2.md ---" result))
                  (should (string-match-p "Content 1" result))
                  (should (string-match-p "Content 2" result)))))))
      (delete-directory temp-dir t))))

;;; Load and Reload Tests

(ert-deftest ogent-presets-load-tracks-loaded-projects ()
  "Load should track projects in loaded-projects hash."
  (let ((ogent-presets--loaded-projects (make-hash-table :test 'equal))
        (temp-dir (make-temp-file "ogent-project" t)))
    (unwind-protect
        (progn
          ;; Create a valid .ogent.el file
          (with-temp-file (expand-file-name ".ogent.el" temp-dir)
            (insert "((ogent-project-model . \"test\"))"))
          (with-temp-buffer
            (let ((default-directory temp-dir)
                  (ogent-presets-file-name ".ogent.el"))
              (cl-letf (((symbol-function 'ogent-presets-project-root)
                         (lambda (&optional _) temp-dir)))
                (ogent-presets-load)
                (should (gethash temp-dir ogent-presets--loaded-projects))))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-load-skips-already-loaded ()
  "Load should skip already loaded projects unless forced."
  (let ((ogent-presets--loaded-projects (make-hash-table :test 'equal))
        (load-count 0)
        (temp-dir (make-temp-file "ogent-project" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".ogent.el" temp-dir)
            (insert "((ogent-project-model . \"test\"))"))
          (with-temp-buffer
            (let ((default-directory temp-dir)
                  (ogent-presets-file-name ".ogent.el"))
              (cl-letf (((symbol-function 'ogent-presets-project-root)
                         (lambda (&optional _) temp-dir))
                        ((symbol-function 'ogent-presets--safe-read)
                         (lambda (_)
                           (cl-incf load-count)
                           '((ogent-project-model . "test")))))
                ;; First load
                (ogent-presets-load)
                (should (= 1 load-count))
                ;; Second load (should skip)
                (ogent-presets-load)
                (should (= 1 load-count))
                ;; Force reload
                (ogent-presets-load t)
                (should (= 2 load-count))))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets-load-handles-missing-preset-file ()
  "Load should handle missing .ogent.el gracefully."
  (let ((ogent-presets--loaded-projects (make-hash-table :test 'equal))
        (temp-dir (make-temp-file "ogent-project" t)))
    (unwind-protect
        (with-temp-buffer
          (let ((default-directory temp-dir)
                (ogent-presets-file-name ".ogent.el"))
            (cl-letf (((symbol-function 'ogent-presets-project-root)
                       (lambda (&optional _) temp-dir)))
              ;; Should not error when file doesn't exist
              (ogent-presets-load)
              (should (= 0 (hash-table-count ogent-presets--loaded-projects))))))
      (delete-directory temp-dir t))))

;;; Buffer Switch Hook Tests

(ert-deftest ogent-presets--on-buffer-switch-respects-auto-load-setting ()
  "Buffer switch hook should respect auto-load setting."
  (let ((ogent-presets-auto-load nil)
        (load-called nil))
    (cl-letf (((symbol-function 'ogent-presets-load)
               (lambda () (setq load-called t))))
      (with-temp-buffer
        (setq buffer-file-name "/fake/path.el")
        (ogent-presets--on-buffer-switch)
        (should-not load-called)))))

(ert-deftest ogent-presets--on-buffer-switch-skips-non-file-buffers ()
  "Buffer switch hook should skip buffers without files."
  (let ((ogent-presets-auto-load t)
        (load-called nil))
    (cl-letf (((symbol-function 'ogent-presets-load)
               (lambda () (setq load-called t))))
      (with-temp-buffer
        ;; No buffer-file-name
        (ogent-presets--on-buffer-switch)
        (should-not load-called)))))

(ert-deftest ogent-presets--on-buffer-switch-calls-load-for-files ()
  "Buffer switch hook should call load for file buffers."
  (let ((ogent-presets-auto-load t)
        (load-called nil))
    (cl-letf (((symbol-function 'ogent-presets-load)
               (lambda () (setq load-called t))))
      (with-temp-buffer
        (setq buffer-file-name "/fake/path.el")
        (ogent-presets--on-buffer-switch)
        (should load-called)))))

;;; Mode Tests

(ert-deftest ogent-presets-mode-adds-hook-when-enabled ()
  "Presets mode should add buffer-list-update-hook when enabled."
  (let ((original-hook buffer-list-update-hook))
    (unwind-protect
        (progn
          (ogent-presets-mode 1)
          (should (memq 'ogent-presets--on-buffer-switch buffer-list-update-hook)))
      (ogent-presets-mode -1)
      (setq buffer-list-update-hook original-hook))))

(ert-deftest ogent-presets-mode-removes-hook-when-disabled ()
  "Presets mode should remove hook when disabled."
  (let ((original-hook buffer-list-update-hook))
    (unwind-protect
        (progn
          (ogent-presets-mode 1)
          (ogent-presets-mode -1)
          (should-not (memq 'ogent-presets--on-buffer-switch buffer-list-update-hook)))
      (setq buffer-list-update-hook original-hook))))

;;; Register Prompts Tests

(ert-deftest ogent-presets--register-prompts-registers-project-prompts ()
  "Register prompts should register all project-specific prompts."
  (with-temp-buffer
    (setq-local ogent-project-prompts '(("review" . "Review code")
                                        ("explain" . "Explain this")))
    (let ((registered nil))
      (cl-letf (((symbol-function 'ogent-prompt-register)
                 (lambda (id &rest _)
                   (push id registered))))
        (ogent-presets--register-prompts)
        (should (member "review" registered))
        (should (member "explain" registered))))))

(ert-deftest ogent-presets--register-prompts-skips-when-no-prompts ()
  "Register prompts should do nothing when no project prompts."
  (with-temp-buffer
    (setq-local ogent-project-prompts nil)
    (let ((register-called nil))
      (cl-letf (((symbol-function 'ogent-prompt-register)
                 (lambda (&rest _) (setq register-called t))))
        (ogent-presets--register-prompts)
        (should-not register-called)))))

;;; Auto Pin Tests

(ert-deftest ogent-presets--auto-pin-files-pins-when-configured ()
  "Auto pin should pin files when auto-pin-docs is enabled."
  (let ((temp-dir (make-temp-file "ogent-project" t))
        (pinned-files nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "README.md" temp-dir)
            (insert "test"))
          (with-temp-buffer
            (let ((ogent-presets-auto-pin-docs t)
                  (default-directory temp-dir))
              (setq-local ogent-project-context-files '("README.md"))
              (cl-letf (((symbol-function 'ogent-presets-project-root)
                         (lambda () temp-dir))
                        ((symbol-function 'ogent-pin-file)
                         (lambda (path) (push path pinned-files))))
                (ogent-presets--auto-pin-files)
                (should (= 1 (length pinned-files)))))))
      (delete-directory temp-dir t))))

(ert-deftest ogent-presets--auto-pin-files-skips-when-disabled ()
  "Auto pin should skip when auto-pin-docs is disabled."
  (with-temp-buffer
    (let ((ogent-presets-auto-pin-docs nil)
          (pin-called nil))
      (setq-local ogent-project-context-files '("README.md"))
      (cl-letf (((symbol-function 'ogent-pin-file)
                 (lambda (_) (setq pin-called t))))
        (ogent-presets--auto-pin-files)
        (should-not pin-called)))))

(ert-deftest ogent-presets--auto-pin-files-skips-unreadable ()
  "Auto pin should skip files that aren't readable."
  (let ((temp-dir (make-temp-file "ogent-project" t))
        (pinned-files nil))
    (unwind-protect
        (with-temp-buffer
          (let ((ogent-presets-auto-pin-docs t)
                (default-directory temp-dir))
            (setq-local ogent-project-context-files '("NONEXISTENT.md"))
            (cl-letf (((symbol-function 'ogent-presets-project-root)
                       (lambda () temp-dir))
                      ((symbol-function 'ogent-pin-file)
                       (lambda (path) (push path pinned-files))))
              (ogent-presets--auto-pin-files)
              (should (= 0 (length pinned-files))))))
      (delete-directory temp-dir t))))

;;; Show Settings Tests

(ert-deftest ogent-presets-show-creates-help-buffer ()
  "Show should create a help buffer with settings info."
  (with-temp-buffer
    (setq-local ogent-project-model "test-model")
    (setq-local ogent-project-preset 'test-preset)
    (setq-local ogent-project-context-files '("a.md"))
    (cl-letf (((symbol-function 'ogent-presets-project-root)
               (lambda () "/test/root"))
              ((symbol-function 'file-exists-p)
               (lambda (_) nil)))
      (ogent-presets-show)
      (let ((help-buf (get-buffer "*Ogent Presets*")))
        (unwind-protect
            (progn
              (should help-buf)
              (with-current-buffer help-buf
                (should (string-match-p "test-model" (buffer-string)))
                (should (string-match-p "test-preset" (buffer-string)))
                (should (string-match-p "a.md" (buffer-string)))))
          (when help-buf
            (kill-buffer help-buf)))))))

;;; Allowed Variables Tests

(ert-deftest ogent-presets--allowed-variables-contains-expected ()
  "Allowed variables list should contain all expected variables."
  (should (memq 'ogent-project-model ogent-presets--allowed-variables))
  (should (memq 'ogent-project-preset ogent-presets--allowed-variables))
  (should (memq 'ogent-project-context-files ogent-presets--allowed-variables))
  (should (memq 'ogent-project-codemap-roots ogent-presets--allowed-variables))
  (should (memq 'ogent-project-prompts ogent-presets--allowed-variables))
  (should (memq 'ogent-project-tools ogent-presets--allowed-variables))
  (should (memq 'ogent-project-system-prompt ogent-presets--allowed-variables)))

(ert-deftest ogent-presets--allowed-variables-excludes-dangerous ()
  "Allowed variables list should not contain dangerous variables."
  (should-not (memq 'eval-expression ogent-presets--allowed-variables))
  (should-not (memq 'load-path ogent-presets--allowed-variables))
  (should-not (memq 'exec-path ogent-presets--allowed-variables)))

(provide 'ogent-presets-tests)
;;; ogent-presets-tests.el ends here
