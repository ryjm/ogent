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

;;; Companion Buffer Logging Integration Tests

(ert-deftest ogent-edit-log-proposal-creates-entry ()
  "Logging a proposal creates an Org entry in companion buffer."
  (let ((source-buffer (get-buffer-create "*test-source-log*"))
        (companion-buffer (get-buffer-create "*ogent:test-source-log*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test Session\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create and log an edit
          (let ((edit (make-ogent-edit
                       :id "test-log-001"
                       :old-text "old code"
                       :new-text "new code"
                       :source-buffer source-buffer
                       :source-file "/test/file.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            ;; Verify companion buffer has the entry
            (with-current-buffer companion-buffer
              (should (string-match-p "\\*\\* Edit: test-log-001" (buffer-string)))
              (should (string-match-p ":OGENT_EDIT_ID: test-log-001" (buffer-string)))
              (should (string-match-p ":SOURCE_FILE: /test/file.el" (buffer-string)))
              (should (string-match-p ":STATUS: pending" (buffer-string)))
              (should (string-match-p "\\*\\*\\* Proposed Change" (buffer-string)))
              (should (string-match-p "#\\+begin_src diff" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-resolution-updates-status ()
  "Logging a resolution updates STATUS property and adds timestamp."
  (let ((source-buffer (get-buffer-create "*test-source-res*"))
        (companion-buffer (get-buffer-create "*ogent:test-source-res*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test Session\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create, log proposal, then log resolution
          (let ((edit (make-ogent-edit
                       :id "test-res-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test/file.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            ;; Now resolve it
            (ogent-edit-log-resolution edit 'accepted)
            ;; Verify resolution was logged
            ;; Note: org-set-property may add padding, so use flexible match
            (with-current-buffer companion-buffer
              (should (string-match-p ":STATUS:\\s-*accepted" (buffer-string)))
              (should (string-match-p "\\*\\*\\* Resolution" (buffer-string)))
              (should (string-match-p "Status: accepted" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-resolution-rejected ()
  "Rejected edits are logged with rejected status."
  (let ((source-buffer (get-buffer-create "*test-source-rej*"))
        (companion-buffer (get-buffer-create "*ogent:test-source-rej*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test Session\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create, log proposal, then reject
          (let ((edit (make-ogent-edit
                       :id "test-rej-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test/file.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            (ogent-edit-log-resolution edit 'rejected)
            ;; Verify rejection was logged
            ;; Note: org-set-property may add padding, so use flexible match
            (with-current-buffer companion-buffer
              (should (string-match-p ":STATUS:\\s-*rejected" (buffer-string)))
              (should (string-match-p "Status: rejected" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-log-marker-stored ()
  "Log marker is stored in edit struct for navigation."
  (let ((source-buffer (get-buffer-create "*test-source-marker*"))
        (companion-buffer (get-buffer-create "*ogent:test-source-marker*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test Session\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create and log an edit
          (let ((edit (make-ogent-edit
                       :id "test-marker-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test/file.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            ;; Verify marker was stored
            (should (ogent-edit-companion-marker edit))
            (should (markerp (ogent-edit-companion-marker edit)))
            (should (eq (marker-buffer (ogent-edit-companion-marker edit))
                        companion-buffer))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-resolved-hook-logs-resolution ()
  "The resolved hook triggers logging to companion buffer."
  (let ((source-buffer (get-buffer-create "*test-source-hook*"))
        (companion-buffer (get-buffer-create "*ogent:test-source-hook*")))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test Session\n\n* Session\n"))
          (with-current-buffer source-buffer
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create and log an edit
          (let ((edit (make-ogent-edit
                       :id "test-hook-001"
                       :old-text "old"
                       :new-text "new"
                       :source-buffer source-buffer
                       :source-file "/test/file.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-log-proposal edit)
            ;; Simulate resolution via hook (as if smerge resolved)
            (setf (ogent-edit-status edit) 'accepted)
            (run-hook-with-args 'ogent-edit-resolved-hook edit)
            ;; Verify resolution was logged via hook
            (with-current-buffer companion-buffer
              (should (string-match-p ":STATUS:\\s-*accepted" (buffer-string)))
              (should (string-match-p "\\*\\*\\* Resolution" (buffer-string))))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-accept-current-triggers-hook ()
  "Accepting an edit via ogent-edit-accept-current triggers the resolved hook."
  (let ((source-buffer (get-buffer-create "*test-accept*"))
        (companion-buffer (get-buffer-create "*ogent:test-accept*"))
        (hook-called nil))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test Session\n\n* Session\n"))
          (with-current-buffer source-buffer
            (emacs-lisp-mode)
            (insert "(defun foo () nil)")
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create edit, validate, and apply as smerge
          (let ((edit (make-ogent-edit
                       :id "test-accept-001"
                       :old-text "(defun foo () nil)"
                       :new-text "(defun foo () t)"
                       :source-buffer source-buffer
                       :source-file "/test/file.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-validate edit)
            (ogent-edit-log-proposal edit)
            (ogent-edit-apply-as-smerge edit)
            ;; Track pending edits and add hook in source buffer
            (with-current-buffer source-buffer
              (setq ogent-edit--pending-edits (list edit))
              ;; Add test hook to verify it's called (global, not buffer-local)
              (add-hook 'ogent-edit-resolved-hook
                        (lambda (e) (setq hook-called (ogent-edit-status e)))))
            ;; Accept the edit
            (with-current-buffer source-buffer
              (goto-char (point-min))
              (smerge-next)
              (ogent-edit-accept-current))
            ;; Verify hook was called with accepted status
            (should (eq hook-called 'accepted))
            ;; Verify companion was updated
            (with-current-buffer companion-buffer
              (should (string-match-p ":STATUS:\\s-*accepted" (buffer-string))))))
      ;; Clean up hook
      (remove-hook 'ogent-edit-resolved-hook
                   (lambda (e) (setq hook-called (ogent-edit-status e))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

(ert-deftest ogent-edit-reject-current-triggers-hook ()
  "Rejecting an edit via ogent-edit-reject-current triggers the resolved hook."
  (let ((source-buffer (get-buffer-create "*test-reject*"))
        (companion-buffer (get-buffer-create "*ogent:test-reject*"))
        (hook-called nil))
    (unwind-protect
        (progn
          ;; Set up companion link
          (with-current-buffer companion-buffer
            (org-mode)
            (insert "#+title: Test Session\n\n* Session\n"))
          (with-current-buffer source-buffer
            (emacs-lisp-mode)
            (insert "(defun bar () nil)")
            (setq-local ogent-companion--linked-buffer companion-buffer))
          (with-current-buffer companion-buffer
            (setq-local ogent-companion--linked-buffer source-buffer))
          ;; Create edit, validate, and apply as smerge
          (let ((edit (make-ogent-edit
                       :id "test-reject-001"
                       :old-text "(defun bar () nil)"
                       :new-text "(defun bar () t)"
                       :source-buffer source-buffer
                       :source-file "/test/file.el"
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-validate edit)
            (ogent-edit-log-proposal edit)
            (ogent-edit-apply-as-smerge edit)
            ;; Track pending edits and add hook in source buffer
            (with-current-buffer source-buffer
              (setq ogent-edit--pending-edits (list edit))
              ;; Add test hook to verify it's called (global, not buffer-local)
              (add-hook 'ogent-edit-resolved-hook
                        (lambda (e) (setq hook-called (ogent-edit-status e)))))
            ;; Reject the edit
            (with-current-buffer source-buffer
              (goto-char (point-min))
              (smerge-next)
              (ogent-edit-reject-current))
            ;; Verify hook was called with rejected status
            (should (eq hook-called 'rejected))
            ;; Verify companion was updated
            (with-current-buffer companion-buffer
              (should (string-match-p ":STATUS:\\s-*rejected" (buffer-string))))))
      ;; Clean up hook
      (remove-hook 'ogent-edit-resolved-hook
                   (lambda (e) (setq hook-called (ogent-edit-status e))))
      (kill-buffer source-buffer)
      (kill-buffer companion-buffer))))

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

(ert-deftest ogent-edit-request-sends-to-gptel ()
  "ogent-request-edit sends request via gptel with proper prompt and system."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "(defun foo () nil)"))
          (with-current-buffer (find-file-noselect temp-file)
            (emacs-lisp-mode)
            (ogent-test-with-mock-gptel
             (ogent-request-edit "Fix this")
             (let* ((captured (ogent-test-last-request))
                    (prompt (plist-get captured :prompt))
                    (args (plist-get captured :args))
                    (system (plist-get args :system)))
               (should captured)
               (should (string-match-p "Fix this" prompt))
               (should (string-match-p "SEARCH/REPLACE" system))
               (should (plist-get args :stream))
               (should (plist-get args :callback))))
            (kill-buffer)))
      (delete-file temp-file))))

(ert-deftest ogent-edit-request-uses-explicit-bounds ()
  "ogent-request-edit can send a focused buffer slice."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "(defun first () nil)\n\n(defun second () t)\n"))
          (with-current-buffer (find-file-noselect temp-file)
            (emacs-lisp-mode)
            (let ((start (point-min))
                  (end (save-excursion
                         (goto-char (point-min))
                         (search-forward "\n\n")
                         (match-beginning 0))))
              (ogent-test-with-mock-gptel
                (ogent-request-edit "Return t" start end)
                (let* ((captured (ogent-test-last-request))
                       (prompt (plist-get captured :prompt)))
                  (should captured)
                  (should (string-match-p "defun first" prompt))
                  (should-not (string-match-p "defun second" prompt))
                  (should (= (plist-get ogent-edit--pending-request :region-start)
                             start))
                  (should (= (plist-get ogent-edit--pending-request :region-end)
                             end)))))
            (kill-buffer)))
      (delete-file temp-file))))

(ert-deftest ogent-edit-quick-target-prefers-region ()
  "Quick edit targets the active region first."
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (goto-char (point-min))
    (push-mark (+ (point-min) 5) t t)
    (activate-mark)
    (let ((target (ogent-edit--quick-target)))
      (should (eq (plist-get target :scope) 'region))
      (should (= (plist-get target :start) (point-min)))
      (should (= (plist-get target :end) (+ (point-min) 5))))))

(ert-deftest ogent-edit-quick-target-uses-defun-at-point ()
  "Quick edit targets the current defun when no region is active."
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun first ()\n  nil)\n\n(defun second ()\n  t)\n")
    (goto-char (point-min))
    (search-forward "nil")
    (let ((target (ogent-edit--quick-target)))
      (should (eq (plist-get target :scope) 'defun))
      (should (string-match-p
               "defun first"
               (buffer-substring-no-properties
                (plist-get target :start)
                (plist-get target :end))))
      (should-not (string-match-p
                   "defun second"
                   (buffer-substring-no-properties
                    (plist-get target :start)
                    (plist-get target :end)))))))

(ert-deftest ogent-edit-quick-target-falls-back-to-line ()
  "Quick edit targets the current line when no defun is available."
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (goto-char (point-min))
    (forward-line 1)
    (cl-letf (((symbol-function 'mark-defun)
               (lambda (&rest _args)
                 (user-error "No defun"))))
      (let ((target (ogent-edit--quick-target)))
        (should (eq (plist-get target :scope) 'line))
        (should (string= "beta"
                         (buffer-substring-no-properties
                          (plist-get target :start)
                          (plist-get target :end))))))))

(ert-deftest ogent-edit-quick-edit-sends-focused-target ()
  "ogent-quick-edit sends only the selected quick edit target."
  (let ((temp-file (make-temp-file "ogent-test" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "(defun first ()\n  nil)\n\n(defun second ()\n  t)\n"))
          (with-current-buffer (find-file-noselect temp-file)
            (emacs-lisp-mode)
            (goto-char (point-min))
            (search-forward "nil")
            (ogent-test-with-mock-gptel
              (ogent-quick-edit "Return t")
              (let* ((captured (ogent-test-last-request))
                     (prompt (plist-get captured :prompt)))
                (should captured)
                (should (string-match-p "Return t" prompt))
                (should (string-match-p "defun first" prompt))
                (should-not (string-match-p "defun second" prompt))))
            (kill-buffer)))
      (delete-file temp-file))))

;;; Coverage Expansion Tests for ogent-edit.el

(ert-deftest ogent-edit-make-callback-accumulates-streaming ()
  "The streaming callback accumulates text during streaming."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request nil))
    (let ((callback (ogent-edit--make-callback)))
      ;; Simulate streaming chunks -- info is non-nil to indicate "not done yet"
      ;; Using (:status "streaming") to indicate an in-progress state
      (funcall callback "chunk1" '(:status "streaming"))
      (should (string= ogent-edit--streaming-response "chunk1"))
      (funcall callback "chunk2" '(:status "streaming"))
      (should (string= ogent-edit--streaming-response "chunk1chunk2")))))

(ert-deftest ogent-edit-make-callback-handles-error ()
  "The streaming callback handles error info."
  (let ((ogent-edit--streaming-response "partial")
        (ogent-edit--pending-request nil))
    (let ((callback (ogent-edit--make-callback)))
      (funcall callback nil '(:error "Request failed"))
      ;; Response should be reset on error
      (should (string= ogent-edit--streaming-response "")))))

(ert-deftest ogent-edit-make-callback-processes-on-done ()
  "The streaming callback processes response on :done."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (processed nil))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (response)
                 (setq processed response))))
      (let ((callback (ogent-edit--make-callback)))
        ;; Accumulate some text first
        (funcall callback "some response" nil)
        ;; Then signal done
        (funcall callback nil '(:done t))
        (should (string= processed "some response"))
        ;; Streaming response should be reset
        (should (string= ogent-edit--streaming-response ""))))))

(ert-deftest ogent-edit-make-callback-handles-processing-error ()
  "The callback catches errors in ogent-edit--process-response."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer))))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (_response)
                 (error "Processing exploded"))))
      (let ((callback (ogent-edit--make-callback)))
        (funcall callback "response text" nil)
        ;; Should not signal -- error is caught
        (funcall callback nil '(:done t))
        ;; Response should be reset even after error
        (should (string= ogent-edit--streaming-response ""))))))

(ert-deftest ogent-edit-auto-apply-edit-success ()
  "Auto-apply replaces text in buffer and marks accepted."
  (let ((source-buffer (get-buffer-create "*test-auto-apply*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "old code here"))
          (let ((edit (make-ogent-edit
                       :id "aa-001"
                       :old-text "old code here"
                       :new-text "new code here"
                       :source-buffer source-buffer
                       :status 'pending
                       :timestamp (current-time))))
            (ogent-edit-validate edit)
            (should (ogent-edit-auto-apply-edit edit))
            (should (eq (ogent-edit-status edit) 'accepted))
            (with-current-buffer source-buffer
              (should (string= (buffer-string) "new code here")))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-auto-apply-edit-not-pending ()
  "Auto-apply returns nil for non-pending edits."
  (let ((edit (make-ogent-edit
               :id "aa-002"
               :old-text "old"
               :new-text "new"
               :source-buffer (current-buffer)
               :start-pos 1
               :end-pos 4
               :status 'accepted
               :timestamp (current-time))))
    (should-not (ogent-edit-auto-apply-edit edit))))

(ert-deftest ogent-edit-auto-apply-edit-invalid ()
  "Auto-apply returns nil for invalid edits (no positions)."
  (let ((edit (make-ogent-edit
               :id "aa-003"
               :old-text "old"
               :new-text "new"
               :source-buffer (current-buffer)
               :status 'pending
               :timestamp (current-time))))
    ;; No start-pos/end-pos -- not valid
    (should-not (ogent-edit-auto-apply-edit edit))))

(ert-deftest ogent-edit-auto-apply-all-multiple ()
  "Auto-apply-all applies multiple edits in correct order."
  (let ((source-buffer (get-buffer-create "*test-auto-apply-all*")))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "AAA\nBBB\nCCC"))
          (let ((edit1 (make-ogent-edit
                        :id "aal-001"
                        :old-text "AAA"
                        :new-text "111"
                        :source-buffer source-buffer
                        :status 'pending
                        :timestamp (current-time)))
                (edit2 (make-ogent-edit
                        :id "aal-002"
                        :old-text "CCC"
                        :new-text "333"
                        :source-buffer source-buffer
                        :status 'pending
                        :timestamp (current-time))))
            (ogent-edit-validate edit1)
            (ogent-edit-validate edit2)
            (let ((count (ogent-edit-auto-apply-all (list edit1 edit2))))
              (should (= count 2))
              (with-current-buffer source-buffer
                (should (string= (buffer-string) "111\nBBB\n333"))))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-auto-apply-all-returns-zero-for-empty ()
  "Auto-apply-all returns 0 for empty list."
  (should (= 0 (ogent-edit-auto-apply-all nil))))

(ert-deftest ogent-edit-process-response-auto-apply ()
  "Process response in auto-apply mode directly applies edits."
  (let ((source-buffer (get-buffer-create "*test-process-auto*"))
        (ogent-edit-auto-apply t)
        (ogent-edit-auto-display nil)
        (ogent-edit-log-to-companion nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "(defun foo () nil)"))
          (let ((ogent-edit--pending-request
                 (list :source-buffer source-buffer)))
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
              (let ((edits (ogent-edit--process-response
                            "<<<<<<< SEARCH\n(defun foo () nil)\n=======\n(defun foo () t)\n>>>>>>> REPLACE")))
                (should (= (length edits) 1))
                ;; The edit should be applied
                (with-current-buffer source-buffer
                  (should (string= (buffer-string) "(defun foo () t)")))))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-process-response-no-valid-edits ()
  "Process response with no valid edits shows message."
  (let ((source-buffer (get-buffer-create "*test-process-empty*"))
        (ogent-edit-auto-apply nil)
        (ogent-edit-auto-display t)
        (ogent-edit-log-to-companion nil))
    (unwind-protect
        (progn
          (with-current-buffer source-buffer
            (insert "nothing matches"))
          (let ((ogent-edit--pending-request
                 (list :source-buffer source-buffer)))
            ;; Response with SEARCH text not found in buffer
            (let ((edits (ogent-edit--process-response
                          "<<<<<<< SEARCH\nnonexistent text\n=======\nreplacement\n>>>>>>> REPLACE")))
              ;; Should have 1 edit but it's an error
              (should (= (length edits) 1))
              (should (ogent-edit-error-p (car edits))))))
      (kill-buffer source-buffer))))

(ert-deftest ogent-edit-pending-count-smerge ()
  "Pending count works for smerge display method."
  (let ((ogent-edit-display-method 'smerge))
    ;; Mock ogent-edit-count-pending
    (cl-letf (((symbol-function 'ogent-edit-count-pending)
               (lambda () 3)))
      (should (= (ogent-edit--pending-count) 3)))))

(ert-deftest ogent-edit-pending-count-overlay ()
  "Pending count works for overlay display method."
  (let ((ogent-edit-display-method 'overlay)
        (ogent-edit--overlay-list '(ov1 ov2)))
    (should (= (ogent-edit--pending-count) 2))))

(ert-deftest ogent-edit-dispatch-functions-call-smerge-methods ()
  "Dispatch functions route to smerge methods when display-method is smerge."
  (let ((ogent-edit-display-method 'smerge)
        (called nil))
    ;; Test accept dispatch
    (cl-letf (((symbol-function 'ogent-edit-accept-current)
               (lambda () (setq called 'accept-current))))
      (ogent-edit--accept-current-dispatch)
      (should (eq called 'accept-current)))
    ;; Test reject dispatch
    (cl-letf (((symbol-function 'ogent-edit-reject-current)
               (lambda () (setq called 'reject-current))))
      (ogent-edit--reject-current-dispatch)
      (should (eq called 'reject-current)))
    ;; Test next dispatch
    (cl-letf (((symbol-function 'smerge-next)
               (lambda () (setq called 'smerge-next))))
      (ogent-edit--next-dispatch)
      (should (eq called 'smerge-next)))
    ;; Test prev dispatch
    (cl-letf (((symbol-function 'smerge-prev)
               (lambda () (setq called 'smerge-prev))))
      (ogent-edit--prev-dispatch)
      (should (eq called 'smerge-prev)))
    ;; Test accept all dispatch
    (cl-letf (((symbol-function 'ogent-edit-accept-all)
               (lambda () (setq called 'accept-all))))
      (ogent-edit--accept-all-dispatch)
      (should (eq called 'accept-all)))
    ;; Test reject all dispatch
    (cl-letf (((symbol-function 'ogent-edit-reject-all)
               (lambda () (setq called 'reject-all))))
      (ogent-edit--reject-all-dispatch)
      (should (eq called 'reject-all)))))

(ert-deftest ogent-edit-dispatch-functions-call-overlay-methods ()
  "Dispatch functions route to overlay methods when display-method is overlay."
  (let ((ogent-edit-display-method 'overlay)
        (called nil))
    (cl-letf (((symbol-function 'ogent-edit-overlay-accept)
               (lambda () (setq called 'ov-accept))))
      (ogent-edit--accept-current-dispatch)
      (should (eq called 'ov-accept)))
    (cl-letf (((symbol-function 'ogent-edit-overlay-reject)
               (lambda () (setq called 'ov-reject))))
      (ogent-edit--reject-current-dispatch)
      (should (eq called 'ov-reject)))
    (cl-letf (((symbol-function 'ogent-edit-overlay-next)
               (lambda () (setq called 'ov-next))))
      (ogent-edit--next-dispatch)
      (should (eq called 'ov-next)))
    (cl-letf (((symbol-function 'ogent-edit-overlay-previous)
               (lambda () (setq called 'ov-prev))))
      (ogent-edit--prev-dispatch)
      (should (eq called 'ov-prev)))
    (cl-letf (((symbol-function 'ogent-edit-overlay-accept-all)
               (lambda () (setq called 'ov-accept-all))))
      (ogent-edit--accept-all-dispatch)
      (should (eq called 'ov-accept-all)))
    (cl-letf (((symbol-function 'ogent-edit-overlay-reject-all)
               (lambda () (setq called 'ov-reject-all))))
      (ogent-edit--reject-all-dispatch)
      (should (eq called 'ov-reject-all)))))

(ert-deftest ogent-edit-show-diff-buffer-errors-when-empty ()
  "Show diff buffer errors when no pending edits."
  (let ((ogent-edit--pending-edits nil))
    (should-error (ogent-edit-show-diff-buffer) :type 'user-error)))

(ert-deftest ogent-edit-ensure-gptel-errors-without-gptel ()
  "Ensure gptel signals error when gptel not available."
  (cl-letf (((symbol-function 'require)
             (lambda (feature &optional _filename _noerror)
               (when (eq feature 'gptel) nil))))
    (should-error (ogent-edit--ensure-gptel) :type 'user-error)))

;;; Streaming Edge Case Tests for ogent-edit callback

(ert-deftest ogent-edit-callback-completes-on-final-marker ()
  "Edit callback should trigger processing on :final marker."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (processed nil))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (response)
                 (setq processed response))))
      (let ((callback (ogent-edit--make-callback)))
        (funcall callback "response via final" nil)
        (funcall callback nil '(:final t))
        (should (equal processed "response via final"))
        (should (string= ogent-edit--streaming-response ""))))))

(ert-deftest ogent-edit-callback-completes-on-status-success ()
  "Edit callback should trigger processing on :status \"success\"."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (processed nil))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (response)
                 (setq processed response))))
      (let ((callback (ogent-edit--make-callback)))
        (funcall callback "status complete" nil)
        (funcall callback nil '(:status "success"))
        (should (equal processed "status complete"))))))

(ert-deftest ogent-edit-callback-non-streaming-single-response ()
  "Edit callback should handle non-streaming mode (text + nil info)."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (processed nil))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (response)
                 (setq processed response))))
      (let ((callback (ogent-edit--make-callback)))
        ;; Non-streaming: full response with nil info triggers completion
        (funcall callback "full edit response" nil)
        (should (equal processed "full edit response"))))))

(ert-deftest ogent-edit-callback-empty-response-on-done ()
  "Edit callback should skip processing when response is empty at completion."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (processed nil))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (response)
                 (setq processed response))))
      (let ((callback (ogent-edit--make-callback)))
        ;; Done with no accumulated content
        (funcall callback nil '(:done t))
        (should-not processed)))))

(ert-deftest ogent-edit-callback-error-resets-then-fresh-accumulation ()
  "After error resets accumulator, subsequent streaming processes fresh data."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (processed nil))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (response)
                 (setq processed response))))
      (let ((callback (ogent-edit--make-callback)))
        ;; First: partial + error
        (funcall callback "stale" nil)
        (funcall callback nil '(:error "timeout"))
        (should (string= ogent-edit--streaming-response ""))
        ;; Second: fresh data
        (funcall callback "fresh" nil)
        (funcall callback nil '(:done t))
        (should (equal processed "fresh"))))))

(ert-deftest ogent-edit-callback-nil-text-during-streaming ()
  "Edit callback handles nil text chunks without corruption."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (processed-list nil))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (response)
                 (push response processed-list))))
      (let ((callback (ogent-edit--make-callback)))
        ;; In non-streaming mode, each (text nil) triggers processing.
        ;; nil text should not trigger processing or corrupt state.
        (funcall callback "part1" nil)
        ;; nil text shouldn't trigger processing
        (funcall callback nil nil)
        (funcall callback "part2" nil)
        ;; Both text chunks triggered processing individually
        (should (member "part1" processed-list))
        (should (member "part2" processed-list))
        ;; nil text did not produce a spurious processing call
        (should (= 2 (length processed-list)))))))

(ert-deftest ogent-edit-callback-multiple-processing-errors ()
  "Edit callback gracefully handles repeated processing errors."
  (let ((ogent-edit--streaming-response "")
        (ogent-edit--pending-request
         (list :source-buffer (current-buffer)))
        (error-count 0))
    (cl-letf (((symbol-function 'ogent-edit--process-response)
               (lambda (_response)
                 (setq error-count (1+ error-count))
                 (error "Parse error #%d" error-count))))
      (let ((callback (ogent-edit--make-callback)))
        ;; First attempt
        (funcall callback "data1" nil)
        (funcall callback nil '(:done t))
        (should (= error-count 1))
        (should (string= ogent-edit--streaming-response ""))
        ;; Second attempt - should also handle gracefully
        (funcall callback "data2" nil)
        (funcall callback nil '(:done t))
        (should (= error-count 2))
        (should (string= ogent-edit--streaming-response ""))))))

(provide 'ogent-edit-tests)
;;; ogent-edit-tests.el ends here
