;;; ogent-provider-fallback.el --- Provider fallback prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared provider access error handling for chat and edit request paths.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(autoload 'ogent-onboard-login-different-provider "ogent-onboard" nil t)

(declare-function gptel--model-name "ext:gptel-request")

(defgroup ogent-provider-fallback nil
  "Provider fallback behavior for failed model access."
  :group 'ogent)

(defcustom ogent-prompt-provider-login-on-access-error t
  "When non-nil, offer provider login after model access errors."
  :type 'boolean
  :group 'ogent-provider-fallback)

(defconst ogent-provider--built-in-access-error-patterns
  '("invalid api key"
    "unauthorized"
    "authentication"
    "permission denied"
    "forbidden"
    "access denied"
    "not have access"
    "does not have access"
    "model_not_found"
    "model .*not found"
    "model .*unavailable"
    "insufficient_quota"
    "quota exceeded"
    "billing"
    "credit"
    "payment required"
    "account balance")
  "Built-in access error regexps that should always be recognized.")

(defcustom ogent-provider-access-error-patterns
  ogent-provider--built-in-access-error-patterns
  "Case-insensitive regexps that identify provider or model access errors."
  :type '(repeat regexp)
  :group 'ogent-provider-fallback)

(defvar ogent-provider--login-prompt-active nil
  "Non-nil while a provider login prompt is active.")

(defun ogent-provider-error-message-string (error-message)
  "Return ERROR-MESSAGE as a display string."
  (cond
   ((stringp error-message) error-message)
   ((null error-message) "")
   (t (format "%s" error-message))))

(defun ogent-provider-access-error-p (error-message)
  "Detect whether ERROR-MESSAGE reports a provider access failure."
  (let ((message (downcase (ogent-provider-error-message-string
                            error-message))))
    (cl-some (lambda (pattern)
               (string-match-p pattern message))
             (append ogent-provider-access-error-patterns
                     ogent-provider--built-in-access-error-patterns))))

(defun ogent-provider--model-name (model)
  "Return a display name for MODEL."
  (cond
   ((stringp model) model)
   ((symbolp model) (symbol-name model))
   ((and model (fboundp 'gptel--model-name))
    (or (ignore-errors (gptel--model-name model))
        (format "%s" model)))
   (model (format "%s" model))
   (t "selected model")))

(defun ogent-provider-login-prompt (model error-message)
  "Return the provider login prompt for MODEL and ERROR-MESSAGE."
  (let ((short-error (truncate-string-to-width
                      (ogent-provider-error-message-string error-message)
                      80 nil nil "...")))
    (format "%s failed: %s. Login to a different provider now? "
            (ogent-provider--model-name model)
            short-error)))

(defun ogent-provider-offer-login (model backend error-message)
  "Offer login to another provider after MODEL fails with ERROR-MESSAGE.
BACKEND identifies the provider that failed, when available."
  (unless ogent-provider--login-prompt-active
    (let ((ogent-provider--login-prompt-active t))
      (when (y-or-n-p (ogent-provider-login-prompt model error-message))
        (condition-case err
            (ogent-onboard-login-different-provider backend)
          (error
           (message "Provider login failed: %s"
                    (error-message-string err))))))))

(defun ogent-provider-maybe-offer-login (model backend error-message)
  "Schedule provider login offer for MODEL when ERROR-MESSAGE qualifies.
BACKEND identifies the provider that failed, when available."
  (when (and ogent-prompt-provider-login-on-access-error
             (not noninteractive)
             (ogent-provider-access-error-p error-message))
    (run-at-time 0 nil #'ogent-provider-offer-login
                 model backend
                 (ogent-provider-error-message-string error-message))))

(provide 'ogent-provider-fallback)

;;; ogent-provider-fallback.el ends here
