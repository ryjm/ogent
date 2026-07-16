;;; ogent-provider-fallback.el --- Provider fallback prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared provider access error handling for chat and edit request paths,
;; including headless retry with exponential backoff and automatic
;; failover to a model from a different provider.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'ogent-models)

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

(defconst ogent-provider--built-in-transient-error-patterns
  '("rate.?limit"
    "too many requests"
    "\\b429\\b"
    "\\b\\(?:500\\|502\\|503\\|504\\|529\\)\\b"
    "internal server error"
    "bad gateway"
    "service unavailable"
    "gateway time.?out"
    "overloaded"
    "temporarily unavailable"
    "connection \\(?:reset\\|refused\\|broken\\|closed\\)"
    "network \\(?:error\\|failure\\|is unreachable\\)"
    "could not resolve host"
    "timed? ?out")
  "Built-in transient error regexps that should always be recognized.")

(defcustom ogent-provider-transient-error-patterns
  ogent-provider--built-in-transient-error-patterns
  "Case-insensitive regexps that identify transient provider errors.
Transient errors (rate limits, 5xx statuses, network hiccups) are
retried automatically with exponential backoff before failing over
to a different provider."
  :type '(repeat regexp)
  :group 'ogent-provider-fallback)

(defcustom ogent-provider-max-retries 2
  "Maximum number of automatic retries for a transient model error.
Retries target the model that failed; once they are exhausted, ogent
fails over to a model from a different provider when one is
registered.  A :max-retries property on a model's
`ogent-model-registry' entry overrides this default for that model."
  :type 'natnum
  :group 'ogent-provider-fallback)

(defcustom ogent-provider-retry-base-delay 1.0
  "Base delay in seconds before the first automatic retry.
Each subsequent retry doubles the previous delay.  A
:retry-base-delay property on a model's `ogent-model-registry' entry
overrides this default for that model."
  :type 'number
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

(defun ogent-provider-transient-error-p (error-message)
  "Detect whether ERROR-MESSAGE reports a transient provider failure."
  (let ((message (downcase (ogent-provider-error-message-string
                            error-message))))
    (cl-some (lambda (pattern)
               (string-match-p pattern message))
             (append ogent-provider-transient-error-patterns
                     ogent-provider--built-in-transient-error-patterns))))

(defun ogent-provider-classify-error (error-message)
  "Classify ERROR-MESSAGE as one of `auth', `transient', or `fatal'.
`auth' covers access errors that require credentials or account
changes and are never retried against the same provider.
`transient' covers rate limits, 5xx statuses, and network failures
that warrant an automatic retry.  Anything unrecognized is `fatal'.
Access patterns win over transient ones so hard auth failures are
never retried."
  (cond
   ((ogent-provider-access-error-p error-message) 'auth)
   ((ogent-provider-transient-error-p error-message) 'transient)
   (t 'fatal)))

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

(defun ogent-provider--model-id (model)
  "Return the canonical registry id string for MODEL, or nil.
MODEL may be a registry id string, an alias, a symbol, or a model
plist with an :id entry."
  (cond
   ((stringp model) (or (ogent-models-canonical-id model) model))
   ((and model (symbolp model))
    (ogent-provider--model-id (symbol-name model)))
   ((and (listp model) (plist-get model :id)))
   (t nil)))

(defun ogent-provider--model-provider (model-id)
  "Return the backend symbol registered for MODEL-ID, or nil."
  (when (stringp model-id)
    (plist-get (ogent-models-get model-id) :backend)))

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

;;; Headless retry and failover

(defun ogent-provider--model-property (model-id property default)
  "Return MODEL-ID's registry PROPERTY, or DEFAULT when it is absent.
Registry properties are per-model overrides; DEFAULT carries the
documented global behavior for models that do not set PROPERTY."
  (let ((entry (and (stringp model-id) (ogent-models-get model-id))))
    (if (plist-member entry property)
        (plist-get entry property)
      default)))

(defun ogent-provider-model-max-retries (model-id)
  "Return the maximum automatic transient retries allowed for MODEL-ID.
A :max-retries property on MODEL-ID's `ogent-model-registry' entry
overrides `ogent-provider-max-retries'."
  (ogent-provider--model-property
   model-id :max-retries ogent-provider-max-retries))

(defun ogent-provider-retry-delay (attempt &optional model-id)
  "Return the backoff delay in seconds before scheduling a retry.
ATTEMPT counts the retries already performed, starting at zero, so
the delay doubles with each successive retry.  When MODEL-ID names an
`ogent-model-registry' entry with a :retry-base-delay property, that
base delay replaces `ogent-provider-retry-base-delay'."
  (* (ogent-provider--model-property
      model-id :retry-base-delay ogent-provider-retry-base-delay)
     (expt 2 attempt)))

(defun ogent-provider--context-put (context &rest props)
  "Return a copy of the CONTEXT plist with PROPS merged in."
  (let ((result (copy-sequence context)))
    (while props
      (setq result (plist-put result (pop props) (pop props))))
    result))

(defun ogent-provider--dispatch (model-id context)
  "Re-issue the request described by CONTEXT against MODEL-ID.
Call the :dispatch function stored in CONTEXT with MODEL-ID and
CONTEXT."
  (funcall (plist-get context :dispatch) model-id context))

(defun ogent-provider--schedule-retry (model-id context attempt)
  "Schedule a backoff retry of MODEL-ID for CONTEXT.
ATTEMPT is the number of retries already performed against
MODEL-ID."
  (run-at-time (ogent-provider-retry-delay attempt model-id) nil
               #'ogent-provider--dispatch model-id
               (ogent-provider--context-put context :attempt (1+ attempt))))

(defun ogent-provider-failover-candidate (context)
  "Return the next registry model plist eligible for failover, or nil.
Eligible models come from `ogent-model-registry' and use a provider
different from the failed model in CONTEXT, from CONTEXT's :backend
when it is a symbol, and from every model listed under CONTEXT's
:tried key."
  (let* ((model-id (ogent-provider--model-id (plist-get context :model)))
         (tried (delq nil (cons model-id
                                (copy-sequence (plist-get context :tried)))))
         (providers (delq nil (mapcar #'ogent-provider--model-provider
                                      tried)))
         (backend (plist-get context :backend)))
    (when (and backend (symbolp backend))
      (push backend providers))
    (seq-find (lambda (entry)
                (let ((id (plist-get entry :id))
                      (provider (plist-get entry :backend)))
                  (and id provider
                       (not (member id tried))
                       (not (memq provider providers)))))
              ogent-model-registry)))

(defun ogent-provider--schedule-failover (candidate context)
  "Schedule re-dispatch of CONTEXT against registry entry CANDIDATE."
  (let ((candidate-id (plist-get candidate :id))
        (failed-id (ogent-provider--model-id (plist-get context :model))))
    (run-at-time 0 nil #'ogent-provider--dispatch candidate-id
                 (ogent-provider--context-put
                  context
                  :model candidate-id
                  :backend (plist-get candidate :backend)
                  :attempt 0
                  :tried (cons failed-id (plist-get context :tried))))))

(defun ogent-provider--finish (context class)
  "Take the terminal fallback action for CONTEXT with error CLASS.
Offer the interactive provider login for `auth' failures in
interactive sessions; otherwise log the failure and stop.  Return
`login-offer' or `give-up'."
  (let ((model (plist-get context :model))
        (backend (plist-get context :backend))
        (error-message (plist-get context :error)))
    (if (and (eq class 'auth)
             ogent-prompt-provider-login-on-access-error
             (not noninteractive))
        (progn
          (ogent-provider-maybe-offer-login model backend error-message)
          'login-offer)
      (message "ogent: request for %s failed with no fallback available: %s"
               (ogent-provider--model-name model)
               (ogent-provider-error-message-string error-message))
      'give-up)))

(defun ogent-provider-handle-error (context)
  "Recover headlessly from the failed model request in CONTEXT.
CONTEXT is a plist with these keys:
  :model    - failed model, a registry id string or model plist.
  :backend  - backend symbol of the failed provider, when known.
  :error    - error message string or object from the failure.
  :dispatch - function of (MODEL-ID CONTEXT) that re-issues the
              original request; when the re-issued request fails the
              caller should call `ogent-provider-handle-error' again
              with that CONTEXT, storing the new failure under
              :error.
  :attempt  - retries already performed against :model, default 0.
  :tried    - list of model ids already attempted.
Classify :error with `ogent-provider-classify-error', then retry
:model with exponential backoff for transient errors, fail over to a
different provider once retries are exhausted or the error is an
auth failure, and finally offer interactive login or give up.  All
scheduling goes through `run-at-time'.  Return the action taken, one
of `retry', `failover', `login-offer', or `give-up'."
  (let* ((error-message (plist-get context :error))
         (dispatch (plist-get context :dispatch))
         (attempt (or (plist-get context :attempt) 0))
         (model-id (ogent-provider--model-id (plist-get context :model)))
         (class (ogent-provider-classify-error error-message)))
    (cond
     ((and (eq class 'transient) dispatch model-id
           (< attempt (ogent-provider-model-max-retries model-id)))
      (ogent-provider--schedule-retry model-id context attempt)
      'retry)
     ((and (memq class '(transient auth)) dispatch)
      (let ((candidate (ogent-provider-failover-candidate context)))
        (if candidate
            (progn
              (ogent-provider--schedule-failover candidate context)
              'failover)
          (ogent-provider--finish context class))))
     (t (ogent-provider--finish context class)))))

(provide 'ogent-provider-fallback)

;;; ogent-provider-fallback.el ends here
