;;; ogent-edit-log-tests.el --- Tests for ogent-edit-log -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-edit-format)
(require 'ogent-edit-log)
(require 'ogent-companion)

;;; Log Entry Formatting Tests

(ert-deftest ogent-edit-log-format-entry-basic ()
  "Log entry format includes required Org structure."
  (let ((edit (make-ogent-edit
               :id "test-001"
               :old-text "old code"
               :new-text "new code"
               :source-file "/path/to/file.el"
               :status 'pending
               :timestamp (current-time))))
    (let ((entry (ogent-edit--format-log-entry edit)))
      ;; Check Org heading structure
      (should (string-match-p "^\\*\\* Edit: test-001" entry))
      ;; Check timestamp present (flexible format)
      (should (string-match-p "\\[[-0-9]+ [A-Z][a-z]+ [0-9]+:[0-9]+\\]" entry))
      ;; Check properties drawer
      (should (string-match-p ":PROPERTIES:" entry))
      (should (string-match-p ":OGENT_EDIT_ID: test-001" entry))
      (should (string-match-p ":SOURCE_FILE: /path/to/file.el" entry))
      (should (string-match-p ":STATUS: pending" entry))
      (should (string-match-p ":END:" entry))
      ;; Check subheading
      (should (string-match-p "\\*\\*\\* Proposed Change" entry)))))

(ert-deftest ogent-edit-log-format-entry-unsaved-buffer ()
  "Log entry handles unsaved buffers gracefully."
  (let ((edit (make-ogent-edit
               :id "test-002"
               :old-text "old"
               :new-text "new"
               :source-file nil
               :status 'pending
               :timestamp (current-time))))
    (let ((entry (ogent-edit--format-log-entry edit)))
      (should (string-match-p ":SOURCE_FILE: (unsaved)" entry)))))

(ert-deftest ogent-edit-log-format-entry-all-statuses ()
  "Log entry format works for all status types."
  (dolist (status '(pending applied rejected error))
    (let ((edit (make-ogent-edit
                 :id (format "test-%s" status)
                 :old-text "old"
                 :new-text "new"
                 :source-file "/test.el"
                 :status status
                 :timestamp (current-time))))
      (let ((entry (ogent-edit--format-log-entry edit)))
        (should (string-match-p (format ":STATUS: %s" status) entry))))))

;;; Diff Formatting Tests

(ert-deftest ogent-edit-log-format-diff-single-line ()
  "Diff format works for single-line changes."
  (let ((diff (ogent-edit--format-diff "old line" "new line")))
    (should (string-match-p "^#\\+begin_src diff" diff))
    (should (string-match-p "^- old line$" diff))
    (should (string-match-p "^\\+ new line$" diff))
    (should (string-match-p "#\\+end_src$" diff))))

(ert-deftest ogent-edit-log-format-diff-multiline ()
  "Diff format works for multi-line changes."
  (let ((diff (ogent-edit--format-diff
               "line1\nline2\nline3"
               "new1\nnew2")))
    (should (string-match-p "^- line1$" diff))
    (should (string-match-p "^- line2$" diff))
    (should (string-match-p "^- line3$" diff))
    (should (string-match-p "^\\+ new1$" diff))
    (should (string-match-p "^\\+ new2$" diff))))

(ert-deftest ogent-edit-log-format-diff-empty-old ()
  "Diff format handles empty old text (pure addition)."
  (let ((diff (ogent-edit--format-diff "" "new content")))
    (should (string-match-p "#\\+begin_src diff" diff))
    (should (string-match-p "^\\+ new content$" diff))
    (should (string-match-p "#\\+end_src" diff))))

(ert-deftest ogent-edit-log-format-diff-empty-new ()
  "Diff format handles empty new text (pure deletion)."
  (let ((diff (ogent-edit--format-diff "old content" "")))
    (should (string-match-p "#\\+begin_src diff" diff))
    (should (string-match-p "^- old content$" diff))
    (should (string-match-p "#\\+end_src" diff))))

(ert-deftest ogent-edit-log-generate-diff-lines ()
  "Diff line generation produces correct prefix format."
  (let ((lines (ogent-edit--generate-diff-lines "a\nb" "x\ny\nz")))
    (should (string-match-p "^- a" lines))
    (should (string-match-p "^- b" lines))
    (should (string-match-p "^\\+ x" lines))
    (should (string-match-p "^\\+ y" lines))
    (should (string-match-p "^\\+ z" lines))))

;;; Log Marker Management Tests

(ert-deftest ogent-edit-log-store-marker ()
  "Log markers are stored correctly in companion buffer."
  (let ((source-buffer (get-buffer-create "*test-src-marker*"))
        (companion-buffer (get-buffer-create "*ogent:test-src-marker*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create edit and store marker
          (let ((edit (make-ogent-edit
                       :id "marker-test-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :status 'pending
                       :timestamp (current-time)))
                (test-marker (with-current-buffer companion-buffer
                               (point-max-marker))))
            (ogent-edit--store-log-marker edit test-marker)
            ;; Verify marker is in companion's local alist
            (with-current-buffer companion-buffer
              (should (assoc "marker-test-001" ogent-edit--log-markers)))
            ;; Verify marker is in edit struct
            (should (markerp (ogent-edit-companion-marker edit)))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-find-marker ()
  "Finding log markers retrieves stored markers."
  (let ((source-buffer (get-buffer-create "*test-find-marker*"))
        (companion-buffer (get-buffer-create "*ogent:test-find-marker*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Log proposal (which stores marker)
          (let ((edit (make-ogent-edit
                       :id "find-marker-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            ;; Find the marker
            (let ((found-marker (ogent-edit--find-log-marker edit)))
              (should (markerp found-marker))
              (should (eq (marker-buffer found-marker) companion-buffer)))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-find-marker-no-companion ()
  "Finding log marker returns nil when no companion exists."
  (let ((source-buffer (get-buffer-create "*test-no-companion*")))
    (unwind-protect
        (let ((edit (make-ogent-edit
                     :id "no-companion-001"
                     :old-text "old"
                     :new-text "new"
                     :source-buffer source-buffer
                     :status 'pending
                     :timestamp (current-time))))
          (should-not (ogent-edit--find-log-marker edit)))
      (kill-buffer source-buffer))))

;;; Proposal Logging Tests

(ert-deftest ogent-edit-log-proposal-appends-to-companion ()
  "Log proposal appends entry to end of companion buffer."
  (let ((source-buffer (get-buffer-create "*test-append*"))
        (companion-buffer (get-buffer-create "*ogent:test-append*")))
    (unwind-protect
        (progn
          ;; Set up companion with existing content
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n\nExisting content here.\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Log a proposal
          (let ((edit (make-ogent-edit
                       :id "append-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test.el"
                       :status 'pending
                       :timestamp (current-time)))
                (initial-size (with-current-buffer companion-buffer
                                (buffer-size))))
            (ogent-edit-log-proposal edit)
            ;; Buffer should have grown
            (with-current-buffer companion-buffer
              (should (> (buffer-size) initial-size))
              ;; New content should be at the end
              (goto-char (point-max))
              (should (re-search-backward "Edit: append-001" nil t)))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-proposal-no-companion ()
  "Log proposal does nothing when no companion buffer exists."
  (let ((source-buffer (get-buffer-create "*test-no-comp-log*")))
    (unwind-protect
        (let ((edit (make-ogent-edit
                     :id "no-comp-001"
                     :old-text "old"
                     :new-text "new"
                     :source-buffer source-buffer
                     :status 'pending
                     :timestamp (current-time))))
          ;; Should not error
          (ogent-edit-log-proposal edit))
      (kill-buffer source-buffer))))

;;; Resolution Logging Tests

(ert-deftest ogent-edit-log-resolution-updates-property ()
  "Log resolution updates the STATUS property in companion."
  (let ((source-buffer (get-buffer-create "*test-res-prop*"))
        (companion-buffer (get-buffer-create "*ogent:test-res-prop*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Log proposal then resolution
          (let ((edit (make-ogent-edit
                       :id "res-prop-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            (ogent-edit-log-resolution edit 'accepted)
            ;; Check STATUS was updated (with flexible whitespace)
            (with-current-buffer companion-buffer
              (should (string-match-p ":STATUS:\\s-*accepted" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-resolution-adds-timestamp ()
  "Log resolution adds a Resolution subheading with timestamp."
  (let ((source-buffer (get-buffer-create "*test-res-ts*"))
        (companion-buffer (get-buffer-create "*ogent:test-res-ts*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Log proposal then resolution
          (let ((edit (make-ogent-edit
                       :id "res-ts-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            (ogent-edit-log-resolution edit 'rejected)
            ;; Check Resolution subheading was added
            (with-current-buffer companion-buffer
              (should (string-match-p "\\*\\*\\* Resolution" (buffer-string)))
              ;; Check timestamp format
              (should (string-match-p "\\[[-0-9]+ [A-Z][a-z]+ [0-9]+:[0-9]+\\]"
                                      (buffer-string)))
              (should (string-match-p "Status: rejected" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-resolution-no-marker ()
  "Log resolution does nothing when marker is missing."
  (let ((source-buffer (get-buffer-create "*test-no-marker*")))
    (unwind-protect
        (let ((edit (make-ogent-edit
                     :id "no-marker-001"
                     :old-text "old"
                     :new-text "new"
                     :source-buffer source-buffer
                     :status 'pending
                     :timestamp (current-time))))
          ;; Should not error
          (ogent-edit-log-resolution edit 'accepted))
      (kill-buffer source-buffer))))

;;; Batch Logging Tests

(ert-deftest ogent-edit-log-all-proposals ()
  "Batch logging logs multiple edits."
  (let ((source-buffer (get-buffer-create "*test-batch*"))
        (companion-buffer (get-buffer-create "*ogent:test-batch*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create multiple edits
          (let ((edits (list
                        (make-ogent-edit
                         :id "batch-001"
                         :old-text "old1"
                         :new-text "new1"
                         :source-buffer source-buffer
                         :source-file "/test.el"
                         :status 'pending
                         :timestamp (current-time))
                        (make-ogent-edit
                         :id "batch-002"
                         :old-text "old2"
                         :new-text "new2"
                         :source-buffer source-buffer
                         :source-file "/test.el"
                         :status 'pending
                         :timestamp (current-time))
                        (make-ogent-edit
                         :id "batch-003"
                         :old-text "old3"
                         :new-text "new3"
                         :source-buffer source-buffer
                         :source-file "/test.el"
                         :status 'pending
                         :timestamp (current-time)))))
            (ogent-edit-log-all-proposals edits)
            ;; All should be logged
            (with-current-buffer companion-buffer
              (should (string-match-p "Edit: batch-001" (buffer-string)))
              (should (string-match-p "Edit: batch-002" (buffer-string)))
              (should (string-match-p "Edit: batch-003" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-errors ()
  "Error logging creates error section for failed edits."
  (let ((source-buffer (get-buffer-create "*test-errors*"))
        (companion-buffer (get-buffer-create "*ogent:test-errors*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create edits with some errors
          (let ((edits (list
                        (make-ogent-edit
                         :id "err-001"
                         :old-text "old1"
                         :new-text "new1"
                         :source-buffer source-buffer
                         :status 'error
                         :error-message "Text not found"
                         :timestamp (current-time))
                        (make-ogent-edit
                         :id "err-002"
                         :old-text "old2"
                         :new-text "new2"
                         :source-buffer source-buffer
                         :status 'pending
                         :timestamp (current-time))
                        (make-ogent-edit
                         :id "err-003"
                         :old-text "old3"
                         :new-text "new3"
                         :source-buffer source-buffer
                         :status 'error
                         :error-message "Multiple matches"
                         :timestamp (current-time)))))
            (ogent-edit-log-errors edits)
            ;; Error section should exist
            (with-current-buffer companion-buffer
              (should (string-match-p "\\*\\* Edit Errors" (buffer-string)))
              (should (string-match-p "err-001: Text not found" (buffer-string)))
              (should (string-match-p "err-003: Multiple matches" (buffer-string)))
              ;; Non-error edit should not appear in errors section
              (should-not (string-match-p "err-002:" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-errors-no-errors ()
  "Error logging does nothing when there are no errors."
  (let ((source-buffer (get-buffer-create "*test-no-errors*"))
        (companion-buffer (get-buffer-create "*ogent:test-no-errors*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create edits with no errors
          (let ((edits (list
                        (make-ogent-edit
                         :id "ok-001"
                         :old-text "old"
                         :new-text "new"
                         :source-buffer source-buffer
                         :status 'pending
                         :timestamp (current-time))))
                (initial-content (with-current-buffer companion-buffer
                                   (buffer-string))))
            (ogent-edit-log-errors edits)
            ;; Buffer should be unchanged
            (with-current-buffer companion-buffer
              (should (string= initial-content (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

;;; Hook Integration Tests

(ert-deftest ogent-edit-log-hook-registered ()
  "The logging hook is registered in ogent-edit-resolved-hook."
  (should (memq #'ogent-edit--log-resolved ogent-edit-resolved-hook)))

(ert-deftest ogent-edit-log-hook-function-logs ()
  "The hook function logs resolution correctly."
  (let ((source-buffer (get-buffer-create "*test-hook-fn*"))
        (companion-buffer (get-buffer-create "*ogent:test-hook-fn*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create and log edit
          (let ((edit (make-ogent-edit
                       :id "hook-fn-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            ;; Simulate resolution
            (setf (ogent-edit-status edit) 'applied)
            (ogent-edit--log-resolved edit)
            ;; Check resolution was logged
            (with-current-buffer companion-buffer
              (should (string-match-p ":STATUS:\\s-*applied" (buffer-string)))
              (should (string-match-p "\\*\\*\\* Resolution" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(provide 'ogent-edit-log-tests)
;;; ogent-edit-log-tests.el ends here
