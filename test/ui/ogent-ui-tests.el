;;; ogent-ui-tests.el --- Tests for ogent UI layer -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-context)
(require 'ogent-tools)
(require 'cl-lib)

(ert-deftest ogent-ui-format-context-includes-missing ()
  "Format string contains handles and missing metadata."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Root Overview")
     (org-back-to-heading t)
     (let* ((context (ogent-context-build))
            (summary (ogent-ui--format-context context)))
       (should (string-match-p "Handles: details-block" summary))
       (should (string-match-p "missing-note (missing)" summary))))))

(ert-deftest ogent-request-streams-via-gptel ()
  "ogent-request uses gptel and streams response with nested headline structure."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((captured nil)
           (ogent-ui--selected-models '("gpt-4o-mini")))
        (cl-letf (((symbol-function 'gptel-request)
                   (lambda (prompt &rest args)
                     (setq captured (list :prompt prompt
                                          :args args
                                          :backend gptel-backend
                                          :model gptel-model))
                    (when-let ((callback (plist-get args :callback)))
                      (funcall callback "Hello world" nil)
                      (funcall callback nil '(:done t)))
                    'mock-request)))
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (should (string-match-p "Test prompt"
                                 (plist-get captured :prompt)))
         (should (eq (plist-get captured :backend) 'gptel-openai))
         (should (equal (plist-get captured :model) "gpt-4o-mini"))
                   (save-excursion
           (goto-char (point-min))
           ;; Should have Request headline as child of Session (level 2)
           (search-forward "** Request: Test prompt")
           ;; The src block should be under the Request headline
           (search-forward "#+begin_src text :model gpt-4o-mini")
           (search-forward "#+end_src")
           ;; Response streams under nested *** Response sub-headline
           (search-forward "*** Response")
           (search-forward "Hello world")))))))

(ert-deftest ogent-ui-nested-headline-structure ()
  "Verify nested headline structure: * Session -> ** Request -> *** Response."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (when-let ((callback (plist-get args :callback)))
                      (funcall callback "Response text" nil)
                      (funcall callback nil '(:done t)))
                    'mock-request)))
         (ogent-request "This is a longer test prompt that should be truncated in the headline" 
                        '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           ;; Request headline as child of Session (level 2) with truncated prompt (max 60 chars)
           (should (search-forward "** Request: This is a longer test prompt that should be truncated in ..." nil t))
           ;; Src block should be directly under Request headline
           (should (search-forward "#+begin_src text :model gpt-4o-mini" nil t))
           (should (search-forward "Prompt:" nil t))
           (should (search-forward "This is a longer test prompt that should be truncated in the headline" nil t))
           (should (search-forward "#+end_src" nil t))
           ;; Response should be a level 3 heading (nested under Request)
           (should (search-forward "*** Response" nil t))
           (should (search-forward "Response text" nil t))))))))

(ert-deftest ogent-ui-ensure-gptel-loads-required-backends ()
  "ogent-ui--ensure-gptel requires gptel plus declared backend features."
  (let ((requested '()))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requested)
                 t))
              ((symbol-function 'display-warning) (lambda (&rest _) nil))
              (ogent-gptel-required-features '(foo bar)))
      (ogent-ui--ensure-gptel))
    (should (equal (nreverse requested) '(gptel foo bar)))))

(ert-deftest ogent-ui-extract-preset-cookies ()
  "Extract @preset cookies from prompts."
  (let ((ogent-preset-registry '((:name code-review :spec (:description "review"))
                                 (:name summarize :spec (:description "sum")))))
    (let ((result (ogent-ui--extract-preset-cookies "Review this @code-review please")))
      (should (equal (car result) "Review this please"))
      (should (equal (cdr result) '("code-review"))))
    (let ((result (ogent-ui--extract-preset-cookies "No presets here")))
      (should (equal (car result) "No presets here"))
      (should (null (cdr result))))
    (let ((result (ogent-ui--extract-preset-cookies "@summarize @code-review both")))
      (should (equal (car result) "both"))
      ;; Order matches registry order, both presets extracted
      (should (member "summarize" (cdr result)))
      (should (member "code-review" (cdr result)))
      (should (= 2 (length (cdr result)))))))

(ert-deftest ogent-ui-extract-default-preset-cookies ()
  "Default ogent presets can be used as @preset cookies."
  (let ((ogent-preset-registry nil)
        (ogent--presets-registered nil))
    ;; Default presets should be available
    (let ((result (ogent-ui--extract-preset-cookies "Review @ogent-code-review this")))
      (should (equal (car result) "Review this"))
      (should (equal (cdr result) '("ogent-code-review"))))
    (let ((result (ogent-ui--extract-preset-cookies "@ogent-explain the code")))
      (should (equal (car result) "the code"))
      (should (equal (cdr result) '("ogent-explain"))))
    (let ((result (ogent-ui--extract-preset-cookies "@ogent-refactor this function")))
      (should (equal (car result) "this function"))
      (should (equal (cdr result) '("ogent-refactor"))))))

(ert-deftest ogent-request-applies-preset ()
  "ogent-request applies presets from cookies and dispatcher."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((captured-request nil)
           (ogent-ui--selected-models '("gpt-4o-mini"))
           (ogent-ui--selected-preset nil)
           (ogent-preset-registry '((:name mypreset :spec (:description "test")))))
       (cl-letf (((symbol-function 'ogent-ui--send-request)
                  (lambda (request)
                    (setq captured-request request))))
         (ogent-request "Test @mypreset prompt" '("gpt-4o-mini"))
         (should (equal (ogent-ui-request-preset captured-request) "mypreset")))))))

(ert-deftest ogent-ui-status-tracking ()
  "Request status transitions through wait -> type -> done."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           (callback nil))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (setq callback (plist-get args :callback))
                    'mock-request)))
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (let* ((request-id (format "ogent-request-%d" ogent-ui--request-seq))
                (request (gethash request-id ogent-ui--request-table)))
           ;; Initial status is wait
           (should (eq (ogent-ui-request-status request) 'wait))
           (should (ogent-ui-request-start-time request))
           ;; First text transitions to type
           (funcall callback "Hello" nil)
           (should (eq (ogent-ui-request-status request) 'type))
           ;; Done signal finalizes
           (funcall callback nil '(:done t))
           (should (eq (ogent-ui-request-status request) 'done))
           (should (ogent-ui-request-end-time request))))))))

(ert-deftest ogent-ui-latency-formatting ()
  "Format latency shows seconds with one decimal."
  (let ((request (make-ogent-ui-request
                  :id "test"
                  :start-time (time-subtract (current-time) (seconds-to-time 2.5))
                  :end-time (current-time))))
    (should (string-match-p "^2\\.[0-9]s$" (ogent-ui--format-latency request)))))

(ert-deftest ogent-ui-abort-request ()
  "Abort marks request as closed with error."
  (let ((request (make-ogent-ui-request
                  :id "test-abort"
                  :buffer (current-buffer)
                  :status 'wait)))
    (puthash "test-abort" request ogent-ui--request-table)
    (ogent-ui--abort-request request)
    (should (ogent-ui-request-closed request))
    (should (null (gethash "test-abort" ogent-ui--request-table)))))

(ert-deftest ogent-ui-request-history ()
  "Closed requests are added to history."
  (let ((ogent-ui--request-history nil)
        (request (make-ogent-ui-request
                  :id "test-history"
                  :buffer (current-buffer)
                  :marker (copy-marker (point))
                  :status 'type)))
    (puthash "test-history" request ogent-ui--request-table)
    (ogent-ui--close-response request)
    (should (member request ogent-ui--request-history))))

(ert-deftest ogent-ui-active-requests ()
  "Active requests only includes non-closed."
  (let ((active (make-ogent-ui-request :id "active" :closed nil))
        (closed (make-ogent-ui-request :id "closed" :closed t)))
    (clrhash ogent-ui--request-table)
    (puthash "active" active ogent-ui--request-table)
    (puthash "closed" closed ogent-ui--request-table)
    (let ((result (ogent-ui-active-requests)))
      (should (= 1 (length result)))
      (should (equal "active" (ogent-ui-request-id (car result)))))))

(ert-deftest ogent-ui-insert-tool-block ()
  "Tool blocks use Org drawer format with args and result blocks."
  (with-temp-buffer
    (org-mode)
    (ogent-ui--insert-tool-block "search" '(:query "test") "Result text")
    (goto-char (point-min))
    (should (search-forward ":TOOL:" nil t))
    (should (search-forward "search:" nil t))
    (should (search-forward "#+begin_src elisp :args" nil t))
    (should (search-forward ":query" nil t))
    (should (search-forward "#+end_src" nil t))
    (should (search-forward ":result" nil t))
    (should (search-forward "Result text" nil t))
    (should (search-forward ":END:" nil t))))

(ert-deftest ogent-ui-insert-reasoning-block ()
  "Reasoning blocks follow gptel format."
  (with-temp-buffer
    (org-mode)
    (ogent-ui--insert-reasoning-block "Thinking about this...")
    (goto-char (point-min))
    (should (search-forward "#+begin_reasoning" nil t))
    (should (search-forward "Thinking about this..." nil t))
    (should (search-forward "#+end_reasoning" nil t))))

;;; Tool Approval Tests

(ert-deftest ogent-tool-pattern-match-basic ()
  "Tool pattern matching for simple patterns."
  ;; Tool name only
  (should (ogent-tool--pattern-match-p "read-file" "read-file" nil))
  (should-not (ogent-tool--pattern-match-p "read-file" "write-file" nil))
  ;; Wildcard args
  (should (ogent-tool--pattern-match-p "bash(*)" "bash" '(:command "git status")))
  ;; No args required
  (should (ogent-tool--pattern-match-p "glob" "glob" '(:pattern "*.el"))))

(ert-deftest ogent-tool-pattern-match-with-args ()
  "Tool pattern matching with specific argument patterns."
  ;; Match specific arg value
  (should (ogent-tool--pattern-match-p
           "bash(command:git *)"
           "bash"
           '(:command "git status")))
  ;; Doesn't match different command
  (should-not (ogent-tool--pattern-match-p
               "bash(command:git *)"
               "bash"
               '(:command "rm -rf /"))))

(ert-deftest ogent-tool-glob-match ()
  "Glob pattern matching works correctly."
  (should (ogent-tool--glob-match-p "git *" "git status"))
  (should (ogent-tool--glob-match-p "git *" "git log"))
  (should-not (ogent-tool--glob-match-p "git *" "make test"))
  (should (ogent-tool--glob-match-p "*" "anything"))
  (should (ogent-tool--glob-match-p "make test:*" "make test:all")))

(ert-deftest ogent-tool-allow-list-check ()
  "Allow-list checking works correctly."
  (let ((ogent-tool-allow-list '("read-file" "bash(command:git *)")))
    (should (ogent-tool--allowed-p "read-file" nil))
    (should (ogent-tool--allowed-p "bash" '(:command "git status")))
    (should-not (ogent-tool--allowed-p "write-file" nil))
    (should-not (ogent-tool--allowed-p "bash" '(:command "rm -rf /")))))

(ert-deftest ogent-tool-approval-disabled ()
  "When approval is disabled, all tools are approved."
  (let ((ogent-tool-require-approval nil)
        (ogent-tool-allow-list nil))
    (should (eq (ogent-ui--check-tool-approval "bash" '(:command "rm -rf /"))
                'approved))))

(ert-deftest ogent-tool-approval-allow-listed ()
  "Allow-listed tools are auto-approved."
  (let ((ogent-tool-require-approval t)
        (ogent-tool-allow-list '("read-file")))
    (should (eq (ogent-ui--check-tool-approval "read-file" nil)
                'approved))))

(ert-deftest ogent-tool-format-preview ()
  "Tool preview formatting is human-readable."
  (let ((preview (ogent-tool--format-preview "bash" '(:command "git status"))))
    (should (string-match-p "Tool: bash" preview))
    (should (string-match-p "command" preview))
    (should (string-match-p "git status" preview))))

(ert-deftest ogent-request-writes-to-companion-buffer ()
  "Verify ogent-request writes to companion buffer when invoked from non-Org buffer."
  (let ((text-buffer (get-buffer-create "*test-source.txt*"))
        (companion-buffer nil)
        (request-buffer nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gptel-request)
                     (lambda (_prompt &rest _args)
                       ;; Capture the buffer where the request is created
                       (setq request-buffer (current-buffer))
                       nil)))
            (with-current-buffer text-buffer
              (fundamental-mode)
              ;; Set up companion with Org structure
              (let ((companion (ogent-companion-get-or-create)))
                (setq companion-buffer companion)
                (with-current-buffer companion
                  (erase-buffer)
                  (insert "#+title: Test\n\n* Session\n")
                  (goto-char (point-max)))
                ;; Call ogent-request from the text buffer
                (ogent-request "test prompt" '("gpt-4o-mini"))))
            ;; Verify request was created in the companion, not the source
            (should request-buffer)
            (should-not (eq request-buffer text-buffer))
            (should (eq request-buffer companion-buffer))
            (with-current-buffer request-buffer
              (should (derived-mode-p 'org-mode)))
            (when companion-buffer
              (kill-buffer companion-buffer))))
      (kill-buffer text-buffer))))

;;; Tests using new mocking utilities

(ert-deftest ogent-ui-error-response-handling ()
  "Test error handling when gptel returns an error."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (ogent-test-with-error-mock "API rate limit exceeded"
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         ;; Verify request was captured
         (should (= 1 (ogent-test-request-count)))
         (let ((req (ogent-test-last-request)))
           (should (string-match-p "Test prompt" (plist-get req :prompt)))))))))

(ert-deftest ogent-ui-streaming-chunks ()
  "Test streaming response with multiple chunks."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (ogent-test-with-streaming-mock '("Hello " "world " "!")
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         ;; Verify the streaming content was inserted
         (save-excursion
           (goto-char (point-min))
           (should (search-forward "Hello world !" nil t))))))))

(ert-deftest ogent-ui-request-capture ()
  "Test that requests are properly captured for inspection."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (ogent-test-with-mock-gptel
         (ogent-request "First request" '("gpt-4o-mini"))
         (ogent-request "Second request" '("gpt-4o-mini"))
         ;; Two requests should be captured
         (should (= 2 (ogent-test-request-count)))
         ;; Most recent is first in list
         (should (string-match-p "Second" (plist-get (ogent-test-last-request) :prompt))))))))

;;; Interactive function tests (require with-simulated-input)

(ert-deftest ogent-ui-read-prompt-interactive ()
  "Test reading prompt with simulated input."
  (ogent-test-with-input "Hello world RET"
    (let ((prompt (ogent-ui--read-prompt)))
      (should (equal prompt "Hello world")))))

(ert-deftest ogent-ui-read-prompt-uses-region ()
  "Test that read-prompt uses region when active."
  (with-temp-buffer
    (insert "This is selected text")
    (set-mark (point-min))
    (goto-char (point-max))
    (activate-mark)
    (let ((prompt (ogent-ui--read-prompt)))
      (should (equal prompt "This is selected text")))))

;;; Inline Diff Display Tests

(ert-deftest ogent-ui-generate-diff-write ()
  "Test diff generation for write-file operations."
  (let ((test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          ;; Write initial content
          (with-temp-file test-file
            (insert "line 1\nline 2\nline 3\n"))
          ;; Generate diff for new content
          (let ((diff (ogent-ui--generate-diff test-file "line 1\nline 2 modified\nline 3\n")))
            (should (stringp diff))
            (should (string-match-p "-line 2" diff))
            (should (string-match-p "\\+line 2 modified" diff))))
      (delete-file test-file))))

(ert-deftest ogent-ui-generate-diff-edit ()
  "Test diff generation for edit-file operations."
  (let ((test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          ;; Write initial content
          (with-temp-file test-file
            (insert "function foo() {\n  return 42;\n}\n"))
          ;; Generate diff for string replacement
          (let ((diff (ogent-ui--generate-diff test-file nil
                                                "return 42;"
                                                "return 100;")))
            (should (stringp diff))
            (should (string-match-p "-.*return 42" diff))
            (should (string-match-p "\\+.*return 100" diff))))
      (delete-file test-file))))

(ert-deftest ogent-ui-generate-diff-new-file ()
  "Test diff generation for new file creation."
  (let ((test-file (make-temp-file "ogent-test" nil nil)))
    ;; Delete the file to simulate new file creation
    (delete-file test-file)
    ;; Generate diff for new content
    (let ((diff (ogent-ui--generate-diff test-file "new file content\n")))
      (should (stringp diff))
      (should (string-match-p "\\+new file content" diff)))))

(ert-deftest ogent-ui-insert-diff-block ()
  "Test diff block insertion."
  (with-temp-buffer
    (org-mode)
    (ogent-ui--insert-diff-block "test-diff-1" "/tmp/test.el"
                                  "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n"
                                  'pending)
    (goto-char (point-min))
    (should (search-forward "#+begin_diff test-diff-1" nil t))
    (should (search-forward "File: /tmp/test.el" nil t))
    (should (search-forward "[PENDING" nil t))
    (should (search-forward "#+end_diff" nil t))))

(ert-deftest ogent-ui-diff-fontification ()
  "Test diff syntax highlighting."
  (let ((fontified (ogent-ui--fontify-diff "--- a\n+++ b\n@@ -1 +1 @@\n-removed\n+added\n")))
    (should (stringp fontified))
    ;; Check that face properties were added
    (should (text-property-any 0 (length fontified) 'face 'ogent-diff-removed fontified))
    (should (text-property-any 0 (length fontified) 'face 'ogent-diff-added fontified))))

(ert-deftest ogent-ui-is-edit-tool-p ()
  "Test edit tool detection."
  (should (ogent-ui--is-edit-tool-p "write-file"))
  (should (ogent-ui--is-edit-tool-p "edit-file"))
  (should-not (ogent-ui--is-edit-tool-p "read-file"))
  (should-not (ogent-ui--is-edit-tool-p "bash"))
  (should-not (ogent-ui--is-edit-tool-p "glob")))

(ert-deftest ogent-ui-show-diff-for-tool ()
  "Test showing diff preview for edit tools."
  (let ((test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          ;; Write initial content
          (with-temp-file test-file
            (insert "original content\n"))
          ;; Show diff in an org buffer
          (with-temp-buffer
            (org-mode)
            (let ((diff-id (ogent-ui--show-diff-for-tool
                           "write-file"
                           (list :file_path test-file
                                 :content "new content\n"))))
              (should diff-id)
              (should (string-match-p "^ogent-diff-" diff-id))
              ;; Check diff info was stored
              (let ((info (gethash diff-id ogent-ui--pending-diffs)))
                (should info)
                (should (eq (plist-get info :status) 'pending))
                (should (equal (plist-get info :file-path) test-file)))
              ;; Check block was inserted
              (goto-char (point-min))
              (should (search-forward "#+begin_diff" nil t)))))
      (delete-file test-file))))

(ert-deftest ogent-ui-diff-accept ()
  "Test accepting a diff."
  (let ((test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          ;; Write initial content
          (with-temp-file test-file
            (insert "old content\n"))
          ;; Create and accept a diff
          (with-temp-buffer
            (org-mode)
            ;; Set up tool registry with write-file tool
            (let ((ogent-tool-registry
                   '((:name write-file
                      :function ogent-tool--write-file
                      :description "Write file"
                      :args ((:name "file_path" :type "string")
                             (:name "content" :type "string"))))))
              (let ((diff-id (ogent-ui--show-diff-for-tool
                             "write-file"
                             (list :file_path test-file
                                   :content "new content\n"))))
                ;; Move point into the diff block
                (goto-char (point-min))
                (search-forward "#+begin_diff")
                ;; Accept the diff
                (ogent-diff-accept)
                ;; Check status updated
                (let ((info (gethash diff-id ogent-ui--pending-diffs)))
                  (should (eq (plist-get info :status) 'applied)))
                ;; Check file was updated
                (with-temp-buffer
                  (insert-file-contents test-file)
                  (should (string= (buffer-string) "new content\n")))))))
      (delete-file test-file))))

(ert-deftest ogent-ui-diff-reject ()
  "Test rejecting a diff."
  (let ((test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          ;; Write initial content
          (with-temp-file test-file
            (insert "original content\n"))
          ;; Create and reject a diff
          (with-temp-buffer
            (org-mode)
            (let ((diff-id (ogent-ui--show-diff-for-tool
                           "write-file"
                           (list :file_path test-file
                                 :content "modified content\n"))))
              ;; Move point into the diff block
              (goto-char (point-min))
              (search-forward "#+begin_diff")
              ;; Reject the diff
              (ogent-diff-reject)
              ;; Check status updated
              (let ((info (gethash diff-id ogent-ui--pending-diffs)))
                (should (eq (plist-get info :status) 'rejected)))
              ;; Check file was NOT modified
              (with-temp-buffer
                (insert-file-contents test-file)
                (should (string= (buffer-string) "original content\n"))))))
      (delete-file test-file))))

(ert-deftest ogent-ui-pending-diffs ()
  "Test listing pending diffs."
  (clrhash ogent-ui--pending-diffs)
  (let ((test-file (make-temp-file "ogent-test")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "content\n"))
          (with-temp-buffer
            (org-mode)
            ;; Create two diffs
            (ogent-ui--show-diff-for-tool
             "write-file"
             (list :file_path test-file :content "a\n"))
            (ogent-ui--show-diff-for-tool
             "write-file"
             (list :file_path test-file :content "b\n"))
            ;; Both should be pending
            (should (= 2 (length (ogent-ui-pending-diffs))))))
      (delete-file test-file))))

;;; Context Diff Tests

(ert-deftest ogent-ui-diff-strings-added ()
  "Detect added lines in context diff."
  (let* ((old "line 1\nline 2\nline 3")
         (new "line 1\nline 2\nline 2.5\nline 3")
         (diff (ogent-ui--diff-strings old new)))
    (should diff)
    (let ((added (seq-find (lambda (d) (eq (plist-get d :type) :added)) diff)))
      (should added)
      (should (equal (plist-get added :lines) '("line 2.5")))
      (should (= (plist-get added :line-number) 3)))))

(ert-deftest ogent-ui-diff-strings-removed ()
  "Detect removed lines in context diff."
  (let* ((old "line 1\nline 2\nline 3")
         (new "line 1\nline 3")
         (diff (ogent-ui--diff-strings old new)))
    (should diff)
    (let ((removed (seq-find (lambda (d) (eq (plist-get d :type) :removed)) diff)))
      (should removed)
      (should (equal (plist-get removed :lines) '("line 2")))
      (should (= (plist-get removed :line-number) 2)))))

(ert-deftest ogent-ui-diff-strings-no-change ()
  "No diff when strings are identical."
  (let* ((text "line 1\nline 2\nline 3")
         (diff (ogent-ui--diff-strings text text)))
    (should-not diff)))

(ert-deftest ogent-ui-diff-strings-multiple-changes ()
  "Detect multiple changes in one diff."
  (let* ((old "line 1\nline 2\nline 3\nline 4")
         (new "line 1\nline 2 modified\nline 3\nline 5")
         (diff (ogent-ui--diff-strings old new)))
    (should diff)
    ;; Should have both removed and added entries
    (should (seq-find (lambda (d) (eq (plist-get d :type) :removed)) diff))
    (should (seq-find (lambda (d) (eq (plist-get d :type) :added)) diff))))

(ert-deftest ogent-ui-apply-diff-overlays ()
  "Apply diff overlays to buffer."
  (with-temp-buffer
    (org-mode)
    (insert "line 1\nline 2\nline 3\n")
    (let ((diff '((:type :added :lines ("line 2") :line-number 2))))
      (ogent-ui--apply-diff-overlays diff)
      (should ogent-ui--diff-overlays)
      (should (= 1 (length ogent-ui--diff-overlays)))
      (let ((ov (car ogent-ui--diff-overlays)))
        (should (overlay-get ov 'ogent-diff))
        (should (eq (overlay-get ov 'face) 'ogent-context-diff-added))))))

(ert-deftest ogent-ui-clear-diff-overlays ()
  "Clear all diff overlays."
  (with-temp-buffer
    (org-mode)
    (insert "line 1\nline 2\nline 3\n")
    (let ((diff '((:type :added :lines ("line 2") :line-number 2))))
      (ogent-ui--apply-diff-overlays diff)
      (should ogent-ui--diff-overlays)
      (ogent-ui--clear-diff-overlays)
      (should-not ogent-ui--diff-overlays)
      ;; Overlays should be deleted from buffer
      (should-not (seq-find (lambda (ov) (overlay-get ov 'ogent-diff))
                           (overlays-in (point-min) (point-max)))))))

(ert-deftest ogent-ui-diff-overlays-multiple-lines ()
  "Apply overlays for multiple consecutive lines."
  (with-temp-buffer
    (org-mode)
    (insert "line 1\nline 2\nline 3\nline 4\n")
    (let ((diff '((:type :removed :lines ("line 2" "line 3") :line-number 2))))
      (ogent-ui--apply-diff-overlays diff)
      (should (= 2 (length ogent-ui--diff-overlays)))
      (dolist (ov ogent-ui--diff-overlays)
        (should (eq (overlay-get ov 'face) 'ogent-context-diff-removed))))))

(ert-deftest ogent-ui-context-preview-tracks-previous ()
  "Context preview stores previous context."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n")
    (let* ((ogent-context-preview-buffer-name "*test-context*")
           (buffer (get-buffer-create ogent-context-preview-buffer-name)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (org-mode)
              (setq ogent-ui--previous-context nil)
              ;; First update
              (erase-buffer)
              (setq ogent-ui--previous-context nil)
              (insert "Root: test")
              (setq ogent-ui--previous-context "Root: test")
              (should (equal ogent-ui--previous-context "Root: test"))
              ;; Second update with diff
              (erase-buffer)
              (let ((previous ogent-ui--previous-context))
                (insert "Root: modified")
                (let ((diff (ogent-ui--diff-strings previous "Root: modified")))
                  (should diff)
                  (should (seq-find (lambda (d) (eq (plist-get d :type) :removed)) diff))
                  (should (seq-find (lambda (d) (eq (plist-get d :type) :added)) diff)))
                (setq ogent-ui--previous-context "Root: modified"))))
        (kill-buffer buffer)))))

;;; Error Collection and Display Tests

(ert-deftest ogent-ui-record-error ()
  "Test error recording."
  (let ((ogent-ui--error-history nil))
    (with-temp-buffer
      (org-mode)
      (let* ((request (make-ogent-ui-request
                       :id "test-error-req"
                       :model '(:id "gpt-4o-mini")
                       :context '(:root nil)
                       :prompt "Test prompt"
                       :buffer (current-buffer)
                       :marker (point-marker)))
             (record (ogent-ui--record-error request "API rate limit exceeded")))
        (should record)
        (should (= 1 (length ogent-ui--error-history)))
        (should (equal (plist-get record :error) "API rate limit exceeded"))
        (should (equal (plist-get record :model) "gpt-4o-mini"))
        (should (equal (plist-get record :request-id) "test-error-req"))
        (should (equal (plist-get record :prompt) "Test prompt"))
        (should (plist-get record :timestamp))))))

(ert-deftest ogent-ui-error-history-limit ()
  "Test error history is limited to 50 entries."
  (let ((ogent-ui--error-history nil))
    (with-temp-buffer
      (org-mode)
      (dotimes (i 60)
        (let ((request (make-ogent-ui-request
                        :id (format "req-%d" i)
                        :model '(:id "test-model")
                        :context '(:root nil)
                        :prompt "test"
                        :buffer (current-buffer)
                        :marker (point-marker))))
          (ogent-ui--record-error request (format "Error %d" i))))
      ;; Should be capped at 50
      (should (= 50 (length ogent-ui--error-history)))
      ;; Most recent error should be first
      (should (string-match-p "Error 59" (plist-get (car ogent-ui--error-history) :error))))))

(ert-deftest ogent-ui-format-error-for-display ()
  "Test error formatting for display."
  (let* ((timestamp (encode-time 0 30 12 13 12 2025))
         (record (list :timestamp timestamp
                       :model "claude-3.5-sonnet"
                       :error "Connection timeout"
                       :request-id "req-123"
                       :prompt "This is a test prompt that is quite long and should be truncated"))
         (formatted (ogent-ui--format-error-for-display record)))
    (should (stringp formatted))
    (should (string-match-p "\\*\\* \\[2025-12-13 12:30:00\\]" formatted))
    (should (string-match-p "claude-3.5-sonnet" formatted))
    (should (string-match-p "Connection timeout" formatted))
    (should (string-match-p "req-123" formatted))))

(ert-deftest ogent-ui-surface-error-creates-buffer ()
  "Test that surfacing error creates and displays buffer."
  (let ((ogent-ui--error-history nil)
        (ogent-errors-buffer-name "*test-ogent-errors*"))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (let ((request (make-ogent-ui-request
                          :id "surface-test"
                          :model '(:id "test-model")
                          :context '(:root nil)
                          :prompt "test"
                          :buffer (current-buffer)
                          :marker (point-marker))))
            (ogent-ui--surface-error request "Test error message")
            ;; Error should be recorded
            (should (= 1 (length ogent-ui--error-history)))
            ;; Buffer should exist
            (let ((error-buffer (get-buffer ogent-errors-buffer-name)))
              (should error-buffer)
              (with-current-buffer error-buffer
                (goto-char (point-min))
                (should (search-forward "* Error History" nil t))
                (should (search-forward "Test error message" nil t))))))
      ;; Cleanup
      (when-let ((buf (get-buffer ogent-errors-buffer-name)))
        (kill-buffer buf)))))

(ert-deftest ogent-ui-clear-errors ()
  "Test clearing error history."
  (let ((ogent-ui--error-history '((:error "test")))
        (ogent-errors-buffer-name "*test-ogent-errors*"))
    (unwind-protect
        (progn
          (ogent-ui--update-error-buffer)
          ;; Simulate yes-or-no-p returning t
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
            (ogent-clear-errors))
          ;; History should be cleared
          (should (null ogent-ui--error-history))
          ;; Buffer should show no errors
          (let ((buffer (get-buffer ogent-errors-buffer-name)))
            (when buffer
              (with-current-buffer buffer
                (goto-char (point-min))
                (should (search-forward "No errors recorded" nil t))))))
      ;; Cleanup
      (when-let ((buf (get-buffer ogent-errors-buffer-name)))
        (kill-buffer buf)))))

(ert-deftest ogent-ui-show-errors ()
  "Test show-errors command."
  (let ((ogent-ui--error-history nil)
        (ogent-errors-buffer-name "*test-ogent-errors*"))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (let ((request (make-ogent-ui-request
                          :id "show-test"
                          :model '(:id "test-model")
                          :context '(:root nil)
                          :prompt "test"
                          :buffer (current-buffer)
                          :marker (point-marker))))
            (ogent-ui--record-error request "Error to show")
            ;; Show errors should display buffer and select window
            (ogent-show-errors)
            ;; Window should be selected
            (should ogent-ui--error-window)
            (should (window-live-p ogent-ui--error-window))
            (should (equal (buffer-name (window-buffer ogent-ui--error-window))
                          ogent-errors-buffer-name))))
      ;; Cleanup
      (when (and ogent-ui--error-window (window-live-p ogent-ui--error-window))
        (delete-window ogent-ui--error-window))
      (when-let ((buf (get-buffer ogent-errors-buffer-name)))
        (kill-buffer buf)))))

(ert-deftest ogent-ui-insert-error-block-surfaces-error ()
  "Test that inserting error block also surfaces it."
  (let ((ogent-ui--error-history nil)
        (ogent-errors-buffer-name "*test-ogent-errors*"))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (insert "* Test\n\n")
          (let ((request (make-ogent-ui-request
                          :id "insert-test"
                          :model '(:id "test-model")
                          :context '(:root nil)
                          :prompt "test"
                          :buffer (current-buffer)
                          :marker (copy-marker (point) t))))
            (ogent-ui--insert-error-block request "Insertion test error")
            ;; Error block should be inserted
            (goto-char (point-min))
            (should (search-forward "#+begin_quote ogent-error" nil t))
            (should (search-forward "Insertion test error" nil t))
            ;; Error should also be surfaced
            (should (= 1 (length ogent-ui--error-history)))
            (let ((error-buffer (get-buffer ogent-errors-buffer-name)))
              (should error-buffer)
              (with-current-buffer error-buffer
                (goto-char (point-min))
                (should (search-forward "Insertion test error" nil t))))))
      ;; Cleanup
      (when-let ((buf (get-buffer ogent-errors-buffer-name)))
        (kill-buffer buf)))))

(ert-deftest ogent-ui-session-buffer-appends-at-end ()
  "Session buffers always append new requests at point-max."
  (let ((text-buffer (get-buffer-create "*test-append-end*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (with-current-buffer companion
              ;; Verify it's marked as session buffer
              (should ogent-session-buffer-p)
              ;; Add initial content
              (goto-char (point-max))
              (insert "* First Request\n** Response\nFirst response here\n\n")
              (let ((first-request-pos (save-excursion
                                         (goto-char (point-min))
                                         (search-forward "* First Request")
                                         (line-beginning-position))))
                ;; Move point to beginning (simulating user scrolling up)
                (goto-char (point-min))
                (should (= (point) (point-min)))
                ;; Create a new response block
                (let* ((model '(:id "test-model" :backend gptel-openai))
                       (block (ogent-ui--create-response-block
                               "Second request" '() model)))
                  ;; New content should be at end, after First Request
                  (goto-char (point-min))
                  (search-forward "* First Request")
                  (should (search-forward "** Request: Second request"))
                  ;; Verify First Request position hasn't changed
                  (goto-char (point-min))
                  (search-forward "* First Request")
                  (should (= (line-beginning-position) first-request-pos)))))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-ui-session-buffer-appends-regardless-of-point ()
  "New requests append at end even when point is in middle of buffer."
  (let ((text-buffer (get-buffer-create "*test-append-middle*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (with-current-buffer companion
              (should ogent-session-buffer-p)
              ;; Add multiple requests
              (goto-char (point-max))
              (insert "** Request 1\n*** Response\nResponse 1\n\n")
              (insert "** Request 2\n*** Response\nResponse 2\n\n")
              ;; Position in the middle
              (goto-char (point-min))
              (search-forward "Request 1")
              (let ((middle-point (point)))
                ;; Create new request (point is in middle)
                (let* ((model '(:id "test-model"))
                       (block (ogent-ui--create-response-block
                               "Request 3" '() model)))
                  ;; Should be at end, after Request 2
                  (goto-char (point-min))
                  (search-forward "** Request 1")
                  (search-forward "** Request 2")
                  (should (search-forward "** Request: Request 3"))
                  ;; Middle content position should be unchanged
                  (goto-char (point-min))
                  (search-forward "Request 1")
                  (should (= (point) middle-point)))))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-ui-regular-org-respects-current-position ()
  "Regular Org buffers (non-session) use current heading position."
  (ogent-test-with-fixture "data/fixture.org"
    (lambda ()
      ;; Regular org file should not be marked as session buffer
      (should-not ogent-session-buffer-p)
      ;; Find a specific heading
      (goto-char (point-min))
      (search-forward "Root Overview")
      (org-back-to-heading t)
      (let ((start-pos (point)))
        ;; Create response block
        (let* ((model '(:id "test-model"))
               (block (ogent-ui--create-response-block
                       "Test at heading" '() model)))
          ;; Should insert after current subtree (Root Overview + children)
          ;; Verify it comes after Deep Note (end of subtree)
          (goto-char start-pos)
          (should (search-forward "Deep Note"))
          (should (search-forward "** Request: Test at heading"))
          ;; But before Appendix Note (next top-level heading)
          (should (search-forward "* Appendix Note")))))))

(ert-deftest ogent-ui-session-buffer-multiple-requests ()
  "Session buffer correctly handles multiple sequential requests."
  (let ((text-buffer (get-buffer-create "*test-multi-append*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (fundamental-mode)
          (let ((companion (ogent-companion-get-or-create)))
            (with-current-buffer companion
              (should ogent-session-buffer-p)
              ;; Create multiple requests from different cursor positions
              (goto-char (point-min))
              (let* ((model '(:id "test-model"))
                     (block1 (ogent-ui--create-response-block "First" '() model)))
                (goto-char (point-min))  ; Reset to top
                (let ((block2 (ogent-ui--create-response-block "Second" '() model)))
                  (goto-char (1+ (point-min)))  ; Some random position
                  (let ((block3 (ogent-ui--create-response-block "Third" '() model)))
                    ;; All should be in order at end (after * Session heading)
                    (goto-char (point-min))
                    (search-forward "* Session")
                    (should (search-forward "** Request: First"))
                    (should (search-forward "** Request: Second"))
                    (should (search-forward "** Request: Third"))
                    ;; No more requests after Third
                    (should-not (search-forward "** Request:" nil t))))))
            (kill-buffer companion)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-ui-auto-scroll-enabled-on-request ()
  "Auto-scroll is enabled when a new request starts."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-auto-scroll t)
           (ogent-ui--selected-models '("gpt-4o-mini")))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    ;; Verify auto-scroll was enabled when request registered
                    (should ogent--auto-scroll-enabled)
                    (when-let ((callback (plist-get args :callback)))
                      (funcall callback "Test" nil)
                      (funcall callback nil '(:done t)))
                    'mock-request)))
         (ogent-request "Test prompt" '("gpt-4o-mini")))))))

(ert-deftest ogent-ui-auto-scroll-respects-global-disable ()
  "Auto-scroll is not enabled when globally disabled."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-auto-scroll nil)
           (ogent-ui--selected-models '("gpt-4o-mini")))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    ;; Verify auto-scroll was NOT enabled
                    (should-not ogent--auto-scroll-enabled)
                    (when-let ((callback (plist-get args :callback)))
                      (funcall callback "Test" nil)
                      (funcall callback nil '(:done t)))
                    'mock-request)))
         (ogent-request "Test prompt" '("gpt-4o-mini")))))))

(ert-deftest ogent-ui-at-window-bottom-p-detects-position ()
  "ogent-ui--at-window-bottom-p correctly detects if at bottom."
  (with-temp-buffer
    (insert "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n")
    (goto-char (point-max))
    (should (ogent-ui--at-window-bottom-p))))

;;; Heading Shift Tests

(ert-deftest ogent-ui-shift-org-headings-basic ()
  "Shift single-level org headings by response heading level."
  (let ((ogent-shift-response-headings t))
    ;; Level 1 heading becomes level 4 (1 + 3)
    (should (equal (ogent-ui--shift-org-headings "* Heading\n")
                   "**** Heading\n"))
    ;; Level 2 heading becomes level 5 (2 + 3)
    (should (equal (ogent-ui--shift-org-headings "** Subheading\n")
                   "***** Subheading\n"))
    ;; Level 3 heading becomes level 6 (3 + 3)
    (should (equal (ogent-ui--shift-org-headings "*** Deep\n")
                   "****** Deep\n"))))

(ert-deftest ogent-ui-shift-org-headings-mixed-content ()
  "Shift headings in mixed content without affecting other text."
  (let ((ogent-shift-response-headings t))
    (should (equal (ogent-ui--shift-org-headings
                    "Some text\n* Heading\nMore text\n** Another\n")
                   "Some text\n**** Heading\nMore text\n***** Another\n"))))

(ert-deftest ogent-ui-shift-org-headings-preserves-emphasis ()
  "Don't shift emphasis markers like *bold* or **strong**."
  (let ((ogent-shift-response-headings t))
    ;; Inline emphasis should not be affected
    (should (equal (ogent-ui--shift-org-headings "This is *bold* text\n")
                   "This is *bold* text\n"))
    ;; Emphasis at start of line but not a heading (no space after)
    (should (equal (ogent-ui--shift-org-headings "*bold* at start\n")
                   "*bold* at start\n"))))

(ert-deftest ogent-ui-shift-org-headings-disabled ()
  "When disabled, headings are not shifted."
  (let ((ogent-shift-response-headings nil))
    (should (equal (ogent-ui--shift-org-headings "* Heading\n")
                   "* Heading\n"))))

(ert-deftest ogent-ui-shift-org-headings-empty-heading ()
  "Handle headings with no title (just stars and newline)."
  (let ((ogent-shift-response-headings t))
    ;; Heading with just stars and newline
    (should (equal (ogent-ui--shift-org-headings "*\n")
                   "****\n"))
    (should (equal (ogent-ui--shift-org-headings "**\n")
                   "*****\n"))))

(ert-deftest ogent-ui-streaming-shifts-headings ()
  "Streaming response chunks have headings shifted."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-shift-response-headings t)
           (ogent-ui--selected-models '("gpt-4o-mini")))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (when-let ((callback (plist-get args :callback)))
                      ;; Simulate LLM returning an org heading
                      (funcall callback "Here's a heading:\n* My Heading\nContent\n" nil)
                      (funcall callback nil '(:done t)))
                    'mock-request)))
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           ;; The heading should be shifted to level 4
           (should (search-forward "**** My Heading" nil t))
           ;; Original level 1 heading should NOT exist
           (goto-char (point-min))
           (should-not (search-forward "\n* My Heading" nil t))))))))

;;; Streaming Edge Cases

(ert-deftest ogent-ui-streaming-empty-chunks ()
  "Test streaming with empty chunks interspersed."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (ogent-test-with-streaming-mock '("Hello" "" " " "world" "" "!")
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           ;; Empty chunks should be handled gracefully
           (should (search-forward "Hello world!" nil t))))))))

(ert-deftest ogent-ui-streaming-unicode-chunks ()
  "Test streaming with unicode characters split across chunks."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (ogent-test-with-streaming-mock '("Hello " "world " "from " "Emacs")
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           (should (search-forward "Hello world from Emacs" nil t))))))))

(ert-deftest ogent-ui-streaming-large-response ()
  "Test streaming with many small chunks."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           ;; Generate 100 small chunks
           (chunks (make-list 100 "x")))
       (ogent-test-with-streaming-mock chunks
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           ;; Should have 100 x's concatenated
           (should (search-forward (make-string 100 ?x) nil t))))))))

(ert-deftest ogent-ui-streaming-error-mid-stream ()
  "Test error occurring after partial response."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (_prompt &rest args)
                    (when-let ((callback (plist-get args :callback)))
                      ;; First some content arrives
                      (funcall callback "Partial response..." nil)
                      ;; Then an error occurs
                      (funcall callback nil '(:error "Connection reset")))
                    'mock-request)))
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           ;; Partial content should still be present
           (should (search-forward "Partial response..." nil t))
           ;; Error should be recorded
           (should (>= (length ogent-ui--error-history) 1))))))))

(ert-deftest ogent-ui-streaming-newlines-preserved ()
  "Test that newlines in streamed content are preserved."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (ogent-test-with-streaming-mock '("Line 1\n" "Line 2\n" "Line 3")
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           (should (search-forward "Line 1\nLine 2\nLine 3" nil t))))))))

(ert-deftest ogent-ui-streaming-code-block-content ()
  "Test streaming content that includes org code blocks."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini")))
       (ogent-test-with-streaming-mock
           '("Here's code:\n" "#+begin_src elisp\n" "(message \"hi\")\n" "#+end_src")
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           ;; The nested code block should be preserved
           (should (search-forward "#+begin_src elisp" nil t))
           (should (search-forward "(message \"hi\")" nil t))))))))

;;; Error Injection Tests

(ert-deftest ogent-ui-error-api-rate-limit ()
  "Test handling of API rate limit error."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           (ogent-ui--error-history nil))
       (ogent-test-with-error-mock "Rate limit exceeded. Please retry after 60 seconds."
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         ;; Error should be recorded in history
         (should (= 1 (length ogent-ui--error-history)))
         (should (string-match-p "Rate limit"
                                 (plist-get (car ogent-ui--error-history) :error))))))))

(ert-deftest ogent-ui-error-invalid-api-key ()
  "Test handling of invalid API key error."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           (ogent-ui--error-history nil))
       (ogent-test-with-error-mock "Invalid API key provided"
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (should (= 1 (length ogent-ui--error-history)))
         (should (string-match-p "Invalid API key"
                                 (plist-get (car ogent-ui--error-history) :error))))))))

(ert-deftest ogent-ui-error-context-too-long ()
  "Test handling of context length exceeded error."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           (ogent-ui--error-history nil))
       (ogent-test-with-error-mock "This model's maximum context length is 128000 tokens"
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (should (= 1 (length ogent-ui--error-history)))
         (should (string-match-p "context length"
                                 (plist-get (car ogent-ui--error-history) :error))))))))

(ert-deftest ogent-ui-error-network-timeout ()
  "Test handling of network timeout."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           (ogent-ui--error-history nil))
       (ogent-test-with-error-mock "Connection timed out"
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (should (= 1 (length ogent-ui--error-history))))))))

(ert-deftest ogent-ui-error-malformed-response ()
  "Test handling of malformed JSON response."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           (ogent-ui--error-history nil))
       (ogent-test-with-error-mock "JSON parse error: unexpected character at position 0"
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (should (= 1 (length ogent-ui--error-history))))))))

(ert-deftest ogent-ui-multiple-errors-recorded ()
  "Test that multiple errors are recorded in history."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("gpt-4o-mini"))
           (ogent-ui--error-history nil))
       ;; First error
       (ogent-test-with-error-mock "Error 1"
         (ogent-request "Test prompt 1" '("gpt-4o-mini")))
       ;; Second error
       (ogent-test-with-error-mock "Error 2"
         (ogent-request "Test prompt 2" '("gpt-4o-mini")))
       ;; Both should be recorded
       (should (= 2 (length ogent-ui--error-history)))))))

(provide 'ogent-ui-tests)
;;; ogent-ui-tests.el ends here
