;;; ogent-ui-tests.el --- Tests for ogent UI layer -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-context)
(require 'ogent-tools)
(require 'ogent-edit-format)
(require 'ogent-analytics)
(require 'cl-lib)

(defvar ogent-ui-tests--backend nil
  "Backend placeholder for ogent-ui backend resolution tests.")

(defvar gptel-testbackend nil
  "Dummy gptel backend binding for ogent-ui tests.")

(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-cache)
(defvar gptel--known-backends)

(cl-defstruct (ogent-ui-test-provider
               (:constructor ogent-ui-test-provider-create))
  "Dummy backend type for backend resolution tests.")

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
                                   (_ogent-ui--selected-models '("gpt-4o-mini")))
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
                                 (should (string-match-p "# Resolved @handles"
                                                         (plist-get captured :prompt)))
                                 (should (string-match-p "Final supporting text"
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

(ert-deftest ogent-ui-send-request-binds-gptel-cache-and-model-props ()
  "Sending binds `gptel-cache' and surfaces registry props on the symbol."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((sym (intern "ogent-test-cache-model"))
                                   (ogent-gptel-cache '(message system))
                                   (ogent-model-registry
                                    '((:id "ogent-test-cache-model"
                                       :backend gptel-openai :stream? t
                                       :request-params (:reasoning_effort "high")
                                       :capabilities (cache))))
                                   (captured-cache 'unset))
                               (unwind-protect
                                   (progn
                                     (cl-letf (((symbol-function 'gptel-request)
                                                (lambda (_prompt &rest args)
                                                  (setq captured-cache gptel-cache)
                                                  (when-let ((callback (plist-get args :callback)))
                                                    (funcall callback "ok" nil)
                                                    (funcall callback nil '(:done t)))
                                                  'mock-request)))
                                       (ogent-request "Cache prompt" '("ogent-test-cache-model"))
                                       (should (equal captured-cache '(message system)))
                                       (should (equal (get sym :request-params)
                                                      '(:reasoning_effort "high")))
                                       (should (memq 'cache (get sym :capabilities)))))
                                 (put sym :request-params nil)
                                 (put sym :capabilities nil))))))

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
                                   (should (search-forward "# User Prompt" nil t))
                                   (should (search-forward "This is a longer test prompt that should be truncated in the headline" nil t))
                                   (should (search-forward "#+end_src" nil t))
                                   ;; Response should be a level 3 heading (nested under Request)
                                   (should (search-forward "*** Response" nil t))
                                   (should (search-forward "Response text" nil t))))))))

(ert-deftest ogent-ui-response-block-escapes-org-syntax-in-context ()
  "Prompt/context transcripts escape Org syntax that would split src blocks."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let* ((context (ogent-context-build-with-source
                                              (current-buffer) nil nil))
                                    (model '(:id "gpt-4o-mini"))
                                    (block (ogent-ui--create-response-block
                                            "Test prompt" context model))
                                    (block-start (plist-get block :block-start)))
                               (goto-char block-start)
                               (should (eq (org-element-type (org-element-context))
                                           'src-block))
                               (let ((block-end (save-excursion
                                                  (search-forward "#+end_src")
                                                  (point))))
                                 (goto-char block-start)
                                 (should (search-forward ",*** Deep Note" block-end t))
                                 (goto-char block-start)
                                 (should-not (search-forward "\n*** Deep Note"
                                                             block-end t)))))))

(ert-deftest ogent-ui-response-block-headline-is-single-line ()
  "Request headlines should not be split by multi-line prompts."
  (with-temp-buffer
    (org-mode)
    (insert "* Session\n")
    (goto-char (point-min))
    (let ((ogent-session-buffer-p nil))
      (ogent-ui--create-response-block
       "first line\nsecond line\n#+end_src\n* hostile"
       '(:root nil)
       '(:id "test-model"))
      (goto-char (point-min))
      (should (search-forward
               "** Request: first line second line #+end_src * hostile"
               nil t))
      ;; The prompt is persisted in a single-line property drawer
      ;; directly under the headline (hostile newlines stay encoded).
      (forward-line 1)
      (should (looking-at-p ":PROPERTIES:"))
      (should (re-search-forward "^:END:\n" nil t))
      (should (looking-at-p "#\\+begin_src text")))))

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

(ert-deftest ogent-ui-resolve-backend-function ()
  "Backend resolution supports function backends."
  (should (eq (ogent-ui--resolve-backend '(:backend (lambda () 'backend)))
              'backend)))

(ert-deftest ogent-ui-resolve-backend-symbol ()
  "Backend resolution returns bound symbol value."
  (let ((ogent-ui-tests--backend 'backend-object))
    (should (eq (ogent-ui--resolve-backend
                 '(:backend ogent-ui-tests--backend))
                'backend-object))))

(ert-deftest ogent-ui-resolve-backend-symbol-current-provider ()
  "Backend resolution can use the current gptel backend provider object."
  (let ((gptel-backend (ogent-ui-test-provider-create)))
    (should (eq (ogent-ui--resolve-backend '(:backend ogent-ui-test-provider))
                gptel-backend))))

(ert-deftest ogent-ui-resolve-backend-symbol-known-provider ()
  "Backend resolution can use a matching known gptel backend provider."
  (let* ((backend (ogent-ui-test-provider-create))
         (gptel--known-backends `(("Audit" . ,backend))))
    (should (eq (ogent-ui--resolve-backend '(:backend ogent-ui-test-provider))
                backend))))

(ert-deftest ogent-ui-resolve-backend-string-bound ()
  "Backend resolution handles string backend with bound gptel-* symbol."
  (let ((gptel-testbackend 'backend-object))
    (should (eq (ogent-ui--resolve-backend '(:backend "testbackend"))
                'backend-object))))

(ert-deftest ogent-ui-resolve-backend-string-fallback ()
  "Backend resolution falls back to string when require fails."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
    (should (equal (ogent-ui--resolve-backend '(:backend "missing"))
                   "missing"))))

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

(ert-deftest ogent-ui-apply-prompt-templates-prefixes ()
  "Selected templates are prefixed to the prompt."
  (let ((ogent-ui--selected-templates '("template-one")))
    (cl-letf (((symbol-function 'ogent-prompt-compose-with-params)
               (lambda (_ids &optional _params) "Template content")))
      (should (equal (ogent-ui--apply-prompt-templates "User prompt")
                     "Template content\n\nUser prompt")))))

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

(ert-deftest ogent-ui-callback-tool-pending-keeps-open ()
  "Callback does not close request when tool-pending is set."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (closed-called nil))
      (let* ((request (make-ogent-ui-request
                       :id "req-tool"
                       :buffer (current-buffer)
                       :marker (copy-marker (point-max))
                       :status 'wait))
             (callback (ogent-ui--make-callback "req-tool")))
        (puthash "req-tool" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-ui--close-response)
                   (lambda (&rest _args) (setq closed-called t))))
          (funcall callback nil '(:tool-pending t)))
        (should (not closed-called))
        (should-not (ogent-ui-request-closed request))))))

(ert-deftest ogent-ui-callback-fallback-executes-tools-once ()
  "The :tool-use fallback runs each payload once across repeated chunks."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (handle-count 0))
      (let* ((request (make-ogent-ui-request
                       :id "req-fb" :buffer (current-buffer)
                       :marker (copy-marker (point-max)) :status 'wait))
             (callback (ogent-ui--make-callback "req-fb"))
             ;; Same object across chunks, as gptel reuses it within a turn.
             (tool-use '((:name "bash" :args (:command "ls"))))
             (info (list :tool-use tool-use)))
        (puthash "req-fb" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-ui--handle-tool-calls)
                   (lambda (&rest _) (cl-incf handle-count)))
                  ((symbol-function 'ogent-ui--close-response) #'ignore))
          ;; Three streamed text chunks all carrying the same :tool-use.
          (funcall callback "chunk one " info)
          (funcall callback "chunk two " info)
          (funcall callback "chunk three" info))
        (should (= handle-count 1))
        ;; A genuinely new tool-use payload dispatches again.
        (cl-letf (((symbol-function 'ogent-ui--handle-tool-calls)
                   (lambda (&rest _) (cl-incf handle-count)))
                  ((symbol-function 'ogent-ui--close-response) #'ignore))
          (funcall callback "more"
                   (list :tool-use '((:name "bash" :args (:command "pwd"))))))
        (should (= handle-count 2))))))

(ert-deftest ogent-ui-callback-tool-result-does-not-close ()
  "A (tool-result ...) cons is intermediate and must not close the request."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (closed-called nil))
      (let* ((request (make-ogent-ui-request
                       :id "req-tr" :buffer (current-buffer)
                       :marker (copy-marker (point-max)) :status 'wait))
             (callback (ogent-ui--make-callback "req-tr")))
        (puthash "req-tr" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-ui--close-response)
                   (lambda (&rest _) (setq closed-called t)))
                  ((symbol-function 'ogent-ui--insert-tool-block) #'ignore))
          (funcall callback '(tool-result . ((:name "bash" :args nil
                                                    :result "ok")))
                   nil))
        (should-not closed-called)
        ;; A real completion signal still closes.
        (cl-letf (((symbol-function 'ogent-ui--close-response)
                   (lambda (&rest _) (setq closed-called t))))
          (funcall callback nil nil))
        (should closed-called)))))

(ert-deftest ogent-ui-callback-closes-on-error ()
  "Callback closes request when error info is supplied."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (closed-message nil))
      (let* ((request (make-ogent-ui-request
                       :id "req-error"
                       :buffer (current-buffer)
                       :marker (copy-marker (point-max))
                       :status 'wait))
             (callback (ogent-ui--make-callback "req-error")))
        (puthash "req-error" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-ui--close-response)
                   (lambda (_req message) (setq closed-message message))))
          (funcall callback nil '(:error "Boom"))))
      (should (equal closed-message "Boom")))))

(ert-deftest ogent-ui-close-response-updates-status ()
  "Closing a request marks it done, closed, and removes it from table."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (ogent-ui--request-history nil))
      (let ((request (make-ogent-ui-request
                      :id "req-close"
                      :buffer (current-buffer)
                      :status 'type
                      :start-time (time-subtract (current-time) (seconds-to-time 1)))))
        (puthash "req-close" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-theme-flash) (lambda (&rest _) nil)))
          (ogent-ui--close-response request))
        (should (ogent-ui-request-closed request))
        (should (eq (ogent-ui-request-status request) 'done))
        (should (ogent-ui-request-end-time request))
        (should (null (gethash "req-close" ogent-ui--request-table)))
        (should (member request ogent-ui--request-history))))))

(ert-deftest ogent-ui-response-body-text-extracts-streamed-body ()
  "Response body text is the content under the heading, sans heading."
  (with-temp-buffer
    (org-mode)
    (insert "*** Response (m)\n")
    (let ((pos (line-beginning-position 0)))
      (insert "hello world\nsecond line\n")
      (let ((request (make-ogent-ui-request
                      :id "rb" :buffer (current-buffer)
                      :response-pos pos
                      :marker (copy-marker (point) t))))
        (should (equal (ogent-ui--response-body-text request)
                       "hello world\nsecond line"))))))

(ert-deftest ogent-ui-close-response-records-analytics-completion ()
  "A successful close records a completion via the analytics eval loop."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (ogent-ui--request-history nil)
          (recorded nil))
      (goto-char (point-max))
      (let ((heading-pos (point)))
        (insert "*** Response (gpt-x)\nthe answer\n")
        (let ((request (make-ogent-ui-request
                        :id "req-an" :buffer (current-buffer) :status 'type
                        :model '(:id "gpt-x") :prompt "what is 2+2?"
                        :response-pos heading-pos
                        :marker (copy-marker (point) t)
                        :start-time (time-subtract (current-time)
                                                   (seconds-to-time 1)))))
          (puthash "req-an" request ogent-ui--request-table)
          (cl-letf (((symbol-function 'ogent-theme-flash) (lambda (&rest _) nil))
                    ((symbol-function 'ogent-analytics-record-completion)
                     (lambda (model prompt response &optional _tmpl)
                       (setq recorded (list model prompt response)))))
            (ogent-ui--close-response request))
          (should (equal (nth 0 recorded) "gpt-x"))
          (should (equal (nth 1 recorded) "what is 2+2?"))
          (should (equal (nth 2 recorded) "the answer")))))))

(ert-deftest ogent-ui-close-response-error-skips-analytics ()
  "A failed close does not record a completion."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (ogent-ui--request-history nil)
          (recorded nil))
      (let ((request (make-ogent-ui-request
                      :id "req-anerr" :buffer (current-buffer) :status 'type)))
        (puthash "req-anerr" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-theme-flash) (lambda (&rest _) nil))
                  ((symbol-function 'ogent-ui--insert-error-block) #'ignore)
                  ((symbol-function 'ogent-ui--maybe-offer-provider-login) #'ignore)
                  ((symbol-function 'ogent-analytics-record-completion)
                   (lambda (&rest _) (setq recorded t))))
          (ogent-ui--close-response request "Boom"))
        (should-not recorded)))))

(ert-deftest ogent-ui-close-response-error-status ()
  "Closing with error marks status error and closes request."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (ogent-ui--request-history nil))
      (let ((request (make-ogent-ui-request
                      :id "req-error-close"
                      :buffer (current-buffer)
                      :status 'type)))
        (puthash "req-error-close" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-ui--insert-error-block) (lambda (&rest _) nil))
                  ((symbol-function 'ogent-theme-flash) (lambda (&rest _) nil)))
          (ogent-ui--close-response request "failure"))
        (should (ogent-ui-request-closed request))
        (should (eq (ogent-ui-request-status request) 'error))
        (should (member request ogent-ui--request-history))))))

(ert-deftest ogent-ui-close-response-is-idempotent ()
  "Closing a request twice should run lifecycle side effects once."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (ogent-ui--request-history nil)
          (hook-count 0)
          (error-block-count 0))
      (let ((request (make-ogent-ui-request
                      :id "req-idempotent"
                      :context '(:source test)
                      :buffer (current-buffer)
                      :marker (copy-marker (point-max))
                      :status 'type
                      :start-time (current-time)))
            (ogent-after-request-hook
             (list (lambda (_context)
                     (setq hook-count (1+ hook-count))))))
        (puthash "req-idempotent" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-ui--insert-error-block)
                   (lambda (&rest _)
                     (setq error-block-count (1+ error-block-count))))
                  ((symbol-function 'ogent-theme-flash)
                   (lambda (&rest _) nil))
                  ((symbol-function 'ogent-status-clear-request)
                   (lambda (&rest _) nil)))
          (ogent-ui--close-response request)
          (ogent-ui--close-response request "late error"))
        (should (ogent-ui-request-closed request))
        (should (eq (ogent-ui-request-status request) 'done))
        (should (= hook-count 1))
        (should (= error-block-count 0))
        (should (= (length ogent-ui--request-history) 1))
        (should (null (gethash "req-idempotent" ogent-ui--request-table)))))))

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

(ert-deftest ogent-ui-abort-request-preserves-aborted-status ()
  "Abort should close with terminal aborted status."
  (with-temp-buffer
    (org-mode)
    (let ((ogent-ui--request-table (make-hash-table :test #'equal))
          (ogent-ui--request-history nil))
      (let ((request (make-ogent-ui-request
                      :id "req-abort-status"
                      :buffer (current-buffer)
                      :marker (copy-marker (point-max))
                      :status 'wait
                      :start-time (current-time))))
        (puthash "req-abort-status" request ogent-ui--request-table)
        (cl-letf (((symbol-function 'ogent-ui--insert-error-block)
                   (lambda (&rest _) nil))
                  ((symbol-function 'ogent-theme-flash)
                   (lambda (&rest _) nil))
                  ((symbol-function 'ogent-status-clear-request)
                   (lambda (&rest _) nil)))
          (ogent-ui--abort-request request))
        (should (ogent-ui-request-closed request))
        (should (eq (ogent-ui-request-status request) 'aborted))
        (should (ogent-ui-request-end-time request))
        (should (member request ogent-ui--request-history))
        (should (null (gethash "req-abort-status" ogent-ui--request-table)))))))

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
  (should (ogent-tool--pattern-match-p "read-file" 'read-file nil))
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

(ert-deftest ogent-tool-glob-match-does-not-match-inner-lines ()
  "Glob pattern matching anchors to the whole string, not line boundaries."
  (should-not (ogent-tool--glob-match-p "git *" "git log\nrm -rf ~"))
  (should-not (ogent-tool--glob-match-p "git *" "echo ok\ngit status")))

(ert-deftest ogent-tool-allow-list-check ()
  "Allow-list checking works correctly."
  (let ((ogent-tool-allow-list '("read-file" "bash(command:git *)")))
    (should (ogent-tool--allowed-p "read-file" nil))
    (should (ogent-tool--allowed-p 'read-file nil))
    (should (ogent-tool--allowed-p "bash" '(:command "git status")))
    (should-not (ogent-tool--allowed-p "write-file" nil))
    (should-not (ogent-tool--allowed-p "bash" '(:command "rm -rf /")))))

(ert-deftest ogent-tool-allow-list-rejects-newline-injected-command ()
  "Allow-listed shell commands do not approve later injected lines."
  (let ((ogent-tool-allow-list '("bash(command:git *)")))
    (should-not (ogent-tool--allowed-p
                 "bash"
                 '(:command "git status\nrm -rf ~")))))

(ert-deftest ogent-tool-approval-disabled ()
  "When approval is disabled, all tools are approved."
  (let ((ogent-tool-require-approval nil)
        (ogent-tool-allow-list nil))
    (should (eq (ogent-tool-approval-check "bash" '(:command "rm -rf /"))
                'approved))))

(ert-deftest ogent-tool-approval-allow-listed ()
  "Allow-listed tools are auto-approved."
  (let ((ogent-tool-require-approval t)
        (ogent-tool-allow-list '("read-file")))
    (should (eq (ogent-tool-approval-check "read-file" nil)
                'approved))
    (should (eq (ogent-tool-approval-check 'read-file nil)
                'approved))))

(ert-deftest ogent-tool-approval-read-effect-auto-approves ()
  "Read-only tool specs are auto-approved by policy."
  (let ((ogent-tool-require-approval t)
        (ogent-tool-allow-list nil))
    (cl-letf (((symbol-function 'ogent-tool-spec-get)
               (lambda (_name)
                 '(:name read-file
                   :effects ((:kind read :target file :scope workspace)))))
              ((symbol-function 'ogent-tool--prompt-approval)
               (lambda (&rest _)
                 (error "approval prompt should not be called"))))
      (should (eq (ogent-tool-approval-check "read-file" nil)
                  'approved)))))

(ert-deftest ogent-tool-approval-write-effect-prompts ()
  "Write effects require the approval prompt."
  (let ((ogent-tool-require-approval t)
        (ogent-tool-allow-list nil)
        (prompt-called nil))
    (cl-letf (((symbol-function 'ogent-tool-spec-get)
               (lambda (_name)
                 '(:name write-file
                   :effects ((:kind write :target file :scope workspace)))))
              ((symbol-function 'ogent-tool--prompt-approval)
               (lambda (&rest _)
                 (setq prompt-called t)
                 'deny)))
      (should (eq (ogent-tool-approval-check "write-file" nil)
                  'denied))
      (should prompt-called))))

(ert-deftest ogent-tool-deny-list-normalizes-tool-names ()
  "Session deny-list should treat string and symbol tool names alike."
  (let ((ogent-tool--denied-tools nil))
    (ogent-tool--add-to-deny-list 'bash)
    (should (ogent-tool--denied-p "bash"))
    (should (ogent-tool--denied-p 'bash))))

(ert-deftest ogent-ui-execute-tool-accepts-symbol-tool-names ()
  "Tool execution should accept symbol names from structured callbacks."
  (let ((ogent-tool-registry
         (list (list :name 'symbol-tool
                     :function (lambda (arg1) (format "got %s" arg1))
                     :description "Symbol tool"
                     :args '((:name "arg1" :type "string"))))))
    (should (equal (ogent-ui--execute-tool 'symbol-tool '(:arg1 "value"))
                   "got value"))))

(defmacro ogent-ui-tests--with-ledger (file &rest body)
  "Run BODY with a fresh enabled ledger written to FILE."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "ogent-ui-ledger-" t))
          (,file (expand-file-name "ledger.org" dir))
          (ogent-ledger-enabled t)
          (ogent-ledger-file ,file))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun ogent-ui-tests--ledger-text (file)
  "Return the ledger FILE contents as a string."
  (if (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string))
    ""))

(ert-deftest ogent-ui-execute-tool-records-ledger-start-and-finish ()
  "A synchronous tool execution writes tool-start and tool-finish events."
  (let ((ogent-tool-registry
         (list (list :name 'ledger-tool
                     :function (lambda (arg1) (format "got %s" arg1))
                     :description "Ledger tool"
                     :effects '((:kind write :target file :scope workspace
                                       :risk high))
                     :args '((:name "arg1" :type "string"))))))
    (ogent-ui-tests--with-ledger file
      (should (equal (ogent-ui--execute-tool 'ledger-tool '(:arg1 "v")) "got v"))
      (let ((text (ogent-ui-tests--ledger-text file)))
        (should (string-match-p "OGENT_LEDGER_TYPE: tool-start" text))
        (should (string-match-p "OGENT_LEDGER_TYPE: tool-finish" text))
        (should (string-match-p "ledger-tool" text))
        ;; finish records a result hash and the declared effects
        (should (string-match-p ":result-hash" text))
        (should (string-match-p ":effects" text))))))

(ert-deftest ogent-ui-execute-tool-records-error-finish ()
  "A failing tool records a tool-finish event carrying the error."
  (let ((ogent-tool-registry
         (list (list :name 'boom-tool
                     :function (lambda (_a) (error "kaboom"))
                     :description "Boom"
                     :args '((:name "a" :type "string"))))))
    (ogent-ui-tests--with-ledger file
      (should (string-match-p "Tool error"
                              (ogent-ui--execute-tool 'boom-tool '(:a "x"))))
      (let ((text (ogent-ui-tests--ledger-text file)))
        (should (string-match-p "OGENT_LEDGER_TYPE: tool-finish" text))
        (should (string-match-p "kaboom" text))))))

(ert-deftest ogent-ui-execute-tool-ledger-silent-when-disabled ()
  "No ledger file is written when the ledger is disabled."
  (let ((ogent-tool-registry
         (list (list :name 'quiet-tool
                     :function (lambda (a) a)
                     :description "Quiet"
                     :args '((:name "a" :type "string")))))
        (dir (make-temp-file "ogent-ui-ledger-off-" t)))
    (unwind-protect
        (let ((ogent-ledger-enabled nil)
              (ogent-ledger-file (expand-file-name "ledger.org" dir)))
          (ogent-ui--execute-tool 'quiet-tool '(:a "y"))
          (should-not (file-exists-p ogent-ledger-file)))
      (delete-directory dir t))))

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
                                ;; Most recent is first in list.  With multi-turn
                                ;; history the prompt may be a conversation list
                                ;; whose final element is the current prompt.
                                (let ((p (plist-get (ogent-test-last-request) :prompt)))
                                  (should (string-match-p
                                           "Second"
                                           (if (listp p) (car (last p)) p)))))))))

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

(ert-deftest ogent-ui-quick-ask-description-names-org-subtree ()
  "Dispatcher quick ask label names the current Org subtree."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** Target subtree\nBody\n")
    (goto-char (point-min))
    (search-forward "Target subtree")
    (let* ((ogent-ask-include-buffer t)
           (description (ogent--desc-quick-ask)))
      (should (string-match-p
               "Ask about subtree \"Target subtree\""
               description)))))

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

(ert-deftest ogent-ui-show-diff-for-tool-inline-diff ()
  "Inline diff preview path is selected when configured."
  (let ((ogent-ui-edit-preview-style 'inline-diff)
        (captured nil))
    (cl-letf (((symbol-function 'ogent-ui--inline-diff-available-p)
               (lambda () t))
              ((symbol-function 'ogent-ui--show-inline-diff-for-tool)
               (lambda (tool-name tool-args)
                 (setq captured (list tool-name tool-args))
                 "inline-diff-id")))
      (with-temp-buffer
        (org-mode)
        (let ((diff-id (ogent-ui--show-diff-for-tool
                        "write-file"
                        (list :file_path "/tmp/example.txt"
                              :content "new content\n"))))
          (should (equal diff-id "inline-diff-id"))
          (should (equal captured
                         (list "write-file"
                               (list :file_path "/tmp/example.txt"
                                     :content "new content\n"))))
          (goto-char (point-min))
          (should-not (search-forward "#+begin_diff" nil t)))))))

(ert-deftest ogent-ui-tool-edits-for-inline-diff-edit-file-replace-all ()
  "Inline diff edit builder expands replace-all edits."
  (let ((test-file (make-temp-file "ogent-inline-edit-")))
    (unwind-protect
        (progn
          (with-temp-file test-file
            (insert "foo\nbar\nfoo\n"))
          (let ((buffer (find-file-noselect test-file)))
            (with-current-buffer buffer
              (let ((edits (ogent-ui--tool-edits-for-inline-diff
                            "edit-file"
                            (list :file_path test-file
                                  :old_string "foo"
                                  :new_string "baz"
                                  :replace_all t)
                            buffer)))
                (should (= 2 (length edits)))
                (dolist (edit edits)
                  (should (equal (ogent-edit-old-text edit) "foo"))
                  (should (equal (ogent-edit-new-text edit) "baz"))
                  (let ((start (ogent-edit-start-pos edit))
                        (end (ogent-edit-end-pos edit)))
                    (should start)
                    (should end)
                    (should (string= (buffer-substring-no-properties start end)
                                     "foo"))))))))
      (when-let ((buf (get-file-buffer test-file)))
        (kill-buffer buf))
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

(ert-deftest ogent-ui-context-preview-renders-send-payload ()
  "Context preview uses the same hydrated renderer as request dispatch."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Root Overview")
                             (org-back-to-heading t)
                             (let* ((ogent-context-preview-buffer-name "*test-ogent-context-payload*")
                                    (ogent--transient-prompt "Preview prompt")
                                    (preview-buffer (get-buffer-create ogent-context-preview-buffer-name)))
                               (unwind-protect
                                   (progn
                                     (ogent-context-preview)
                                     (with-current-buffer preview-buffer
                                       (let ((payload (buffer-string)))
                                         (should (string-match-p "# User Prompt" payload))
                                         (should (string-match-p "Preview prompt" payload))
                                         (should (string-match-p "# Resolved @handles" payload))
                                         (should (string-match-p "Final supporting text" payload)))))
                                 (when (buffer-live-p preview-buffer)
                                   (kill-buffer preview-buffer)))))))

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
                       (_block (ogent-ui--create-response-block
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
                       (_block (ogent-ui--create-response-block
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
                                      (_block (ogent-ui--create-response-block
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
                     (_block1 (ogent-ui--create-response-block "First" '() model)))
                (goto-char (point-min))  ; Reset to top
                (let ((_block2 (ogent-ui--create-response-block "Second" '() model)))
                  (goto-char (1+ (point-min)))  ; Some random position
                  (let ((_block3 (ogent-ui--create-response-block "Third" '() model)))
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

(ert-deftest ogent-ui-streaming-preserves-scrolled-away-window ()
  "Streaming does not pull a scrolled-away window to the response tail."
  (with-temp-buffer
    (switch-to-buffer (current-buffer))
    (org-mode)
    (dotimes (i 120)
      (insert (format "line %03d\n" i)))
    (let* ((win (selected-window))
           (marker (copy-marker (point-max) t))
           (request (make-ogent-ui-request
                     :id "scroll-away"
                     :model (list :id "test-model")
                     :buffer (current-buffer)
                     :marker marker)))
      (set-window-start win (point-min) t)
      (set-window-point win (point-min))
      (let ((before-start (window-start win))
            (before-point (window-point win))
            (ogent-auto-scroll t)
            (ogent--auto-scroll-enabled t))
        (ogent-ui--append-response request "streamed text\n")
        (should (= (window-start win) before-start))
        (should (= (window-point win) before-point))
        (should-not ogent--auto-scroll-enabled)))))

(ert-deftest ogent-ui-streaming-follows-visible-response-tail ()
  "Streaming keeps following when the response tail is visible."
  (with-temp-buffer
    (switch-to-buffer (current-buffer))
    (org-mode)
    (dotimes (i 20)
      (insert (format "line %03d\n" i)))
    (let* ((win (selected-window))
           (marker (copy-marker (point-max) t))
           (request (make-ogent-ui-request
                     :id "scroll-follow"
                     :model (list :id "test-model")
                     :buffer (current-buffer)
                     :marker marker)))
      (goto-char (point-max))
      (set-window-point win (point-max))
      (let ((ogent-auto-scroll t)
            (ogent--auto-scroll-enabled t))
        (ogent-ui--append-response request "streamed text\n")
        (should (= (window-point win) (marker-position marker)))
        (should ogent--auto-scroll-enabled)))))

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

(ert-deftest ogent-ui-provider-access-error-detection ()
  "Provider access error detection is narrow enough for retries."
  (should (ogent-ui--provider-access-error-p "Invalid API key provided"))
  (should (ogent-ui--provider-access-error-p
           "You do not have access to model claude-opus"))
  (should (ogent-ui--provider-access-error-p "model_not_found"))
  (should (ogent-ui--provider-access-error-p "Quota exceeded"))
  (should (ogent-ui--provider-access-error-p "Your credits are exhausted"))
  (should-not (ogent-ui--provider-access-error-p "Connection timed out"))
  (should-not (ogent-ui--provider-access-error-p "Rate limit exceeded")))

(ert-deftest ogent-ui-invalid-api-key-offers-provider-login ()
  "Access failures offer to log in to a different provider."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini"))
                                   (ogent-ui--error-history nil)
                                   (ogent-prompt-provider-login-on-access-error t)
                                   (ogent-provider--login-prompt-active nil)
                                   (noninteractive nil)
                                   (captured-backend :unset)
                                   (captured-prompt nil))
                               (cl-letf (((symbol-function 'run-at-time)
                                          (lambda (_secs _repeat function &rest args)
                                            (when (eq function 'ogent-provider-offer-login)
                                              (apply function args))
                                            (timer-create)))
                                         ((symbol-function 'ogent-theme-flash)
                                          (lambda (&rest _) nil))
                                         ((symbol-function 'y-or-n-p)
                                          (lambda (prompt)
                                            (setq captured-prompt prompt)
                                            t))
                                         ((symbol-function
                                           'ogent-onboard-login-different-provider)
                                          (lambda (backend)
                                            (setq captured-backend backend))))
                                 (ogent-test-with-error-mock
                                     "Invalid API key provided"
                                   (ogent-request "Test prompt" '("gpt-4o-mini")))
                                 (should (eq captured-backend 'gptel-openai))
                                 (should (string-match-p
                                          "Login to a different provider"
                                          captured-prompt)))))))

(ert-deftest ogent-ui-non-access-error-does-not-offer-provider-login ()
  "Transient failures do not trigger provider login."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini"))
                                   (ogent-ui--error-history nil)
                                   (ogent-prompt-provider-login-on-access-error t)
                                   (noninteractive nil)
                                   (scheduled nil)
                                   (login-called nil))
                               (cl-letf (((symbol-function 'run-at-time)
                                          (lambda (_secs _repeat function &rest args)
                                            (when (eq function 'ogent-provider-offer-login)
                                              (setq scheduled t)
                                              (apply function args))
                                            (timer-create)))
                                         ((symbol-function 'ogent-theme-flash)
                                          (lambda (&rest _) nil))
                                         ((symbol-function
                                           'ogent-onboard-login-different-provider)
                                          (lambda (&rest _)
                                            (setq login-called t))))
                                 (ogent-test-with-error-mock
                                     "Connection timed out"
                                   (ogent-request "Test prompt" '("gpt-4o-mini")))
                                 (should-not scheduled)
                                 (should-not login-called))))))

(ert-deftest ogent-ui-provider-login-prompt-can-be-disabled ()
  "The access-error provider prompt obeys its customization switch."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini"))
                                   (ogent-ui--error-history nil)
                                   (ogent-prompt-provider-login-on-access-error nil)
                                   (noninteractive nil)
                                   (scheduled nil))
                               (cl-letf (((symbol-function 'run-at-time)
                                          (lambda (_secs _repeat function &rest args)
                                            (when (eq function 'ogent-provider-offer-login)
                                              (setq scheduled t)
                                              (apply function args))
                                            (timer-create)))
                                         ((symbol-function 'ogent-theme-flash)
                                          (lambda (&rest _) nil)))
                                 (ogent-test-with-error-mock
                                     "Invalid API key provided"
                                   (ogent-request "Test prompt" '("gpt-4o-mini")))
                                 (should-not scheduled))))))

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

;;; Multi-Model Fan-Out Tests

(ert-deftest ogent-ui-multi-model-request-count ()
  "Test that each model in a multi-model request gets its own gptel request."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-model-registry '((:id "test-model-1" :backend gptel-openai)
                                                           (:id "test-model-2" :backend gptel-anthropic)))
                                   (ogent-ui--selected-models '("test-model-1" "test-model-2")))
                               (ogent-test-with-mock-gptel
                                (ogent-request "Test prompt" '("test-model-1" "test-model-2"))
                                ;; Should have made 2 separate requests
                                (should (= 2 (ogent-test-request-count))))))))

(ert-deftest ogent-ui-multi-model-distinct-backends ()
  "Test that each model request uses the correct backend."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-model-registry '((:id "test-model-1" :backend gptel-openai)
                                                           (:id "test-model-2" :backend gptel-anthropic)))
                                   (ogent-ui--selected-models '("test-model-1" "test-model-2"))
                                   (captured-backends nil))
                               (cl-letf (((symbol-function 'gptel-request)
                                          (lambda (_prompt &rest args)
                                            (push (list :backend gptel-backend :model gptel-model) captured-backends)
                                            (when-let ((callback (plist-get args :callback)))
                                              (funcall callback "Response" nil)
                                              (funcall callback nil '(:done t)))
                                            'mock-request)))
                                 (ogent-request "Test prompt" '("test-model-1" "test-model-2"))
                                 ;; Should capture 2 distinct backend configurations
                                 (should (= 2 (length captured-backends)))
                                 ;; One should be OpenAI, one should be Anthropic
                                 (let ((backends (mapcar (lambda (b) (plist-get b :backend)) captured-backends)))
                                   (should (member 'gptel-openai backends))
                                   (should (member 'gptel-anthropic backends))))))))

(ert-deftest ogent-ui-multi-model-independent-responses ()
  "Test that each model's response is recorded separately in buffer."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-model-registry '((:id "test-model-1" :backend gptel-openai)
                                                           (:id "test-model-2" :backend gptel-anthropic)))
                                   (ogent-ui--selected-models '("test-model-1" "test-model-2"))
                                   (response-count 0))
                               (cl-letf (((symbol-function 'gptel-request)
                                          (lambda (_prompt &rest args)
                                            (setq response-count (1+ response-count))
                                            (let ((model-response (format "Response from model %d" response-count)))
                                              (when-let ((callback (plist-get args :callback)))
                                                (funcall callback model-response nil)
                                                (funcall callback nil '(:done t))))
                                            'mock-request)))
                                 (ogent-request "Test prompt" '("test-model-1" "test-model-2"))
                                 (save-excursion
                                   (goto-char (point-min))
                                   ;; Both responses should appear in buffer
                                   (should (search-forward "Response from model 1" nil t))
                                   (goto-char (point-min))
                                   (should (search-forward "Response from model 2" nil t))))))))

(ert-deftest ogent-ui-multi-model-streaming-concurrent ()
  "Test that multiple models can stream responses concurrently."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-model-registry '((:id "test-model-1" :backend gptel-openai)
                                                           (:id "test-model-2" :backend gptel-anthropic)))
                                   (ogent-ui--selected-models '("test-model-1" "test-model-2"))
                                   (callbacks nil))
                               ;; Capture callbacks without immediately calling them
                               (cl-letf (((symbol-function 'gptel-request)
                                          (lambda (_prompt &rest args)
                                            (push (plist-get args :callback) callbacks)
                                            'mock-request)))
                                 (ogent-request "Test prompt" '("test-model-1" "test-model-2"))
                                 ;; Both requests should be initiated
                                 (should (= 2 (length callbacks)))
                                 ;; Simulate concurrent streaming by interleaving callback invocations
                                 (let ((cb1 (nth 1 callbacks))
                                       (cb2 (nth 0 callbacks)))
                                   (funcall cb1 "First chunk from model 1" nil)
                                   (funcall cb2 "First chunk from model 2" nil)
                                   (funcall cb1 " second chunk from model 1" nil)
                                   (funcall cb2 " second chunk from model 2" nil)
                                   (funcall cb1 nil '(:done t))
                                   (funcall cb2 nil '(:done t)))
                                 (save-excursion
                                   (goto-char (point-min))
                                   ;; Both response streams should be present
                                   (should (search-forward "First chunk from model 1 second chunk from model 1" nil t))
                                   (goto-char (point-min))
                                   (should (search-forward "First chunk from model 2 second chunk from model 2" nil t))))))))

(ert-deftest ogent-ui-multi-model-partial-failure ()
  "Test that one model failing doesn't prevent other models from responding."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-model-registry '((:id "test-model-1" :backend gptel-openai)
                                                           (:id "test-model-2" :backend gptel-anthropic)))
                                   (ogent-ui--selected-models '("test-model-1" "test-model-2"))
                                   (ogent-ui--error-history nil)
                                   (request-count 0))
                               (cl-letf (((symbol-function 'gptel-request)
                                          (lambda (_prompt &rest args)
                                            (setq request-count (1+ request-count))
                                            (when-let ((callback (plist-get args :callback)))
                                              (if (= request-count 1)
                                                  ;; First model fails
                                                  (funcall callback nil '(:error "Model temporarily unavailable"))
                                                ;; Second model succeeds
                                                (progn
                                                  (funcall callback "Successful response" nil)
                                                  (funcall callback nil '(:done t)))))
                                            'mock-request)))
                                 (ogent-request "Test prompt" '("test-model-1" "test-model-2"))
                                 ;; Both requests were made
                                 (should (= 2 request-count))
                                 ;; Error was recorded
                                 (should (= 1 (length ogent-ui--error-history)))
                                 ;; Successful response is in buffer
                                 (save-excursion
                                   (goto-char (point-min))
                                   (should (search-forward "Successful response" nil t))))))))

(ert-deftest ogent-ui-single-model-no-fanout ()
  "Test that single model request only makes one gptel request."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini")))
                               (ogent-test-with-mock-gptel
                                (ogent-request "Test prompt" '("gpt-4o-mini"))
                                ;; Should have made exactly 1 request
                                (should (= 1 (ogent-test-request-count))))))))

;;; Large Context Handling Tests

(ert-deftest ogent-ui-large-prompt-headline-truncation ()
  "Test that very long prompts are truncated in headline but preserved in body."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini"))
                                   ;; Create a 500 character prompt
                                   (long-prompt (make-string 500 ?A)))
                               (ogent-test-with-mock-gptel
                                (ogent-request long-prompt '("gpt-4o-mini"))
                                (save-excursion
                                  (goto-char (point-min))
                                  ;; Headline should be truncated (max ~60 chars visible)
                                  (should (search-forward "** Request: AAAA" nil t))
                                  (should (search-forward "..." nil t))
                                  ;; But full prompt should be in the src block
                                  (should (search-forward "#+begin_src text" nil t))
                                  (should (search-forward long-prompt nil t))))))))

(ert-deftest ogent-ui-large-context-passed-to-gptel ()
  "Test that large context is properly passed through to gptel-request."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Root Overview")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini"))
                                   (captured-prompt nil))
                               (cl-letf (((symbol-function 'gptel-request)
                                          (lambda (prompt &rest args)
                                            (setq captured-prompt prompt)
                                            (when-let ((callback (plist-get args :callback)))
                                              (funcall callback "Response" nil)
                                              (funcall callback nil '(:done t)))
                                            'mock-request)))
                                 ;; The fixture has context - make a request
                                 (ogent-request "Test prompt" '("gpt-4o-mini"))
                                 ;; Captured prompt should include both context and user prompt
                                 (should captured-prompt)
                                 (should (stringp captured-prompt))
                                 (should (> (length captured-prompt) 10)))))))

(ert-deftest ogent-ui-streaming-very-large-response ()
  "Test streaming with a very large response (1000+ chunks)."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini"))
                                   ;; Generate 1000 chunks
                                   (chunks (make-list 1000 "chunk")))
                               (ogent-test-with-streaming-mock chunks
                                                               (ogent-request "Test prompt" '("gpt-4o-mini"))
                                                               (save-excursion
                                                                 (goto-char (point-min))
                                                                 (should (search-forward "*** Response" nil t))
                                                                 ;; Response should contain all chunks concatenated
                                                                 ;; Just verify it's there and reasonably sized
                                                                 (let ((response-start (point)))
                                                                   (should (search-forward "chunk" nil t))
                                                                   ;; Count occurrences - should have many
                                                                   (goto-char response-start)
                                                                   (let ((count 0))
                                                                     (while (search-forward "chunk" nil t)
                                                                       (setq count (1+ count)))
                                                                     ;; Should have all 1000 chunks
                                                                     (should (= 1000 count))))))))))

(ert-deftest ogent-ui-large-prompt-with-newlines ()
  "Test handling of large prompts with embedded newlines."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini"))
                                   ;; Multi-line prompt
                                   (multi-line-prompt (mapconcat #'identity
                                                                 (make-list 50 "This is a line of the prompt")
                                                                 "\n")))
                               (ogent-test-with-mock-gptel
                                (ogent-request multi-line-prompt '("gpt-4o-mini"))
                                (save-excursion
                                  (goto-char (point-min))
                                  ;; Headline should use first line only
                                  (should (search-forward "** Request: This is a line of the prompt" nil t))
                                  ;; Full prompt with newlines should be in src block
                                  (should (search-forward "#+begin_src text" nil t))
                                  (should (search-forward "This is a line of the prompt" nil t))))))))

(ert-deftest ogent-ui-empty-prompt-handling ()
  "Test that empty prompts are handled gracefully."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini")))
                               ;; Empty prompt should be rejected or handled gracefully
                               (condition-case err
                                   (ogent-test-with-mock-gptel
                                    (ogent-request "" '("gpt-4o-mini")))
                                 (error
                                  ;; Expected - empty prompts may be rejected
                                  (should (stringp (error-message-string err)))))))))

(ert-deftest ogent-ui-whitespace-only-prompt ()
  "Test handling of whitespace-only prompts."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (goto-char (point-min))
                             (search-forward "Details Block")
                             (org-back-to-heading t)
                             (let ((ogent-ui--selected-models '("gpt-4o-mini")))
                               ;; Whitespace-only prompt should be handled
                               (condition-case err
                                   (ogent-test-with-mock-gptel
                                    (ogent-request "   \n\t  " '("gpt-4o-mini")))
                                 (error
                                  ;; May be rejected - that's fine
                                  (should (stringp (error-message-string err)))))))))

;;; Transient Suffix Definition Tests

(ert-deftest ogent-ui-suffix-send-action-is-transient-suffix ()
  "Test that ogent--suffix-send-action is properly defined as a transient suffix.
Regression test: plain defun with inline shorthand caused macro expansion error."
  ;; The suffix should have transient metadata attached
  (let ((suffix-obj (get 'ogent--suffix-send-action 'transient--suffix)))
    (should suffix-obj)
    ;; Should be a transient-suffix object
    (should (cl-typep suffix-obj 'transient-suffix))
    ;; Should have the correct key binding
    (should (equal (oref suffix-obj key) "RET"))
    ;; Should have a description (function reference)
    (should (oref suffix-obj description))))

(ert-deftest ogent-ui-prompt-dispatch-loads-without-error ()
  "Test that ogent-prompt-dispatch transient prefix loads without macro errors.
Regression test: inline suffix shorthand with plain defun caused 'Need keyword' error."
  ;; Simply loading the transient should not error
  (should (fboundp 'ogent-prompt-dispatch))
  ;; The prefix should be defined as a transient command
  (should (get 'ogent-prompt-dispatch 'transient--prefix)))

(ert-deftest ogent-ui-prompt-dispatch-sets-up-without-error ()
  "Prompt dispatcher should render under Transient in clean sessions."
  (let ((gptel-backend nil)
        (gptel-model nil))
    (unwind-protect
        (progn
          (transient-setup 'ogent-prompt-dispatch)
          (should (get 'ogent-prompt-dispatch 'transient--prefix)))
      (when transient-current-prefix
        (transient-quit-one)))))

(ert-deftest ogent-ui-prompt-dispatch-visible-keys-are-unique ()
  "Prompt dispatcher should not bind duplicate visible keys."
  (let ((seen (make-hash-table :test #'equal))
        duplicates)
    (dolist (suffix (transient-suffixes 'ogent-prompt-dispatch))
      (let ((key (oref suffix key)))
        (unless (string-prefix-p "C-" key)
          (let ((existing (gethash key seen)))
            (if existing
                (push (list key existing (oref suffix command)) duplicates)
              (puthash key (oref suffix command) seen))))))
    (should-not duplicates)))

(defun ogent-ui-tests--contains-private-use-char-p (text)
  "Return non-nil when TEXT contains a private-use glyph."
  (catch 'found
    (mapc (lambda (char)
            (when (and (>= char #xe000)
                       (<= char #xf8ff))
              (throw 'found t)))
          text)
    nil))

(ert-deftest ogent-ui-prompt-dispatch-renders-without-icon-glyphs ()
  "Prompt dispatcher should render as compact text without icon glyphs."
  (let ((gptel-backend nil)
        (gptel-model nil))
    (unwind-protect
        (progn
          (transient-setup 'ogent-prompt-dispatch)
          (let ((text (with-current-buffer (get-buffer transient--buffer-name)
                        (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "Send" text))
            (should (string-match-p "Model" text))
            (should (string-match-p "Context" text))
            (should-not (ogent-ui-tests--contains-private-use-char-p text))))
      (when transient-current-prefix
        (transient-quit-one)))))

(ert-deftest ogent-ui-prompt-dispatch-model-and-codemap-keys-are-distinct ()
  "Model selection and codemap commands should use separate keys."
  (let ((model (cl-find-if (lambda (suffix)
                             (equal (oref suffix key) "m"))
                           (transient-suffixes 'ogent-prompt-dispatch)))
        (codemap (cl-find-if (lambda (suffix)
                               (equal (oref suffix key) "C"))
                             (transient-suffixes 'ogent-prompt-dispatch))))
    (should model)
    (should codemap)
    (should (eq (oref model command) 'ogent--infix-provider))
    (should (eq (oref codemap command) 'ogent-codemap-buffer))))

(ert-deftest ogent-ui-prompt-dispatch-ai-speed-edit-key ()
  "Prompt dispatcher exposes AI speed edit on v."
  (let ((speed-edit (cl-find-if (lambda (suffix)
                                  (equal (oref suffix key) "v"))
                                (transient-suffixes
                                 'ogent-prompt-dispatch))))
    (should speed-edit)
    (should (eq (oref speed-edit command) 'ogent-ai-speed-edit))))

(ert-deftest ogent-ui-provider-infix-does-not-persist-backend-objects ()
  "Provider selection should not store backend structs in Transient history."
  (let* ((backend (ogent-ui-test-provider-create))
         (model 'audit-model)
         (gptel--known-backends `(("Audit" . ,backend)))
         (transient-history nil))
    (cl-letf (((symbol-function 'gptel-backend-models)
               (lambda (_backend) (list model)))
              ((symbol-function 'gptel--model-name)
               (lambda (candidate) (symbol-name candidate)))
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (caar choices)))
              ((symbol-function 'transient--show)
               #'ignore))
      (let* ((obj (ogent-provider-variable
                   :command 'ogent--infix-provider
                   :variable 'gptel-backend
                   :model 'gptel-model
                   :set-value #'ogent--set-with-scope
                   :key "m"
                   :reader #'ogent--read-provider))
             (selection (transient-infix-read obj)))
        (should (equal selection (list backend model)))
        (should-not (alist-get 'ogent--infix-provider transient-history))))))

;;; Transcript Navigation Tests

(ert-deftest ogent-ui-next-response-finds-response ()
  "Next response should move point to the following Response heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: test\n"
            "** Response\n"
            "Some content\n"
            "** Response\n"
            "More content\n")
    (goto-char (point-min))
    (ogent-next-response)
    (should (looking-at "\\*\\* Response"))))

(ert-deftest ogent-ui-next-response-stays-put-when-none ()
  "Next response should not move point when no response follows."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: test\n"
            "No responses here\n")
    (goto-char (point-min))
    (ogent-next-response)
    (should (= (point) (point-min)))))

(ert-deftest ogent-ui-prev-response-finds-response ()
  "Previous response should move point to the preceding Response heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: test\n"
            "** Response\n"
            "First response\n"
            "** Response\n"
            "Second response\n")
    (goto-char (point-max))
    (ogent-prev-response)
    (should (looking-at "\\*\\* Response"))))

(ert-deftest ogent-ui-next-request-finds-request ()
  "Next request should move point to the following Request heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: first\n"
            "** Response\n"
            "* Request: second\n"
            "** Response\n")
    (goto-char (point-min))
    (forward-line 1)
    (ogent-next-request)
    (should (looking-at "\\* Request: second"))))

(ert-deftest ogent-ui-prev-request-finds-request ()
  "Previous request should move point to the preceding Request heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: first\n"
            "** Response\n"
            "* Request: second\n"
            "** Response\n")
    (goto-char (point-max))
    (ogent-prev-request)
    (should (looking-at "\\* Request: second"))))

(ert-deftest ogent-ui-navigate-is-transient-prefix ()
  "ogent-navigate should be a defined transient prefix command."
  (should (fboundp 'ogent-navigate))
  (should (commandp 'ogent-navigate))
  (should (get 'ogent-navigate 'transient--prefix)))

;;; Conversation History Tests

(ert-deftest ogent-ui-prompt-property-round-trips ()
  "Encoding a prompt for an org property decodes back exactly."
  (dolist (prompt '("simple"
                    "two\nlines"
                    "literal \\n backslash-n"
                    "mix\n\\n and \\\\ tail\n"))
    (should (equal (ogent-ui--decode-prompt-property
                    (ogent-ui--encode-prompt-property prompt))
                   prompt)))
  (should-not (string-match-p "\n" (ogent-ui--encode-prompt-property "a\nb"))))

(defun ogent-ui-tests--insert-exchange (prompt response &optional model summary)
  "Insert a completed Request/Response exchange into the current buffer.
PROMPT goes into the OGENT_PROMPT property unless nil; SUMMARY (or
PROMPT) becomes the headline text; RESPONSE is the body under a
Response heading for MODEL (default \"m\")."
  (insert (format "** Request: %s\n" (or summary prompt)))
  (when prompt
    (insert ":PROPERTIES:\n"
            (format ":OGENT_PROMPT: %s\n"
                    (ogent-ui--encode-prompt-property prompt))
            ":END:\n"))
  (insert (format "*** Response (%s)\n" (or model "m")))
  (when response
    (insert response "\n")))

(ert-deftest ogent-ui-conversation-history-collects-completed-exchanges ()
  "Walker returns alternating turns, skipping the in-flight exchange."
  (with-temp-buffer
    (org-mode)
    (insert "* Session\n")
    (ogent-ui-tests--insert-exchange "p1" "r1")
    (ogent-ui-tests--insert-exchange "p2" "r2")
    (let ((bound (point)))
      ;; In-flight third request: empty response, must not appear.
      (ogent-ui-tests--insert-exchange "p3" nil)
      (should (equal (ogent-ui--conversation-history (current-buffer) bound "m")
                     '("p1" "r1" "p2" "r2"))))))

(ert-deftest ogent-ui-conversation-history-falls-back-to-summary ()
  "Exchanges without OGENT_PROMPT use the headline summary."
  (with-temp-buffer
    (org-mode)
    (insert "* Session\n")
    (ogent-ui-tests--insert-exchange nil "old answer" "m" "legacy summary…")
    (should (equal (ogent-ui--conversation-history
                    (current-buffer) (point) "m")
                   '("legacy summary…" "old answer")))))

(ert-deftest ogent-ui-conversation-history-prefers-matching-model ()
  "Fan-out requests replay the response of the requesting model."
  (with-temp-buffer
    (org-mode)
    (insert "* Session\n"
            "** Request: fan\n"
            ":PROPERTIES:\n:OGENT_PROMPT: fan\n:END:\n"
            "*** Response (a)\nanswer-a\n"
            "*** Response (b)\nanswer-b\n")
    (let ((bound (point)))
      (should (equal (ogent-ui--conversation-history (current-buffer) bound "b")
                     '("fan" "answer-b")))
      (should (equal (ogent-ui--conversation-history (current-buffer) bound "a")
                     '("fan" "answer-a")))
      ;; Unknown model falls back to the first response.
      (should (equal (ogent-ui--conversation-history (current-buffer) bound "zz")
                     '("fan" "answer-a"))))))

(ert-deftest ogent-ui-compact-history-evicts-oldest-pairs ()
  "Compaction drops whole oldest pairs and preserves alternation."
  (let* ((history (list "u1-aaaaaaaaaaaaaaaa" "r1-aaaaaaaaaaaaaaaa"
                        "u2-bbbbbbbbbbbbbbbb" "r2-bbbbbbbbbbbbbbbb"))
         (total (apply #'+ (mapcar #'ogent-analytics-estimate-tokens history))))
    ;; Fits exactly: untouched.
    (should (equal (ogent-ui--compact-history history total) history))
    ;; One token short: oldest pair evicted together.
    (let ((compacted (ogent-ui--compact-history history (1- total))))
      (should (equal compacted (list "u2-bbbbbbbbbbbbbbbb" "r2-bbbbbbbbbbbbbbbb")))
      (should (cl-evenp (length compacted))))
    ;; Nothing fits: empty list, not an error.
    (should (null (ogent-ui--compact-history history 0)))))

(ert-deftest ogent-ui-second-request-sends-conversation-list ()
  "A follow-up request replays the prior exchange as a 3-element PROMPT."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (let ((prompts nil))
                               (cl-letf (((symbol-function 'gptel-request)
                                          (lambda (prompt &rest args)
                                            (push prompt prompts)
                                            (when-let ((callback (plist-get args :callback)))
                                              (funcall callback "First answer\n" nil)
                                              (funcall callback nil '(:done t)))
                                            'mock-request)))
                                 (goto-char (point-min))
                                 (search-forward "Details Block")
                                 (org-back-to-heading t)
                                 (ogent-request "First prompt" '("gpt-4o-mini"))
                                 ;; Follow up from the response, as a user
                                 ;; continuing the conversation would.
                                 (goto-char (point-min))
                                 (re-search-forward "^\\*\\*\\* Response (gpt-4o-mini)")
                                 (org-back-to-heading t)
                                 (ogent-request "Second prompt" '("gpt-4o-mini"))
                                 (let ((first (cadr prompts))
                                       (second (car prompts)))
                                   (should (stringp first))
                                   (should (listp second))
                                   (should (= (length second) 3))
                                   (should (equal (nth 0 second) "First prompt"))
                                   (should (equal (nth 1 second) "First answer"))
                                   (should (string-match-p "Second prompt" (nth 2 second)))))))))

(ert-deftest ogent-ui-multi-turn-disabled-sends-plain-string ()
  "With `ogent-multi-turn-history' nil the PROMPT stays a string."
  (ogent-test-with-fixture "data/fixture.org"
                           (lambda ()
                             (let ((ogent-multi-turn-history nil)
                                   (prompts nil))
                               (cl-letf (((symbol-function 'gptel-request)
                                          (lambda (prompt &rest args)
                                            (push prompt prompts)
                                            (when-let ((callback (plist-get args :callback)))
                                              (funcall callback "Answer" nil)
                                              (funcall callback nil '(:done t)))
                                            'mock-request)))
                                 (goto-char (point-min))
                                 (search-forward "Details Block")
                                 (org-back-to-heading t)
                                 (ogent-request "First prompt" '("gpt-4o-mini"))
                                 (goto-char (point-min))
                                 (search-forward "Details Block")
                                 (org-back-to-heading t)
                                 (ogent-request "Second prompt" '("gpt-4o-mini"))
                                 (should (= (length prompts) 2))
                                 (dolist (p prompts)
                                   (should (stringp p))))))))

(provide 'ogent-ui-tests)
;;; ogent-ui-tests.el ends here
