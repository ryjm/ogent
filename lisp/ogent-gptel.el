;;; ogent-gptel.el --- Shared gptel helpers for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Small helpers for resolving ogent model registry entries into gptel
;; runtime bindings.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(declare-function gptel--model-name "ext:gptel-request")
(declare-function gptel-backend-models "ext:gptel-request" t t)

(defvar gptel--known-backends)
(defvar gptel-backend)
(defvar gptel-tools)
(defvar gptel-use-tools)
(defvar gptel-model)
(defvar gptel--request-params)
(defvar gptel-org-convert-response)
(defvar ogent-tools-project-root)
(declare-function gptel-tool-function "ext:gptel-request" t t)
(declare-function gptel--fsm-transition "ext:gptel-request")
(declare-function gptel-abort "ext:gptel-request")
(defvar gptel--request-alist)

(defun ogent-gptel-cancel (handle buffer)
  "Cancel HANDLE and verify its transport is gone, using BUFFER as fallback.
Target the request's own FSM so cancellation cannot abort a fan-out sibling."
  (if (and handle (boundp 'gptel--request-alist))
      (let ((entries (seq-filter (lambda (entry) (eq (cadr entry) handle))
                                 gptel--request-alist)))
        (dolist (entry entries)
          (funcall (cddr entry))
          (setq gptel--request-alist (assq-delete-all (car entry) gptel--request-alist))
          (when (and (processp (car entry)) (process-live-p (car entry)))
            (error "Transport cleanup did not stop the previous attempt")))
        (when (fboundp 'gptel--fsm-transition) (gptel--fsm-transition handle 'ABRT)))
    (when (fboundp 'gptel-abort) (gptel-abort buffer))))
(declare-function gptel-request "ext:gptel-request")
(declare-function gptel-backend-header "ext:gptel-request" t t)
(declare-function gptel-backend-p "ext:gptel-request" t t)
(declare-function ogent-models-get "ogent-models")

(defcustom ogent-gptel-header-timeout 25
  "Maximum seconds allowed for preparing authentication headers.
Prepare headers before starting transport, including on older gptel versions
that start curl before evaluating the header callback."
  :type 'number
  :group 'ogent)

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
  "Gptel model symbol properties copied from a known prototype.")

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

(defun ogent-gptel-tool-request-params (model)
  "Return the `gptel--request-params' value MODEL needs for this request.

Some models reject function tools unless extra body parameters ride
along: the OpenAI chat/completions endpoint rejects a gpt-5.6 request
carrying function tools with HTTP 400 unless `reasoning_effort' is
\"none\".  MODEL declares that override in its `:tools-request-params'
registry key, which is merged over its `:request-params'.

Return nil when the pending request carries no tools, so tool-free
requests keep the model's normal reasoning behavior.  Bind the result
to `gptel--request-params' after `gptel-tools' and `gptel-use-tools',
whose live values this reads.  The override is deliberately never
written onto the shared gptel model symbol: it is a per-request
compatibility patch, not user configuration, so a plain `gptel-send'
outside ogent never inherits a silently downgraded reasoning effort."
  (when (and (not (eq (ogent-gptel-endpoint
                       (and (boundp 'gptel-backend) gptel-backend)) 'responses))
             (bound-and-true-p gptel-use-tools)
             (bound-and-true-p gptel-tools))
    (plist-get model :tools-request-params)))

(defun ogent-gptel-backend-matches-provider-p (backend-object provider)
  "Return non-nil when BACKEND-OBJECT has PROVIDER type."
  (and backend-object
       (symbolp provider)
       (or (and (eq provider 'gptel-openai)
                (eq (type-of backend-object) 'gptel-openai-responses))
           (eq (type-of backend-object) provider)
           (ignore-errors (cl-typep backend-object provider)))))

(defun ogent-gptel-endpoint (backend)
  "Return the API endpoint family of BACKEND."
  (cond
   ((eq (type-of backend) 'gptel-openai-responses) 'responses)
   ((ogent-gptel-backend-matches-provider-p backend 'gptel-openai) 'chat)
   ((ogent-gptel-backend-matches-provider-p backend 'gptel-anthropic)
    'messages)))

(defun ogent-gptel-validate-endpoint (model backend)
  "Validate MODEL against BACKEND and the pending tool configuration."
  (let ((endpoint (ogent-gptel-endpoint backend))
        (tools (and gptel-use-tools gptel-tools)))
    (when (and endpoint (plist-member model :endpoints)
               (or (not (memq endpoint (plist-get model :endpoints)))
                   (and tools (plist-get model :tools-endpoints)
                        (not (memq endpoint
                                   (plist-get model :tools-endpoints))))))
      (user-error
       "Model %s%s requires %s; configure a matching gptel backend (update gptel for Responses API)"
       (plist-get model :id) (if tools " with tools" "")
       (or (and tools (plist-get model :tools-endpoints))
           (plist-get model :endpoints))))))

(defun ogent-gptel--prepared-backend (backend)
  "Copy BACKEND with bounded, already evaluated authentication headers."
  (if (not (and (fboundp 'gptel-backend-p) (gptel-backend-p backend)
                (fboundp 'gptel-backend-header)))
      backend
    (let ((copy (copy-sequence backend))
          (header (gptel-backend-header backend)))
      (when (functionp header)
        (setq header
              (with-timeout (ogent-gptel-header-timeout
                             (error "Authentication header preparation timed out"))
                (if (eq (cdr (func-arity header)) 0)
                    (funcall header)
                  (funcall header
                           (list :backend backend :model gptel-model
                                 :buffer (current-buffer)))))))
      (aset copy (cl-struct-slot-offset 'gptel-backend 'header) header)
      copy)))

(defun ogent-gptel-request (prompt &rest args)
  "Send PROMPT with ARGS after validating the effective gptel configuration.
Validate after presets have bound their backend, model and tools.  Evaluate
headers before gptel can spawn a transport child."
  (let ((model (and (fboundp 'ogent-models-get)
                    (ogent-models-get
                     (ogent-gptel-model-display-name
                      (and (boundp 'gptel-model) gptel-model))))))
    (when model
      (ogent-gptel-validate-endpoint model (and (boundp 'gptel-backend) gptel-backend))
      (when (and (fboundp 'gptel-backend-p) (gptel-backend-p gptel-backend))
        (ogent-gptel-ensure-model-on-backend model gptel-backend)))
    (let* ((overrides (and model (ogent-gptel-tool-request-params model)))
           (gptel-org-convert-response nil)
           (gptel-backend (ogent-gptel--prepared-backend
                           (and (boundp 'gptel-backend) gptel-backend)))
           (gptel-tools (ogent-gptel--workspace-tools
                         (and (boundp 'gptel-tools) gptel-tools)))
           (gptel--request-params
            (ogent-gptel--merge-params
             (and (boundp 'gptel--request-params) gptel--request-params) overrides))
           ;; Model parameters take precedence in gptel.  Use a private symbol
           ;; with the same wire name so compatibility never alters user props.
           (gptel-model
            (if (and overrides (fboundp 'gptel-backend-p)
                     (gptel-backend-p gptel-backend))
		(let* ((symbol (intern (plist-get model :id)))
                       (copy (make-symbol (symbol-name symbol))))
                  (setplist copy (copy-tree (symbol-plist symbol)))
                  (put copy :request-params
                       (ogent-gptel--merge-params (get copy :request-params) overrides))
                  (ogent-gptel--set-backend-models
                   gptel-backend (cons copy (gptel-backend-models gptel-backend)))
                  copy)
              (and (boundp 'gptel-model) gptel-model))))
      (apply #'gptel-request prompt args))))

(defun ogent-gptel--merge-params (params overrides)
  "Copy PARAMS and merge OVERRIDES with compatibility values taking precedence."
  (let ((result (copy-tree params)))
    (while overrides
      (let ((key (pop overrides)))
        (setq result (plist-put result key (pop overrides)))))
    result))

(defun ogent-gptel--workspace-tools (tools)
  "Copy TOOLS with their execution bound to the request's workspace."
  (let ((root (or (and (boundp 'ogent-tools-project-root) ogent-tools-project-root)
                  default-directory)))
    (mapcar
     (lambda (tool)
       (if (not (and (fboundp 'gptel-tool-function)
                     (ignore-errors (gptel-tool-function tool))))
           tool
         (let ((copy (copy-sequence tool))
               (function (gptel-tool-function tool)))
           (aset copy (cl-struct-slot-offset 'gptel-tool 'function)
                 (lambda (&rest values)
                   (let ((ogent-tools-project-root root)
                         (default-directory root))
                     (apply function values))))
           copy)))
     tools)))

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
