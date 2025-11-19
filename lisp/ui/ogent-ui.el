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

(defcustom ogent-context-preview-buffer-name "*ogent-context*"
  "Buffer used to display the context summary."
  :type 'string
  :group 'ogent-mode)

(defcustom ogent-response-function #'ogent-ui-insert-response-block
  "Function responsible for materializing a response block.
Receives PROMPT, CONTEXT plist, and MODELS list."
  :type 'function
  :group 'ogent-mode)

(defvar ogent-ui--selected-models nil
  "Models toggled inside the dispatch transient.")

(defun ogent-ui--current-models ()
  "Return the list of currently selected models, falling back to defaults."
  (or (cl-remove-duplicates ogent-ui--selected-models :test #'string=)
      (list ogent-default-model)))

(defun ogent-ui--toggle-model (model)
  "Toggle MODEL membership in `ogent-ui--selected-models'."
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

(defun ogent-ui-toggle-gpt-4o-mini ()
  "Toggle the gpt-4o-mini model in the dispatcher."
  (interactive)
  (ogent-ui--toggle-model "gpt-4o-mini"))

(defun ogent-ui-toggle-gpt-4o ()
  "Toggle the gpt-4o model in the dispatcher."
  (interactive)
  (ogent-ui--toggle-model "gpt-4o"))

(defun ogent-ui-toggle-claude-35 ()
  "Toggle the claude-3.5 model in the dispatcher."
  (interactive)
  (ogent-ui--toggle-model "claude-3.5"))

;;;###autoload
(transient-define-prefix ogent-prompt-dispatch ()
  "Prompt dispatcher for ogent requests."
  ["Models"
   ("1" "gpt-4o-mini" ogent-ui-toggle-gpt-4o-mini)
   ("2" "gpt-4o" ogent-ui-toggle-gpt-4o)
   ("3" "claude-3.5" ogent-ui-toggle-claude-35)]
  ["Actions"
   ("c" "Preview context" ogent-context-preview)
   ("m" "Codemap" ogent-codemap-buffer)
   ("RET" "Send request" ogent-request)])

(defun ogent-ui--request-payload (prompt models)
  "Build the block content for PROMPT and MODELS."
  (let ((context (ogent-context-build)))
    (funcall ogent-response-function prompt context models)
    (run-hook-with-args 'ogent-after-request-hook context)))

;;;###autoload
(defun ogent-request (&optional prompt models)
  "Build context for the current subtree and insert a response block.
When PROMPT or MODELS are nil, prompt the user / use defaults."
  (interactive)
  (let* ((prompt (or prompt (ogent-ui--read-prompt)))
         (models (or models (ogent-ui--current-models))))
    (ogent-ui--request-payload prompt models)))

(provide 'ogent-ui)

;;; ogent-ui.el ends here
