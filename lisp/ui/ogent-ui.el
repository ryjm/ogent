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
  id model context prompt buffer marker closed)

(defvar ogent-ui--selected-models nil
  "Models toggled inside the dispatch transient.")

(defvar ogent-ui--request-table (make-hash-table :test #'equal)
  "Active gptel requests keyed by their `ogent-ui-request-id'.")

(defvar ogent-ui--request-seq 0
  "Incrementing counter for request identifiers.")

(defvar ogent-ui--prompt-transient nil
  "Symbol naming the dynamically generated prompt dispatcher command.")

(defvar ogent-ui--prompt-transient-counter 0)

(defun ogent-ui--current-models ()
  "Return the list of currently selected models, falling back to defaults."
  (or (cl-remove-duplicates ogent-ui--selected-models :test #'string=)
        (let ((default (ogent-models-default)))
          (when default
            (let ((model-id (plist-get default :id)))
              (setq ogent-ui--selected-models (list model-id))
              ogent-ui--selected-models)))))

(defun ogent-ui--toggle-model (model)
  "Toggle MODEL membership in `ogent-ui--selected-models'."
  (ogent-models-ensure model)
  (if (member model ogent-ui--selected-models)
      (setq ogent-ui--selected-models
            (cl-remove model ogent-ui--selected-models :test #'string=))
    (push model ogent-ui--selected-models))
  (message "Active models: %s"
           (string-join (ogent-ui--current-models) ", ")))

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
  "Render the current subtree context into a preview buffer."
  (interactive)
  (let* ((context (ogent-context-build))
         (summary (ogent-ui--format-context context))
         (buffer (ogent-ui--context-buffer)))
    (with-current-buffer buffer
      (insert summary)
      (goto-char (point-min)))
    (display-buffer buffer)))

(defun ogent-ui--backend-label (backend)
  "Return a string label describing BACKEND."
  (cond
   ((symbolp backend) (symbol-name backend))
   ((and (consp backend) (symbolp (car backend))) (symbol-name (car backend)))
   (t "backend")))

(defun ogent-ui--model-label (model)
  "Return a formatted label for MODEL plist."
  (let ((id (plist-get model :id))
        (backend (plist-get model :backend)))
    (if backend
        (format "%s (%s)" id (ogent-ui--backend-label backend))
      id)))

(defun ogent-ui--build-model-suffixes ()
  "Return transient suffix specs for every registered model."
  (let (suffixes)
    (cl-loop for model in (ogent-models-all)
             for index from 1
             for key = (number-to-string index)
             for id = (plist-get model :id)
             for label = (ogent-ui--model-label model)
             do (push
                 `(,key ,label
                        (lambda ()
                          (interactive)
                          (ogent-ui--toggle-model ,id))
                        :transient t)
                 suffixes))
    (nreverse suffixes)))

(defun ogent-ui--define-prompt-transient ()
  "Internal helper to (re)define the prompt dispatcher."
  (let* ((command (intern (format "ogent-ui--prompt-dispatch-%d"
                                  (cl-incf ogent-ui--prompt-transient-counter))))
         (model-suffixes (ogent-ui--build-model-suffixes)))
    (eval
     `(transient-define-prefix ,command ()
        "Prompt dispatcher for ogent requests."
        ["Models" ,@model-suffixes]
        ["Actions"
         ("c" "Preview context" ogent-context-preview)
         ("m" "Codemap" ogent-codemap-buffer)
         ("RET" "Send request" ogent-request)]))
    (setq ogent-ui--prompt-transient command)))

(defun ogent-ui-refresh-dispatch ()
  "Rebuild the prompt dispatcher after updating the model registry."
  (interactive)
  (ogent-ui--define-prompt-transient))

(ogent-ui-refresh-dispatch)

;;;###autoload
(defun ogent-prompt-dispatch ()
  "Prompt dispatcher for ogent requests."
  (interactive)
  (unless ogent-ui--prompt-transient
    (ogent-ui-refresh-dispatch))
  (call-interactively ogent-ui--prompt-transient))

(declare-function gptel-request "ext:gptel-request" (prompt &rest args))
(defvar gptel-backend nil)
(defvar gptel-model nil)

(defun ogent-ui--ensure-gptel ()
  "Signal a user error if gptel is unavailable."
  (unless (require 'gptel nil 'noerror)
    (user-error "gptel is required for ogent requests. Install gptel first")))

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

(defun ogent-ui--close-response (request &optional error-message)
  "Finalize REQUEST, optionally including ERROR-MESSAGE."
  (when error-message
    (ogent-ui--insert-error-block request error-message))
  (unless (ogent-ui-request-closed request)
    (let ((marker (ogent-ui-request-marker request)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (save-excursion
            (goto-char marker)
            (unless (bolp) (insert "\n"))
            (insert "#+end_src\n")
            (set-marker marker (point))))))
    (setf (ogent-ui-request-closed request) t))
  (remhash (ogent-ui-request-id request) ogent-ui--request-table)
  (run-hook-with-args 'ogent-after-request-hook (ogent-ui-request-context request)))

(defun ogent-ui--make-callback (request-id)
  "Return a gptel callback that streams into REQUEST-ID."
  (lambda (text info)
    (let ((request (gethash request-id ogent-ui--request-table)))
      (when request
        (ogent-ui--append-response request text)
        (cond
         ((and (listp info) (plist-get info :error))
          (ogent-ui--close-response request (plist-get info :error)))
         ((or (null info)
              (and (listp info)
                   (or (plist-get info :done)
                       (plist-get info :final))))
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
  "Dispatch REQUEST through gptel."
  (ogent-ui--ensure-gptel)
  (let* ((model (ogent-ui-request-model request))
         (prompt-text (ogent-ui--render-prompt (ogent-ui-request-prompt request)
                                               (ogent-ui-request-context request)))
         (callback (ogent-ui--make-callback (ogent-ui-request-id request)))
         (backend (ogent-ui--resolve-backend model))
         (model-id (plist-get model :id))
         (args (list :buffer (ogent-ui-request-buffer request)
                     :stream (plist-get model :stream?)
                     :callback callback)))
    (when (and (fboundp 'gptel-backend-p)
               (not (gptel-backend-p backend)))
      (user-error
       "Backend %S for model %s is not loaded. Require the backend module or update `ogent-model-registry'."
       (plist-get model :backend) model-id))
    (condition-case err
        (let ((sender (lambda () (apply #'gptel-request prompt-text args)))
              (gptel-backend backend)
              (gptel-model model-id))
          (if-let ((preset (plist-get model :preset)))
              (if (fboundp 'gptel-with-preset)
                  (gptel-with-preset preset
                    (funcall sender))
                (funcall sender))
            (funcall sender)))
      (error
       (ogent-ui--close-response request (error-message-string err))))))

;;;###autoload
(defun ogent-request (&optional prompt models)
  "Dispatch PROMPT for the current subtree using MODELS via gptel.
When PROMPT or MODELS are nil, prompt the user and fall back to the
selected models from the dispatcher."
  (interactive)
  (let* ((prompt (or prompt (ogent-ui--read-prompt)))
         (context (ogent-context-build))
         (model-ids (or models (ogent-ui--current-models))))
    (dolist (model-id model-ids)
      (let* ((model (ogent-models-ensure model-id))
             (request (funcall ogent-response-function prompt context model)))
        (unless (ogent-ui-request-p request)
          (user-error "ogent-response-function must return an `ogent-ui-request'"))
        (ogent-ui--send-request request)))))

(provide 'ogent-ui)

;;; ogent-ui.el ends here
