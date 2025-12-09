;;; ogent-edit-tests.el --- Tests for inline edit modules -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)
(require 'ogent-edit-display)
(require 'ogent-edit-log)
(require 'ogent-edit)
(require 'smerge-mode)

;;; Format Tests

(ert-deftest ogent-edit-format-constants-defined ()
  "Edit format constants are properly defined."
  (should (stringp ogent-edit-search-marker))
  (should (stringp ogent-edit-separator))
  (should (stringp ogent-edit-replace-marker))
  (should (string-match-p "SEARCH" ogent-edit-search-marker))
  (should (string-match-p "REPLACE" ogent-edit-replace-marker)))

(ert-deftest ogent-edit-mode-to-language ()
  "Mode names convert to language identifiers correctly."
  (should (string= (ogent-edit--mode-to-language "emacs-lisp-mode") "elisp"))
  (should (string= (ogent-edit--mode-to-language "python-mode") "python"))
  (should (string= (ogent-edit--mode-to-language "javascript-mode") "javascript"))
  (should (string= (ogent-edit--mode-to-language "rust-mode") "rust"))
  (should (string= (ogent-edit--mode-to-language "unknown-mode") "")))

(ert-deftest ogent-edit-wrap-prompt ()
  "Edit prompts are wrapped correctly with context."
  (let ((wrapped (ogent-edit-wrap-prompt
                  "Fix the bug"
                  "test.el"
                  "emacs-lisp-mode"
                  "(defun foo () nil)")))
    (should (string-match-p "test.el" wrapped))
    (should (string-match-p "emacs-lisp-mode" wrapped))
    (should (string-match-p "Fix the bug" wrapped))
    (should (string-match-p "defun foo" wrapped))
    (should (string-match-p "SEARCH/REPLACE" wrapped))))

(ert-deftest ogent-edit-id-generation ()
  "Edit IDs are generated sequentially."
  (ogent-edit--reset-counter)
  (should (string= (ogent-edit--generate-id) "ogent-edit-001"))
  (should (string= (ogent-edit--generate-id) "ogent-edit-002"))
  (should (string= (ogent-edit--generate-id) "ogent-edit-003"))
  (ogent-edit--reset-counter)
  (should (string= (ogent-edit--generate-id) "ogent-edit-001")))

;;; Parser Tests

(ert-deftest ogent-edit-parse-single-block ()
  "Parse a single SEARCH/REPLACE block."
  (let* ((response "Here's the fix:

<<<<<<< SEARCH
(defun foo ()
  nil)
=======
(defun foo ()
  t)
>>>>>>> REPLACE

This changes the return value.")
         (source-buffer (get-buffer-create "*test-source*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 1))
          (let ((edit (car edits)))
            (should (string= (ogent-edit-old-text edit) "(defun foo ()\n  nil)"))
            (should (string= (ogent-edit-new-text edit) "(defun foo ()\n  t)"))
            (should (eq (ogent-edit-status edit) 'pending))
            (should (ogent-edit-id edit))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse-multiple-blocks ()
  "Parse multiple SEARCH/REPLACE blocks."
  (let* ((response "Making two changes:

<<<<<<< SEARCH
(setq x 1)
=======
(setq x 10)
>>>>>>> REPLACE

And also:

<<<<<<< SEARCH
(setq y 2)
=======
(setq y 20)
>>>>>>> REPLACE
")
         (source-buffer (get-buffer-create "*test-source*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (progn
          (should (= (length edits) 2))
          (should (string= (ogent-edit-old-text (nth 0 edits)) "(setq x 1)"))
          (should (string= (ogent-edit-new-text (nth 0 edits)) "(setq x 10)"))
          (should (string= (ogent-edit-old-text (nth 1 edits)) "(setq y 2)"))
          (should (string= (ogent-edit-new-text (nth 1 edits)) "(setq y 20)")))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse-no-blocks ()
  "Parse response with no edit blocks."
  (let* ((response "I can't make that change because...")
         (source-buffer (get-buffer-create "*test-source*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (should (= (length edits) 0))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-parse-malformed-block ()
  "Malformed blocks are skipped."
  (let* ((response "<<<<<<< SEARCH
old code
missing separator and end marker")
         (source-buffer (get-buffer-create "*test-source*"))
         (edits (ogent-edit-parse-response response source-buffer)))
    (unwind-protect
        (should (= (length edits) 0))
      (kill-buffer source-buffer))))

;;; Validation Tests

(ert-deftest ogent-edit-validate-found-once ()
  "Validation succeeds when old text is found exactly once."
  (let ((source-buffer (get-buffer-create "*test-validate*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(defun foo () nil)\n(defun bar () t)"))
          (let ((edit (make-ogent-edit
                       :id "test-001"
                       :old-text "(defun foo () nil)"
                       :new-text "(defun foo () t)"
                       :source-buffer source-buffer
                       :status 'pending)))
            (ogent-edit-validate edit)
            (should (ogent-edit-start-pos edit))
            (should (ogent-edit-end-pos edit))
            (should (= (ogent-edit-start-pos edit) 1))
            (should-not (ogent-edit-error-p edit))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-validate-not-found ()
  "Validation fails when old text is not found."
  (let ((source-buffer (get-buffer-create "*test-validate*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(defun bar () t)"))
          (let ((edit (make-ogent-edit
                       :id "test-001"
                       :old-text "(defun foo () nil)"
                       :new-text "(defun foo () t)"
                       :source-buffer source-buffer
                       :status 'pending)))
            (ogent-edit-validate edit)
            (should (ogent-edit-error-p edit))
            (should (string-match-p "not found" (ogent-edit-error-message edit)))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-validate-multiple-matches ()
  "Validation fails when old text matches multiple times."
  (let ((source-buffer (get-buffer-create "*test-validate*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(setq x 1)\n(setq x 1)"))
          (let ((edit (make-ogent-edit
                       :id "test-001"
                       :old-text "(setq x 1)"
                       :new-text "(setq x 2)"
                       :source-buffer source-buffer
                       :status 'pending)))
            (ogent-edit-validate edit)
            (should (ogent-edit-error-p edit))
            (should (string-match-p "2 locations" (ogent-edit-error-message edit)))))
      (kill-buffer source-buffer))))

;;; Display Tests

(ert-deftest ogent-edit-format-conflict ()
  "Conflict markers are formatted correctly."
  (let ((conflict (ogent-edit--format-conflict "old code" "new code")))
    (should (string-match-p "<<<<<<< original" conflict))
    (should (string-match-p "old code" conflict))
    (should (string-match-p "=======" conflict))
    (should (string-match-p "new code" conflict))
    (should (string-match-p ">>>>>>> ogent" conflict))))

(ert-deftest ogent-edit-apply-as-smerge ()
  "Edit is applied as smerge conflict markers."
  (let ((source-buffer (get-buffer-create "*test-smerge*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (emacs-lisp-mode)
            (insert "(defun foo () nil)"))
          (let ((edit (make-ogent-edit
                       :id "test-001"
                       :old-text "(defun foo () nil)"
                       :new-text "(defun foo () t)"
                       :source-buffer source-buffer
                       :start-pos 1
                       :end-pos 19
                       :status 'pending)))
            (ogent-edit-apply-as-smerge edit)
            (with-current-buffer source-buffer
              (should (string-match-p "<<<<<<< original"
                                      (buffer-string)))
              (should (string-match-p ">>>>>>> ogent"
                                      (buffer-string)))
              (should (bound-and-true-p smerge-mode)))))
      (kill-buffer source-buffer))))

;;; Logging Tests

(ert-deftest ogent-edit-format-log-entry ()
  "Log entries are formatted correctly."
  (let ((edit (make-ogent-edit
               :id "test-001"
               :old-text "old"
               :new-text "new"
               :source-file "/test/file.el"
               :status 'pending
               :timestamp (current-time))))
    (let ((entry (ogent-edit--format-log-entry edit)))
      (should (string-match-p "\\*\\* Edit: test-001" entry))
      (should (string-match-p ":OGENT_EDIT_ID: test-001" entry))
      (should (string-match-p ":SOURCE_FILE: /test/file.el" entry))
      (should (string-match-p ":STATUS: pending" entry))
      (should (string-match-p "\\*\\*\\* Proposed Change" entry))
      (should (string-match-p "#\\+begin_src diff" entry)))))

(ert-deftest ogent-edit-format-diff ()
  "Diff output is formatted correctly."
  (let ((diff (ogent-edit--format-diff "old line" "new line")))
    (should (string-match-p "#\\+begin_src diff" diff))
    (should (string-match-p "^- old line" diff))
    (should (string-match-p "^\\+ new line" diff))
    (should (string-match-p "#\\+end_src" diff))))

;;; Integration Tests

(ert-deftest ogent-edit-full-flow ()
  "Test full edit flow: parse, validate, display."
  (let* ((response "<<<<<<< SEARCH
(defun test-fn ()
  \"Original.\")
=======
(defun test-fn ()
  \"Modified.\")
>>>>>>> REPLACE")
         (source-buffer (get-buffer-create "*test-flow*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (emacs-lisp-mode)
            (insert "(defun test-fn ()\n  \"Original.\")"))
          (let ((edits (ogent-edit-parse-response response source-buffer)))
            ;; Parse
            (should (= (length edits) 1))
            ;; Validate
            (setq edits (ogent-edit-validate-all edits))
            (should (ogent-edit-valid-p (car edits)))
            ;; Display
            (ogent-edit-apply-all-as-smerge edits)
            (with-current-buffer source-buffer
              (should (string-match-p "<<<<<<< original" (buffer-string)))
              (should (string-match-p "Modified" (buffer-string))))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-request-returns-prompt ()
  "ogent-request-edit returns properly formatted prompt."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "(defun foo () nil)"))
          (with-current-buffer (find-file-noselect temp-file)
            (emacs-lisp-mode)
            (let ((result (ogent-request-edit "Fix this")))
              (should (plist-get result :prompt))
              (should (plist-get result :system))
              (should (plist-get result :callback))
              (should (string-match-p "Fix this" (plist-get result :prompt)))
              (should (string-match-p "SEARCH/REPLACE"
                                      (plist-get result :system))))
            (kill-buffer)))
      (delete-file temp-file))))

(provide 'ogent-edit-tests)
;;; ogent-edit-tests.el ends here
