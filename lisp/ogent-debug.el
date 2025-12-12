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

(declare-function ogent-tool-fsm-execute "ogent-tool-fsm")

;;; Configuration

(defvar ogent-debug-enabled nil
  "When non-nil, `ogent-debug' macros produce output.
Set to t during development, nil for production.
Changes take effect at compile time for byte-compiled code.")

(defvar ogent-debug-buffer "*ogent-debug*"
  "Buffer name for debug output.
Set to nil to use *Messages* instead.")

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

;;; Conditional Execution

(defmacro ogent-when-debug (&rest body)
  "Execute BODY only when debugging is enabled.
Use for debug-only side effects like assertions or state dumps."
  (declare (indent 0) (debug t))
  (when ogent-debug-enabled
    `(progn ,@body)))

;;; Interactive Commands

;;;###autoload
(defun ogent-debug-enable ()
  "Enable ogent debug output.
Note: This only affects interpreted code. Byte-compiled code
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

(defun ogent-debug-tool-history-buffer ()
  "Display tool call history in a dedicated buffer."
  (interactive)
  (let ((buf (get-buffer-create "*ogent-tool-history*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# Ogent Tool Call History\n\n")
        (if (null ogent-debug-tool-history)
            (insert "No tool calls recorded yet.\n")
          (dolist (entry (reverse ogent-debug-tool-history))
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
                (insert (format "  %S\n" args)))
              (if error-val
                  (insert (format "Error: %s\n" error-val))
                (when result
                  (insert (format "Result: %s\n" 
                                  (if (stringp result)
                                      (substring result 0 (min 200 (length result)))
                                    (format "%S" result))))))
              (insert "\n"))))
        (goto-char (point-min))
        (view-mode 1)))
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
  (let* ((name (plist-get entry :name))
         (args (plist-get entry :args))
         (id (format "replay-%s-%d" name (random 10000)))
         (tool-call (list :id id :name name :args args)))
    (message "Replaying %s..." name)
    (require 'ogent-tool-fsm)
    (ogent-tool-fsm-execute
     tool-call
     (lambda (result error)
       (if error
           (message "Replay failed: %s" error)
         (message "Replay succeeded: %s" result))))))

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
  "Show current session's tool approval status."
  (interactive)
  (require 'ogent-tool-approval)
  (let ((buf (get-buffer-create "*ogent-approval-status*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# Tool Approval Status\n\n")
        (insert (format "Session mode: %s\n\n"
                        (if (bound-and-true-p ogent-tool-approval--session-approved)
                            "Active"
                          "Inactive")))
        (if (and (boundp 'ogent-tool-approval--session-approved)
                 (hash-table-p ogent-tool-approval--session-approved)
                 (> (hash-table-count ogent-tool-approval--session-approved) 0))
            (progn
              (insert "Approved tools:\n")
              (maphash (lambda (tool approved)
                         (when approved
                           (insert (format "  - %s\n" tool))))
                       ogent-tool-approval--session-approved))
          (insert "No tools approved this session.\n"))
        (goto-char (point-min))
        (view-mode 1)))
    (display-buffer buf)))

;;; Transient Menu

(require 'transient)

;;;###autoload (autoload 'ogent-debug-tools-menu "ogent-debug" nil t)
(transient-define-prefix ogent-debug-tools-menu ()
  "Tool debugging and history menu."
  ["Tool Call History"
   ("h" "View history" ogent-debug-tool-history-buffer)
   ("r" "Replay last tool" ogent-debug-replay-last-tool)
   ("c" "Clear history" ogent-debug-clear-tool-history)]
  ["Approval Status"
   ("a" "Show approvals" ogent-debug-show-approval-status)])

(provide 'ogent-debug)

;;; ogent-debug.el ends here
