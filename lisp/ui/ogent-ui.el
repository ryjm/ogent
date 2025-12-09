;;; ogent-ui.el --- UI commands for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides prompt dispatch, request handling, and context previews.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'transient)
(require 'ogent-context)
(require 'ogent-core)
(require 'ogent-codemap)
(require 'ogent-models)
(require 'ogent-companion)

;; Silence byte-compiler for functions that may not be loaded at compile time
(declare-function ogent-presets-available "ogent-models")
(declare-function ogent-preset-get "ogent-models")

;; gptel integration
(declare-function gptel-backend-name "ext:gptel")
(declare-function gptel-backend-models "ext:gptel")
(declare-function gptel--model-name "ext:gptel")
(defvar gptel--known-backends)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-stream)

;;; gptel-style Variable Scope Management

(defvar-local ogent--set-buffer-locally nil
  "When non-nil, set model parameters buffer-locally.")

(defun ogent--set-with-scope (sym value &optional scope)
  "Set SYM to VALUE, buffer-locally if SCOPE is non-nil."
  (if scope
      (set (make-local-variable sym) value)
    (kill-local-variable sym)
    (set sym value)))

;;; Provider/Model Selection Infix

(defclass ogent-provider-variable (transient-lisp-variable)
  ((model       :initarg :model)
   (model-value :initarg :model-value)
   (always-read :initform t)
   (set-value   :initarg :set-value :initform #'set))
  "Transient variable class for selecting gptel backend and model.")

(cl-defmethod transient-init-value ((obj ogent-provider-variable))
  "Initialize OBJ's value from gptel-backend."
  (oset obj value gptel-backend)
  (oset obj model-value gptel-model))

(cl-defmethod transient-format-value ((obj ogent-provider-variable))
  "Format the current backend:model selection for display."
  (let ((backend (oref obj value))
        (model (oref obj model-value)))
    (if (and backend model)
        (propertize (format "%s:%s"
                            (if (fboundp 'gptel-backend-name)
                                (gptel-backend-name backend)
                              "backend")
                            (if (fboundp 'gptel--model-name)
                                (gptel--model-name model)
                              model))
                    'face 'transient-value)
      (propertize "not configured" 'face 'transient-inactive-value))))

(cl-defmethod transient-infix-set ((obj ogent-provider-variable) value)
  "Set backend and model from VALUE, which should be (backend . model)."
  (pcase-let ((`(,backend ,model) value))
    (oset obj value backend)
    (oset obj model-value model)
    (funcall (oref obj set-value) 'gptel-backend backend ogent--set-buffer-locally)
    (funcall (oref obj set-value) 'gptel-model model ogent--set-buffer-locally)))

(defun ogent--read-provider (prompt &rest _)
  "Read provider:model using completing-read.
PROMPT is the completion prompt."
  (unless (boundp 'gptel--known-backends)
    (require 'gptel nil t))
  (let ((models-alist
         (cl-loop for (name . backend) in gptel--known-backends
                  nconc (cl-loop for model in (gptel-backend-models backend)
                                 for model-name = (gptel--model-name model)
                                 collect (list (concat name ":" model-name)
                                               backend model)))))
    (if models-alist
        (cdr (assoc (completing-read prompt models-alist nil t) models-alist))
      (user-error "No gptel backends configured. Run gptel-make-* first"))))

(transient-define-infix ogent--infix-provider ()
  "Select LLM provider and model."
  :description "Model"
  :class 'ogent-provider-variable
  :variable 'gptel-backend
  :model 'gptel-model
  :set-value #'ogent--set-with-scope
  :key "m"
  :reader #'ogent--read-provider)

;;; Inline Prompt Infix

(defvar ogent--transient-prompt nil
  "Prompt text set via the transient infix.")

(transient-define-infix ogent--infix-prompt ()
  "Enter a prompt to send."
  :description "Prompt"
  :class 'transient-lisp-variable
  :variable 'ogent--transient-prompt
  :key "p"
  :prompt "Prompt: "
  :reader (lambda (prompt _initial _history)
            (let ((text (read-string prompt)))
              (unless (string-empty-p text) text))))

;;; Direct Send Suffix

(defun ogent--get-effective-prompt ()
  "Get the prompt to send: transient input, region, or minibuffer."
  (or ogent--transient-prompt
      (when (use-region-p)
        (buffer-substring-no-properties (region-beginning) (region-end)))
      (read-string "Prompt: ")))

(defun ogent--send-with-current-model (prompt)
  "Send PROMPT using current gptel-backend and gptel-model."
  (let* ((companion (ogent-ui--ensure-companion-context))
         (extracted (ogent-ui--extract-preset-cookies prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or (car cookie-presets) ogent-ui--selected-preset)))
    (with-current-buffer companion
      (let* ((context (ogent-context-build))
             (model (list :id (if (fboundp 'gptel--model-name)
                                  (gptel--model-name gptel-model)
                                gptel-model)
                          :backend gptel-backend
                          :stream? gptel-stream))
             (request (funcall ogent-response-function clean-prompt context model)))
        (unless (ogent-ui-request-p request)
          (user-error "ogent-response-function must return an `ogent-ui-request'"))
        (setf (ogent-ui-request-preset request) effective-preset)
        (ogent-ui--send-request request)))))

(transient-define-suffix ogent--suffix-send ()
  "Send prompt to LLM."
  :key "RET"
  :description
  (lambda ()
    (concat "Send"
            (cond
             (ogent--transient-prompt
              (format " \"%s\"" (truncate-string-to-width ogent--transient-prompt 20 nil nil "...")))
             ((use-region-p) " (region)")
             (t ""))))
  (interactive)
  (let ((prompt (ogent--get-effective-prompt)))
    (setq ogent--transient-prompt nil)  ; Clear for next time
    (ogent--send-with-current-model prompt)))

(defun ogent-ui--ensure-companion-context ()
  "Ensure we're in an Org buffer, creating a companion if needed.
When invoked from a non-Org buffer, get or create the companion Org buffer
and display it as a popup/side window.  Returns the companion (or current) Org buffer."
  (if (derived-mode-p 'org-mode)
      (current-buffer)
    (let ((companion (ogent-companion-get-or-create)))
      ;; Display the companion buffer as a popup or side window
      (unless (get-buffer-window companion)
        (ogent-companion-display-buffer companion))
      companion)))

(defcustom ogent-context-preview-buffer-name "*ogent-context*"
  "Buffer used to display the context summary."
  :type 'string
  :group 'ogent-mode)

(defun ogent-ui--set-response-function (symbol value)
  "Setter for `ogent-response-function' that migrates legacy values."
  (set-default symbol
               (if (eq value #'ogent-ui-insert-response-block)
                   #'ogent-ui-prepare-response-block
                 value)))

(defcustom ogent-response-function #'ogent-ui-prepare-response-block
  "Function that prepares an `ogent-ui-request' for streaming responses.
The function receives PROMPT text, a CONTEXT plist from
`ogent-context-build', and the MODEL plist drawn from
`ogent-model-registry'.  It must return an `ogent-ui-request'
object that points at the buffer location where streamed output
should be inserted."
  :type 'function
  :set #'ogent-ui--set-response-function
  :group 'ogent-mode)

(cl-defstruct ogent-ui-request
  id model context prompt buffer marker closed preset
  status start-time end-time gptel-handle)

(defvar ogent-ui--selected-preset nil
  "The currently selected preset name (string), or nil for no preset.")

(defvar ogent-ui--request-table (make-hash-table :test #'equal)
  "Active gptel requests keyed by their `ogent-ui-request-id'.")

(defvar ogent-ui--request-history nil
  "List of recently closed requests, most recent first.
Used for retry functionality.")

(defvar ogent-ui--request-seq 0
  "Incrementing counter for request identifiers.")

(defun ogent-ui--format-node (node)
  "Return a human-readable summary line for NODE."
  (when node
    (format "%s (id: %s)"
            (or (ogent-context-node-title node) "<untitled>")
            (ogent-context-node-id node))))

(defun ogent-ui--format-context (context)
  "Format CONTEXT plist as a readable summary string."
  (let* ((root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         (handles (plist-get context :handles))
         (lines (list (format "Root: %s" (ogent-ui--format-node root)))))
    (when ancestors
      (push (format "Ancestors: %s"
                    (string-join
                     (mapcar #'ogent-ui--format-node ancestors)
                     " -> ")) lines))
    (when handles
      (push (format "Handles: %s" (string-join handles ", ")) lines))
    (when dependencies
      (push "Dependencies:" lines)
      (dolist (dep dependencies)
        (push (format "  - %s%s"
                      (plist-get dep :handle)
                      (if (plist-get dep :missing-p)
                          " (missing)"
                        (format " -> %s"
                                (ogent-ui--format-node
                                 (plist-get dep :node)))))
              lines)))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun ogent-ui--context-buffer ()
  "Return the context preview buffer, clearing previous content."
  (let ((buffer (get-buffer-create ogent-context-preview-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)))
    buffer))

(defun ogent-ui--read-prompt ()
  "Derive the prompt from the region or minibuffer."
  (if (use-region-p)
      (string-trim (buffer-substring-no-properties (region-beginning)
                                                   (region-end)))
    (read-string "Prompt: ")))

(defun ogent-ui--insert-src-block (content models)
  "Insert a src block containing CONTENT annotated with MODELS."
  (org-back-to-heading t)
  (org-end-of-subtree t t)
  (unless (bolp) (insert "\n"))
  (let ((model-label (string-join models ", ")))
    (insert (format "#+begin_src text :model %s\n" model-label))
    (insert content)
    (unless (string-suffix-p "\n" content)
      (insert "\n"))
    (insert "#+end_src\n")))

(defun ogent-ui-insert-response-block (prompt context models)
  "Default response function writing PROMPT and CONTEXT to Org."
  (let ((summary (ogent-ui--format-context context)))
    (ogent-ui--insert-src-block
     (format "Prompt:\n%s\n\nContext Summary:\n%s\n"
             prompt summary)
     models)))

;;;###autoload
(defun ogent-context-preview ()
  "Render the current subtree context into a preview buffer.
When invoked from a non-Org buffer, uses the companion Org buffer's context."
  (interactive)
  (let ((companion (ogent-ui--ensure-companion-context)))
    (with-current-buffer companion
      (let* ((context (ogent-context-build))
             (summary (ogent-ui--format-context context))
             (buffer (ogent-ui--context-buffer)))
        (with-current-buffer buffer
          (insert summary)
          (goto-char (point-min)))
        (display-buffer buffer)))))

(defun ogent-ui--backend-label (backend)
  "Return a string label describing BACKEND."
  (cond
   ((symbolp backend) (symbol-name backend))
   ((and (consp backend) (symbolp (car backend))) (symbol-name (car backend)))
   (t "backend")))

(defun ogent--format-model-header ()
  "Format the current model for display in transient header."
  (if (and (boundp 'gptel-backend) gptel-backend
           (boundp 'gptel-model) gptel-model)
      (format "Model: %s:%s"
              (if (fboundp 'gptel-backend-name)
                  (gptel-backend-name gptel-backend)
                "backend")
              (if (fboundp 'gptel--model-name)
                  (gptel--model-name gptel-model)
                gptel-model))
    "Model: not configured"))

;;;###autoload (autoload 'ogent-prompt-dispatch "ogent-ui" nil t)
(transient-define-prefix ogent-prompt-dispatch ()
  "Prompt dispatcher for ogent requests.
Shows current model, allows changing it, and sends prompts to LLM."
  [:description ogent--format-model-header
   ["Options"
    (ogent--infix-provider)
    (ogent--infix-prompt)]
   ["Context"
    ("c" "Preview context" ogent-context-preview :transient t)
    ("C" "Codemap" ogent-codemap-buffer :transient t)]]
  [["Actions"
    (ogent--suffix-send)
    ("q" "Quit" transient-quit-one)]]
  (interactive)
  (ogent-ui--ensure-companion-context)
  (transient-setup 'ogent-prompt-dispatch))

(declare-function gptel-request "ext:gptel-request" (prompt &rest args))

(defcustom ogent-gptel-required-features '(gptel-openai gptel-anthropic)
  "Features that must be loaded so gptel backends can service requests.
Every symbol should name the feature provided by the corresponding
`gptel-*' backend file (for example `gptel-openai').  Extend this list
whenever `ogent-model-registry' gains a new provider so backend structs
exist before `ogent-request' dispatches."
  :type '(repeat symbol)
  :group 'ogent-mode)

(defun ogent-ui--ensure-gptel ()
  "Signal a user error if gptel is unavailable."
  (unless (require 'gptel nil 'noerror)
    (user-error "gptel is required for ogent requests. Install gptel first"))
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

(defun ogent-ui--next-request-id ()
  "Return a fresh request identifier."
  (setq ogent-ui--request-seq (1+ ogent-ui--request-seq))
  (format "ogent-request-%d" ogent-ui--request-seq))

(defun ogent-ui--create-response-block (prompt context model)
  "Insert a placeholder src block for MODEL using PROMPT and CONTEXT.
Returns a plist containing a streaming marker."
  (org-back-to-heading t)
  (org-end-of-subtree t t)
  (unless (bolp) (insert "\n"))
  (let* ((model-id (plist-get model :id))
         (backend (plist-get model :backend))
         (summary (ogent-ui--format-context context)))
    (insert (format "#+begin_src text :model %s%s\n"
                    model-id
                    (if backend
                        (format " :backend %s" (ogent-ui--backend-label backend))
                      "")))
    (insert (format "Prompt:\n%s\n\nContext Summary:\n%s\n\nResponse:\n"
                    prompt summary))
    (let ((marker (copy-marker (point) t)))
      (list :marker marker))))

(defun ogent-ui-register-request (request)
  "Register REQUEST in the active request table."
  (setf (ogent-ui-request-start-time request) (current-time))
  (setf (ogent-ui-request-status request) 'wait)
  (puthash (ogent-ui-request-id request) request ogent-ui--request-table)
  request)

(defun ogent-ui-prepare-response-block (prompt context model)
  "Default `ogent-response-function' implementation.
Creates an `ogent-ui-request' struct and registers it for streaming."
  (let* ((block (ogent-ui--create-response-block prompt context model))
         (request (make-ogent-ui-request
                   :id (ogent-ui--next-request-id)
                   :model model
                   :context context
                   :prompt prompt
                   :buffer (current-buffer)
                   :marker (plist-get block :marker))))
    (ogent-ui-register-request request)))

(when (and (boundp 'ogent-response-function)
           (eq ogent-response-function #'ogent-ui-insert-response-block))
  (setq ogent-response-function #'ogent-ui-prepare-response-block))

(defun ogent-ui--append-response (request chunk)
  "Append CHUNK to REQUEST's response block."
  (when (and chunk (> (length chunk) 0))
    (let ((marker (ogent-ui-request-marker request)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (save-excursion
            (goto-char marker)
            (insert chunk)
            (set-marker marker (point))))))))

(defun ogent-ui--insert-error-block (request message)
  "Insert an error block for REQUEST containing MESSAGE."
  (let ((marker (ogent-ui-request-marker request)))
    (when (and marker (marker-buffer marker))
      (with-current-buffer (ogent-ui-request-buffer request)
        (save-excursion
          (goto-char marker)
          (insert (format "\n#+begin_quote ogent-error\n%s\n#+end_quote\n" message))
          (set-marker marker (point)))))))

(defun ogent-ui--update-status (request new-status)
  "Update REQUEST status to NEW-STATUS and refresh block metadata."
  (setf (ogent-ui-request-status request) new-status)
  (when (eq new-status 'done)
    (setf (ogent-ui-request-end-time request) (current-time)))
  (ogent-ui--update-block-header request))

(defun ogent-ui--format-latency (request)
  "Return a formatted latency string for REQUEST, or nil if incomplete."
  (when-let* ((start (ogent-ui-request-start-time request))
              (end (ogent-ui-request-end-time request)))
    (format "%.1fs" (float-time (time-subtract end start)))))

(defun ogent-ui--update-block-header (request)
  "Update the src block header with current status and timing for REQUEST."
  (let ((marker (ogent-ui-request-marker request))
        (model (ogent-ui-request-model request))
        (status (ogent-ui-request-status request)))
    (when (and marker (marker-buffer marker))
      (with-current-buffer (ogent-ui-request-buffer request)
        (save-excursion
          (goto-char marker)
          (when (re-search-backward "^#\\+begin_src text :model \\([^ \n]+\\)" nil t)
            (let* ((model-id (plist-get model :id))
                   (backend (plist-get model :backend))
                   (latency (ogent-ui--format-latency request))
                   (status-str (pcase status
                                 ('wait "waiting")
                                 ('type "typing")
                                 ('done "done")
                                 ('error "error")
                                 (_ nil)))
                   (new-header (concat "#+begin_src text :model " model-id
                                       (when backend
                                         (format " :backend %s"
                                                 (ogent-ui--backend-label backend)))
                                       (when status-str
                                         (format " :status %s" status-str))
                                       (when latency
                                         (format " :latency %s" latency)))))
              (replace-match new-header t t))))))))

(defcustom ogent-ui-request-history-max 20
  "Maximum number of closed requests to keep in history."
  :type 'integer
  :group 'ogent-mode)

(defun ogent-ui--close-response (request &optional error-message)
  "Finalize REQUEST, optionally including ERROR-MESSAGE."
  (when error-message
    (ogent-ui--insert-error-block request error-message)
    (ogent-ui--update-status request 'error))
  (unless (ogent-ui-request-closed request)
    (unless error-message
      (ogent-ui--update-status request 'done))
    (let ((marker (ogent-ui-request-marker request)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (save-excursion
            (goto-char marker)
            (unless (bolp) (insert "\n"))
            (insert "#+end_src\n")
            (set-marker marker (point))))))
    (setf (ogent-ui-request-closed request) t)
    ;; Save to history for retry
    (push request ogent-ui--request-history)
    (when (> (length ogent-ui--request-history) ogent-ui-request-history-max)
      (setq ogent-ui--request-history
            (seq-take ogent-ui--request-history ogent-ui-request-history-max))))
  (remhash (ogent-ui-request-id request) ogent-ui--request-table)
  (run-hook-with-args 'ogent-after-request-hook (ogent-ui-request-context request)))

(defun ogent-ui--make-callback (request-id)
  "Return a gptel callback that streams into REQUEST-ID."
  (lambda (text info)
    (let ((request (gethash request-id ogent-ui--request-table)))
      (when request
        ;; Update status based on what we're receiving
        (when (and text (> (length text) 0))
          (unless (eq (ogent-ui-request-status request) 'type)
            (ogent-ui--update-status request 'type)))
        (ogent-ui--append-response request text)
        (cond
         ((and (listp info) (plist-get info :error))
          (ogent-ui--close-response request (plist-get info :error)))
         ;; Done when we get explicit :done/:final or nil info with no text
         ((or (and (listp info)
                   (or (plist-get info :done)
                       (plist-get info :final)))
              (and (null info) (null text)))
          (ogent-ui--close-response request)))))))

(defun ogent-ui--resolve-backend (model)
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
              backend))
           (t backend)))
    backend))

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

(defun ogent-ui--render-prompt (prompt context)
  "Render PROMPT and CONTEXT into the final text sent to gptel."
  (let* ((root (plist-get context :root))
         (content (when root (ogent-context-node-content root)))
         (segments (delq nil
                         (list (format "Prompt:\n%s" prompt)
                               (format "Org Context:\n%s"
                                       (ogent-ui--format-context context))
                               (when (and content (not (string-empty-p content)))
                                 (format "Subtree Content:\n%s" content))))))
    (string-join segments "\n\n")))

(defun ogent-ui--send-request (request)
  "Dispatch REQUEST through gptel.
Preset priority: request preset > model preset."
  (ogent-ui--ensure-gptel)
  (let* ((model (ogent-ui-request-model request))
         (prompt-text (ogent-ui--render-prompt (ogent-ui-request-prompt request)
                                               (ogent-ui-request-context request)))
         (callback (ogent-ui--make-callback (ogent-ui-request-id request)))
         (backend (ogent-ui--resolve-backend model))
         (model-id (plist-get model :id))
         (preset (or (ogent-ui-request-preset request)
                     (plist-get model :preset)))
         (args (list :buffer (ogent-ui-request-buffer request)
                     :stream (plist-get model :stream?)
                     :callback callback)))
    (when (and (fboundp 'gptel-backend-p)
               (not (gptel-backend-p backend)))
      (user-error
       "Backend %S for model %s is not loaded. Require the backend module or update `ogent-model-registry'."
       (plist-get model :backend) model-id))
    (condition-case err
        (let* ((sender (lambda () (apply #'gptel-request prompt-text args)))
               (gptel-backend backend)
               (gptel-model model-id)
               (handle (if preset
                           (if (fboundp 'gptel-with-preset)
                               (gptel-with-preset (if (stringp preset) (intern preset) preset)
                                 (funcall sender))
                             (funcall sender))
                         (funcall sender))))
          (setf (ogent-ui-request-gptel-handle request) handle))
      (error
       (ogent-ui--close-response request (error-message-string err))))))

;;;###autoload
(defun ogent-request (&optional prompt models preset)
  "Dispatch PROMPT for the current subtree using MODELS via gptel.
When PROMPT or MODELS are nil, prompt the user and fall back to the
selected models from the dispatcher.
PRESET overrides any dispatcher or model preset.  If PROMPT contains
@preset cookies, they are extracted and applied (first cookie wins).

When invoked from a non-Org buffer, automatically creates and displays
a companion Org buffer to hold the request/response transcript."
  (interactive)
  (let* ((companion (ogent-ui--ensure-companion-context))
         (raw-prompt (or prompt (ogent-ui--read-prompt)))
         (extracted (ogent-ui--extract-preset-cookies raw-prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or preset
                               (car cookie-presets)
                               ogent-ui--selected-preset)))
    (with-current-buffer companion
      (let* ((context (ogent-context-build))
             (model-ids (or models (ogent-ui--current-models))))
        (dolist (model-id model-ids)
          (let* ((model (ogent-models-ensure model-id))
                 (request (funcall ogent-response-function clean-prompt context model)))
            (unless (ogent-ui-request-p request)
              (user-error "ogent-response-function must return an `ogent-ui-request'"))
            (setf (ogent-ui-request-preset request) effective-preset)
            (ogent-ui--send-request request)))))))

;;; Tool and Reasoning Block Support

(defcustom ogent-enable-highlight-mode t
  "When non-nil, enable `gptel-highlight-mode' for response blocks.
This provides visual highlighting for tool calls, reasoning blocks,
and responses marked with gptel text properties."
  :type 'boolean
  :group 'ogent-mode)

(defun ogent-ui--setup-highlight-mode ()
  "Enable gptel-highlight-mode if available and configured."
  (when (and ogent-enable-highlight-mode
             (derived-mode-p 'org-mode)
             (fboundp 'gptel-highlight-mode))
    (gptel-highlight-mode 1)))

(defun ogent-ui--fold-special-block ()
  "Fold the current Org special block if at one."
  (when (and (derived-mode-p 'org-mode)
             (fboundp 'org-cycle))
    (save-excursion
      (when (looking-at "^#\\+begin_\\(tool\\|reasoning\\)")
        (org-cycle)))))

(defun ogent-ui--insert-tool-block (name args result)
  "Insert a tool block with NAME, ARGS, and RESULT.
The block follows gptel's format for Org tool results."
  (let ((marker (point)))
    (insert (format "#+begin_tool %s\n" name))
    (insert (format "Args: %S\n" args))
    (insert "Result:\n")
    (insert (if (stringp result)
                result
              (pp-to-string result)))
    (unless (bolp) (insert "\n"))
    (insert "#+end_tool\n")
    (save-excursion
      (goto-char marker)
      (ogent-ui--fold-special-block))))

(defun ogent-ui--insert-reasoning-block (content)
  "Insert a reasoning block containing CONTENT.
The block follows gptel's format for Org reasoning."
  (let ((marker (point)))
    (insert "#+begin_reasoning\n")
    (insert content)
    (unless (bolp) (insert "\n"))
    (insert "#+end_reasoning\n")
    (save-excursion
      (goto-char marker)
      (ogent-ui--fold-special-block))))

;;; Cancellation and Retry

(defun ogent-ui-active-requests ()
  "Return a list of all active (non-closed) requests."
  (let (requests)
    (maphash (lambda (_id request)
               (unless (ogent-ui-request-closed request)
                 (push request requests)))
             ogent-ui--request-table)
    (nreverse requests)))

(declare-function gptel-abort "ext:gptel" (buffer))

(defun ogent-ui--abort-request (request)
  "Abort REQUEST if it's still active."
  (unless (ogent-ui-request-closed request)
    (let ((handle (ogent-ui-request-gptel-handle request)))
      ;; gptel uses buffer-based abort; try if available
      (when (and handle (fboundp 'gptel-abort))
        (ignore-errors
          (gptel-abort (ogent-ui-request-buffer request)))))
    (ogent-ui--update-status request 'aborted)
    (ogent-ui--close-response request "Request aborted by user")))

;;;###autoload
(defun ogent-abort-request (&optional request-id)
  "Abort the request with REQUEST-ID, or prompt for one if interactive.
When called interactively with a prefix arg, abort all active requests."
  (interactive)
  (if current-prefix-arg
      ;; Abort all
      (let ((requests (ogent-ui-active-requests)))
        (if requests
            (progn
              (dolist (request requests)
                (ogent-ui--abort-request request))
              (message "Aborted %d request(s)" (length requests)))
          (message "No active requests")))
    ;; Abort single request
    (let* ((requests (ogent-ui-active-requests))
           (id (or request-id
                   (when requests
                     (completing-read
                      "Abort request: "
                      (mapcar #'ogent-ui-request-id requests)
                      nil t))))
           (request (and id (gethash id ogent-ui--request-table))))
      (if request
          (progn
            (ogent-ui--abort-request request)
            (message "Aborted request %s" id))
        (message "No request to abort")))))

;;;###autoload
(defun ogent-retry-request (&optional request-id)
  "Retry a failed or completed request with REQUEST-ID.
Re-sends the original prompt with the same model and context."
  (interactive)
  (if ogent-ui--request-history
      (let* ((id (or request-id
                     (completing-read
                      "Retry request: "
                      (mapcar #'ogent-ui-request-id ogent-ui--request-history)
                      nil t)))
             (request (seq-find (lambda (r) (string= (ogent-ui-request-id r) id))
                                ogent-ui--request-history)))
        (when request
          ;; Create a fresh request with the same params
          (ogent-request (ogent-ui-request-prompt request)
                         (list (plist-get (ogent-ui-request-model request) :id))
                         (ogent-ui-request-preset request))
          (message "Retrying request %s" id)))
    (message "No requests in history to retry")))

(provide 'ogent-ui)

;;; ogent-ui.el ends here
