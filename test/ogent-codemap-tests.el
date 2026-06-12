;;; ogent-codemap-tests.el --- Tests for ogent codemap -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-codemap)
(require 'ogent-codemap-task)
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

(ert-deftest ogent-codemap-definitions-regex ()
  "Definition regex captures ogent-* symbols only."
  (let ((test-file (make-temp-file "ogent-defs-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "(defun ogent-alpha () nil)\n")
            (insert "(defmacro ogent-beta () nil)\n")
            (insert "(defcustom ogent-gamma nil \"Doc\")\n")
            (insert "(defvar ogent-delta 1)\n")
            (insert "(defconst ogent-epsilon 2)\n")
            (insert "(defun not-ogent () nil)\n")
            (insert "(defun ogent-alpha () t)\n"))
          (should (equal (ogent-codemap--definitions test-file)
                         '("ogent-alpha" "ogent-beta" "ogent-gamma" "ogent-delta"))))
      (delete-file test-file))))

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

(ert-deftest ogent-codemap-heading-includes-mtime ()
  "File headings include modification time metadata."
  (let* ((root (ogent-codemap--project-root))
         (test-file (expand-file-name "test/data/ogent-codemap-mtime.el" root)))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "(defun ogent-codemap-mtime-test () nil)\n"))
          (with-temp-buffer
            (ogent-codemap--insert-file (current-buffer) test-file)
            (goto-char (point-min))
            (should (re-search-forward "mtime:" nil t))))
      (when (file-exists-p test-file)
        (delete-file test-file)))))

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

(ert-deftest ogent-codemap-test-definitions-regex ()
  "Test regex captures ert-deftest names and removes duplicates."
  (let ((test-file (make-temp-file "ogent-tests-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "(ert-deftest ogent-alpha-test () nil)\n")
            (insert "(ert-deftest other-test () nil)\n")
            (insert "(ert-deftest ogent-alpha-test () nil)\n"))
          (should (equal (ogent-codemap--test-definitions test-file)
                         '("ogent-alpha-test" "other-test"))))
      (delete-file test-file))))

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

(ert-deftest ogent-codemap-org-heading-levels ()
  "Org heading regex captures levels 1-3 only."
  (let ((org-file (make-temp-file "ogent-heading-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file org-file
            (insert "* One\n** Two\n*** Three\n**** Four\n"))
          (let ((headings (ogent-codemap--org-headings org-file)))
            (should (member '(1 . "One") headings))
            (should (member '(2 . "Two") headings))
            (should (member '(3 . "Three") headings))
            (should-not (cl-find "Four" headings :key #'cdr :test #'string=))))
      (delete-file org-file))))

(ert-deftest ogent-codemap-md-heading-levels ()
  "Markdown heading regex captures levels 1-3 only."
  (let ((md-file (make-temp-file "ogent-md-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file md-file
            (insert "# One\n## Two\n### Three\n#### Four\n"))
          (let ((headings (ogent-codemap--md-headings md-file)))
            (should (member '(1 . "One") headings))
            (should (member '(2 . "Two") headings))
            (should (member '(3 . "Three") headings))
            (should-not (cl-find "Four" headings :key #'cdr :test #'string=))))
      (delete-file md-file))))

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

(ert-deftest ogent-codemap-refresh-on-save-schedules ()
  "Saving a tracked file schedules a codemap refresh."
  (let ((ogent-codemap-refresh-on-save t)
        (ogent-codemap--last-file-snapshot (list (cons "dummy" (current-time))))
        (called nil)
        (buffer (get-buffer-create ogent-codemap-buffer-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-codemap--schedule-refresh)
                   (lambda () (setq called t))))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "* Codemap\n"))
          (with-temp-buffer
            (setq buffer-file-name (expand-file-name "lisp/ogent-core.el"
                                                     (ogent-codemap--project-root)))
            (ogent-codemap--maybe-refresh-after-save))
          (should called))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ogent-codemap-refresh-on-save-ignores-untracked ()
  "Saving an untracked file does not schedule refresh."
  (let ((ogent-codemap-refresh-on-save t)
        (ogent-codemap--last-file-snapshot (list (cons "dummy" (current-time))))
        (called nil)
        (buffer (get-buffer-create ogent-codemap-buffer-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-codemap--schedule-refresh)
                   (lambda () (setq called t))))
          (with-current-buffer buffer
            (erase-buffer)
            (insert "* Codemap\n"))
          (with-temp-buffer
            (setq buffer-file-name "/tmp/ogent-codemap-untracked.txt")
            (ogent-codemap--maybe-refresh-after-save))
          (should-not called))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

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

;;; Cache staleness tests

(ert-deftest ogent-codemap-cache-stale-missing-entry ()
  "Missing cache entry is considered stale."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (test-file (make-temp-file "ogent-stale-test")))
    (unwind-protect
        (should (ogent-codemap--cache-stale-p test-file))
      (delete-file test-file))))

(ert-deftest ogent-codemap-cache-stale-after-modification ()
  "Cache becomes stale after file modification."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (test-file (make-temp-file "ogent-mod-test")))
    (unwind-protect
        (progn
          ;; Cache with current mtime
          (ogent-codemap--cache-file test-file '("def1"))
          (should-not (ogent-codemap--cache-stale-p test-file))
          ;; Modify the file
          (sleep-for 0.1)
          (write-region "changed" nil test-file)
          (should (ogent-codemap--cache-stale-p test-file)))
      (delete-file test-file))))

;;; Task hash tests

(ert-deftest ogent-codemap-task-hash-deterministic ()
  "Same task string produces same hash."
  (should (string= (ogent-codemap--task-hash "my task")
                   (ogent-codemap--task-hash "my task"))))

(ert-deftest ogent-codemap-task-hash-case-insensitive ()
  "Task hash is case-insensitive."
  (should (string= (ogent-codemap--task-hash "My Task")
                   (ogent-codemap--task-hash "my task"))))

(ert-deftest ogent-codemap-task-hash-trims-whitespace ()
  "Task hash trims whitespace."
  (should (string= (ogent-codemap--task-hash "  my task  ")
                   (ogent-codemap--task-hash "my task"))))

(ert-deftest ogent-codemap-task-hash-different-tasks ()
  "Different tasks produce different hashes."
  (should-not (string= (ogent-codemap--task-hash "task alpha")
                        (ogent-codemap--task-hash "task beta"))))

;;; Files hash tests

(ert-deftest ogent-codemap-files-hash-returns-string ()
  "Files hash returns a non-empty string."
  (let ((hash (ogent-codemap--files-hash)))
    (should (stringp hash))
    (should (> (length hash) 0))))

(ert-deftest ogent-codemap-files-hash-deterministic ()
  "Files hash is deterministic for unchanged files."
  (should (string= (ogent-codemap--files-hash)
                   (ogent-codemap--files-hash))))

;;; Cache key tests

(ert-deftest ogent-codemap-cache-key-format ()
  "Cache key combines task hash and files hash prefix."
  (let ((key (ogent-codemap--cache-key "test task")))
    (should (stringp key))
    (should (string-match-p ":" key))
    ;; Should be task-hash:first-8-chars-of-files-hash
    (let ((parts (split-string key ":")))
      (should (= (length parts) 2))
      (should (= (length (nth 1 parts)) 8)))))

(ert-deftest ogent-codemap-cache-key-deterministic ()
  "Same task produces same cache key."
  (should (string= (ogent-codemap--cache-key "same task")
                   (ogent-codemap--cache-key "same task"))))

;;; Cache get/put tests

(ert-deftest ogent-codemap-cache-put-and-get ()
  "Cache put stores and get retrieves content."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600))
    (ogent-codemap--cache-put "test-key" "test content")
    (should (string= (ogent-codemap--cache-get "test-key") "test content"))))

(ert-deftest ogent-codemap-cache-get-missing ()
  "Cache get returns nil for missing key."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal)))
    (should-not (ogent-codemap--cache-get "nonexistent-key"))))

(ert-deftest ogent-codemap-cache-get-expired ()
  "Cache get returns nil for expired entries."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 1))
    ;; Put entry with timestamp in the past
    (puthash "expired-key"
             (list :content "old content" :timestamp (- (float-time) 100))
             ogent-codemap--task-cache)
    (should-not (ogent-codemap--cache-get "expired-key"))))

(ert-deftest ogent-codemap-cache-put-overwrites ()
  "Cache put overwrites existing entries."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600))
    (ogent-codemap--cache-put "key" "first")
    (ogent-codemap--cache-put "key" "second")
    (should (string= (ogent-codemap--cache-get "key") "second"))))

;;; Cache clearing tests

(ert-deftest ogent-codemap-clear-cache-empties-file-cache ()
  "Clear cache empties the file cache and snapshot."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (ogent-codemap--last-file-snapshot '(("file" . time))))
    (puthash "some-file" '(:mtime t :data ("def")) ogent-codemap--file-cache)
    (ogent-codemap-clear-cache)
    (should (= (hash-table-count ogent-codemap--file-cache) 0))
    (should-not ogent-codemap--last-file-snapshot)))

(ert-deftest ogent-codemap-clear-task-cache-empties ()
  "Clear task cache empties the task cache and handle registry."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap--task-handles (make-hash-table :test 'equal)))
    (puthash "key" '(:content "x" :timestamp 0) ogent-codemap--task-cache)
    (puthash "codemap-task:x" nil ogent-codemap--task-handles)
    (ogent-codemap-clear-task-cache)
    (should (= (hash-table-count ogent-codemap--task-cache) 0))
    (should (= (hash-table-count ogent-codemap--task-handles) 0))))

;;; Project root tests

(ert-deftest ogent-codemap-project-root-returns-string ()
  "Project root returns a non-nil string."
  (let ((root (ogent-codemap--project-root)))
    (should (stringp root))
    (should (> (length root) 0))))

(ert-deftest ogent-codemap-project-root-is-directory ()
  "Project root is an existing directory."
  (let ((root (ogent-codemap--project-root)))
    (should (file-directory-p root))))

;;; Get file mtime tests

(ert-deftest ogent-codemap-get-file-mtime-existing ()
  "Mtime is returned for existing files."
  (let ((test-file (make-temp-file "ogent-mtime-test")))
    (unwind-protect
        (let ((mtime (ogent-codemap--get-file-mtime test-file)))
          (should mtime)
          ;; mtime should be a time value (list of integers)
          (should (listp mtime)))
      (delete-file test-file))))

(ert-deftest ogent-codemap-get-file-mtime-nonexistent ()
  "Mtime is nil for non-existent files."
  (should-not (ogent-codemap--get-file-mtime "/no/such/file/ogent-test.el")))

;;; Snapshot files tests

(ert-deftest ogent-codemap-snapshot-files-returns-alist ()
  "Snapshot returns an alist of (file . mtime) pairs."
  (let ((snapshot (ogent-codemap--snapshot-files)))
    (should (listp snapshot))
    (should (> (length snapshot) 0))
    ;; Each entry is (file . mtime)
    (let ((entry (car snapshot)))
      (should (stringp (car entry)))
      (should (cdr entry)))))

;;; Insert file tests

(ert-deftest ogent-codemap-insert-file-elisp ()
  "Inserting an elisp file produces Org headings."
  (let ((test-file (make-temp-file "ogent-insert-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "(defun ogent-test-fn () nil)\n"))
          (with-temp-buffer
            (ogent-codemap--insert-file (current-buffer) test-file)
            (should (string-match-p "\\*\\*" (buffer-string)))
            (should (string-match-p "ogent-test-fn" (buffer-string)))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-insert-file-org ()
  "Inserting an org file produces nested headings."
  (let ((test-file (make-temp-file "ogent-insert-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "* Top Level\n** Sub Level\n"))
          (with-temp-buffer
            (ogent-codemap--insert-file (current-buffer) test-file)
            (should (string-match-p "Top Level" (buffer-string)))
            (should (string-match-p "Sub Level" (buffer-string)))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-insert-file-markdown ()
  "Inserting a markdown file produces headings."
  (let ((test-file (make-temp-file "ogent-insert-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "# Title\n## Section\n"))
          (with-temp-buffer
            (ogent-codemap--insert-file (current-buffer) test-file)
            (should (string-match-p "Title" (buffer-string)))
            (should (string-match-p "Section" (buffer-string)))))
      (delete-file test-file))))

;;; Parse sections tests

(ert-deftest ogent-codemap-parse-sections-returns-hash ()
  "Parse sections returns a hash table keyed by file path."
  (with-temp-buffer
    (insert "* Codemap\n")
    (insert "** [[file:lisp/foo.el][lisp/foo.el]]\n")
    (insert "mtime: 2025-01-01\n")
    (insert "*** [[file:lisp/foo.el::ogent-fn][ogent-fn]]\n")
    (insert "** [[file:test/bar.el][test/bar.el]]\n")
    (let ((sections (ogent-codemap--parse-sections)))
      (should (hash-table-p sections))
      (should (gethash "lisp/foo.el" sections))
      (should (gethash "test/bar.el" sections)))))

(ert-deftest ogent-codemap-parse-sections-correct-content ()
  "Parsed section content includes the full section text."
  (with-temp-buffer
    (insert "* Codemap\n")
    (insert "** [[file:lisp/a.el][lisp/a.el]]\nmtime: 2025-01-01\n# annotation\n")
    (insert "** [[file:lisp/b.el][lisp/b.el]]\n")
    (let* ((sections (ogent-codemap--parse-sections))
           (a-section (gethash "lisp/a.el" sections)))
      (should (string-match-p "annotation" a-section))
      (should (string-match-p "mtime:" a-section)))))

;;; Extract annotations tests

(ert-deftest ogent-codemap-extract-annotations-comments ()
  "Annotations are lines that are not standard codemap patterns."
  (let* ((section "** [[file:foo.el][foo.el]]\nmtime: 2025-01-01\n# my note\n*** [[file:foo.el::fn][fn]]\n")
         (annotations (ogent-codemap--extract-annotations section)))
    (should (member "# my note" annotations))
    ;; Standard patterns should not be included
    (should-not (cl-find-if (lambda (a) (string-match-p "mtime:" a)) annotations))
    (should-not (cl-find-if (lambda (a) (string-match-p "\\[\\[file:" a)) annotations))))

(ert-deftest ogent-codemap-extract-annotations-empty ()
  "No annotations returns empty list."
  (let* ((section "** [[file:foo.el][foo.el]]\nmtime: 2025-01-01\n*** [[file:foo.el::fn][fn]]\n")
         (annotations (ogent-codemap--extract-annotations section)))
    (should (null annotations))))

;;; As content tests

(ert-deftest ogent-codemap-as-content-returns-string ()
  "As content returns the codemap buffer as a string."
  (let ((content (ogent-codemap--as-content)))
    (should (stringp content))
    (should (string-match-p "Codemap" content))))

;;; Extract section tests

(ert-deftest ogent-codemap-extract-section-lisp ()
  "Extract section filters to a specific directory."
  (let ((content (concat "* Codemap\n"
                         "** [[file:lisp/core.el][lisp/core.el]]\n"
                         "*** [[file:lisp/core.el::fn][fn]]\n"
                         "** [[file:test/core-tests.el][test/core-tests.el]]\n"
                         "*** [[file:test/core-tests.el::test][test]]\n")))
    (let ((lisp-section (ogent-codemap--extract-section content "lisp")))
      (should (string-match-p "lisp/core.el" lisp-section))
      (should-not (string-match-p "test/core-tests.el" lisp-section)))))

(ert-deftest ogent-codemap-extract-section-not-found ()
  "Extract section returns message when section not found."
  (let ((content "* Codemap\n** [[file:lisp/a.el][lisp/a.el]]\n"))
    (let ((result (ogent-codemap--extract-section content "nonexistent")))
      (should (string-match-p "No nonexistent/ section found" result)))))

;;; File summary tests

(ert-deftest ogent-codemap-file-summary-elisp ()
  "File summary for elisp includes function names."
  (let ((test-file (make-temp-file "ogent-summary-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "(defun ogent-summary-fn () nil)\n"))
          (let ((ogent-codemap--file-cache (make-hash-table :test 'equal)))
            (let ((summary (ogent-codemap--file-summary test-file)))
              (should (stringp summary))
              (should (string-match-p "elisp" summary))
              (should (string-match-p "ogent-summary-fn" summary)))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-file-summary-test ()
  "File summary for test file includes test count."
  (let ((test-file (make-temp-file "ogent-summary-" nil "-tests.el")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "(ert-deftest test-a () nil)\n(ert-deftest test-b () nil)\n"))
          (let ((ogent-codemap--file-cache (make-hash-table :test 'equal)))
            (let ((summary (ogent-codemap--file-summary test-file)))
              (should (string-match-p "test" summary))
              (should (string-match-p "2 tests" summary)))))
      (delete-file test-file))))

;;; Codemap changes tests

(ert-deftest ogent-codemap-changes-returns-plist ()
  "Codemap changes returns a plist with change categories."
  (let ((ogent-codemap--last-file-snapshot nil))
    (let ((changes (ogent-codemap-changes)))
      (should (plist-get changes :added))
      (should (listp (plist-get changes :modified)))
      (should (listp (plist-get changes :removed))))))

;;; Task handle predicate tests

(ert-deftest ogent-codemap-task-handle-p-valid ()
  "Task handle predicate matches codemap-task: prefix."
  (should (ogent-codemap-task-handle-p "codemap-task:my question"))
  (should (ogent-codemap-task-handle-p "codemap-task:how does auth work")))

(ert-deftest ogent-codemap-task-handle-p-invalid ()
  "Task handle predicate rejects non-task handles."
  (should-not (ogent-codemap-task-handle-p "codemap"))
  (should-not (ogent-codemap-task-handle-p "codemap-lisp"))
  (should-not (ogent-codemap-task-handle-p "other-handle"))
  (should-not (ogent-codemap-task-handle-p "codemap-task")))

;;; Extract task from handle tests

(ert-deftest ogent-codemap-extract-task-basic ()
  "Task extraction gets description from handle."
  (should (string= (ogent-codemap--extract-task-from-handle "codemap-task:my question")
                   "my question")))

(ert-deftest ogent-codemap-extract-task-with-spaces ()
  "Task extraction preserves spaces and punctuation."
  (should (string= (ogent-codemap--extract-task-from-handle
                     "codemap-task:how does auth work?")
                   "how does auth work?")))

(ert-deftest ogent-codemap-extract-task-no-match ()
  "Task extraction returns nil for non-task handles."
  (should-not (ogent-codemap--extract-task-from-handle "codemap"))
  (should-not (ogent-codemap--extract-task-from-handle "other")))

(ert-deftest ogent-codemap-extract-task-empty-description ()
  "Task extraction with empty description after colon."
  ;; The regex requires at least one char after colon
  (should-not (ogent-codemap--extract-task-from-handle "codemap-task:")))

;;; Coverage Expansion Tests for ogent-codemap.el

(ert-deftest ogent-codemap-format-mtime-existing ()
  "Format mtime returns a date string for existing files."
  (let ((test-file (make-temp-file "ogent-fmt-mtime")))
    (unwind-protect
        (let ((mtime-str (ogent-codemap--format-mtime test-file)))
          (should (stringp mtime-str))
          (should (string-match-p "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" mtime-str)))
      (delete-file test-file))))

(ert-deftest ogent-codemap-format-mtime-nonexistent ()
  "Format mtime returns nil for non-existent files."
  (should-not (ogent-codemap--format-mtime "/no/such/file-ogent-test.el")))

(ert-deftest ogent-codemap-build-prompt-includes-task ()
  "Build prompt includes the task description."
  (cl-letf (((symbol-function 'ogent-codemap--all-file-summaries)
             (lambda () "- lisp/core.el (elisp): ogent-core-fn")))
    (let ((prompt (ogent-codemap--build-prompt "understand auth flow")))
      (should (string-match-p "understand auth flow" prompt))
      (should (string-match-p "lisp/core.el" prompt))
      (should (string-match-p "Project files:" prompt)))))

(ert-deftest ogent-codemap-generate-async-uses-cache ()
  "Generate async returns cached content immediately."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600)
        (callback-result nil))
    (cl-letf (((symbol-function 'ogent-codemap--cache-key)
               (lambda (_task) "test-cache-key")))
      ;; Pre-populate cache
      (ogent-codemap--cache-put "test-cache-key" "cached codemap content")
      (ogent-codemap--generate-async
       "some task"
       (lambda (content _error)
         (setq callback-result content)))
      (should (string= callback-result "cached codemap content")))))

(ert-deftest ogent-codemap-generate-async-pending-request ()
  "Generate async reports error for duplicate pending requests."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap--pending-requests (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600)
        (callback-error nil))
    (cl-letf (((symbol-function 'ogent-codemap--cache-key)
               (lambda (_task) "pending-key")))
      ;; Mark request as pending
      (puthash "pending-key" t ogent-codemap--pending-requests)
      (ogent-codemap--generate-async
       "some task"
       (lambda (_content error)
         (setq callback-error error)))
      (should (string-match-p "already pending" callback-error)))))


(ert-deftest ogent-codemap-generate-async-missing-gptel-stops ()
  "Generate async reports missing gptel without falling through to request."
  (let ((original-require (symbol-function 'require))
        (callback-error nil))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'gptel)
                     nil
                   (funcall original-require feature filename noerror))))
              ((symbol-function 'gptel-request)
               (lambda (&rest _)
                 (error "gptel-request should not be called"))))
      (ogent-codemap--generate-async
       "some task"
       (lambda (_content error)
         (setq callback-error error)))
      (should (string-match-p "gptel is required" callback-error)))))

(ert-deftest ogent-codemap-display-task-codemap-creates-buffer ()
  "Display task codemap creates org buffer with content."
  (let ((ogent-codemap--task-buffer-name "*ogent-codemap-test-task*"))
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer) #'ignore))
          (ogent-codemap--display-task-codemap
           "test task"
           "* Codemap: test task\n** Overview\nSome content\n")
          (let ((buf (get-buffer "*ogent-codemap-test-task*")))
            (should buf)
            (with-current-buffer buf
              (should (derived-mode-p 'org-mode))
              (should (string-match-p "Codemap: test task" (buffer-string)))
              (should (string= ogent-codemap--current-task "test task"))
              (should buffer-read-only))))
      (when-let ((buf (get-buffer "*ogent-codemap-test-task*")))
        (kill-buffer buf)))))

(ert-deftest ogent-codemap-resolve-task-handle-cached ()
  "Resolve task handle returns cached content when available."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600))
    (cl-letf (((symbol-function 'ogent-codemap--cache-key)
               (lambda (_task) "resolve-key")))
      (ogent-codemap--cache-put "resolve-key" "* Resolved content")
      (let ((content (ogent-codemap-resolve-task-handle "codemap-task:my question")))
        (should (string= content "* Resolved content"))))))

(ert-deftest ogent-codemap-resolve-task-handle-revalidates-resolved-registry ()
  "Resolved task handles still honor the TTL/files-hash aware cache."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap--task-handles (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600))
    (puthash "codemap-task:my question" "* Stale content"
             ogent-codemap--task-handles)
    (cl-letf (((symbol-function 'ogent-codemap--cache-key)
               (lambda (_task) "resolve-key")))
      (ogent-codemap--cache-put "resolve-key" "* Fresh content")
      (should (string= (ogent-codemap-resolve-task-handle
                        "codemap-task:my question")
                       "* Fresh content")))))
(ert-deftest ogent-codemap-resolve-task-handle-starts-generation-unresolved ()
  "Resolve task handle starts generation and returns nil until content exists."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap--task-handles (make-hash-table :test 'equal))
        (ogent-codemap--pending-requests (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600)
        (started nil))
    (cl-letf (((symbol-function 'ogent-codemap--generate-async)
               (lambda (_task _callback) (setq started t))))
      (should-not (ogent-codemap-resolve-task-handle "codemap-task:what is this"))
      (should started)
      (should (eq (gethash "codemap-task:what is this" ogent-codemap--task-handles :missing)
                  nil)))))

(ert-deftest ogent-codemap-resolve-task-handle-rejects-non-task ()
  "Resolve task handle returns nil for non-task handles."
  (should-not (ogent-codemap-resolve-task-handle "codemap"))
  (should-not (ogent-codemap-resolve-task-handle "other-handle")))

(ert-deftest ogent-codemap-resolve-handle-enhanced-routes-task ()
  "Enhanced handle resolution routes task handles correctly."
  (let ((ogent-codemap--task-cache (make-hash-table :test 'equal))
        (ogent-codemap-cache-ttl 3600))
    (cl-letf (((symbol-function 'ogent-codemap--cache-key)
               (lambda (_task) "enhanced-key")))
      (ogent-codemap--cache-put "enhanced-key" "task content")
      (let ((content (ogent-codemap-resolve-handle-enhanced "codemap-task:test")))
        (should (string= content "task content"))))))

(ert-deftest ogent-codemap-resolve-handle-enhanced-routes-static ()
  "Enhanced handle resolution routes static handles correctly."
  (cl-letf (((symbol-function 'ogent-codemap-resolve-handle)
             (lambda (_handle) "static codemap content")))
    (let ((content (ogent-codemap-resolve-handle-enhanced "codemap")))
      (should (string= content "static codemap content")))))

(ert-deftest ogent-codemap-resolve-handle-enhanced-returns-nil ()
  "Enhanced handle resolution returns nil for unknown handles."
  (should-not (ogent-codemap-resolve-handle-enhanced "unknown-handle")))

(ert-deftest ogent-codemap-file-summary-org ()
  "File summary for org file shows org doc type."
  (let ((test-file (make-temp-file "ogent-summary-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "* Heading\n"))
          (let ((summary (ogent-codemap--file-summary test-file)))
            (should (string-match-p "org doc" summary))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-file-summary-markdown ()
  "File summary for markdown file shows markdown doc type."
  (let ((test-file (make-temp-file "ogent-summary-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "# Heading\n"))
          (let ((summary (ogent-codemap--file-summary test-file)))
            (should (string-match-p "markdown doc" summary))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-file-summary-elisp-no-defs ()
  "File summary for elisp with no ogent defs shows 'no ogent- functions'."
  (let ((test-file (make-temp-file "ogent-no-defs-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "(defun other-fn () nil)\n"))
          (let ((ogent-codemap--file-cache (make-hash-table :test 'equal)))
            (let ((summary (ogent-codemap--file-summary test-file)))
              (should (string-match-p "no ogent- functions" summary)))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-all-file-summaries-returns-string ()
  "All file summaries returns non-empty string."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal)))
    (let ((summaries (ogent-codemap--all-file-summaries)))
      (should (stringp summaries))
      (should (> (length summaries) 0)))))

(ert-deftest ogent-codemap-get-cached-returns-data ()
  "Get cached returns data for fresh cache entries."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal))
        (test-file (make-temp-file "ogent-get-cached")))
    (unwind-protect
        (progn
          (ogent-codemap--cache-file test-file '("def1" "def2"))
          (let ((data (ogent-codemap--get-cached test-file)))
            (should (equal data '("def1" "def2")))))
      (delete-file test-file))))

(ert-deftest ogent-codemap-get-cached-returns-nil-stale ()
  "Get cached returns nil for stale entries."
  (let ((ogent-codemap--file-cache (make-hash-table :test 'equal)))
    ;; Non-existent file in cache
    (should-not (ogent-codemap--get-cached "/nonexistent/ogent-test.el"))))

(ert-deftest ogent-codemap-codemap-handle-rejects-task-prefix ()
  "Codemap handle-p correctly rejects codemap-task: handles."
  (should-not (ogent-codemap-handle-p "codemap-task:something")))

(provide 'ogent-codemap-tests)
;;; ogent-codemap-tests.el ends here
