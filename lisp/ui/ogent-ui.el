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
(require 'ogent-ui-engine)

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





;;; Conversation History














(when (and (boundp 'ogent-response-function)
           (eq ogent-response-function #'ogent-ui-insert-response-block))
  (setq ogent-response-function #'ogent-ui-prepare-response-block))











(declare-function ogent-analytics-start-request "ogent-analytics")
(declare-function ogent-analytics-estimate-tokens "ogent-analytics" (text))
(declare-function ogent-analytics-first-token "ogent-analytics")
(declare-function ogent-analytics-record-completion "ogent-analytics"
                  (model prompt response &optional template))




















;; Register the post-response handler with gptel (both now and after load)

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





;;;###autoload (autoload 'ogent-show-errors "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-clear-errors "ogent-ui" nil t)

;;; Cancellation and Retry


(declare-function gptel-abort "ext:gptel" (buffer))





;;;###autoload (autoload 'ogent-abort-request "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-pause-request "ogent-ui" nil t)


;;;###autoload (autoload 'ogent-resume-request "ogent-ui" nil t)

;;;###autoload (autoload 'ogent-retry-request "ogent-ui" nil t)

(provide 'ogent-ui)

;;; ogent-ui.el ends here
