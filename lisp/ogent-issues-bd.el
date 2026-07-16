;;; ogent-issues-bd.el --- Beads CLI integration layer -*- lexical-binding: t; -*-

;;; Commentary:
;; Async wrapper for the `br' CLI (beads_rust issue tracker,
;; https://github.com/Dicklesworthstone/beads_rust).  Provides
;; non-blocking execution, JSON parsing, caching, and error handling.
;; This is the data access layer for ogent-issues.  The historical
;; `-bd-' infix in symbol names refers to beads generically.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)

(defgroup ogent-issues-bd nil
  "Beads CLI integration for ogent-issues."
  :group 'ogent)

(defcustom ogent-issues-bd-executable "br"
  "Path to the beads executable.
Defaults to \"br\" (beads_rust).  Can be a bare command name on PATH
or an absolute path; the classic \"bd\" binary also works if its CLI
is compatible."
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
    "br CLI not found. Install beads_rust: https://github.com/Dicklesworthstone/beads_rust")
   ((not (ogent-issues-bd-initialized-p))
    (format "No beads project found (searched up from %s). Run: br init"
            (abbreviate-file-name default-directory)))
   (t nil)))

;;; Git Worktree Support
;;
;; br has no `worktree' subcommand.  Inside a linked git worktree it
;; auto-discovers the checked-out `.beads/' (or creates one) and forks
;; a fresh database from the committed JSONL, so parallel agents
;; working in sibling worktrees would claim and close issues in
;; divergent databases.  br does honor a `.beads/redirect' file
;; containing the path of another beads directory; pointing every
;; worktree at the main checkout's `.beads/' restores a single shared
;; database with atomic claims.

(defun ogent-issues-bd--worktree-main-root (root)
  "Return the main checkout root when ROOT is a linked git worktree.
ROOT is a directory whose `.git' entry is a gitdir pointer file, as
created by \\='git worktree add\\='.  Return nil for primary
checkouts, submodules, and non-git directories."
  (let ((git-file (expand-file-name ".git" root)))
    (when (and (file-regular-p git-file)
               (file-readable-p git-file))
      (with-temp-buffer
        (insert-file-contents git-file)
        (goto-char (point-min))
        (when (looking-at "gitdir:[ \t]*\\(.+\\)$")
          (let* ((gitdir (string-trim (match-string 1)))
                 (gitdir (if (file-name-absolute-p gitdir)
                             gitdir
                           (expand-file-name gitdir root))))
            ;; Linked worktrees point at <main>/.git/worktrees/<name>.
            ;; Submodules point at .git/modules/<name> and must not be
            ;; treated as worktrees.
            (when (string-match "\\`\\(.+\\)/\\.git/worktrees/[^/]+/?\\'"
                                (directory-file-name gitdir))
              (match-string 1 (directory-file-name gitdir)))))))))

(defun ogent-issues-bd-ensure-worktree-redirect (&optional directory)
  "Ensure br resolves the shared beads database from DIRECTORY.
When DIRECTORY (default `default-directory') is inside a linked git
worktree whose main checkout has a `.beads/' directory, write
`.beads/redirect' in the worktree root pointing at the main beads
directory, unless a redirect already exists.  Without the redirect br
forks an independent database per worktree, and parallel agents stop
seeing each other's claims.

Return the redirect file path when one exists or was created, or nil
when DIRECTORY needs no redirect (primary checkout, not in git, or
the main checkout has no beads directory)."
  (interactive)
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory default-directory))))
         (root (locate-dominating-file dir ".git"))
         (main-root (and root (ogent-issues-bd--worktree-main-root root))))
    (when main-root
      (let ((main-beads (expand-file-name ".beads" main-root))
            (worktree-beads (expand-file-name ".beads" root)))
        (when (file-directory-p main-beads)
          (let ((redirect (expand-file-name "redirect" worktree-beads)))
            (unless (file-exists-p redirect)
              (make-directory worktree-beads t)
              (write-region (concat main-beads "\n") nil redirect
                            nil 'silent))
            (when (called-interactively-p 'interactive)
              (message "beads worktree redirect: %s -> %s"
                       (abbreviate-file-name redirect)
                       (abbreviate-file-name main-beads)))
            redirect))))))

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

(defun ogent-issues-bd--issue-list (result)
  "Normalize a `list --json' RESULT to a bare list of issue plists.
br wraps the issues in a (:issues ... :total ...) pagination plist,
while classic bd returned a bare array.  Accept both."
  (if (and (consp result) (keywordp (car result)))
      (plist-get result :issues)
    result))

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
              (funcall callback (ogent-issues-bd--issue-list cached))
            ;; Fetch from bd
            (ogent-issues-bd--run-async
             args
             (lambda (result)
               (ogent-issues-bd--cache-set args result)
               (funcall callback (ogent-issues-bd--issue-list result)))
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
  "Run `br sync --flush-only', calling CALLBACK on success.
Exports the database to the git-friendly JSONL file; committing the
result is the caller's responsibility (br never runs git).
ERROR-CALLBACK is called on error with an error message."
  (let ((err (ogent-issues-bd-check-requirements)))
    (if err
        (progn
          (if error-callback
              (funcall error-callback err)
            (user-error "%s" err))
          nil)
      (ogent-issues-bd--run-async
       '("sync" "--flush-only")
       (lambda (_result)
         (ogent-issues-bd-cache-invalidate)
         (funcall callback))
       error-callback
       t))))

(defconst ogent-issues-bd--update-string-flags
  '((:title . "--title")
    (:status . "--status")
    (:type . "--type")
    (:assignee . "--assignee")
    (:description . "--description")
    (:design . "--design")
    (:acceptance-criteria . "--acceptance-criteria")
    (:notes . "--notes"))
  "Mapping from `ogent-issues-bd-update' string props to br update flags.")

(defun ogent-issues-bd-update (id callback &rest props)
  "Update issue ID with PROPS, calling CALLBACK on success.
PROPS is a plist of fields to change: :title, :status, :type,
:assignee, :description, :design, :acceptance-criteria and :notes
take strings (an explicit empty string passes through, which br
interprets as clearing the field); :priority takes a number;
:add-labels and :remove-labels take lists of label strings.
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
        (pcase-dolist (`(,key . ,flag) ogent-issues-bd--update-string-flags)
          (let ((value (plist-get props key)))
            (when (stringp value)
              (setq args (append args (list flag value))))))
        (let ((priority (plist-get props :priority)))
          (when (numberp priority)
            (setq args (append args (list "--priority"
                                          (number-to-string priority))))))
        (dolist (label (plist-get props :add-labels))
          (setq args (append args (list "--add-label" label))))
        (dolist (label (plist-get props :remove-labels))
          (setq args (append args (list "--remove-label" label))))
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

;;; Org Agenda Projection

(declare-function org-agenda "org-agenda" (&optional arg keys restriction))
(defvar org-agenda-buffer)
(defvar org-agenda-buffer-name)
(defvar org-agenda-files)

(defcustom ogent-issues-agenda-file nil
  "File that receives the generated br-beads Org projection.
When nil, derive a per-project cache path under
`user-emacs-directory'/ogent/beads/ via `ogent-issues-bd--agenda-file'.
The generated file is overwritten on every `ogent-issues-agenda'
invocation and never lives inside the project worktree."
  :type '(choice (const :tag "Derive per project" nil) file)
  :group 'ogent-issues-bd)

(defun ogent-issues-bd--agenda-file (&optional directory)
  "Return the Org projection file path for the beads project at DIRECTORY.
Honor `ogent-issues-agenda-file' when customized.  Otherwise derive
\"ogent/beads/<project>-<hash>.org\" under `user-emacs-directory',
where <hash> is the first eight characters of the md5 of the project
root's truename; the cache never writes into the worktree or
`.beads/'."
  (or ogent-issues-agenda-file
      (let* ((root (or (ogent-issues-bd-project-root directory)
                       directory
                       default-directory))
             (truename (file-truename
                        (directory-file-name (expand-file-name root)))))
        (expand-file-name
         (format "ogent/beads/%s-%s.org"
                 (file-name-nondirectory truename)
                 (substring (md5 truename) 0 8))
         user-emacs-directory))))

(defconst ogent-issues-bd--projection-keywords
  '(("open" . "TODO")
    ("in_progress" . "RUNNING")
    ("blocked" . "BLOCKED"))
  "Mapping from br issue status to Org TODO keyword.")

(defun ogent-issues-bd--projection-priority (priority)
  "Return the Org priority cookie letter for br PRIORITY.
Map 0-1 to A, 2 to B, and 3 or higher (or nil) to C."
  (cond ((null priority) "C")
        ((<= priority 1) "A")
        ((= priority 2) "B")
        (t "C")))

(defun ogent-issues-bd--projection-sorted (issues)
  "Return open/in_progress/blocked ISSUES in projection order.
Sort in-progress work first, then ascending priority, then id."
  (sort (seq-filter
         (lambda (issue)
           (member (plist-get issue :status)
                   '("open" "in_progress" "blocked")))
         issues)
        (lambda (a b)
          (let ((a-active (equal (plist-get a :status) "in_progress"))
                (b-active (equal (plist-get b :status) "in_progress")))
            (if (not (eq a-active b-active))
                a-active
              (let ((pa (or (plist-get a :priority) most-positive-fixnum))
                    (pb (or (plist-get b :priority) most-positive-fixnum)))
                (if (/= pa pb)
                    (< pa pb)
                  (string< (or (plist-get a :id) "")
                           (or (plist-get b :id) "")))))))))

(defun ogent-issues-bd--issue-parent (issue)
  "Return the parent bead id recorded in the ISSUE plist, or nil.
br emits parent-child dependencies in two JSON shapes: the JSONL
export nests (:issue_id CHILD :depends_on_id PARENT :type
\"parent-child\") entries under :dependencies, while `br show
--json' nests (:id PARENT :dependency_type \"parent-child\")
entries and adds a top-level :parent string.  `br list --json'
carries only :dependency_count, so issues from plain list calls
yield nil.  Prefer the explicit :parent field, then the first
parent-child dependency entry."
  (let ((parent (plist-get issue :parent)))
    (if (and (stringp parent) (not (string-blank-p parent)))
        parent
      (seq-some
       (lambda (dep)
         (and (listp dep)
              (equal (or (plist-get dep :dependency_type)
                         (plist-get dep :type))
                     "parent-child")
              (let ((id (or (plist-get dep :depends_on_id)
                            (plist-get dep :id))))
                (and (stringp id)
                     (not (string-blank-p id))
                     id))))
       (plist-get issue :dependencies)))))

(defun ogent-issues-bd--org-projection (issues root)
  "Return the Org-mode projection of br ISSUES for project ROOT.
Include only open, in_progress, and blocked issues as TODO headlines
with OGENT_ISSUE_ID/OGENT_ISSUE_TYPE/OGENT_BLOCKED_BY property
drawers, plus OGENT_ISSUE_PARENT for issues carrying a parent-child
dependency (see `ogent-issues-bd--issue-parent'); indent description
bodies two spaces so stray structure markers stay inert."
  (with-temp-buffer
    (insert (format "#+title: br beads: %s\n" root))
    (insert "#+filetags: :ogent_beads:\n")
    (insert "#+TODO: TODO BLOCKED RUNNING | DONE\n")
    (insert "# Generated by ogent-issues-agenda; edits are overwritten.\n")
    (dolist (issue (ogent-issues-bd--projection-sorted issues))
      (let ((id (or (plist-get issue :id) ""))
            (type (plist-get issue :issue_type))
            (blocked-by (plist-get issue :blocked_by))
            (description (plist-get issue :description)))
        (insert (format "\n* %s [#%s] %s: %s\n"
                        (cdr (assoc (plist-get issue :status)
                                    ogent-issues-bd--projection-keywords))
                        (ogent-issues-bd--projection-priority
                         (plist-get issue :priority))
                        id
                        (or (plist-get issue :title) "")))
        (insert ":PROPERTIES:\n")
        (insert (format ":OGENT_ISSUE_ID: %s\n" id))
        (when type
          (insert (format ":OGENT_ISSUE_TYPE: %s\n" type)))
        (when blocked-by
          (insert (format ":OGENT_BLOCKED_BY: %s\n"
                          (mapconcat #'identity blocked-by " "))))
        (when-let ((parent (ogent-issues-bd--issue-parent issue)))
          (insert (format ":OGENT_ISSUE_PARENT: %s\n" parent)))
        (insert ":END:\n")
        (when (and description
                   (string-match-p "[^ \t\n\r]" description))
          (dolist (line (split-string description "\n"))
            (insert "  " line "\n")))))
    (buffer-string)))

;;;###autoload
(defun ogent-issues-agenda ()
  "Display an Org agenda built from the project's br beads.
Fetch issues with `ogent-issues-bd-list', regenerate the projection
file returned by `ogent-issues-bd--agenda-file' (the file is
overwritten on every invocation), then open the Org agenda global
TODO view scoped to that file.  Inside the agenda buffer, `r' and
`g' re-read the projection file but do not re-run br; invoke this
command again to refresh from br.  State changes flow through
`ogent-issues', never back from the generated file."
  (interactive)
  (let ((root (ogent-issues-bd-project-root))
        (file (ogent-issues-bd--agenda-file)))
    (ogent-issues-bd-list
     (lambda (issues)
       (require 'org-agenda)
       (make-directory (file-name-directory file) t)
       (with-temp-file file
         (insert (ogent-issues-bd--org-projection
                  issues (or root default-directory))))
       (let ((org-agenda-files (list file)))
         (org-agenda nil "t"))
       (when-let ((buf (or (and (boundp 'org-agenda-buffer)
                                org-agenda-buffer)
                           (get-buffer org-agenda-buffer-name))))
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq-local org-agenda-files (list file))))))
     nil
     (lambda (err)
       (message "ogent-issues-agenda: %s" err)))))

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
