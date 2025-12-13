;;; ogent-edit-display-tests.el --- Tests for ogent-edit-display -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for smerge-based edit display and diff preview functionality.

;;; Code:

(require 'ert)
(require 'ogent-edit-display)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)

;;; Test Helpers

(defun ogent-edit-display-test--make-edit (old new)
  "Create a test edit struct with OLD and NEW text."
  (let ((buf (generate-new-buffer " *ogent-test*")))
    (with-current-buffer buf
      (insert old))
    (let ((edit (make-ogent-edit
                 :id "test-edit-001"
                 :old-text old
                 :new-text new
                 :source-buffer buf
                 :source-file "test.el"
                 :status 'pending
                 :timestamp (current-time))))
      ;; Validate to set positions
      (ogent-edit-validate edit)
      edit)))

(defun ogent-edit-display-test--cleanup-buffers ()
  "Kill test buffers."
  (dolist (buf (buffer-list))
    (when (string-prefix-p " *ogent-test" (buffer-name buf))
      (kill-buffer buf)))
  (when (get-buffer "*ogent-diff*")
    (kill-buffer "*ogent-diff*")))

;;; Diff Generation Tests

(ert-deftest ogent-edit-display-test-generate-unified-diff ()
  "Test unified diff generation produces valid format."
  (let* ((old-text "function foo() {\n  return 1;\n}")
         (new-text "function foo() {\n  return 2;\n}")
         (diff (ogent-edit--generate-unified-diff "test.js" old-text new-text)))
    (should (string-match-p "^--- a/test.js" diff))
    (should (string-match-p "^\\+\\+\\+ b/test.js" diff))
    (should (string-match-p "^@@" diff))
    (should (string-match-p "^-function foo()" diff))
    (should (string-match-p "^\\+function foo()" diff))
    (should (string-match-p "^-  return 1;" diff))
    (should (string-match-p "^\\+  return 2;" diff))))

(ert-deftest ogent-edit-display-test-diff-has-proper-line-counts ()
  "Test diff hunk header has correct line counts."
  (let* ((old-text "line1\nline2\nline3")
         (new-text "line1\nmodified\nline3")
         (diff (ogent-edit--generate-unified-diff "test.txt" old-text new-text)))
    ;; Should have 3 old lines and 3 new lines
    (should (string-match-p "@@ -1,3 \\+1,3 @@" diff))))

;;; Preview Buffer Tests

(ert-deftest ogent-edit-display-test-preview-diff-creates-buffer ()
  "Test preview diff creates buffer with correct content."
  (unwind-protect
      (let* ((old-text "old code")
             (new-text "new code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (preview-buf (ogent-edit-preview-diff edit)))
        (should (buffer-live-p preview-buf))
        (should (equal (buffer-name preview-buf) "*ogent-diff*"))
        (with-current-buffer preview-buf
          (should (bound-and-true-p ogent-edit-preview-mode))
          (should (eq major-mode 'diff-mode))
          (should (eq ogent-edit-preview--current-edit edit))
          (let ((content (buffer-string)))
            (should (string-match-p "^--- a/test.el" content))
            (should (string-match-p "^-old code" content))
            (should (string-match-p "^\\+new code" content)))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-preview-buffer-is-read-only ()
  "Test preview buffer is read-only."
  (unwind-protect
      (let* ((edit (ogent-edit-display-test--make-edit "old" "new"))
             (preview-buf (ogent-edit-preview-diff edit)))
        (with-current-buffer preview-buf
          (should buffer-read-only)))
    (ogent-edit-display-test--cleanup-buffers)))

;;; Keybinding Tests

(ert-deftest ogent-edit-display-test-preview-has-keybindings ()
  "Test preview mode defines expected keybindings."
  (should (keymapp ogent-edit-preview-mode-map))
  (should (eq (lookup-key ogent-edit-preview-mode-map (kbd "a"))
              'ogent-edit-preview-accept))
  (should (eq (lookup-key ogent-edit-preview-mode-map (kbd "r"))
              'ogent-edit-preview-reject))
  (should (eq (lookup-key ogent-edit-preview-mode-map (kbd "q"))
              'ogent-edit-preview-reject))
  (should (eq (lookup-key ogent-edit-preview-mode-map (kbd "RET"))
              'ogent-edit-preview-accept))
  (should (eq (lookup-key ogent-edit-preview-mode-map (kbd "n"))
              'diff-hunk-next))
  (should (eq (lookup-key ogent-edit-preview-mode-map (kbd "p"))
              'diff-hunk-prev)))

;;; Accept/Reject Tests

(ert-deftest ogent-edit-display-test-accept-applies-smerge ()
  "Test accepting preview applies edit as smerge conflict."
  (unwind-protect
      (let* ((old-text "original")
             (new-text "modified")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (ogent-edit-preview-diff edit)
        ;; Simulate accept
        (with-current-buffer "*ogent-diff*"
          (ogent-edit-preview-accept))
        ;; Check source buffer has smerge conflict markers
        (with-current-buffer source-buf
          (let ((content (buffer-string)))
            (should (string-match-p "<<<<<<< original" content))
            (should (string-match-p "=======" content))
            (should (string-match-p ">>>>>>> ogent" content))
            (should (string-match-p "original" content))
            (should (string-match-p "modified" content)))
          (should (eq (ogent-edit-status edit) 'applied))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-reject-closes-preview ()
  "Test rejecting preview closes buffer without applying."
  (unwind-protect
      (let* ((old-text "original")
             (new-text "modified")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (ogent-edit-preview-diff edit)
        ;; Simulate reject
        (with-current-buffer "*ogent-diff*"
          (ogent-edit-preview-reject))
        ;; Preview buffer should be gone
        (should-not (get-buffer "*ogent-diff*"))
        ;; Source buffer should be unchanged
        (with-current-buffer source-buf
          (let ((content (buffer-string)))
            (should (equal content old-text))
            (should-not (string-match-p "<<<<<<< original" content))))
        ;; Edit status should be rejected
        (should (eq (ogent-edit-status edit) 'rejected)))
    (ogent-edit-display-test--cleanup-buffers)))

;;; Smerge Workflow Tests (existing functionality)

(ert-deftest ogent-edit-display-test-format-conflict ()
  "Test conflict marker formatting."
  (let ((result (ogent-edit--format-conflict "old" "new")))
    (should (string-match-p "<<<<<<< original" result))
    (should (string-match-p "=======" result))
    (should (string-match-p ">>>>>>> ogent" result))
    (should (string-match-p "old" result))
    (should (string-match-p "new" result))))

(ert-deftest ogent-edit-display-test-apply-as-smerge ()
  "Test applying edit as smerge conflict."
  (unwind-protect
      (let* ((old-text "line1\nline2")
             (new-text "line1\nmodified")
             (edit (ogent-edit-display-test--make-edit old-text new-text)))
        (should (ogent-edit-valid-p edit))
        (ogent-edit-apply-as-smerge edit)
        (should (eq (ogent-edit-status edit) 'applied))
        (with-current-buffer (ogent-edit-source-buffer edit)
          (let ((content (buffer-string)))
            (should (string-match-p "<<<<<<< original" content))
            (should (string-match-p "line1" content))
            (should (string-match-p "line2" content))
            (should (string-match-p "modified" content)))))
    (ogent-edit-display-test--cleanup-buffers)))

;;; Marker Synchronization Tests

(ert-deftest ogent-edit-display-test-source-marker-created ()
  "Test that source marker is created when edit is applied."
  (unwind-protect
      (let* ((old-text "original code")
             (new-text "modified code")
             (edit (ogent-edit-display-test--make-edit old-text new-text)))
        ;; Before applying, no source marker
        (should-not (ogent-edit-source-marker edit))
        ;; Apply the edit
        (ogent-edit-apply-as-smerge edit)
        ;; Now source marker should exist
        (should (ogent-edit-source-marker edit))
        (should (markerp (ogent-edit-source-marker edit)))
        (should (marker-buffer (ogent-edit-source-marker edit))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-find-edit-by-id ()
  "Test finding edit by ID across buffers."
  (unwind-protect
      (let* ((edit (ogent-edit-display-test--make-edit "old" "new"))
             (source-buf (ogent-edit-source-buffer edit)))
        ;; Track the edit
        (with-current-buffer source-buf
          (ogent-edit--track-edits (list edit)))
        ;; Should find it by ID
        (let ((found (ogent-edit--find-edit-by-id "test-edit-001")))
          (should found)
          (should (equal (ogent-edit-id found) "test-edit-001")))
        ;; Should not find non-existent ID
        (should-not (ogent-edit--find-edit-by-id "non-existent")))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-find-edit-at-point ()
  "Test finding edit at point in source buffer."
  (unwind-protect
      (let* ((old-text "original code")
             (new-text "modified code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        ;; Apply and track
        (ogent-edit-apply-as-smerge edit)
        (with-current-buffer source-buf
          (ogent-edit--track-edits (list edit))
          ;; Move to start of conflict
          (goto-char (point-min))
          ;; Should find the edit
          (let ((found (ogent-edit--find-edit-at-point)))
            (should found)
            (should (equal (ogent-edit-id found) "test-edit-001")))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-goto-source-errors-without-edit ()
  "Test goto-source errors when no edit at point."
  (with-temp-buffer
    (org-mode)
    (insert "* Some heading\nNo edit here")
    (should-error (ogent-edit-goto-source) :type 'user-error)))

(ert-deftest ogent-edit-display-test-goto-companion-errors-without-edit ()
  "Test goto-companion errors when no edit at point."
  (with-temp-buffer
    (insert "No edit here")
    (should-error (ogent-edit-goto-companion) :type 'user-error)))

(provide 'ogent-edit-display-tests)

;;; ogent-edit-display-tests.el ends here
