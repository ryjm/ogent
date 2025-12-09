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
    (define-key map (kbd "C-c o p") #'ogent-prompt-dispatch)
    (define-key map (kbd "C-c o r") #'ogent-request)
    (define-key map (kbd "C-c o c") #'ogent-context-preview)
    (define-key map (kbd "C-c o m") #'ogent-codemap-buffer)
    (define-key map (kbd "C-c o a") #'ogent-abort-request)
    (define-key map (kbd "C-c o R") #'ogent-retry-request)
    map)
  "Keymap for `ogent-mode'.")

;;;###autoload
(define-minor-mode ogent-mode
  "Minor mode providing ogent AI assistant commands via C-c o prefix.
When enabled, provides access to ogent commands in any buffer.
For non-Org buffers, companion Org buffers are automatically created
to maintain conversation history."
  :lighter " Ogent"
  :keymap ogent-mode-map
  (when ogent-mode
    (when (derived-mode-p 'org-mode)
      (ogent-ui--setup-highlight-mode))))

(defun ogent--maybe-enable ()
  "Enable `ogent-mode' in all buffers.
This is the function used by `ogent-global-mode' to enable
ogent-mode globally across all buffers."
  (ogent-mode 1))

;;;###autoload
(define-globalized-minor-mode ogent-global-mode
  ogent-mode ogent--maybe-enable)

(provide 'ogent-core)

;;; ogent-core.el ends here
