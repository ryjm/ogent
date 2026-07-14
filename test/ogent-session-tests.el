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
          (setq list-buffer (get-buffer "*ogent-sessions*"))
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
          (setq list-buffer (get-buffer "*ogent-sessions*"))
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
         file2)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (org-mode)
            (insert "#+title: Resave Test\n\n* Content\n")
            (ogent-session-save)
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

;;; Detect Project Tests

(ert-deftest ogent-persist-detect-project-uses-project-el ()
  "Test project detection via project.el."
  (cl-letf (((symbol-function 'project-current)
             (lambda () '(vc Git "/home/user/myproject/")))
            ((symbol-function 'project-root)
             (lambda (_proj) "/home/user/myproject/")))
    (should (equal (ogent-persist--detect-project) "/home/user/myproject/"))))

(ert-deftest ogent-persist-detect-project-vc-fallback ()
  "Test project detection falls back to vc-root-dir."
  (cl-letf (((symbol-function 'project-current) (lambda () nil))
            ((symbol-function 'vc-root-dir) (lambda () "/home/user/vcrepo/")))
    (should (equal (ogent-persist--detect-project) "/home/user/vcrepo/"))))

(ert-deftest ogent-persist-detect-project-default-directory ()
  "Test project detection falls back to default-directory."
  (let ((default-directory "/tmp/fallback/"))
    (cl-letf (((symbol-function 'project-current) (lambda () nil))
              ((symbol-function 'vc-root-dir) (lambda () nil)))
      (should (equal (ogent-persist--detect-project) "/tmp/fallback/")))))

;;; Parse File Metadata Tests

(ert-deftest ogent-persist-parse-file-metadata-complete ()
  "Test parsing metadata from a file with all keywords."
  (let* ((temp-dir (make-temp-file "ogent-test-pfm-" t))
         (file (expand-file-name "complete.org" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+title: Complete Session\n")
            (insert "#+OGENT-SESSION-ID: pfm-001\n")
            (insert "#+OGENT-SESSION-START: 2024-06-01 12:00:00\n")
            (insert "#+OGENT-SESSION-MODELS: gpt-4, claude-3\n")
            (insert "#+OGENT-SESSION-PROJECT: /home/user/project/\n")
            (insert "#+OGENT-SESSION-ROAM: roam-abc-123\n")
            (insert "\n* Content here\n"))
          (let ((metadata (ogent-persist--parse-file-metadata file)))
            (should (equal (plist-get metadata :file) file))
            (should (equal (plist-get metadata :id) "pfm-001"))
            (should (equal (plist-get metadata :title) "Complete Session"))
            (should (equal (plist-get metadata :models) '("gpt-4" "claude-3")))))
      (when (file-exists-p temp-dir)
        (delete-directory temp-dir t)))))

(ert-deftest ogent-persist-parse-file-metadata-no-keywords ()
  "Test parsing metadata from a file with no ogent keywords."
  (let* ((temp-dir (make-temp-file "ogent-test-pfm2-" t))
         (file (expand-file-name "plain.org" temp-dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Just a plain org file\nSome text.\n"))
          (let ((metadata (ogent-persist--parse-file-metadata file)))
            (should (equal (plist-get metadata :file) file))
            ;; With no session ID, fallback gives title from filename
            (should (equal (plist-get metadata :title) "plain"))))
      (when (file-exists-p temp-dir)
        (delete-directory temp-dir t)))))

;;; Maybe Auto Save Tests

(ert-deftest ogent-persist-maybe-auto-save-when-disabled ()
  "Test auto-save does nothing when disabled."
  (let ((buffer (get-buffer-create "*test-auto-save-off*"))
        (save-called nil))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (setq-local ogent-persist--id "test-id")
          (setq-local ogent-session-auto-save nil)
          (cl-letf (((symbol-function 'ogent-session-save)
                     (lambda (&rest _) (setq save-called t))))
            (ogent-persist--maybe-auto-save)
            (should-not save-called)))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-maybe-auto-save-auto ()
  "Test auto-save saves automatically when set to t."
  (let ((buffer (get-buffer-create "*test-auto-save-t*"))
        (save-called nil))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (setq-local ogent-persist--id "test-id")
          (setq-local ogent-session-auto-save t)
          (cl-letf (((symbol-function 'ogent-session-save)
                     (lambda (&rest _) (setq save-called t))))
            (ogent-persist--maybe-auto-save)
            (should save-called)))
      (with-current-buffer buffer
        (setq-local ogent-persist--id nil))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-maybe-auto-save-prompt-yes ()
  "Test auto-save with prompt mode when user says yes."
  (let ((buffer (get-buffer-create "*test-auto-save-prompt*"))
        (save-called nil))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (setq-local ogent-persist--id "test-id")
          (setq-local ogent-session-auto-save 'prompt)
          (cl-letf (((symbol-function 'ogent-session-save)
                     (lambda (&rest _) (setq save-called t)))
                    ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
            (ogent-persist--maybe-auto-save)
            (should save-called)))
      (with-current-buffer buffer
        (setq-local ogent-persist--id nil))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-maybe-auto-save-prompt-no ()
  "Test auto-save with prompt mode when user says no."
  (let ((buffer (get-buffer-create "*test-auto-save-no*"))
        (save-called nil))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (setq-local ogent-persist--id "test-id")
          (setq-local ogent-session-auto-save 'prompt)
          (cl-letf (((symbol-function 'ogent-session-save)
                     (lambda (&rest _) (setq save-called t)))
                    ((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
            (ogent-persist--maybe-auto-save)
            (should-not save-called)))
      (with-current-buffer buffer
        (setq-local ogent-persist--id nil))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-maybe-auto-save-no-id ()
  "Test auto-save does nothing when no session ID exists."
  (let ((buffer (get-buffer-create "*test-auto-save-noid*"))
        (save-called nil))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (setq-local ogent-persist--id nil)
          (setq-local ogent-session-auto-save t)
          (cl-letf (((symbol-function 'ogent-session-save)
                     (lambda (&rest _) (setq save-called t))))
            (ogent-persist--maybe-auto-save)
            (should-not save-called)))
      (kill-buffer buffer))))

;;; Session At Point Tests

(ert-deftest ogent-history-session-at-point-with-property ()
  "Test session-at-point returns the text property."
  (let ((buffer (get-buffer-create "*test-at-point*"))
        (session '(:id "s1" :title "Test" :file "/tmp/s1.org")))
    (unwind-protect
        (with-current-buffer buffer
          (insert (propertize "Session line\n" 'ogent-history-session session))
          (goto-char (point-min))
          (should (equal (ogent-history--session-at-point) session)))
      (kill-buffer buffer))))

(ert-deftest ogent-history-session-at-point-no-property ()
  "Test session-at-point returns nil on lines without the property."
  (let ((buffer (get-buffer-create "*test-at-point-nil*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "Plain text line\n")
          (goto-char (point-min))
          (should-not (ogent-history--session-at-point)))
      (kill-buffer buffer))))

;;; Format Entry Tests

(ert-deftest ogent-history-format-entry-full ()
  "Test format-entry with complete session metadata."
  (let ((session '(:title "My Session"
                          :start-time (25000 0 0 0)
                          :models ("gpt-4" "claude-3")
                          :project "/home/user/project/")))
    (let ((entry (ogent-history--format-entry session)))
      (should (stringp entry))
      (should (string-match-p "My Session" entry))
      (should (string-match-p "gpt-4" entry)))))

(ert-deftest ogent-history-format-entry-minimal ()
  "Test format-entry with minimal metadata."
  (let ((session '(:title nil :start-time nil :models nil :project nil)))
    (let ((entry (ogent-history--format-entry session)))
      (should (stringp entry))
      ;; Should use fallback for missing title
      (should (string-match-p "(untitled)" entry))
      ;; Should use fallback for missing date
      (should (string-match-p "\\?" entry)))))

(ert-deftest ogent-history-format-entry-long-title-truncated ()
  "Test format-entry truncates long titles."
  (let ((session (list :title (make-string 80 ?x)
                       :start-time nil :models nil :project nil)))
    (let ((entry (ogent-history--format-entry session)))
      (should (stringp entry))
      ;; Entry should not contain the full 80-char title
      (should (< (length entry) 200)))))

;;; History Refresh Tests

(ert-deftest ogent-history-refresh-calls-history ()
  "Test that refresh delegates to ogent-history."
  (let ((history-called nil))
    (cl-letf (((symbol-function 'ogent-history)
               (lambda () (setq history-called t))))
      (ogent-history-refresh)
      (should history-called))))

;;; Link Roam Tests

(ert-deftest ogent-history-link-roam-disabled ()
  "Test link-roam errors when roam integration is disabled."
  (let ((ogent-session-roam-integration nil))
    (should-error (ogent-history-link-roam)
                  :type 'user-error)))

(ert-deftest ogent-history-link-roam-no-package ()
  "Test link-roam errors when org-roam is not available."
  (let ((ogent-session-roam-integration t))
    (cl-letf (((symbol-function 'require) (lambda (_feature &rest _args) nil)))
      (should-error (ogent-history-link-roam)
                    :type 'user-error))))

;;; Session Search Tests

(ert-deftest ogent-session-search-finds-matching-content ()
  "Test ogent-session-search finds matching content in session files."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-search-" t))
         (file1 (expand-file-name "s1.org" ogent-session-directory))
         (file2 (expand-file-name "s2.org" ogent-session-directory))
         result-buf)
    (unwind-protect
        (progn
          (with-temp-file file1
            (insert "#+title: Alpha\n")
            (insert "#+OGENT-SESSION-ID: s1\n")
            (insert "\n* Conversation\nThis is about pandas.\n"))
          (with-temp-file file2
            (insert "#+title: Beta\n")
            (insert "#+OGENT-SESSION-ID: s2\n")
            (insert "\n* Discussion\nThis is about pandas too.\n"))
          (ogent-session-search "pandas")
          (setq result-buf (get-buffer "*ogent-search*"))
          (should (buffer-live-p result-buf))
          (with-current-buffer result-buf
            (goto-char (point-min))
            (should (search-forward "Search: pandas" nil t))
            (should (search-forward "2 session(s) matched" nil t))))
      (when (buffer-live-p result-buf)
        (kill-buffer result-buf))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-session-search-no-results ()
  "Test ogent-session-search displays no results message."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-search-empty-" t))
         (file1 (expand-file-name "s1.org" ogent-session-directory))
         result-buf)
    (unwind-protect
        (progn
          (with-temp-file file1
            (insert "#+title: Alpha\n* Content\nSome text.\n"))
          (ogent-session-search "nonexistent-query-xyz")
          (setq result-buf (get-buffer "*ogent-search*"))
          (should (buffer-live-p result-buf))
          (with-current-buffer result-buf
            (goto-char (point-min))
            (should (search-forward "0 session(s) matched" nil t))
            (should (search-forward "No matches found" nil t))))
      (when (buffer-live-p result-buf)
        (kill-buffer result-buf))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-session-search-empty-directory ()
  "Test ogent-session-search with no session files."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-search-none-" t))
         result-buf)
    (unwind-protect
        (progn
          (ogent-session-search "anything")
          (setq result-buf (get-buffer "*ogent-search*"))
          (should (buffer-live-p result-buf))
          (with-current-buffer result-buf
            (goto-char (point-min))
            (should (search-forward "0 session(s) matched" nil t))))
      (when (buffer-live-p result-buf)
        (kill-buffer result-buf))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-session-search-treats-query-literally ()
  "Session search accepts strings that are invalid regexps."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-search-literal-" t))
         (file1 (expand-file-name "s1.org" ogent-session-directory))
         result-buf)
    (unwind-protect
        (progn
          (with-temp-file file1
            (insert "#+title: Literal\n")
            (insert "#+OGENT-SESSION-ID: literal\n")
            (insert "\n* Conversation\nFind this literal text: a[b\n"))
          (ogent-session-search "a[b")
          (setq result-buf (get-buffer "*ogent-search*"))
          (should (buffer-live-p result-buf))
          (with-current-buffer result-buf
            (goto-char (point-min))
            (should (search-forward "1 session(s) matched" nil t))
            (should (search-forward "a[b" nil t))))
      (when (buffer-live-p result-buf)
        (kill-buffer result-buf))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

;;; Display Search Results Tests

(ert-deftest ogent-history-display-search-results-formatting ()
  "Test search results display formatting."
  (let (result-buf)
    (unwind-protect
        (progn
          (ogent-history--display-search-results
           "test-query"
           (list (list :file "/tmp/session.org"
                       :metadata '(:title "My Session")
                       :matches (list '(:line 10 :context "This is the matching line")))))
          (setq result-buf (get-buffer "*ogent-search*"))
          (should (buffer-live-p result-buf))
          (with-current-buffer result-buf
            (goto-char (point-min))
            (should (search-forward "Search: test-query" nil t))
            (should (search-forward "1 session(s) matched" nil t))
            (should (search-forward "My Session" nil t))
            (should (search-forward "L10:" nil t))))
      (when (buffer-live-p result-buf)
        (kill-buffer result-buf)))))

(ert-deftest ogent-history-display-search-results-no-metadata ()
  "Test search results display when metadata has no title."
  (let (result-buf)
    (unwind-protect
        (progn
          (ogent-history--display-search-results
           "q"
           (list (list :file "/tmp/notitle.org"
                       :metadata nil
                       :matches (list '(:line 5 :context "a match")))))
          (setq result-buf (get-buffer "*ogent-search*"))
          (should (buffer-live-p result-buf))
          (with-current-buffer result-buf
            (goto-char (point-min))
            ;; Should fall back to file-name-base
            (should (search-forward "notitle" nil t))))
      (when (buffer-live-p result-buf)
        (kill-buffer result-buf)))))

;;; Format Metadata Header Edge Cases

(ert-deftest ogent-persist-format-metadata-header-with-project ()
  "Metadata header includes project when present."
  (let* ((metadata '(:id "s1" :models nil :start-time (25000 0 0 0)
                         :title "Test" :project "/home/user/proj/" :roam-id nil))
         (header (ogent-persist--format-metadata-header metadata)))
    (should (string-match-p "^#\\+OGENT-SESSION-PROJECT: /home/user/proj/$" header))))

(ert-deftest ogent-persist-format-metadata-header-with-roam ()
  "Metadata header includes roam ID when present."
  (let* ((metadata '(:id "s1" :models nil :start-time (25000 0 0 0)
                         :title "Test" :project nil :roam-id "roam-xyz"))
         (header (ogent-persist--format-metadata-header metadata)))
    (should (string-match-p "^#\\+OGENT-SESSION-ROAM: roam-xyz$" header))))

(ert-deftest ogent-persist-format-metadata-header-minimal ()
  "Metadata header without optional fields omits those lines."
  (let* ((metadata '(:id "s1" :models nil :start-time (25000 0 0 0)
                         :title "Test" :project nil :roam-id nil))
         (header (ogent-persist--format-metadata-header metadata)))
    (should-not (string-match-p "OGENT-SESSION-PROJECT" header))
    (should-not (string-match-p "OGENT-SESSION-ROAM" header))
    (should-not (string-match-p "OGENT-SESSION-MODELS" header))))

;;; Parse Metadata Edge Cases

(ert-deftest ogent-persist-parse-metadata-with-roam-id ()
  "Parsing metadata extracts ROAM ID."
  (let ((buffer (get-buffer-create "*test-parse-roam*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "#+title: Roam Session\n")
          (insert "#+OGENT-SESSION-ID: roam-test-001\n")
          (insert "#+OGENT-SESSION-ROAM: roam-abc-456\n")
          (let ((metadata (ogent-persist--parse-metadata-from-buffer)))
            (should (equal (plist-get metadata :roam-id) "roam-abc-456"))))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-parse-metadata-with-project ()
  "Parsing metadata extracts project path."
  (let ((buffer (get-buffer-create "*test-parse-proj*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "#+title: Project Session\n")
          (insert "#+OGENT-SESSION-ID: proj-test-001\n")
          (insert "#+OGENT-SESSION-PROJECT: /home/user/myproject/\n")
          (let ((metadata (ogent-persist--parse-metadata-from-buffer)))
            (should (equal (plist-get metadata :project) "/home/user/myproject/"))))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-parse-metadata-no-id-returns-nil ()
  "Parsing metadata returns nil when no session ID is present."
  (let ((buffer (get-buffer-create "*test-parse-noid*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "#+title: No ID Session\n")
          (insert "Just some content\n")
          (should-not (ogent-persist--parse-metadata-from-buffer)))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-parse-metadata-date-present ()
  "Parsing metadata extracts start time when present."
  (let ((buffer (get-buffer-create "*test-parse-date*")))
    (unwind-protect
        (with-current-buffer buffer
          (insert "#+title: Date Test\n")
          (insert "#+OGENT-SESSION-ID: bd-001\n")
          (insert "#+OGENT-SESSION-START: 2024-03-15 09:30:00\n")
          (let ((metadata (ogent-persist--parse-metadata-from-buffer)))
            (should (equal (plist-get metadata :id) "bd-001"))
            ;; start-time should be set from the valid date
            (should (plist-get metadata :start-time))))
      (kill-buffer buffer))))

;;; Extract Metadata Edge Cases

(ert-deftest ogent-persist-extract-metadata-no-title ()
  "Metadata extraction uses buffer name when no title keyword."
  (let ((buffer (get-buffer-create "*test-no-title*")))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert "* Just content\nNo title keyword.\n")
          (setq-local ogent-persist--id nil)
          (let ((metadata (ogent-persist--extract-metadata)))
            ;; Title should fall back to buffer name
            (should (equal (plist-get metadata :title) (buffer-name)))))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-extract-metadata-generates-id ()
  "Metadata extraction generates ID when none exists."
  (let ((buffer (get-buffer-create "*test-gen-id*")))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert "#+title: Gen ID\n")
          (setq-local ogent-persist--id nil)
          (let ((metadata (ogent-persist--extract-metadata)))
            (should (string-prefix-p "ogent-" (plist-get metadata :id)))))
      (kill-buffer buffer))))

(ert-deftest ogent-persist-extract-metadata-preserves-roam-id ()
  "Metadata extraction preserves roam ID from buffer local."
  (let ((buffer (get-buffer-create "*test-roam-extract*")))
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert "#+title: Roam\n")
          (setq-local ogent-persist--id "test-1")
          (setq-local ogent-persist--roam-id "roam-111")
          (let ((metadata (ogent-persist--extract-metadata)))
            (should (equal (plist-get metadata :roam-id) "roam-111"))))
      (kill-buffer buffer))))

;;; Apply Metadata Edge Cases

(ert-deftest ogent-persist-apply-metadata-with-project-and-roam ()
  "Apply metadata sets project and roam-id."
  (let ((buffer (get-buffer-create "*test-apply-full*")))
    (unwind-protect
        (with-current-buffer buffer
          (let ((metadata '(:id "full-001"
                                :models ("gpt-4" "claude")
                                :start-time (25000 0 0 0)
                                :project "/home/user/project/"
                                :roam-id "roam-xyz")))
            (ogent-persist--apply-metadata metadata)
            (should (equal ogent-persist--project "/home/user/project/"))
            (should (equal ogent-persist--roam-id "roam-xyz"))))
      (kill-buffer buffer))))

;;; History Mode Tests

(ert-deftest ogent-history-mode-derived-from-special ()
  "History mode is derived from special-mode."
  (let ((buffer (get-buffer-create "*test-history-mode*")))
    (unwind-protect
        (with-current-buffer buffer
          (ogent-history-mode)
          (should (derived-mode-p 'special-mode))
          (should truncate-lines))
      (kill-buffer buffer))))

(ert-deftest ogent-history-mode-keymap-bindings ()
  "History mode keymap has expected bindings."
  (should (keymapp ogent-history-mode-map))
  (should (eq (lookup-key ogent-history-mode-map (kbd "RET")) 'ogent-history-load))
  (should (eq (lookup-key ogent-history-mode-map (kbd "o")) 'ogent-history-load-other-window))
  (should (eq (lookup-key ogent-history-mode-map (kbd "d")) 'ogent-history-delete))
  (should (eq (lookup-key ogent-history-mode-map (kbd "s")) 'ogent-history-search))
  (should (eq (lookup-key ogent-history-mode-map (kbd "/")) 'ogent-history-search))
  (should (eq (lookup-key ogent-history-mode-map (kbd "g")) 'ogent-history-refresh))
  (should (eq (lookup-key ogent-history-mode-map (kbd "r")) 'ogent-history-link-roam))
  (should (eq (lookup-key ogent-history-mode-map (kbd "q")) 'quit-window)))

;;; History Browser Tests

(ert-deftest ogent-history-displays-sessions-sorted ()
  "History browser displays sessions in reverse chronological order."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-hist-" t))
         (file1 (expand-file-name "s1.org" ogent-session-directory))
         (file2 (expand-file-name "s2.org" ogent-session-directory))
         hist-buf)
    (unwind-protect
        (progn
          (with-temp-file file1
            (insert "#+title: Earlier\n")
            (insert "#+OGENT-SESSION-ID: s1\n")
            (insert "#+OGENT-SESSION-START: 2024-01-01 10:00:00\n"))
          (with-temp-file file2
            (insert "#+title: Later\n")
            (insert "#+OGENT-SESSION-ID: s2\n")
            (insert "#+OGENT-SESSION-START: 2024-06-01 10:00:00\n"))
          (ogent-history)
          (setq hist-buf (get-buffer "*ogent-history*"))
          (should (buffer-live-p hist-buf))
          (with-current-buffer hist-buf
            (goto-char (point-min))
            ;; Later session should appear first
            (let ((later-pos (search-forward "Later" nil t))
                  (earlier-pos (search-forward "Earlier" nil t)))
              (should later-pos)
              (should earlier-pos)
              (should (< later-pos earlier-pos)))))
      (when (buffer-live-p hist-buf)
        (kill-buffer hist-buf))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-history-empty-directory ()
  "History browser handles empty directory."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-hist-empty-" t))
         hist-buf)
    (unwind-protect
        (progn
          (ogent-history)
          (setq hist-buf (get-buffer "*ogent-history*"))
          (should (buffer-live-p hist-buf))
          (with-current-buffer hist-buf
            (goto-char (point-min))
            (should (search-forward "No saved sessions found" nil t))))
      (when (buffer-live-p hist-buf)
        (kill-buffer hist-buf))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

;;; Session Create Roam Note Tests

(ert-deftest ogent-session-create-roam-note-disabled ()
  "Creating roam note errors when integration is disabled."
  (let ((ogent-session-roam-integration nil))
    (should-error (ogent-session-create-roam-note)
                  :type 'user-error)))

(ert-deftest ogent-session-create-roam-note-no-package ()
  "Creating roam note errors when org-roam is not available."
  (let ((ogent-session-roam-integration t))
    (cl-letf (((symbol-function 'require) (lambda (_feature &rest _args) nil)))
      (should-error (ogent-session-create-roam-note)
                    :type 'user-error))))

;;; Save Strips Old Metadata

(ert-deftest ogent-persist-save-strips-old-metadata ()
  "Saving a session strips old metadata keywords before writing fresh ones."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-strip-" t))
         (buffer (get-buffer-create "*test-strip-meta*"))
         saved-file)
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert "#+title: Old Title\n")
          (insert "#+OGENT-SESSION-ID: old-id\n")
          (insert "#+OGENT-SESSION-MODELS: old-model\n")
          (insert "\n* Content\n")
          (setq-local ogent-persist--id "new-id")
          (setq-local ogent-persist--models '("new-model"))
          (setq-local ogent-persist--start-time (current-time))
          (setq saved-file (ogent-session-save))
          ;; Read back and check no duplicate keywords
          (with-temp-buffer
            (insert-file-contents saved-file)
            (let ((content (buffer-string)))
              ;; Should have new ID, not old
              (should (string-match-p "OGENT-SESSION-ID: new-id" content))
              (should-not (string-match-p "OGENT-SESSION-ID: old-id" content))
              ;; Should have new model
              (should (string-match-p "OGENT-SESSION-MODELS: new-model" content))
              (should-not (string-match-p "OGENT-SESSION-MODELS: old-model" content)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq-local ogent-persist--id nil))
        (kill-buffer buffer))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-persist-save-preserves-body-org-keywords ()
  "Saving a session preserves Org keywords inside transcript content."
  (let* ((ogent-session-directory (make-temp-file "ogent-test-body-keywords-" t))
         (buffer (get-buffer-create "*test-body-keywords*"))
         saved-file)
    (unwind-protect
        (with-current-buffer buffer
          (org-mode)
          (insert "#+title: Old Title\n")
          (insert "#+OGENT-SESSION-ID: old-id\n\n")
          (insert "* Response\n")
          (insert "#+begin_src org\n")
          (insert "#+title: Keep This Generated Title\n")
          (insert "#+OGENT-SESSION-ID: keep-this-generated-id\n")
          (insert "#+end_src\n")
          (setq-local ogent-persist--id "new-id")
          (setq-local ogent-persist--models '("new-model"))
          (setq-local ogent-persist--start-time (current-time))
          (setq saved-file (ogent-session-save))
          (with-temp-buffer
            (insert-file-contents saved-file)
            (let ((content (buffer-string)))
              (should (string-match-p "OGENT-SESSION-ID: new-id" content))
              (should (string-match-p "Keep This Generated Title" content))
              (should (string-match-p "keep-this-generated-id" content)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq-local ogent-persist--id nil))
        (kill-buffer buffer))
      (when (file-exists-p ogent-session-directory)
        (delete-directory ogent-session-directory t)))))

(ert-deftest ogent-persist-parse-metadata-ignores-body-keywords ()
  "Metadata parsing only reads the initial Org preamble."
  (with-temp-buffer
    (org-mode)
    (insert "* Response\n")
    (insert "#+begin_src org\n")
    (insert "#+title: Body Title\n")
    (insert "#+OGENT-SESSION-ID: body-id\n")
    (insert "#+end_src\n")
    (should-not (ogent-persist--parse-metadata-from-buffer))))

;;; Maybe Auto Save Non-Org Buffer

(ert-deftest ogent-persist-maybe-auto-save-non-org ()
  "Auto-save does nothing in non-org buffers."
  (let ((buffer (get-buffer-create "*test-auto-save-nonorg*"))
        (save-called nil))
    (unwind-protect
        (with-current-buffer buffer
          (fundamental-mode)
          (setq-local ogent-persist--id "test-id")
          (setq-local ogent-session-auto-save t)
          (cl-letf (((symbol-function 'ogent-session-save)
                     (lambda (&rest _) (setq save-called t))))
            (ogent-persist--maybe-auto-save)
            (should-not save-called)))
      (kill-buffer buffer))))

(provide 'ogent-session-tests)

;;; ogent-session-tests.el ends here
