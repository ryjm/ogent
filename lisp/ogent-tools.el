;;; ogent-tools.el --- Tool implementations for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Core tool implementations for ogent's LLM function calling.
;; These tools mirror Claude Code's tool set for familiar UX.
;;
;; Tools are registered via `ogent-tool-registry' in ogent-models.el
;; and executed by gptel's tool-use FSM.

;;; Code:

(require 'cl-lib)

;; Forward declaration for variable defined in ogent-models.el
(defvar ogent-tool-registry)

(defgroup ogent-tools nil
  "Configuration for ogent tool implementations."
  :group 'ogent)

(defcustom ogent-tools-max-file-lines 2000
  "Maximum lines to return from file read operations."
  :type 'integer
  :group 'ogent-tools)

(defcustom ogent-tools-max-output-chars 30000
  "Maximum characters to return from tool output."
  :type 'integer
  :group 'ogent-tools)

(defcustom ogent-tools-shell-timeout 120
  "Default timeout in seconds for shell commands."
  :type 'integer
  :group 'ogent-tools)

(defcustom ogent-tools-project-root nil
  "Project root for relative path resolution.
If nil, uses `default-directory' or projectile/project.el root."
  :type '(choice (const nil) directory)
  :group 'ogent-tools)

(defcustom ogent-tools-stream-callback nil
  "Function called with streaming output from tools.
If set, receives (TOOL-NAME TYPE DATA) where:
  TOOL-NAME is a symbol like `bash' or `grep'
  TYPE is one of: `start', `stdout', `stderr', `progress', `done', `error'
  DATA varies by type:
    start: plist with :command, :directory
    stdout/stderr: string of output chunk
    progress: plist with :bytes, :lines, :elapsed
    done: plist with :exit-code, :duration
    error: error message string"
  :type '(choice (const nil) function)
  :group 'ogent-tools)

(defcustom ogent-tools-show-progress t
  "Whether to show progress indicators for long-running tools.
When non-nil, displays spinner and byte counts in echo area."
  :type 'boolean
  :group 'ogent-tools)

;;; Streaming Infrastructure

(defvar ogent-tools--progress-timer nil
  "Timer for updating progress display.")

(defvar ogent-tools--progress-state nil
  "Current progress state plist with :tool, :bytes, :lines, :start-time.")

(defconst ogent-tools--spinner-frames '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Frames for progress spinner animation.")

(defvar ogent-tools--spinner-index 0
  "Current spinner frame index.")

(defun ogent-tools--format-bytes (bytes)
  "Format BYTES as human-readable string."
  (cond
   ((< bytes 1024) (format "%d B" bytes))
   ((< bytes (* 1024 1024)) (format "%.1f KB" (/ bytes 1024.0)))
   (t (format "%.1f MB" (/ bytes (* 1024.0 1024.0))))))

(defun ogent-tools--progress-update ()
  "Update the progress display in echo area."
  (when (and ogent-tools-show-progress ogent-tools--progress-state)
    (let* ((tool (plist-get ogent-tools--progress-state :tool))
           (bytes (plist-get ogent-tools--progress-state :bytes))
           (lines (plist-get ogent-tools--progress-state :lines))
           (start (plist-get ogent-tools--progress-state :start-time))
           (elapsed (float-time (time-subtract (current-time) start)))
           (spinner (nth ogent-tools--spinner-index ogent-tools--spinner-frames)))
      (setq ogent-tools--spinner-index
            (mod (1+ ogent-tools--spinner-index)
                 (length ogent-tools--spinner-frames)))
      (message "%s %s: %s | %d lines | %.1fs"
               spinner tool
               (ogent-tools--format-bytes bytes)
               lines elapsed))))

(defun ogent-tools--stream-start (tool-name &optional info)
  "Signal start of streaming for TOOL-NAME with optional INFO plist."
  (setq ogent-tools--progress-state
        (list :tool tool-name
              :bytes 0
              :lines 0
              :start-time (current-time)))
  (setq ogent-tools--spinner-index 0)
  ;; Start progress timer
  (when ogent-tools-show-progress
    (when ogent-tools--progress-timer
      (cancel-timer ogent-tools--progress-timer))
    (setq ogent-tools--progress-timer
          (run-at-time 0.1 0.1 #'ogent-tools--progress-update)))
  ;; Notify callback
  (when ogent-tools-stream-callback
    (funcall ogent-tools-stream-callback tool-name 'start info)))

(defun ogent-tools--stream-output (tool-name type data)
  "Stream output DATA of TYPE for TOOL-NAME.
TYPE is `stdout' or `stderr'."
  (when ogent-tools--progress-state
    ;; Update counters
    (let ((bytes (+ (plist-get ogent-tools--progress-state :bytes)
                    (length data)))
          (lines (+ (plist-get ogent-tools--progress-state :lines)
                    (cl-count ?\n data))))
      (plist-put ogent-tools--progress-state :bytes bytes)
      (plist-put ogent-tools--progress-state :lines lines)))
  ;; Notify callback
  (when ogent-tools-stream-callback
    (funcall ogent-tools-stream-callback tool-name type data)))

(defun ogent-tools--stream-done (tool-name exit-code)
  "Signal completion of TOOL-NAME with EXIT-CODE."
  (let ((duration (when ogent-tools--progress-state
                    (float-time
                     (time-subtract (current-time)
                                    (plist-get ogent-tools--progress-state :start-time))))))
    ;; Stop progress timer
    (when ogent-tools--progress-timer
      (cancel-timer ogent-tools--progress-timer)
      (setq ogent-tools--progress-timer nil))
    ;; Final message
    (when ogent-tools-show-progress
      (message "%s completed (exit %d) in %.1fs"
               (or (plist-get ogent-tools--progress-state :tool) tool-name)
               exit-code
               (or duration 0)))
    ;; Notify callback
    (when ogent-tools-stream-callback
      (funcall ogent-tools-stream-callback tool-name 'done
               (list :exit-code exit-code :duration duration)))
    ;; Clear state
    (setq ogent-tools--progress-state nil)))

(defun ogent-tools--stream-error (tool-name message)
  "Signal error for TOOL-NAME with MESSAGE."
  ;; Stop progress timer
  (when ogent-tools--progress-timer
    (cancel-timer ogent-tools--progress-timer)
    (setq ogent-tools--progress-timer nil))
  ;; Notify callback
  (when ogent-tools-stream-callback
    (funcall ogent-tools-stream-callback tool-name 'error message))
  ;; Clear state
  (setq ogent-tools--progress-state nil))

;;; Helper Functions

(defun ogent-tools--project-root ()
  "Return the project root directory."
  (or ogent-tools-project-root
      (and (fboundp 'projectile-project-root)
           (projectile-project-root))
      (and (fboundp 'project-root)
           (when-let ((proj (project-current)))
             (project-root proj)))
      default-directory))

(defun ogent-tools--resolve-path (path)
  "Resolve PATH to absolute, expanding ~ and relative paths."
  (if (or (file-name-absolute-p path)
          (string-prefix-p "~" path))
      (expand-file-name path)
    (expand-file-name path (ogent-tools--project-root))))

(defun ogent-tools--truncate-output (output max-chars)
  "Truncate OUTPUT to MAX-CHARS, adding notice if truncated."
  (if (> (length output) max-chars)
      (concat (substring output 0 max-chars)
              "\n\n[Output truncated. Total length: "
              (number-to-string (length output)) " chars]")
    output))

;;; Async Process Helpers

(defvar ogent-tools--active-processes nil
  "Alist of (process . callback-info) for active async tool processes.")

(defun ogent-tools--drop-active-process (process)
  "Remove PROCESS from the active async process registry."
  (setq ogent-tools--active-processes
        (assq-delete-all process ogent-tools--active-processes)))

(defun ogent-tools--cancel-timer (timer)
  "Cancel TIMER when it is non-nil."
  (when timer
    (cancel-timer timer)))

(defun ogent-tools--kill-buffer-if-live (buffer)
  "Kill BUFFER when it is still live."
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(defun ogent-tools--format-timeout (seconds)
  "Return SECONDS formatted for timeout messages."
  (if (integerp seconds)
      (format "%ds" seconds)
    (format "%.1fs" seconds)))

;;; Tool: Read File

(defun ogent-tool--read-file (file-path &optional offset limit)
  "Read contents of FILE-PATH.
OFFSET is the starting line number (1-indexed, default 1).
LIMIT is the max lines to read (default `ogent-tools-max-file-lines')."
  (let* ((path (ogent-tools--resolve-path file-path))
         (offset (or offset 1))
         (limit (or limit ogent-tools-max-file-lines)))
    (unless (file-exists-p path)
      (error "File not found: %s" path))
    (unless (file-readable-p path)
      (error "File not readable: %s" path))
    ;; Check for binary
    (when (with-temp-buffer
            (insert-file-contents-literally path nil 0 1000)
            (goto-char (point-min))
            (search-forward "\0" nil t))
      (error "Binary file detected: %s" path))
    ;; Read with line numbers
    (with-temp-buffer
      (insert-file-contents path)
      (let ((lines (split-string (buffer-string) "\n"))
            (result nil)
            (line-num 1))
        (dolist (line lines)
          (when (and (>= line-num offset)
                     (< (length result) limit))
            ;; Truncate very long lines
            (let ((truncated (if (> (length line) 2000)
                                 (concat (substring line 0 2000) "...")
                               line)))
              (push (format "%6d\t%s" line-num truncated) result)))
          (cl-incf line-num))
        (string-join (nreverse result) "\n")))))

;;; Tool: Glob (File Search)

(defun ogent-tool--glob (pattern &optional path)
  "Find files matching glob PATTERN.
PATH is the directory to search (default project root).
Returns files sorted by modification time (newest first)."
  (let* ((dir (if path
                  (ogent-tools--resolve-path path)
                (ogent-tools--project-root)))
         (default-directory dir)
         (files (file-expand-wildcards pattern t)))
    ;; Sort by mtime, newest first
    (setq files
          (sort files
                (lambda (a b)
                  (time-less-p
                   (file-attribute-modification-time (file-attributes b))
                   (file-attribute-modification-time (file-attributes a))))))
    ;; Limit results
    (when (> (length files) 100)
      (setq files (seq-take files 100)))
    (if files
        (string-join files "\n")
      "No files found matching pattern")))

;;; Tool: Grep (Content Search)

(defun ogent-tool--grep (pattern &optional path glob-filter context-lines)
  "Search for PATTERN in files with streaming progress.
PATH is file or directory to search (default project root).
GLOB-FILTER limits to matching files (e.g., \"*.el\").
CONTEXT-LINES shows N lines before/after matches.
Output is streamed incrementally via `ogent-tools-stream-callback'."
  (let* ((dir (if path
                  (ogent-tools--resolve-path path)
                (ogent-tools--project-root)))
         (context (or context-lines 0))
         (use-rg (executable-find "rg"))
         (cmd (if use-rg
                  ;; Use ripgrep if available
                  (format "rg --no-heading --line-number --color=never %s %s %s %s"
                          (if (> context 0) (format "-C %d" context) "")
                          (if glob-filter (format "-g '%s'" glob-filter) "")
                          (shell-quote-argument pattern)
                          (shell-quote-argument dir))
                ;; Fall back to grep
                (format "grep -rn %s %s %s %s"
                        (if (> context 0) (format "-C %d" context) "")
                        (if glob-filter (format "--include='%s'" glob-filter) "")
                        (shell-quote-argument pattern)
                        (shell-quote-argument dir))))
         (default-directory dir)
         (output-buffer (generate-new-buffer " *ogent-grep*"))
         (start-time (current-time))
         exit-code output)
    ;; Signal start
    (ogent-tools--stream-start 'grep
                               (list :pattern pattern
                                     :directory dir
                                     :filter glob-filter))
    (unwind-protect
        (progn
          ;; Use make-process for streaming
          (let ((proc (make-process
                       :name "ogent-grep"
                       :command (list shell-file-name
                                      shell-command-switch
                                      cmd)
                       :buffer output-buffer
                       :sentinel #'ignore
                       :noquery t
                       :filter (lambda (_proc chunk)
                                 (with-current-buffer output-buffer
                                   (goto-char (point-max))
                                   (insert chunk))
                                 (ogent-tools--stream-output 'grep 'stdout chunk)))))
            ;; Wait for completion (grep is usually fast, but can be slow on large codebases)
            (while (process-live-p proc)
              (accept-process-output proc 0.1))
            (setq exit-code (process-exit-status proc)))
          (setq output (with-current-buffer output-buffer
                         (buffer-string))))
      ;; Cleanup
      (kill-buffer output-buffer))
    ;; Signal completion
    (ogent-tools--stream-done 'grep exit-code)
    ;; Format result
    (ogent-tools--truncate-output
     (if (string-empty-p output)
         (format "No matches found (searched in %.1fs)"
                 (float-time (time-subtract (current-time) start-time)))
       (format "%s\n\n[%d matches in %.1fs]"
               output
               (cl-count ?\n output)
               (float-time (time-subtract (current-time) start-time))))
     ogent-tools-max-output-chars)))

(defun ogent-tool--grep-async (pattern &optional path glob-filter context-lines callback)
  "Search for PATTERN asynchronously with streaming.
PATH, GLOB-FILTER, CONTEXT-LINES as in `ogent-tool--grep'.
CALLBACK is called with (TYPE DATA) where TYPE is:
  - `match': DATA is a matched line string
  - `done': DATA is the total match count
  - `error': DATA is an error message
If CALLBACK is nil, results are only reported via `ogent-tools-stream-callback'."
  (let* ((dir (if path
                  (ogent-tools--resolve-path path)
                (ogent-tools--project-root)))
         (context (or context-lines 0))
         (use-rg (executable-find "rg"))
         (cmd (if use-rg
                  (format "rg --no-heading --line-number --color=never %s %s %s %s"
                          (if (> context 0) (format "-C %d" context) "")
                          (if glob-filter (format "-g '%s'" glob-filter) "")
                          (shell-quote-argument pattern)
                          (shell-quote-argument dir))
                (format "grep -rn %s %s %s %s"
                        (if (> context 0) (format "-C %d" context) "")
                        (if glob-filter (format "--include='%s'" glob-filter) "")
                        (shell-quote-argument pattern)
                        (shell-quote-argument dir))))
         (default-directory dir)
         (match-count 0)
         (pending-line "")
         (stderr-buffer (generate-new-buffer " *ogent-grep-stderr*"))
         completed
         proc)
    ;; Signal start
    (ogent-tools--stream-start 'grep
                               (list :pattern pattern
                                     :directory dir
                                     :filter glob-filter))
    (condition-case err
        (cl-labels
            ((emit-line
              (line)
              (unless (string-empty-p line)
                (cl-incf match-count)
                (when callback
                  (funcall callback 'match line))))
             (emit-output
              (output)
              (let* ((text (concat pending-line output))
                     (lines (split-string text "\n")))
                (setq pending-line (car (last lines)))
                (dolist (line (butlast lines))
                  (emit-line line))))
             (stderr-text
              ()
              (if (buffer-live-p stderr-buffer)
                  (with-current-buffer stderr-buffer
                    (buffer-string))
                "")))
          (setq proc (make-process
                      :name "ogent-grep-async"
                      :command (list shell-file-name
                                     shell-command-switch
                                     cmd)
                      :stderr stderr-buffer
                      :noquery t
                      :filter (lambda (_proc output)
                                (ogent-tools--stream-output 'grep 'stdout output)
                                (emit-output output))))
          (when-let ((stderr-proc (get-buffer-process stderr-buffer)))
            (set-process-query-on-exit-flag stderr-proc nil)
            (set-process-filter
             stderr-proc
             (lambda (_proc output)
               (with-current-buffer stderr-buffer
                 (goto-char (point-max))
                 (insert output))
               (ogent-tools--stream-output 'grep 'stderr output))))
          (set-process-sentinel
           proc
           (lambda (process event)
             (unless completed
               (setq completed t)
               (ogent-tools--drop-active-process process)
               (unless (string-empty-p pending-line)
                 (emit-line pending-line)
                 (setq pending-line ""))
               (let ((status (process-exit-status process)))
                 (cond
                  ((and (string-match-p "finished\\|exited" event)
                        (memq status '(0 1)))
                   (ogent-tools--stream-done 'grep status)
                   (when callback
                     (funcall callback 'done match-count)))
                  (t
                   (let ((message (string-trim
                                   (or (and (buffer-live-p stderr-buffer)
                                            (stderr-text))
                                       ""))))
                     (when (string-empty-p message)
                       (setq message (string-trim event)))
                     (ogent-tools--stream-error 'grep message)
                     (when callback
                       (funcall callback 'error message)))))))
             (ogent-tools--kill-buffer-if-live stderr-buffer)))
          (push (cons proc (list :callback callback
                                 :stderr-buffer stderr-buffer))
                ogent-tools--active-processes)
          proc)
      (error
       (ogent-tools--kill-buffer-if-live stderr-buffer)
       (let ((message (error-message-string err)))
         (ogent-tools--stream-error 'grep message)
         (when callback
           (funcall callback 'error message)))
       nil))))

;;; Tool: Bash (Shell Execution)

(defcustom ogent-tools-bash-stream-threshold 0
  "Byte threshold above which bash output is streamed.
Set to 0 to always stream, or a larger value to only stream
for commands that produce significant output."
  :type 'integer
  :group 'ogent-tools)

(defun ogent-tool--bash (command &optional working-directory timeout)
  "Execute shell COMMAND with streaming progress.
WORKING-DIRECTORY defaults to project root.
TIMEOUT in seconds (default `ogent-tools-shell-timeout').
Output is streamed incrementally via `ogent-tools-stream-callback'."
  (let* ((default-directory (if working-directory
                                (ogent-tools--resolve-path working-directory)
                              (ogent-tools--project-root)))
         (timeout-secs (or timeout ogent-tools-shell-timeout))
         (output-buffer (generate-new-buffer " *ogent-bash*"))
         (stderr-buffer (generate-new-buffer " *ogent-bash-stderr*"))
         (start-time (current-time))
         exit-code stdout-text stderr-text)
    ;; Signal start
    (ogent-tools--stream-start 'bash
                               (list :command command
                                     :directory default-directory))
    (unwind-protect
        (progn
          ;; Use make-process for separate stdout/stderr handling
          (let* ((proc (make-process
                        :name "ogent-bash"
                        :command (list shell-file-name
                                       shell-command-switch
                                       command)
                        :buffer output-buffer
                        :stderr stderr-buffer
                        :sentinel #'ignore
                        :noquery t
                        :filter (lambda (_proc output)
                                  (with-current-buffer output-buffer
                                    (goto-char (point-max))
                                    (insert output))
                                  (ogent-tools--stream-output 'bash 'stdout output))))
                 ;; Set up stderr filter
                 (stderr-proc (get-buffer-process stderr-buffer)))
            ;; Don't query on stderr process exit either
            (when stderr-proc
              (set-process-query-on-exit-flag stderr-proc nil))
            (when stderr-proc
              (set-process-filter
               stderr-proc
               (lambda (_proc output)
                 (with-current-buffer stderr-buffer
                   (goto-char (point-max))
                   (insert output))
                 (ogent-tools--stream-output 'bash 'stderr output))))
            ;; Wait for completion with timeout
            (let ((deadline (+ (float-time) timeout-secs)))
              (while (and (process-live-p proc)
                          (< (float-time) deadline))
                (accept-process-output proc 0.1))
              ;; Check for timeout
              (when (process-live-p proc)
                (kill-process proc)
                (ogent-tools--stream-error 'bash
                                           (format "Timeout after %s"
                                                   (ogent-tools--format-timeout
                                                    timeout-secs)))
                (error "Command timed out after %s"
                       (ogent-tools--format-timeout timeout-secs))))
            (setq exit-code (process-exit-status proc)))
          ;; Collect output
          (setq stdout-text (with-current-buffer output-buffer
                              (buffer-string)))
          (setq stderr-text (with-current-buffer stderr-buffer
                              (buffer-string))))
      ;; Cleanup
      (kill-buffer output-buffer)
      (kill-buffer stderr-buffer))
    ;; Signal completion
    (ogent-tools--stream-done 'bash exit-code)
    ;; Format result
    (ogent-tools--truncate-output
     (concat
      (if (string-empty-p stdout-text)
          "(no stdout)"
        stdout-text)
      (unless (string-empty-p stderr-text)
        (concat "\n\n--- stderr ---\n" stderr-text))
      (format "\n\nExit code: %s (%.1fs)"
              exit-code
              (float-time (time-subtract (current-time) start-time))))
     ogent-tools-max-output-chars)))

(defun ogent-tool--bash-async (command &optional working-directory timeout callback)
  "Execute shell COMMAND asynchronously with streaming output.
WORKING-DIRECTORY defaults to project root.
TIMEOUT in seconds (default `ogent-tools-shell-timeout').
CALLBACK is called with (TYPE DATA) where TYPE is:
  - `stdout': DATA is a string of stdout chunk
  - `stderr': DATA is a string of stderr chunk
  - `done': DATA is the exit code (integer)
  - `error': DATA is an error message
If CALLBACK is nil, results are only reported via `ogent-tools-stream-callback'."
  (let* ((default-directory (if working-directory
                                (ogent-tools--resolve-path working-directory)
                              (ogent-tools--project-root)))
         (timeout-secs (or timeout ogent-tools-shell-timeout))
         (proc-name (format "ogent-bash-%d" (random 100000)))
         (output-count 0)
         (stderr-buffer (generate-new-buffer " *ogent-bash-stderr*"))
         proc timer timed-out completed)
    ;; Signal start
    (ogent-tools--stream-start 'bash
                               (list :command command
                                     :directory default-directory))
    (condition-case err
        (progn
          (setq proc (make-process
                      :name proc-name
                      :command (list shell-file-name
                                     shell-command-switch
                                     command)
                      :stderr stderr-buffer
                      :noquery t
                      :filter (lambda (_process output)
                                (setq output-count (+ output-count (length output)))
                                (ogent-tools--stream-output 'bash 'stdout output)
                                (when (and callback
                                           (< output-count ogent-tools-max-output-chars))
                                  (funcall callback 'stdout output)))))
          ;; Set up stderr filter
          (when-let ((stderr-proc (get-buffer-process stderr-buffer)))
            (set-process-query-on-exit-flag stderr-proc nil)
            (set-process-filter
             stderr-proc
             (lambda (_proc output)
               (ogent-tools--stream-output 'bash 'stderr output)
               (when callback
                 (funcall callback 'stderr output)))))
          ;; Set up sentinel for completion
          (set-process-sentinel
           proc
           (lambda (process event)
             (unless completed
               (setq completed t)
               (ogent-tools--cancel-timer timer)
               (ogent-tools--drop-active-process process)
               (ogent-tools--kill-buffer-if-live stderr-buffer)
               (if timed-out
                   (let ((message (format "Timeout after %s"
                                          (ogent-tools--format-timeout timeout-secs))))
                     (ogent-tools--stream-error 'bash message)
                     (when callback
                       (funcall callback 'error message)))
                 (let ((status (process-exit-status process)))
                   (if (string-match-p "finished\\|exited" event)
                       (progn
                         (ogent-tools--stream-done 'bash status)
                         (when callback
                           (funcall callback 'done status)))
                     (let ((message (format "Process %s: %s"
                                            (process-name process)
                                            (string-trim event))))
                       (ogent-tools--stream-error 'bash message)
                       (when callback
                         (funcall callback 'error message)))))))))
          ;; Set up timeout
          (when (> timeout-secs 0)
            (setq timer
                  (run-at-time timeout-secs nil
                               (lambda ()
                                 (when (and (process-live-p proc)
                                            (not completed))
                                   (setq timed-out t)
                                   (kill-process proc))))))
          ;; Track active process
          (push (cons proc (list :callback callback :timer timer :stderr-buffer stderr-buffer))
                ogent-tools--active-processes)
          proc)
      (error
       (ogent-tools--cancel-timer timer)
       (ogent-tools--kill-buffer-if-live stderr-buffer)
       (ogent-tools--stream-error 'bash (error-message-string err))
       (when callback
         (funcall callback 'error (error-message-string err)))
       nil))))


;;; Process Management

(defun ogent-tools-cancel-all ()
  "Cancel all active tool processes."
  (interactive)
  (let ((count 0))
    (dolist (entry ogent-tools--active-processes)
      (let ((proc (car entry))
            (info (cdr entry)))
        (when (process-live-p proc)
          (kill-process proc)
          (cl-incf count))
        ;; Cancel associated timer if any
        (when-let ((timer (plist-get info :timer)))
          (ogent-tools--cancel-timer timer))
        ;; Kill stderr buffer if any
        (when-let ((buf (plist-get info :stderr-buffer)))
          (ogent-tools--kill-buffer-if-live buf))))
    (setq ogent-tools--active-processes nil)
    ;; Clean up progress state
    (when ogent-tools--progress-timer
      (cancel-timer ogent-tools--progress-timer)
      (setq ogent-tools--progress-timer nil))
    (setq ogent-tools--progress-state nil)
    (message "Cancelled %d active tool process(es)" count)))

(defun ogent-tools-active-count ()
  "Return the number of active tool processes."
  (cl-count-if (lambda (entry) (process-live-p (car entry)))
               ogent-tools--active-processes))

;;; Tool: Write File

(defun ogent-tool--write-file (file-path content)
  "Write CONTENT to FILE-PATH, overwriting if exists."
  (let ((path (ogent-tools--resolve-path file-path)))
    ;; Create parent directories if needed
    (make-directory (file-name-directory path) t)
    (with-temp-file path
      (insert content))
    (format "Wrote %d characters to %s" (length content) path)))

;;; Tool: Edit File

(defun ogent-tool--edit-file (file-path old-string new-string &optional replace-all)
  "Replace OLD-STRING with NEW-STRING in FILE-PATH.
If REPLACE-ALL is non-nil, replace all occurrences."
  (let* ((path (ogent-tools--resolve-path file-path))
         (content (with-temp-buffer
                    (insert-file-contents path)
                    (buffer-string)))
         (count 0)
         new-content)
    (unless (string-match-p (regexp-quote old-string) content)
      (error "Old_string not found in file: %s" path))
    (if replace-all
        (progn
          (setq new-content (replace-regexp-in-string
                             (regexp-quote old-string)
                             new-string
                             content t t))
          ;; Count occurrences by counting matches in original content
          (let ((pos 0)
                (old-len (length old-string)))
            (while (string-match (regexp-quote old-string) content pos)
              (setq count (1+ count)
                    pos (+ (match-beginning 0) old-len)))))
      ;; Single replacement
      (if (string-match (regexp-quote old-string) content)
          (setq new-content (replace-match new-string t t content)
                count 1)
        (error "Old_string not found in file")))
    (with-temp-file path
      (insert new-content))
    (format "Replaced %d occurrence(s) in %s" count path)))

;;; Default Tool Definitions

(defvar ogent-tools-default-registry
  '((:name read-file
	   :function ogent-tool--read-file
	   :description "Read the contents of a file. Returns lines with line numbers."
	   :args ((:name "file_path" :type "string"
			 :description "Absolute path to the file to read")
		  (:name "offset" :type "integer" :optional t
			 :description "Line number to start from (1-indexed)")
		  (:name "limit" :type "integer" :optional t
			 :description "Maximum lines to read"))
	   :category "filesystem")

    (:name glob
	   :function ogent-tool--glob
	   :description "Find files matching a glob pattern. Returns paths sorted by modification time."
	   :args ((:name "pattern" :type "string"
			 :description "Glob pattern like **/*.el or src/**/*.py")
		  (:name "path" :type "string" :optional t
			 :description "Directory to search in (default: project root)"))
	   :category "search")

    (:name grep
	   :function ogent-tool--grep
	   :async-function ogent-tool--grep-async
	   :async-callback-style :match  ; callback receives (match line), (done count), (error msg)
	   :description "Search file contents using regex pattern. Uses ripgrep if available."
	   :args ((:name "pattern" :type "string"
			 :description "Regular expression pattern to search for")
		  (:name "path" :type "string" :optional t
			 :description "File or directory to search")
		  (:name "glob_filter" :type "string" :optional t
			 :description "Limit search to files matching pattern (e.g., *.el)")
		  (:name "context_lines" :type "integer" :optional t
			 :description "Lines of context around matches"))
	   :category "search")

    (:name bash
	   :function ogent-tool--bash
	   :async-function ogent-tool--bash-async
	   :async-callback-style :stream  ; callback receives (stdout chunk), (stderr chunk), (done code), (error msg)
	   :description "Execute a shell command and return output."
	   :args ((:name "command" :type "string"
			 :description "Shell command to execute")
		  (:name "working_directory" :type "string" :optional t
			 :description "Directory to run command in")
		  (:name "timeout" :type "integer" :optional t
			 :description "Timeout in seconds"))
	   :category "shell"
	   :confirm t)

    (:name write-file
	   :function ogent-tool--write-file
	   :description "Write content to a file, creating it if it doesn't exist."
	   :args ((:name "file_path" :type "string"
			 :description "Absolute path to write to")
		  (:name "content" :type "string"
			 :description "Content to write"))
	   :category "filesystem"
	   :confirm t)

    (:name edit-file
	   :function ogent-tool--edit-file
	   :description "Replace a string in a file. The old_string must be unique."
	   :args ((:name "file_path" :type "string"
			 :description "Absolute path to the file")
		  (:name "old_string" :type "string"
			 :description "Exact string to replace (must be unique in file)")
		  (:name "new_string" :type "string"
			 :description "Replacement string")
		  (:name "replace_all" :type "boolean" :optional t
			 :description "If true, replace all occurrences"))
	   :category "filesystem"
	   :confirm t))
  "Default tool definitions for ogent.
These provide Claude Code-like functionality.")

(defun ogent-tools-install-defaults ()
  "Install default tools into `ogent-tool-registry'.
Does not overwrite existing entries with the same name."
  (dolist (tool ogent-tools-default-registry)
    (let ((name (plist-get tool :name)))
      (unless (seq-find (lambda (spec) (eq (plist-get spec :name) name))
                        ogent-tool-registry)
        (push tool ogent-tool-registry)))))

(provide 'ogent-tools)

;;; ogent-tools.el ends here
