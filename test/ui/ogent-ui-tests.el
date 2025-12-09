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
  "ogent-request uses gptel and streams into the Org block."
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
           (search-forward "#+begin_src text :model gpt-4o-mini")
           (search-forward "Hello world")
           (search-forward "#+end_src")))))))

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

(provide 'ogent-ui-tests)
;;; ogent-ui-tests.el ends here
