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

(provide 'ogent-companion-tests)
;;; ogent-companion-tests.el ends here
