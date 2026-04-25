;;; ogent-issues-bd.el --- Beads CLI integration layer -*- lexical-binding: t; -*-

;;; Commentary:
;; Async wrapper for the `bd` CLI (beads issue tracker).
;; Provides non-blocking execution, JSON parsing, caching, and error handling.
;; This is the data access layer for ogent-issues.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)

(defgroup ogent-issues-bd nil
  "Beads CLI integration for ogent-issues."
  :group 'ogent)

(defcustom ogent-issues-bd-executable "bd"
  "Path to the bd executable.
Can be just \"bd\" if it's in PATH, or an absolute path."
  :type 'string
  :group 'ogent-issues-bd)

(defcustom ogent-issues-bd-timeout 30
  "Timeout in seconds for bd commands."
  :type 'integer
  :group 'ogent-issues-bd)

(defcustom ogent-issues-bd-cache-ttl 5
  "Cache time-to-live in seconds for list results.
Set to 0 to disable caching."
  :type 'integer
  :group 'ogent-issues-bd)

;;; Internal State

(defvar ogent-issues-bd--cache (make-hash-table :test 'equal)
  "Cache for bd command results.
Keys are command argument lists, values are (timestamp . result) cons cells.")

(defvar ogent-issues-bd--version-cache nil
  "Cached bd version string.")

(defvar ogent-issues-bd--processes nil
  "List of active bd processes for cleanup.")

;;; Availability Checks

(defun ogent-issues-bd-available-p ()
  "Return non-nil if bd CLI is available in PATH or at configured location."
  (executable-find ogent-issues-bd-executable))

(defun ogent-issues-bd-initialized-p (&optional directory)
  "Return non-nil if beads is initialized in DIRECTORY or any parent.
DIRECTORY defaults to `default-directory'.
Walks up the directory tree looking for .beads directory."
  (not (null (ogent-issues-bd-project-root directory))))

(defun ogent-issues-bd-version (&optional callback)
  "Get the bd CLI version.
If CALLBACK is provided, call it asynchronously with the version string.
Otherwise, return the cached version or fetch synchronously."
  (if callback
      (ogent-issues-bd--run-async
       '("--version")
       (lambda (output)
         (let ((version (string-trim output)))
           (setq ogent-issues-bd--version-cache version)
           (funcall callback version)))
       nil
       t)  ; raw output, not JSON
    ;; Synchronous path - use cache or fetch
    (or ogent-issues-bd--version-cache
        (when (ogent-issues-bd-available-p)
          (let ((output (shell-command-to-string
                         (format "%s --version" ogent-issues-bd-executable))))
            (setq ogent-issues-bd--version-cache (string-trim output)))))))

(defun ogent-issues-bd-check-requirements ()
  "Check that bd is available and initialized.
Return nil if OK, or an error message string if not."
  (cond
   ((not (ogent-issues-bd-available-p))
    "bd CLI not found. Install beads: https://github.com/gastownhall/beads")
   ((not (ogent-issues-bd-initialized-p))
    (format "No beads project found (searched up from %s). Run: bd init"
            (abbreviate-file-name default-directory)))
   (t nil)))

;;; Core Async Execution

(defun ogent-issues-bd--run-async (args callback &optional error-callback raw-output)
  "Run bd with ARGS asynchronously, call CALLBACK with result.
ARGS is a list of command-line arguments (without \"bd\").
CALLBACK receives the parsed JSON result (as plist) on success.
ERROR-CALLBACK receives an error message string on failure.
If RAW-OUTPUT is non-nil, pass raw string output instead of parsing JSON.

The process runs from the beads project root directory.
Returns the process object, or nil if no project root found."
  (let ((project-root (ogent-issues-bd-project-root)))
    ;; Run from project root if found, otherwise current directory
    (let* ((default-directory (or project-root default-directory))
           (buffer (generate-new-buffer " *ogent-bd*"))
           (stderr-buffer (generate-new-buffer " *ogent-bd-stderr*"))
           (proc nil)
           (timer nil))
      
      ;; Set up timeout timer
      (setq timer
            (run-with-timer
             ogent-issues-bd-timeout nil
             (lambda ()
               (when (and proc (process-live-p proc))
                 (kill-process proc)
                 (when error-callback
                   (funcall error-callback
                            (format "bd command timed out after %ds"
                                    ogent-issues-bd-timeout)))))))
      
      ;; Start the process from project root
      (let ((full-command (cons ogent-issues-bd-executable args)))
        (setq proc
              (make-process
               :name "ogent-bd"
               :buffer buffer
               :stderr stderr-buffer
               :command full-command
               :sentinel
           (lambda (process event)
             ;; Cancel timeout timer
             (when timer (cancel-timer timer))
             
             ;; Clean up process list
             (setq ogent-issues-bd--processes
                   (delq process ogent-issues-bd--processes))
             
              (cond
               ;; Success
               ((string= event "finished\n")
                (with-current-buffer (process-buffer process)
                  (goto-char (point-min))
                  ;; Skip any leading whitespace or empty lines
                  (skip-chars-forward " \t\n\r")
                  (condition-case err
                      (let ((result (if raw-output
                                        (buffer-string)
                                      (if (eobp)
                                          ;; Empty output - return empty list
                                          '()
                                        (json-parse-buffer
                                         :object-type 'plist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object nil)))))
                        (funcall callback result))
                    (error
                     (if error-callback
                         (funcall error-callback
                                  (format "JSON parse error: %s (buffer: %S)"
                                          (error-message-string err)
                                          (buffer-substring-no-properties
                                           (point-min)
                                           (min (point-max) (+ (point-min) 100)))))
                        (message "ogent-bd: JSON parse error: %s" (error-message-string err))))))
                ;; Clean up buffers
                (when (buffer-live-p (process-buffer process))
                  (kill-buffer (process-buffer process)))
                (when (buffer-live-p stderr-buffer)
                  (kill-buffer stderr-buffer)))
              
              ;; Process exited with error
              ((string-match "exited abnormally" event)
               (let ((stderr-content
                      (when (buffer-live-p stderr-buffer)
                        (with-current-buffer stderr-buffer
                          (string-trim (buffer-string))))))
                 (if error-callback
                     (funcall error-callback
                              (or stderr-content
                                  (format "bd command failed: %s" event)))
                   (message "ogent-bd error: %s" (or stderr-content event))))
               ;; Clean up buffers
               (when (buffer-live-p (process-buffer process))
                 (kill-buffer (process-buffer process)))
               (when (buffer-live-p stderr-buffer)
                 (kill-buffer stderr-buffer)))
              
              ;; Other events (killed, etc.)
              (t
               (when (buffer-live-p (process-buffer process))
                 (kill-buffer (process-buffer process)))
               (when (buffer-live-p stderr-buffer)
                 (kill-buffer stderr-buffer))))))))
      
      ;; Don't prompt "Buffer has a running process" on buffer kill
      (set-process-query-on-exit-flag proc nil)
      (when-let ((stderr-proc (get-buffer-process stderr-buffer)))
        (set-process-query-on-exit-flag stderr-proc nil))
      ;; Track process for cleanup
      (push proc ogent-issues-bd--processes)
      proc)))

;;; Caching

(defun ogent-issues-bd--cache-key (args)
  "Generate cache key from ARGS including project context.
The key includes the project root to ensure cache isolation between projects."
  (let ((project-root (ogent-issues-bd-project-root)))
    (format "%S:%S"
            (if project-root
                (directory-file-name (expand-file-name project-root))
              "nil")
            args)))

(defun ogent-issues-bd--cache-get (args)
  "Get cached result for ARGS if valid, otherwise nil."
  (when (> ogent-issues-bd-cache-ttl 0)
    (let* ((key (ogent-issues-bd--cache-key args))
           (entry (gethash key ogent-issues-bd--cache)))
      (when entry
        (let ((timestamp (car entry))
              (result (cdr entry)))
          (if (< (float-time (time-subtract (current-time) timestamp))
                 ogent-issues-bd-cache-ttl)
              result
            ;; Expired - remove from cache
            (remhash key ogent-issues-bd--cache)
            nil))))))

(defun ogent-issues-bd--cache-set (args result)
  "Cache RESULT for ARGS."
  (when (> ogent-issues-bd-cache-ttl 0)
    (let ((key (ogent-issues-bd--cache-key args)))
      (puthash key (cons (current-time) result) ogent-issues-bd--cache))))

(defun ogent-issues-bd-cache-invalidate ()
  "Invalidate all cached results.
Call this after any mutation (create, close, update, etc.)."
  (clrhash ogent-issues-bd--cache))

(defun ogent-issues-bd--coerce-single-issue (result)
  "Normalize `bd show --json` RESULT to a single issue plist.
Recent bd versions return a one-element array for `show`, while callers of
`ogent-issues-bd-get` expect one plist."
  (cond
   ((null result) nil)
   ((and (listp result) (keywordp (car result))) result)
   ((and (listp result)
         (listp (car result))
         (keywordp (caar result)))
    (car result))
   (t result)))

;;; High-Level API

(defun ogent-issues-bd-list (callback &optional filters error-callback)
  "List all issues, calling CALLBACK with the result.
FILTERS is an optional plist with :status, :type, :priority keys.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        ;; Requirements not met - report error and return nil
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      ;; Requirements met - proceed with list
      (let ((args (list "list" "--json")))
        ;; Add filters (append to end, not push to front)
        (when-let ((status (plist-get filters :status)))
          (setq args (append args (list (format "--status=%s" status)))))
        (when-let ((type (plist-get filters :type)))
          (setq args (append args (list (format "--type=%s" type)))))
        (when-let ((priority (plist-get filters :priority)))
          (setq args (append args (list (format "--priority=%d" priority)))))
        ;; Check cache first
        (let ((cached (ogent-issues-bd--cache-get args)))
          (if cached
              (funcall callback cached)
            ;; Fetch from bd
            (ogent-issues-bd--run-async
             args
             (lambda (result)
               (ogent-issues-bd--cache-set args result)
               (funcall callback result))
             error-callback)))))))

(defun ogent-issues-bd-get (id callback &optional error-callback)
  "Get issue with ID, calling CALLBACK with the result.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (let ((args (list "show" id "--json")))
        ;; Check cache
        (let ((cached (ogent-issues-bd--cache-get args)))
          (if cached
              (funcall callback (ogent-issues-bd--coerce-single-issue cached))
            (ogent-issues-bd--run-async
             args
             (lambda (result)
               (let ((issue (ogent-issues-bd--coerce-single-issue result)))
                 (ogent-issues-bd--cache-set args issue)
                 (funcall callback issue)))
             error-callback)))))))

(defun ogent-issues-bd-ready (callback &optional error-callback)
  "Get ready (unblocked) issues, calling CALLBACK with the result.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (let ((args '("ready" "--json")))
        (let ((cached (ogent-issues-bd--cache-get args)))
          (if cached
              (funcall callback cached)
            (ogent-issues-bd--run-async
             args
             (lambda (result)
               (ogent-issues-bd--cache-set args result)
               (funcall callback result))
             error-callback)))))))

(defun ogent-issues-bd-create (title callback &rest props)
  "Create a new issue with TITLE, calling CALLBACK with the result.
PROPS is a plist with optional :type, :priority, :description, :parent.
The last element of PROPS can be :error-callback followed by a function."
  (let ((err (ogent-issues-bd-check-requirements))
        (error-callback (plist-get props :error-callback)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (let ((args (list "create" "--title" title "--json")))
        ;; Add optional properties
        (when-let ((type (plist-get props :type)))
          (setq args (append args (list "--type" type))))
        (when-let ((priority (plist-get props :priority)))
          (setq args (append args (list "--priority" (number-to-string priority)))))
        (when-let ((description (plist-get props :description)))
          (setq args (append args (list "--description" description))))
        (when-let ((parent (plist-get props :parent)))
          (setq args (append args (list "--parent" parent))))
        (ogent-issues-bd--run-async
         args
         (lambda (result)
           ;; Invalidate cache after mutation
           (ogent-issues-bd-cache-invalidate)
           (funcall callback result))
         error-callback)))))

(defun ogent-issues-bd-close (id reason callback &optional error-callback)
  "Close issue ID with REASON, calling CALLBACK on success.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (ogent-issues-bd--run-async
       (list "close" id "--reason" reason)
       (lambda (_result)
         (ogent-issues-bd-cache-invalidate)
         (funcall callback))
       error-callback
       t))))  ; raw output - close doesn't return JSON

(defun ogent-issues-bd-reopen (id callback &optional error-callback)
  "Reopen issue ID, calling CALLBACK on success.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (ogent-issues-bd--run-async
       (list "reopen" id)
       (lambda (_result)
         (ogent-issues-bd-cache-invalidate)
         (funcall callback))
       error-callback
       t))))

(defun ogent-issues-bd-start (id callback &optional error-callback)
  "Claim issue ID, calling CALLBACK on success.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (ogent-issues-bd--run-async
       (list "update" id "--claim")
       (lambda (_result)
         (ogent-issues-bd-cache-invalidate)
         (funcall callback))
       error-callback
       t))))

(defun ogent-issues-bd-comment (id text callback &optional error-callback)
  "Add comment TEXT to issue ID, calling CALLBACK on success.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (ogent-issues-bd--run-async
       (list "comments" "add" id text)
       (lambda (_result)
         (ogent-issues-bd-cache-invalidate)
         (funcall callback))
       error-callback
       t))))

(defun ogent-issues-bd-sync (callback &optional error-callback)
  "Run `bd sync', calling CALLBACK on success.
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (ogent-issues-bd--run-async
       '("sync")
       (lambda (_result)
         (ogent-issues-bd-cache-invalidate)
         (funcall callback))
       error-callback
       t))))

(defun ogent-issues-bd-update (id callback &rest props)
  "Update issue ID with PROPS, calling CALLBACK on success.
PROPS is a plist with optional :status, :priority, :description.
The last element of PROPS can be :error-callback followed by a function."
  (let ((err (ogent-issues-bd-check-requirements))
        (error-callback (plist-get props :error-callback)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (let ((args (list "update" id)))
        ;; Add optional properties
        (when-let ((status (plist-get props :status)))
          (setq args (append args (list "--status" status))))
        (when-let ((priority (plist-get props :priority)))
          (setq args (append args (list "--priority" (number-to-string priority)))))
        (when-let ((description (plist-get props :description)))
          (setq args (append args (list "--description" description))))
        (ogent-issues-bd--run-async
         args
         (lambda (_result)
           (ogent-issues-bd-cache-invalidate)
           (funcall callback))
         error-callback
         t)))))

(defun ogent-issues-bd-dep-add (blocked-id blocker-id callback &optional error-callback)
  "Add dependency: BLOCKED-ID depends on BLOCKER-ID.
Calls CALLBACK on success, ERROR-CALLBACK on error."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (ogent-issues-bd--run-async
       (list "dep" "add" blocked-id blocker-id)
       (lambda (_result)
         (ogent-issues-bd-cache-invalidate)
         (funcall callback))
       error-callback
       t))))

;;; Cleanup

(defun ogent-issues-bd-cleanup ()
  "Kill all active bd processes and clear cache."
  (interactive)
  (dolist (proc ogent-issues-bd--processes)
    (when (process-live-p proc)
      (kill-process proc)))
  (setq ogent-issues-bd--processes nil)
  (ogent-issues-bd-cache-invalidate)
  (message "ogent-issues-bd: Cleaned up processes and cache"))

;;; Project Detection

(defun ogent-issues-bd-project-root (&optional directory)
  "Find the beads project root starting from DIRECTORY.
DIRECTORY defaults to `default-directory'.
Returns the directory containing .beads, or nil if not found."
  (let ((dir (or directory default-directory)))
    (locate-dominating-file dir ".beads")))

(defun ogent-issues-bd-project-name (&optional directory)
  "Get the project name for the beads project at DIRECTORY.
Returns the directory name of the project root."
  (when-let ((root (ogent-issues-bd-project-root directory)))
    (file-name-nondirectory (directory-file-name root))))

(provide 'ogent-issues-bd)

;;; ogent-issues-bd.el ends here
