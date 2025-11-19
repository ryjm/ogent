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
    map)
  "Keymap for `ogent-mode'.")

;;;###autoload
(define-minor-mode ogent-mode
  "Minor mode that turns an Org buffer into an ogent agent panel."
  :lighter " Ogent"
  :keymap ogent-mode-map)

(defun ogent--maybe-enable ()
  "Enable `ogent-mode' inside Org buffers."
  (when (derived-mode-p 'org-mode)
    (ogent-mode 1)))

;;;###autoload
(define-globalized-minor-mode ogent-global-mode
  ogent-mode ogent--maybe-enable)

(provide 'ogent-core)

;;; ogent-core.el ends here
