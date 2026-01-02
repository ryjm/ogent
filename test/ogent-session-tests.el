;;; ogent-session-tests.el --- Tests for session persistence -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-session)
(require 'org)

(ert-deftest ogent-persist-ensures-directory ()
  "Session directory is created if it doesn't exist."
  (let ((ogent-session-directory (make-temp-file "ogent-test-sessions-" t)))
    (unwind-protect
        (progn
          (delete-directory ogent-session-directory)
          (should-not (file-exists-p ogent-session-directory))
          (ogent-persist--ensure-directory)
          (should (file-directory-p ogent-session-directory)))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-persist-generates-unique-ids ()
  "Session IDs are unique and properly formatted."
  (let ((id1 (ogent-persist--generate-id))
        (id2 (ogent-persist--generate-id)))
    (should (string-prefix-p "ogent-" id1))
    (should (string-prefix-p "ogent-" id2))
    (should-not (string= id1 id2))))

(ert-deftest ogent-persist-extracts-metadata ()
  "Metadata extraction captures buffer state."
  (let ((buffer (get-buffer-create "*test-session*")))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert "#+title: Test Session\n\n* Conversation\n")
          (setq-local ogent-persist--id "test-id-123")
          (setq-local ogent-persist--models '("gpt-4" "claude-3"))
          (setq-local ogent-persist--start-time (current-time))
          
          (let ((metadata (ogent-persist--extract-metadata)))
            (should (equal (plist-get metadata :id) "test-id-123"))
            (should (equal (plist-get metadata :models) '("gpt-4" "claude-3")))
            (should (equal (plist-get metadata :title) "Test Session"))
            (should (plist-get metadata :start-time))))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-formats-metadata-header ()
  "Metadata header is properly formatted as Org keywords."
  (let* ((metadata '(:id "session-001"
			 :models ("gpt-4" "claude-3")
			 :start-time (25000 0 0 0)
			 :title "My Session"))
         (header (ogent-persist--format-metadata-header metadata)))
    (should (string-match-p "^#\\+title: My Session$" header))
    (should (string-match-p "^#\\+OGENT-SESSION-ID: session-001$" header))
    (should (string-match-p "^#\\+OGENT-SESSION-MODELS: gpt-4, claude-3$" header))))

(ert-deftest ogent-persist-parses-metadata-from-buffer ()
  "Metadata is parsed from Org keyword headers."
  (let ((buffer (get-buffer-create "*test-parse*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "#+title: Parsed Session\n")
          (insert "#+OGENT-SESSION-ID: parsed-001\n")
          (insert "#+OGENT-SESSION-START: 2024-01-15 14:30:00\n")
          (insert "#+OGENT-SESSION-MODELS: gpt-4, claude-3\n")
          (insert "\n* Content\n")
          
          (let ((metadata (ogent-persist--parse-metadata-from-buffer)))
            (should (equal (plist-get metadata :id) "parsed-001"))
            (should (equal (plist-get metadata :models) '("gpt-4" "claude-3")))
            (should (equal (plist-get metadata :title) "Parsed Session"))
            (should (plist-get metadata :start-time))))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-saves-and-loads ()
  "Session can be saved and loaded with metadata preserved."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-sessions-" t))
         (test-buffer (get-buffer-create "*test-save-load*"))
         saved-file
         loaded-buffer)
    (unwind-protect
        (progn
          ;; Create and save session
          (with-current-buffer test-buffer
            (org-mode)
            (insert "#+title: Save Load Test\n\n")
            (insert "* Session Content\n")
            (insert "Some conversation here.\n")
            (setq-local ogent-persist--models '("gpt-4"))
            (setq saved-file (ogent-session-save)))
          
          (should (file-exists-p saved-file))
          
          ;; Load session
          (setq loaded-buffer (ogent-session-load saved-file))
          (should (buffer-live-p loaded-buffer))
          
          (with-current-buffer loaded-buffer
            (should (derived-mode-p 'org-mode))
            ;; Check metadata was restored
            (should ogent-persist--id)
            (should (equal ogent-persist--models '("gpt-4")))
            (should ogent-persist--start-time)
            (should (equal ogent-persist--file-path saved-file))
            ;; Check content is present
            (goto-char (point-min))
            (should (search-forward "Session Content" nil t))
            (should (search-forward "Some conversation here." nil t))))
      
      ;; Cleanup
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer))
      (when (buffer-live-p loaded-buffer)
        (kill-buffer loaded-buffer))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-persist-tracks-models ()
  "Model tracking adds unique models to session list."
  (let ((buffer (get-buffer-create "*test-models*")))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (setq-local ogent-persist--models nil)
          
          (ogent-session-track-model "gpt-4")
          (should (member "gpt-4" ogent-persist--models))
          
          (ogent-session-track-model "claude-3")
          (should (member "claude-3" ogent-persist--models))
          
          ;; Duplicate shouldn't be added twice
          (ogent-session-track-model "gpt-4")
          (should (= (length ogent-persist--models) 2)))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-generates-filename ()
  "Filename generation uses time format or custom name."
  (let ((ogent-session-directory "/tmp/sessions/"))
    ;; Generated filename
    (let ((filename (ogent-persist--generate-filename)))
      (should (string-prefix-p "/tmp/sessions/" filename))
      (should (string-suffix-p ".org" filename)))
    
    ;; Custom name
    (let ((filename (ogent-persist--generate-filename "my-session")))
      (should (string= filename "/tmp/sessions/my-session.org")))))

(ert-deftest ogent-persist-applies-metadata ()
  "Metadata application sets buffer-local variables."
  (let ((buffer (get-buffer-create "*test-apply*")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((metadata '(:id "apply-001"
				:models ("gpt-4")
				:start-time (25000 0 0 0))))
            (ogent-persist--apply-metadata metadata)
            
            (should (equal ogent-persist--id "apply-001"))
            (should (equal ogent-persist--models '("gpt-4")))
            (should (equal ogent-persist--start-time '(25000 0 0 0)))))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-save-requires-org-mode ()
  "Saving a non-org buffer signals an error."
  (let ((buffer (get-buffer-create "*test-non-org*")))
    (unwind-protect
        (with-current-buffer buffer
          (fundamental-mode)
          (should-error (ogent-session-save)
                        :type 'user-error))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-load-requires-existing-file ()
  "Loading a non-existent file signals an error."
  (should-error (ogent-session-load "/nonexistent/session.org")
                :type 'user-error))

(ert-deftest ogent-persist-list-shows-sessions ()
  "Session list displays available sessions."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-sessions-" t))
         (file1 (expand-file-name "session1.org" ogent-session-directory))
         (file2 (expand-file-name "session2.org" ogent-session-directory))
         list-buffer)
    (unwind-protect
        (progn
          ;; Create test session files
          (with-temp-file file1
            (insert "#+title: Session One\n")
            (insert "#+OGENT-SESSION-ID: session-001\n")
            (insert "#+OGENT-SESSION-START: 2024-01-15 10:00:00\n")
            (insert "#+OGENT-SESSION-MODELS: gpt-4\n"))
          
          (with-temp-file file2
            (insert "#+title: Session Two\n")
            (insert "#+OGENT-SESSION-ID: session-002\n")
            (insert "#+OGENT-SESSION-START: 2024-01-16 14:30:00\n")
            (insert "#+OGENT-SESSION-MODELS: claude-3\n"))
          
          ;; Generate list
          (ogent-session-list)
          (setq list-buffer (get-buffer "*Ogent Sessions*"))
          (should (buffer-live-p list-buffer))
          
          (with-current-buffer list-buffer
            (goto-char (point-min))
            (should (search-forward "Ogent Sessions" nil t))
            (should (search-forward "Session One" nil t))
            (should (search-forward "gpt-4" nil t))
            (should (search-forward "Session Two" nil t))
            (should (search-forward "claude-3" nil t))))
      
      ;; Cleanup
      (when (buffer-live-p list-buffer)
        (kill-buffer list-buffer))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-persist-list-handles-empty-directory ()
  "Session list handles empty directory gracefully."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-empty-" t))
         list-buffer)
    (unwind-protect
        (progn
          (ogent-session-list)
          (setq list-buffer (get-buffer "*Ogent Sessions*"))
          (should (buffer-live-p list-buffer))
          
          (with-current-buffer list-buffer
            (goto-char (point-min))
            (should (search-forward "No saved sessions found" nil t))))
      
      (when (buffer-live-p list-buffer)
        (kill-buffer list-buffer))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-persist-parses-file-metadata ()
  "File metadata parsing extracts session info from saved files."
  (let* ((temp-dir (make-temp-file "ogent-test-parse-" t))
         (file (expand-file-name "test.org" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+title: File Test\n")
            (insert "#+OGENT-SESSION-ID: file-001\n")
            (insert "#+OGENT-SESSION-MODELS: gpt-4, claude-3\n"))
          
          (let ((metadata (ogent-persist--parse-file-metadata file)))
            (should (equal (plist-get metadata :file) file))
            (should (equal (plist-get metadata :id) "file-001"))
            (should (equal (plist-get metadata :title) "File Test"))
            (should (equal (plist-get metadata :models) '("gpt-4" "claude-3")))))
      
      (when (file-exists-p temp-dir)
        (delete-directory temp-dir t)))))

(ert-deftest ogent-persist-resave-preserves-metadata ()
  "Re-saving a session preserves its original ID."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-resave-" t))
         (buffer (get-buffer-create "*test-resave*"))
         _file1 file2)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (org-mode)
            (insert "#+title: Resave Test\n\n* Content\n")
            (setq file1 (ogent-session-save))
            (let ((original-id ogent-persist--id))
              
              ;; Modify buffer and save again
              (goto-char (point-max))
              (insert "More content.\n")
              (setq file2 (ogent-session-save))
              
              ;; ID should be preserved
              (should (equal ogent-persist--id original-id))
              
              ;; Reload and verify
              (kill-buffer buffer)
              (let ((reloaded (ogent-session-load file2)))
                (with-current-buffer reloaded
                  (should (equal ogent-persist--id original-id))
                  (goto-char (point-min))
                  (should (search-forward "More content." nil t)))
                (kill-buffer reloaded)))))
      
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(provide 'ogent-session-tests)

;;; ogent-session-tests.el ends here
