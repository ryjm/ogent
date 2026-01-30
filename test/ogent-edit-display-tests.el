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

;;; Overlay Display Tests

(ert-deftest ogent-edit-display-test-overlay-customization-exists ()
  "Test that display method customization exists."
  (should (boundp 'ogent-edit-display-method))
  (should (memq ogent-edit-display-method '(smerge overlay))))

(ert-deftest ogent-edit-display-test-overlay-faces-defined ()
  "Test that overlay faces are defined."
  (should (facep 'ogent-edit-overlay-face))
  (should (facep 'ogent-edit-overlay-new-face)))

(ert-deftest ogent-edit-display-test-overlay-keymap-defined ()
  "Test that overlay keymap has expected bindings."
  (should (keymapp ogent-edit-overlay-map))
  (should (eq (lookup-key ogent-edit-overlay-map (kbd "a"))
              'ogent-edit-overlay-accept))
  (should (eq (lookup-key ogent-edit-overlay-map (kbd "r"))
              'ogent-edit-overlay-reject))
  (should (eq (lookup-key ogent-edit-overlay-map (kbd "d"))
              'ogent-edit-overlay-diff))
  (should (eq (lookup-key ogent-edit-overlay-map (kbd "e"))
              'ogent-edit-overlay-ediff))
  (should (eq (lookup-key ogent-edit-overlay-map (kbd "m"))
              'ogent-edit-overlay-merge))
  (should (eq (lookup-key ogent-edit-overlay-map (kbd "n"))
              'ogent-edit-overlay-next))
  (should (eq (lookup-key ogent-edit-overlay-map (kbd "p"))
              'ogent-edit-overlay-previous)))

(ert-deftest ogent-edit-display-test-apply-as-overlay-creates-overlay ()
  "Test applying edit as overlay creates overlay with correct properties."
  (unwind-protect
      (let* ((old-text "original code")
             (new-text "modified code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (with-current-buffer source-buf
          (ogent-edit-apply-as-overlay edit)
          ;; Should have created an overlay
          (should (= (length ogent-edit--overlay-list) 1))
          (let ((ov (car ogent-edit--overlay-list)))
            ;; Overlay should have correct properties
            (should (overlay-get ov 'ogent-edit))
            (should (equal (overlay-get ov 'ogent-new-text) new-text))
            (should (overlay-get ov 'display))
            (should (overlay-get ov 'keymap))
            (should (eq (overlay-get ov 'face) 'ogent-edit-overlay-face)))
          ;; Edit status should be applied
          (should (eq (ogent-edit-status edit) 'applied))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-overlay-accept-replaces-text ()
  "Test accepting overlay replaces original with new text."
  (unwind-protect
      (let* ((old-text "original code")
             (new-text "modified code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (with-current-buffer source-buf
          (ogent-edit-apply-as-overlay edit)
          (goto-char (point-min))
          (ogent-edit-overlay-accept)
          ;; Overlay should be removed
          (should (= (length ogent-edit--overlay-list) 0))
          ;; Text should be replaced
          (should (equal (buffer-string) new-text))
          ;; Edit status should be accepted
          (should (eq (ogent-edit-status edit) 'accepted))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-overlay-reject-keeps-original ()
  "Test rejecting overlay keeps original text."
  (unwind-protect
      (let* ((old-text "original code")
             (new-text "modified code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (with-current-buffer source-buf
          (ogent-edit-apply-as-overlay edit)
          (goto-char (point-min))
          (ogent-edit-overlay-reject)
          ;; Overlay should be removed
          (should (= (length ogent-edit--overlay-list) 0))
          ;; Text should be unchanged
          (should (equal (buffer-string) old-text))
          ;; Edit status should be rejected
          (should (eq (ogent-edit-status edit) 'rejected))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-overlay-merge-creates-smerge ()
  "Test merge action converts overlay to smerge conflict."
  (unwind-protect
      (let* ((old-text "original code")
             (new-text "modified code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (with-current-buffer source-buf
          (ogent-edit-apply-as-overlay edit)
          (goto-char (point-min))
          (ogent-edit-overlay-merge)
          ;; Overlay should be removed
          (should (= (length ogent-edit--overlay-list) 0))
          ;; Buffer should have smerge markers
          (let ((content (buffer-string)))
            (should (string-match-p "<<<<<<< original" content))
            (should (string-match-p "=======" content))
            (should (string-match-p ">>>>>>> ogent" content)))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-overlay-navigation ()
  "Test navigation between multiple overlays."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-test-nav*")))
        (with-current-buffer buf
          (insert "line1\nline2\nline3\nline4\nline5")
          ;; Create two edits at different positions
          (let* ((edit1 (make-ogent-edit
                         :id "edit-1"
                         :old-text "line2"
                         :new-text "modified2"
                         :source-buffer buf
                         :source-file "test.el"
                         :status 'pending
                         :timestamp (current-time)))
                 (edit2 (make-ogent-edit
                         :id "edit-2"
                         :old-text "line4"
                         :new-text "modified4"
                         :source-buffer buf
                         :source-file "test.el"
                         :status 'pending
                         :timestamp (current-time))))
            ;; Validate edits
            (ogent-edit-validate edit1)
            (ogent-edit-validate edit2)
            ;; Apply as overlays (in reverse order to preserve positions)
            (ogent-edit-apply-as-overlay edit2)
            (ogent-edit-apply-as-overlay edit1)
            ;; Should have 2 overlays
            (should (= (length ogent-edit--overlay-list) 2))
            ;; Navigate from start
            (goto-char (point-min))
            (ogent-edit-overlay-next)
            ;; Should be at first overlay
            (should (> (point) (point-min)))
            ;; Navigate to next
            (ogent-edit-overlay-next)
            ;; Should be at second overlay
            (let ((pos (point)))
              ;; Navigate back
              (ogent-edit-overlay-previous)
              (should (< (point) pos))))))
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *ogent-test" (buffer-name buf))
        (kill-buffer buf)))))

(ert-deftest ogent-edit-display-test-unified-display-interface ()
  "Test unified display interface respects display method."
  (unwind-protect
      (let* ((old-text "original")
             (new-text "modified")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        ;; Test smerge method
        (let ((ogent-edit-display-method 'smerge))
          (ogent-edit-display edit)
          (with-current-buffer source-buf
            (should (string-match-p "<<<<<<< original" (buffer-string))))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-overlay-accept-all ()
  "Test accepting all overlays."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-test-all*")))
        (with-current-buffer buf
          (insert "line1\nline2")
          (let* ((edit1 (make-ogent-edit
                         :id "edit-1"
                         :old-text "line1"
                         :new-text "mod1"
                         :source-buffer buf
                         :source-file "test.el"
                         :status 'pending
                         :timestamp (current-time)))
                 (edit2 (make-ogent-edit
                         :id "edit-2"
                         :old-text "line2"
                         :new-text "mod2"
                         :source-buffer buf
                         :source-file "test.el"
                         :status 'pending
                         :timestamp (current-time))))
            (ogent-edit-validate edit1)
            (ogent-edit-validate edit2)
            (ogent-edit-apply-as-overlay edit2)
            (ogent-edit-apply-as-overlay edit1)
            (should (= (length ogent-edit--overlay-list) 2))
            (ogent-edit-overlay-accept-all)
            (should (= (length ogent-edit--overlay-list) 0))
            (should (eq (ogent-edit-status edit1) 'accepted))
            (should (eq (ogent-edit-status edit2) 'accepted)))))
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *ogent-test" (buffer-name buf))
        (kill-buffer buf)))))

(ert-deftest ogent-edit-display-test-overlay-reject-all ()
  "Test rejecting all overlays."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-test-all*")))
        (with-current-buffer buf
          (insert "line1\nline2")
          (let* ((edit1 (make-ogent-edit
                         :id "edit-1"
                         :old-text "line1"
                         :new-text "mod1"
                         :source-buffer buf
                         :source-file "test.el"
                         :status 'pending
                         :timestamp (current-time)))
                 (edit2 (make-ogent-edit
                         :id "edit-2"
                         :old-text "line2"
                         :new-text "mod2"
                         :source-buffer buf
                         :source-file "test.el"
                         :status 'pending
                         :timestamp (current-time))))
            (ogent-edit-validate edit1)
            (ogent-edit-validate edit2)
            (ogent-edit-apply-as-overlay edit2)
            (ogent-edit-apply-as-overlay edit1)
            (should (= (length ogent-edit--overlay-list) 2))
            (ogent-edit-overlay-reject-all)
            (should (= (length ogent-edit--overlay-list) 0))
            (should (eq (ogent-edit-status edit1) 'rejected))
            (should (eq (ogent-edit-status edit2) 'rejected))
            ;; Original text should be preserved
            (should (equal (buffer-string) "line1\nline2")))))
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *ogent-test" (buffer-name buf))
        (kill-buffer buf)))))

;;; Inline-diff Display Tests

(ert-deftest ogent-edit-display-test-inline-diff-available ()
  "Test that inline-diff availability check works."
  (require 'inline-diff)
  (should (ogent-edit-inline-diff-available-p)))

(ert-deftest ogent-edit-display-test-apply-as-inline-diff ()
  "Test applying edit as inline-diff creates overlays."
  (require 'inline-diff)
  (unwind-protect
      (let* ((old-text "hello world")
             (new-text "hello there")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (with-current-buffer source-buf
          (ogent-edit-apply-as-inline-diff edit)
          ;; Should have inline-diff-mode enabled
          (should (bound-and-true-p inline-diff-mode))
          ;; Should have overlays
          (should (> (length inline-diff--overlays) 0))
          ;; Edit status should be applied
          (should (eq (ogent-edit-status edit) 'applied))
          ;; Buffer should have new text
          (should (equal (buffer-string) new-text))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-inline-diff-display-method ()
  "Test unified display interface with inline-diff method."
  (require 'inline-diff)
  (unwind-protect
      (let* ((old-text "original text")
             (new-text "modified text")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit))
             (ogent-edit-display-method 'inline-diff))
        (with-current-buffer source-buf
          (ogent-edit-display edit)
          ;; Should have inline-diff-mode enabled
          (should (bound-and-true-p inline-diff-mode))
          ;; Buffer should have new text
          (should (equal (buffer-string) new-text))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-toggle-display-method ()
  "Test toggling between display methods."
  (require 'inline-diff)
  (let ((original ogent-edit-display-method))
    (unwind-protect
        (progn
          (setq ogent-edit-display-method 'smerge)
          (ogent-edit-toggle-display-method)
          (should (eq ogent-edit-display-method 'overlay))
          (ogent-edit-toggle-display-method)
          (should (eq ogent-edit-display-method 'inline-diff))
          (ogent-edit-toggle-display-method)
          (should (eq ogent-edit-display-method 'smerge)))
      (setq ogent-edit-display-method original))))

(ert-deftest ogent-edit-display-test-inline-diff-tracks-edits ()
  "Test that inline-diff adds edit to tracking list."
  (require 'inline-diff)
  (unwind-protect
      (let* ((old-text "old code")
             (new-text "new code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (with-current-buffer source-buf
          (ogent-edit-apply-as-inline-diff edit)
          ;; Edit should be tracked
          (should (memq edit ogent-edit--pending-edits))))
    (ogent-edit-display-test--cleanup-buffers)))

(provide 'ogent-edit-display-tests)

;;; ogent-edit-display-tests.el ends here
