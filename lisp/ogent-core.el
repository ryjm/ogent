;;; ogent-core.el --- Minor mode scaffold for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Defines the ogent minor mode, keymap, and user-facing hooks.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ogent-context)

(declare-function ogent-request "ogent-ui")
(declare-function ogent-context-preview "ogent-ui")
(declare-function ogent-prompt-dispatch "ogent-ui")
(declare-function ogent-abort-request "ogent-ui")
(declare-function ogent-retry-request "ogent-ui")
(declare-function ogent-ui--setup-highlight-mode "ogent-ui")
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

(defvar ogent-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Note: C-c followed by punctuation is reserved for minor modes
    (define-key map (kbd "C-c . p") #'ogent-prompt-dispatch)
    (define-key map (kbd "C-c . r") #'ogent-request)
    (define-key map (kbd "C-c . c") #'ogent-context-preview)
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
  (when ogent-mode
    (when (derived-mode-p 'org-mode)
      ;; Use save-selected-window to prevent buffer switching side effects
      ;; from gptel-highlight-mode or other mode hooks
      (save-selected-window
        (when (fboundp 'ogent-ui--setup-highlight-mode)
          (ogent-ui--setup-highlight-mode))))))

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
