;;; ogent-gptel.el --- Shared gptel helpers for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Small helpers for resolving ogent model registry entries into gptel
;; runtime bindings.

;;; Code:

(require 'cl-lib)
(require 'seq)

(declare-function gptel--model-name "ext:gptel")

(defvar gptel--known-backends)
(defvar gptel-backend)

(defcustom ogent-gptel-cache t
  "Value bound to `gptel-cache' for ogent requests.
t caches everything; nil disables caching; a list of the symbols
`message', `system', and `tool' caches only those parts.  Only the
Anthropic backend supports client-controlled prompt caching (and only
for models declaring the `cache' capability, see
`ogent-models-apply-gptel-props'); other backends ignore this.
ogent re-sends a large stable prefix (pinned context, system
directive, tools) on every request, so cache reads typically dominate
the cache-write surcharge."
  :type '(choice (const :tag "Cache everything" t)
                 (const :tag "Disabled" nil)
                 (repeat :tag "Cache only" symbol))
  :group 'ogent)

(defun ogent-gptel-model-display-name (model)
  "Return a display name for MODEL."
  (cond
   ((stringp model) model)
   ((symbolp model) (symbol-name model))
   ((and model (fboundp 'gptel--model-name))
    (or (ignore-errors (gptel--model-name model))
        (format "%s" model)))
   (model (format "%s" model))
   (t "selected model")))

(defun ogent-gptel-backend-matches-provider-p (backend-object provider)
  "Return non-nil when BACKEND-OBJECT has PROVIDER type."
  (and backend-object
       (symbolp provider)
       (or (eq (type-of backend-object) provider)
           (ignore-errors (cl-typep backend-object provider)))))

(defun ogent-gptel-resolve-backend (model)
  "Return the backend object for MODEL plist."
  (let ((backend (plist-get model :backend)))
    (setq backend
          (cond
           ((functionp backend) (funcall backend))
           ((stringp backend)
            (let ((sym (intern (format "gptel-%s" backend))))
              (or (and (boundp sym) (symbol-value sym))
                  (ignore-errors (require sym nil 'noerror))
                  backend)))
           ((symbolp backend)
            (unless (boundp backend)
              (ignore-errors (require backend nil 'noerror)))
            (if (boundp backend)
                (symbol-value backend)
              (or (and (boundp 'gptel-backend)
                       (ogent-gptel-backend-matches-provider-p
                        gptel-backend backend)
                       gptel-backend)
                  (when (boundp 'gptel--known-backends)
                    (cdr (seq-find
                          (lambda (entry)
                            (ogent-gptel-backend-matches-provider-p
                             (cdr entry) backend))
                          gptel--known-backends)))
                  backend)))
           (t backend)))
    backend))

(provide 'ogent-gptel)

;;; ogent-gptel.el ends here
