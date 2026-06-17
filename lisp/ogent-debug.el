;;; ogent-debug.el --- Development debugging utilities -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides debugging macros that compile away to nothing in production.
;; Based on patterns from elisp-handbook.org.
;;
;; Usage:
;;   ;; Enable debugging (in init.el or interactively)
;;   (setq ogent-debug-enabled t)
;;
;;   ;; In code:
;;   (defun my-function (arg)
;;     (ogent-debug "Processing arg=%s buffer=%s" arg (current-buffer))
;;     ...)
;;
;;   ;; Output in *Messages*:
;;   ;; [ogent] my-function: Processing arg=foo buffer=#<buffer test.org>
;;
;; When ogent-debug-enabled is nil, the macro expands to nil (zero overhead).

;;; Code:

(require 'cl-lib)

(declare-function ogent-ui--execute-tool "ogent-ui-toolcalls")
(declare-function gptel-backend-name "ext:gptel" t t)
(defvar ogent-tool-allow-list)
(defvar ogent-tool--denied-tools)
(defvar ogent-tool-require-approval)

(defgroup ogent-debug nil
  "Debugging utilities for ogent."
  :group 'ogent-mode
  :prefix "ogent-debug-")

;;; Configuration

(defvar ogent-debug-enabled nil
  "When non-nil, `ogent-debug' macros produce output.
Set to t during development, nil for production.
Changes take effect at compile time for byte-compiled code.")

(defvar ogent-debug-buffer "*ogent-debug*"
  "Buffer name for debug output.
Set to nil to use *Messages* instead.")

(defcustom ogent-debug-log-level nil
  "Logging level for ogent debug mode.
This controls what gets logged to the debug buffer:

nil: No logging (default)
info: Log requests, responses, edit parsing, validation
debug: Log everything including raw API data, context building

When non-nil, also enables gptel's logging at the same level."
  :type '(choice
          (const :tag "Off" nil)
          (const :tag "Info" info)
          (const :tag "Debug" debug))
  :group 'ogent-debug)

(defcustom ogent-debug-mirror-gptel t
  "When non-nil, mirror gptel log entries to ogent debug buffer.
This provides a unified view of all LLM interactions."
  :type 'boolean
  :group 'ogent-debug)

(defcustom ogent-debug-log-context nil
  "When non-nil, log context building details.
This can produce verbose output for large contexts."
  :type 'boolean
  :group 'ogent-debug)

(defvar ogent-debug--request-start-time nil
  "Start time of current request for duration tracking.")

;;; Debug Mode

(defvar ogent-debug-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c d c") #'ogent-debug-clear)
    (define-key map (kbd "C-c d s") #'ogent-debug-show)
    (define-key map (kbd "C-c d h") #'ogent-debug-tool-history-buffer)
    map)
  "Keymap for `ogent-debug-mode'.")

;;;###autoload
(define-minor-mode ogent-debug-mode
  "Minor mode for debugging ogent LLM interactions.
When enabled, logs requests, responses, edit parsing, and validation
to the *ogent-debug* buffer.  Also enables gptel's logging.

Key bindings:
\\{ogent-debug-mode-map}"
  :lighter " OgDbg"
  :keymap ogent-debug-mode-map
  :global t
  (if ogent-debug-mode
      (progn
        ;; Enable logging
        (setq ogent-debug-log-level (or ogent-debug-log-level 'info))
        (setq ogent-debug-enabled t)
        ;; Enable gptel logging at same level
        (when (boundp 'gptel-log-level)
          (setq gptel-log-level ogent-debug-log-level))
        ;; Set up hooks
        (ogent-debug--setup-hooks)
        (message "ogent-debug-mode enabled (level: %s)" ogent-debug-log-level))
    ;; Disable logging
    (setq ogent-debug-enabled nil)
    (when (boundp 'gptel-log-level)
      (setq gptel-log-level nil))
    (ogent-debug--teardown-hooks)
    (message "ogent-debug-mode disabled")))

(defun ogent-debug--setup-hooks ()
  "Set up hooks for debug logging."
  ;; Hook into gptel's request/response cycle if available
  (when (boundp 'gptel-pre-request-hook)
    (add-hook 'gptel-pre-request-hook #'ogent-debug--log-pre-request))
  (when (boundp 'gptel-post-response-hook)
    (add-hook 'gptel-post-response-hook #'ogent-debug--log-post-response)))

(defun ogent-debug--teardown-hooks ()
  "Remove debug logging hooks."
  (when (boundp 'gptel-pre-request-hook)
    (remove-hook 'gptel-pre-request-hook #'ogent-debug--log-pre-request))
  (when (boundp 'gptel-post-response-hook)
    (remove-hook 'gptel-post-response-hook #'ogent-debug--log-post-response)))

;;; Request/Response Logging

(defun ogent-debug--log-pre-request ()
  "Log before sending a request."
  (setq ogent-debug--request-start-time (current-time))
  (ogent-debug-log 'request ">>> REQUEST STARTED"
                   :model (when (boundp 'gptel-model) gptel-model)
                   :backend (when (boundp 'gptel-backend)
                              (and gptel-backend
                                   (gptel-backend-name gptel-backend)))))

(defun ogent-debug--log-post-response (beg end)
  "Log after receiving a response between BEG and END."
  (let* ((elapsed (when ogent-debug--request-start-time
                    (float-time (time-subtract (current-time)
                                               ogent-debug--request-start-time))))
         (response-length (- end beg)))
    (ogent-debug-log 'response "<<< RESPONSE RECEIVED"
                     :elapsed (when elapsed (format "%.2fs" elapsed))
                     :length response-length)
    (setq ogent-debug--request-start-time nil)))

(defun ogent-debug-log (type message &rest props)
  "Log MESSAGE of TYPE with optional PROPS to debug buffer.
TYPE is a symbol like `request', `response', `edit', `validation'.
PROPS is a plist of additional properties to log."
  (when ogent-debug-log-level
    (let ((timestamp (format-time-string "%H:%M:%S"))
          (type-str (upcase (symbol-name type)))
          (props-str (if props
                         (mapconcat (lambda (pair)
                                      (format "%s=%S" (car pair) (cadr pair)))
                                    (seq-partition props 2)
                                    " ")
                       "")))
      (ogent-debug--insert-log
       (format "%s [%s] %s%s"
               timestamp
               type-str
               message
               (if (string-empty-p props-str) "" (concat " | " props-str)))))))

(defun ogent-debug--insert-log (text)
  "Insert TEXT into the debug buffer."
  (when ogent-debug-buffer
    (with-current-buffer (get-buffer-create ogent-debug-buffer)
      (goto-char (point-max))
      (insert text "\n"))))

;;; Edit Parsing Logging

(defun ogent-debug-log-edit-parse (source result)
  "Log edit parsing from SOURCE with RESULT.
SOURCE is the raw response text, RESULT is the parsed edit structure."
  (when (and ogent-debug-log-level
             (memq ogent-debug-log-level '(info debug)))
    (ogent-debug-log 'edit "Edit parsed"
                     :edits (if (listp result) (length result) 0)
                     :source-length (length source))
    (when (eq ogent-debug-log-level 'debug)
      (ogent-debug--insert-log
       (format "  Source preview: %s..."
               (substring source 0 (min 200 (length source)))))
      (ogent-debug--insert-log
       (format "  Parsed: %S" result)))))

(defun ogent-debug-log-edit-apply (edit status &optional error)
  "Log edit application with EDIT, STATUS, and optional ERROR."
  (when ogent-debug-log-level
    (let ((file (plist-get edit :file))
          (type (plist-get edit :type)))
      (ogent-debug-log 'edit (format "Edit %s" status)
                       :file file
                       :type type
                       :error error))))

;;; Validation Logging

(defun ogent-debug-log-validation (type result &optional details)
  "Log validation of TYPE with RESULT and optional DETAILS."
  (when ogent-debug-log-level
    (ogent-debug-log 'validation (format "%s validation: %s" type result)
                     :details details)))

;;; Context Logging

(defun ogent-debug-log-context (action &rest props)
  "Log context ACTION with PROPS."
  (when (and ogent-debug-log-level ogent-debug-log-context)
    (apply #'ogent-debug-log 'context action props)))

;;; Debug Macro

(defmacro ogent-debug (format-string &rest args)
  "Log debug message when `ogent-debug-enabled' is non-nil.
FORMAT-STRING and ARGS are passed to `format'.
The message is prefixed with [ogent] and the calling function name.

This macro compiles to nil when `ogent-debug-enabled' is nil,
so it can be left in production code with zero overhead.

Example:
  (defun ogent-context-build ()
    (ogent-debug \"Building context at point=%s\" (point))
    ...)"
  (declare (indent 1) (debug t))
  (when ogent-debug-enabled
    (let ((fn-name (or (and (boundp 'byte-compile-current-form)
                            byte-compile-current-form)
                       'unknown)))
      `(ogent-debug--log ',fn-name ,format-string ,@args))))

(defun ogent-debug--log (fn-name format-string &rest args)
  "Log a debug message from FN-NAME using FORMAT-STRING and ARGS."
  (let ((msg (format "[ogent] %s: %s"
                     fn-name
                     (apply #'format format-string args))))
    (if ogent-debug-buffer
        (with-current-buffer (get-buffer-create ogent-debug-buffer)
          (goto-char (point-max))
          (insert (format-time-string "%H:%M:%S ") msg "\n"))
      (message "%s" msg))))

;;; Debug with Variable Display

(defmacro ogent-debug-vars (&rest vars)
  "Log the names and values of VARS when debugging is enabled.
Each VAR can be a symbol or an expression.

Example:
  (let ((x 1) (y 2))
    (ogent-debug-vars x y (+ x y)))
  ;; Output: [ogent] fn: x=1 y=2 (+ x y)=3"
  (declare (debug t))
  (when ogent-debug-enabled
    (let ((fn-name (or (and (boundp 'byte-compile-current-form)
                            byte-compile-current-form)
                       'unknown))
          (var-formats (mapcar (lambda (var)
                                 (if (symbolp var)
                                     (format "%s=%%S" var)
                                   (format "%S=%%S" var)))
                               vars)))
      `(ogent-debug--log ',fn-name
                         ,(string-join var-formats " ")
                         ,@vars))))

;;; Interactive Commands

;;;###autoload
(defun ogent-debug-enable ()
  "Enable ogent debug output.
Note: This only affects interpreted code.  Byte-compiled code
must be recompiled to pick up the change."
  (interactive)
  (setq ogent-debug-enabled t)
  (message "ogent debugging enabled (interpreted code only)"))

;;;###autoload
(defun ogent-debug-disable ()
  "Disable ogent debug output."
  (interactive)
  (setq ogent-debug-enabled nil)
  (message "ogent debugging disabled"))

;;;###autoload
(defun ogent-debug-toggle ()
  "Toggle ogent debug output."
  (interactive)
  (if ogent-debug-enabled
      (ogent-debug-disable)
    (ogent-debug-enable)))

;;;###autoload
(defun ogent-debug-show ()
  "Show the ogent debug buffer."
  (interactive)
  (if ogent-debug-buffer
      (display-buffer (get-buffer-create ogent-debug-buffer))
    (display-buffer "*Messages*")))

;;;###autoload
(defun ogent-debug-clear ()
  "Clear the ogent debug buffer."
  (interactive)
  (when ogent-debug-buffer
    (with-current-buffer (get-buffer-create ogent-debug-buffer)
      (erase-buffer)))
  (message "Debug buffer cleared"))

;;; Tool Call History

(defvar ogent-debug-tool-history nil
  "List of tool call records.
Each entry is a plist with:
  :id       - unique call ID
  :name     - tool name symbol
  :args     - argument plist
  :result   - execution result (or nil if failed)
  :error    - error message (or nil if succeeded)
  :duration - execution time in seconds
  :timestamp - time of invocation")

(defvar ogent-debug-tool-history-max 100
  "Maximum number of tool calls to keep in history.
Older entries are discarded when this limit is exceeded.")

(defun ogent-debug-log-tool-call (tool-call result duration)
  "Log TOOL-CALL with RESULT and DURATION to history.
TOOL-CALL should be a plist with :id, :name, :args.
RESULT is either the success value or nil if error occurred.
DURATION is execution time in seconds."
  (let* ((id (plist-get tool-call :id))
         (name (plist-get tool-call :name))
         (args (plist-get tool-call :args))
         (error-val (plist-get tool-call :error))
         (entry (list :id id
                      :name name
                      :args args
                      :result result
                      :error error-val
                      :duration duration
                      :timestamp (current-time))))
    ;; Add to front of list
    (push entry ogent-debug-tool-history)
    ;; Trim if exceeds max
    (when (> (length ogent-debug-tool-history) ogent-debug-tool-history-max)
      (setq ogent-debug-tool-history
            (seq-take ogent-debug-tool-history ogent-debug-tool-history-max)))
    entry))

(defun ogent-debug-clear-tool-history ()
  "Clear all tool call history."
  (interactive)
  (setq ogent-debug-tool-history nil)
  (message "Tool call history cleared"))

;;; Tool History Major Mode

(defvar ogent-tool-history-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'ogent-tool-history-next)
    (define-key map (kbd "p") #'ogent-tool-history-prev)
    (define-key map (kbd "RET") #'ogent-tool-history-replay-at-point)
    (define-key map (kbd "r") #'ogent-tool-history-replay-at-point)
    (define-key map (kbd "g") #'ogent-tool-history-refresh)
    (define-key map (kbd "j") #'ogent-debug-export-tool-history-json)
    (define-key map (kbd "t") #'ogent-debug-export-tool-history-text)
    (define-key map (kbd "c") #'ogent-debug-clear-tool-history)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'ogent-tool-history-help)
    map)
  "Keymap for `ogent-tool-history-mode'.")

(define-derived-mode ogent-tool-history-mode special-mode "ToolHist"
  "Major mode for browsing ogent tool call history.

\\{ogent-tool-history-mode-map}"
  :group 'ogent-debug
  (setq-local revert-buffer-function #'ogent-tool-history--revert)
  (setq truncate-lines t))

(defun ogent-tool-history--revert (_ignore-auto _noconfirm)
  "Revert the tool history buffer."
  (ogent-tool-history-refresh))

(defvar-local ogent-tool-history--entries nil
  "List of history entries displayed in current buffer.
Each entry maps line ranges to history plists.")

(defun ogent-tool-history-next ()
  "Move to next tool entry."
  (interactive)
  (when (re-search-forward "^## \\[" nil t)
    (beginning-of-line)))

(defun ogent-tool-history-prev ()
  "Move to previous tool entry."
  (interactive)
  (beginning-of-line)
  (when (re-search-backward "^## \\[" nil t)
    (beginning-of-line)))

(defun ogent-tool-history--entry-at-point ()
  "Return the history entry at point, or nil."
  (save-excursion
    (beginning-of-line)
    (when (or (looking-at "^## \\[")
              (re-search-backward "^## \\[" nil t))
      (when-let* ((id-line (save-excursion
                             (forward-line 1)
                             (when (looking-at "^ID: \\(.+\\)$")
                               (match-string 1)))))
        (seq-find (lambda (e) (equal (plist-get e :id) id-line))
                  ogent-debug-tool-history)))))

(defun ogent-tool-history-replay-at-point ()
  "Replay the tool call at point."
  (interactive)
  (if-let ((entry (ogent-tool-history--entry-at-point)))
      (ogent-debug-replay-tool entry)
    (user-error "No tool entry at point")))

(defun ogent-tool-history-refresh ()
  "Refresh the tool history buffer."
  (interactive)
  (let ((pos (point)))
    (ogent-debug-tool-history-buffer)
    (goto-char (min pos (point-max)))))

(defun ogent-tool-history-help ()
  "Show help for tool history mode."
  (interactive)
  (message "n/p: next/prev  RET/r: replay  g: refresh  j: export JSON  t: export text  c: clear  q: quit"))

(defun ogent-debug-tool-history-buffer ()
  "Display tool call history in a dedicated buffer."
  (interactive)
  (let ((buf (get-buffer-create "*ogent-tool-history*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# Ogent Tool Call History\n")
        (insert "# Keys: n/p=nav  RET=replay  g=refresh  j=json  t=text  q=quit\n\n")
        (if (null ogent-debug-tool-history)
            (insert "No tool calls recorded yet.\n")
          (let ((entries (reverse ogent-debug-tool-history)))
            (dolist (entry entries)
              (let* ((id (plist-get entry :id))
                     (name (plist-get entry :name))
                     (args (plist-get entry :args))
                     (result (plist-get entry :result))
                     (error-val (plist-get entry :error))
                     (duration (plist-get entry :duration))
                     (timestamp (plist-get entry :timestamp))
                     (time-str (format-time-string "%Y-%m-%d %H:%M:%S" timestamp))
                     (status (if error-val "FAILED" "SUCCESS")))
                (insert (format "## [%s] %s - %s (%.3fs)\n"
                                time-str status name duration))
                (insert (format "ID: %s\n" id))
                (when args
                  (insert "Args:\n")
                  (let ((arg-str (format "%S" args)))
                    (insert (format "  %s\n"
                                    (if (> (length arg-str) 300)
                                        (concat (substring arg-str 0 300) "...")
                                      arg-str)))))
                (if error-val
                    (insert (format "Error: %s\n" error-val))
                  (when result
                    (let ((res-str (if (stringp result) result (format "%S" result))))
                      (insert (format "Result: %s\n"
                                      (if (> (length res-str) 200)
                                          (concat (substring res-str 0 200) "...")
                                        res-str))))))
                (insert "\n")))))
        (goto-char (point-min))
        (ogent-tool-history-mode)))
    (display-buffer buf)))

(defun ogent-debug-replay-tool (entry)
  "Re-execute tool call from history ENTRY.
ENTRY should be a plist from `ogent-debug-tool-history'."
  (interactive
   (list
    (if (null ogent-debug-tool-history)
        (user-error "No tool calls in history")
      (let* ((choices
              (mapcar (lambda (e)
                        (cons (format "%s [%s]"
                                      (plist-get e :name)
                                      (format-time-string "%H:%M:%S"
                                                          (plist-get e :timestamp)))
                              e))
                      ogent-debug-tool-history))
             (choice (completing-read "Replay tool: " choices nil t)))
        (cdr (assoc choice choices))))))
  (let ((name (plist-get entry :name))
        (args (plist-get entry :args)))
    (message "Replaying %s..." name)
    ;; Replay through the live executor so it shares the same approval
    ;; policy and proof-ledger recording as a normal tool run.  Lazy
    ;; require avoids pulling the UI layer into ogent-debug at load time.
    (require 'ogent-ui)
    (let ((result (ogent-ui--execute-tool name args)))
      (message "Replay result: %s" result))))

(defun ogent-debug-last-tool ()
  "Return the most recent tool call entry, or nil."
  (car ogent-debug-tool-history))

;;;###autoload
(defun ogent-debug-replay-last-tool ()
  "Replay the most recent tool call."
  (interactive)
  (if-let ((last (ogent-debug-last-tool)))
      (ogent-debug-replay-tool last)
    (user-error "No tool calls in history")))

;;;###autoload
(defun ogent-debug-show-approval-status ()
  "Show the current tool approval state.
Reports the live policy used by the request pipeline: the
persistent allow-list (`ogent-tool-allow-list') and the
session-only deny list (`ogent-tool--denied-tools')."
  (interactive)
  (require 'ogent-ui)
  (let ((allow (and (boundp 'ogent-tool-allow-list) ogent-tool-allow-list))
        (denied (and (boundp 'ogent-tool--denied-tools)
                     ogent-tool--denied-tools))
        (buf (get-buffer-create "*ogent-approval-status*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# Tool Approval Status\n\n")
        (insert (format "Approval required: %s\n\n"
                        (if (and (boundp 'ogent-tool-require-approval)
                                 ogent-tool-require-approval)
                            "yes" "no (all tools auto-approved)")))
        (if allow
            (progn
              (insert "Allow-list (auto-approved):\n")
              (dolist (pattern allow)
                (insert (format "  - %s\n" pattern))))
          (insert "Allow-list: empty.\n"))
        (insert "\n")
        (if denied
            (progn
              (insert "Denied this session:\n")
              (dolist (tool denied)
                (insert (format "  - %s\n" tool))))
          (insert "No tools denied this session.\n"))
        (goto-char (point-min))
        (view-mode 1)))
    (display-buffer buf)))

;;; Export Tool History

(require 'json)

(defun ogent-debug-export-tool-history-json (file)
  "Export tool call history to FILE in JSON format.
Creates a shareable record of tool calls for debugging."
  (interactive
   (list (read-file-name "Export JSON to: "
                         nil nil nil
                         (format "ogent-tool-history-%s.json"
                                 (format-time-string "%Y%m%d-%H%M%S")))))
  (if (null ogent-debug-tool-history)
      (user-error "No tool calls in history")
    (let ((json-array-type 'list)
          (json-object-type 'plist)
          (entries
           (mapcar
            (lambda (entry)
              (list :id (plist-get entry :id)
                    :name (symbol-name (plist-get entry :name))
                    :args (plist-get entry :args)
                    :result (let ((r (plist-get entry :result)))
                              (if (stringp r)
                                  (substring r 0 (min 1000 (length r)))
                                r))
                    :error (plist-get entry :error)
                    :duration (plist-get entry :duration)
                    :timestamp (format-time-string
                                "%Y-%m-%dT%H:%M:%S%z"
                                (plist-get entry :timestamp))))
            (reverse ogent-debug-tool-history))))
      (with-temp-file file
        (insert (json-encode (list :version 1
                                   :exported (format-time-string "%Y-%m-%dT%H:%M:%S%z")
                                   :count (length entries)
                                   :calls entries))))
      (message "Exported %d tool calls to %s" (length entries) file))))

(defun ogent-debug-export-tool-history-text (file)
  "Export tool call history to FILE in readable text format."
  (interactive
   (list (read-file-name "Export text to: "
                         nil nil nil
                         (format "ogent-tool-history-%s.txt"
                                 (format-time-string "%Y%m%d-%H%M%S")))))
  (if (null ogent-debug-tool-history)
      (user-error "No tool calls in history")
    (with-temp-file file
      (insert "# Ogent Tool Call History\n")
      (insert (format "# Exported: %s\n" (format-time-string "%Y-%m-%d %H:%M:%S")))
      (insert (format "# Entries: %d\n\n" (length ogent-debug-tool-history)))
      (dolist (entry (reverse ogent-debug-tool-history))
        (let* ((name (plist-get entry :name))
               (args (plist-get entry :args))
               (result (plist-get entry :result))
               (error-val (plist-get entry :error))
               (duration (plist-get entry :duration))
               (timestamp (plist-get entry :timestamp))
               (time-str (format-time-string "%Y-%m-%d %H:%M:%S" timestamp)))
          (insert (format "## %s - %s (%.3fs) %s\n"
                          time-str name duration
                          (if error-val "FAILED" "SUCCESS")))
          (insert (format "ID: %s\n" (plist-get entry :id)))
          (when args
            (insert "Args:\n")
            (let ((arg-str (format "%S" args)))
              (insert (format "  %s\n"
                              (if (> (length arg-str) 500)
                                  (concat (substring arg-str 0 500) "...")
                                arg-str)))))
          (if error-val
              (insert (format "Error: %s\n" error-val))
            (when result
              (let ((result-str (if (stringp result) result (format "%S" result))))
                (insert (format "Result:\n  %s\n"
                                (if (> (length result-str) 500)
                                    (concat (substring result-str 0 500) "...")
                                  result-str))))))
          (insert "\n"))))
    (message "Exported %d tool calls to %s"
             (length ogent-debug-tool-history) file)))

(defun ogent-debug-import-tool-history (file)
  "Import tool call history from JSON FILE.
Merges with existing history."
  (interactive "fImport JSON from: ")
  (let* ((json-array-type 'list)
         (json-object-type 'plist)
         (data (json-read-file file))
         (calls (plist-get data :calls))
         (imported 0))
    (dolist (call calls)
      (let ((entry (list :id (plist-get call :id)
                         :name (intern (plist-get call :name))
                         :args (plist-get call :args)
                         :result (plist-get call :result)
                         :error (plist-get call :error)
                         :duration (plist-get call :duration)
                         :timestamp (current-time)))) ; Use current time for imported
        (push entry ogent-debug-tool-history)
        (cl-incf imported)))
    ;; Trim to max
    (when (> (length ogent-debug-tool-history) ogent-debug-tool-history-max)
      (setq ogent-debug-tool-history
            (seq-take ogent-debug-tool-history ogent-debug-tool-history-max)))
    (message "Imported %d tool calls from %s" imported file)))

;;; Transient Menu

(require 'transient)

;;;###autoload (autoload 'ogent-debug-tools-menu "ogent-debug" nil t)
(transient-define-prefix ogent-debug-tools-menu ()
  "Tool debugging and history menu."
  ["Tool Call History"
   ("h" "View history" ogent-debug-tool-history-buffer)
   ("r" "Replay last tool" ogent-debug-replay-last-tool)
   ("c" "Clear history" ogent-debug-clear-tool-history)]
  ["Export/Import"
   ("j" "Export JSON" ogent-debug-export-tool-history-json)
   ("t" "Export text" ogent-debug-export-tool-history-text)
   ("i" "Import JSON" ogent-debug-import-tool-history)]
  ["Approval Status"
   ("a" "Show approvals" ogent-debug-show-approval-status)])

;; Canonical Evil integration so the tool-history buffer's single-key
;; affordances (n/p, RET replay, g refresh, ? help, q quit) fire under
;; Doom/Evil.
(with-eval-after-load 'evil
  (when (fboundp 'ogent-evil-display-mode-setup)
    (ogent-evil-display-mode-setup
     'ogent-tool-history-mode ogent-tool-history-mode-map
     'ogent-tool-history-mode-hook #'ogent-tool-history-refresh)))

(provide 'ogent-debug)

;;; ogent-debug.el ends here
