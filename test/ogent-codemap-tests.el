;;; ogent-codemap-tests.el --- Tests for ogent codemap -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-codemap)
(require 'cl-lib)

(ert-deftest ogent-codemap-finds-context-file ()
  "The codemap scans known source files."
  (let ((files (ogent-codemap--source-files)))
    (should (cl-some (lambda (file)
                       (string-match-p "ogent-context\\.el$" file))
                     files))))

(ert-deftest ogent-codemap-extracts-definitions ()
  "Definitions are extracted with correct names."
  (let* ((ctx-file (cl-find-if (lambda (file)
                                 (string-match-p "ogent-context\\.el$" file))
                               (ogent-codemap--source-files)))
         (defs (ogent-codemap--definitions ctx-file)))
    (should (member "ogent-context-build" defs))
    (should (member "ogent-resolve-handle" defs))))

(ert-deftest ogent-codemap-buffer-renders-org ()
  "Rendering produces an Org buffer with expected headings."
  (let ((buf (ogent-codemap-refresh)))
    (unwind-protect
        (with-current-buffer buf
          (should (derived-mode-p 'org-mode))
          (goto-char (point-min))
          (should (looking-at "\\* Codemap")))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-detects-file-types ()
  "File type detection works for all supported types."
  (should (eq (ogent-codemap--file-type "lisp/ogent-core.el") 'elisp))
  (should (eq (ogent-codemap--file-type "test/ogent-core-tests.el") 'elisp-test))
  (should (eq (ogent-codemap--file-type "test/ogent-test.el") 'elisp-test))
  (should (eq (ogent-codemap--file-type "specs/architecture.org") 'org))
  (should (eq (ogent-codemap--file-type "docs/guide.md") 'markdown))
  (should-not (ogent-codemap--file-type "README.txt")))

(ert-deftest ogent-codemap-extracts-test-definitions ()
  "Test definitions are extracted from test files."
  (let* ((test-file (cl-find-if (lambda (file)
                                  (string-match-p "ogent-core-tests\\.el$" file))
                                (ogent-codemap--source-files)))
         (tests (ogent-codemap--test-definitions test-file)))
    (should test-file)
    (should (cl-some (lambda (name) (string-match-p "^ogent-" name)) tests))))

(ert-deftest ogent-codemap-extracts-org-headings ()
  "Org headings are extracted from .org files."
  (let* ((org-file (cl-find-if (lambda (file)
                                 (string-match-p "architecture\\.org$" file))
                               (ogent-codemap--source-files)))
         (headings (ogent-codemap--org-headings org-file)))
    (should org-file)
    (should (> (length headings) 0))
    ;; Each heading is (level . text)
    (should (numberp (caar headings)))
    (should (stringp (cdar headings)))))

(ert-deftest ogent-codemap-scans-all-directories ()
  "Source files include test, specs, and docs directories."
  (let ((files (ogent-codemap--source-files)))
    ;; Should have files from each configured directory
    (should (cl-some (lambda (f) (string-match-p "/lisp/" f)) files))
    (should (cl-some (lambda (f) (string-match-p "/test/" f)) files))
    (should (cl-some (lambda (f) (string-match-p "/specs/" f)) files))
    (should (cl-some (lambda (f) (string-match-p "/docs/" f)) files))))

(ert-deftest ogent-codemap-handle-detection ()
  "Codemap handles are correctly identified."
  (should (ogent-codemap-handle-p "codemap"))
  (should (ogent-codemap-handle-p "codemap-lisp"))
  (should (ogent-codemap-handle-p "codemap-test"))
  (should-not (ogent-codemap-handle-p "codemaps"))
  (should-not (ogent-codemap-handle-p "my-codemap"))
  (should-not (ogent-codemap-handle-p "foo")))

(ert-deftest ogent-codemap-handle-resolves ()
  "Codemap handle returns content."
  (let ((content (ogent-codemap-resolve-handle "codemap")))
    (should content)
    (should (stringp content))
    (should (string-match-p "\\* Codemap" content))))

(ert-deftest ogent-codemap-section-handle-resolves ()
  "Codemap section handle returns filtered content."
  (let ((content (ogent-codemap-resolve-handle "codemap-lisp")))
    (should content)
    (should (stringp content))
    (should (string-match-p "lisp/" content))
    ;; Should not contain test/ files
    (should-not (string-match-p "^\\*\\* .*test/" content))))

;;; Caching Tests

(ert-deftest ogent-codemap-cache-stores-mtime ()
  "File cache stores modification times."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (test-file (make-temp-file "ogent-cache-test")))
    (unwind-protect
        (progn
          (ogent-codemap--cache-file test-file '("def1" "def2"))
          (let ((entry (gethash test-file ogent-codemap--file-cache)))
            (should entry)
            (should (plist-get entry :mtime))
            (should (equal (plist-get entry :data) '("def1" "def2")))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-cache-detects-stale ()
  "Cache correctly identifies stale entries."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          ;; Cache with old mtime
          (puthash test-file
                   (list :mtime (time-subtract (current-time) (seconds-to-time 10))
                         :data '("old-def"))
                   ogent-codemap--file-cache)
          ;; Touch file to update mtime
          (write-region "new content" nil test-file)
          (should (ogent-codemap--cache-stale-p test-file)))
      (delete-file test-file))))

(ert-deftest ogent-codemap-cache-fresh-not-stale ()
  "Fresh cache entries are not marked stale."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          ;; Cache with current mtime
          (puthash test-file
                   (list :mtime (file-attribute-modification-time
                                 (file-attributes test-file))
                         :data '("def"))
                   ogent-codemap--file-cache)
          (should-not (ogent-codemap--cache-stale-p test-file)))
      (delete-file test-file))))

;;; Incremental Refresh Tests

(ert-deftest ogent-codemap-preserves-annotations ()
  "Manual annotations in codemap are preserved on refresh."
  (let ((buf (get-buffer-create "*ogent-codemap-test*"))
        (ogent-codemap-buffer-name "*ogent-codemap-test*"))
    (unwind-protect
        (progn
          ;; Initial render
          (ogent-codemap-refresh)
          (with-current-buffer buf
            ;; Add a manual annotation after a file heading
            (goto-char (point-min))
            (when (re-search-forward "^\\*\\* \\[\\[file:lisp/ogent-core\\.el" nil t)
              (end-of-line)
              (insert "\n# MY ANNOTATION: important note")))
          ;; Refresh again
          (ogent-codemap-refresh)
          ;; Annotation should still be there
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "MY ANNOTATION: important note" nil t))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-incremental-updates-changed ()
  "Incremental refresh updates only changed files."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (scanned-files nil))
    ;; Advice to track which files get scanned
    (cl-letf (((symbol-function 'ogent-codemap--definitions)
               (lambda (file)
                 (push file scanned-files)
                 '("mock-def"))))
      ;; First render - should scan all
      (let ((files (ogent-codemap--source-files)))
        (dolist (f files)
          (when (eq (ogent-codemap--file-type f) 'elisp)
            (ogent-codemap--get-cached-or-scan f 'elisp))))
      ;; Verify we scanned some files
      (should (> (length scanned-files) 0))
      (setq scanned-files nil)
      ;; Second pass - nothing changed, should scan none
      (let ((files (ogent-codemap--source-files)))
        (dolist (f files)
          (when (eq (ogent-codemap--file-type f) 'elisp)
            (ogent-codemap--get-cached-or-scan f 'elisp))))
      (should (= 0 (length scanned-files))))))

;;; Cross-linking Tests

(ert-deftest ogent-codemap-finds-test-file ()
  "Source files are linked to their test files."
  (should (string-match-p "ogent-core-tests\\.el"
                          (ogent-codemap--find-test-file "lisp/ogent-core.el")))
  (should (string-match-p "ogent-context-tests\\.el"
                          (ogent-codemap--find-test-file "lisp/ogent-context.el")))
  ;; No test file for non-existent module
  (should-not (ogent-codemap--find-test-file "lisp/ogent-nonexistent.el")))

(ert-deftest ogent-codemap-finds-source-for-test ()
  "Test files are linked back to their source files."
  (should (string-match-p "ogent-core\\.el"
                          (ogent-codemap--find-source-file "test/ogent-core-tests.el")))
  ;; UI subdir tests
  (should (string-match-p "ogent-ui\\.el"
                          (ogent-codemap--find-source-file "test/ui/ogent-ui-tests.el"))))

(ert-deftest ogent-codemap-renders-test-links ()
  "Rendered codemap includes test file links for source files."
  (let ((buf (ogent-codemap-refresh)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          ;; Find ogent-core.el entry
          (when (re-search-forward "^\\*\\* \\[\\[file:lisp/ogent-core\\.el" nil t)
            (let ((section-end (save-excursion
                                 (if (re-search-forward "^\\*\\* " nil t)
                                     (point)
                                   (point-max)))))
              ;; Should have a Tests: link within this section
              (should (re-search-forward "Tests:" section-end t)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;;; Incremental Refresh Tests

(ert-deftest ogent-codemap-detect-changes-no-snapshot ()
  "All files are reported as added when no snapshot exists."
  (let ((ogent-codemap--last-file-snapshot nil))
    (let ((changes (ogent-codemap--detect-changes)))
      (should (> (length (plist-get changes :added)) 0))
      (should (null (plist-get changes :modified)))
      (should (null (plist-get changes :removed))))))

(ert-deftest ogent-codemap-detect-changes-with-snapshot ()
  "Change detection correctly categorizes files."
  (let* ((files (ogent-codemap--source-files))
         ;; Create snapshot with current files but old mtimes
         (ogent-codemap--last-file-snapshot
          (mapcar (lambda (f)
                    (cons f (time-subtract (current-time)
                                           (seconds-to-time 3600))))
                  files)))
    (let ((changes (ogent-codemap--detect-changes)))
      ;; All files should be marked as modified (mtime mismatch)
      (should (> (length (plist-get changes :modified)) 0))
      ;; Nothing should be added (same file set)
      (should (null (plist-get changes :added))))))

(ert-deftest ogent-codemap-detect-changes-removed ()
  "Removed files are detected correctly."
  (let ((ogent-codemap--last-file-snapshot
         (list (cons "/nonexistent/removed-file.el"
                     (current-time)))))
    (let ((changes (ogent-codemap--detect-changes)))
      (should (member "/nonexistent/removed-file.el"
                      (plist-get changes :removed))))))

(ert-deftest ogent-codemap-section-bounds ()
  "Section bounds are correctly identified."
  (let ((buf (ogent-codemap-refresh)))
    (unwind-protect
        (let ((bounds (ogent-codemap--section-bounds buf "lisp/ogent-core.el")))
          (should bounds)
          (should (< (car bounds) (cdr bounds)))
          ;; Should contain the file link
          (with-current-buffer buf
            (should (string-match-p "ogent-core\\.el"
                                    (buffer-substring (car bounds) (cdr bounds))))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-remove-section ()
  "Sections can be removed from the buffer."
  (let ((buf (ogent-codemap-refresh)))
    (unwind-protect
        (progn
          ;; Verify section exists
          (should (ogent-codemap--section-bounds buf "lisp/ogent-core.el"))
          ;; Remove it
          (should (ogent-codemap--remove-section buf "lisp/ogent-core.el"))
          ;; Verify it's gone
          (should-not (ogent-codemap--section-bounds buf "lisp/ogent-core.el")))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-update-section ()
  "Sections can be updated in place."
  (let* ((ogent-codemap-buffer-name "*ogent-codemap-test-update*")
         (buf (ogent-codemap-refresh))
         (core-file (cl-find-if (lambda (f)
                                  (string-match-p "ogent-core\\.el$" f))
                                (ogent-codemap--source-files))))
    (unwind-protect
        (progn
          ;; Add annotation to section
          (with-current-buffer buf
            (goto-char (point-min))
            (when (re-search-forward "^\\*\\* \\[\\[file:lisp/ogent-core\\.el" nil t)
              (end-of-line)
              (insert "\n# TEST ANNOTATION")))
          ;; Update section
          (ogent-codemap--update-section buf core-file)
          ;; Annotation should be preserved
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "TEST ANNOTATION" nil t))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-incremental-vs-full ()
  "Incremental render produces same result as full render."
  (let ((ogent-codemap-buffer-name "*ogent-codemap-test-inc*")
        (ogent-codemap--last-file-snapshot nil)
        (ogent-codemap--file-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          ;; Do initial full render
          (let ((full-buf (ogent-codemap--render-full)))
            (with-current-buffer full-buf
              (let ((full-content (buffer-string)))
                ;; Now do incremental (should be no-op since snapshot matches)
                (let ((inc-buf (ogent-codemap--render-incremental)))
                  (should inc-buf)
                  ;; Content should be identical
                  (with-current-buffer inc-buf
                    (should (string= full-content (buffer-string)))))))))
      (when-let ((buf (get-buffer "*ogent-codemap-test-inc*")))
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-snapshot-updates ()
  "Snapshot is updated after refresh."
  (let ((ogent-codemap-buffer-name "*ogent-codemap-test-snap*")
        (ogent-codemap--last-file-snapshot nil))
    (unwind-protect
        (progn
          (should-not ogent-codemap--last-file-snapshot)
          (ogent-codemap--render-full)
          (should ogent-codemap--last-file-snapshot)
          (should (> (length ogent-codemap--last-file-snapshot) 0)))
      (when-let ((buf (get-buffer "*ogent-codemap-test-snap*")))
        (kill-buffer buf))
      (setq ogent-codemap--last-file-snapshot nil))))

(provide 'ogent-codemap-tests)
;;; ogent-codemap-tests.el ends here
