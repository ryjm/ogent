;;; ogent-tools.el --- Tool implementations for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Core tool implementations for ogent's LLM function calling.
;; These tools mirror Claude Code's tool set for familiar UX.
;;
;; Tools are registered via `ogent-tool-registry' in ogent-models.el
;; and executed by gptel's tool-use FSM.

;;; Code:

(require 'cl-lib)

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
  (let ((expanded (expand-file-name path)))
    (if (file-name-absolute-p expanded)
        expanded
      (expand-file-name path (ogent-tools--project-root)))))

(defun ogent-tools--truncate-output (output max-chars)
  "Truncate OUTPUT to MAX-CHARS, adding notice if truncated."
  (if (> (length output) max-chars)
      (concat (substring output 0 max-chars)
              "\n\n[Output truncated. Total length: "
              (number-to-string (length output)) " chars]")
    output))

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
  "Search for PATTERN in files.
PATH is file or directory to search (default project root).
GLOB-FILTER limits to matching files (e.g., \"*.el\").
CONTEXT-LINES shows N lines before/after matches."
  (let* ((dir (if path
                  (ogent-tools--resolve-path path)
                (ogent-tools--project-root)))
         (context (or context-lines 0))
         (cmd (if (executable-find "rg")
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
         (output (shell-command-to-string cmd)))
    (ogent-tools--truncate-output
     (if (string-empty-p output)
         "No matches found"
       output)
     ogent-tools-max-output-chars)))

;;; Tool: Bash (Shell Execution)

(defvar ogent-tools--active-processes nil
  "Alist of (process . callback-info) for active async tool processes.")

(defun ogent-tool--bash (command &optional working-directory timeout)
  "Execute shell COMMAND synchronously.
WORKING-DIRECTORY defaults to project root.
TIMEOUT in seconds (default `ogent-tools-shell-timeout')."
  (let* ((default-directory (if working-directory
                                (ogent-tools--resolve-path working-directory)
                              (ogent-tools--project-root)))
         (_timeout-secs (or timeout ogent-tools-shell-timeout))
         (output-buffer (generate-new-buffer " *ogent-bash*"))
         (_start-time (current-time))
         exit-code output)
    (unwind-protect
        (progn
          (setq exit-code
                (call-process-shell-command
                 command nil output-buffer nil))
          (setq output (with-current-buffer output-buffer
                         (buffer-string))))
      (kill-buffer output-buffer))
    ;; Format result
    (ogent-tools--truncate-output
     (format "%s\n\nExit code: %s"
             (if (string-empty-p output) "(no output)" output)
             exit-code)
     ogent-tools-max-output-chars)))

(defun ogent-tool--bash-async (command callback &optional working-directory timeout)
  "Execute shell COMMAND asynchronously with streaming output.
CALLBACK is called with (TYPE DATA) where TYPE is:
  - `chunk': DATA is a string of output
  - `done': DATA is the exit code (integer)
  - `error': DATA is an error message
WORKING-DIRECTORY defaults to project root.
TIMEOUT in seconds (default `ogent-tools-shell-timeout')."
  (let* ((default-directory (if working-directory
                                (ogent-tools--resolve-path working-directory)
                              (ogent-tools--project-root)))
         (timeout-secs (or timeout ogent-tools-shell-timeout))
         (proc-name (format "ogent-bash-%d" (random 100000)))
         (output-count 0)
         proc timer)
    (condition-case err
        (progn
          (setq proc (start-process-shell-command
                      proc-name nil command))
          ;; Set up process filter for streaming output
          (set-process-filter
           proc
           (lambda (process output)
             (setq output-count (+ output-count (length output)))
             (when (< output-count ogent-tools-max-output-chars)
               (funcall callback 'chunk output))))
          ;; Set up sentinel for completion
          (set-process-sentinel
           proc
           (lambda (process event)
             (when timer (cancel-timer timer))
             (setq ogent-tools--active-processes
                   (assq-delete-all process ogent-tools--active-processes))
             (let ((status (process-exit-status process)))
               (if (string-match-p "finished\\|exited" event)
                   (funcall callback 'done status)
                 (funcall callback 'error
                          (format "Process %s: %s"
                                  (process-name process)
                                  (string-trim event)))))))
          ;; Set up timeout
          (when (> timeout-secs 0)
            (setq timer
                  (run-at-time timeout-secs nil
                               (lambda ()
                                 (when (process-live-p proc)
                                   (kill-process proc)
                                   (funcall callback 'error
                                            (format "Timeout after %ds" timeout-secs)))))))
          ;; Track active process
          (push (cons proc (list :callback callback :timer timer))
                ogent-tools--active-processes)
          proc)
      (error
       (funcall callback 'error (error-message-string err))
       nil))))

(defun ogent-tool--abort-process (proc)
  "Abort an active async tool PROC."
  (when (process-live-p proc)
    (kill-process proc))
  (when-let ((info (assq proc ogent-tools--active-processes)))
    (when-let ((timer (plist-get (cdr info) :timer)))
      (cancel-timer timer))
    (setq ogent-tools--active-processes
          (assq-delete-all proc ogent-tools--active-processes))))

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
