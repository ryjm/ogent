;;; ogent-companion-tests.el --- Tests for companion buffer management -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-companion)
(require 'org)

(ert-deftest ogent-companion-detects-org-buffer ()
  "Detect when a buffer is in org-mode."
  (let ((org-buffer (get-buffer-create "*test-org*"))
        (text-buffer (get-buffer-create "*test-text*")))
    (unwind-protect
        (progn
          (with-current-buffer org-buffer
            (org-mode)
            (should (ogent-companion--org-buffer-p)))
          (with-current-buffer text-buffer
            (fundamental-mode)
            (should-not (ogent-companion--org-buffer-p))))
      (kill-buffer org-buffer)
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-returns-org-buffer-as-is ()
  "When invoked in an Org buffer, return that buffer directly."
  (let ((org-buffer (get-buffer-create "*test-org*")))
    (unwind-protect
        (with-current-buffer org-buffer
          (org-mode)
          (should (eq (ogent-companion-get-or-create) org-buffer)))
      (kill-buffer org-buffer))))

(ert-deftest ogent-companion-creates-for-non-org ()
  "When invoked in a non-Org buffer, create a companion Org buffer."
  (let ((text-buffer (get-buffer-create "*test-text*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (should (buffer-live-p companion))
            (should-not (eq companion text-buffer))
            (should (string-prefix-p "*ogent:" (buffer-name companion)))
            (with-current-buffer companion
              (should (derived-mode-p 'org-mode)))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-reuses-existing ()
  "Companion buffers are reused for the same source buffer."
  (let ((text-buffer (get-buffer-create "*test-text*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let* ((companion1 (ogent-companion-get-or-create))
                 (companion2 (ogent-companion-get-or-create)))
            (should (eq companion1 companion2))
            (kill-buffer companion1)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-bidirectional-linking ()
  "Source and companion buffers have bidirectional links."
  (let ((text-buffer (get-buffer-create "*test-text*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (should (eq (ogent-companion--get-linked-buffer text-buffer) companion))
            (should (eq (ogent-companion--get-linked-buffer companion) text-buffer))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-source-buffer-returns-original ()
  "ogent-companion-source-buffer returns the source for a companion."
  (let ((text-buffer (get-buffer-create "*test-text*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (should (eq (ogent-companion-source-buffer companion) text-buffer))
            (should (eq (ogent-companion-source-buffer text-buffer) text-buffer))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-initializes-with-header ()
  "Newly created companion buffers have a basic Org header."
  (let ((text-buffer (get-buffer-create "*test-text*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (with-current-buffer companion
              (goto-char (point-min))
              (should (looking-at "#\\+title:"))
              (should (search-forward "* Session" nil t)))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-naming-uses-file-name ()
  "Companion buffer name uses file name when available."
  (let ((file-buffer (find-file-noselect (make-temp-file "ogent-test" nil ".txt"))))
    (unwind-protect
        (with-current-buffer file-buffer
          (fundamental-mode)
          (let* ((filename (file-name-nondirectory (buffer-file-name)))
                 (expected-name (format "*ogent:%s*" filename))
                 (companion (ogent-companion-get-or-create)))
            (should (string= (buffer-name companion) expected-name))
            (kill-buffer companion)))
      (let ((file (buffer-file-name file-buffer)))
        (kill-buffer file-buffer)
        (delete-file file)))))

(ert-deftest ogent-companion-saves-link-to-file-local ()
  "Companion link is saved to buffer-local variable."
  (let ((file-buffer (find-file-noselect (make-temp-file "ogent-test" nil ".txt"))))
    (unwind-protect
        (with-current-buffer file-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            ;; Link should be saved automatically
            (should (local-variable-p 'ogent-companion-file))
            (should ogent-companion-file)
            (should (or (string-prefix-p "*ogent:" ogent-companion-file)
			(file-name-absolute-p ogent-companion-file)))
            (kill-buffer companion)))
      (let ((file (buffer-file-name file-buffer)))
        (kill-buffer file-buffer)
        (delete-file file)))))

(ert-deftest ogent-companion-identifier-for-temp-buffer ()
  "Get companion identifier returns buffer name for temp buffers."
  (let ((temp-buffer (get-buffer-create "*test-temp*")))
    (unwind-protect
        (should (string= (ogent-companion--get-companion-identifier temp-buffer)
                         "*test-temp*"))
      (kill-buffer temp-buffer))))

(ert-deftest ogent-companion-identifier-for-file-buffer ()
  "Get companion identifier returns file path for file buffers."
  (let ((file-buffer (find-file-noselect (make-temp-file "ogent-test" nil ".txt"))))
    (unwind-protect
        (let ((identifier (ogent-companion--get-companion-identifier file-buffer)))
          (should (file-name-absolute-p identifier))
          (should (file-exists-p identifier)))
      (let ((file (buffer-file-name file-buffer)))
        (kill-buffer file-buffer)
        (delete-file file)))))

(ert-deftest ogent-companion-find-from-buffer-name ()
  "Find or create companion from buffer name identifier."
  (let ((identifier "*ogent:test-buffer.el*"))
    (unwind-protect
        (let ((companion (ogent-companion--find-or-create-from-identifier identifier)))
          (should (buffer-live-p companion))
          (should (string= (buffer-name companion) identifier))
          (kill-buffer companion))
      (when (get-buffer identifier)
        (kill-buffer identifier)))))

(ert-deftest ogent-companion-find-from-file-path ()
  "Find or create companion from file path identifier."
  (let* ((temp-file (make-temp-file "ogent-test" nil ".org"))
         (identifier temp-file))
    (unwind-protect
        (progn
          ;; Create the file first
          (with-temp-file temp-file
            (insert "#+title: Test\n"))
          (let ((companion (ogent-companion--find-or-create-from-identifier identifier)))
            (should (buffer-live-p companion))
            (should (string= (buffer-file-name companion) temp-file))
            (kill-buffer companion)))
      (when (file-exists-p temp-file)
        (delete-file temp-file)))))

(ert-deftest ogent-companion-restore-link-creates-companion ()
  "Restoring a link creates the companion buffer if it doesn't exist."
  (let ((text-buffer (get-buffer-create "*test-restore*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          ;; Manually set the file-local variable
          (setq-local ogent-companion-file "*ogent:test-restore*")
          ;; Simulate the restore hook
          (ogent-companion--restore-link)
          ;; Should have created and linked the companion
          (should (buffer-live-p ogent-companion--linked-buffer))
          (should (string= (buffer-name ogent-companion--linked-buffer)
                           "*ogent:test-restore*"))
          (kill-buffer ogent-companion--linked-buffer))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-persistence-disabled ()
  "Persistence can be disabled via customization."
  (let ((ogent-companion-persist-links nil)
        (file-buffer (find-file-noselect (make-temp-file "ogent-test" nil ".txt"))))
    (unwind-protect
        (with-current-buffer file-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            ;; Link should NOT be saved when persistence is disabled
            (should-not ogent-companion-file)
            (kill-buffer companion)))
      (let ((file (buffer-file-name file-buffer)))
        (kill-buffer file-buffer)
        (delete-file file)))))

(ert-deftest ogent-companion-rebind-changes-link ()
  "Rebinding companion changes the linked buffer."
  (let ((text-buffer (get-buffer-create "*test-rebind*"))
        (org1 (get-buffer-create "*org1*"))
        (org2 (get-buffer-create "*org2*")))
    (unwind-protect
        (progn
          (with-current-buffer org1 (org-mode))
          (with-current-buffer org2 (org-mode))
          (with-current-buffer text-buffer
            (fundamental-mode)
            ;; Get initial companion (auto-created)
            (let ((initial (ogent-companion-get-or-create)))
              ;; Rebind to org2
              (ogent-companion-rebind text-buffer org2)
              ;; Check new link
              (should (eq (ogent-companion--get-linked-buffer text-buffer) org2))
              (should (eq (ogent-companion--get-linked-buffer org2) text-buffer))
              ;; Old link should be cleared
              (should-not (ogent-companion--get-linked-buffer initial))
              (kill-buffer initial))))
      (kill-buffer text-buffer)
      (kill-buffer org1)
      (kill-buffer org2))))

(ert-deftest ogent-companion-unlink-removes-link ()
  "Unlinking companion removes all links."
  (let ((text-buffer (get-buffer-create "*test-unlink*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            ;; Should have link
            (should (ogent-companion--get-linked-buffer text-buffer))
            ;; Unlink
            (ogent-companion-unlink text-buffer)
            ;; Should have no link
            (should-not (ogent-companion--get-linked-buffer text-buffer))
            (should-not (ogent-companion--get-linked-buffer companion))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-list-org-buffers ()
  "List org buffers returns only Org mode buffers."
  (let ((org-buffer (get-buffer-create "*test-list-org*"))
        (text-buffer (get-buffer-create "*test-list-text*")))
    (unwind-protect
        (progn
          (with-current-buffer org-buffer (org-mode))
          (with-current-buffer text-buffer (fundamental-mode))
          (let ((org-buffers (ogent-companion--list-org-buffers)))
            (should (member org-buffer org-buffers))
            (should-not (member text-buffer org-buffers))))
      (kill-buffer org-buffer)
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-marks-session-buffer ()
  "Companion buffers are marked as session buffers."
  (let ((text-buffer (get-buffer-create "*test-session*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (with-current-buffer companion
              (should ogent-session-buffer-p))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-session-buffer-append-behavior ()
  "Session buffers should support append-at-end insertion.
This test verifies the buffer-local variable is set correctly,
but doesn't test actual insertion behavior (that's in UI tests)."
  (let ((text-buffer (get-buffer-create "*test-append*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (with-current-buffer companion
              ;; Verify it's marked as a session buffer
              (should ogent-session-buffer-p)
              ;; Move to beginning
              (goto-char (point-min))
              ;; Position should be ignored by UI code when inserting
              ;; (actual insertion tested in ogent-ui-tests.el)
              (should (= (point) (point-min))))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-regular-org-not-session ()
  "Regular Org buffers should not be marked as session buffers."
  (let ((org-buffer (get-buffer-create "*test-regular-org*")))
    (unwind-protect
        (with-current-buffer org-buffer
          (org-mode)
          ;; Regular org buffers shouldn't have the flag
          (should-not ogent-session-buffer-p)
          ;; Getting companion for an org buffer returns itself
          (should (eq (ogent-companion-get-or-create org-buffer) org-buffer)))
      (kill-buffer org-buffer))))

;;; Lifecycle Edge Cases

(ert-deftest ogent-companion-kill-companion-keeps-source ()
  "Killing companion buffer doesn't affect source buffer."
  (let ((text-buffer (get-buffer-create "*test-kill-companion*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (insert "source content")
          (let ((companion (ogent-companion-get-or-create)))
            ;; Kill companion
            (kill-buffer companion)
            ;; Source buffer should still be alive and have content
            (should (buffer-live-p text-buffer))
            (with-current-buffer text-buffer
              (should (string-match-p "source content" (buffer-string))))
            ;; Link should be cleared
            (should-not (ogent-companion--get-linked-buffer text-buffer))
            ;; Can create new companion
            (let ((new-companion (ogent-companion-get-or-create)))
              (should (buffer-live-p new-companion))
              (should-not (eq companion new-companion))
              (kill-buffer new-companion))))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest ogent-companion-kill-source-orphans-companion ()
  "Killing source buffer orphans companion but keeps content."
  (let ((text-buffer (get-buffer-create "*test-kill-source*"))
        companion-buffer)
    (unwind-protect
        (progn
          (with-current-buffer text-buffer
            (fundamental-mode)
            (setq companion-buffer (ogent-companion-get-or-create))
            ;; Add some content to companion
            (with-current-buffer companion-buffer
              (goto-char (point-max))
              (insert "\n* Test Response\nContent here")))
          ;; Kill source
          (kill-buffer text-buffer)
          ;; Companion should still be alive
          (should (buffer-live-p companion-buffer))
          ;; Companion content preserved
          (with-current-buffer companion-buffer
            (should (string-match-p "Test Response" (buffer-string)))))
      (when (buffer-live-p companion-buffer)
        (kill-buffer companion-buffer)))))

(ert-deftest ogent-companion-multiple-sources-independent ()
  "Multiple source buffers have independent companions."
  (let ((source1 (get-buffer-create "*test-source1*"))
        (source2 (get-buffer-create "*test-source2*")))
    (unwind-protect
        (let (companion1 companion2)
          (with-current-buffer source1
            (fundamental-mode)
            (setq companion1 (ogent-companion-get-or-create)))
          (with-current-buffer source2
            (fundamental-mode)
            (setq companion2 (ogent-companion-get-or-create)))
          ;; Should be different companions
          (should-not (eq companion1 companion2))
          ;; Kill one doesn't affect other
          (kill-buffer source1)
          (should (buffer-live-p source2))
          (should (buffer-live-p companion2))
          (kill-buffer companion1)
          (kill-buffer companion2))
      (when (buffer-live-p source1) (kill-buffer source1))
      (when (buffer-live-p source2) (kill-buffer source2)))))

(ert-deftest ogent-companion-switch-and-return ()
  "Switching away from source and returning maintains link."
  (let ((source-buffer (get-buffer-create "*test-switch*"))
        (other-buffer (get-buffer-create "*test-other*")))
    (unwind-protect
        (with-current-buffer source-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            ;; Switch away
            (switch-to-buffer other-buffer)
            ;; Return to source
            (switch-to-buffer source-buffer)
            ;; Link should still work
            (should (eq (ogent-companion-get-or-create) companion))
            (kill-buffer companion)))
      (kill-buffer source-buffer)
      (kill-buffer other-buffer))))

(ert-deftest ogent-companion-recreate-after-kill ()
  "New companion after kill has fresh content."
  (let ((text-buffer (get-buffer-create "*test-recreate*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion1 (ogent-companion-get-or-create)))
            ;; Add content
            (with-current-buffer companion1
              (goto-char (point-max))
              (insert "\n* Old Content\nThis should be gone"))
            ;; Kill companion
            (kill-buffer companion1)
            ;; Create new companion
            (let ((companion2 (ogent-companion-get-or-create)))
              ;; Should be fresh (no old content)
              (with-current-buffer companion2
                (should-not (string-match-p "Old Content" (buffer-string))))
              (kill-buffer companion2))))
      (kill-buffer text-buffer))))

(ert-deftest ogent-companion-works-from-companion-buffer ()
  "Calling get-or-create from companion returns itself."
  (let ((text-buffer (get-buffer-create "*test-from-companion*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            ;; Call from companion should return the companion
            (with-current-buffer companion
              (should (eq (ogent-companion-get-or-create) companion)))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

;;; Display Function Tests

(ert-deftest ogent-companion-display-buffer-popup-or-side-standard ()
  "Test display function falls back to side window when no Doom."
  (let ((displayed-buffer nil)
        (displayed-alist nil))
    (cl-letf (((symbol-function 'display-buffer-in-side-window)
               (lambda (buf alist)
                 (setq displayed-buffer buf
                       displayed-alist alist)
                 nil)))
      (let ((buf (get-buffer-create " *test-display*")))
        (unwind-protect
            (progn
              (ogent-companion--display-buffer-popup-or-side
               buf '((side . right) (window-width . 0.4)))
              (should (eq displayed-buffer buf))
              ;; Should pass through side parameter
              (should (eq (alist-get 'side displayed-alist) 'right)))
          (kill-buffer buf))))))

(ert-deftest ogent-companion-display-buffer-uses-display-action ()
  "Test display-buffer uses configured display action."
  (let ((called-with nil))
    (cl-letf (((symbol-function 'display-buffer)
               (lambda (buf action)
                 (setq called-with (list buf action))
                 nil)))
      (let ((buf (get-buffer-create " *test-display-2*")))
        (unwind-protect
            (progn
              (ogent-companion-display-buffer buf)
              (should called-with)
              (should (eq (car called-with) buf)))
          (kill-buffer buf))))))

;;; Companion Display Interactive

(ert-deftest ogent-companion-display-returns-companion ()
  "Test companion-display returns the companion buffer."
  (let ((text-buffer (get-buffer-create "*test-display-3*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-display)))
            (should companion)
            (should (buffer-live-p companion))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

;;; Save Link Tests

(ert-deftest ogent-companion-save-link-file-backed ()
  "Test save-link saves identifier for file-backed buffer."
  (let ((temp-file (make-temp-file "ogent-save-link" nil ".el")))
    (unwind-protect
        (let ((src-buf (find-file-noselect temp-file)))
          (with-current-buffer src-buf
            (fundamental-mode)
            (let ((companion (ogent-companion-get-or-create)))
              (unwind-protect
                  (progn
                    ;; companion-file should be set
                    (should (local-variable-p 'ogent-companion-file))
                    (should ogent-companion-file))
                (kill-buffer companion))))
          (kill-buffer src-buf))
      (delete-file temp-file))))

(ert-deftest ogent-companion-save-link-writes-registry ()
  "File-backed companion links are written to the registry."
  (let ((temp-file (make-temp-file "ogent-save-registry" nil ".el"))
        (registry-file (make-temp-file "ogent-link-registry" nil ".el")))
    (unwind-protect
        (let ((ogent-companion-link-registry-file registry-file)
              (ogent-companion-persist-links t)
              src-buf companion)
          (setq src-buf (find-file-noselect temp-file))
          (with-current-buffer src-buf
            (fundamental-mode)
            (setq companion (ogent-companion-get-or-create))
            (let ((registry (ogent-companion--read-link-registry)))
              (should (equal (cdr (assoc temp-file registry))
                             (buffer-name companion)))))
          (kill-buffer companion)
          (kill-buffer src-buf))
      (when (file-exists-p temp-file)
        (delete-file temp-file))
      (when (file-exists-p registry-file)
        (delete-file registry-file)))))

(ert-deftest ogent-companion-restore-link-from-registry ()
  "A reopened source buffer restores its companion from the registry."
  (let ((temp-file (make-temp-file "ogent-restore-registry" nil ".el"))
        (registry-file (make-temp-file "ogent-link-registry" nil ".el"))
        companion-name)
    (unwind-protect
        (let ((ogent-companion-link-registry-file registry-file)
              (ogent-companion-persist-links t)
              src-buf companion reopened restored)
          (setq src-buf (find-file-noselect temp-file))
          (with-current-buffer src-buf
            (fundamental-mode)
            (setq companion (ogent-companion-get-or-create))
            (setq companion-name (buffer-name companion)))
          (kill-buffer src-buf)
          (kill-buffer companion)
          (setq reopened (find-file-noselect temp-file))
          (with-current-buffer reopened
            (fundamental-mode)
            (setq-local ogent-companion--linked-buffer nil)
            (setq-local ogent-companion-file nil)
            (ogent-companion--restore-link)
            (setq restored ogent-companion--linked-buffer)
            (should (buffer-live-p restored))
            (should (equal (buffer-name restored) companion-name))
            (with-current-buffer restored
              (should (derived-mode-p 'org-mode))))
          (kill-buffer restored)
          (kill-buffer reopened))
      (when (file-exists-p temp-file)
        (delete-file temp-file))
      (when (file-exists-p registry-file)
        (delete-file registry-file)))))

(ert-deftest ogent-companion-unlink-removes-registry-entry ()
  "Unlinking clears the persisted companion mapping."
  (let ((temp-file (make-temp-file "ogent-unlink-registry" nil ".el"))
        (registry-file (make-temp-file "ogent-link-registry" nil ".el")))
    (unwind-protect
        (let ((ogent-companion-link-registry-file registry-file)
              (ogent-companion-persist-links t)
              src-buf companion)
          (setq src-buf (find-file-noselect temp-file))
          (with-current-buffer src-buf
            (fundamental-mode)
            (setq companion (ogent-companion-get-or-create))
            (should (assoc temp-file (ogent-companion--read-link-registry)))
            (ogent-companion-unlink)
            (should-not (assoc temp-file (ogent-companion--read-link-registry))))
          (kill-buffer companion)
          (kill-buffer src-buf))
      (when (file-exists-p temp-file)
        (delete-file temp-file))
      (when (file-exists-p registry-file)
        (delete-file registry-file)))))

;;; Restore Link Tests

(ert-deftest ogent-companion-restore-link-with-buffer-name ()
  "Test restore-link works with buffer name identifier."
  (let ((companion-buf (get-buffer-create "*ogent:test-restore*")))
    (unwind-protect
        (with-temp-buffer
          (setq-local ogent-companion-persist-links t)
          (setq-local ogent-companion-file (buffer-name companion-buf))
          (setq-local ogent-companion--linked-buffer nil)
          (ogent-companion--restore-link)
          ;; Should now be linked
          (should (buffer-live-p ogent-companion--linked-buffer))
          (should (eq ogent-companion--linked-buffer companion-buf)))
      (kill-buffer companion-buf))))

(ert-deftest ogent-companion-restore-link-nil-when-no-file ()
  "Test restore-link does nothing when no companion-file."
  (with-temp-buffer
    (setq-local ogent-companion-persist-links t)
    (setq-local ogent-companion-file nil)
    (ogent-companion--restore-link)
    (should-not ogent-companion--linked-buffer)))

;;; Find or Create from Identifier Tests

(ert-deftest ogent-companion-find-from-buffer-name-identifier ()
  "Test find-or-create-from-identifier with buffer name."
  (let ((buf (ogent-companion--find-or-create-from-identifier "*ogent:test-find*")))
    (unwind-protect
        (progn
          (should buf)
          (should (buffer-live-p buf))
          (should (equal (buffer-name buf) "*ogent:test-find*")))
      (when buf (kill-buffer buf)))))

(ert-deftest ogent-companion-find-from-identifier-returns-nil ()
  "Test find-or-create-from-identifier returns nil for bad input."
  (should-not (ogent-companion--find-or-create-from-identifier "not-ogent-prefix"))
  (should-not (ogent-companion--find-or-create-from-identifier nil)))

;;; Get Companion Identifier Tests

(ert-deftest ogent-companion-get-identifier-for-file-backed ()
  "Test get-companion-identifier returns file path for file buffers."
  (let ((temp-file (make-temp-file "ogent-id-test")))
    (unwind-protect
        (let ((buf (find-file-noselect temp-file)))
          (should (equal (ogent-companion--get-companion-identifier buf) temp-file))
          (kill-buffer buf))
      (delete-file temp-file))))

(ert-deftest ogent-companion-get-identifier-for-temp-buffer ()
  "Test get-companion-identifier returns buffer name for temp buffers."
  (let ((buf (get-buffer-create "*test-id*")))
    (unwind-protect
        (should (equal (ogent-companion--get-companion-identifier buf) "*test-id*"))
      (kill-buffer buf))))

(provide 'ogent-companion-tests)
;;; ogent-companion-tests.el ends here
