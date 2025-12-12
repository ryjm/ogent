;;; ogent-ui-tests.el --- Tests for ogent UI layer -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-context)

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
  "ogent-request uses gptel and streams response outside the src block."
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
           ;; The src block should be closed before the response
           (search-forward "#+begin_src text :model gpt-4o-mini")
           (search-forward "#+end_src")
           ;; Response streams after the src block under ** Response heading
           (search-forward "** Response")
           (search-forward "Hello world")))))))

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
  "Tool blocks follow gptel format."
  (with-temp-buffer
    (org-mode)
    (ogent-ui--insert-tool-block "search" '(:query "test") "Result text")
    (goto-char (point-min))
    (should (search-forward "#+begin_tool search" nil t))
    (should (search-forward "Args:" nil t))
    (should (search-forward "Result:" nil t))
    (should (search-forward "#+end_tool" nil t))))

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

(provide 'ogent-ui-tests)
;;; ogent-ui-tests.el ends here
