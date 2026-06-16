;;; ogent-ui-toolcalls.el --- Tool execution, drawers, and inline diffs -*- lexical-binding: t; -*-

;;; Commentary:
;; The tool-call subsystem for ogent UI: synchronous/async tool execution
;; with ledger wrapping, Org `:TOOL:' drawer rendering (including the
;; streaming drawer state machine), and inline/unified diff previews with
;; accept/reject for edit-tool proposals.

;;; Code:

(require 'cl-lib)
(require 'ogent-ui-core)
(require 'ogent-ui-format)
(require 'ogent-tool-approval)
(require 'ogent-ledger)
(require 'ogent-edit-format)

;; Specials read/let-bound by the tool subsystem.
(defvar ogent-zen-mode)
(defvar ogent-zen-tool-calls-inline)
(defvar ogent-tools-project-root)
(defvar ogent-edit-display-method)

;; Zen out-of-band tool recording (decoupled: declare + fboundp, never required).
(declare-function ogent-zen--tool-record-active-p "ogent-zen-tools" ())
(declare-function ogent-zen-record-tool-call
                  "ogent-zen-tools" (name args result &optional status context))
(declare-function ogent-zen-tool-record-append "ogent-zen-tools" (record chunk))
(declare-function ogent-zen-tool-record-finish
                  "ogent-zen-tools" (record status &optional detail))
(declare-function org-fold-region "org-fold" (from to flag &optional spec))

;; Inline-edit display (loaded lazily by the edit subsystem).
(declare-function ogent-edit-display-all "ogent-edit-display")
(declare-function ogent-edit-inline-diff-available-p "ogent-edit-display")

;; Tool execution helpers from sibling subsystems.
(declare-function ogent-debug-log-tool-call "ogent-debug")
(declare-function ogent-tool--bash-async "ogent-tools")
(declare-function ogent-tools--resolve-path "ogent-tools")
(declare-function ogent-tools--project-root "ogent-tools")

(defun ogent-ui--async-tool-p (tool-name)
  "Return non-nil if TOOL-NAME supports async streaming execution.
Checks the tool spec for an :async-function property."
  (and ogent-stream-tool-output
       (when-let* ((tool-symbol (ogent-tool--name-symbol tool-name))
                   (spec (and (fboundp 'ogent-tool-spec-get)
                              (ogent-tool-spec-get tool-symbol))))
         (plist-get spec :async-function))))

(defun ogent-ui--make-streaming-callback (drawer callback-style)
  "Create a callback function for DRAWER based on CALLBACK-STYLE.
CALLBACK-STYLE is :stream (bash-style) or :match (grep-style)."
  (pcase callback-style
    ;; Stream style: (stdout chunk), (stderr chunk), (done exit-code), (error msg)
    (:stream
     (lambda (type data)
       (pcase type
         ((or 'stdout 'chunk)
          (ogent-ui--streaming-drawer-append drawer data))
         ('stderr
          (ogent-ui--streaming-drawer-append drawer (propertize data 'face 'error)))
         ('done
          (ogent-ui--streaming-drawer-finalize
           drawer
           (if (= data 0) 'success 'error)
           data)
          (ogent-ui--streaming-drawer-cleanup drawer))
         ('error
          (ogent-ui--streaming-drawer-append
           drawer (format "\n[Error: %s]" data))
          (ogent-ui--streaming-drawer-finalize drawer 'error)
          (ogent-ui--streaming-drawer-cleanup drawer)))))
    ;; Match style: (match line), (done count), (error msg)
    (:match
     (let ((line-count 0))
       (lambda (type data)
         (pcase type
           ('match
            (cl-incf line-count)
            (ogent-ui--streaming-drawer-append drawer (concat data "\n")))
           ('done
            (ogent-ui--streaming-drawer-finalize
             drawer 'success
             (format "%d matches" data))
            (ogent-ui--streaming-drawer-cleanup drawer))
           ('error
            (ogent-ui--streaming-drawer-append
             drawer (format "\n[Error: %s]" data))
            (ogent-ui--streaming-drawer-finalize drawer 'error)
            (ogent-ui--streaming-drawer-cleanup drawer))))))
    ;; Default: treat as stream style
    (_
     (ogent-ui--make-streaming-callback drawer :stream))))

(defun ogent-ui--execute-tool-async (tool-name tool-args)
  "Execute TOOL-NAME with TOOL-ARGS asynchronously with streaming output.
Returns the streaming drawer struct.  Output is streamed to the drawer.
Uses the :async-function and :async-callback-style from the tool spec."
  (let* ((drawer (ogent-ui--insert-streaming-drawer tool-name tool-args))
         (spec (and (fboundp 'ogent-tool-spec-get)
                    (when-let ((tool-symbol (ogent-tool--name-symbol tool-name)))
                      (ogent-tool-spec-get tool-symbol))))
         (async-func (plist-get spec :async-function))
         (callback-style (or (plist-get spec :async-callback-style) :stream))
         (arg-values (ogent-ui--extract-tool-args spec tool-args))
         (base-callback (ogent-ui--make-streaming-callback drawer callback-style)))
    (if (and async-func (fboundp async-func))
        ;; Call the async function with args + a ledger-wrapped callback.
        (let* ((tool-call (ogent-ui--tool-ledger-call tool-name tool-args))
               (effects (plist-get spec :effects))
               (start (current-time))
               (callback
                (lambda (type data)
                  (when (memq type '(done error))
                    (ogent-ledger-record-tool-finish
                     tool-call (and (eq type 'done) data)
                     (and (eq type 'error) (format "%s" data))
                     (float-time (time-subtract (current-time) start))
                     effects))
                  (funcall base-callback type data))))
          (ogent-ledger-record-tool-start tool-call effects)
          (apply async-func (append arg-values (list callback))))
      ;; Fallback: no async function found. ogent-ui--execute-tool records
      ;; its own ledger events.
      (let ((result (ogent-ui--execute-tool tool-name tool-args)))
        (ogent-ui--streaming-drawer-append drawer result)
        (ogent-ui--streaming-drawer-finalize drawer 'success)
        (ogent-ui--streaming-drawer-cleanup drawer)))
    drawer))

(defun ogent-ui--handle-tool-calls (request tool-calls _info)
  "Handle TOOL-CALLS from gptel response for REQUEST.
Each tool call is checked for approval, then executed if approved.
Edit tools (write-file, edit-file) show a diff preview for accept/reject.
Results are displayed in the buffer."
  (let ((buffer (ogent-ui-request-buffer request))
        (workspace-root (plist-get (ogent-ui-request-context request)
                                   :workspace-root)))
    (with-current-buffer buffer
      (let ((ogent-tools-project-root workspace-root)
            (default-directory (or workspace-root default-directory)))
        (save-excursion
          (goto-char (or (ogent-ui-request-response-pos request) (point-max)))
          (dolist (tool-call tool-calls)
            ;; Debug: log the raw tool-call structure
            (when (bound-and-true-p ogent-ui-debug-stream-completion)
              (message "[ogent-debug] tool-call raw: %S" tool-call))
            (let* ((raw-tool-name (plist-get tool-call :name))
                   (tool-name (ogent-tool--name-string raw-tool-name))
                   ;; gptel normalizes to :args, but check
                   ;; :input/:arguments as fallback.
                   (tool-args (or (plist-get tool-call :args)
                                  (plist-get tool-call :input)
                                  (plist-get tool-call :arguments))))
              (if (not tool-name)
                  (ogent-ui--insert-tool-block
                   "unknown" tool-args "[Malformed tool call: missing name]")
                (let ((approval (ogent-tool-approval-check tool-name tool-args)))
                  (pcase approval
                    (`approved
                     (cond
                      ;; Edit tools: show diff preview.
                      ((ogent-ui--is-edit-tool-p tool-name)
                       (condition-case err
                           (ogent-ui--show-diff-for-tool tool-name tool-args)
                         (error
                          (ogent-ui--insert-tool-block
                           tool-name tool-args
                           (format "[Diff preview error: %s]"
                                   (error-message-string err))))))
                      ;; Async-capable tools: stream output incrementally.
                      ((ogent-ui--async-tool-p tool-name)
                       (ogent-ui--execute-tool-async tool-name tool-args))
                      ;; All other tools: execute synchronously.
                      (t
                       (let ((result (ogent-ui--execute-tool tool-name
                                                             tool-args)))
                         (ogent-ui--insert-tool-block tool-name tool-args
                                                      result)))))
                    (`denied
                     (ogent-ui--insert-tool-block
                      tool-name tool-args
                      "[Tool execution denied by user]")))))))))))


)

(defun ogent-ui--tool-ledger-effects (name)
  "Return the declared :effects for tool NAME, or nil."
  (when-let* ((tool-symbol (ogent-tool--name-symbol name))
              (spec (and (fboundp 'ogent-tool-spec-get)
                         (ogent-tool-spec-get tool-symbol))))
    (plist-get spec :effects)))

(defun ogent-ui--tool-ledger-call (name args)
  "Build a ledger tool-call plist for NAME with ARGS."
  (list :name (ogent-tool--name-string name) :args args))

(defun ogent-ui--execute-tool (name args)
  "Execute tool NAME with ARGS and return result string.
Looks up tool in `ogent-tool-registry' and calls its function.
Records start/finish to the proof ledger (a no-op unless
`ogent-ledger-enabled') and, when `ogent-debug' is loaded, appends to
the inspectable tool-call history that powers `ogent-debug-replay-tool'."
  (if-let* ((tool-symbol (ogent-tool--name-symbol name))
            (spec (and (fboundp 'ogent-tool-spec-get)
                       (ogent-tool-spec-get tool-symbol)))
            (func (plist-get spec :function)))
      (let* ((tool-call (ogent-ui--tool-ledger-call name args))
             ;; History entries key on a symbol name and carry an id.
             (history-call (list :id (format "tool-%d" (abs (random)))
                                 :name tool-symbol :args args))
             (effects (plist-get spec :effects))
             (start (current-time)))
        (ogent-ledger-record-tool-start tool-call effects)
        (condition-case err
            (let* ((arg-values (ogent-ui--extract-tool-args spec args))
                   (result (apply func arg-values))
                   (duration (float-time (time-subtract (current-time) start))))
              (ogent-ledger-record-tool-finish tool-call result nil duration effects)
              (when (fboundp 'ogent-debug-log-tool-call)
                (ogent-debug-log-tool-call history-call result duration))
              result)
          (error
           (let ((msg (error-message-string err))
                 (duration (float-time (time-subtract (current-time) start))))
             (ogent-ledger-record-tool-finish tool-call nil msg duration effects)
             (when (fboundp 'ogent-debug-log-tool-call)
               (ogent-debug-log-tool-call
                (plist-put history-call :error msg) nil duration))
             (format "Tool error: %s" msg)))))
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

(defun ogent-ui--fold-tool-drawer-region (start end)
  "Fold the Org tool drawer spanning START to END.
Zen buffers hide the entire drawer, including the `:TOOL:' line, because
the run-card headline already carries the usable summary.  Plain Org
buffers keep the normal drawer header visible."
  (when (derived-mode-p 'org-mode)
    (let ((start (if (markerp start) (marker-position start) start))
          (end (if (markerp end) (marker-position end) end)))
      (condition-case nil
          (if (and (bound-and-true-p ogent-zen-mode)
                   (fboundp 'org-fold-region))
              (org-fold-region start end t 'drawer)
            (save-excursion
              (goto-char start)
              (when (fboundp 'org-hide-drawer-toggle)
                (org-hide-drawer-toggle t))))
        (error nil)))))

(defun ogent-ui--tool-result-status (result)
  "Return `error' when RESULT is a tool error or denial string, else `done'."
  (if (and (stringp result)
           (string-match-p "\\[.*error\\|denied\\]" result))
      'error 'done))

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
    (ogent-ui--fold-tool-drawer-region drawer-start drawer-end)
    tool-id))

(defun ogent-ui--insert-tool-block (name args result)
  "Insert a tool block with NAME, ARGS, and RESULT.
In Zen buffers (unless `ogent-zen-tool-calls-inline'), record the call
out of band instead of inserting a drawer so the notebook stays small."
  (or (and (fboundp 'ogent-zen--tool-record-active-p)
           (ogent-zen--tool-record-active-p)
           (ogent-zen-record-tool-call
            name args result
            (ogent-ui--tool-result-status result)
            (ogent-ui--tool-context-summary name args))
           t)
      (ogent-ui--insert-tool-drawer name args result)))

(cl-defstruct ogent-streaming-drawer
  "State for a streaming tool drawer."
  id
  buffer
  drawer-start     ; marker at :TOOL:
  result-start     ; marker at start of result content
  result-end       ; marker at end of result content (before #+end_src)
  status-marker    ; marker at status icon position
  name
  args
  char-count       ; total chars streamed
  record)          ; non-nil => virtual recorder; no buffer drawer

(defun ogent-ui--insert-streaming-drawer (name args)
  "Insert a streaming tool drawer for NAME with ARGS.
In Zen buffers (unless `ogent-zen-tool-calls-inline'), record the call
out of band and return a virtual drawer instead of inserting buffer text.
Returns an `ogent-streaming-drawer' struct for updating the drawer."
  (if (and (fboundp 'ogent-zen--tool-record-active-p)
           (ogent-zen--tool-record-active-p))
      (if-let ((record (ogent-zen-record-tool-call
                        name args "" 'running
                        (ogent-ui--tool-context-summary name args))))
          (make-ogent-streaming-drawer
           :id (format "tool-%d" (cl-incf ogent-ui--tool-seq))
           :buffer (current-buffer)
           :name (if (stringp name) name (symbol-name name))
           :args args :char-count 0 :record record)
        (ogent-ui--insert-streaming-drawer-inline name args))
    (ogent-ui--insert-streaming-drawer-inline name args)))

(defun ogent-ui--insert-streaming-drawer-inline (name args)
  "Insert a streaming tool drawer for NAME with ARGS as buffer text.
Returns an `ogent-streaming-drawer' struct for updating the drawer."
  (let* ((tool-id (format "tool-%d" (cl-incf ogent-ui--tool-seq)))
         (context (ogent-ui--tool-context-summary name args))
         (icon (ogent-ui--tool-status-icon 'running))
         (name-str (if (stringp name) name (symbol-name name)))
         (drawer-start (point-marker))
         result-start result-end status-marker)
    ;; Insert drawer header
    (insert ":TOOL:\n")
    (insert (format "▶ %s: %s " name-str context))
    (setq status-marker (point-marker))
    (insert (format "%s\n" icon))
    ;; Args block
    (insert "#+begin_src elisp :args\n")
    (insert (pp-to-string args))
    (unless (bolp) (insert "\n"))
    (insert "#+end_src\n")
    ;; Result block - initially empty with markers
    (insert "#+begin_src text :result\n")
    (setq result-start (point-marker))
    (set-marker-insertion-type result-start nil)  ; grows with inserted text
    (insert "(running...)\n")
    (setq result-end (point-marker))
    (set-marker-insertion-type result-end t)  ; stays at end
    (insert "#+end_src\n")
    (insert ":END:\n")
    (ogent-ui--fold-tool-drawer-region (marker-position drawer-start)
                                       (point))
    ;; Add text properties (will update when finalized)
    (add-text-properties (marker-position drawer-start) (point)
                         (list 'ogent-tool-id tool-id
                               'ogent-tool-name (intern name-str)
                               'ogent-tool-status 'running
                               'ogent-tool-args args))
    (make-ogent-streaming-drawer
     :id tool-id
     :buffer (current-buffer)
     :drawer-start drawer-start
     :result-start result-start
     :result-end result-end
     :status-marker status-marker
     :name name-str
     :args args
     :char-count 0)))

(defun ogent-ui--streaming-drawer-append (drawer chunk)
  "Append CHUNK to streaming DRAWER's result section.
Returns nil if drawer buffer is dead."
  (if-let ((record (ogent-streaming-drawer-record drawer)))
      (let ((text (if (stringp chunk) chunk (format "%s" chunk))))
        (ogent-zen-tool-record-append record text)
        (setf (ogent-streaming-drawer-char-count drawer)
              (+ (ogent-streaming-drawer-char-count drawer) (length text)))
        t)
    (let ((buf (ogent-streaming-drawer-buffer drawer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (save-excursion
            (let ((inhibit-read-only t)
                  (result-start (ogent-streaming-drawer-result-start drawer))
                  (result-end (ogent-streaming-drawer-result-end drawer))
                  (count (ogent-streaming-drawer-char-count drawer)))
              ;; On first chunk, remove "(running...)" placeholder
              (when (= count 0)
                (goto-char result-start)
                (when (looking-at "(running\\.\\.\\.)\n")
                  (delete-region result-start (match-end 0))))
              ;; Append chunk at result-end
              (goto-char result-end)
              (insert chunk)
              ;; Update char count
              (setf (ogent-streaming-drawer-char-count drawer)
                    (+ count (length chunk))))))
        t))))

(defun ogent-ui--streaming-drawer-finalize (drawer status &optional exit-code)
  "Finalize streaming DRAWER with STATUS and optional EXIT-CODE.
STATUS is `success', `error', or other status symbol."
  (if-let ((record (ogent-streaming-drawer-record drawer)))
      (progn
        (when exit-code
          (ogent-zen-tool-record-append
           record (format "\nExit code: %s" exit-code)))
        (ogent-zen-tool-record-finish
         record (if (eq status 'success) 'done status)))
    (let ((buf (ogent-streaming-drawer-buffer drawer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (save-excursion
            (let* ((inhibit-read-only t)
                   (drawer-start (ogent-streaming-drawer-drawer-start drawer))
                   (status-marker (ogent-streaming-drawer-status-marker drawer))
                   (result-end (ogent-streaming-drawer-result-end drawer))
                   (new-icon (ogent-ui--tool-status-icon status))
                   (drawer-end (save-excursion
                                 (goto-char drawer-start)
                                 (when (re-search-forward "^:END:$" nil t)
                                   (line-end-position)))))
              ;; Update status icon
              (goto-char status-marker)
              (when (looking-at ".")
                (delete-char 1)
                (insert new-icon))
              ;; Add exit code line if provided
              (when exit-code
                (goto-char result-end)
                (insert (format "\nExit code: %s" exit-code)))
              ;; Update text properties
              (when drawer-end
                (put-text-property drawer-start drawer-end
                                   'ogent-tool-status status))
              (ogent-ui--fold-tool-drawer-region
               drawer-start (or drawer-end result-end)))))))))

(defun ogent-ui--streaming-drawer-cleanup (drawer)
  "Clean up markers from DRAWER."
  (unless (ogent-streaming-drawer-record drawer)
    (set-marker (ogent-streaming-drawer-drawer-start drawer) nil)
    (set-marker (ogent-streaming-drawer-result-start drawer) nil)
    (set-marker (ogent-streaming-drawer-result-end drawer) nil)
    (set-marker (ogent-streaming-drawer-status-marker drawer) nil)))

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
              (error nil))))))))

(defun ogent-tool--replace-result-at-point (new-result)
  "Replace the result in the current tool drawer with NEW-RESULT."
  (save-excursion
    ;; Find drawer boundaries
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
              (insert (if (stringp new-result)
                          new-result
                        (pp-to-string new-result)))
              (unless (bolp)
                (insert "\n")))))
        ;; Update status icon in header (now on second line)
        (goto-char drawer-start)
        (forward-line 1)
        (when (re-search-forward "\\([○◐✓✗]\\)" (line-end-position) t)
          (replace-match (ogent-ui--tool-status-icon 'success)))))))

(defcustom ogent-ui-edit-preview-style 'diff-block
  "How to display edit tool previews.
When set to `diff-block', show unified diffs in the companion buffer.
When set to `inline-diff', display inline diff previews in the source buffer."
  :type '(choice (const :tag "Unified diff block" diff-block)
                 (const :tag "Inline diff preview" inline-diff))
  :group 'ogent)

(defun ogent-ui--inline-diff-available-p ()
  "Return non-nil if inline diff preview is available."
  (and (require 'ogent-edit-display nil 'noerror)
       (or (and (fboundp 'ogent-edit-inline-diff-available-p)
                (ogent-edit-inline-diff-available-p))
           (require 'inline-diff nil 'noerror))))

(defun ogent-ui--tool-edit-occurrences (buffer old-string)
  "Return list of (START . END) occurrences of OLD-STRING in BUFFER."
  (when (string-empty-p old-string)
    (error "Old string is empty; cannot build inline diff edits"))
  (let (positions)
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (while (search-forward old-string nil t)
          (push (cons (match-beginning 0) (match-end 0)) positions))))
    (nreverse positions)))

(defun ogent-ui--tool-edits-for-inline-diff (tool-name tool-args buffer)
  "Return list of `ogent-edit' structs for TOOL-NAME/TOOL-ARGS in BUFFER."
  (require 'ogent-edit-format)
  (let ((file-path (or (plist-get tool-args :file-path)
                       (plist-get tool-args :file_path))))
    (pcase tool-name
      ("write-file"
       (let ((content (plist-get tool-args :content)))
         (unless content
           (error "No content in tool args"))
         (with-current-buffer buffer
           (list (make-ogent-edit
                  :id (ogent-edit--generate-id)
                  :old-text (buffer-substring-no-properties (point-min) (point-max))
                  :new-text content
                  :source-buffer buffer
                  :source-file file-path
                  :start-pos (point-min)
                  :end-pos (point-max)
                  :status 'pending
                  :timestamp (current-time))))))
      ("edit-file"
       (let* ((old-string (or (plist-get tool-args :old-string)
                              (plist-get tool-args :old_string)))
              (new-string (or (plist-get tool-args :new-string)
                              (plist-get tool-args :new_string)))
              (replace-all (or (plist-get tool-args :replace-all)
                               (plist-get tool-args :replace_all)))
              (positions (and old-string
                              (ogent-ui--tool-edit-occurrences buffer old-string))))
         (unless old-string
           (error "No old-string in tool args"))
         (unless new-string
           (error "No new-string in tool args"))
         (unless positions
           (error "Old string not found in buffer for %s" file-path))
         (let* ((targets (if replace-all positions (list (car positions)))))
           (with-current-buffer buffer
             (mapcar (lambda (pos)
                       (let ((old-text (buffer-substring-no-properties (car pos) (cdr pos))))
                         (make-ogent-edit
                          :id (ogent-edit--generate-id)
                          :old-text old-text
                          :new-text new-string
                          :source-buffer buffer
                          :source-file file-path
                          :start-pos (car pos)
                          :end-pos (cdr pos)
                          :status 'pending
                          :timestamp (current-time))))
                     targets)))))
      (_ (error "Unknown edit tool: %s" tool-name)))))

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
  (if (and (eq ogent-ui-edit-preview-style 'inline-diff)
           (ogent-ui--inline-diff-available-p))
      (ogent-ui--show-inline-diff-for-tool tool-name tool-args)
    (when (eq ogent-ui-edit-preview-style 'inline-diff)
      (message "Inline diff not available; falling back to diff block preview."))
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
             (let ((content (plist-get tool-args :content)))
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
      diff-id))))

(defun ogent-ui--show-inline-diff-for-tool (tool-name tool-args)
  "Show an inline diff preview for TOOL-NAME with TOOL-ARGS.
Returns a generated diff-id for tracking."
  (unless (ogent-ui--inline-diff-available-p)
    (error "inline-diff not available"))
  (let* ((diff-id (ogent-ui--next-diff-id))
         (file-path (or (plist-get tool-args :file-path)
                        (plist-get tool-args :file_path))))
    (unless file-path
      (error "No file path in tool args"))
    (let* ((buffer (find-file-noselect file-path))
           (edits (ogent-ui--tool-edits-for-inline-diff tool-name tool-args buffer)))
      (with-current-buffer buffer
        (let ((ogent-edit-display-method 'inline-diff))
          (ogent-edit-display-all edits)))
      (display-buffer buffer)
      (ogent-ui--insert-tool-block
       tool-name
       tool-args
       (format (concat "Inline diff preview opened in %s "
                       "(%d change(s)). Use C-c C-c to accept, "
                       "C-c C-k to reject, then save the buffer.")
               file-path
               (length edits))))
    diff-id))

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

(provide 'ogent-ui-toolcalls)
;;; ogent-ui-toolcalls.el ends here
