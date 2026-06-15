;;; ogent-gptel.el --- Shared gptel helpers for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Small helpers for resolving ogent model registry entries into gptel
;; runtime bindings.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function gptel--model-name "ext:gptel")
(declare-function gptel-backend-models "ext:gptel" (backend))

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

(defconst ogent-gptel--model-property-keys
  '(:description :capabilities :mime-types :context-window
                 :input-cost :output-cost :cutoff-date)
  "gptel model symbol properties copied from a known prototype.")

(defun ogent-gptel--prototype-model (model-id)
  "Return the closest built-in gptel prototype symbol for MODEL-ID."
  (cond
   ((string-suffix-p "-nano" model-id) 'gpt-5-nano)
   ((string-suffix-p "-mini" model-id) 'gpt-5-mini)
   ((string-prefix-p "gpt-5" model-id) 'gpt-5)
   ((string-prefix-p "gpt-4.1" model-id) 'gpt-4.1)
   (t nil)))

(defun ogent-gptel--copy-missing-model-props (model-id symbol)
  "Copy missing gptel model metadata for MODEL-ID onto SYMBOL."
  (when-let* ((prototype (ogent-gptel--prototype-model model-id))
              (props (symbol-plist prototype)))
    (dolist (key ogent-gptel--model-property-keys)
      (when (and (not (plist-member (symbol-plist symbol) key))
                 (plist-member props key))
        (put symbol key (plist-get props key))))))

(defun ogent-gptel--set-backend-models (backend models)
  "Set BACKEND's advertised model list to MODELS."
  (aset backend (cl-struct-slot-offset 'gptel-backend 'models) models))

(defun ogent-gptel-ensure-model-on-backend (model backend)
  "Ensure MODEL is listed in gptel BACKEND before `gptel-request'.

gptel silently rewrites an unsupported `gptel-model' to the first model in
the backend's model list.  Ogent keeps a newer registry than bundled gptel, so
new model ids must be added to the live backend or transcripts can claim
`gpt-5.5' while the request actually went to the backend fallback."
  (let* ((model-id (plist-get model :id))
         (symbol (intern model-id)))
    (ogent-gptel--copy-missing-model-props model-id symbol)
    (when-let ((description (plist-get model :description)))
      (put symbol :description description))
    (when-let ((models (and (fboundp 'gptel-backend-models)
                            (gptel-backend-models backend))))
      (unless (memq symbol models)
        (ogent-gptel--set-backend-models
         backend (append models (list symbol)))))
    symbol))

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
