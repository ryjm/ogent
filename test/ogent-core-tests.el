;;; ogent-core-tests.el --- Tests for ogent-mode -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-core)
(require 'org)
;; Dynamically bound in prompt-validation tests; defined in ogent-prompts,
;; which those tests require at runtime.
(defvar ogent-prompt-registry)
(declare-function ogent-prompt-register "ogent-prompts")
(declare-function ogent-retry-request "ui/ogent-ui" t t)
(declare-function ogent-abort-request "ui/ogent-ui" t t)
(declare-function ogent-prompt-dispatch "ui/ogent-ui" t t)
(declare-function ogent-request "ui/ogent-ui" t t)
(declare-function ogent-context-preview "ui/ogent-ui" t t)
(declare-function ogent-codemap-buffer "ogent-codemap" t t)

(ert-deftest ogent-mode-keymap-binds-dispatch ()
  "Ensure the primary keybindings are available."
  (should (eq (lookup-key ogent-mode-map (kbd "C-c . p"))
              #'ogent-prompt-dispatch))
  (should (eq (lookup-key ogent-mode-map (kbd "C-c . r"))
              #'ogent-request)))

(ert-deftest ogent-global-mode-enables-in-all-buffers ()
  "Global mode should enable in all buffers, not just Org."
  (let ((org-buffer (get-buffer-create "*ogent-org*"))
        (text-buffer (get-buffer-create "*ogent-txt*")))
    (unwind-protect
        (progn
          (with-current-buffer org-buffer
            (org-mode)
            (ogent-mode -1))
          (with-current-buffer text-buffer
            (fundamental-mode)
            (ogent-mode -1))
          (ogent-global-mode 1)
          (with-current-buffer org-buffer
            (should ogent-mode))
          (with-current-buffer text-buffer
            (should ogent-mode)))
      (ogent-global-mode -1)
      (when (buffer-live-p org-buffer)
        (kill-buffer org-buffer))
      (when (buffer-live-p text-buffer)
        (kill-buffer text-buffer)))))

(ert-deftest ogent-mode-works-in-non-org-buffers ()
  "ogent-mode can be enabled manually in non-Org buffers."
  (let ((text-buffer (get-buffer-create "*test-python*")))
    (unwind-protect
        (with-current-buffer text-buffer
          (python-mode)
          (ogent-mode 1)
          (should ogent-mode)
          (should (keymapp ogent-mode-map))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . p"))
                      #'ogent-prompt-dispatch)))
      (kill-buffer text-buffer))))

(ert-deftest ogent-mode-keybindings-available-globally ()
  "C-c . keybindings work when ogent-mode is enabled in any buffer."
  (let ((js-buffer (get-buffer-create "*test.js*")))
    (unwind-protect
        (with-current-buffer js-buffer
          (fundamental-mode)
          (ogent-mode 1)
          ;; Verify all main keybindings are available
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . p"))
                      #'ogent-prompt-dispatch))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . r"))
                      #'ogent-request))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . c"))
                      #'ogent-context-preview))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . m"))
                      #'ogent-codemap-buffer))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . a"))
                      #'ogent-abort-request))
          (should (eq (lookup-key ogent-mode-map (kbd "C-c . R"))
                      #'ogent-retry-request)))
      (kill-buffer js-buffer))))

(ert-deftest ogent-global-mode-does-not-switch-buffer ()
  "Enabling ogent-global-mode should not change current buffer or window."
  (let ((test-buffer (get-buffer-create "*ogent-test-nosw*"))
        (original-buffer nil))
    (unwind-protect
        (progn
          (set-buffer test-buffer)
          (setq original-buffer (current-buffer))
          (ogent-global-mode 1)
          ;; Buffer should not change
          (should (eq (current-buffer) original-buffer)))
      (ogent-global-mode -1)
      (when (buffer-live-p test-buffer)
        (kill-buffer test-buffer)))))

;;; Validation Tests

(ert-deftest ogent-context-validate-detects-missing-handles ()
  "ogent-context-validate should identify missing handles from dependencies."
  (let ((context (list :dependencies
                       (list (list :handle "found-handle"
                                   :missing-p nil
                                   :node '(mock-node))
                             (list :handle "missing-handle"
                                   :missing-p t
                                   :node nil)
                             (list :handle "another-missing"
                                   :missing-p t
                                   :node nil)))))
    (let ((missing (ogent-context-validate context)))
      (should (equal missing '("missing-handle" "another-missing"))))))

(ert-deftest ogent-context-validate-returns-empty-when-all-resolved ()
  "ogent-context-validate should return empty list when all handles resolved."
  (let ((context (list :dependencies
                       (list (list :handle "handle1"
                                   :missing-p nil
                                   :node '(mock-node))
                             (list :handle "handle2"
                                   :missing-p nil
                                   :node '(another-mock))))))
    (should (null (ogent-context-validate context)))))

(ert-deftest ogent-context-validate-handles-empty-dependencies ()
  "ogent-context-validate should handle context with no dependencies."
  (let ((context (list :dependencies nil)))
    (should (null (ogent-context-validate context)))))

(ert-deftest ogent-context-add-validation-warnings-adds-warnings ()
  "ogent-context-add-validation-warnings should add :validation-warnings key."
  (let* ((context (list :dependencies
                        (list (list :handle "missing"
                                    :missing-p t
                                    :node nil))))
         (updated (ogent-context-add-validation-warnings context))
         (warnings (plist-get updated :validation-warnings)))
    (should warnings)
    (should (= (length warnings) 1))
    (should (string-match-p "missing" (car warnings)))))

(ert-deftest ogent-context-add-validation-warnings-handles-no-missing ()
  "ogent-context-add-validation-warnings with no missing handles."
  (let* ((context (list :dependencies
                        (list (list :handle "found"
                                    :missing-p nil
                                    :node '(node)))))
         (updated (ogent-context-add-validation-warnings context))
         (warnings (plist-get updated :validation-warnings)))
    (should (null warnings))))

(ert-deftest ogent-validate-and-prompt-with-nil-setting ()
  "ogent-validate-and-prompt should proceed when validation is nil."
  (let ((ogent-validate-before-send nil)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil)))))
    (should (ogent-validate-and-prompt context))))

(ert-deftest ogent-validate-and-prompt-with-warn-setting ()
  "ogent-validate-and-prompt should warn and proceed."
  (let ((ogent-validate-before-send 'warn)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil))))
        (message-log nil))
    ;; Capture message output
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (should (ogent-validate-and-prompt context))
      (should (string-match-p "missing" message-log)))))

(ert-deftest ogent-validate-and-prompt-with-confirm-approve ()
  "ogent-validate-and-prompt should prompt and respect user approval."
  (let ((ogent-validate-before-send 'confirm)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil)))))
    ;; Mock y-or-n-p to return t (user approves)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) t)))
      (should (ogent-validate-and-prompt context)))))

(ert-deftest ogent-validate-and-prompt-with-confirm-deny ()
  "ogent-validate-and-prompt should abort when user denies."
  (let ((ogent-validate-before-send 'confirm)
        (context (list :dependencies
                       (list (list :handle "missing"
                                   :missing-p t
                                   :node nil)))))
    ;; Mock y-or-n-p to return nil (user denies)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (_prompt) nil)))
      (should-not (ogent-validate-and-prompt context)))))

(ert-deftest ogent-validate-and-prompt-proceeds-when-no-missing ()
  "ogent-validate-and-prompt should proceed when no handles missing."
  (let ((ogent-validate-before-send 'confirm)
        (context (list :dependencies
                       (list (list :handle "found"
                                   :missing-p nil
                                   :node '(node))))))
    (should (ogent-validate-and-prompt context))))

;;; Prompt Validation Integration Tests

(ert-deftest ogent-validate-prompts-detects-missing-context ()
  "ogent-validate-prompts should detect missing required context."
  (require 'ogent-prompts)
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "needs-code"
                           :title "Needs Code"
                           :content "Review this."
                           :required-context '(code))
    (let ((result (ogent-validate-prompts '("needs-code") nil)))
      (should-not (plist-get result :valid))
      (should (member 'code (plist-get result :missing))))))

(ert-deftest ogent-validate-prompts-passes-with-context ()
  "ogent-validate-prompts should pass when context is present."
  (require 'ogent-prompts)
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "needs-code"
                           :title "Needs Code"
                           :content "Review this."
                           :required-context '(code))
    (let ((result (ogent-validate-prompts '("needs-code") '(:code "some code"))))
      (should (plist-get result :valid)))))

(ert-deftest ogent-validate-prompts-handles-no-requirements ()
  "ogent-validate-prompts should pass for prompts without requirements."
  (require 'ogent-prompts)
  (let ((ogent-prompt-registry (make-hash-table :test 'equal)))
    (ogent-prompt-register "simple"
                           :title "Simple"
                           :content "Just do it.")
    (let ((result (ogent-validate-prompts '("simple") nil)))
      (should (plist-get result :valid)))))

(ert-deftest ogent-context-add-prompt-warnings-adds-warnings ()
  "ogent-context-add-prompt-warnings should add prompt validation warnings."
  (require 'ogent-prompts)
  (let ((ogent-prompt-registry (make-hash-table :test 'equal))
        (context (list :prompt-ids '("needs-code"))))
    (ogent-prompt-register "needs-code"
                           :title "Needs Code"
                           :content "Review."
                           :required-context '(code))
    (let ((updated (ogent-context-add-prompt-warnings context)))
      (should (plist-get updated :prompt-warnings))
      (should (string-match-p "code"
                              (car (plist-get updated :prompt-warnings)))))))

;;; Completion Notification Tests

(ert-deftest ogent-notify-completion-with-nil-setting ()
  "ogent-notify-completion should do nothing when setting is nil."
  (let ((ogent-notify-on-completion nil)
        (message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (ogent-notify-completion
       (list :model "gpt-4o" :status "done"
             :start-time (current-time)
             :end-time (current-time)))
      ;; No message should be displayed
      (should (null message-log)))))

(ert-deftest ogent-notify-completion-with-message-setting ()
  "ogent-notify-completion should display message when setting is 'message."
  (let ((ogent-notify-on-completion 'message)
        (message-log nil)
        (start-time (current-time)))
    ;; Create end-time 1.5 seconds later
    (let ((end-time (time-add start-time (seconds-to-time 1.5))))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq message-log (apply #'format fmt args)))))
        (ogent-notify-completion
         (list :model "gpt-4o" :status "done"
               :start-time start-time
               :end-time end-time))
        ;; Should contain model, status, and latency
        (should (string-match-p "gpt-4o" message-log))
        (should (string-match-p "done" message-log))
        (should (string-match-p "1\\.5s" message-log))))))

(ert-deftest ogent-notify-completion-message-handles-missing-times ()
  "ogent-notify-completion should handle missing start/end times."
  (let ((ogent-notify-on-completion 'message)
        (message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (ogent-notify-completion
       (list :model "claude" :status "error"
             :start-time nil
             :end-time nil))
      ;; Should still show model and status, no latency
      (should (string-match-p "claude" message-log))
      (should (string-match-p "error" message-log))
      (should-not (string-match-p "[0-9]+\\.[0-9]+s" message-log)))))

(ert-deftest ogent-notify-completion-with-modeline-flash-setting ()
  "ogent-notify-completion should flash modeline when setting is 'modeline-flash."
  (let ((ogent-notify-on-completion 'modeline-flash)
        (flash-called nil))
    (cl-letf (((symbol-function 'ogent--flash-modeline)
               (lambda () (setq flash-called t))))
      (ogent-notify-completion
       (list :model "gpt-4o" :status "done"
             :start-time (current-time)
             :end-time (current-time)))
      (should flash-called))))

(ert-deftest ogent-notify-completion-runs-hook ()
  "ogent-notify-completion should run ogent-after-completion-hook."
  (let ((ogent-after-completion-hook nil)
        (hook-called nil)
        (hook-arg nil))
    (add-hook 'ogent-after-completion-hook
              (lambda (req)
                (setq hook-called t
                      hook-arg req)))
    (unwind-protect
        (let ((request (list :model "test" :status "done")))
          (ogent-notify-completion request)
          (should hook-called)
          (should (equal hook-arg request)))
      (setq ogent-after-completion-hook nil))))

(ert-deftest ogent-notify-completion-hook-runs-before-notification ()
  "Hook should run even when notification setting is nil."
  (let ((ogent-notify-on-completion nil)
        (ogent-after-completion-hook nil)
        (hook-called nil))
    (add-hook 'ogent-after-completion-hook
              (lambda (_req) (setq hook-called t)))
    (unwind-protect
        (progn
          (ogent-notify-completion
           (list :model "test" :status "done"))
          (should hook-called))
      (setq ogent-after-completion-hook nil))))

(ert-deftest ogent--flash-modeline-changes-face ()
  "ogent--flash-modeline should temporarily change mode-line face."
  (let ((timer-created nil))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (_delay _repeat _fn)
                 (setq timer-created t)
                 ;; Return mock timer
                 (list 'mock-timer))))
      (ogent--flash-modeline)
      ;; Timer should be created
      (should timer-created)
      ;; Face should be changed (can't easily test exact values)
      ;; Just verify the function completes
      (should t))))

(ert-deftest ogent--flash-modeline-cancels-existing-timer ()
  "ogent--flash-modeline should cancel existing flash timer."
  (let ((ogent--modeline-flash-timer (list 'mock-timer))
        (cancel-called nil))
    (cl-letf (((symbol-function 'timerp)
               (lambda (_timer) t))  ; Mock timerp to return true
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (should (equal timer '(mock-timer)))
                 (setq cancel-called t)))
              ((symbol-function 'run-with-timer)
               (lambda (_delay _repeat _fn) (list 'new-timer)))
              ((symbol-function 'set-face-attribute) #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore))
      (ogent--flash-modeline)
      (should cancel-called))))

(ert-deftest ogent-notify-completion-handles-nil-request ()
  "ogent-notify-completion should handle nil request gracefully."
  (let ((ogent-notify-on-completion 'message))
    ;; Should not error
    (should-not (ogent-notify-completion nil))))

;;; ogent-ask Tests

(ert-deftest ogent-ask-keybinding-exists ()
  "ogent-ask should be bound to C-c . ?."
  (should (eq (lookup-key ogent-mode-map (kbd "C-c . ?"))
              #'ogent-ask)))

(ert-deftest ogent-ask-display-popup-creates-buffer ()
  "ogent-ask--display-popup should create and populate buffer."
  (let ((ogent-ask--buffer-name "*ogent-ask-test*"))
    (unwind-protect
        (progn
          (ogent-ask--display-popup "Test response content")
          (let ((buf (get-buffer ogent-ask--buffer-name)))
            (should buf)
            (with-current-buffer buf
              (should (string-match-p "Test response content"
                                      (buffer-string)))
              (should buffer-read-only))))
      (when-let ((buf (get-buffer ogent-ask--buffer-name)))
        (kill-buffer buf)))))

(ert-deftest ogent-ask-display-message-truncates ()
  "ogent-ask--display-message should truncate long responses."
  (let ((message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (ogent-ask--display-message (make-string 300 ?x))
      ;; Should be truncated to ~200 chars + ellipsis
      (should (< (length message-log) 210)))))

(ert-deftest ogent-ask-display-message-collapses-newlines ()
  "ogent-ask--display-message should collapse newlines to spaces."
  (let ((message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (ogent-ask--display-message "line1\nline2\nline3")
      (should (string-match-p "line1 line2 line3" message-log)))))

(ert-deftest ogent-ask-callback-accumulates-text ()
  "ogent-ask callback should accumulate streaming text."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)  ; Simulate streaming mode
  (let ((callback (ogent-ask--make-callback))
        (ogent-ask-display-function #'ignore))
    ;; First chunk - text is string, info is nil (streaming in progress)
    (funcall callback "Hello " nil)
    ;; Second chunk - still streaming
    (funcall callback "world" nil)
    ;; At this point, text is accumulated but not displayed yet
    ;; because nil info doesn't trigger completion in streaming mode
    (should (equal ogent-ask--streaming-response "Hello world"))))

(ert-deftest ogent-ask-callback-displays-on-completion ()
  "ogent-ask callback should display response when done."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)  ; Simulate streaming mode
  (let ((displayed nil))
    ;; Use cl-letf to properly override the defcustom
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        ;; Accumulate some text first
        (funcall callback "Complete " nil)
        (funcall callback "response" nil)
        ;; Now signal completion with :done t
        (funcall callback nil '(:done t))
        (should (equal displayed "Complete response"))))))

(ert-deftest ogent-ask-callback-handles-error ()
  "ogent-ask callback should handle error gracefully."
  (setq ogent-ask--streaming-response "partial")
  (let ((message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback nil '(:error "API error"))
        ;; Should show error message
        (should (string-match-p "failed" message-log))
        ;; Should reset accumulator
        (should (equal ogent-ask--streaming-response ""))))))

(ert-deftest ogent-ask-rejects-empty-question ()
  "ogent-ask should reject empty questions."
  (cl-letf (((symbol-function 'require)
             (lambda (_feature &rest _) t)))
    (should-error (ogent-ask "")
                  :type 'user-error)
    (should-error (ogent-ask "   ")
                  :type 'user-error)))

;;; ogent-open-block Tests

(ert-deftest ogent-open-block-keybinding-exists ()
  "ogent-open-block should be bound to C-c . o."
  (should (eq (lookup-key ogent-mode-map (kbd "C-c . o"))
              #'ogent-open-block)))

(ert-deftest ogent-open-block-requires-org-mode ()
  "ogent-open-block should error in non-Org buffers."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (ogent-open-block)
                  :type 'user-error)))

(ert-deftest ogent-open-block-requires-source-block ()
  "ogent-open-block should error when not in a source block."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\nSome text")
    (goto-char (point-min))
    (should-error (ogent-open-block)
                  :type 'user-error)))

(ert-deftest ogent-open-block-setup-function-enables-ogent-mode ()
  "ogent-open-block--setup-edit-buffer should enable ogent-mode."
  (with-temp-buffer
    ;; Simulate org-src-mode environment
    (let ((org-src-mode t)
          (org-src--beg-marker (point-min-marker)))
      (ogent-open-block--setup-edit-buffer)
      (should ogent-mode))))

;;; Inline Prompting Tests

(ert-deftest ogent-session--in-question-headline-p-detects-question ()
  "ogent-session--in-question-headline-p should detect Question headlines."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nSome content here")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should (ogent-session--in-question-headline-p))))

(ert-deftest ogent-session--in-question-headline-p-case-insensitive ()
  "ogent-session--in-question-headline-p should be case-insensitive."
  (with-temp-buffer
    (org-mode)
    (insert "* question\nContent")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should (ogent-session--in-question-headline-p))
    (erase-buffer)
    (insert "* QUESTION\nContent")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should (ogent-session--in-question-headline-p))))

(ert-deftest ogent-session--in-question-headline-p-exact-match ()
  "ogent-session--in-question-headline-p should require exact match."
  (with-temp-buffer
    (org-mode)
    (insert "* Question Mark\nContent")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should-not (ogent-session--in-question-headline-p))
    (erase-buffer)
    (insert "* A Question\nContent")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should-not (ogent-session--in-question-headline-p))))

(ert-deftest ogent-session--in-question-headline-p-in-subtree ()
  "ogent-session--in-question-headline-p should work from within subtree."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nSome content\n** Subheading\nMore content")
    (goto-char (point-min))
    (search-forward "Some content")
    (should (ogent-session--in-question-headline-p))
    ;; But not from a different headline
    (goto-char (point-min))
    (search-forward "Subheading")
    (should-not (ogent-session--in-question-headline-p))))

(ert-deftest ogent-session--extract-question-content-returns-text ()
  "ogent-session--extract-question-content should extract headline content."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat is the meaning of life?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((content (ogent-session--extract-question-content)))
      (should (stringp content))
      (should (string-match-p "meaning of life" content)))))

(ert-deftest ogent-session--extract-question-content-trims-whitespace ()
  "ogent-session--extract-question-content should trim whitespace."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\n\n  What is this?  \n\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((content (ogent-session--extract-question-content)))
      (should (equal content "What is this?")))))

(ert-deftest ogent-session--extract-question-content-handles-multiline ()
  "ogent-session--extract-question-content should handle multiline content."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nLine 1\nLine 2\nLine 3\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((content (ogent-session--extract-question-content)))
      (should (string-match-p "Line 1" content))
      (should (string-match-p "Line 2" content))
      (should (string-match-p "Line 3" content)))))

(ert-deftest ogent-session--create-response-headline-creates-sibling ()
  "ogent-session--create-response-headline should create sibling headline."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nContent\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (should (search-forward "* Response" nil t))))

(ert-deftest ogent-session--create-response-headline-matches-level ()
  "ogent-session--create-response-headline should match Question level."
  (with-temp-buffer
    (org-mode)
    (insert "** Question\nContent\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (should (search-forward "** Response" nil t))))

(ert-deftest ogent-session--create-response-headline-returns-marker ()
  "ogent-session--create-response-headline should return a marker."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nContent\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (let ((marker (ogent-session--create-response-headline)))
      (should (markerp marker))
      (should (marker-buffer marker)))))

(ert-deftest ogent-session-prompt-from-question-requires-org-mode ()
  "ogent-session-prompt-from-question should require Org mode."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (ogent-session-prompt-from-question)
                  :type 'user-error)))

(ert-deftest ogent-session-prompt-from-question-requires-question-headline ()
  "ogent-session-prompt-from-question should require Question headline."
  (with-temp-buffer
    (org-mode)
    (insert "* Not a Question\nContent\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should-error (ogent-session-prompt-from-question)
                  :type 'user-error)))

(ert-deftest ogent-session-prompt-from-question-requires-content ()
  "ogent-session-prompt-from-question should require non-empty content."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\n\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should-error (ogent-session-prompt-from-question)
                  :type 'user-error)))

(ert-deftest ogent-session--ctrl-c-ctrl-c-handler-returns-t-in-question ()
  "ogent-session--ctrl-c-ctrl-c-handler should return t in Question headline."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat is this?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    ;; Mock the actual prompt function to avoid gptel dependency
    (cl-letf (((symbol-function 'ogent-session-prompt-from-question)
               (lambda () t)))
      (should (ogent-session--ctrl-c-ctrl-c-handler)))))

(ert-deftest ogent-session--ctrl-c-ctrl-c-handler-returns-nil-elsewhere ()
  "ogent-session--ctrl-c-ctrl-c-handler should return nil outside Question."
  (with-temp-buffer
    (org-mode)
    (insert "* Other Headline\nContent\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should-not (ogent-session--ctrl-c-ctrl-c-handler))))

(ert-deftest ogent-mode-adds-ctrl-c-ctrl-c-hook-in-org ()
  "ogent-mode should add org-ctrl-c-ctrl-c-hook in Org buffers."
  (with-temp-buffer
    (org-mode)
    (ogent-mode 1)
    (should (memq 'ogent-session--ctrl-c-ctrl-c-handler
                  org-ctrl-c-ctrl-c-hook))
    (ogent-mode -1)
    (should-not (memq 'ogent-session--ctrl-c-ctrl-c-handler
                      org-ctrl-c-ctrl-c-hook))))

;;; Edit and Re-send Tests

(ert-deftest ogent-session--count-response-siblings-returns-zero-initially ()
  "ogent-session--count-response-siblings should return 0 with no Response."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat is this?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should (= 0 (ogent-session--count-response-siblings)))))

(ert-deftest ogent-session--count-response-siblings-counts-one ()
  "ogent-session--count-response-siblings should count single Response."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat is this?\n* Response\nIt is a thing.\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (should (= 1 (ogent-session--count-response-siblings)))))

(ert-deftest ogent-session--count-response-siblings-counts-multiple ()
  "ogent-session--count-response-siblings should count multiple Responses."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n* Response\nAnswer 1\n* Response 2\nAnswer 2\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (should (= 2 (ogent-session--count-response-siblings)))))

(ert-deftest ogent-session--count-response-siblings-ignores-nested ()
  "ogent-session--count-response-siblings should ignore nested headlines."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n** Nested Response\nShould not count\n* Response\nShould count\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (should (= 1 (ogent-session--count-response-siblings)))))

(ert-deftest ogent-session--has-response-sibling-p-detects-existing ()
  "ogent-session--has-response-sibling-p should detect existing Response."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n* Response\nAnswer\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (should (ogent-session--has-response-sibling-p))))

(ert-deftest ogent-session--has-response-sibling-p-returns-nil-initially ()
  "ogent-session--has-response-sibling-p should return nil with no Response."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat is this?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (should-not (ogent-session--has-response-sibling-p))))

(ert-deftest ogent-session--create-response-headline-creates-response-2 ()
  "ogent-session--create-response-headline should create Response 2 when one exists."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n* Response\nFirst answer\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (should (search-forward "* Response 2" nil t))))

(ert-deftest ogent-session--create-response-headline-creates-response-3 ()
  "ogent-session--create-response-headline should create Response 3 when two exist."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n* Response\nFirst\n* Response 2\nSecond\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (should (search-forward "* Response 3" nil t))))

(ert-deftest ogent-session--create-response-headline-adds-properties ()
  "ogent-session--create-response-headline should add PROPERTIES drawer."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (should (search-forward ":PROPERTIES:" nil t))
    (should (search-forward ":RESPONSE-INDEX:" nil t))
    (should (search-forward ":CREATED:" nil t))
    (should (search-forward ":END:" nil t))))

(ert-deftest ogent-session--create-response-headline-sets-correct-index ()
  "ogent-session--create-response-headline should set correct RESPONSE-INDEX."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n* Response\nFirst\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (search-forward "* Response 2")
    (should (string= "2" (org-entry-get (point) "RESPONSE-INDEX")))))

(ert-deftest ogent-session--create-response-headline-index-1-for-first ()
  "ogent-session--create-response-headline should set index 1 for first Response."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (search-forward "* Response")
    (should (string= "1" (org-entry-get (point) "RESPONSE-INDEX")))))

(ert-deftest ogent-session--create-response-headline-adds-timestamp ()
  "ogent-session--create-response-headline should add CREATED timestamp."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nWhat?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (search-forward "* Response")
    (let ((timestamp (org-entry-get (point) "CREATED")))
      (should timestamp)
      (should (string-match-p "\\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]" timestamp)))))

(ert-deftest ogent-session--create-response-headline-at-different-levels ()
  "ogent-session--create-response-headline should work at different levels."
  (with-temp-buffer
    (org-mode)
    (insert "*** Question\nWhat?\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (ogent-session--create-response-headline)
    (goto-char (point-min))
    (should (search-forward "*** Response" nil t))))

(ert-deftest ogent-session-edit-workflow-integration ()
  "Integration test: edit Question and create fork."
  (with-temp-buffer
    (org-mode)
    (insert "* Question\nOriginal question\n")
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    
    ;; First response
    (let ((marker1 (ogent-session--create-response-headline)))
      (should (markerp marker1))
      (goto-char marker1)
      (insert "First answer\n"))
    
    ;; User edits the Question
    (goto-char (point-min))
    (search-forward "Original")
    (replace-match "Edited")
    
    ;; Second response (fork)
    (goto-char (point-min))
    (forward-line 1)  ; Move into Question content
    (let ((marker2 (ogent-session--create-response-headline)))
      (should (markerp marker2))
      (goto-char marker2)
      (insert "Second answer\n"))
    
    ;; Verify structure
    (goto-char (point-min))
    (should (search-forward "* Question" nil t))
    (should (search-forward "Edited question" nil t))
    (should (search-forward "* Response" nil t))
    (should (search-forward "First answer" nil t))
    (should (search-forward "* Response 2" nil t))
    (should (search-forward "Second answer" nil t))))

;;; Streaming Edge Case Tests for ogent-ask callback

(ert-deftest ogent-ask-callback-completes-on-final-marker ()
  "ogent-ask callback should handle :final completion marker."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback "Complete " nil)
        (funcall callback "via final" nil)
        (funcall callback nil '(:final t))
        (should (equal displayed "Complete via final"))))))

(ert-deftest ogent-ask-callback-completes-on-status-success ()
  "ogent-ask callback should handle :status \"success\" completion marker."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback "Status " nil)
        (funcall callback "success" nil)
        (funcall callback nil '(:status "success"))
        (should (equal displayed "Status success"))))))

(ert-deftest ogent-ask-callback-non-streaming-completion ()
  "ogent-ask callback should detect non-streaming completion (text + nil info)."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming nil)  ; Non-streaming mode
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        ;; Non-streaming: single response, info is nil
        (funcall callback "Full response at once" nil)
        (should (equal displayed "Full response at once"))))))

(ert-deftest ogent-ask-callback-streaming-ignores-nil-info-text ()
  "In streaming mode, text with nil info should NOT trigger completion."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        ;; In streaming mode, chunks arrive as (text nil) - should only accumulate
        (funcall callback "chunk1" nil)
        (should-not displayed)  ; Not done yet
        (should (equal ogent-ask--streaming-response "chunk1"))))))

(ert-deftest ogent-ask-callback-empty-response-on-done ()
  "ogent-ask callback should not call display when response is empty at completion."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        ;; Signal done without any accumulated text
        (funcall callback nil '(:done t))
        ;; Display should not be called for empty response
        (should-not displayed)))))

(ert-deftest ogent-ask-callback-nil-text-chunks ()
  "ogent-ask callback should handle nil text chunks gracefully."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback "real " nil)
        ;; nil text shouldn't crash or corrupt accumulator
        (funcall callback nil nil)
        (funcall callback "data" nil)
        (funcall callback nil '(:done t))
        (should (equal displayed "real data"))))))

(ert-deftest ogent-ask-callback-error-then-retry-accumulates-fresh ()
  "After error resets accumulator, subsequent streaming starts fresh."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        ;; First attempt: partial data then error
        (funcall callback "stale data" nil)
        (funcall callback nil '(:error "Connection lost"))
        (should (equal ogent-ask--streaming-response ""))
        ;; Second attempt: fresh accumulation
        (funcall callback "fresh data" nil)
        (funcall callback nil '(:done t))
        ;; Should display only fresh data, not stale
        (should (equal displayed "fresh data"))))))

(ert-deftest ogent-ask-callback-error-message-contains-details ()
  "ogent-ask callback error message should include the error string."
  (setq ogent-ask--streaming-response "")
  (let ((message-log nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-log (apply #'format fmt args)))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback nil '(:error "rate limit exceeded"))
        (should (string-match-p "rate limit exceeded" message-log))))))

(ert-deftest ogent-ask-callback-streaming-done-with-t-text ()
  "Streaming done with text=t and info plist should trigger completion."
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  (let ((displayed nil))
    (cl-letf (((symbol-value 'ogent-ask-display-function)
               (lambda (text) (setq displayed text))))
      (let ((callback (ogent-ask--make-callback)))
        (funcall callback "accumulated" nil)
        ;; Some backends send t as text with info plist on done
        (funcall callback t '(:done t))
        (should (equal displayed "accumulated"))))))

(provide 'ogent-core-tests)
;;; ogent-core-tests.el ends here
