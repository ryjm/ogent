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
(require 'ogent-ui-status)

;; Forward declarations for source context
(declare-function ogent-context-build-with-source "ogent-context")
(declare-function ogent-context--format-source-context "ogent-context")

;; Silence byte-compiler for functions that may not be loaded at compile time
(declare-function ogent-presets-available "ogent-models")
(declare-function ogent-preset-get "ogent-models")

;; gptel integration
(declare-function gptel-backend-name "ext:gptel")
(declare-function gptel-backend-models "ext:gptel")
(declare-function gptel--model-name "ext:gptel")
(declare-function gptel-backend-p "ext:gptel")
(defvar gptel--known-backends)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-stream)
(defvar gptel-tools)
(defvar gptel-use-tools)

;; OAuth integration - for detecting when system message is locked
(declare-function ogent-anthropic-oauth-using-bearer-p "ogent-anthropic-oauth")

;; ogent-tools integration
(declare-function ogent-tools-enabled-list "ogent-models")
(declare-function ogent-tool-spec-get "ogent-models")

;;; Org-mode Output Formatting

(defcustom ogent-org-format-responses t
  "When non-nil, instruct LLM to format responses as Org-mode.
This adds a system directive to requests when the target buffer
is in Org-mode, ensuring code blocks use #+begin_src syntax,
headings use * instead of #, etc."
  :type 'boolean
  :group 'ogent-mode)

(defcustom ogent-auto-scroll t
  "When non-nil, auto-scroll window to follow streaming responses.
During a streaming response, the window will scroll to show new content
as it arrives. Auto-scroll stops if the user manually scrolls away from
the bottom, and resumes when they scroll back to the bottom or when a
new request starts."
  :type 'boolean
  :group 'ogent-mode)

(defconst ogent-org-format-directive
  "Format your response using Org-mode syntax:
- Use * for headings (not # markdown headings)
- Use #+begin_src LANG / #+end_src for code blocks (not ``` fences)
- Use - or + for unordered lists
- Use 1. for ordered lists
- Use [[url][description]] for links
- Use *bold*, /italic/, =code=, ~verbatim~ for inline formatting
- Use | for tables with |---| separator rows

Do NOT use markdown syntax. Use Org-mode syntax exclusively."
  "System directive instructing the LLM to format output as Org-mode.")

;;; Tool Approval System

(defcustom ogent-tool-allow-list nil
  "List of patterns for auto-approved tool calls.
Each pattern is a string like \"ToolName(arg:pattern)\" where:
- ToolName matches the tool name exactly
- arg:pattern matches an argument (supports glob wildcards)
- * inside parens matches any arguments
- No parens means any invocation of that tool is allowed

Examples:
  \"read-file\" - allow all read-file calls
  \"bash(command:git *)\" - allow bash with git commands
  \"bash(command:make test:*)\" - allow make test and variations
  \"glob(*)\" - allow all glob calls

Patterns are case-sensitive and checked in order."
  :type '(repeat string)
  :group 'ogent-mode)

(defcustom ogent-tool-require-approval t
  "When non-nil, prompt for approval before executing tools.
Tools matching `ogent-tool-allow-list' are auto-approved.
When nil, all tools execute without prompting."
  :type 'boolean
  :group 'ogent-mode)

(defun ogent-tool--pattern-match-p (pattern tool-name args)
  "Return non-nil if TOOL-NAME with ARGS matches PATTERN.
PATTERN format: \"tool-name\" or \"tool-name(arg:glob)\"."
  (if (string-match "^\\([^(]+\\)\\(?:(\\(.*\\))\\)?$" pattern)
      (let ((pat-name (match-string 1 pattern))
            (pat-args (match-string 2 pattern)))
        (and (string= pat-name tool-name)
             (or (null pat-args)
                 (string= pat-args "*")
                 (ogent-tool--args-match-p pat-args args))))
    nil))

(defun ogent-tool--args-match-p (arg-pattern args)
  "Return non-nil if ARG-PATTERN matches ARGS plist.
ARG-PATTERN format: \"argname:glob\" or \"argname:glob,other:glob\"."
  (let ((patterns (split-string arg-pattern ",")))
    (cl-every
     (lambda (pat)
       (if (string-match "^\\([^:]+\\):\\(.*\\)$" pat)
           (let* ((arg-name (match-string 1 pat))
                  (glob (match-string 2 pat))
                  ;; Try both :keyword and plain symbol forms
                  (arg-keyword (intern (concat ":" arg-name)))
                  (arg-val (plist-get args arg-keyword)))
             (if arg-val
                 (ogent-tool--glob-match-p glob (format "%s" arg-val))
               ;; Arg not present, pattern fails unless glob is *
               (string= glob "*")))
         t))
     patterns)))

(defun ogent-tool--glob-match-p (pattern string)
  "Return non-nil if PATTERN (glob-style) matches STRING.
Supports * as wildcard."
  ;; Split pattern on *, quote each part, join with .*
  (let* ((parts (split-string pattern "\\*"))
         (quoted-parts (mapcar #'regexp-quote parts))
         (regexp (concat "^" (string-join quoted-parts ".*") "$")))
    (string-match-p regexp string)))

(defun ogent-tool--allowed-p (tool-name args)
  "Return non-nil if TOOL-NAME with ARGS is in the allow-list."
  (cl-some (lambda (pattern)
             (ogent-tool--pattern-match-p pattern tool-name args))
           ogent-tool-allow-list))

(defun ogent-tool--format-preview (tool-name args)
  "Format a preview string for TOOL-NAME with ARGS."
  (let ((preview (format "Tool: %s\n" tool-name)))
    (when args
      (setq preview (concat preview "Arguments:\n"))
      (let ((pairs nil))
        (while args
          (push (format "  %s: %s" (car args) (cadr args)) pairs)
          (setq args (cddr args)))
        (setq preview (concat preview (string-join (nreverse pairs) "\n")))))
    preview))

(defun ogent-tool--prompt-approval (tool-name args)
  "Prompt user to approve TOOL-NAME with ARGS.
Returns symbol: `approve', `deny', `always', or `never'."
  (let* ((preview (ogent-tool--format-preview tool-name args))
         (prompt (format "%s\n\nAllow? (y)es, (n)o, (a)lways, n(e)ver: " preview))
         (response (read-char-choice prompt '(?y ?n ?a ?e))))
    (pcase response
      (?y 'approve)
      (?n 'deny)
      (?a 'always)
      (?e 'never))))

(defun ogent-tool--add-to-allow-list (tool-name args)
  "Add TOOL-NAME to `ogent-tool-allow-list'.
If ARGS is non-nil, creates a pattern matching those specific args."
  (let ((pattern (if (and args (plist-get args :command))
                     ;; For bash, include the command prefix
                     (let ((cmd (plist-get args :command)))
                       (if (string-match "^\\([^ ]+\\)" cmd)
                           (format "%s(command:%s *)" tool-name (match-string 1 cmd))
                         tool-name))
                   tool-name)))
    (unless (member pattern ogent-tool-allow-list)
      (customize-save-variable 'ogent-tool-allow-list
                               (cons pattern ogent-tool-allow-list)))))

(defvar ogent-tool--denied-tools nil
  "List of tool patterns permanently denied in this session.")

(defun ogent-tool--add-to-deny-list (tool-name)
  "Add TOOL-NAME to the session deny list."
  (unless (member tool-name ogent-tool--denied-tools)
    (push tool-name ogent-tool--denied-tools)))

(defun ogent-tool--denied-p (tool-name)
  "Return non-nil if TOOL-NAME is in the session deny list."
  (member tool-name ogent-tool--denied-tools))

;;; gptel-style Variable Scope Management

(defvar-local ogent--set-buffer-locally nil
  "When non-nil, set model parameters buffer-locally.")

(defvar-local ogent--auto-scroll-enabled nil
  "Buffer-local flag tracking if auto-scroll is active for current request.
Set to t when a new request starts (if `ogent-auto-scroll' is enabled).
Set to nil when user scrolls away from bottom.
Re-enabled when user scrolls back to bottom.")

(defun ogent-ui--auto-scroll-post-command ()
  "Post-command hook to re-enable auto-scroll when user scrolls to bottom.
Only runs when auto-scroll is globally enabled but locally disabled,
and there's an active request."
  (when (and ogent-auto-scroll
             (not ogent--auto-scroll-enabled)
             (ogent-ui-active-requests))
    ;; User might have scrolled back to bottom - check and re-enable
    (when (ogent-ui--at-window-bottom-p)
      (setq ogent--auto-scroll-enabled t))))

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

(defvar ogent-ui--selected-preset nil
  "The currently selected preset name (string), or nil for no preset.")

;; Forward declaration for ogent-response-function (defined as defcustom later)
(defvar ogent-response-function)

;; Request struct must be defined early for setf accessors
(cl-defstruct ogent-ui-request
  id model context prompt buffer marker closed preset
  status start-time end-time gptel-handle source-buffer
  block-start response-pos)

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

;;; Direct Send Suffix

(defun ogent--get-effective-prompt ()
  "Get the prompt to send: transient input, region, or minibuffer."
  (or ogent--transient-prompt
      (when (use-region-p)
        (buffer-substring-no-properties (region-beginning) (region-end)))
      (read-string "Prompt: ")))

(defun ogent--send-with-current-model (prompt)
  "Send PROMPT using current gptel-backend and gptel-model.
Captures source buffer context and sends to companion without switching focus."
  (let* ((source-buffer (current-buffer))
         (region-start (when (use-region-p) (region-beginning)))
         (region-end (when (use-region-p) (region-end)))
         (companion (ogent-ui--ensure-companion-context))
         (extracted (ogent-ui--extract-preset-cookies prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or (car cookie-presets) ogent-ui--selected-preset)))
    (with-current-buffer companion
      (let* ((context (ogent-context-build-with-source
                       source-buffer region-start region-end))
             (model (list :id (if (fboundp 'gptel--model-name)
                                  (gptel--model-name gptel-model)
                                gptel-model)
                          :backend gptel-backend
                          :stream? gptel-stream))
             (request (funcall ogent-response-function clean-prompt context model)))
        (unless (ogent-ui-request-p request)
          (user-error "ogent-response-function must return an `ogent-ui-request'"))
        (setf (ogent-ui-request-preset request) effective-preset)
        ;; Store source buffer reference for inline edits
        (setf (ogent-ui-request-source-buffer request) source-buffer)
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
  (let* ((source-ctx (plist-get context :source-context))
         (root (plist-get context :root))
         (ancestors (plist-get context :ancestors))
         (dependencies (plist-get context :dependencies))
         (handles (plist-get context :handles))
         (lines nil))
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
When invoked from a non-Org buffer, includes source buffer context."
  (interactive)
  (let* ((source-buffer (current-buffer))
         (region-start (when (use-region-p) (region-beginning)))
         (region-end (when (use-region-p) (region-end)))
         (companion (ogent-ui--ensure-companion-context)))
    (with-current-buffer companion
      (let* ((context (ogent-context-build-with-source
                       source-buffer region-start region-end))
             (summary (ogent-ui--format-context context))
             (buffer (ogent-ui--context-buffer)))
        (with-current-buffer buffer
          (let ((previous ogent-ui--previous-context))
            (insert summary)
            (goto-char (point-min))
            ;; Apply diff highlighting if we have previous context
            (when previous
              (let ((diff (ogent-ui--diff-strings previous summary)))
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
            (setq ogent-ui--previous-context summary)))
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
        (let* ((context (ogent-context-build-with-source
                         source-buffer region-start region-end))
               (summary (ogent-ui--format-context context))
               (buffer (ogent-ui--context-buffer)))
          (with-current-buffer buffer
            (insert summary)
            (goto-char (point-min)))
          ;; Use side-window with slot -1 to appear above transient (slot 0)
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
      (format "Model: %s:%s"
              (if (fboundp 'gptel-backend-name)
                  (gptel-backend-name gptel-backend)
                "backend")
              (if (fboundp 'gptel--model-name)
                  (gptel--model-name gptel-model)
                gptel-model))
    "Model: not configured"))

;;;###autoload (autoload 'ogent-prompt-dispatch "ogent" nil t)
(transient-define-prefix ogent-prompt-dispatch ()
  "Prompt dispatcher for ogent requests.
Shows current model, allows changing it, and sends prompts to LLM."
  [:description ogent--format-model-header
                ["Options"
                 (ogent--infix-provider)
                 (ogent--infix-prompt)
                 (ogent--infix-tools)]
                ["Context"
                 ("c" "Preview context" ogent-context-preview-toggle :transient t)
                 ("C" "Codemap" ogent-codemap-buffer)]]
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
  "Insert a nested headline structure for a request with MODEL.
Creates a top-level '* Request: <truncated prompt>' headline containing
the prompt/context src block and a nested '** Response' sub-headline
where streamed content goes. This mimics Claude Code's conversation
structure using org-mode idioms.
Returns a plist containing a streaming marker and block-start marker."
  ;; Always append at end for session buffers, otherwise use current position
  (if ogent-session-buffer-p
      (progn
        (goto-char (point-max))
        (unless (bolp) (insert "\n")))
    (org-back-to-heading t)
    (org-end-of-subtree t t)
    (unless (bolp) (insert "\n")))
  (let* ((model-id (plist-get model :id))
         (backend (plist-get model :backend))
         (summary (ogent-ui--format-context context))
         ;; Truncate prompt for headline (max 60 chars)
         (prompt-summary (truncate-string-to-width prompt 60 nil nil "..."))
         request-heading-pos
         block-start
         response-heading-pos)
    ;; Insert request headline as child of Session (level 2)
    (setq request-heading-pos (point-marker))
    (insert (format "** Request: %s\n" prompt-summary))
    ;; Insert the prompt/context src block under the request headline
    (setq block-start (point-marker))
    (insert (format "#+begin_src text :model %s%s :status waiting\n"
                    model-id
                    (if backend
                        (format " :backend %s" (ogent-ui--backend-label backend))
                      "")))
    (insert (format "Prompt:\n%s\n\nContext Summary:\n%s\n"
                    prompt summary))
    (insert "#+end_src\n\n")
    ;; Fold the context src block immediately
    (save-excursion
      (goto-char block-start)
      (when (and (derived-mode-p 'org-mode)
                 (fboundp 'org-fold-hide-block-toggle))
        (org-fold-hide-block-toggle 'hide)))
    ;; Insert Response sub-headline as child of Request (level 3)
    (setq response-heading-pos (point))
    (insert "*** Response\n")
    (let ((marker (copy-marker (point) t)))
      (list :marker marker
            :block-start block-start
            :response-pos response-heading-pos
            :request-heading-pos request-heading-pos))))

(defun ogent-ui-register-request (request)
  "Register REQUEST in the active request table."
  (setf (ogent-ui-request-start-time request) (current-time))
  (setf (ogent-ui-request-status request) 'wait)
  (puthash (ogent-ui-request-id request) request ogent-ui--request-table)
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
                   :response-pos (plist-get block :response-pos))))
    ;; Note: :request-heading-pos is available in block but not stored in struct
    ;; as it's not needed for current functionality
    (ogent-ui-register-request request)))

(when (and (boundp 'ogent-response-function)
           (eq ogent-response-function #'ogent-ui-insert-response-block))
  (setq ogent-response-function #'ogent-ui-prepare-response-block))

(defun ogent-ui--at-window-bottom-p (&optional window)
  "Return non-nil if WINDOW is scrolled to show the bottom.
WINDOW defaults to the selected window. This checks if `window-end'
is at or near `point-max', allowing for a small margin."
  (let ((win (or window (selected-window))))
    (when (window-live-p win)
      (with-selected-window win
        (>= (window-end win t) (- (point-max) 10))))))

(defun ogent-ui--scroll-to-bottom (&optional window)
  "Scroll WINDOW to show the bottom of the buffer.
WINDOW defaults to the selected window."
  (let ((win (or window (selected-window))))
    (when (window-live-p win)
      (with-selected-window win
        (goto-char (point-max))
        (recenter -1)))))

(defcustom ogent-shift-response-headings t
  "When non-nil, shift org headings in LLM responses to nest under Response.
LLM responses appear under a `*** Response' heading (level 3).
When this is enabled, any org headings in the response are shifted
by 3 levels so they remain nested under Response.

For example, `* Heading' becomes `**** Heading' (level 4)."
  :type 'boolean
  :group 'ogent-mode)

(defconst ogent-ui--response-heading-level 3
  "The org heading level of the Response headline.
Used to calculate how much to shift headings in LLM responses.")

(defun ogent-ui--shift-org-headings (text)
  "Shift org headings in TEXT to nest under the Response heading.
Headings are shifted by `ogent-ui--response-heading-level' levels.
For example, `* Heading' becomes `**** Heading'.

This prevents LLM-generated headings from breaking the session
buffer's org hierarchy."
  (if (not ogent-shift-response-headings)
      text
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      ;; Match org headings: line start, one or more *, then space or EOL
      ;; We need to be careful not to match emphasis like *bold*
      (while (re-search-forward "^\\(\\*+\\)\\([ \t]\\|$\\)" nil t)
        (let* ((stars (match-string 1))
               (suffix (match-string 2))
               (new-stars (make-string
                           (+ (length stars) ogent-ui--response-heading-level)
                           ?*)))
          (replace-match (concat new-stars suffix) t t)))
      (buffer-string))))

(defun ogent-ui--append-response (request chunk)
  "Append CHUNK to REQUEST's response block.
If `ogent-auto-scroll' is enabled and the user hasn't scrolled away,
automatically scroll the window to show new content.

Org headings in the response are shifted to nest under the Response
heading (see `ogent-shift-response-headings')."
  (when (and (stringp chunk) (> (length chunk) 0))
    (let ((marker (ogent-ui-request-marker request))
          (processed-chunk (ogent-ui--shift-org-headings chunk)))
      (when (and marker (marker-buffer marker))
        (with-current-buffer (ogent-ui-request-buffer request)
          (save-excursion
            (goto-char marker)
            (insert processed-chunk)
            (set-marker marker (point)))
          ;; Auto-scroll if enabled and we're tracking this request
          (when (and ogent-auto-scroll
                     ogent--auto-scroll-enabled)
            (let ((window (get-buffer-window (current-buffer))))
              (when window
                ;; Always scroll to bottom during streaming - don't disable
                ;; based on window position since insertion moves point
                (ogent-ui--scroll-to-bottom window)))))))))


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
  (when (eq new-status 'done)
    (setf (ogent-ui-request-end-time request) (current-time)))
  (ogent-ui--update-block-header request)
  ;; Update margin indicator
  (when (fboundp 'ogent-status-update-indicator)
    (ogent-status-update-indicator request new-status)))

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

(defun ogent-ui--fold-prompt-block (request)
  "Fold the prompt/context src block for REQUEST after response completes."
  (let ((block-start (ogent-ui-request-block-start request)))
    (when (and block-start (marker-buffer block-start))
      (with-current-buffer (ogent-ui-request-buffer request)
        (save-excursion
          (goto-char block-start)
          (when (and (looking-at "^#\\+begin_src")
                     (derived-mode-p 'org-mode)
                     (fboundp 'org-fold-hide-block-toggle))
            ;; Fold the src block
            (org-fold-hide-block-toggle 'hide)))))))

(defcustom ogent-ui-request-history-max 20
  "Maximum number of closed requests to keep in history."
  :type 'integer
  :group 'ogent-mode)

(defun ogent-ui--close-response (request &optional error-message)
  "Finalize REQUEST, optionally including ERROR-MESSAGE.
The src block is already closed; this just updates status and folds."
  (when error-message
    (ogent-ui--insert-error-block request error-message)
    (ogent-ui--update-status request 'error))
  (unless (ogent-ui-request-closed request)
    (unless error-message
      (ogent-ui--update-status request 'done))
    ;; Fold the prompt/context src block
    (ogent-ui--fold-prompt-block request)
    (setf (ogent-ui-request-closed request) t)
    ;; Save to history for retry
    (push request ogent-ui--request-history)
    (when (> (length ogent-ui--request-history) ogent-ui-request-history-max)
      (setq ogent-ui--request-history
            (seq-take ogent-ui--request-history ogent-ui-request-history-max))))
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
  ;; Clean up margin indicator (after a delay to keep it visible briefly)
  (when (fboundp 'ogent-status-clear-request)
    (run-with-timer 2.0 nil #'ogent-status-clear-request request))
  (run-hook-with-args 'ogent-after-request-hook (ogent-ui-request-context request)))

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
             ;; Tools were executed by gptel, display results
             (dolist (result (cdr text))
               (let ((tool-name (plist-get result :name))
                     (tool-args (plist-get result :args))
                     (tool-result (plist-get result :result)))
                 (ogent-ui--insert-tool-block tool-name tool-args
                                              (or tool-result "[No result]")))))
            ('tool-call
             ;; Tools pending confirmation - gptel handles this
             (ogent-ui--update-status request 'tool))))
        ;; Check for tool calls in info plist (legacy/fallback)
        (when (and (listp info) (plist-get info :tool-use)
                   (not (and (consp text) (memq (car text) '(tool-call tool-result)))))
          (ogent-ui--handle-tool-calls request (plist-get info :tool-use) info))
        ;; Update status based on what we're receiving
        ;; Note: gptel may pass t instead of a string in some cases
        (when (and (stringp text) (> (length text) 0))
          (unless (eq (ogent-ui-request-status request) 'type)
            (ogent-ui--update-status request 'type))
          (ogent-ui--append-response request text))
        (cond
         ((and (listp info) (plist-get info :error))
          (when (bound-and-true-p ogent-ui-debug-stream-completion)
            (message "[ogent-debug] closing due to error: %s" (plist-get info :error)))
          (ogent-ui--close-response request (plist-get info :error)))
         ;; Done when text is not a string (gptel sends t or nil to signal completion)
         ;; But NOT when there are pending tool calls
         ((not (stringp text))
          (let ((tool-pending (and (listp info) (plist-get info :tool-pending))))
            (when (bound-and-true-p ogent-ui-debug-stream-completion)
              (message "[ogent-debug] stream complete (text=%s), tool-pending=%s, closing=%s"
                       text tool-pending (not tool-pending)))
            (unless tool-pending
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

(defun ogent-ui--handle-tool-calls (request tool-calls _info)
  "Handle TOOL-CALLS from gptel response for REQUEST.
Each tool call is checked for approval, then executed if approved.
Edit tools (write-file, edit-file) show a diff preview for accept/reject.
Results are displayed in the buffer."
  (let ((buffer (ogent-ui-request-buffer request)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (or (ogent-ui-request-response-pos request) (point-max)))
        (dolist (tool-call tool-calls)
          ;; Debug: log the raw tool-call structure
          (when (bound-and-true-p ogent-ui-debug-stream-completion)
            (message "[ogent-debug] tool-call raw: %S" tool-call))
          (let* ((tool-name (plist-get tool-call :name))
                 ;; gptel normalizes to :args, but check :input/:arguments as fallback
                 (tool-args (or (plist-get tool-call :args)
                                (plist-get tool-call :input)
                                (plist-get tool-call :arguments)))
                 (approval (ogent-ui--check-tool-approval tool-name tool-args)))
            (pcase approval
              ('approved
               ;; For edit tools, show diff preview instead of executing
               (if (ogent-ui--is-edit-tool-p tool-name)
                   (condition-case err
                       (ogent-ui--show-diff-for-tool tool-name tool-args)
                     (error
                      (ogent-ui--insert-tool-block
                       tool-name tool-args
                       (format "[Diff preview error: %s]" (error-message-string err))))))
               ;; Non-edit tools execute immediately
               (let ((result (ogent-ui--execute-tool tool-name tool-args)))
                 (ogent-ui--insert-tool-block tool-name tool-args result))))
            ('denied
             (ogent-ui--insert-tool-block tool-name tool-args
                                          "[Tool execution denied by user]"))))))))

(defun ogent-ui--check-tool-approval (tool-name tool-args)
  "Check if TOOL-NAME with TOOL-ARGS should be executed.
Returns `approved' or `denied'."
  (cond
   ;; Approval disabled - always approve
   ((not ogent-tool-require-approval) 'approved)
   ;; Already denied this session
   ((ogent-tool--denied-p tool-name) 'denied)
   ;; In allow-list - auto-approve
   ((ogent-tool--allowed-p tool-name tool-args) 'approved)
   ;; Check tool spec for :confirm flag (if false, auto-approve)
   ((let ((spec (and (fboundp 'ogent-tool-spec-get)
                     (ogent-tool-spec-get (intern tool-name)))))
      (and spec (not (plist-get spec :confirm))))
    'approved)
   ;; Prompt user
   (t (let ((response (ogent-tool--prompt-approval tool-name tool-args)))
        (pcase response
          ('approve 'approved)
          ('deny 'denied)
          ('always
           (ogent-tool--add-to-allow-list tool-name tool-args)
           'approved)
          ('never
           (ogent-tool--add-to-deny-list tool-name)
           'denied))))))

(defun ogent-ui--execute-tool (name args)
  "Execute tool NAME with ARGS and return result string.
Looks up tool in `ogent-tool-registry' and calls its function."
  (if-let* ((spec (and (fboundp 'ogent-tool-spec-get)
                       (ogent-tool-spec-get (intern name))))
            (func (plist-get spec :function)))
      (condition-case err
          (let ((arg-values (ogent-ui--extract-tool-args spec args)))
            (apply func arg-values))
        (error (format "Tool error: %s" (error-message-string err))))
    (format "Unknown tool: %s" name)))

(defun ogent-ui--extract-tool-args (spec args)
  "Extract argument values from ARGS plist based on SPEC.
Returns a list of values in the order defined in the spec's :args."
  (when (bound-and-true-p ogent-ui-debug-stream-completion)
    (message "[ogent-debug] extract-tool-args: spec=%S args=%S" spec args))
  (let ((arg-specs (plist-get spec :args))
        (values nil))
    (dolist (arg-spec arg-specs)
      (let* ((arg-name (plist-get arg-spec :name))
             ;; Try various forms: :file-path, :file_path, file-path, file_path
             (arg-keyword-hyphen (intern (concat ":" (replace-regexp-in-string "_" "-" arg-name))))
             (arg-keyword-underscore (intern (concat ":" arg-name)))
             (arg-sym-hyphen (intern (replace-regexp-in-string "_" "-" arg-name)))
             (arg-sym-underscore (intern arg-name))
             (value (or (plist-get args arg-keyword-hyphen)
                        (plist-get args arg-keyword-underscore)
                        (plist-get args arg-sym-hyphen)
                        (plist-get args arg-sym-underscore))))
        (when (bound-and-true-p ogent-ui-debug-stream-completion)
          (message "[ogent-debug] arg %s: tried %S %S %S %S -> %S"
                   arg-name arg-keyword-hyphen arg-keyword-underscore
                   arg-sym-hyphen arg-sym-underscore value))
        (push value values)))
    (nreverse values)))

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
  "Send REQUEST to the LLM via gptel.
When target buffer is Org-mode, includes org-format directive.
When model has :tools, enables gptel tool calling."
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
    (when (and (fboundp 'gptel-backend-p)
               (not (gptel-backend-p backend)))
      (user-error
       "Backend %S for model %s is not loaded. Require the backend module or update `ogent-model-registry'."
       (plist-get model :backend) model-id))
    (condition-case err
        (let* ((sender (lambda () (apply #'gptel-request prompt-text args)))
               (gptel-backend backend)
               (gptel-model model-id)
               ;; Bind all registered tools
               (gptel-tools (or tools gptel-tools))
               (gptel-use-tools (when tools t))
               (handle (if preset
                           (if (fboundp 'gptel-with-preset)
                               (gptel-with-preset (if (stringp preset) (intern preset) preset)
                                 (funcall sender))
                             (funcall sender))
                         (funcall sender))))
          (setf (ogent-ui-request-gptel-handle request) handle))
      (error
       (ogent-ui--close-response request (error-message-string err))))))

;;;###autoload (autoload 'ogent-request "ogent" nil t)
(defun ogent-request (&optional prompt models preset)
  "Dispatch PROMPT for the current subtree using MODELS via gptel.
When PROMPT or MODELS are nil, prompt the user and fall back to the
selected models from the dispatcher.
PRESET overrides any dispatcher or model preset.  If PROMPT contains
@preset cookies, they are extracted and applied (first cookie wins).

When invoked from a non-Org buffer, automatically creates and displays
a companion Org buffer to hold the request/response transcript.
The source buffer content is captured for context."
  (interactive)
  (let* ((source-buffer (current-buffer))
         (region-start (when (use-region-p) (region-beginning)))
         (region-end (when (use-region-p) (region-end)))
         (companion (ogent-ui--ensure-companion-context))
         (raw-prompt (or prompt (ogent-ui--read-prompt)))
         (extracted (ogent-ui--extract-preset-cookies raw-prompt))
         (clean-prompt (car extracted))
         (cookie-presets (cdr extracted))
         (effective-preset (or preset
                               (car cookie-presets)
                               ogent-ui--selected-preset)))
    (with-current-buffer companion
      (let* ((context (ogent-context-build-with-source
                       source-buffer region-start region-end))
             ;; Use provided models or fall back to current gptel model
             (model-ids (or models
                            (list (if (and (boundp 'gptel-model) gptel-model)
                                      (if (fboundp 'gptel--model-name)
                                          (gptel--model-name gptel-model)
                                        gptel-model)
                                    "gpt-4o-mini"))))
             last-request)
        (dolist (model-id model-ids)
          (let* ((model (ogent-models-ensure model-id))
                 (request (funcall ogent-response-function clean-prompt context model)))
            (unless (ogent-ui-request-p request)
              (user-error "ogent-response-function must return an `ogent-ui-request'"))
            (setf (ogent-ui-request-preset request) effective-preset)
            (setf (ogent-ui-request-source-buffer request) source-buffer)
            (ogent-ui--send-request request)
            (setq last-request request)))
        ;; Position cursor at response heading in companion window
        (when-let* ((response-pos (and last-request
                                       (ogent-ui-request-response-pos last-request)))
                    (win (get-buffer-window companion)))
          (with-selected-window win
            (goto-char response-pos)))))))

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

;;; Tool Drawer Display

(defvar ogent-ui--tool-seq 0
  "Sequence number for generating unique tool IDs.")

(defconst ogent-tool-status-icons
  '((pending . "○")
    (running . "◐")
    (success . "✓")
    (error . "✗"))
  "Status icons for tool calls.")

(defun ogent-ui--tool-context-summary (name args)
  "Generate a brief context summary for tool NAME with ARGS."
  (when (bound-and-true-p ogent-ui-debug-stream-completion)
    (message "[ogent-debug] tool-context-summary: name=%S args=%S args-type=%s"
             name args (type-of args)))
  (let ((name-str (if (stringp name) name (symbol-name name))))
    (pcase name-str
      ((or "read-file" "Read")
       (or (plist-get args :file_path)
           (plist-get args :path)
           "file"))
      ((or "bash" "Bash")
       (let ((cmd (or (plist-get args :command) "")))
         (truncate-string-to-width cmd 30 nil nil "...")))
      ((or "glob" "Glob")
       (or (plist-get args :pattern) "pattern"))
      ((or "grep" "Grep")
       (or (plist-get args :pattern) "search"))
      ((or "edit" "Edit")
       (or (plist-get args :file_path) "file"))
      ((or "write" "Write")
       (or (plist-get args :file_path) "file"))
      (_ (let ((first-val (cadr args)))
           (if (stringp first-val)
               (truncate-string-to-width first-val 25 nil nil "...")
             ""))))))

(defun ogent-ui--tool-status-icon (status)
  "Return the icon string for STATUS with appropriate face."
  (let ((icon (alist-get status ogent-tool-status-icons "?")))
    (pcase status
      ('success (propertize icon 'face 'success))
      ('error (propertize icon 'face 'error))
      ('running (propertize icon 'face 'warning))
      (_ icon))))

(defun ogent-ui--insert-tool-drawer (name args result &optional status)
  "Insert a tool drawer with NAME, ARGS, RESULT, and STATUS.
Uses Org drawer format for collapsible display with summary line."
  (let* ((tool-id (format "tool-%d" (cl-incf ogent-ui--tool-seq)))
         (status (or status (if (and (stringp result)
                                     (string-match-p "\\[.*error\\|denied\\]" result))
                                'error 'success)))
         (context (ogent-ui--tool-context-summary name args))
         (icon (ogent-ui--tool-status-icon status))
         (name-str (if (stringp name) name (symbol-name name)))
         (drawer-start (point))
         drawer-end)
    ;; Insert drawer - summary on first line inside drawer
    (insert ":TOOL:\n")
    (insert (format "▶ %s: %s %s\n" name-str context icon))
    ;; Args block
    (insert "#+begin_src elisp :args\n")
    (insert (pp-to-string args))
    (unless (bolp) (insert "\n"))
    (insert "#+end_src\n")
    ;; Result block
    (insert (format "#+begin_src %s :result\n"
                    (if (eq status 'error) "text" "text")))
    (insert (if (stringp result) result (pp-to-string result)))
    (unless (bolp) (insert "\n"))
    (insert "#+end_src\n")
    (insert ":END:\n")
    (setq drawer-end (point))
    ;; Add text properties for tool metadata
    (add-text-properties drawer-start drawer-end
                         (list 'ogent-tool-id tool-id
                               'ogent-tool-name (intern name-str)
                               'ogent-tool-status status
                               'ogent-tool-args args
                               'ogent-tool-result result))
    ;; Fold the drawer - use condition-case to handle edge cases
    (save-excursion
      (goto-char drawer-start)
      (when (derived-mode-p 'org-mode)
        (condition-case nil
            (when (fboundp 'org-hide-drawer-toggle)
              (org-hide-drawer-toggle t))
          (error nil))))  ; Silently ignore folding errors
    tool-id))

(defun ogent-ui--insert-tool-block (name args result)
  "Insert a tool block with NAME, ARGS, and RESULT.
Uses drawer format for collapsible display."
  (ogent-ui--insert-tool-drawer name args result))

(defun ogent-tool-at-point ()
  "Return tool info plist if point is within a tool drawer, nil otherwise.
The plist contains :id, :name, :status, :args, and :result."
  (let ((tool-id (get-text-property (point) 'ogent-tool-id)))
    (when tool-id
      (list :id tool-id
            :name (get-text-property (point) 'ogent-tool-name)
            :status (get-text-property (point) 'ogent-tool-status)
            :args (get-text-property (point) 'ogent-tool-args)
            :result (get-text-property (point) 'ogent-tool-result)))))

(defun ogent-tool-rerun ()
  "Re-execute the tool at point with its current arguments.
If the args have been edited in the drawer, uses the edited values."
  (interactive)
  (let ((tool-info (ogent-tool-at-point)))
    (unless tool-info
      (user-error "No tool at point"))
    (let* ((name (plist-get tool-info :name))
           (args (ogent-tool--parse-args-at-point))
           (args (or args (plist-get tool-info :args))))
      (message "Re-running %s..." name)
      (let ((result (ogent-ui--execute-tool (symbol-name name) args)))
        ;; Find drawer boundaries and replace
        (ogent-tool--replace-result-at-point result)
        (message "Re-ran %s" name)))))

(defun ogent-tool--parse-args-at-point ()
  "Parse the args src block in the current tool drawer.
Returns the parsed plist, or nil if parsing fails."
  (save-excursion
    (let ((start (point)))
      ;; Find the drawer start
      (when (re-search-backward "^:TOOL:$" nil t)
        ;; Find args block
        (when (re-search-forward "#\\+begin_src.*:args" nil t)
          (forward-line 1)
          (let ((args-start (point)))
            (when (re-search-forward "#\\+end_src" nil t)
              (forward-line 0)
              (condition-case nil
                  (read (buffer-substring-no-properties args-start (point)))
                (error nil)))))))))

(defun ogent-tool--replace-result-at-point (new-result)
  "Replace the result in the current tool drawer with NEW-RESULT."
  (save-excursion
    ;; Find drawer boundaries
    (let ((start (point)))
      (when (re-search-backward "^:TOOL:$" nil t)
        (let ((drawer-start (point)))
          ;; Find and replace result block content
          (when (re-search-forward "#\\+begin_src.*:result" nil t)
            (forward-line 1)
            (let ((result-start (point)))
              (when (re-search-forward "#\\+end_src" nil t)
                (forward-line 0)
                (delete-region result-start (point))
                (goto-char result-start)
                (insert (if (stringp new-result) new-result (pp-to-string new-result)))
                (unless (bolp) (insert "\n")))))
          ;; Update status icon in header (now on second line)
          (goto-char drawer-start)
          (forward-line 1)
          (when (re-search-forward "\\([○◐✓✗]\\)" (line-end-position) t)
            (replace-match (ogent-ui--tool-status-icon 'success))))))))

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

;;; Inline Diff Display for Edit Proposals

(defvar ogent-ui--pending-diffs (make-hash-table :test 'equal)
  "Hash table mapping diff-id to pending diff info plists.
Each entry contains: :id, :file-path, :diff-text, :tool-name,
:tool-args, :buffer, :marker, :status.")

(defvar ogent-ui--diff-seq 0
  "Sequence number for generating unique diff IDs.")

(defface ogent-diff-header
  '((t :inherit diff-header))
  "Face for diff block headers."
  :group 'ogent-mode)

(defface ogent-diff-added
  '((t :inherit diff-added))
  "Face for added lines in diff blocks."
  :group 'ogent-mode)

(defface ogent-diff-removed
  '((t :inherit diff-removed))
  "Face for removed lines in diff blocks."
  :group 'ogent-mode)

(defface ogent-diff-pending
  '((((class color) (background light)) :foreground "DarkOrange")
    (((class color) (background dark)) :foreground "Orange"))
  "Face for pending diff status."
  :group 'ogent-mode)

(defface ogent-diff-applied
  '((((class color) (background light)) :foreground "DarkGreen")
    (((class color) (background dark)) :foreground "LightGreen"))
  "Face for applied diff status."
  :group 'ogent-mode)

(defface ogent-diff-rejected
  '((((class color) (background light)) :foreground "DarkRed")
    (((class color) (background dark)) :foreground "IndianRed"))
  "Face for rejected diff status."
  :group 'ogent-mode)

(defun ogent-ui--next-diff-id ()
  "Generate a unique diff ID."
  (cl-incf ogent-ui--diff-seq)
  (format "ogent-diff-%d" ogent-ui--diff-seq))

(defun ogent-ui--generate-diff (file-path new-content &optional old-string new-string)
  "Generate a unified diff for a file change.
If OLD-STRING and NEW-STRING are provided, it's an edit operation.
Otherwise, it's a write operation comparing FILE-PATH to NEW-CONTENT."
  (let* ((file-exists (file-exists-p file-path))
         (old-content (if old-string
                          ;; For edit: get current file content
                          (with-temp-buffer
                            (when file-exists
                              (insert-file-contents file-path))
                            (buffer-string))
                        ;; For write: compare against existing
                        (if file-exists
                            (with-temp-buffer
                              (insert-file-contents file-path)
                              (buffer-string))
                          "")))
         (computed-new (if old-string
                           ;; For edit: apply the replacement
                           (replace-regexp-in-string
                            (regexp-quote old-string)
                            new-string
                            old-content t t)
                         ;; For write: use new-content directly
                         new-content)))
    (with-temp-buffer
      (let ((old-file (make-temp-file "ogent-diff-old"))
            (new-file (make-temp-file "ogent-diff-new")))
        (unwind-protect
            (progn
              (with-temp-file old-file
                (insert old-content))
              (with-temp-file new-file
                (insert computed-new))
              (let ((diff-output
                     (shell-command-to-string
                      (format "diff -u %s %s | tail -n +3"
                              (shell-quote-argument old-file)
                              (shell-quote-argument new-file)))))
                (if (string-empty-p diff-output)
                    "(no changes)"
                  ;; Add file header
                  (concat (format "--- %s\n+++ %s\n"
                                  (if file-exists file-path "/dev/null")
                                  file-path)
                          diff-output))))
          (delete-file old-file)
          (delete-file new-file))))))

(defvar ogent-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'ogent-diff-accept)
    (define-key map (kbd "r") #'ogent-diff-reject)
    (define-key map (kbd "RET") #'ogent-diff-accept)
    map)
  "Keymap for ogent diff blocks.")

(defun ogent-ui--fontify-diff (diff-text)
  "Add faces to DIFF-TEXT for syntax highlighting."
  (with-temp-buffer
    (insert diff-text)
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line-start (point))
            (line-end (line-end-position)))
        (cond
         ((looking-at "^@@")
          (add-face-text-property line-start line-end 'ogent-diff-header))
         ((looking-at "^\\+")
          (add-face-text-property line-start line-end 'ogent-diff-added))
         ((looking-at "^-")
          (add-face-text-property line-start line-end 'ogent-diff-removed))
         ((looking-at "^\\(---\\|+++\\)")
          (add-face-text-property line-start line-end 'ogent-diff-header)))
        (forward-line 1)))
    (buffer-string)))

(defun ogent-ui--insert-diff-block (diff-id file-path diff-text status)
  "Insert a diff block with DIFF-ID for FILE-PATH.
DIFF-TEXT is the unified diff content. STATUS is pending/applied/rejected."
  (let ((marker (point))
        (status-face (pcase status
                       ('pending 'ogent-diff-pending)
                       ('applied 'ogent-diff-applied)
                       ('rejected 'ogent-diff-rejected)
                       (_ 'default)))
        (status-text (pcase status
                       ('pending "[PENDING - Press 'a' to accept, 'r' to reject]")
                       ('applied "[APPLIED]")
                       ('rejected "[REJECTED]")
                       (_ "[UNKNOWN]"))))
    (insert (format "#+begin_diff %s\n" diff-id))
    (insert (format "File: %s\n" file-path))
    (insert "Status: ")
    (let ((status-start (point)))
      (insert status-text)
      (add-face-text-property status-start (point) status-face))
    (insert "\n")
    (insert (ogent-ui--fontify-diff diff-text))
    (unless (bolp) (insert "\n"))
    (insert "#+end_diff\n")
    ;; Add text properties for navigation and keybindings
    (save-excursion
      (goto-char marker)
      (let ((end (point)))
        (search-forward "#+end_diff")
        (setq end (point))
        (put-text-property marker end 'ogent-diff-id diff-id)
        (put-text-property marker end 'keymap ogent-diff-mode-map)))
    marker))

(defun ogent-ui--update-diff-status (diff-id new-status)
  "Update the status of diff DIFF-ID to NEW-STATUS in the buffer."
  (let ((diff-info (gethash diff-id ogent-ui--pending-diffs)))
    (when diff-info
      (let ((buffer (plist-get diff-info :buffer))
            (marker (plist-get diff-info :marker)))
        (when (and (buffer-live-p buffer) marker)
          (with-current-buffer buffer
            (save-excursion
              (goto-char marker)
              (when (re-search-forward "^Status: \\[.*\\]" nil t)
                (let* ((start (match-beginning 0))
                       (end (match-end 0))
                       (status-face (pcase new-status
                                      ('applied 'ogent-diff-applied)
                                      ('rejected 'ogent-diff-rejected)
                                      (_ 'ogent-diff-pending)))
                       (status-text (pcase new-status
                                      ('applied "Status: [APPLIED]")
                                      ('rejected "Status: [REJECTED]")
                                      (_ "Status: [PENDING]"))))
                  (delete-region start end)
                  (goto-char start)
                  (insert status-text)
                  (add-face-text-property start (point) status-face))))))))))

(defun ogent-ui--diff-at-point ()
  "Return the diff-id at point, or nil."
  (get-text-property (point) 'ogent-diff-id))

(defun ogent-diff-accept ()
  "Accept and apply the diff at point."
  (interactive)
  (let ((diff-id (ogent-ui--diff-at-point)))
    (if diff-id
        (let ((diff-info (gethash diff-id ogent-ui--pending-diffs)))
          (if (and diff-info (eq (plist-get diff-info :status) 'pending))
              (progn
                ;; Execute the actual tool
                (let* ((tool-name (plist-get diff-info :tool-name))
                       (tool-args (plist-get diff-info :tool-args))
                       (result (ogent-ui--execute-tool tool-name tool-args)))
                  ;; Update status
                  (plist-put diff-info :status 'applied)
                  (plist-put diff-info :result result)
                  (puthash diff-id diff-info ogent-ui--pending-diffs)
                  (ogent-ui--update-diff-status diff-id 'applied)
                  (message "Applied: %s" (truncate-string-to-width
                                          (format "%s" result) 60 nil nil "..."))))
            (message "Diff already processed")))
      (message "No diff at point"))))

(defun ogent-diff-reject ()
  "Reject the diff at point."
  (interactive)
  (let ((diff-id (ogent-ui--diff-at-point)))
    (if diff-id
        (let ((diff-info (gethash diff-id ogent-ui--pending-diffs)))
          (if (and diff-info (eq (plist-get diff-info :status) 'pending))
              (progn
                (plist-put diff-info :status 'rejected)
                (puthash diff-id diff-info ogent-ui--pending-diffs)
                (ogent-ui--update-diff-status diff-id 'rejected)
                (message "Rejected diff for %s" (plist-get diff-info :file-path)))
            (message "Diff already processed")))
      (message "No diff at point"))))

(defun ogent-ui--is-edit-tool-p (tool-name)
  "Return non-nil if TOOL-NAME is a file editing tool."
  (member tool-name '("write-file" "edit-file")))

(defun ogent-ui--show-diff-for-tool (tool-name tool-args)
  "Show a diff preview for TOOL-NAME with TOOL-ARGS.
Returns the diff-id if a diff was created, nil otherwise."
  (let* ((diff-id (ogent-ui--next-diff-id))
         (file-path (or (plist-get tool-args :file-path)
                        (plist-get tool-args :file_path)))
         diff-text)
    (unless file-path
      (error "No file path in tool args"))
    ;; Generate diff based on tool type
    (setq diff-text
          (pcase tool-name
            ("write-file"
             (let ((content (or (plist-get tool-args :content)
                                (plist-get tool-args :content))))
               (ogent-ui--generate-diff file-path content)))
            ("edit-file"
             (let ((old-string (or (plist-get tool-args :old-string)
                                   (plist-get tool-args :old_string)))
                   (new-string (or (plist-get tool-args :new-string)
                                   (plist-get tool-args :new_string))))
               (ogent-ui--generate-diff file-path nil old-string new-string)))
            (_ (error "Unknown edit tool: %s" tool-name))))
    ;; Insert the diff block
    (let ((marker (ogent-ui--insert-diff-block diff-id file-path diff-text 'pending)))
      ;; Store pending diff info
      (puthash diff-id
               (list :id diff-id
                     :file-path file-path
                     :diff-text diff-text
                     :tool-name tool-name
                     :tool-args tool-args
                     :buffer (current-buffer)
                     :marker marker
                     :status 'pending)
               ogent-ui--pending-diffs)
      diff-id)))

(defun ogent-ui-pending-diffs ()
  "Return a list of all pending diff info plists."
  (let (diffs)
    (maphash (lambda (_id info)
               (when (eq (plist-get info :status) 'pending)
                 (push info diffs)))
             ogent-ui--pending-diffs)
    (nreverse diffs)))

(defun ogent-accept-all-diffs ()
  "Accept all pending diffs in the current buffer."
  (interactive)
  (let ((count 0))
    (maphash (lambda (diff-id info)
               (when (and (eq (plist-get info :status) 'pending)
                          (eq (plist-get info :buffer) (current-buffer)))
                 (let ((tool-name (plist-get info :tool-name))
                       (tool-args (plist-get info :tool-args)))
                   (ogent-ui--execute-tool tool-name tool-args)
                   (plist-put info :status 'applied)
                   (puthash diff-id info ogent-ui--pending-diffs)
                   (ogent-ui--update-diff-status diff-id 'applied)
                   (cl-incf count))))
             ogent-ui--pending-diffs)
    (message "Applied %d diff(s)" count)))

(defun ogent-reject-all-diffs ()
  "Reject all pending diffs in the current buffer."
  (interactive)
  (let ((count 0))
    (maphash (lambda (diff-id info)
               (when (and (eq (plist-get info :status) 'pending)
                          (eq (plist-get info :buffer) (current-buffer)))
                 (plist-put info :status 'rejected)
                 (puthash diff-id info ogent-ui--pending-diffs)
                 (ogent-ui--update-diff-status diff-id 'rejected)
                 (cl-incf count)))
             ogent-ui--pending-diffs)
    (message "Rejected %d diff(s)" count)))

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
  (let ((record (ogent-ui--record-error request error-message)))
    (ogent-ui--update-error-buffer)))

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
