;;; ogent-edit-display-tests.el --- Tests for ogent-edit-display -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for smerge-based edit display and diff preview functionality.

;;; Code:

(require 'ert)
(require 'ogent-edit-display)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)

;; Defined by the optional inline-diff package, loaded at runtime.
(defvar inline-diff--overlays)

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

;;; Track Edits Tests

(ert-deftest ogent-edit-display-test-track-edits-appends ()
  "ogent-edit--track-edits appends edits to tracking list."
  (with-temp-buffer
    (setq ogent-edit--pending-edits nil)
    (let ((edit1 (make-ogent-edit :id "e1" :status 'pending))
          (edit2 (make-ogent-edit :id "e2" :status 'pending)))
      (ogent-edit--track-edits (list edit1))
      (should (= 1 (length ogent-edit--pending-edits)))
      (ogent-edit--track-edits (list edit2))
      (should (= 2 (length ogent-edit--pending-edits)))
      ;; Order should be preserved (first added first)
      (should (equal "e1" (ogent-edit-id (nth 0 ogent-edit--pending-edits))))
      (should (equal "e2" (ogent-edit-id (nth 1 ogent-edit--pending-edits)))))))

(ert-deftest ogent-edit-display-test-track-edits-empty-list ()
  "ogent-edit--track-edits with empty list is a no-op."
  (with-temp-buffer
    (setq ogent-edit--pending-edits nil)
    (ogent-edit--track-edits nil)
    (should (null ogent-edit--pending-edits))))

(ert-deftest ogent-edit-display-test-track-edits-multiple-at-once ()
  "ogent-edit--track-edits can add multiple edits at once."
  (with-temp-buffer
    (setq ogent-edit--pending-edits nil)
    (let ((edits (list (make-ogent-edit :id "e1" :status 'pending)
                       (make-ogent-edit :id "e2" :status 'pending)
                       (make-ogent-edit :id "e3" :status 'pending))))
      (ogent-edit--track-edits edits)
      (should (= 3 (length ogent-edit--pending-edits))))))

;;; Goto First Tests

(ert-deftest ogent-edit-display-test-goto-first-moves-to-conflict ()
  "ogent-edit-goto-first moves point into the smerge conflict region."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-test-goto*")))
        (with-current-buffer buf
          ;; Insert content with conflict and text after
          (insert "prefix\n<<<<<<< original\nold\n=======\nnew\n>>>>>>> ogent\nsuffix\n")
          (smerge-mode 1)
          (goto-char (point-max))
          ;; Go to first conflict
          (ogent-edit-goto-first)
          ;; Point should be inside the conflict (after <<<<<<)
          (should (> (point) (length "prefix\n")))
          (should (< (point) (point-max)))))
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *ogent-test" (buffer-name buf))
        (kill-buffer buf)))))

;;; Count Pending Tests

(ert-deftest ogent-edit-display-test-count-pending-with-conflicts ()
  "ogent-edit-count-pending counts smerge conflicts."
  (unwind-protect
      (let* ((edit (ogent-edit-display-test--make-edit "original" "modified"))
             (source-buf (ogent-edit-source-buffer edit)))
        (ogent-edit-apply-as-smerge edit)
        (with-current-buffer source-buf
          (let ((count (ogent-edit-count-pending)))
            (should (numberp count))
            (should (>= count 1)))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-count-pending-nil-without-smerge ()
  "ogent-edit-count-pending returns nil when smerge-mode is off."
  (with-temp-buffer
    (insert "No conflicts here")
    ;; smerge-mode not active
    (should (null (ogent-edit-count-pending)))))

;;; Accept/Reject Current Tests

(ert-deftest ogent-edit-display-test-accept-current-keeps-new ()
  "ogent-edit-accept-current keeps the new (lower) text."
  (unwind-protect
      (let* ((old-text "old code")
             (new-text "new code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (ogent-edit-apply-as-smerge edit)
        (with-current-buffer source-buf
          (ogent-edit--track-edits (list edit))
          (goto-char (point-min))
          (smerge-next)
          (ogent-edit-accept-current)
          ;; New text should remain, conflict markers should be gone
          (should (string-match-p "new code" (buffer-string)))
          (should-not (string-match-p "<<<<<<" (buffer-string)))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-reject-current-keeps-old ()
  "ogent-edit-reject-current keeps the original (upper) text."
  (unwind-protect
      (let* ((old-text "old code")
             (new-text "new code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (ogent-edit-apply-as-smerge edit)
        (with-current-buffer source-buf
          (ogent-edit--track-edits (list edit))
          (goto-char (point-min))
          (smerge-next)
          (ogent-edit-reject-current)
          ;; Old text should remain, conflict markers should be gone
          (should (string-match-p "old code" (buffer-string)))
          (should-not (string-match-p "<<<<<<" (buffer-string)))))
    (ogent-edit-display-test--cleanup-buffers)))

;;; Accept/Reject All Tests

(ert-deftest ogent-edit-display-test-accept-all-resolves-single ()
  "ogent-edit-accept-all resolves a single smerge conflict with new text."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-test-all*")))
        (with-current-buffer buf
          (insert "<<<<<<< original\nold1\n=======\nnew1\n>>>>>>> ogent\n")
          (smerge-mode 1)
          (ogent-edit-accept-all)
          ;; Conflict markers should be resolved
          (should-not (string-match-p "<<<<<<" (buffer-string)))
          ;; New text should be kept
          (should (string-match-p "new1" (buffer-string)))))
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *ogent-test" (buffer-name buf))
        (kill-buffer buf)))))

(ert-deftest ogent-edit-display-test-reject-all-resolves-single ()
  "ogent-edit-reject-all resolves a single smerge conflict with original text."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-test-all*")))
        (with-current-buffer buf
          (insert "<<<<<<< original\nold1\n=======\nnew1\n>>>>>>> ogent\n")
          (smerge-mode 1)
          (ogent-edit-reject-all)
          ;; Conflict markers should be resolved
          (should-not (string-match-p "<<<<<<" (buffer-string)))
          ;; Old text should be kept
          (should (string-match-p "old1" (buffer-string)))))
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *ogent-test" (buffer-name buf))
        (kill-buffer buf)))))

;;; Find Edit in Companion Tests

(ert-deftest ogent-edit-display-test-find-edit-in-companion-with-id ()
  "ogent-edit--find-edit-in-companion finds edit by OGENT_EDIT_ID property."
  (unwind-protect
      (let* ((edit (ogent-edit-display-test--make-edit "old" "new"))
             (source-buf (ogent-edit-source-buffer edit)))
        ;; Track the edit
        (with-current-buffer source-buf
          (ogent-edit--track-edits (list edit)))
        ;; Create a companion buffer with the property
        (with-temp-buffer
          (org-mode)
          (insert "* Edit\n:PROPERTIES:\n:OGENT_EDIT_ID: test-edit-001\n:END:\nDetails\n")
          (goto-char (point-min))
          (let ((found (ogent-edit--find-edit-in-companion)))
            (should found)
            (should (equal "test-edit-001" (ogent-edit-id found))))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-find-edit-in-companion-nil-no-property ()
  "ogent-edit--find-edit-in-companion returns nil without OGENT_EDIT_ID."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\nNo edit property here\n")
    (goto-char (point-min))
    (should-not (ogent-edit--find-edit-in-companion))))

;;; Preview Accept/Reject Tests

(ert-deftest ogent-edit-display-test-preview-accept-errors-without-edit ()
  "ogent-edit-preview-accept errors when no edit is set."
  (with-temp-buffer
    (setq ogent-edit-preview--current-edit nil)
    (should-error (ogent-edit-preview-accept) :type 'user-error)))

(ert-deftest ogent-edit-display-test-preview-reject-errors-without-edit ()
  "ogent-edit-preview-reject errors when no edit is set."
  (with-temp-buffer
    (setq ogent-edit-preview--current-edit nil)
    (should-error (ogent-edit-preview-reject) :type 'user-error)))

;;; Overlay Hint String Tests

(ert-deftest ogent-edit-display-test-overlay-hint-string-format ()
  "ogent-edit--overlay-hint-string returns a string with action hints."
  (let ((hint (ogent-edit--overlay-hint-string)))
    (should (stringp hint))
    (should (string-match-p "EDIT READY" hint))
    (should (string-match-p "ccept" hint))
    (should (string-match-p "eject" hint))
    (should (string-match-p "iff" hint))
    (should (string-match-p "diff" hint))
    (should (string-match-p "erge" hint))
    (should (string-match-p "oggle" hint))))

;;; Overlay At Tests

(ert-deftest ogent-edit-display-test-overlay-at-finds-overlay ()
  "ogent-edit--overlay-at finds overlay at point."
  (unwind-protect
      (let* ((old-text "original code")
             (new-text "modified code")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit)))
        (with-current-buffer source-buf
          (ogent-edit-apply-as-overlay edit)
          ;; Should find the overlay at point-min
          (goto-char (point-min))
          (let ((ov (ogent-edit--overlay-at)))
            (should ov)
            (should (overlay-get ov 'ogent-edit)))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-overlay-at-errors-when-none ()
  "ogent-edit--overlay-at signals error when no overlay at point."
  (with-temp-buffer
    (insert "No overlays here")
    (setq ogent-edit--overlay-list nil)
    (should-error (ogent-edit--overlay-at) :type 'user-error)))

;;; Overlay Do Action Tests

(ert-deftest ogent-edit-display-test-overlay-do-action-dispatches ()
  "ogent-edit--overlay-do-action dispatches to correct function."
  (let ((actions-called nil))
    (cl-letf (((symbol-function 'ogent-edit-overlay-accept)
               (lambda (ov) (push (cons 'accept ov) actions-called)))
              ((symbol-function 'ogent-edit-overlay-reject)
               (lambda (ov) (push (cons 'reject ov) actions-called)))
              ((symbol-function 'ogent-edit-overlay-diff)
               (lambda (ov) (push (cons 'diff ov) actions-called)))
              ((symbol-function 'ogent-edit-overlay-ediff)
               (lambda (ov) (push (cons 'ediff ov) actions-called)))
              ((symbol-function 'ogent-edit-overlay-merge)
               (lambda (ov) (push (cons 'merge ov) actions-called)))
              ((symbol-function 'ogent-edit-overlay-dispatch)
               (lambda (ov) (push (cons 'dispatch ov) actions-called))))
      (ogent-edit--overlay-do-action 'mock-ov 'accept)
      (ogent-edit--overlay-do-action 'mock-ov 'reject)
      (ogent-edit--overlay-do-action 'mock-ov 'diff)
      (ogent-edit--overlay-do-action 'mock-ov 'ediff)
      (ogent-edit--overlay-do-action 'mock-ov 'merge)
      (ogent-edit--overlay-do-action 'mock-ov 'dispatch)
      (should (= 6 (length actions-called))))))

;;; Overlay Cleanup Tests

(ert-deftest ogent-edit-display-test-overlay-cleanup-removes ()
  "ogent-edit--overlay-cleanup removes overlay and tracking entry."
  (with-temp-buffer
    (insert "some text here")
    (let ((ov (make-overlay 1 5)))
      (setq ogent-edit--overlay-list (list ov))
      (ogent-edit--overlay-cleanup ov)
      ;; Overlay should be deleted
      (should-not (overlay-buffer ov))
      ;; Should be removed from tracking list
      (should (= 0 (length ogent-edit--overlay-list))))))

(ert-deftest ogent-edit-display-test-overlay-cleanup-preserves-others ()
  "ogent-edit--overlay-cleanup only removes the target overlay."
  (with-temp-buffer
    (insert "some text here more text")
    (let ((ov1 (make-overlay 1 5))
          (ov2 (make-overlay 10 15)))
      (setq ogent-edit--overlay-list (list ov1 ov2))
      (ogent-edit--overlay-cleanup ov1)
      ;; Only ov1 should be removed
      (should (= 1 (length ogent-edit--overlay-list)))
      (should (eq ov2 (car ogent-edit--overlay-list)))
      ;; ov2 should still be alive
      (should (overlay-buffer ov2))
      (delete-overlay ov2))))

;;; Inline Diff Available Tests

(ert-deftest ogent-edit-display-test-inline-diff-available-checks-feature ()
  "ogent-edit-inline-diff-available-p checks for inline-diff feature."
  ;; Should return non-nil if inline-diff is loaded (which it is in test env)
  (require 'inline-diff)
  (should (ogent-edit-inline-diff-available-p)))

;;; Display All Tests

(ert-deftest ogent-edit-display-test-display-all-smerge ()
  "ogent-edit-display-all with smerge method applies all edits."
  (unwind-protect
      (let* ((buf (generate-new-buffer " *ogent-test-display-all*")))
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
                 (ogent-edit-display-method 'smerge))
            (ogent-edit-validate edit1)
            (let ((applied (ogent-edit-display-all (list edit1))))
              (should (= 1 (length applied)))
              (should (string-match-p "<<<<<<" (buffer-string)))))))
    (dolist (buf (buffer-list))
      (when (string-prefix-p " *ogent-test" (buffer-name buf))
        (kill-buffer buf)))))

;;; Smerge Resolved Hook Tests

(ert-deftest ogent-edit-display-test-smerge-resolved-hook-sets-status ()
  "ogent-edit--smerge-resolved-hook sets edit status to resolved."
  (unwind-protect
      (let* ((old-text "original")
             (new-text "modified")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (source-buf (ogent-edit-source-buffer edit))
             (hook-called nil))
        (ogent-edit-apply-as-smerge edit)
        (with-current-buffer source-buf
          (ogent-edit--track-edits (list edit))
          ;; Set up a hook to track the call
          (let ((ogent-edit-resolved-hook
                 (list (lambda (e) (setq hook-called e)))))
            ;; Position point at the conflict
            (goto-char (point-min))
            (smerge-next)
            ;; Simulate resolution
            (ogent-edit--smerge-resolved-hook)
            ;; Edit should be marked resolved
            (should (eq (ogent-edit-status edit) 'resolved))
            (should hook-called))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-smerge-resolved-hook-no-edit ()
  "ogent-edit--smerge-resolved-hook is safe when no edit at point."
  (with-temp-buffer
    (insert "No conflicts")
    (setq ogent-edit--pending-edits nil)
    ;; Should not error
    (ogent-edit--smerge-resolved-hook)))

;;; Batch Apply Tests

(ert-deftest ogent-edit-display-test-apply-all-smerge-reverse-order ()
  "Apply-all-as-smerge applies a single edit correctly."
  (with-temp-buffer
    (insert "hello world\n")
    (let* ((buf (current-buffer))
           (edit1 (make-ogent-edit
                   :id "edit-001" :old-text "hello world"
                   :new-text "HELLO WORLD" :source-buffer buf
                   :start-pos 1 :end-pos 12 :status 'pending))
           (edits (list edit1)))
      (cl-letf (((symbol-function 'ogent-edit-filter-valid)
                 (lambda (e) e)))
        (let ((applied (ogent-edit-apply-all-as-smerge edits)))
          ;; Should have been applied
          (should (= (length applied) 1))
          (should (eq (ogent-edit-status edit1) 'applied))
          ;; Buffer should contain conflict markers
          (should (string-match-p "<<<<<<< original" (buffer-string)))
          (should (string-match-p "HELLO WORLD" (buffer-string))))))))

(ert-deftest ogent-edit-display-test-apply-all-smerge-handles-errors ()
  "Apply-all-as-smerge gracefully handles individual edit errors."
  (with-temp-buffer
    (insert "test content\n")
    (let* ((good-edit (make-ogent-edit
                       :id "edit-good" :old-text "test content"
                       :new-text "new content" :source-buffer (current-buffer)
                       :start-pos 1 :end-pos 13 :status 'pending))
           (bad-edit (make-ogent-edit
                      :id "edit-bad" :old-text "nonexistent"
                      :new-text "replacement" :source-buffer (current-buffer)
                      :start-pos 999 :end-pos 1010 :status 'pending)))
      (cl-letf (((symbol-function 'ogent-edit-filter-valid)
                 (lambda (e) e)))
        (let ((applied (ogent-edit-apply-all-as-smerge (list bad-edit good-edit))))
          ;; Good edit should succeed
          (should (>= (length applied) 1))
          ;; Bad edit should be marked as error
          (should (eq (ogent-edit-status bad-edit) 'error))
          (should (ogent-edit-error-message bad-edit)))))))

;;; Overlay Display Tests

(ert-deftest ogent-edit-display-test-overlay-hint-string ()
  "Test overlay hint string contains action labels."
  (let ((hint (ogent-edit--overlay-hint-string)))
    (should (string-match-p "EDIT READY" hint))
    (should (string-match-p "ccept" hint))
    (should (string-match-p "eject" hint))
    (should (string-match-p "iff" hint))))

(ert-deftest ogent-edit-display-test-overlay-at-error ()
  "Test overlay-at signals error when no overlay at point."
  (with-temp-buffer
    (insert "no overlays\n")
    (let ((ogent-edit--overlay-list nil))
      (should-error (ogent-edit--overlay-at (point))))))

(ert-deftest ogent-edit-display-test-overlay-nav-forward-backward ()
  "Test overlay next/previous navigation."
  (with-temp-buffer
    (insert "abcdefghijklmnop\n")
    (let* ((ov1 (make-overlay 1 4))
           (ov2 (make-overlay 8 12)))
      (overlay-put ov1 'ogent-edit t)
      (overlay-put ov2 'ogent-edit t)
      (let ((ogent-edit--overlay-list (list ov1 ov2)))
        ;; From beginning, next should go to first overlay
        (goto-char 1)
        (should-error (ogent-edit-overlay-previous))
        ;; Next from position 5 should go to ov2
        (goto-char 5)
        (ogent-edit-overlay-next)
        (should (= (point) 8))))))

;;; Unified Display Interface Tests

(ert-deftest ogent-edit-display-test-display-dispatches-smerge ()
  "Test display dispatches to smerge method."
  (let ((ogent-edit-display-method 'smerge)
        (dispatched nil))
    (cl-letf (((symbol-function 'ogent-edit-apply-as-smerge)
               (lambda (_edit) (setq dispatched 'smerge))))
      (ogent-edit-display (make-ogent-edit :id "test"))
      (should (eq dispatched 'smerge)))))

(ert-deftest ogent-edit-display-test-display-dispatches-overlay ()
  "Test display dispatches to overlay method."
  (let ((ogent-edit-display-method 'overlay)
        (dispatched nil))
    (cl-letf (((symbol-function 'ogent-edit-apply-as-overlay)
               (lambda (_edit) (setq dispatched 'overlay))))
      (ogent-edit-display (make-ogent-edit :id "test"))
      (should (eq dispatched 'overlay)))))

(ert-deftest ogent-edit-display-test-display-all-dispatches ()
  "Test display-all dispatches to correct method."
  (let ((ogent-edit-display-method 'smerge)
        (dispatched nil))
    (cl-letf (((symbol-function 'ogent-edit-apply-all-as-smerge)
               (lambda (_edits) (setq dispatched 'smerge) nil)))
      (ogent-edit-display-all (list (make-ogent-edit :id "test")))
      (should (eq dispatched 'smerge)))))

(ert-deftest ogent-edit-display-test-display-all-overlay ()
  "Test display-all dispatches to overlay when configured."
  (let ((ogent-edit-display-method 'overlay)
        (dispatched nil))
    (cl-letf (((symbol-function 'ogent-edit-apply-all-as-overlay)
               (lambda (_edits) (setq dispatched 'overlay) nil)))
      (ogent-edit-display-all (list (make-ogent-edit :id "test")))
      (should (eq dispatched 'overlay)))))

;;; Toggle Display Method Tests

(ert-deftest ogent-edit-display-test-toggle-cycles-methods ()
  "Test toggle-display-method cycles through available methods."
  (let ((ogent-edit-display-method 'smerge))
    (cl-letf (((symbol-function 'ogent-edit-inline-diff-available-p)
               (lambda () nil))
              ((symbol-function 'message)
               (lambda (&rest _) nil)))
      (ogent-edit-toggle-display-method)
      (should (eq ogent-edit-display-method 'overlay))
      (ogent-edit-toggle-display-method)
      (should (eq ogent-edit-display-method 'smerge)))))

(ert-deftest ogent-edit-display-test-toggle-includes-inline-diff ()
  "Test toggle includes inline-diff when available."
  (let ((ogent-edit-display-method 'smerge))
    (cl-letf (((symbol-function 'ogent-edit-inline-diff-available-p)
               (lambda () t))
              ((symbol-function 'message)
               (lambda (&rest _) nil)))
      (ogent-edit-toggle-display-method)
      (should (eq ogent-edit-display-method 'overlay))
      (ogent-edit-toggle-display-method)
      (should (eq ogent-edit-display-method 'inline-diff))
      (ogent-edit-toggle-display-method)
      (should (eq ogent-edit-display-method 'smerge)))))

;;; Find Edit By ID Tests

(ert-deftest ogent-edit-display-test-find-edit-by-id-cross-buffer ()
  "Test finding edit by ID across buffers."
  (let ((buf (generate-new-buffer " *test-find-edit*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq ogent-edit--pending-edits
                  (list (make-ogent-edit :id "abc-001" :old-text "old"
                                         :new-text "new"))))
          (let ((found (ogent-edit--find-edit-by-id "abc-001")))
            (should found)
            (should (equal (ogent-edit-id found) "abc-001")))
          ;; Non-existent should return nil
          (should-not (ogent-edit--find-edit-by-id "nonexistent")))
      (kill-buffer buf))))

;;; Inline Diff Availability

(ert-deftest ogent-edit-display-test-inline-diff-availability-check ()
  "Test inline-diff-available-p checks for feature."
  ;; inline-diff is not loaded in test environment
  (should (eq (ogent-edit-inline-diff-available-p) (featurep 'inline-diff))))

;;; Re-anchor Tests

(ert-deftest ogent-edit-display-test-smerge-unchanged-buffer-applies-at-position ()
  "Test applying to an unchanged buffer keeps the original position."
  (unwind-protect
      (let* ((old-text "target text")
             (new-text "replacement text")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (start (ogent-edit-start-pos edit)))
        (ogent-edit-apply-as-smerge edit)
        (should (eq (ogent-edit-status edit) 'applied))
        (with-current-buffer (ogent-edit-source-buffer edit)
          ;; Conflict markers start exactly at the validated position.
          (goto-char start)
          (should (looking-at-p "<<<<<<< original"))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-smerge-re-anchors-after-shift ()
  "Test apply re-anchors when text is inserted before the target."
  (unwind-protect
      (let* ((old-text "target text")
             (new-text "replacement text")
             (edit (ogent-edit-display-test--make-edit old-text new-text))
             (prefix ";; unrelated preamble\n"))
        (with-current-buffer (ogent-edit-source-buffer edit)
          (goto-char (point-min))
          (insert prefix))
        (ogent-edit-apply-as-smerge edit)
        (should (eq (ogent-edit-status edit) 'applied))
        (with-current-buffer (ogent-edit-source-buffer edit)
          (let ((content (buffer-string)))
            ;; Prefix intact, conflict wraps the right text after it.
            (should (string-prefix-p prefix content))
            (should (string-match-p "<<<<<<< original\ntarget text\n" content))
            (should (string-match-p "=======\nreplacement text\n" content)))
          ;; Struct positions were updated to the new location.
          (should (= (ogent-edit-start-pos edit) (1+ (length prefix))))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-smerge-refuses-stale-edit ()
  "Test apply refuses when the original text is gone."
  (unwind-protect
      (let* ((old-text "target text")
             (edit (ogent-edit-display-test--make-edit old-text "new text")))
        (with-current-buffer (ogent-edit-source-buffer edit)
          (erase-buffer)
          (insert "completely different content"))
        (should-error (ogent-edit-apply-as-smerge edit) :type 'user-error)
        (should (eq (ogent-edit-status edit) 'error))
        (should (string-match-p "not found" (ogent-edit-error-message edit)))
        (with-current-buffer (ogent-edit-source-buffer edit)
          (should (equal (buffer-string) "completely different content"))))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-smerge-refuses-ambiguous-edit ()
  "Test apply refuses when the original text became ambiguous."
  (unwind-protect
      (let* ((old-text "target text")
             (edit (ogent-edit-display-test--make-edit old-text "new text"))
             (mutated nil))
        (with-current-buffer (ogent-edit-source-buffer edit)
          ;; Shift the cached position off the text AND duplicate it.
          (goto-char (point-min))
          (insert ";; shift\n")
          (goto-char (point-max))
          (insert "\ntarget text")
          (setq mutated (buffer-string)))
        (should-error (ogent-edit-apply-as-smerge edit) :type 'user-error)
        (should (eq (ogent-edit-status edit) 'error))
        (should (string-match-p "2 matches" (ogent-edit-error-message edit)))
        (with-current-buffer (ogent-edit-source-buffer edit)
          (should (equal (buffer-string) mutated))))
    (ogent-edit-display-test--cleanup-buffers)))

;;; Preview Resolution Pipeline Tests

(ert-deftest ogent-edit-display-test-preview-reject-runs-resolved-hook ()
  "Test rejecting a preview runs `ogent-edit-resolved-hook'."
  (unwind-protect
      (let* ((edit (ogent-edit-display-test--make-edit "original" "modified"))
             (resolved nil)
             (ogent-edit-resolved-hook
              (list (lambda (e) (push e resolved)))))
        (ogent-edit-preview-diff edit)
        (with-current-buffer "*ogent-diff*"
          (ogent-edit-preview-reject))
        (should (equal resolved (list edit)))
        (should (eq (ogent-edit-status edit) 'rejected)))
    (ogent-edit-display-test--cleanup-buffers)))

(ert-deftest ogent-edit-display-test-preview-accept-tracks-edit ()
  "Test accepting a preview tracks the edit in the source buffer."
  (unwind-protect
      (let* ((edit (ogent-edit-display-test--make-edit "original" "modified"))
             (source-buf (ogent-edit-source-buffer edit)))
        (ogent-edit-preview-diff edit)
        (with-current-buffer "*ogent-diff*"
          (ogent-edit-preview-accept))
        (should (memq edit (buffer-local-value 'ogent-edit--pending-edits
                                               source-buf))))
    (ogent-edit-display-test--cleanup-buffers)))

(provide 'ogent-edit-display-tests)

;;; ogent-edit-display-tests.el ends here
