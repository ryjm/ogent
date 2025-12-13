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
          ;; Use save-selected-window to prevent buffer switching side effects
          ;; from gptel-highlight-mode or other mode hooks
          (save-selected-window
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
This wrapper preserves the current buffer and window."
  (interactive "P")
  (let ((original-buffer (current-buffer))
        (original-window (selected-window)))
    (ogent-global-mode--internal arg)
    ;; Restore original buffer/window if they still exist
    (when (and (window-live-p original-window)
               (buffer-live-p original-buffer))
      (select-window original-window)
      (set-buffer original-buffer))))

(provide 'ogent-core)

;;; ogent-core.el ends here
