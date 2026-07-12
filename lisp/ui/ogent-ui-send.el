;;; ogent-ui-send.el --- Request build and gptel dispatch -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds the effective prompt and companion context, applies prompt
;; templates and preset cookies, resolves the gptel backend, and
;; dispatches a request into the conversation engine.  Hosts the
;; `ogent-request' command.

;;; Code:

(require 'ogent-ui-core)
(require 'ogent-ui-engine)
(require 'ogent-context)
(require 'ogent-models)
(require 'ogent-gptel)
(require 'ogent-companion)
(require 'ogent-prompts)

;; gptel dynamic variables let-bound while dispatching a request.
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-cache)
(defvar gptel-stream)
(defvar gptel-tools)
(defvar gptel-use-tools)

;; gptel integration (soft dependency).
(declare-function gptel-request "ext:gptel-request")
(declare-function gptel-backend-p "ext:gptel-request" t t)
(declare-function gptel--model-name "ext:gptel-request")
(declare-function gptel-with-preset "ext:gptel" t t)
(declare-function ogent-gptel-ensure-model-on-backend "ogent-gptel" (model backend))
(declare-function ogent-anthropic-oauth-using-bearer-p "ogent-anthropic-oauth")
(declare-function ogent-tools-enabled-list "ogent-models")
(declare-function ogent-presets-available "ogent-models")
(declare-function ogent-prompt-compose-with-params "ogent-prompts")

(defun ogent--get-effective-prompt ()
  "Get the prompt to send: transient input, region, or minibuffer."
  (or ogent--transient-prompt
      (when (use-region-p)
        (buffer-substring-no-properties (region-beginning) (region-end)))
      (read-string "Prompt: ")))

(defun ogent-ui--apply-prompt-templates (prompt &optional templates)
  "Apply TEMPLATES to PROMPT, returning the combined string."
  (let ((templates (or templates ogent-ui--selected-templates)))
    (if (and templates (fboundp 'ogent-prompt-compose-with-params))
        (let ((template-text (ogent-prompt-compose-with-params templates)))
          (if (string-empty-p template-text)
              prompt
            (string-join (list template-text prompt) "\n\n")))
      prompt)))

(defun ogent-ui--model-id-or-default (&optional model-id)
  "Return registered MODEL-ID, or the effective model id at point.
Resolution follows `ogent-models-effective': an inherited
`OGENT_MODEL' Org property, then the buffer's registered gptel
model, then the project model, then `ogent-default-model'.  This
keeps buffer-local gptel state from breaking ogent when a buffer
remembers a model that is not in `ogent-model-registry'."
  (if (and model-id (ogent-models-get model-id))
      model-id
    (ogent-models-effective-id)))

(defun ogent--send-with-current-model (prompt)
  "Send PROMPT using current gptel-backend and gptel-model.
Captures source buffer context and sends to companion without switching focus.
When `ogent-ui--selected-models' is non-nil, dispatches to all selected models
concurrently (fan-out mode)."
  (let* ((source-buffer (current-buffer))
         (region-start (when (use-region-p) (region-beginning)))
         (region-end (when (use-region-p) (region-end)))
         (companion (ogent-ui--ensure-companion-context))
         (extracted (ogent-ui--extract-preset-cookies prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or (car cookie-presets) ogent-ui--selected-preset))
         (final-prompt (ogent-ui--apply-prompt-templates clean-prompt)))
    (with-current-buffer companion
      (let ((context (ogent-context-build-with-source
                      source-buffer region-start region-end)))
        (if (ogent-validate-and-prompt context)
            (if ogent-ui--selected-models
                ;; Multi-model fan-out: dispatch to all selected models
                (dolist (model-id ogent-ui--selected-models)
                  (let* ((model (ogent-models-ensure model-id))
                         (request (funcall ogent-response-function final-prompt context model)))
                    (unless (ogent-ui-request-p request)
                      (user-error "Function `ogent-response-function' must return an `ogent-ui-request'"))
                    (setf (ogent-ui-request-preset request) effective-preset)
                    (setf (ogent-ui-request-source-buffer request) source-buffer)
                    (ogent-ui--send-request request)))
              ;; Single model: resolve the effective model at point
              ;; (Org property > session > project > default).
              (let* ((model (ogent-models-ensure (ogent-ui--model-id-or-default)))
                     (request (funcall ogent-response-function final-prompt context model)))
                (unless (ogent-ui-request-p request)
                  (user-error "Function `ogent-response-function' must return an `ogent-ui-request'"))
                (setf (ogent-ui-request-preset request) effective-preset)
                (setf (ogent-ui-request-source-buffer request) source-buffer)
                (ogent-ui--send-request request)))
          (message "Ogent request canceled"))))))

(defun ogent-ui--ensure-companion-context ()
  "Ensure we're in an Org buffer, creating a companion if needed.
When invoked from a non-Org buffer, get or create the companion Org
buffer and display it as a popup/side window.  Returns the companion
\(or current) Org buffer.
The original window remains selected - companion is shown but not focused."
  (if (derived-mode-p 'org-mode)
      (current-buffer)
    (let ((original-window (selected-window))
          (companion (ogent-companion-get-or-create)))
      ;; Display the companion buffer as a popup or side window
      (unless (get-buffer-window companion)
        (ogent-companion-display-buffer companion))
      ;; Ensure we stay in the original window
      (when (window-live-p original-window)
        (select-window original-window))
      companion)))

(defun ogent-ui--read-prompt ()
  "Derive the prompt from the region or minibuffer."
  (if (use-region-p)
      (string-trim (buffer-substring-no-properties (region-beginning)
                                                   (region-end)))
    (read-string "Prompt: ")))

(defun ogent-ui--ensure-gptel ()
  "Signal a user error if gptel is unavailable."
  (unless (require 'gptel nil 'noerror)
    (user-error "Gptel is required for ogent requests.  Install gptel first"))
  (dolist (feature ogent-gptel-required-features)
    (unless (require feature nil 'noerror)
      (display-warning
       'ogent
       (format
        (concat "Could not load `%s'. Add the backend feature to your load path "
                "or update `ogent-gptel-required-features'.")
        feature)
       :warning)))
  t)

(defun ogent-ui--backend-matches-provider-p (backend-object provider)
  "Return non-nil when BACKEND-OBJECT has PROVIDER type."
  (ogent-gptel-backend-matches-provider-p backend-object provider))

(defun ogent-ui--resolve-backend (model)
  "Return the backend object for MODEL plist."
  (ogent-gptel-resolve-backend model))

(defun ogent-ui--extract-preset-cookies (prompt)
  "Extract @preset tokens from PROMPT.
Returns a cons (CLEANED-PROMPT . PRESETS) where PRESETS is a list of
preset name strings found in the prompt."
  (let ((presets nil)
        (available (ogent-presets-available))
        (cleaned prompt))
    (when available
      (dolist (name available)
        (let ((pattern (concat "\\s-*@" (regexp-quote name) "\\b\\s-*")))
          (when (string-match (concat "@" (regexp-quote name) "\\b") cleaned)
            (push name presets)
            (setq cleaned (replace-regexp-in-string pattern " " cleaned))))))
    (cons (string-trim cleaned) (nreverse presets))))

(defun ogent-ui--send-request (request)
  "Send REQUEST to the LLM via gptel.
When target buffer is Org-mode, includes org-format directive.
When model has :tools, enables gptel tool calling.
When `ogent-multi-turn-history' is non-nil, prior completed exchanges
found in the transcript buffer are replayed as leading conversation
turns, compacted to `ogent-multi-turn-token-budget'."
  (ogent-ui--ensure-gptel)
  (let* ((model (ogent-ui-request-model request))
         (prompt-text (ogent-ui--render-prompt (ogent-ui-request-prompt request)
                                               (ogent-ui-request-context request)))
         (callback (ogent-ui--make-callback (ogent-ui-request-id request)))
         (backend (ogent-ui--resolve-backend model))
         (model-id (plist-get model :id))
         (preset (or (ogent-ui-request-preset request)
                     (plist-get model :preset)))
         (target-buffer (ogent-ui-request-buffer request))
         (use-org-format (with-current-buffer target-buffer
                           (derived-mode-p 'org-mode)))
         ;; Check if OAuth is active (system message is locked)
         (oauth-active (and (fboundp 'ogent-anthropic-oauth-using-bearer-p)
                            (ogent-anthropic-oauth-using-bearer-p)))
         ;; Get enabled tools based on ogent-tools-enabled
         (tools (when (fboundp 'ogent-tools-enabled-list)
                  (ogent-tools-enabled-list)))
         ;; Prior exchanges replayed as conversation turns (oldest first)
         (history (when ogent-multi-turn-history
                    (ogent-ui--compact-history
                     (ogent-ui--conversation-history
                      target-buffer
                      (or (ogent-ui-request-request-heading-pos request)
                          (ogent-ui-request-block-start request)
                          (ogent-ui-request-marker request))
                      model-id)
                     ogent-multi-turn-token-budget)))
         (args (list :buffer target-buffer
                     :stream (plist-get model :stream?)
                     :callback callback)))
    ;; Add org-format directive when target is org-mode and enabled
    (when (and ogent-org-format-responses use-org-format)
      (if oauth-active
          ;; OAuth locks the system message, so prepend directive to user prompt
          (setq prompt-text (concat ogent-org-format-directive "\n\n" prompt-text))
        ;; Normal mode: use system message
        (setq args (plist-put args :system ogent-org-format-directive))))
    (condition-case err
        (progn
          (when (and (fboundp 'gptel-backend-p)
                     (not (gptel-backend-p backend)))
            (user-error
             "Backend %S for model %s is not loaded.  Require the backend module or update `ogent-model-registry'"
             (plist-get model :backend) model-id))
          ;; Surface the ogent registry to gptel before `gptel--sanitize-model'
          ;; can silently rewrite a newer model id to the backend fallback.
          (ogent-gptel-ensure-model-on-backend model backend)
          (ogent-models-apply-gptel-props model)
          (let* ((sender (lambda ()
                           (apply #'gptel-request
                                  (if history
                                      (append history (list prompt-text))
                                    prompt-text)
                                  args)))
                 (gptel-backend backend)
                 (gptel-model model-id)
                 (gptel-cache ogent-gptel-cache)
                 ;; Bind all registered tools
                 (gptel-tools (or tools gptel-tools))
                 (gptel-use-tools (when tools t))
                 (handle (if preset
                             (if (fboundp 'gptel-with-preset)
                                 (gptel-with-preset
                                  (if (stringp preset) (intern preset) preset)
                                  (funcall sender))
                               (funcall sender))
                           (funcall sender))))
            (setf (ogent-ui-request-gptel-handle request) handle)))
      (error
       (ogent-ui--close-response request (error-message-string err))))))

(defun ogent-ui--dispatch-request
    (source-buffer region-start region-end raw-prompt models preset templates
                   &optional org-point context-transform)
  "Dispatch RAW-PROMPT using MODELS from SOURCE-BUFFER.
REGION-START and REGION-END bound the active region in SOURCE-BUFFER.
PRESET and TEMPLATES shape the request, ORG-POINT anchors the transcript
heading, and CONTEXT-TRANSFORM, when non-nil, post-processes the context."
  (let* ((companion (ogent-ui--ensure-companion-context))
         (extracted (ogent-ui--extract-preset-cookies raw-prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or preset
                               (car cookie-presets)
                               ogent-ui--selected-preset))
         (final-prompt (ogent-ui--apply-prompt-templates
                        clean-prompt
                        (or templates ogent-ui--selected-templates))))
    (with-current-buffer companion
      ;; Anchor the transcript at the requested heading: Zen runs may be
      ;; invoked with point deep inside a generated transcript, and the
      ;; response skeleton must attach to the user bullet, not to point.
      (when (and org-point (eq companion source-buffer))
        (goto-char org-point))
      (let* ((context (ogent-context-build-with-source
                       source-buffer region-start region-end org-point))
             (context (if context-transform
                          (funcall context-transform context)
                        context))
             ;; Use provided models or fall back to a registered/default ogent model.
             (model-ids (or models
                            (list (ogent-ui--model-id-or-default))))
             last-request)
        (if (ogent-validate-and-prompt context)
            (progn
              (dolist (model-id model-ids)
                (let* ((model (ogent-models-ensure model-id))
                       (request (funcall ogent-response-function
                                         final-prompt context model)))
                  (unless (ogent-ui-request-p request)
                    (user-error "Function `ogent-response-function' must return an `ogent-ui-request'"))
                  (setf (ogent-ui-request-preset request) effective-preset)
                  (setf (ogent-ui-request-source-buffer request) source-buffer)
                  (ogent-ui--send-request request)
                  (setq last-request request)))
              ;; Position cursor at response heading in companion window.
              (when-let* ((response-pos (and last-request
                                             (ogent-ui-request-response-pos
                                              last-request)))
                          (win (get-buffer-window companion)))
                (with-selected-window win
                  (goto-char response-pos))))
          (message "Ogent request canceled"))))))

(defun ogent-request (&optional prompt models preset templates)
  "Dispatch PROMPT for the current subtree using MODELS via gptel.
When PROMPT or MODELS are nil, prompt the user and fall back to the
selected models from the dispatcher.
PRESET overrides any dispatcher or model preset.  If PROMPT contains
@preset cookies, they are extracted and applied (first cookie wins).
TEMPLATES is an optional list of prompt template IDs to apply.

When invoked from a non-Org buffer, automatically creates and displays
a companion Org buffer to hold the request/response transcript.
The source buffer content is captured for context."
  (interactive)
  (let ((source-buffer (current-buffer))
        (region-start (when (use-region-p) (region-beginning)))
        (region-end (when (use-region-p) (region-end)))
        (raw-prompt (or prompt (ogent-ui--read-prompt))))
    (ogent-ui--dispatch-request source-buffer region-start region-end
                                raw-prompt models preset templates)))

(provide 'ogent-ui-send)
;;; ogent-ui-send.el ends here
