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
(require 'ogent-gptel)
(require 'ogent-prompts)
(require 'ogent-companion)
(require 'ogent-tool-effects)
(require 'ogent-tool-approval)
(require 'ogent-ledger)
(require 'ogent-provider-fallback)
(require 'ogent-ui-status)
(require 'ogent-ui-theme)

;; Extracted ogent UI submodules (dependency order).
(require 'ogent-ui-core)
(require 'ogent-ui-format)
(require 'ogent-ui-toolcalls)

;; Forward declarations for source context
(declare-function ogent-context-build-with-source "ogent-context")
(declare-function ogent-context--format-source-context "ogent-context")
(declare-function ogent-context-render-prompt "ogent-context")

;; Forward declarations for Zen presentation
(declare-function ogent-run-subtree "ogent-zen" (&optional models preset templates))
(declare-function ogent-zen-rerun "ogent-zen" ())
(declare-function ogent-zen-run-region
                  "ogent-zen" (question &optional models preset templates))
(declare-function ogent-zen-edit-dwim
                  "ogent-zen" (instruction &optional models preset templates))
(declare-function ogent-zen-apply-last-edit "ogent-zen" ())
(declare-function ogent-zen-refresh "ogent-zen" (&optional begin end))
(declare-function ogent-zen-refresh-at "ogent-zen" (position))
(declare-function ogent-zen-after-insert "ogent-zen" (request-pos))
(declare-function ogent-zen-store-result-title "ogent-zen" (request))
(declare-function ogent-zen-preview-edit-from-request
                  "ogent-zen" (context request-pos))
(declare-function ogent-zen--heading-point "ogent-zen" () t)
(declare-function ogent-zen--context-transform "ogent-zen" (context point) t)
(declare-function ogent-zen--tool-record-active-p "ogent-zen" ())
(declare-function ogent-zen-record-tool-call
                  "ogent-zen" (name args result &optional status context))
(declare-function ogent-zen-tool-record-append "ogent-zen" (record chunk))
(declare-function ogent-zen-tool-record-finish
                  "ogent-zen" (record status &optional detail))
(defvar ogent-zen-tool-calls-inline)
(declare-function org-fold-region "org-fold" (from to flag &optional spec))
(defvar ogent-zen-mode)
(defvar ogent-tools-project-root)
;; cl-defstruct accessors (fileonly: generated, not findable by check-declare)
(declare-function ogent-pinned-item-type "ogent-context" t t)
(declare-function ogent-pinned-item-label "ogent-context" t t)
(declare-function ogent-pinned-item-content "ogent-context")
(declare-function ogent-pinned-context-string "ogent-context")
(declare-function ogent-pin-dwim "ogent-context")
(declare-function ogent-list-pinned "ogent-context")
(declare-function ogent-pinned-count "ogent-context")
(declare-function ogent-edit-display-all "ogent-edit-display")
(declare-function ogent-edit-inline-diff-available-p "ogent-edit-display")
(declare-function ogent-edit--generate-id "ogent-edit-format")
(declare-function make-ogent-edit "ogent-edit-format" t t)
(autoload 'ogent-edit-menu "ogent-edit" nil t)
(autoload 'ogent-ai-speed-edit "ogent-edit" nil t)
(autoload 'ogent-fix-buffer-diagnostics "ogent-edit" nil t)
(autoload 'ogent-fix-diagnostic "ogent-edit" nil t)
(autoload 'ogent-quick-edit "ogent-edit" nil t)
(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-session-save "ogent-session" nil t)
(autoload 'ogent-session-load "ogent-session" nil t)
(autoload 'ogent-session-list "ogent-session" nil t)
(autoload 'ogent-debug-mode "ogent-debug" nil t)
(autoload 'ogent-onboard-login-different-provider "ogent-onboard" nil t)

(declare-function ogent-describe-bindings "ogent-keys")

(defvar ogent-edit-display-method)

;; Silence byte-compiler for functions that may not be loaded at compile time
(declare-function ogent-presets-available "ogent-models")
(declare-function ogent-preset-get "ogent-models")
(declare-function ogent-gptel-ensure-model-on-backend "ogent-gptel" (model backend))
;; gptel integration
(declare-function gptel-backend-name "ext:gptel")
(declare-function gptel-backend-models "ext:gptel")
(declare-function gptel--model-name "ext:gptel")
(declare-function gptel-backend-p "ext:gptel")
(declare-function gptel-tool-name "ext:gptel-request" (tool))
(defvar gptel--known-backends)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-cache)
(defvar gptel-stream)
(defvar gptel-tools)
(defvar gptel-use-tools)

;; OAuth integration - for detecting when system message is locked
(declare-function ogent-anthropic-oauth-using-bearer-p "ogent-anthropic-oauth")

;; ogent-tools integration
(declare-function ogent-tools-enabled-list "ogent-models")
(declare-function ogent-tool-spec-get "ogent-models")
(declare-function ogent-tool--bash-async "ogent-tools")
(declare-function ogent-tools--resolve-path "ogent-tools")
(declare-function ogent-tools--project-root "ogent-tools")

;;; Org-mode Output Formatting








;;; gptel-style Variable Scope Management





;;; Provider/Model Selection Infix

(defclass ogent-provider-variable (transient-lisp-variable)
	  ((model       :initarg :model)
	   (model-value :initarg :model-value)
	   (always-read :initform t)
	   (set-value   :initarg :set-value :initform #'set))
	  "Transient variable class for selecting gptel backend and model.")

(cl-defmethod transient-init-value ((obj ogent-provider-variable))
  "Initialize OBJ's value from gptel-backend."
  (oset obj value (and (boundp 'gptel-backend) gptel-backend))
  (oset obj model-value (and (boundp 'gptel-model) gptel-model)))

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

(cl-defmethod transient-infix-read ((obj ogent-provider-variable))
  "Read OBJ without persisting runtime backend structs in Transient history."
  (funcall (oref obj reader) (transient-prompt obj) nil nil))

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





;; Forward declaration for ogent-response-function (defined as defcustom later)

;; Request struct must be defined early for setf accessors

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

;;; Tools Toggle Infix

(defun ogent--tools-description ()
  "Return description string for tools infix showing current state."
  (let* ((all-tools (when (fboundp 'ogent-tools-all)
                      (ogent-tools-all)))
         (total (length all-tools))
         (enabled (when (fboundp 'ogent-tools-enabled-list)
                    (ogent-tools-enabled-list)))
         (enabled-count (length enabled)))
    (concat "Tools: "
            (cond
             ((null ogent-tools-enabled)
              (propertize "[disabled]" 'face 'font-lock-comment-face))
             ((eq ogent-tools-enabled t)
              (if (zerop total)
                  (propertize "[none registered]" 'face 'font-lock-comment-face)
                (propertize (format "[all %d]" total) 'face 'success)))
             ((listp ogent-tools-enabled)
              (propertize (format "[%d of %d]" enabled-count total)
                          'face 'font-lock-keyword-face))
             (t "[?]")))))

(defun ogent--toggle-tools ()
  "Toggle `ogent-tools-enabled' for current buffer.
Cycles: t -> nil -> t (simple toggle).
Makes the variable buffer-local for session-level control."
  (interactive)
  (make-local-variable 'ogent-tools-enabled)
  (setq ogent-tools-enabled (not ogent-tools-enabled))
  (message "Tools %s for this session"
           (if ogent-tools-enabled "enabled" "disabled")))

(transient-define-infix ogent--infix-tools ()
			"Toggle tool availability."
			:description #'ogent--tools-description
			:class 'transient-lisp-variable
			:variable 'ogent-tools-enabled
			:key "t"
			:reader (lambda (_prompt _initial _history)
				  (ogent--toggle-tools)
				  ;; Return current value to satisfy the reader contract
				  ogent-tools-enabled))

;;; Preset Selector Infix

(defun ogent--preset-description ()
  "Return description string for preset infix showing current selection."
  (concat "Preset: "
          (if ogent-ui--selected-preset
              (propertize ogent-ui--selected-preset 'face 'font-lock-function-name-face)
            (propertize "[none]" 'face 'font-lock-comment-face))))

(defun ogent--read-preset (_prompt _initial _history)
  "Read a preset name with completion."
  (let* ((available (if (fboundp 'ogent-presets-available)
                        (ogent-presets-available)
                      nil))
         (choices (cons "[none]" available))
         (selection (completing-read "Preset: " choices nil t nil nil
                                     (or ogent-ui--selected-preset "[none]"))))
    (if (string= selection "[none]")
        (progn (setq ogent-ui--selected-preset nil) nil)
      (setq ogent-ui--selected-preset selection)
      selection)))

(transient-define-infix ogent--infix-preset ()
			"Select gptel preset."
			:description #'ogent--preset-description
			:class 'transient-lisp-variable
			:variable 'ogent-ui--selected-preset
			:key "s"
			:reader #'ogent--read-preset)

;;; Prompt Template Infix

(defun ogent--templates-description ()
  "Return description string for template infix showing selection."
  (concat "Templates: "
          (if ogent-ui--selected-templates
              (propertize (format "[%d]" (length ogent-ui--selected-templates))
                          'face 'font-lock-function-name-face)
            (propertize "[none]" 'face 'font-lock-comment-face))))

(defun ogent--read-templates (_prompt _initial _history)
  "Read prompt template IDs using completing-read-multiple."
  (let* ((available (if (fboundp 'ogent-prompt-ids)
                        (ogent-prompt-ids)
                      nil))
         (selection (completing-read-multiple
                     "Templates (comma-separated, empty for none): "
                     available nil nil
                     (when ogent-ui--selected-templates
                       (string-join ogent-ui--selected-templates ",")))))
    (if (or (null selection) (equal selection '("")))
        (progn (setq ogent-ui--selected-templates nil) nil)
      (setq ogent-ui--selected-templates selection)
      selection)))

(transient-define-infix ogent--infix-templates ()
			"Select prompt templates."
			:description #'ogent--templates-description
			:class 'transient-lisp-variable
			:variable 'ogent-ui--selected-templates
			:key "T"
			:reader #'ogent--read-templates)

;;; Multi-Model Selection Infix

(defun ogent--models-description ()
  "Return description string for multi-model infix showing current selection."
  (concat "Fan-out: "
          (if ogent-ui--selected-models
              (propertize (format "[%d models]" (length ogent-ui--selected-models))
                          'face 'font-lock-function-name-face)
            (propertize "[single]" 'face 'font-lock-comment-face))))

(defun ogent--read-models (_prompt _initial _history)
  "Read multiple model IDs with completing-read-multiple."
  (let* ((available (if (fboundp 'ogent-models-ids)
                        (ogent-models-ids)
                      nil))
         (selection (completing-read-multiple
                     "Models (comma-separated, empty for single): "
                     available nil nil
                     (when ogent-ui--selected-models
                       (string-join ogent-ui--selected-models ",")))))
    (if (or (null selection) (equal selection '("")))
        (progn (setq ogent-ui--selected-models nil) nil)
      (setq ogent-ui--selected-models selection)
      selection)))

(transient-define-infix ogent--infix-models ()
			"Select multiple models for fan-out."
			:description #'ogent--models-description
			:class 'transient-lisp-variable
			:variable 'ogent-ui--selected-models
			:key "M"
			:reader #'ogent--read-models)

;;; Direct Send Suffix

(defun ogent--get-effective-prompt ()
  "Get the prompt to send: transient input, region, or minibuffer."
  (or ogent--transient-prompt
      (when (use-region-p)
        (buffer-substring-no-properties (region-beginning) (region-end)))
      (read-string "Prompt: ")))

(defun ogent-ui--apply-prompt-templates (prompt &optional templates)
  "Apply prompt templates to PROMPT, returning the combined string."
  (let ((templates (or templates ogent-ui--selected-templates)))
    (if (and templates (fboundp 'ogent-prompt-compose-with-params))
        (let ((template-text (ogent-prompt-compose-with-params templates)))
          (if (string-empty-p template-text)
              prompt
            (string-join (list template-text prompt) "\n\n")))
      prompt)))

(defun ogent-ui--model-id-or-default (&optional model-id)
  "Return registered MODEL-ID, or the configured ogent default.
This keeps buffer-local gptel state from breaking ogent when a buffer
remembers a model that is not in `ogent-model-registry'."
  (let* ((candidate (or model-id
                        (and (boundp 'gptel-model)
                             gptel-model)))
         (candidate (cond
                     ((and candidate (fboundp 'gptel--model-name))
                      (gptel--model-name candidate))
                     ((symbolp candidate)
                      (symbol-name candidate))
                     (t candidate)))
         (default (plist-get (ogent-models-default) :id)))
    (if (and candidate (ogent-models-get candidate))
        candidate
      default)))

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
                      (user-error "ogent-response-function must return an `ogent-ui-request'"))
                    (setf (ogent-ui-request-preset request) effective-preset)
                    (setf (ogent-ui-request-source-buffer request) source-buffer)
                    (ogent-ui--send-request request)))
              ;; Single model: use the current registered gptel model, or ogent default.
              (let* ((model (ogent-models-ensure (ogent-ui--model-id-or-default)))
                     (request (funcall ogent-response-function final-prompt context model)))
                (unless (ogent-ui-request-p request)
                  (user-error "ogent-response-function must return an `ogent-ui-request'"))
                (setf (ogent-ui-request-preset request) effective-preset)
                (setf (ogent-ui-request-source-buffer request) source-buffer)
                (ogent-ui--send-request request)))
          (message "Ogent request canceled"))))))

;; Note: ogent--suffix-send replaced by ogent--suffix-send-action
;; which includes visual feedback via ogent-theme-flash

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

(defcustom ogent-context-preview-buffer-name "*ogent-context*"
  "Buffer used to display the context summary."
  :type 'string
  :group 'ogent-mode)

(defcustom ogent-errors-buffer-name "*ogent-errors*"
  "Buffer used to display ogent request errors."
  :type 'string
  :group 'ogent-mode)

(defface ogent-context-diff-added
  '((((class color) (background light)) :background "#d0ffd0")
    (((class color) (background dark)) :background "#004400"))
  "Face for lines added to context."
  :group 'ogent-mode)

(defface ogent-context-diff-removed
  '((((class color) (background light)) :background "#ffd0d0")
    (((class color) (background dark)) :background "#440000"))
  "Face for lines removed from context."
  :group 'ogent-mode)

(defvar ogent-ui--context-preview-window nil
  "Window displaying the context preview, if any.")

(defvar-local ogent-ui--previous-context nil
  "Previous context string for diff comparison.")

(defvar-local ogent-ui--diff-overlays nil
  "List of overlays used for highlighting context changes.")

(defvar ogent-ui--diff-clear-timer nil
  "Timer for clearing diff overlays.")

(defvar ogent-ui--error-history nil
  "List of error records, most recent first.
Each record is a plist with :timestamp, :model, :error, :request-id, :context.")

(defvar ogent-ui--error-window nil
  "Window displaying the error buffer, if any.")






(defun ogent-ui--format-node (node)
  "Return a human-readable summary line for NODE."
  (when node
    (format "%s (id: %s)"
            (or (ogent-context-node-title node) "<untitled>")
            (ogent-context-node-id node))))

(defun ogent-ui--format-context (context)
  "Format CONTEXT plist as a readable summary string."
  (let* ((source-ctx (plist-get context :source-context))
         (root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         (handles (plist-get context :handles))
         (pinned (plist-get context :pinned))
         (lines nil))
    ;; Pinned context (always include first)
    (when pinned
      (push (format "Pinned (%d item%s):"
                    (length pinned)
                    (if (= (length pinned) 1) "" "s"))
            lines)
      (dolist (item pinned)
        (push (format "  - [%s] %s"
                      (ogent-pinned-item-type item)
                      (ogent-pinned-item-label item))
              lines))
      (push "" lines))
    ;; Source context (for non-Org buffers)
    (when source-ctx
      (push (ogent-context--format-source-context source-ctx) lines)
      (push "" lines))  ; blank line separator
    ;; Org context
    (when root
      (push (format "Root: %s" (ogent-ui--format-node root)) lines))
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
    (if lines
        (mapconcat #'identity (nreverse lines) "\n")
      "(no context)")))

(defun ogent-ui--context-buffer ()
  "Return the context preview buffer, clearing previous content."
  (let ((buffer (get-buffer-create ogent-context-preview-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)))
    buffer))

(defun ogent-ui--preview-prompt ()
  "Return the prompt text to display in context previews."
  (or ogent--transient-prompt
      "(prompt will be supplied at dispatch)"))

(defun ogent-ui--read-prompt ()
  "Derive the prompt from the region or minibuffer."
  (if (use-region-p)
      (string-trim (buffer-substring-no-properties (region-beginning)
                                                   (region-end)))
    (read-string "Prompt: ")))

(defun ogent-ui--diff-strings (old new)
  "Compare OLD and NEW strings line by line.
Return list of plists with :type (:added or :removed), :lines (list of strings),
and :line-number (first line number where changes start)."
  (let ((old-lines (and old (split-string old "\n" nil)))
        (new-lines (and new (split-string new "\n" nil)))
        (result nil)
        (line-num 1)
        (i 0)
        (j 0))
    ;; Simple line-by-line diff
    (while (or (< i (length old-lines)) (< j (length new-lines)))
      (let ((old-line (and (< i (length old-lines)) (nth i old-lines)))
            (new-line (and (< j (length new-lines)) (nth j new-lines))))
        (cond
         ;; Lines match - advance both
         ((and old-line new-line (string= old-line new-line))
          (setq i (1+ i)
                j (1+ j)
                line-num (1+ line-num)))
         ;; New line added
         ((and (not old-line) new-line)
          (let ((added-lines (list new-line))
                (start-line line-num))
            (setq j (1+ j)
                  line-num (1+ line-num))
            ;; Collect consecutive added lines
            (while (and (< j (length new-lines))
                        (or (>= i (length old-lines))
                            (not (string= (nth i old-lines) (nth j new-lines)))))
              (push (nth j new-lines) added-lines)
              (setq j (1+ j)
                    line-num (1+ line-num)))
            (push (list :type :added
                        :lines (nreverse added-lines)
                        :line-number start-line)
                  result)))
         ;; Old line removed
         ((and old-line (not new-line))
          (let ((removed-lines (list old-line))
                (start-line line-num))
            (setq i (1+ i))
            ;; Collect consecutive removed lines
            (while (and (< i (length old-lines))
                        (or (>= j (length new-lines))
                            (not (string= (nth i old-lines) (nth j new-lines)))))
              (push (nth i old-lines) removed-lines)
              (setq i (1+ i)))
            (push (list :type :removed
                        :lines (nreverse removed-lines)
                        :line-number start-line)
                  result)))
         ;; Lines differ - mark as replacement (removed + added)
         (t
          (let ((removed-lines (list old-line))
                (added-lines (list new-line))
                (start-line line-num))
            (setq i (1+ i)
                  j (1+ j)
                  line-num (1+ line-num))
            ;; Look ahead for more changes
            (while (and (< i (length old-lines))
                        (< j (length new-lines))
                        (not (string= (nth i old-lines) (nth j new-lines))))
              (push (nth i old-lines) removed-lines)
              (push (nth j new-lines) added-lines)
              (setq i (1+ i)
                    j (1+ j)
                    line-num (1+ line-num)))
            (push (list :type :removed
                        :lines (nreverse removed-lines)
                        :line-number start-line)
                  result)
            (push (list :type :added
                        :lines (nreverse added-lines)
                        :line-number start-line)
                  result))))))
    (nreverse result)))

(defun ogent-ui--apply-diff-overlays (diff-result)
  "Create overlays for DIFF-RESULT in current buffer.
DIFF-RESULT is a list of plists from `ogent-ui--diff-strings'."
  (ogent-ui--clear-diff-overlays)
  (save-excursion
    (goto-char (point-min))
    (dolist (change diff-result)
      (let* ((type (plist-get change :type))
             (lines (plist-get change :lines))
             (line-num (plist-get change :line-number))
             (face (if (eq type :added)
                       'ogent-context-diff-added
                     'ogent-context-diff-removed)))
        ;; Move to the target line
        (goto-char (point-min))
        (forward-line (1- line-num))
        ;; Create overlay for each line
        (dolist (_line lines)
          (let ((start (line-beginning-position))
                (end (min (1+ (line-end-position)) (point-max))))
            (when (< start end)
              (let ((ov (make-overlay start end)))
                (overlay-put ov 'face face)
                (overlay-put ov 'ogent-diff t)
                (push ov ogent-ui--diff-overlays)))
            (forward-line 1)))))))

(defun ogent-ui--clear-diff-overlays ()
  "Remove all diff overlays from current buffer."
  (when ogent-ui--diff-overlays
    (mapc #'delete-overlay ogent-ui--diff-overlays)
    (setq ogent-ui--diff-overlays nil))
  (when ogent-ui--diff-clear-timer
    (cancel-timer ogent-ui--diff-clear-timer)
    (setq ogent-ui--diff-clear-timer nil)))




(defun ogent-ui--maybe-transform-zen-context (context &optional point)
  "Return CONTEXT adjusted to match the current Zen run, when active."
  (if (and (bound-and-true-p ogent-zen-mode)
           (fboundp 'ogent-zen--heading-point)
           (fboundp 'ogent-zen--context-transform))
      (let ((zen-point (or point (ogent-zen--heading-point))))
        (if zen-point
            (ogent-zen--context-transform context zen-point)
          context))
    context))

;;;###autoload
(defun ogent-context-preview ()
  "Render the current subtree context into a preview buffer.
When invoked from a non-Org buffer, includes source buffer context."
  (interactive)
  (let* ((source-buffer (current-buffer))
         (region-start (when (use-region-p) (region-beginning)))
         (region-end (when (use-region-p) (region-end)))
         (companion (ogent-ui--ensure-companion-context)))
    (with-current-buffer companion
      (let* ((org-point (and (bound-and-true-p ogent-zen-mode)
                             (fboundp 'ogent-zen--heading-point)
                             (ogent-zen--heading-point)))
             (context (ogent-ui--maybe-transform-zen-context
                       (ogent-context-build-with-source
                        source-buffer region-start region-end org-point)
                       org-point))
             (payload (ogent-ui--render-prompt (ogent-ui--preview-prompt) context))
             (buffer (ogent-ui--context-buffer)))
        (with-current-buffer buffer
          (let ((previous ogent-ui--previous-context))
            (insert payload)
            (goto-char (point-min))
            ;; Apply diff highlighting if we have previous context
            (when previous
              (let ((diff (ogent-ui--diff-strings previous payload)))
                (when diff
                  (ogent-ui--apply-diff-overlays diff)
                  ;; Clear overlays after 3 seconds
                  (setq ogent-ui--diff-clear-timer
                        (run-with-timer 3 nil
                                        (lambda (buf)
                                          (when (buffer-live-p buf)
                                            (with-current-buffer buf
                                              (ogent-ui--clear-diff-overlays))))
                                        buffer)))))
            ;; Update previous context for next comparison
            (setq ogent-ui--previous-context payload)))
        (display-buffer buffer)))))

(defun ogent-ui--context-preview-visible-p ()
  "Return non-nil if the context preview buffer is currently visible."
  (and ogent-ui--context-preview-window
       (window-live-p ogent-ui--context-preview-window)
       (eq (window-buffer ogent-ui--context-preview-window)
           (get-buffer ogent-context-preview-buffer-name))))

(defun ogent-ui--close-context-preview ()
  "Close the context preview window if visible."
  (when (ogent-ui--context-preview-visible-p)
    (delete-window ogent-ui--context-preview-window)
    (setq ogent-ui--context-preview-window nil)))

;;;###autoload
(defun ogent-context-preview-toggle ()
  "Toggle the context preview popup.
If visible, close it.  Otherwise, show it in a popup without switching focus."
  (interactive)
  (if (ogent-ui--context-preview-visible-p)
      (ogent-ui--close-context-preview)
    (let* ((source-buffer (current-buffer))
           (region-start (when (use-region-p) (region-beginning)))
           (region-end (when (use-region-p) (region-end)))
           (companion (ogent-ui--ensure-companion-context)))
      (with-current-buffer companion
        (let* ((org-point (and (bound-and-true-p ogent-zen-mode)
                               (fboundp 'ogent-zen--heading-point)
                               (ogent-zen--heading-point)))
               (context (ogent-ui--maybe-transform-zen-context
                         (ogent-context-build-with-source
                          source-buffer region-start region-end org-point)
                         org-point))
               (payload (ogent-ui--render-prompt (ogent-ui--preview-prompt) context))
               (buffer (ogent-ui--context-buffer)))
          (with-current-buffer buffer
            (insert payload)
            (goto-char (point-min)))
          ;; Use side-window with slot -1 to appear above transient (slot 0)
          (setq ogent-ui--context-preview-window
                (display-buffer buffer
                                '((display-buffer-in-side-window)
                                  (side . bottom)
                                  (slot . -1)
                                  (window-height . 10)
                                  (preserve-size . (nil . t))))))))))

;;;###autoload
(defun ogent-ask-context-preview-toggle ()
  "Toggle the context preview popup for the active ask scope."
  (interactive)
  (if (ogent-ui--context-preview-visible-p)
      (ogent-ui--close-context-preview)
    (let* ((source-buffer (current-buffer))
           (region-start (when (use-region-p) (region-beginning)))
           (region-end (when (use-region-p) (region-end)))
           (org-point (ogent-ask--org-scope-point))
           (companion (ogent-ui--ensure-companion-context)))
      (with-current-buffer companion
        (let* ((context (ogent-context-build-with-source
                         source-buffer region-start region-end org-point))
               (payload (ogent-ui--render-prompt (ogent-ui--preview-prompt) context))
               (buffer (ogent-ui--context-buffer)))
          (with-current-buffer buffer
            (insert payload)
            (goto-char (point-min)))
          (setq ogent-ui--context-preview-window
                (display-buffer buffer
                                '((display-buffer-in-side-window)
                                  (side . bottom)
                                  (slot . -1)
                                  (window-height . 10)
                                  (preserve-size . (nil . t))))))))))

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
      (propertize
       (format "%s:%s"
               (if (fboundp 'gptel-backend-name)
                   (gptel-backend-name gptel-backend)
                 "backend")
               (if (fboundp 'gptel--model-name)
                   (gptel--model-name gptel-model)
                 gptel-model))
       'face 'ogent-theme-primary)
    (propertize "not configured" 'face 'ogent-theme-muted)))

(defun ogent--format-status-header ()
  "Format a comprehensive status line for the dispatcher header.
Shows model, context info, and pinned count."
  (let* ((model-str (ogent--format-model-header))
         (pinned (ogent-pinned-count))
         (pinned-str (if (> pinned 0)
                         (concat "  "
                                 (propertize "pinned " 'face 'transient-heading)
                                 (propertize (format "%d" pinned)
                                             'face 'ogent-theme-highlight))
                       ""))
         (preset-str (if ogent-ui--selected-preset
                         (concat "  "
                                 (propertize "preset " 'face 'transient-heading)
                                 (propertize ogent-ui--selected-preset
                                             'face 'ogent-theme-secondary))
                       ""))
         ;; Show active request count if any
         (active-count (hash-table-count ogent-ui--request-table))
         (active-str (if (> active-count 0)
                         (concat "  "
                                 (propertize (format "%d active" active-count)
                                             'face 'ogent-theme-warning))
                       "")))
    (concat model-str pinned-str preset-str active-str)))

(defun ogent--format-context-group ()
  "Format the Context group header with pinned count."
  (let ((count (ogent-pinned-count)))
    (concat "Context"
            (when (> count 0)
              (propertize (format " (%d)" count) 'face 'ogent-theme-highlight)))))

;;; Prompt dispatcher descriptions

(defun ogent--desc-send ()
  "Return the dynamic description for sending from the dispatcher."
  (cond
   (ogent--transient-prompt
    (propertize
     (format "Send \"%s\""
             (truncate-string-to-width ogent--transient-prompt 20 nil nil "..."))
     'face 'ogent-theme-success))
   ((use-region-p)
    (propertize "Send region" 'face 'ogent-theme-success))
   (t (propertize "Send" 'face 'ogent-theme-success))))

(defun ogent--desc-ask-here ()
  "Return the description for inline asking."
  (let ((scope (ogent-ask-context-description)))
    (if (string= scope "no context")
        "Ask here..."
      (propertize (format "Ask here about %s..." scope)
                  'face 'ogent-theme-success))))

(defun ogent--desc-quick-ask ()
  "Return the description for popup quick ask."
  (let ((scope (ogent-ask-context-description)))
    (if (string= scope "no context")
        "Ask popup..."
      (format "Ask popup about %s..." scope))))

(defun ogent-ask-menu--scope-line ()
  "Return the contextual scope line for `ogent-ask-menu'."
  (let ((scope (ogent-ask-context-description)))
    (if (string= scope "no context")
        (propertize
         "Scope: no Org subtree or buffer context; popup ask sends only your question."
         'face 'transient-heading)
      (concat
       (propertize "Scope: " 'face 'transient-heading)
       (propertize scope 'face 'ogent-theme-highlight)
       (propertize
        "  q = inline Request/Response here, c = preview ask context"
        'face 'font-lock-comment-face)))))

(defun ogent-ask-here--read-question ()
  "Read an inline `ogent-ask-here' question with the active scope."
  (let ((scope (ogent-ask-context-description)))
    (read-string
     (if (string= scope "no context")
         "Ask here: "
       (format "Ask here about %s: " scope)))))

;;;###autoload
(defun ogent-ask-here (question)
  "Ask QUESTION with current context and stream the response into Org.
In an Org subtree, insert a normal ogent Request/Response transcript
as a child of the current subtree.  In source buffers, use the normal
companion Org transcript.  If an Org buffer has no headline at point,
fall back to the popup `ogent-ask' path."
  (interactive (list (ogent-ask-here--read-question)))
  (when (string-empty-p (string-trim question))
    (user-error "Question cannot be empty"))
  (if (and (derived-mode-p 'org-mode)
           (not (ogent-ask--org-heading-title)))
      (ogent-ask question)
    (ogent-request question)))

;;;###autoload (autoload 'ogent-ask-menu "ogent" nil t)
(transient-define-prefix ogent-ask-menu ()
  "Ask about the current ogent context."
  [:description ogent-ask-menu--scope-line
   ["Ask"
    ("RET" "Run current bullet" ogent-run-subtree)
    ("!" "Re-run at point" ogent-zen-rerun)
    ("q" ogent-ask-here :description ogent--desc-ask-here)
    ("?" ogent-ask :description ogent--desc-quick-ask)
    ("r" "Send prompt..." ogent-request)]
   ["Malleable"
    ("g" "Ask about region" ogent-zen-run-region)
    ("x" "Rewrite region/paragraph" ogent-zen-edit-dwim)
    ("A" "Apply last edit" ogent-zen-apply-last-edit)]
   ["Inspect"
    ("c" "Preview ask context" ogent-ask-context-preview-toggle :transient t)
    ("p" "Full dispatcher" ogent-prompt-dispatch)
    ("h" "All keys" ogent-describe-bindings)]]
  (interactive)
  (transient-setup 'ogent-ask-menu))

(defun ogent--desc-quick-edit ()
  "Return the description for quick edit."
  "Quick edit...")

(defun ogent--desc-ai-speed-edit ()
  "Return the description for AI speed edit."
  "AI speed edit")

(defun ogent--desc-fix-diagnostic ()
  "Return the description for diagnostic repair."
  "Fix diagnostic")

(defun ogent--desc-fix-buffer-diagnostics ()
  "Return the description for buffer diagnostic repair."
  "Fix buffer diagnostics")

(defun ogent--desc-preview ()
  "Return the description for context preview."
  "Preview...")

(defun ogent--desc-codemap ()
  "Return the description for codemap."
  "Codemap...")

(defun ogent--desc-edit-menu ()
  "Return the description for edit menu."
  "Edit menu")

(defun ogent--desc-issues ()
  "Return the description for issues."
  "Issues")

(defun ogent--desc-save ()
  "Return the description for saving a session."
  "Save...")

(defun ogent--desc-load ()
  "Return the description for loading a session."
  "Load...")

(defun ogent--desc-history ()
  "Return the description for session history."
  "History...")

(defun ogent--desc-debug ()
  "Return the description for debug mode."
  "Debug mode")

(defun ogent--desc-quit ()
  "Return the description for quitting the dispatcher."
  "Quit")

(transient-define-suffix ogent--suffix-send-action ()
  "Send prompt to LLM with visual feedback."
  :key "RET"
  :description #'ogent--desc-send
  (interactive)
  (let ((prompt (ogent--get-effective-prompt)))
    (setq ogent--transient-prompt nil)
    ;; Flash success on send
    (ogent-theme-flash 'info "Sending request...")
    (ogent--send-with-current-model prompt)))

;;;###autoload (autoload 'ogent-prompt-dispatch "ogent" nil t)
(transient-define-prefix ogent-prompt-dispatch ()
  "Prompt dispatcher for ogent requests.

A polished interface for AI-assisted workflows.

                    ╭─────────────────────────────╮
                    │      OGENT DISPATCHER       │
                    ╰─────────────────────────────╯"
  [:description ogent--format-status-header
   [:description "Send"
    (ogent--suffix-send-action)
    ("v" ogent-ai-speed-edit :description ogent--desc-ai-speed-edit)
    ("f" ogent-fix-diagnostic :description ogent--desc-fix-diagnostic)
    ("F" ogent-fix-buffer-diagnostics
     :description ogent--desc-fix-buffer-diagnostics)
    ("a" ogent-ask-here :description ogent--desc-ask-here)
    ("?" "Ask menu" ogent-ask-menu)]
   [:description "Model"
    (ogent--infix-provider)
    (ogent--infix-preset)
    (ogent--infix-models)]]

  [[:description "Prompt"
    (ogent--infix-prompt)
    (ogent--infix-templates)
    (ogent--infix-tools)]
   [:description ogent--format-context-group
    ("c" ogent-context-preview-toggle :description ogent--desc-preview :transient t)
    ("C" ogent-codemap-buffer :description ogent--desc-codemap)
    (ogent--suffix-pin-dwim)
    (ogent--suffix-unpin)
    (ogent--suffix-list-pinned)]]

  [[:description "Navigate"
    ("e" ogent-edit-menu :description ogent--desc-edit-menu)
    ("i" ogent-issues :description ogent--desc-issues)]
   [:description "Session"
    ("S" ogent-session-save :description ogent--desc-save)
    ("L" ogent-session-load :description ogent--desc-load)
    ("H" ogent-session-list :description ogent--desc-history)]
   [""
    ("D" ogent-debug-mode :description ogent--desc-debug)
    ("q" transient-quit-one :description ogent--desc-quit)]]
  (interactive)
  (ogent-ui--ensure-companion-context)
  (transient-setup 'ogent-prompt-dispatch))

(transient-define-suffix ogent--suffix-pin-dwim ()
			 "Pin current file/buffer/region to context."
			 :key "P"
			 :description
			 (lambda ()
			   (concat "Pin "
				   (cond
				    ((use-region-p) "region")
				    ((buffer-file-name) "file")
				    (t "buffer"))))
			 :transient t
			 (interactive)
			 (ogent-pin-dwim)
			 (ogent-theme-flash 'success "Pinned to context"))

(transient-define-suffix ogent--suffix-unpin ()
			 "Unpin an item from context."
			 :key "U"
			 :description
			 (lambda ()
			   (let ((count (ogent-pinned-count)))
			     (if (zerop count)
				 (propertize "Unpin..." 'face 'ogent-theme-muted)
			       "Unpin...")))
			 :transient t
			 (interactive)
			 (if (zerop (ogent-pinned-count))
			     (message "%s No pinned items" (ogent-theme-icon 'warning))
			   (ogent-unpin-interactive)
			   (ogent-theme-flash 'info "Unpinned from context")))

(transient-define-suffix ogent--suffix-list-pinned ()
			 "List pinned context items."
			 :key "l"
			 :description
			 (lambda ()
			   (let ((count (ogent-pinned-count)))
			     (concat "List"
				     (when (> count 0)
				       (propertize (format " (%d)" count) 'face 'ogent-theme-highlight)))))
			 (interactive)
			 (ogent-list-pinned))

;;; Transcript Navigation

(defun ogent-next-response ()
  "Move to next response heading."
  (interactive)
  (if (re-search-forward "^\\*+ Response" nil t)
      (org-back-to-heading t)
    (message "No more responses")))

(defun ogent-prev-response ()
  "Move to previous response heading."
  (interactive)
  (if (re-search-backward "^\\*+ Response" nil t)
      (org-back-to-heading t)
    (message "No previous responses")))

(defun ogent-next-request ()
  "Move to next request heading."
  (interactive)
  (if (re-search-forward "^\\*+ Request:" nil t)
      (org-back-to-heading t)
    (message "No more requests")))

(defun ogent-prev-request ()
  "Move to previous request heading."
  (interactive)
  (if (re-search-backward "^\\*+ Request:" nil t)
      (org-back-to-heading t)
    (message "No previous requests")))

;;;###autoload (autoload 'ogent-navigate "ogent-ui" nil t)
(transient-define-prefix ogent-navigate ()
  "Navigate request and response headings in ogent transcript buffers."
  [["Response"
    ("n" "Next response" ogent-next-response :transient t)
    ("p" "Previous response" ogent-prev-response :transient t)]
   ["Request"
    ("N" "Next request" ogent-next-request :transient t)
    ("P" "Previous request" ogent-prev-request :transient t)]
   ["Heading"
    ("j" "Next heading" org-next-visible-heading :transient t)
    ("k" "Previous heading" org-previous-visible-heading :transient t)]]
  [["Jump"
    ("g" "Dependency graph" ogent-show-dependency-graph)
    ("b" "Backlinks" ogent-show-backlinks)
    ("o" "Open block" ogent-open-block)
    ("q" "Quit" transient-quit-one)]])

(declare-function gptel-request "ext:gptel-request" (prompt &rest args))


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




;;; Conversation History

(defun ogent-ui--encode-prompt-property (prompt)
  "Encode PROMPT for storage in a single-line Org property.
Backslashes are doubled, then newlines become literal backslash-n, so
`ogent-ui--decode-prompt-property' can reverse the encoding exactly."
  (replace-regexp-in-string
   "\n" "\\\\n"
   (replace-regexp-in-string "\\\\" "\\\\\\\\" prompt)))

(defun ogent-ui--decode-prompt-property (value)
  "Decode VALUE produced by `ogent-ui--encode-prompt-property'."
  (replace-regexp-in-string
   "\\\\[n\\\\]"
   (lambda (match)
     (if (string= match "\\n") "\n" "\\"))
   value t t))

(defun ogent-ui--next-heading-at-or-above (level bound)
  "Return the next heading position at or above LEVEL before BOUND."
  (save-excursion
    (when (re-search-forward (format "^\\*\\{1,%d\\} " level) bound t)
      (match-beginning 0))))

(defun ogent-ui--response-body-in-region (start end model-id)
  "Return the preferred Response body between START and END.
Prefer the \"Response (MODEL-ID)\" child when several models fanned
out under one request; otherwise return the first response
body.  Return nil when the region contains no Response heading."
  (save-excursion
    (goto-char start)
    (let (preferred first)
      (while (and (not preferred)
                  (re-search-forward "^\\(\\*+\\) Response (\\([^)]*\\))" end t))
        (let* ((response-level (length (match-string 1)))
               (this-model (match-string-no-properties 2))
               (body-start (min end (1+ (line-end-position))))
               (body-end (or (save-excursion
                                (goto-char body-start)
                                (ogent-ui--next-heading-at-or-above
                                 response-level end))
                              end))
               (body (string-trim (buffer-substring-no-properties
                                   body-start (max body-start body-end)))))
          (unless first (setq first body))
          (when (and model-id (string= this-model model-id))
            (setq preferred body))))
      (or preferred first))))

(defun ogent-ui--conversation-history (buffer bound-pos model-id)
  "Collect completed exchanges in BUFFER strictly before BOUND-POS.
Return a flat list (user-1 response-1 user-2 response-2 ...) suitable
as the leading turns of a `gptel-request' conversation PROMPT.  The
user turn comes from the request headline's OGENT_PROMPT property when
present, falling back to the headline summary for transcripts written
before the property existed.  When a request has several Response
children (multi-model fan-out), prefer the one matching MODEL-ID.
Exchanges whose response body is empty (in-flight, aborted, or
errored) are skipped so the user/assistant alternation stays intact."
  (with-current-buffer buffer
    (save-excursion
      (save-match-data
        (save-restriction
          (widen)
          (let ((bound (ogent-ui--position-value bound-pos))
                (history nil))
            (goto-char (point-min))
            (while (re-search-forward "^\\(\\*+\\) Request: \\(.*\\)$" bound t)
              (let* ((request-level (length (match-string 1)))
                     (summary (string-trim (match-string-no-properties 2)))
                     (request-pos (match-beginning 0))
                     (request-end (or (save-excursion
                                        (ogent-ui--next-heading-at-or-above
                                         request-level bound))
                                      (or bound (point-max))))
                     (stored (org-entry-get request-pos "OGENT_PROMPT"))
                     (user-turn (if (and stored (not (string-empty-p stored)))
                                    (ogent-ui--decode-prompt-property stored)
                                  summary))
                     (response (ogent-ui--response-body-in-region
                                request-pos request-end model-id)))
                (when (and response (not (string-empty-p response))
                           (not (string-empty-p user-turn)))
                  (push user-turn history)
                  (push response history))
                (goto-char request-end)))
            (nreverse history)))))))

(defun ogent-ui--compact-history (history budget)
  "Drop oldest exchange pairs from HISTORY until it fits BUDGET tokens.
HISTORY is a flat (user response ...) list; pairs are evicted together
so the user/assistant alternation is preserved.  Token counts use
`ogent-analytics-estimate-tokens'.  Return the possibly empty
compacted list."
  (require 'ogent-analytics)
  (let ((total (apply #'+ (mapcar #'ogent-analytics-estimate-tokens history))))
    (while (and history (> total budget))
      (setq total (- total
                     (ogent-analytics-estimate-tokens (car history))
                     (ogent-analytics-estimate-tokens (cadr history))))
      (setq history (cddr history)))
    history))

(defun ogent-ui--stars (level)
  "Return an Org headline prefix for LEVEL."
  (make-string (max 1 level) ?*))

(defun ogent-ui--request-heading-level ()
  "Return the Org level to use for a new Request headline."
  (if ogent-session-buffer-p
      2
    (save-excursion
      (condition-case nil
          (progn
            (org-back-to-heading t)
            (1+ (or (org-current-level) 0)))
        (error 1)))))

(defun ogent-ui--prepare-request-insertion ()
  "Move point to the insertion position for a new Request headline."
  (if ogent-session-buffer-p
      (progn
        (goto-char (point-max))
        (unless (bolp) (insert "\n")))
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n")))
      (error
       (goto-char (point-max))
       (unless (bolp) (insert "\n"))))))

(defun ogent-ui--maybe-refresh-zen (&optional request)
  "Refresh Zen overlays when `ogent-zen-mode' is active.
With REQUEST, refresh only that request's transcript region instead of
rescanning the whole buffer."
  (when (and (bound-and-true-p ogent-zen-mode)
             (fboundp 'ogent-zen-refresh))
    (let ((pos (and request
                    (fboundp 'ogent-zen-refresh-at)
                    (let ((marker (ogent-ui-request-request-heading-pos
                                   request)))
                      (and (markerp marker)
                           (eq (marker-buffer marker) (current-buffer))
                           (marker-position marker))))))
      (if pos
          (ogent-zen-refresh-at pos)
        (ogent-zen-refresh)))))

(defun ogent-ui--create-response-block (prompt context model)
  "Insert a nested headline structure for a request with MODEL.
Creates a Request child under the current Org heading containing the
prompt/context src block and a nested Response sub-headline where
streamed content goes. This mimics Claude Code's conversation structure
using org-mode idioms.
The raw PROMPT is persisted in an OGENT_PROMPT property at the request
headline so later requests can replay the exchange as history (see
`ogent-ui--conversation-history').
Returns a plist containing a streaming marker and block-start marker."
  (let* ((request-level (ogent-ui--request-heading-level))
         (response-level (1+ request-level))
         (request-stars (ogent-ui--stars request-level))
         (response-stars (ogent-ui--stars response-level))
         (model-id (plist-get model :id))
         (backend (plist-get model :backend))
         (payload (ogent-ui--render-prompt prompt context))
         (prompt-summary (ogent-ui--prompt-headline-summary prompt))
         request-heading-pos
         block-start
         response-heading-pos)
    (ogent-ui--prepare-request-insertion)
    (setq request-heading-pos (point-marker))
    (insert (format "%s Request: %s\n" request-stars prompt-summary))
    ;; Persist the raw prompt for later history replay.  Inserted as
    ;; literal drawer text (not `org-entry-put') so the positions and
    ;; markers captured below stay exact.
    (insert ":PROPERTIES:\n"
            (format ":OGENT_PROMPT: %s\n"
                    (ogent-ui--encode-prompt-property
                     (substring-no-properties prompt))))
    (when (plist-get context :zen-run)
      (let ((selection (plist-get context :zen-selection))
            (scope-kind (plist-get context :zen-scope-kind))
            (instruction (plist-get context :zen-scope-instruction))
            (edit-p (plist-get context :zen-edit)))
        (insert ":OGENT_STYLE: zen\n"
                (format ":OGENT_KIND: %s\n" (if edit-p "edit" "request"))
                (format ":OGENT_PATH: %s\n"
                        (or (plist-get context :zen-path) "")))
        (when scope-kind
          (insert (format ":OGENT_SCOPE_KIND: %s\n" scope-kind)))
        (when instruction
          (insert (format ":OGENT_INSTRUCTION: %s\n"
                          (ogent-ui--encode-prompt-property
                           (substring-no-properties instruction)))))
        (when edit-p
          (insert ":OGENT_EDIT_STATUS: waiting\n"))
        (when selection
          (when-let ((begin (plist-get selection :begin)))
            (insert (format ":OGENT_TARGET_BEGIN: %s\n" begin)))
          (when-let ((end (plist-get selection :end)))
            (insert (format ":OGENT_TARGET_END: %s\n" end)))
          (when-let ((length (plist-get selection :length)))
            (insert (format ":OGENT_TARGET_LENGTH: %s\n" length)))
          (when-let ((sha256 (plist-get selection :sha256)))
            (insert (format ":OGENT_TARGET_SHA256: %s\n" sha256))))
        (when-let ((workspace-root (plist-get context :workspace-root)))
          (insert (format ":OGENT_WORKSPACE: %s\n"
                          (file-name-nondirectory
                           (directory-file-name workspace-root)))
                  (format ":OGENT_WORKSPACE_ROOT: %s\n" workspace-root))
          (when-let ((workspace-target (plist-get context :workspace-target)))
            (insert (format ":OGENT_WORKSPACE_TARGET: %s\n"
                            workspace-target)))
          (when-let ((workspace-source (plist-get context :workspace-source)))
            (insert (format ":OGENT_WORKSPACE_SOURCE: %s\n"
                            workspace-source)))
          (when (plist-get context :workspace-tool-intent)
            (insert ":OGENT_TOOLS: true\n")))))
    (insert ":END:\n")
    ;; Insert the prompt/context src block under the request headline
    (setq block-start (point-marker))
    (insert (format "#+begin_src text :model %s%s :status waiting\n"
                    model-id
                    (if backend
                        (format " :backend %s" (ogent-ui--backend-label backend))
                      "")))
    (insert (ogent-ui--escape-org-block-content payload))
    (insert "\n")
    (insert "#+end_src\n\n")
    ;; Fold the context src block immediately.
    (ogent-ui--hide-src-block-at block-start)
    ;; Include model name for multi-model fan-out disambiguation.
    (setq response-heading-pos (point))
    (insert (format "%s Response (%s)\n" response-stars model-id))
    (let ((marker (copy-marker (point))))
      ;; Keep the next sibling headline on its own line even when the final
      ;; streamed chunk has no trailing newline.
      (insert "\n")
      (if (and (plist-get context :zen-run)
               (bound-and-true-p ogent-zen-mode)
               (fboundp 'ogent-zen-after-insert))
          (ogent-zen-after-insert request-heading-pos)
        (ogent-ui--maybe-refresh-zen))
      (list :marker marker
            :block-start block-start
            :response-pos response-heading-pos
            :request-heading-pos request-heading-pos
            :response-heading-level response-level))))

(defun ogent-ui-register-request (request)
  "Register REQUEST in the active request table."
  (setf (ogent-ui-request-start-time request) (current-time))
  (setf (ogent-ui-request-status request) 'wait)
  (puthash (ogent-ui-request-id request) request ogent-ui--request-table)
  (ogent-ledger-record-request-start request)
  (when (fboundp 'ogent-analytics-start-request)
    (ogent-analytics-start-request))
  ;; Create margin indicator
  (when (fboundp 'ogent-status-set-request)
    (ogent-status-set-request request))
  ;; Enable auto-scroll for new requests if configured
  (with-current-buffer (ogent-ui-request-buffer request)
    (setq ogent--auto-scroll-enabled ogent-auto-scroll)
    ;; Add post-command hook to detect when user scrolls to bottom
    (add-hook 'post-command-hook #'ogent-ui--auto-scroll-post-command nil t))
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
                   :marker (plist-get block :marker)
                   :block-start (plist-get block :block-start)
                   :response-pos (plist-get block :response-pos)
                   :request-heading-pos (plist-get block :request-heading-pos)
                   :response-heading-level
                   (plist-get block :response-heading-level))))
    (ogent-ui-register-request request)))

(when (and (boundp 'ogent-response-function)
           (eq ogent-response-function #'ogent-ui-insert-response-block))
  (setq ogent-response-function #'ogent-ui-prepare-response-block))











(declare-function ogent-analytics-start-request "ogent-analytics")
(declare-function ogent-analytics-estimate-tokens "ogent-analytics" (text))
(declare-function ogent-analytics-first-token "ogent-analytics")
(declare-function ogent-analytics-record-completion "ogent-analytics"
                  (model prompt response &optional template))

(defun ogent-ui--response-body-text (request)
  "Return the streamed response body for REQUEST as a string, or nil.
Reads the buffer text between REQUEST's Response heading and its end
marker, excluding the heading line itself."
  (when-let* ((buffer (ogent-ui-request-buffer request))
              (start (ogent-ui-request-response-pos request))
              (end (ogent-ui-request-marker request)))
    (when (and (buffer-live-p buffer) (markerp end) (marker-position end))
      (with-current-buffer buffer
        (save-excursion
          (goto-char start)
          (forward-line 1)            ; skip the Response heading
          (let ((body-start (point))
                (body-end (marker-position end)))
            (when (< body-start body-end)
              (string-trim
               (buffer-substring-no-properties body-start body-end)))))))))

(defun ogent-ui--append-response (request chunk)
  "Append CHUNK to REQUEST's response block.
If `ogent-auto-scroll' is enabled and the user hasn't scrolled away,
automatically scroll the window to show new content.

Org headings in the response are shifted to nest under the Response
heading (see `ogent-shift-response-headings')."
  (when (and (stringp chunk) (> (length chunk) 0))
    ;; First streamed chunk marks time-to-first-token for analytics
    ;; (self-guards; no-op after the first call or when analytics is off).
    (when (fboundp 'ogent-analytics-first-token)
      (ogent-analytics-first-token))
    (let ((marker (ogent-ui-request-marker request))
          (processed-chunk
           (ogent-ui--shift-org-headings
            chunk
            (ogent-ui-request-response-heading-level request))))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (let ((following-windows
                 (when (and ogent-auto-scroll
                            ogent--auto-scroll-enabled)
                   (ogent-ui--windows-following-position
                    (current-buffer)
                    marker))))
            (save-excursion
              (goto-char marker)
              (insert processed-chunk)
              (set-marker marker (point)))
            (cond
             (following-windows
              (dolist (window following-windows)
                (ogent-ui--scroll-window-to-position window marker)))
             ((and ogent-auto-scroll
                   ogent--auto-scroll-enabled
                   (get-buffer-window-list (current-buffer) nil t))
              (setq ogent--auto-scroll-enabled nil)))))))))


(defun ogent-ui--insert-error-block (request message)
  "Insert an error block for REQUEST containing MESSAGE."
  (let ((marker (ogent-ui-request-marker request)))
    (when (and marker (marker-buffer marker))
      (with-current-buffer (ogent-ui-request-buffer request)
        (save-excursion
          (goto-char marker)
          (insert (format "\n#+begin_quote ogent-error\n%s\n#+end_quote\n" message))
          (set-marker marker (point))))))
  ;; Surface error prominently
  (ogent-ui--surface-error request message))

(defun ogent-ui--update-status (request new-status)
  "Update REQUEST status to NEW-STATUS and refresh block metadata."
  (setf (ogent-ui-request-status request) new-status)
  (when (memq new-status '(done error aborted))
    (setf (ogent-ui-request-end-time request) (current-time)))
  (ogent-ui--update-block-header request)
  ;; Update margin indicator
  (when (fboundp 'ogent-status-update-indicator)
    (ogent-status-update-indicator request new-status))
  (when-let* ((buffer (ogent-ui-request-buffer request)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (ogent-ui--maybe-refresh-zen request)))))

(defun ogent-ui--format-latency (request)
  "Return a formatted latency string for REQUEST, or nil if incomplete."
  (when-let* ((start (ogent-ui-request-start-time request))
              (end (ogent-ui-request-end-time request)))
    (format "%.1fs" (float-time (time-subtract end start)))))

(defun ogent-ui--update-block-header (request)
  "Update the src block header with current status and timing for REQUEST."
  (let ((block-start (ogent-ui-request-block-start request))
        (model (ogent-ui-request-model request))
        (status (ogent-ui-request-status request)))
    (when (and block-start (marker-buffer block-start))
      (with-current-buffer (ogent-ui-request-buffer request)
        (save-excursion
          (goto-char block-start)
          (when (looking-at "^#\\+begin_src text :model \\([^ \n]+\\).*$")
            (let* ((model-id (plist-get model :id))
                   (backend (plist-get model :backend))
                   (latency (ogent-ui--format-latency request))
                   (status-str (pcase status
                                 ('wait "waiting")
                                 ('tool "tool")
                                 ('type "typing")
                                 ('done "done")
                                 ('error "error")
                                 ('paused "paused")
                                 ('aborted "aborted")
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

(defun ogent-ui--fold-prompt-block (request)
  "Fold the prompt/context src block for REQUEST after response completes."
  (let ((block-start (ogent-ui-request-block-start request)))
    (when (and block-start (marker-buffer block-start))
      (with-current-buffer (ogent-ui-request-buffer request)
        (ogent-ui--hide-src-block-at block-start)))))


(defun ogent-ui--error-message-string (error-message)
  "Return ERROR-MESSAGE as a display string."
  (ogent-provider-error-message-string error-message))

(defun ogent-ui--provider-access-error-p (error-message)
  "Return non-nil when ERROR-MESSAGE looks like a provider access failure."
  (ogent-provider-access-error-p error-message))

(defun ogent-ui--maybe-offer-provider-login (request error-message)
  "Schedule provider login offer for REQUEST when ERROR-MESSAGE qualifies."
  (let* ((model (ogent-ui-request-model request))
         (model-id (plist-get model :id))
         (backend (plist-get model :backend)))
    (ogent-provider-maybe-offer-login model-id backend error-message)))

(defun ogent-ui--maybe-store-zen-result-title (request)
  "Persist a derived Zen result title for REQUEST when Zen support is loaded."
  (when (and (plist-get (ogent-ui-request-context request) :zen-run)
             (fboundp 'ogent-zen-store-result-title))
    (when-let* ((buffer (ogent-ui-request-buffer request))
                (marker (ogent-ui-request-request-heading-pos request)))
      (when (and (buffer-live-p buffer)
                 (markerp marker)
                 (marker-position marker))
        (with-current-buffer buffer
          (ignore-errors
            (ogent-zen-store-result-title (marker-position marker))))))))

(defun ogent-ui--maybe-preview-zen-edit (request)
  "Preview a completed Zen edit REQUEST when it carries edit scope metadata."
  (when (and (plist-get (ogent-ui-request-context request) :zen-edit)
             (fboundp 'ogent-zen-preview-edit-from-request))
    (when-let* ((buffer (ogent-ui-request-buffer request))
                (marker (ogent-ui-request-request-heading-pos request)))
      (when (and (buffer-live-p buffer)
                 (markerp marker)
                 (marker-position marker))
        (with-current-buffer buffer
          (ignore-errors
            (ogent-zen-preview-edit-from-request
             (ogent-ui-request-context request)
             (marker-position marker))))))))

(defun ogent-ui--close-response (request &optional error-message final-status)
  "Finalize REQUEST, optionally including ERROR-MESSAGE.
FINAL-STATUS overrides the default terminal status.
The src block is already closed; this just updates status and folds.
Provides visual feedback via mode-line flash."
  (if (ogent-ui-request-closed request)
      (remhash (ogent-ui-request-id request) ogent-ui--request-table)
    (when-let ((message (and error-message
                             (ogent-ui--error-message-string error-message))))
      (ogent-ui--insert-error-block request message)
      (ogent-ui--update-status request (or final-status 'error))
      ;; Flash error
      (ogent-theme-flash 'error
                         (format "Request failed: %s"
                                 (truncate-string-to-width
                                  message 50 nil nil "...")))
      (ogent-ui--maybe-offer-provider-login request message))
    (unless error-message
      (ogent-ui--update-status request (or final-status 'done))
      (ogent-ui--maybe-store-zen-result-title request)
      (ogent-ui--maybe-preview-zen-edit request)
      ;; Flash success with latency info
      (let ((latency (ogent-ui--format-latency request)))
        (ogent-theme-flash 'success
                           (format "Response complete%s"
                                   (if latency (format " (%s)" latency) ""))))
      ;; Record the completion for the analytics eval loop (self-guards
      ;; on `ogent-analytics-enabled'; only successful responses count).
      ;; Analytics is a side channel: never let it break request close.
      (when (fboundp 'ogent-analytics-record-completion)
        (condition-case err
            (let ((model (ogent-ui-request-model request)))
              (ogent-analytics-record-completion
               (or (plist-get model :id) "unknown")
               (or (ogent-ui-request-prompt request) "")
               (or (ogent-ui--response-body-text request) "")
               (let ((preset (ogent-ui-request-preset request)))
                 (and preset (format "%s" preset)))))
          (error
           (message "ogent-analytics: failed to record completion: %s"
                    (error-message-string err))))))
    (ogent-ledger-record-request-finish request error-message)
    ;; Fold the prompt/context src block
    (ogent-ui--fold-prompt-block request)
    (setf (ogent-ui-request-closed request) t)
    ;; Save to history for retry
    (push request ogent-ui--request-history)
    (when (> (length ogent-ui--request-history) ogent-ui-request-history-max)
      (setq ogent-ui--request-history
            (seq-take ogent-ui--request-history ogent-ui-request-history-max)))
    (remhash (ogent-ui-request-id request) ogent-ui--request-table)
    ;; Fontify the response region for syntax highlighting (src blocks, etc.)
    ;; and align any Org tables that were streamed in
    (with-current-buffer (ogent-ui-request-buffer request)
      (let ((start (ogent-ui-request-response-pos request))
            (end (ogent-ui-request-marker request)))
        (when (and start end (markerp end) (marker-position end))
          (let ((end-pos (marker-position end)))
            (font-lock-flush start end-pos)
            ;; Align Org tables in the response region
            (when (derived-mode-p 'org-mode)
              (save-excursion
                (goto-char start)
                (while (re-search-forward "^[ \t]*|" end-pos t)
                  (org-table-align)
                  ;; Move past this table to avoid re-aligning
                  (goto-char (org-table-end)))))))))
    ;; Clean up auto-scroll hook if no more active requests in buffer
    (with-current-buffer (ogent-ui-request-buffer request)
      (unless (cl-some (lambda (r)
                         (eq (ogent-ui-request-buffer r)
                             (current-buffer)))
                       (ogent-ui-active-requests))
        (remove-hook 'post-command-hook #'ogent-ui--auto-scroll-post-command t)))
    ;; Clean up margin indicator after a short visible grace period.
    (when (fboundp 'ogent-status-clear-request)
      (run-with-timer 2.0 nil #'ogent-status-clear-request request))
    (run-hook-with-args 'ogent-after-request-hook
                        (ogent-ui-request-context request))))

(defun ogent-ui--gptel-tool-result-entry (entry)
  "Normalize one gptel tool-result ENTRY to (:name NAME :args ARGS :result RESULT)."
  (if (plist-member entry :result)
      (list :name (plist-get entry :name)
            :args (plist-get entry :args)
            :result (plist-get entry :result))
    (let* ((tool (nth 0 entry))
           (args (nth 1 entry))
           (result (nth 2 entry))
           (name (cond
                  ((and tool (fboundp 'gptel-tool-name))
                   (condition-case nil
                       (gptel-tool-name tool)
                     (error (format "%s" tool))))
                  ((and (consp tool) (plist-get tool :name))
                   (plist-get tool :name))
                  (tool (format "%s" tool))
                  (t "unknown"))))
      (list :name name :args args :result result))))

(defun ogent-ui--make-callback (request-id)
  "Return a gptel callback that streams into REQUEST-ID.
Handles both regular text responses and tool call responses."
  (lambda (text info)
    (when (bound-and-true-p ogent-ui-debug-stream-completion)
      (message "[ogent-debug] callback: request-id=%s text=%S text-type=%s null-text=%s info-keys=%s"
               request-id
               (if (stringp text) (truncate-string-to-width text 20 nil nil "...") text)
               (type-of text)
               (null text)
               (when (listp info)
                 (cl-loop for (k _v) on info by #'cddr collect k))))
    (let ((request (gethash request-id ogent-ui--request-table)))
      (when (bound-and-true-p ogent-ui-debug-stream-completion)
        (message "[ogent-debug] LOOKUP: request-id=%s found=%s table-size=%s info-status=%s"
                 request-id (if request t nil) (hash-table-count ogent-ui--request-table)
                 (plist-get info :status)))
      (when request
        ;; Handle gptel tool-call/tool-result responses
        ;; gptel sends (tool-call . pending-calls) when waiting for confirmation
        ;; or (tool-result . results) after execution
        (when (and (consp text) (memq (car text) '(tool-call tool-result)))
          (when (bound-and-true-p ogent-ui-debug-stream-completion)
            (message "[ogent-debug] tool response: type=%s data=%S" (car text) (cdr text)))
          (pcase (car text)
            ('tool-result
             ;; Tools were executed by gptel and fed back into the FSM.
             ;; Display the result, but do not close the request here: gptel
             ;; will make the follow-up model call and stream the final text.
             (dolist (entry (cdr text))
               (let* ((normalized (ogent-ui--gptel-tool-result-entry entry))
                      (tool-name (plist-get normalized :name))
                      (tool-args (plist-get normalized :args))
                      (tool-result (plist-get normalized :result)))
                 (ogent-ledger-record-tool-finish
                  (ogent-ui--tool-ledger-call tool-name tool-args)
                  tool-result nil nil
                  (ogent-ui--tool-ledger-effects tool-name))
                 (when-let ((marker (ogent-ui-request-marker request)))
                   (with-current-buffer (ogent-ui-request-buffer request)
                     (save-excursion
                       (goto-char marker)
                       (ogent-ui--insert-tool-block
                        tool-name tool-args (or tool-result "[No result]"))
                       (set-marker marker (point))))))))
            ('tool-call
             ;; Tools pending confirmation - gptel owns resuming the request
             ;; through the callback it supplies in the pending call entry.
             (ogent-ui--update-status request 'tool))))
        ;; Native gptel reports :tool-use on the first response before it
        ;; enters the TOOL state.  Do not execute these ourselves: doing so
        ;; closes ogent before gptel can inject the tool results and ask the
        ;; model for the final answer.
        (when (and (listp info) (plist-get info :tool-use)
                   (not (and (consp text)
                             (memq (car text) '(tool-call tool-result)))))
          (setf (ogent-ui-request-handled-tool-use request)
                (plist-get info :tool-use))
          (ogent-ui--update-status request 'tool))
        ;; Update status based on what we're receiving
        ;; Note: gptel may pass t rather than a string in some cases
        (when (and (stringp text) (> (length text) 0))
          (unless (eq (ogent-ui-request-status request) 'type)
            (ogent-ui--update-status request 'type))
          (ogent-ui--append-response request text))
        (cond
         ((and (listp info) (plist-get info :error))
          (when (bound-and-true-p ogent-ui-debug-stream-completion)
            (message "[ogent-debug] closing due to error: %s" (plist-get info :error)))
          (ogent-ui--close-response request (plist-get info :error)))
         ;; Done when text is not a string (gptel sends t or nil to signal
         ;; completion).  But a (tool-call ...) / (tool-result ...) cons is
         ;; an intermediate payload, not a completion signal; closing on it
         ;; would drop the model's continuation after the tool round.
         ((and (not (stringp text))
               (not (and (consp text)
                         (memq (car text) '(tool-call tool-result)))))
          (let ((tool-active (and (listp info)
                                  (or (plist-get info :tool-pending)
                                      (plist-get info :tool-use)))))
            (when (bound-and-true-p ogent-ui-debug-stream-completion)
              (message "[ogent-debug] stream complete (text=%s), tool-active=%s, closing=%s"
                       text tool-active (not tool-active)))
            (unless tool-active
              (ogent-ui--close-response request)))))))))

(defvar ogent-ui-debug-stream-completion nil
  "When non-nil, log debug info about stream completion detection.")

(defun ogent-ui--gptel-post-response-handler (start _end)
  "Handle gptel stream completion for ogent requests.
START is the response start position.  This function is added to
`gptel-post-response-functions' as a fallback to detect when streaming
completes, in case the callback-based detection doesn't trigger."
  (when (bound-and-true-p ogent-ui-debug-stream-completion)
    (message "[ogent-debug] post-response-handler called: start=%s buffer=%s"
             start (current-buffer)))
  ;; Find any unclosed request in the current buffer whose marker matches START
  (let ((found-match nil))
    (maphash (lambda (id request)
               (let* ((closed (ogent-ui-request-closed request))
                      (req-buffer (ogent-ui-request-buffer request))
                      (handle (ogent-ui-request-gptel-handle request))
                      (handle-pos (when (markerp handle) (marker-position handle))))
                 (when (bound-and-true-p ogent-ui-debug-stream-completion)
                   (message "[ogent-debug] checking request %s: closed=%s buffer-match=%s handle=%s handle-pos=%s start=%s"
                            id closed (eq req-buffer (current-buffer)) handle handle-pos start))
                 (when (and (not closed)
                            (eq req-buffer (current-buffer))
                            handle-pos
                            (= handle-pos start))
                   (setq found-match t)
                   (when (bound-and-true-p ogent-ui-debug-stream-completion)
                     (message "[ogent-debug] MATCH! closing request %s" id))
                   (ogent-ui--close-response request))))
             ogent-ui--request-table)
    (when (and (bound-and-true-p ogent-ui-debug-stream-completion) (not found-match))
      (message "[ogent-debug] NO MATCH found for start=%s in buffer %s"
               start (current-buffer)))))

;; Register the post-response handler with gptel (both now and after load)
(defun ogent-ui--register-gptel-hook ()
  "Register ogent handler with gptel-post-response-functions."
  (add-hook 'gptel-post-response-functions #'ogent-ui--gptel-post-response-handler))

(if (featurep 'gptel)
    (ogent-ui--register-gptel-hook)
  (with-eval-after-load 'gptel
    (ogent-ui--register-gptel-hook)))






(declare-function ogent-debug-log-tool-call "ogent-debug" (tool-call result duration))



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
             "Backend %S for model %s is not loaded. Require the backend module or update `ogent-model-registry'."
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
  "Dispatch RAW-PROMPT using MODELS from SOURCE-BUFFER."
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
                    (user-error "ogent-response-function must return an `ogent-ui-request'"))
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

;;;###autoload (autoload 'ogent-request "ogent" nil t)
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

;;; Tool and Reasoning Block Support




;;; Tool Drawer Display









;;; Streaming Tool Drawer Support












;;; Inline Diff Display for Edit Proposals




























;;; Error Collection and Display

(defun ogent-ui--record-error (request error-message)
  "Record an error for REQUEST with ERROR-MESSAGE."
  (let* ((model (ogent-ui-request-model request))
         (model-id (plist-get model :id))
         (context (ogent-ui-request-context request))
         (context-summary (ogent-ui--format-context context))
         (record (list :timestamp (current-time)
                       :model model-id
                       :error error-message
                       :request-id (ogent-ui-request-id request)
                       :prompt (ogent-ui-request-prompt request)
                       :context context-summary)))
    (push record ogent-ui--error-history)
    ;; Limit history size
    (when (> (length ogent-ui--error-history) 50)
      (setq ogent-ui--error-history (seq-take ogent-ui--error-history 50)))
    record))

(defun ogent-ui--format-error-for-display (error-record)
  "Format ERROR-RECORD as an Org-mode heading with buttons."
  (let* ((timestamp (plist-get error-record :timestamp))
         (model (plist-get error-record :model))
         (error-msg (plist-get error-record :error))
         (request-id (plist-get error-record :request-id))
         (prompt (plist-get error-record :prompt)))
    (format "** [%s] %s\nError: %s\nRequest ID: %s\nPrompt: %s\n\n"
            (format-time-string "%Y-%m-%d %H:%M:%S" timestamp)
            (or model "unknown")
            (or error-msg "unknown error")
            (or request-id "unknown")
            (if prompt
                (truncate-string-to-width prompt 100 nil nil "...")
              "(no prompt)"))))

(defun ogent-ui--surface-error (request error-message)
  "Display error prominently for REQUEST with ERROR-MESSAGE.
Records the error and displays it in the *ogent-errors* buffer."
  (ogent-ui--record-error request error-message)
  (ogent-ui--update-error-buffer))

(defun ogent-ui--update-error-buffer ()
  "Update the *ogent-errors* buffer with current error history."
  (let ((buffer (get-buffer-create ogent-errors-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert "#+title: ogent Errors\n\n")
        (insert "* Error History\n\n")
        (if ogent-ui--error-history
            (dolist (error-record ogent-ui--error-history)
              (insert (ogent-ui--format-error-for-display error-record)))
          (insert "No errors recorded.\n"))
        (goto-char (point-min))
        (view-mode 1)))
    ;; Display buffer if not visible
    (unless (and ogent-ui--error-window
                 (window-live-p ogent-ui--error-window)
                 (eq (window-buffer ogent-ui--error-window) buffer))
      (setq ogent-ui--error-window
            (display-buffer buffer
                            '((display-buffer-in-side-window)
                              (side . bottom)
                              (window-height . 8)
                              (preserve-size . (nil . t))))))))

;;;###autoload
(defun ogent-show-errors ()
  "Display the ogent errors buffer."
  (interactive)
  (ogent-ui--update-error-buffer)
  (select-window ogent-ui--error-window))

;;;###autoload
(defun ogent-clear-errors ()
  "Clear the ogent error history."
  (interactive)
  (when (yes-or-no-p "Clear all error history? ")
    (setq ogent-ui--error-history nil)
    (let ((buffer (get-buffer ogent-errors-buffer-name)))
      (when buffer
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (org-mode)
            (insert "#+title: ogent Errors\n\n")
            (insert "* Error History\n\nNo errors recorded.\n")
            (goto-char (point-min))))))
    (when (and ogent-ui--error-window
               (window-live-p ogent-ui--error-window))
      (delete-window ogent-ui--error-window)
      (setq ogent-ui--error-window nil))
    (message "Error history cleared")))

;;; Cancellation and Retry


(declare-function gptel-abort "ext:gptel" (buffer))

(defun ogent-ui--abort-request (request)
  "Abort REQUEST if it's still active."
  (unless (ogent-ui-request-closed request)
    (let ((handle (ogent-ui-request-gptel-handle request)))
      ;; gptel uses buffer-based abort; try if available
      (when (and handle (fboundp 'gptel-abort))
        (ignore-errors
          (gptel-abort (ogent-ui-request-buffer request)))))
    (ogent-ui--close-response request "Request aborted by user" 'aborted)))

(defun ogent-ui--get-partial-response (request)
  "Extract the partial response text accumulated so far for REQUEST."
  (let ((start (ogent-ui-request-response-pos request))
        (end (ogent-ui-request-marker request))
        (buffer (ogent-ui-request-buffer request)))
    (when (and start end buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (buffer-substring-no-properties
         (if (markerp start) (marker-position start) start)
         (if (markerp end) (marker-position end) end))))))

(defun ogent-ui--pause-request (request)
  "Pause REQUEST, storing its partial response for later resume.
Stops the HTTP stream but keeps the request in a resumable state."
  (unless (or (ogent-ui-request-closed request)
              (eq (ogent-ui-request-status request) 'paused))
    ;; Store partial response before aborting
    (let ((partial (ogent-ui--get-partial-response request)))
      (setf (ogent-ui-request-paused-response request) partial))
    ;; Abort the gptel connection
    (let ((handle (ogent-ui-request-gptel-handle request)))
      (when (and handle (fboundp 'gptel-abort))
        (ignore-errors
          (gptel-abort (ogent-ui-request-buffer request)))))
    ;; Mark as paused (not closed - can be resumed)
    (ogent-ui--update-status request 'paused)
    ;; Insert pause indicator in buffer
    (let ((marker (ogent-ui-request-marker request)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (save-excursion
            (goto-char marker)
            (insert "\n⏸ [Paused - use ogent-resume-request to continue]\n")
            (set-marker marker (point))))))))

(defun ogent-ui--resume-request (request)
  "Resume a paused REQUEST by continuing from where it left off.
Creates a new request with the partial response as context."
  (when (eq (ogent-ui-request-status request) 'paused)
    (let* ((partial (ogent-ui-request-paused-response request))
           (model (ogent-ui-request-model request))
           (preset (ogent-ui-request-preset request))
           (buffer (ogent-ui-request-buffer request))
           ;; Create continuation prompt
           (continuation-prompt
            (format "Continue from where you left off. Your previous partial response was:\n\n%s\n\n---\nPlease continue naturally from this point, completing your response to the original request."
                    (or partial "[No partial response captured]"))))
      ;; Mark old request as resumed (close it)
      (ogent-ui--update-status request 'done)
      (setf (ogent-ui-request-closed request) t)
      (remhash (ogent-ui-request-id request) ogent-ui--request-table)
      ;; Remove the pause indicator
      (let ((marker (ogent-ui-request-marker request)))
        (when (and marker (marker-buffer marker))
          (with-current-buffer buffer
            (save-excursion
              (goto-char marker)
              (when (re-search-backward "⏸ \\[Paused" nil t)
                (delete-region (line-beginning-position)
                               (min (1+ (line-end-position)) (point-max))))))))
      ;; Create new request to continue
      (with-current-buffer buffer
        (goto-char (point-max))
        (ogent-request continuation-prompt
                       (list (plist-get model :id))
                       preset)))))

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
(defun ogent-pause-request (&optional request-id)
  "Pause the request with REQUEST-ID, or prompt for one if interactive.
Paused requests can be resumed with `ogent-resume-request'.
The partial response is stored for continuation."
  (interactive)
  (let* ((requests (ogent-ui-active-requests))
         (id (or request-id
                 (when requests
                   (completing-read
                    "Pause request: "
                    (mapcar #'ogent-ui-request-id requests)
                    nil t))))
         (request (and id (gethash id ogent-ui--request-table))))
    (if request
        (progn
          (ogent-ui--pause-request request)
          (message "Paused request %s - use ogent-resume-request to continue" id))
      (message "No active request to pause"))))

(defun ogent-ui-paused-requests ()
  "Return a list of all paused requests."
  (let (requests)
    (maphash (lambda (_id request)
               (when (eq (ogent-ui-request-status request) 'paused)
                 (push request requests)))
             ogent-ui--request-table)
    (nreverse requests)))

;;;###autoload
(defun ogent-resume-request (&optional request-id)
  "Resume a paused request with REQUEST-ID.
Continues from where the request left off by sending a new request
with the partial response as context."
  (interactive)
  (let* ((paused (ogent-ui-paused-requests))
         (id (or request-id
                 (when paused
                   (completing-read
                    "Resume request: "
                    (mapcar #'ogent-ui-request-id paused)
                    nil t))))
         (request (and id (gethash id ogent-ui--request-table))))
    (if (and request (eq (ogent-ui-request-status request) 'paused))
        (progn
          (ogent-ui--resume-request request)
          (message "Resuming request %s" id))
      (message "No paused request to resume"))))

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
