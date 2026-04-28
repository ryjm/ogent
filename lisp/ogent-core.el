;;; ogent-core.el --- Minor mode scaffold for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Defines the ogent minor mode, keymap, and user-facing hooks.
;; Also provides context validation utilities for checking handle resolution.
;;
;; Integration with request flow (for ogent-ui.el):
;;   After calling `ogent-context-build-with-source' and before
;;   `ogent-ui--send-request', call `ogent-validate-and-prompt' to check
;;   for missing handles and prompt user if needed.  This function respects
;;   the `ogent-validate-before-send' customization setting.

;;; Code:

(require 'org)
(require 'ogent-context)
(require 'ogent-keys)

(declare-function ogent-request "ui/ogent-ui")
(declare-function ogent-context-preview "ui/ogent-ui")
(declare-function ogent-prompt-dispatch "ui/ogent-ui")
(declare-function ogent-abort-request "ui/ogent-ui")
(declare-function ogent-retry-request "ui/ogent-ui")
(declare-function ogent-ui--setup-highlight-mode "ui/ogent-ui")
(declare-function ogent-show-backlinks "ui/ogent-ui-backlinks")
(declare-function ogent-show-dependency-graph "ui/ogent-ui-graph")
(declare-function ogent-codemap-buffer "ogent-codemap")
(declare-function ogent-ai-speed-edit "ogent-edit")
(declare-function ogent-request-edit "ogent-edit")
(declare-function ogent-edit-menu "ogent-edit")
(declare-function ogent-edit-goto-source "ogent-edit-display")
(declare-function ogent-edit-goto-companion "ogent-edit-display")
(declare-function ogent-debug-tools-menu "ogent-debug")
(declare-function ogent-debug-mode "ogent-debug")
(declare-function ogent-tool-rerun "ui/ogent-ui")
(declare-function ogent-notes-capture "ogent-notes")
(declare-function ogent-session-save "ogent-session")
(declare-function ogent-session-load "ogent-session")
(declare-function ogent-session-list "ogent-session")
(declare-function ogent-issues "ogent-issues")
(declare-function ogent-pin-dwim "ogent-context")
(declare-function ogent-unpin-interactive "ogent-context")

;; Prompt validation (optional dependency)
(declare-function ogent-prompt-validate-composition "ogent-prompts")
(declare-function ogent-list-pinned "ogent-context")

;; gptel integration
(declare-function gptel-request "ext:gptel" (prompt &rest args))
(defvar gptel-model)
(defvar gptel-stream)

(defgroup ogent-mode nil
  "Customization entries for `ogent-mode'."
  :group 'ogent)

(defcustom ogent-after-request-hook nil
  "Hook run after `ogent-request' inserts a response.
Each function receives the formatted context plist."
  :type 'hook
  :group 'ogent-mode)

(defcustom ogent-validate-before-send nil
  "Control validation of @handles before sending to LLM.
nil - Don't validate (default)
`warn' - Show warning message if missing handles detected
`confirm' - Prompt user to confirm or abort if missing handles found"
  :type '(choice (const :tag "No validation" nil)
                 (const :tag "Warn about missing handles" warn)
                 (const :tag "Confirm before sending" confirm))
  :group 'ogent-mode)

(defcustom ogent-notify-on-completion nil
  "Control how to notify when requests complete.
nil - No notification (default)
`message' - Display completion message in echo area
`modeline-flash' - Briefly flash the mode-line"
  :type '(choice (const :tag "No notification" nil)
                 (const :tag "Message in echo area" message)
                 (const :tag "Flash mode-line" modeline-flash))
  :group 'ogent-mode)

(defcustom ogent-after-completion-hook nil
  "Hook run after a request completes (success or error).
Each function receives the request plist as argument.
Request plist should contain :model, :status, :start-time, :end-time."
  :type 'hook
  :group 'ogent-mode)

(defun ogent-context-validate (context)
  "Validate CONTEXT and return list of missing handle names.
CONTEXT is a plist as returned by `ogent-context-build'.
Extracts :dependencies and filters for entries where :missing-p is t.
Returns a list of handle names (strings) that could not be resolved."
  (let ((dependencies (plist-get context :dependencies))
        (missing nil))
    (dolist (dep dependencies)
      (when (plist-get dep :missing-p)
        (push (plist-get dep :handle) missing)))
    (nreverse missing)))

(defun ogent-context-add-validation-warnings (context)
  "Add :validation-warnings key to CONTEXT plist.
Returns the updated context plist with warnings about missing handles."
  (let* ((missing-handles (ogent-context-validate context))
         (warnings (when missing-handles
                     (list (format "Missing handles: %s"
                                   (string-join missing-handles ", "))))))
    (plist-put context :validation-warnings warnings)))

(defun ogent-validate-and-prompt (context)
  "Validate CONTEXT according to `ogent-validate-before-send'.
Returns non-nil if the request should proceed, nil to abort.
Adds :validation-warnings to context as a side effect."
  (let ((missing-handles (ogent-context-validate context)))
    (ogent-context-add-validation-warnings context)
    (if (null missing-handles)
        t  ; No missing handles, proceed
      (pcase ogent-validate-before-send
        ('nil t)  ; No validation, proceed anyway
        ('warn
         (message "Warning: Missing handles: %s"
                  (string-join missing-handles ", "))
         t)  ; Show warning but proceed
        ('confirm
         (y-or-n-p
          (format "Missing handles: %s. Continue anyway? "
                  (string-join missing-handles ", "))))
        (_ t)))))  ; Unknown setting, proceed

;;; Prompt Validation Integration

(defun ogent-validate-prompts (prompt-ids context)
  "Validate that CONTEXT satisfies requirements for PROMPT-IDS.
PROMPT-IDS is a list of prompt ID strings.
CONTEXT is a plist of available context (e.g., (:code \"...\")).
Returns a plist with :valid (boolean) and :missing (list of missing keys).

Requires ogent-prompts to be loaded; returns valid if not available."
  (if (require 'ogent-prompts nil t)
      (ogent-prompt-validate-composition prompt-ids context)
    (list :valid t :missing nil)))

(defun ogent-context-add-prompt-warnings (context)
  "Add :prompt-warnings key to CONTEXT plist.
Validates prompts referenced in :prompt-ids against available context.
Returns the updated context plist with warnings about missing context."
  (let* ((prompt-ids (plist-get context :prompt-ids))
         (validation (when prompt-ids
                       (ogent-validate-prompts prompt-ids context)))
         (missing (plist-get validation :missing))
         (warnings (when missing
                     (list (format "Prompts require missing context: %s"
                                   (mapconcat #'symbol-name missing ", "))))))
    (plist-put context :prompt-warnings warnings)))

(defun ogent-validate-prompts-and-prompt (context)
  "Validate prompt requirements in CONTEXT according to `ogent-validate-before-send'.
Returns non-nil if the request should proceed, nil to abort.
Adds :prompt-warnings to context as a side effect."
  (let* ((prompt-ids (plist-get context :prompt-ids))
         (validation (when prompt-ids
                       (ogent-validate-prompts prompt-ids context)))
         (missing (plist-get validation :missing)))
    (ogent-context-add-prompt-warnings context)
    (if (null missing)
        t  ; No missing context, proceed
      (pcase ogent-validate-before-send
        ('nil t)  ; No validation, proceed anyway
        ('warn
         (message "Warning: Prompts require missing context: %s"
                  (mapconcat #'symbol-name missing ", "))
         t)  ; Show warning but proceed
        ('confirm
         (y-or-n-p
          (format "Prompts require missing context: %s. Continue anyway? "
                  (mapconcat #'symbol-name missing ", "))))
        (_ t)))))  ; Unknown setting, proceed

(defvar ogent-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Set up all bindings from the action registry
    (ogent-setup-all-bindings map)
    map)
  "Keymap for `ogent-mode'.
Bindings are defined in `ogent-action-registry' and set up via
`ogent-setup-all-bindings'.  Use `ogent-describe-bindings' to see all.")

;;;###autoload (autoload 'ogent-mode "ogent" nil t)
(define-minor-mode ogent-mode
  "Minor mode providing ogent AI assistant commands via C-c . prefix.
When enabled, provides access to ogent commands in any buffer.
For non-Org buffers, companion Org buffers are automatically created
to maintain conversation history."
  :lighter " Ogent"
  :keymap ogent-mode-map
  (if ogent-mode
      (progn
        (when (derived-mode-p 'org-mode)
          ;; Use save-window-excursion to prevent buffer/window switching
          ;; side effects from gptel-highlight-mode or other mode hooks.
          ;; This is stronger than save-selected-window as it also restores
          ;; window-buffer associations.
          (save-window-excursion
            (when (fboundp 'ogent-ui--setup-highlight-mode)
              (ogent-ui--setup-highlight-mode)))
          ;; Add completion-at-point function for @handles
          (add-hook 'completion-at-point-functions
                    #'ogent-context-completion-at-point nil t)
          ;; Add C-c C-c handler for Question headlines
          (add-hook 'org-ctrl-c-ctrl-c-hook
                    #'ogent-session--ctrl-c-ctrl-c-handler nil t)))
    ;; Remove on disable
    (when (derived-mode-p 'org-mode)
      (remove-hook 'completion-at-point-functions
                   #'ogent-context-completion-at-point t)
      (remove-hook 'org-ctrl-c-ctrl-c-hook
                   #'ogent-session--ctrl-c-ctrl-c-handler t))))

(defun ogent--maybe-enable ()
  "Enable `ogent-mode' in current buffer.
This is the function used by `ogent-global-mode' to enable
ogent-mode globally across all buffers."
  (ogent-mode 1))

;; Use define-globalized-minor-mode for the hook infrastructure
(define-globalized-minor-mode ogent-global-mode--internal
  ogent-mode ogent--maybe-enable)

;;;###autoload (autoload 'ogent-global-mode "ogent" nil t)
(defun ogent-global-mode (&optional arg)
  "Toggle Ogent mode in all buffers.
With prefix ARG, enable if positive, disable otherwise.
This wrapper preserves the current buffer and window configuration."
  (interactive "P")
  (let ((original-buffer (current-buffer))
        (original-window (selected-window))
        (original-window-buffer (window-buffer (selected-window))))
    (ogent-global-mode--internal arg)
    ;; Restore original window and buffer if they still exist
    ;; We must use set-window-buffer to restore what's displayed,
    ;; as set-buffer only changes the current buffer for Lisp code
    (when (window-live-p original-window)
      (select-window original-window 'norecord)
      (when (buffer-live-p original-window-buffer)
        (set-window-buffer original-window original-window-buffer)))
    ;; Also restore current-buffer for any subsequent Lisp code
    (when (buffer-live-p original-buffer)
      (set-buffer original-buffer))))

;;; Completion Notification

(defface ogent-modeline-flash
  '((t :inherit mode-line-highlight))
  "Face used for mode-line flash notification."
  :group 'ogent-mode)

(defvar ogent--modeline-flash-timer nil
  "Timer used to restore mode-line after flash.")

(defun ogent--flash-modeline ()
  "Flash the mode-line briefly to indicate completion."
  ;; Cancel any existing timer
  (when (timerp ogent--modeline-flash-timer)
    (cancel-timer ogent--modeline-flash-timer))
  
  ;; Store original face
  (let ((original-bg (face-attribute 'mode-line :background nil 'default))
        (original-fg (face-attribute 'mode-line :foreground nil 'default))
        (flash-bg (face-attribute 'ogent-modeline-flash :background nil 'default))
        (flash-fg (face-attribute 'ogent-modeline-flash :foreground nil 'default)))
    
    ;; Apply flash
    (set-face-attribute 'mode-line nil
                        :background flash-bg
                        :foreground flash-fg)
    (force-mode-line-update t)
    
    ;; Restore after 0.3s
    (setq ogent--modeline-flash-timer
          (run-with-timer 0.3 nil
                          (lambda ()
                            (set-face-attribute 'mode-line nil
                                                :background original-bg
                                                :foreground original-fg)
                            (force-mode-line-update t))))))

(defun ogent-notify-completion (request)
  "Trigger completion notification based on `ogent-notify-on-completion'.
REQUEST is a plist containing :model, :status, :start-time, :end-time.
Runs `ogent-after-completion-hook' with REQUEST as argument."
  (when request
    ;; Run hook first
    (run-hook-with-args 'ogent-after-completion-hook request)
    
    ;; Trigger notification based on setting
    (pcase ogent-notify-on-completion
      ('message
       (let* ((model (plist-get request :model))
              (status (plist-get request :status))
              (start-time (plist-get request :start-time))
              (end-time (plist-get request :end-time))
              (latency (when (and start-time end-time)
                         (float-time (time-subtract end-time start-time)))))
         (message "ogent: %s completed (%s%s)"
                  (or model "request")
                  (or status "unknown")
                  (if latency
                      (format ", %.1fs" latency)
                    ""))))
      
      ('modeline-flash
       (ogent--flash-modeline))
      
      (_ nil))))

;;; Quick Ask Command

(defcustom ogent-ask-display-function #'ogent-ask--display-popup
  "Function to display ogent-ask responses.
Called with the response text as argument.
Built-in options:
  `ogent-ask--display-popup' - Show in a popup buffer (default)
  `ogent-ask--display-message' - Show in echo area (truncated)"
  :type 'function
  :group 'ogent-mode)

(defvar ogent-ask--buffer-name "*ogent-ask*"
  "Buffer name for ogent-ask responses.")

(defvar ogent-ask--streaming-response ""
  "Accumulated response text during streaming.")

(defvar ogent-ask--is-streaming nil
  "Non-nil when ogent-ask is using streaming mode.")

(defun ogent-ask--display-popup (response)
  "Display RESPONSE in a popup buffer."
  (let ((buf (get-buffer-create ogent-ask--buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert response)
        (goto-char (point-min))
        (when (fboundp 'org-mode)
          (org-mode))
        (setq buffer-read-only t)))
    (display-buffer buf '((display-buffer-reuse-window
                           display-buffer-pop-up-window)
                          (window-height . 0.4)))))

(defun ogent-ask--display-message (response)
  "Display RESPONSE in the echo area (truncated if long)."
  (let ((one-line (replace-regexp-in-string "[\n\r]+" " " response)))
    (message "%s" (truncate-string-to-width one-line 200 nil nil "..."))))

(defun ogent-ask--make-callback ()
  "Return a gptel callback for ogent-ask."
  (lambda (text info)
    ;; Accumulate string content
    (when (stringp text)
      (setq ogent-ask--streaming-response
            (concat ogent-ask--streaming-response text)))
    ;; Check for completion or error
    (cond
     ;; Error case
     ((and (listp info) (plist-get info :error))
      (message "ogent-ask failed: %s" (plist-get info :error))
      (setq ogent-ask--streaming-response ""))
     ;; Done - various completion markers
     ((or (and (listp info)
               (or (plist-get info :done)
                   (plist-get info :final)
                   (equal (plist-get info :status) "success")))
          ;; Non-streaming: text is final response, info is nil
          ;; Only trigger if we're NOT in streaming mode
          (and (not ogent-ask--is-streaming)
               (null info) (stringp text) (> (length text) 0))
          ;; Streaming complete: text is nil/t, info indicates done
          (and (not (stringp text)) (listp info) info))
      (when (> (length ogent-ask--streaming-response) 0)
        (funcall ogent-ask-display-function ogent-ask--streaming-response)
        (setq ogent-ask--streaming-response ""))))))

;;;###autoload
(defun ogent-ask (question)
  "Ask QUESTION and display the response.
This is a quick Q&A command without the full context machinery.
Interactively, prompts for the question.
Response is displayed according to `ogent-ask-display-function'."
  (interactive "sAsk: ")
  (unless (require 'gptel nil 'noerror)
    (user-error "gptel is required for ogent-ask. Install gptel first"))
  (when (string-empty-p (string-trim question))
    (user-error "Question cannot be empty"))
  ;; Reset streaming accumulator and set streaming flag
  (setq ogent-ask--streaming-response "")
  (setq ogent-ask--is-streaming t)
  ;; Send request
  (message "Asking %s..."
           (if (and (boundp 'gptel-model) gptel-model)
               (if (fboundp 'gptel--model-name)
                   (gptel--model-name gptel-model)
                 gptel-model)
             "LLM"))
  (gptel-request question
                 :stream t
                 :callback (ogent-ask--make-callback)))

;;; Open Block Command

(defun ogent-open-block--setup-edit-buffer ()
  "Set up the org-src edit buffer with ogent-mode."
  (when (and (boundp 'org-src-mode) org-src-mode)
    (ogent-mode 1)))

;;;###autoload
(defun ogent-open-block (&optional arg)
  "Open the source block at point with ogent-mode enabled.
This wraps `org-edit-special' but ensures ogent-mode is active
in the edit buffer, allowing you to use ogent commands while
editing code.

With prefix ARG, passed to `org-edit-special' (e.g., for session buffers)."
  (interactive "P")
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent-open-block only works in Org buffers"))
  ;; Check if we're in a source block
  (let ((element (org-element-at-point)))
    (unless (memq (org-element-type element) '(src-block example-block))
      (user-error "Point is not in a source block")))
  ;; Add hook to enable ogent-mode in the edit buffer
  (add-hook 'org-src-mode-hook #'ogent-open-block--setup-edit-buffer)
  (unwind-protect
      (org-edit-special arg)
    ;; Remove hook after use to avoid affecting other org-edit-special calls
    (remove-hook 'org-src-mode-hook #'ogent-open-block--setup-edit-buffer)))

;;; Inline Prompting from Session Buffer

(defun ogent-session--in-question-headline-p ()
  "Return non-nil if point is at or under a headline titled \"Question\".
Case-insensitive match."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      ;; Move to the headline containing point
      (condition-case nil
          (progn
            (org-back-to-heading t)
            (let ((heading-text (org-get-heading t t t t)))
              (and heading-text
                   (string-match-p "\\`[Qq]uestion\\'" heading-text))))
        (error nil)))))

(defun ogent-session--extract-question-content ()
  "Extract content under the current Question headline.
Returns the text content as a string, excluding the headline itself."
  (save-excursion
    (org-back-to-heading t)
    (let ((element (org-element-at-point)))
      (when (eq (org-element-type element) 'headline)
        (let* ((contents-begin (org-element-property :contents-begin element))
               (contents-end (org-element-property :contents-end element)))
          (when (and contents-begin contents-end)
            (string-trim
             (buffer-substring-no-properties contents-begin contents-end))))))))

(defun ogent-session--count-response-siblings ()
  "Count existing Response headlines that are siblings of current headline.
Returns the number of Response headlines found."
  (save-excursion
    (org-back-to-heading t)
    (let ((level (org-current-level))
          (count 0))
      ;; Find the end of the parent subtree (or buffer if at top level)
      (let ((limit (save-excursion
                     (if (org-up-heading-safe)
                         (progn
                           (org-end-of-subtree t t)
                           (point))
                       (point-max)))))
        ;; Move past the current headline
        (forward-line 1)
        ;; Scan forward for siblings at the same level
        (while (< (point) limit)
          (when (and (org-at-heading-p)
                     (= (org-current-level) level))
            (let ((heading-text (org-get-heading t t t t)))
              (when (and heading-text
                         (string-match-p "\\`[Rr]esponse" heading-text))
                (setq count (1+ count)))))
          ;; Move to next line
          (forward-line 1))
        count))))

(defun ogent-session--has-response-sibling-p ()
  "Return non-nil if current Question headline has a Response sibling."
  (> (ogent-session--count-response-siblings) 0))

(defun ogent-session--create-response-headline ()
  "Create a sibling Response headline after the current Question headline.
If Response siblings already exist, creates \"Response 2\", \"Response 3\", etc.
Adds a PROPERTIES drawer with :RESPONSE-INDEX: for tracking.
Returns the marker pointing to the response location."
  (save-excursion
    (org-back-to-heading t)
    (let ((level (org-current-level))
          (response-count (ogent-session--count-response-siblings)))
      ;; Move to end of the Question subtree (and any existing Response siblings)
      (org-end-of-subtree t t)
      ;; Skip any existing Response siblings by moving forward while we find them
      (while (and (not (eobp))
                  (progn
                    (forward-line 0)  ; Move to beginning of line
                    (looking-at org-heading-regexp))
                  (= (org-current-level) level)
                  (let ((heading-text (org-get-heading t t t t)))
                    (and heading-text
                         (string-match-p "\\`[Rr]esponse" heading-text))))
        (org-end-of-subtree t t))
      ;; Now insert the new Response headline
      (unless (bolp) (insert "\n"))
      (let ((response-title (if (> response-count 0)
                                (format "Response %d" (1+ response-count))
                              "Response"))
            (response-index (1+ response-count)))
        (insert (make-string level ?*) " " response-title "\n")
        ;; Add timestamp and response index property
        (let ((timestamp (format-time-string "[%Y-%m-%d %a %H:%M]")))
          (insert ":PROPERTIES:\n")
          (insert (format ":RESPONSE-INDEX: %d\n" response-index))
          (insert (format ":CREATED: %s\n" timestamp))
          (insert ":END:\n"))
        (copy-marker (point) t)))))

;;;###autoload
(defun ogent-session-prompt-from-question ()
  "Prompt from a Question headline in the session buffer.
Extracts the content under the Question headline as the prompt,
creates a sibling Response headline, and streams the response there.

If a Response sibling already exists, this creates a new fork of the
conversation (Response 2, Response 3, etc.), allowing you to edit
the Question and re-send it to explore different paths.

Each Response headline includes a PROPERTIES drawer with:
  :RESPONSE-INDEX: - The sequential number of this response
  :CREATED: - Timestamp when the response was generated

This function is designed to be called via C-c C-c when point is
in or under a Question headline."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "ogent-session-prompt-from-question only works in Org buffers"))
  (unless (ogent-session--in-question-headline-p)
    (user-error "Point is not in a Question headline"))
  
  (let ((question-content (ogent-session--extract-question-content)))
    (when (or (null question-content) (string-empty-p question-content))
      (user-error "Question headline has no content"))
    
    ;; Create Response headline and get marker
    (let ((response-marker (ogent-session--create-response-headline)))
      ;; Send the request using gptel
      (unless (require 'gptel nil 'noerror)
        (user-error "gptel is required for ogent session prompting. Install gptel first"))
      
      (message "Sending question to %s..."
               (if (and (boundp 'gptel-model) gptel-model)
                   (if (fboundp 'gptel--model-name)
                       (gptel--model-name gptel-model)
                     gptel-model)
                 "LLM"))
      
      ;; Use gptel-request with streaming to the Response headline
      (gptel-request question-content
                     :stream (if (boundp 'gptel-stream) gptel-stream t)
                     :callback (lambda (text info)
                                 (ogent-session--stream-callback
                                  text info response-marker))))))

(defun ogent-session--stream-callback (text info marker)
  "Callback for streaming responses to MARKER.
TEXT is the chunk of response, INFO contains metadata."
  (cond
   ;; Error case
   ((and (listp info) (plist-get info :error))
    (when (marker-buffer marker)
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (insert (format "\n#+begin_quote\nError: %s\n#+end_quote\n"
                          (plist-get info :error))))))
    (message "Request failed: %s" (plist-get info :error)))
   
   ;; Streaming text
   ((stringp text)
    (when (and text (> (length text) 0) (marker-buffer marker))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (insert text)
          (set-marker marker (point))))))
   
   ;; Completion
   ((or (and (listp info)
             (or (plist-get info :done)
                 (plist-get info :final)
                 (equal (plist-get info :status) "success")))
        (and (not (stringp text)) (listp info) info))
    (message "Response complete"))))

(defun ogent-session--ctrl-c-ctrl-c-handler ()
  "Handler for C-c C-c in ogent session buffers.
Returns non-nil if we handled the key, nil to fall through to other handlers."
  (when (and (derived-mode-p 'org-mode)
             (ogent-session--in-question-headline-p))
    (ogent-session-prompt-from-question)
    t))  ; Signal that we handled it

(provide 'ogent-core)

;;; ogent-core.el ends here
