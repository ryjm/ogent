;;; ogent-tool-render.el --- Render tool invocations in org-mode -*- lexical-binding: t; -*-

;;; Commentary:
;; Display tool invocations and results as collapsible org drawer blocks.
;; Provides visual feedback for tool execution state and results.
;;
;; Tool calls are rendered as:
;;   :TOOL_CALL: tool-name-123
;;   Status: ⏳ pending
;;   Tool: read-file
;;   Arguments:
;;   - file_path: /path/to/file.txt
;;   - limit: 100
;;   :END:
;;
;; Results are appended inside the drawer when available.

;;; Code:

(require 'cl-lib)
(require 'org)

(defgroup ogent-tool-render nil
  "Configuration for ogent tool rendering."
  :group 'ogent)

(defcustom ogent-tool-render-show-timestamps t
  "Whether to show timestamps for tool invocations."
  :type 'boolean
  :group 'ogent-tool-render)

(defvar ogent-tool-render--id-counter 0
  "Counter for generating unique tool call IDs.")

;;; Status Indicators

(defconst ogent-tool-render-status-indicators
  '((pending . "⏳")
    (running . "🔄")
    (completed . "✓")
    (failed . "✗"))
  "Status indicators for tool execution states.")

(defun ogent-tool-render--status-indicator (status)
  "Return the unicode indicator for STATUS."
  (or (alist-get status ogent-tool-render-status-indicators)
      "?"))

(defun ogent-tool-render--stringify (value)
  "Return VALUE as display text."
  (if (stringp value)
      value
    (format "%S" value)))

(defun ogent-tool-render--single-line (value)
  "Return VALUE as text with record separators escaped."
  (replace-regexp-in-string
   "[\r\n]+"
   (lambda (_match) "\\n")
   (ogent-tool-render--stringify value)
   t t))

(defun ogent-tool-render--escape-example-content (content)
  "Escape CONTENT for literal insertion in an Org example block."
  (let ((case-fold-search t))
    (replace-regexp-in-string
     "^\\([ \t]*\\)\\([#][+]\\|[*]\\|,\\|:END:\\)"
     "\\1,\\2"
     content)))

(defun ogent-tool-render--sanitize-id-part (value)
  "Return VALUE as a drawer-safe identifier part."
  (replace-regexp-in-string
   "[^[:alnum:]_-]+"
   "_"
   (ogent-tool-render--single-line value)))

(defun ogent-tool-render--drawer-name (id)
  "Return the drawer name for tool call ID."
  (format "TOOL_CALL_%s" (ogent-tool-render--sanitize-id-part id)))

(defun ogent-tool-render--drawer-region (drawer-name)
  "Return the region occupied by DRAWER-NAME, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (format "^[ \t]*:%s:[ \t]*$" (regexp-quote drawer-name))
           nil t)
      (let ((start (line-beginning-position)))
        (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
          (cons start (min (point-max) (1+ (line-end-position)))))))))

;;; Tool Call Data Structure

(cl-defstruct (ogent-tool-call
               (:constructor ogent-tool-call-create)
               (:copier nil))
  "Represents a tool invocation with execution state."
  (id nil :read-only t
      :documentation "Unique identifier for this tool call.")
  (name nil :read-only t
        :documentation "Tool name (symbol or string).")
  (args nil
        :documentation "Plist of arguments passed to tool.")
  (status 'pending
          :documentation "Execution status: pending, running, completed, failed.")
  (result nil
          :documentation "Result returned by tool (on success).")
  (error nil
         :documentation "Error message (on failure).")
  (start-marker nil
                :documentation "Buffer marker for start of drawer.")
  (end-marker nil
              :documentation "Buffer marker for end of drawer.")
  (timestamp nil
             :documentation "Time when tool was invoked."))

;;; Rendering Functions

(defun ogent-tool-render-call (tool-call &optional insert-at-point)
  "Render TOOL-CALL as an org drawer.
If INSERT-AT-POINT is non-nil, insert at current point.
Otherwise, search for existing drawer by ID and update it.
Returns the created/updated drawer markers as (START . END)."
  (unless (ogent-tool-call-p tool-call)
    (error "Expected ogent-tool-call struct, got: %S" tool-call))
  
  (let* ((id (ogent-tool-call-id tool-call))
         (name (ogent-tool-call-name tool-call))
         (args (ogent-tool-call-args tool-call))
         (status (ogent-tool-call-status tool-call))
         (result (ogent-tool-call-result tool-call))
         (error-msg (ogent-tool-call-error tool-call))
         (timestamp (or (ogent-tool-call-timestamp tool-call)
                        (current-time)))
         (drawer-name (ogent-tool-render--drawer-name id))
         (start-pos (point))
         existing-region
         start-marker end-marker)
    
    ;; Try to find existing drawer if not inserting new
    (unless insert-at-point
      (setq existing-region (ogent-tool-render--drawer-region drawer-name))
      (when existing-region
        (setq start-pos (car existing-region))))
    
    (goto-char start-pos)
    
    ;; If updating existing, delete the old content
    (cond
     ((and (not insert-at-point)
           (ogent-tool-call-start-marker tool-call))
      (let ((old-start (marker-position (ogent-tool-call-start-marker tool-call)))
            (old-end (marker-position (ogent-tool-call-end-marker tool-call))))
        (when (and old-start old-end)
          (delete-region old-start old-end)
          (goto-char old-start))))
     ((and (not insert-at-point) existing-region)
      (delete-region (car existing-region) (cdr existing-region))
      (goto-char (car existing-region))))
    
    ;; Insert drawer
    (setq start-marker (point-marker))
    (insert (format ":%s:\n" drawer-name))
    (insert (format "Status: %s %s\n"
                    (ogent-tool-render--status-indicator status)
                    status))
    (insert (format "Tool: %s\n" name))
    
    (when ogent-tool-render-show-timestamps
      (insert (format "Time: %s\n"
                      (format-time-string "%Y-%m-%d %H:%M:%S" timestamp))))
    
    ;; Render arguments
    (when args
      (insert "Arguments:\n")
      (let ((arg-pairs (ogent-tool-render--plist-to-pairs args)))
        (dolist (pair arg-pairs)
          (insert (format "- %s: %s\n"
                          (car pair)
                          (ogent-tool-render--format-value (cdr pair)))))))
    
    ;; Insert result if available
    (when result
      (insert "\nResult:\n")
      (insert "#+begin_example\n")
      (insert (ogent-tool-render--truncate-result result))
      (insert "\n#+end_example\n"))
    
    ;; Insert error if available
    (when error-msg
      (insert "\nError:\n")
      (insert "#+begin_example\n")
      (insert (ogent-tool-render--truncate-result error-msg))
      (insert "\n#+end_example\n"))
    
    (insert ":END:\n")
    (setq end-marker (point-marker))
    
    ;; Update markers in struct
    (setf (ogent-tool-call-start-marker tool-call) start-marker)
    (setf (ogent-tool-call-end-marker tool-call) end-marker)
    (setf (ogent-tool-call-timestamp tool-call) timestamp)
    
    (cons start-marker end-marker)))

(defun ogent-tool-render--plist-to-pairs (plist)
  "Convert PLIST to list of (key . value) pairs."
  (let (pairs)
    (while (consp plist)
      (let ((key (car plist)))
        (push (cons (cond
                     ((keywordp key)
                      (substring (symbol-name key) 1))
                     ((symbolp key)
                      (symbol-name key))
                     (t
                      (ogent-tool-render--single-line key)))
                    (cadr plist))
              pairs))
      (setq plist (cddr plist)))
    (nreverse pairs)))

(defun ogent-tool-render--format-value (value)
  "Format VALUE for display in drawer."
  (let ((text (ogent-tool-render--single-line value)))
    (if (> (length text) 60)
        (concat (substring text 0 57) "...")
      text)))

(defun ogent-tool-render-update-status (tool-call new-status)
  "Update the status of TOOL-CALL to NEW-STATUS and re-render.
NEW-STATUS should be one of: pending, running, completed, failed."
  (unless (memq new-status '(pending running completed failed))
    (error "Invalid status: %s" new-status))
  
  (setf (ogent-tool-call-status tool-call) new-status)
  
  ;; Re-render the drawer
  (when (ogent-tool-call-start-marker tool-call)
    (save-excursion
      (goto-char (marker-position (ogent-tool-call-start-marker tool-call)))
      (ogent-tool-render-call tool-call nil))))

(defun ogent-tool-render-insert-result (tool-call result)
  "Insert RESULT into the drawer for TOOL-CALL.
Updates status to \\='completed if not already failed."
  (setf (ogent-tool-call-result tool-call) result)
  (when (eq (ogent-tool-call-status tool-call) 'running)
    (setf (ogent-tool-call-status tool-call) 'completed))
  
  ;; Re-render to show result
  (when (ogent-tool-call-start-marker tool-call)
    (save-excursion
      (goto-char (marker-position (ogent-tool-call-start-marker tool-call)))
      (ogent-tool-render-call tool-call nil))))

(defun ogent-tool-render-insert-error (tool-call error-message)
  "Insert ERROR-MESSAGE into the drawer for TOOL-CALL.
Updates status to \\='failed."
  (setf (ogent-tool-call-error tool-call) error-message)
  (setf (ogent-tool-call-status tool-call) 'failed)
  
  ;; Re-render to show error
  (when (ogent-tool-call-start-marker tool-call)
    (save-excursion
      (goto-char (marker-position (ogent-tool-call-start-marker tool-call)))
      (ogent-tool-render-call tool-call nil))))

(defun ogent-tool-render--truncate-result (result)
  "Truncate RESULT if it's too long for display."
  (let* ((text (ogent-tool-render--stringify result))
         (max-length 2000)
         (truncated
          (if (> (length text) max-length)
              (concat (substring text 0 max-length)
                      "\n\n[... truncated, total length: "
                      (number-to-string (length text))
                      " chars]")
            text)))
    (ogent-tool-render--escape-example-content truncated)))

;;; Navigation

(defun ogent-tool-render-next-call ()
  "Move to the next tool call drawer."
  (interactive)
  (let ((start (point)))
    (end-of-line)
    (if (re-search-forward "^[ \t]*:TOOL_CALL_[^:]+:[ \t]*$" nil t)
        (beginning-of-line)
      (goto-char start)
      (message "No more tool calls"))))

(defun ogent-tool-render-prev-call ()
  "Move to the previous tool call drawer."
  (interactive)
  (let ((start (point)))
    (beginning-of-line)
    (if (re-search-backward "^[ \t]*:TOOL_CALL_[^:]+:[ \t]*$" nil t)
        (beginning-of-line)
      (goto-char start)
      (message "No previous tool calls"))))

;;; Keybindings

(defvar ogent-tool-render-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c t n") #'ogent-tool-render-next-call)
    (define-key map (kbd "C-c t p") #'ogent-tool-render-prev-call)
    map)
  "Keymap for `ogent-tool-render-mode'.")

(define-minor-mode ogent-tool-render-mode
  "Minor mode for navigating tool call drawers in org buffers."
  :lighter " ToolRender"
  :keymap ogent-tool-render-mode-map)

;;; Convenience Functions

(defun ogent-tool-render-create-and-insert (name args)
  "Create a tool call with NAME and ARGS, insert it at point, and return it.
NAME is the tool name (string or symbol).
ARGS is a plist of arguments to pass to the tool.
The tool call is created with a unique ID and `pending' status."
  (let* ((name-str (if (symbolp name) (symbol-name name) name))
         (id (format "%s-%d"
                     (ogent-tool-render--sanitize-id-part name-str)
                     (cl-incf ogent-tool-render--id-counter)))
         (tool-call (ogent-tool-call-create
                     :id id
                     :name name-str
                     :args args
                     :status 'pending)))
    (ogent-tool-render-call tool-call t)
    tool-call))

(provide 'ogent-tool-render)

;;; ogent-tool-render.el ends here
