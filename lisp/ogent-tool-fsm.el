;;; ogent-tool-fsm.el --- Tool execution FSM for gptel integration -*- lexical-binding: t; -*-

;;; Commentary:
;; Finite State Machine for handling tool execution in gptel responses.
;; Integrates with ogent-tool-render for visual feedback, ogent-tool-approval
;; for user consent, and ogent-tools for execution.
;;
;; State flow: pending → running → completed/failed
;; Supports both Claude (tool_use blocks) and OpenAI (function_call) formats.

;;; Code:

(require 'cl-lib)
(require 'ogent-tool-render)
(require 'ogent-tool-approval)

(declare-function ogent-tool-spec-get "ogent-models")
(declare-function ogent-tool-get "ogent-models")
(declare-function ogent-debug-log-tool-call "ogent-debug")

(defgroup ogent-tool-fsm nil
  "Tool execution state machine for ogent."
  :group 'ogent)

(defcustom ogent-tool-fsm-debug nil
  "Enable debug logging for tool FSM state transitions."
  :type 'boolean
  :group 'ogent-tool-fsm)

;;; Tool Call Tracking

(defvar ogent-tool-fsm--active-calls (make-hash-table :test 'equal)
  "Hash table tracking active tool calls by ID.
Keys are tool call IDs (strings), values are `ogent-tool-call' structs.")

(defun ogent-tool-fsm--log (format-string &rest args)
  "Log debug message if `ogent-tool-fsm-debug' is non-nil."
  (when ogent-tool-fsm-debug
    (apply #'message (concat "[ogent-tool-fsm] " format-string) args)))

;;; Response Parsing

(defun ogent-tool-fsm-parse-tool-calls (response)
  "Parse tool calls from RESPONSE.
RESPONSE can be a string or a plist from gptel.
Returns list of plists, each with :id, :name, :args keys.

Supports Claude format (tool_use blocks) and OpenAI format (function_call)."
  (cond
   ;; Response is already a plist with :tool-use key (gptel format)
   ((and (listp response) (plist-get response :tool-use))
    (let ((tool-calls (plist-get response :tool-use)))
      (delq nil (mapcar #'ogent-tool-fsm--normalize-tool-call tool-calls))))
   
   ;; Response is a string - parse it
   ((stringp response)
    (ogent-tool-fsm--parse-string-response response))
   
   ;; Unknown format
   (t nil)))

(defun ogent-tool-fsm--normalize-tool-call (call)
  "Normalize CALL to standard plist format.
Handles both Claude (:name, :input) and OpenAI (:function, :arguments) formats."
  (when (listp call)
    (let* ((name (or (plist-get call :name)
                     (plist-get call :function)))
           (args (or (plist-get call :input)
                     (plist-get call :arguments))))
      (if (not (or (stringp name)
                   (and name (symbolp name))))
          (progn
            (ogent-tool-fsm--log "Ignoring malformed tool call without name: %S" call)
            nil)
        (let ((tool-name (if (symbolp name) name (intern name)))
              (id (or (plist-get call :id)
                      (format "%s-%d" name (random 10000)))))
          (list :id id
                :name tool-name
                :args args))))))

(defun ogent-tool-fsm--parse-string-response (text)
  "Parse tool calls from TEXT string.
Looks for tool_use blocks in Claude format or function_call in OpenAI format."
  ;; This is a simplified parser - in practice, gptel should provide
  ;; structured data via the :tool-use key in the info plist
  (let ((calls nil))
    ;; Try to find JSON-like tool call structures
    ;; This is a fallback - normally gptel provides structured data
    (when (string-match-p "tool_use\\|function_call" text)
      (ogent-tool-fsm--log "Found tool call markers in text (fallback parsing)"))
    calls))

;;; FSM State Management

(defun ogent-tool-fsm-execute (tool-call callback)
  "Execute TOOL-CALL and invoke CALLBACK with result.
TOOL-CALL should be a plist with :id, :name, :args.
CALLBACK is called with (result error) - one will be nil.

Manages state transitions: pending → running → completed/failed.
Automatically logs execution to tool call history."
  (let* ((id (plist-get tool-call :id))
         (name (plist-get tool-call :name))
         (args (plist-get tool-call :args))
         (spec (and (fboundp 'ogent-tool-spec-get)
                    (ogent-tool-spec-get name)))
         (func (and spec (plist-get spec :function)))
         (start-time (current-time)))
    
    (ogent-tool-fsm--log "Executing tool: %s (id: %s)" name id)
    
    (if (not func)
        (let ((err-msg (format "Tool not found: %s" name)))
          ;; Log error to history
          (when (fboundp 'ogent-debug-log-tool-call)
            (ogent-debug-log-tool-call
             (plist-put (copy-sequence tool-call) :error err-msg)
             nil
             0.0))
          (funcall callback nil err-msg))
      ;; Execute the tool
      (condition-case err
          (let* ((result (apply func (ogent-tool-fsm--plist-to-args args)))
                 (duration (float-time (time-subtract (current-time) start-time))))
            (ogent-tool-fsm--log "Tool %s completed successfully" name)
            ;; Log success to history
            (when (fboundp 'ogent-debug-log-tool-call)
              (ogent-debug-log-tool-call tool-call result duration))
            (funcall callback result nil))
        (error
         (let* ((err-msg (error-message-string err))
                (duration (float-time (time-subtract (current-time) start-time))))
           (ogent-tool-fsm--log "Tool %s failed: %s" name err-msg)
           ;; Log failure to history
           (when (fboundp 'ogent-debug-log-tool-call)
             (ogent-debug-log-tool-call
              (plist-put (copy-sequence tool-call) :error err-msg)
              nil
              duration))
           (funcall callback nil err-msg)))))))

(defun ogent-tool-fsm--plist-to-args (plist)
  "Convert PLIST to flat argument list for apply."
  (let ((args nil))
    (while plist
      (push (cadr plist) args)
      (setq plist (cddr plist)))
    (nreverse args)))

;;; Main Handler

(defun ogent-tool-fsm-handle-response (_response info)
  "Handle tool calls in RESPONSE with INFO from gptel callback.
Parses tool calls, renders them, requests approval, executes, and
displays results.

RESPONSE is the text content from gptel.
INFO is the plist containing metadata, including :tool-use.

Returns t if tools were handled, nil otherwise."
  (when-let* ((tool-calls (ogent-tool-fsm-parse-tool-calls info)))
    (ogent-tool-fsm--log "Handling %d tool calls" (length tool-calls))
    
    (dolist (call tool-calls)
      (let* ((id (plist-get call :id))
             (name (plist-get call :name))
             (args (plist-get call :args))
             (spec (and (fboundp 'ogent-tool-spec-get)
                        (ogent-tool-spec-get name))))
        
        ;; Create render struct
        (let ((render-call (ogent-tool-call-create
                           :id id
                           :name name
                           :args args
                           :status 'pending)))
          
          ;; Store for tracking
          (puthash id render-call ogent-tool-fsm--active-calls)
          
          ;; Render as pending
          (ogent-tool-render-call render-call t)
          
          ;; Request approval
          (ogent-tool-approval-request
           spec args
           (lambda (approved)
             (if approved
                 (progn
                   ;; Update to running
                   (ogent-tool-render-update-status render-call 'running)
                   
                   ;; Execute
                   (ogent-tool-fsm-execute
                    call
                    (lambda (result error)
                      (if error
                          ;; Failed
                          (progn
                            (setf (ogent-tool-call-error render-call) error)
                            (ogent-tool-render-insert-error render-call error))
                        ;; Success
                        (ogent-tool-render-insert-result render-call
                                                         (format "%s" result)))
                      ;; Clean up tracking
                      (remhash id ogent-tool-fsm--active-calls))))
               ;; Rejected
               (progn
                 (ogent-tool-render-insert-error render-call "Tool execution denied by user")
                 (remhash id ogent-tool-fsm--active-calls))))))))
    t))

;;; Integration Helpers

(defun ogent-tool-fsm-callback-wrapper (original-callback)
  "Wrap ORIGINAL-CALLBACK to intercept tool calls.
Returns a new callback function suitable for gptel-request.

The wrapper:
1. Checks for tool calls in the info plist
2. If found, handles them via the FSM
3. Still calls ORIGINAL-CALLBACK for text responses"
  (lambda (text info)
    ;; Handle tool calls if present
    (when (and (listp info) (plist-get info :tool-use))
      (ogent-tool-fsm-handle-response text info))
    
    ;; Always call original callback for text handling
    (when original-callback
      (funcall original-callback text info))))

(defun ogent-tool-fsm-reset ()
  "Clear all active tool call tracking.
Useful for cleanup or debugging."
  (interactive)
  (clrhash ogent-tool-fsm--active-calls)
  (ogent-tool-fsm--log "Reset FSM state"))

(defun ogent-tool-fsm-status ()
  "Display status of active tool calls."
  (interactive)
  (let ((count (hash-table-count ogent-tool-fsm--active-calls)))
    (if (zerop count)
        (message "No active tool calls")
      (message "%d active tool call(s)" count)
      (maphash
       (lambda (id call)
         (message "  %s: %s [%s]"
                  id
                  (ogent-tool-call-name call)
                  (ogent-tool-call-status call)))
       ogent-tool-fsm--active-calls))))

(provide 'ogent-tool-fsm)

;;; ogent-tool-fsm.el ends here
