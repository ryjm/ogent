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

(require 'cl-lib)
(require 'org)
(require 'ogent-context)

(declare-function ogent-request "ui/ogent-ui")
(declare-function ogent-context-preview "ui/ogent-ui")
(declare-function ogent-prompt-dispatch "ui/ogent-ui")
(declare-function ogent-abort-request "ui/ogent-ui")
(declare-function ogent-retry-request "ui/ogent-ui")
(declare-function ogent-ui--setup-highlight-mode "ui/ogent-ui")
(declare-function ogent-show-backlinks "ui/ogent-ui-backlinks")
(declare-function ogent-show-dependency-graph "ui/ogent-ui-graph")
(declare-function ogent-codemap-buffer "ogent-codemap")
(declare-function ogent-request-edit "ogent-edit")
(declare-function ogent-edit-menu "ogent-edit")
(declare-function ogent-edit-goto-source "ogent-edit-display")
(declare-function ogent-edit-goto-companion "ogent-edit-display")
(declare-function ogent-debug-tools-menu "ogent-debug")

(defgroup ogent-mode nil
  "Customization entries for `ogent-mode'."
  :group 'ogent)

(defcustom ogent-default-model "gpt-4o-mini"
  "Default model identifier used when dispatching prompts."
  :type 'string
  :group 'ogent-mode)

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

(defvar ogent-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Note: C-c followed by punctuation is reserved for minor modes
    (define-key map (kbd "C-c . p") #'ogent-prompt-dispatch)
    (define-key map (kbd "C-c . r") #'ogent-request)
    (define-key map (kbd "C-c . c") #'ogent-context-preview)
    (define-key map (kbd "C-c . b") #'ogent-show-backlinks)
    (define-key map (kbd "C-c . g") #'ogent-show-dependency-graph)
    (define-key map (kbd "C-c . m") #'ogent-codemap-buffer)
    (define-key map (kbd "C-c . a") #'ogent-abort-request)
    (define-key map (kbd "C-c . R") #'ogent-retry-request)
    (define-key map (kbd "C-c . e") #'ogent-edit-menu)
    (define-key map (kbd "C-c . E") #'ogent-request-edit)
    (define-key map (kbd "C-c . t") #'ogent-debug-tools-menu)
    ;; Navigation between source and companion
    (define-key map (kbd "C-c . s") #'ogent-edit-goto-source)
    (define-key map (kbd "C-c . C") #'ogent-edit-goto-companion)
    ;; Quick ask
    (define-key map (kbd "C-c . ?") #'ogent-ask)
    map)
  "Keymap for `ogent-mode'.")

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
                    #'ogent-context-completion-at-point nil t)))
    ;; Remove on disable
    (when (derived-mode-p 'org-mode)
      (remove-hook 'completion-at-point-functions
                   #'ogent-context-completion-at-point t))))

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

(declare-function gptel-request "ext:gptel" (prompt &rest args))
(defvar gptel-model)

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

(provide 'ogent-core)

;;; ogent-core.el ends here
