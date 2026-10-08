;;; ogent-tool-process.el --- Structured local process tools -*- lexical-binding: t; -*-

;;; Commentary:
;; Return process results as data without decoding human-facing tool footers.
;; These low-level helpers trust their caller; the agent dispatcher owns policy.
;; Search uses ripgrep JSON or GNU grep's NUL-delimited filename protocol.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'ogent-tools)

(define-error 'ogent-tool-process-start-failed "Local process could not start" 'user-error)
(define-error 'ogent-tool-process-search-failed "Local search failed" 'user-error)
(define-error 'ogent-tool-process-search-timeout "Local search timed out" 'user-error)
(define-error 'ogent-tool-process-search-cancelled "Local search was cancelled" 'user-error)
(define-error 'ogent-tool-process-output-error "Local process output is unsupported" 'user-error)
(define-error 'ogent-tool-process-unavailable "Local search dependency is unavailable" 'user-error)

(defconst ogent-tool-process--max-context 20
  "Maximum context lines on each side of a structured search match.")

(defconst ogent-tool-process--max-limit 200
  "Maximum matches in a structured search page.")

(defun ogent-tool-process--safe-text (text)
  "Return TEXT with undecodable raw bytes replaced by Unicode replacement chars."
  (replace-regexp-in-string "[\x3fff80-\x3fffff]" "\uFFFD" text t t))

(defun ogent-tool-process--callback (callback data error-data &optional process)
  "Invoke CALLBACK with DATA and ERROR-DATA, recording errors on PROCESS."
  (when callback
    (condition-case err
        (funcall callback data error-data)
      (error
       (when process (process-put process 'ogent-callback-error err))
       (message "ogent: process callback failed: %s" (error-message-string err))))))

(defun ogent-tool-process--stop (process)
  "Terminate PROCESS and its local process group when possible."
  (when (processp process)
    ;; Pipe children have a separate process group on POSIX Emacs.  Killing
    ;; that group also closes inherited output pipes in shell grandchildren.
    (condition-case nil
        (when-let ((pid (process-id process)))
          (signal-process (- pid) 9))
      (error nil))
    (when (process-live-p process) (delete-process process))))

(defun ogent-tool-process-cancel (process)
  "Cancel structured PROCESS and deliver its partial terminal result.
Return non-nil when PROCESS had an active cancellation handler."
  (when-let ((cancel (and (processp process)
                          (process-get process 'ogent-cancel))))
    (funcall cancel)
    t))

(defun ogent-tool-process--run (command directory timeout callback
					&optional stdout-handler input cleanup)
  "Run COMMAND in DIRECTORY with TIMEOUT and terminal CALLBACK.
Call CALLBACK once with a process-data plist and an error condition or nil.
STDOUT-HANDLER, when present, consumes stdout instead of retaining it.
Feed INPUT to stdin when non-nil.  Invoke CLEANUP on every terminal path."
  (let ((default-directory directory)
        (budget (max 0 ogent-tools-max-output-chars))
        (retained 0)
        (stdout "") (stderr "")
        process stderr-process timer completed finishing timed-out cancelled failure
        encoding-loss)
    (cl-labels
        ((emit (channel chunk)
           (unless completed
             (if (and (eq channel 'stdout) stdout-handler)
                 (condition-case err
                     (funcall stdout-handler chunk)
                   (error
                    (setq failure err)
                    (ogent-tool-process--stop process)))
               (let* ((safe (ogent-tool-process--safe-text chunk))
                      (remaining (max 0 (- budget retained)))
                      (kept (substring safe 0 (min remaining (length safe)))))
                 (unless (equal safe chunk) (setq encoding-loss t))
                 (cl-incf retained (length kept))
                 (when (> (length chunk) remaining)
                   (when process (process-put process 'ogent-truncated t)))
                 (if (eq channel 'stdout)
                     (setq stdout (concat stdout kept))
                   (setq stderr (concat stderr kept)))))))
         (finish ()
           (unless (or completed finishing)
             (setq finishing t)
             (when timer (cancel-timer timer))
             (when (and process (eq (process-status process) 'signal))
               (ogent-tool-process--stop process))
             (when process
               (while (accept-process-output process 0.01)))
             ;; Drain the separate stderr pipe before marking the result final.
             (while (and stderr-process
                         (accept-process-output stderr-process 0.01)))
             (setq completed t)
             (when process
               (process-put process 'ogent-cancel nil)
               (ogent-tools--drop-active-process process))
             (when stderr-process
               (set-process-filter stderr-process #'ignore)
               (set-process-sentinel stderr-process #'ignore)
               (when (process-live-p stderr-process)
                 (delete-process stderr-process)))
             (when cleanup
               (condition-case err
                   (funcall cleanup)
                 (error
                  (when process (process-put process 'ogent-cleanup-error err))
                  (message "ogent: process cleanup failed: %s"
                           (error-message-string err)))))
             (ogent-tool-process--callback
              callback
              (and process
                   (list :stdout stdout :stderr stderr
                         :exit_code (process-exit-status process)
                         :signal (if (eq (process-status process) 'signal)
                                     (process-exit-status process) :json-null)
                         :timed_out (if timed-out t :json-false)
                         :cancelled (if cancelled t :json-false)
                         :encoding_loss (if encoding-loss t :json-false)
                         :truncated (if (process-get process 'ogent-truncated)
                                        t :json-false)))
              failure process))))
      (condition-case err
          (progn
            (setq stderr-process
                  (make-pipe-process
                   :name "ogent-structured-stderr" :noquery t
                   :coding 'utf-8-unix :buffer nil
                   :filter (lambda (_process chunk) (emit 'stderr chunk))
                   :sentinel #'ignore))
            (setq process
                  (make-process
                   :name "ogent-structured-process" :command command
                   :connection-type 'pipe :coding 'utf-8-unix
                   :noquery t :buffer nil :stderr stderr-process
                   :filter (lambda (_process chunk) (emit 'stdout chunk))
                   :sentinel (lambda (proc _event)
                               (when (memq (process-status proc) '(exit signal failed))
                                 (finish)))))
            (process-put process 'ogent-cancel
                         (lambda ()
                           (unless completed
                             (setq cancelled t)
                             (ogent-tool-process--stop process)
                             (finish))))
            (push (cons process (list :callback callback))
                  ogent-tools--active-processes)
            (setq timer
                  (run-at-time timeout nil
                               (lambda ()
                                 (unless completed
                                   (setq timed-out t)
                                   (ogent-tool-process--stop process)
                                   (finish)))))
            (when input (process-send-string process input))
            (when (process-live-p process) (process-send-eof process))
            process)
        (error
         (setq failure
               (list 'ogent-tool-process-start-failed
                     (format "Unable to start local process: %s; verify the configured shell and search executables"
                             (error-message-string err))))
         (when process
           (set-process-sentinel process #'ignore)
           (ogent-tool-process--stop process))
         (finish)
         nil)))))

(defun ogent-tool-process--wait (starter)
  "Run asynchronous STARTER and return its terminal data or signal its error."
  (let (done data failure process)
    (unwind-protect
        (progn
          (setq process
                (funcall starter
                         (lambda (result error-data)
                           (setq done t data result failure error-data))))
          (while (not done)
            (accept-process-output nil 0.05))
          (if failure (signal (car failure) (cdr failure)) data))
      (when (and process (process-live-p process))
        (ogent-tool-process-cancel process)))))

(defun ogent-tool-process-bash-async (command &optional working-directory timeout callback)
  "Execute shell COMMAND and return its asynchronous process.
WORKING-DIRECTORY and TIMEOUT have the legacy shell defaults.
Call CALLBACK once with (DATA ERROR), where ERROR is a condition or nil.
DATA separates stdout, stderr, exit_code, timed_out, cancelled and truncated.
Timeout and cancellation preserve partial output as terminal data."
  (condition-case err
      (let ((seconds (or timeout ogent-tools-shell-timeout)))
        (ogent-tools--bash-validate command working-directory seconds)
        (ogent-tool-process--run
         (list shell-file-name shell-command-switch command)
         (file-name-as-directory
          (if working-directory (ogent-tools--resolve-path working-directory)
            (ogent-tools--project-root)))
         seconds callback))
    (error (ogent-tool-process--callback callback nil err) nil)))

(defun ogent-tool-process-bash (command &optional working-directory timeout)
  "Execute shell COMMAND and return its structured process data.
Use WORKING-DIRECTORY and TIMEOUT as in `ogent-tool-process-bash-async'.
Retain partial output on a nonzero exit, timeout or cancellation."
  (ogent-tool-process--wait
   (lambda (callback)
     (ogent-tool-process-bash-async command working-directory timeout callback))))

(defun ogent-tool-process--search-options (pattern path glob-filter context offset limit)
  "Validate search PATTERN, PATH, GLOB-FILTER, CONTEXT, OFFSET and LIMIT."
  (ogent-tools--grep-pattern pattern)
  (unless (or (null path) (and (stringp path) (not (string-empty-p path))))
    (user-error "Invalid grep path; use an existing file or directory path"))
  (unless (or (null glob-filter) (stringp glob-filter))
    (user-error "Invalid grep glob_filter; use a string, such as *.el"))
  (unless (and (integerp context) (<= 0 context ogent-tool-process--max-context))
    (user-error "Invalid grep context_lines; use an integer from 0 to %d"
                ogent-tool-process--max-context))
  (unless (and (integerp offset) (>= offset 0))
    (user-error "Invalid grep offset; use a non-negative integer, starting at 0"))
  (unless (and (integerp limit) (<= 1 limit ogent-tool-process--max-limit))
    (user-error "Invalid grep limit; use an integer from 1 to %d"
                ogent-tool-process--max-limit))
  (unless (and (numberp ogent-tools-grep-timeout) (> ogent-tools-grep-timeout 0))
    (user-error "Invalid grep timeout; set ogent-tools-grep-timeout to positive seconds"))
  (condition-case err
      (ogent-tools--grep-target path)
    (error (user-error "%s; use glob to find an existing search path"
                       (error-message-string err)))))

(defun ogent-tool-process--json-text (value)
  "Decode ripgrep text or base64 bytes from VALUE without human text parsing."
  (or (plist-get value :text)
      (when-let ((bytes (plist-get value :bytes)))
        (decode-coding-string (base64-decode-string bytes) 'utf-8-unix))
      ""))

(defun ogent-tool-process--grep-files (target glob-filter)
  "Return sorted regular files in TARGET matching GLOB-FILTER."
  (let ((case-fold-search nil)
        (regexp (and glob-filter (wildcard-to-regexp glob-filter))))
    (sort
     (cl-remove-if-not
      (lambda (file)
        (and (file-regular-p file)
             (not (string-match-p "/\\.git/" file))
             (or (null regexp)
                 (string-match-p regexp (file-name-nondirectory file))
                 (string-match-p regexp (file-relative-name file target)))))
      (if (file-directory-p target)
          (directory-files-recursively target "." nil nil)
        (list target)))
     #'string<)))

(defun ogent-tool-process-grep-async (pattern &optional path glob-filter context-lines
                                              offset limit callback)
  "Search PATTERN and return its asynchronous local process.
Search PATH with optional GLOB-FILTER and CONTEXT-LINES (0 through 20).
OFFSET is zero-based; LIMIT defaults to 200 and must be 1 through 200.
Call CALLBACK once with (DATA ERROR), where ERROR is a condition or nil.
DATA contains match objects, pagination, a snapshot hash and truncation flags.
Count all matching lines, retaining only the requested page and bounded text."
  (condition-case err
      (let* ((context (or context-lines 0))
             (start (or offset 0))
             (page-size (or limit ogent-tool-process--max-limit))
             (target-info (ogent-tool-process--search-options
                           pattern path glob-filter context start page-size))
             (directory (plist-get target-info :directory))
             (target (plist-get target-info :target))
             (rg (executable-find "rg"))
             (grep (and (not rg) (executable-find "grep")))
             (xargs (and grep (executable-find "xargs")))
             (engine (if rg "ripgrep-json" "gnu-grep-null"))
             (budget (max 0 ogent-tools-max-output-chars))
             (wire-limit (max 1048576 (* 8 budget)))
             (count 0) (retained 0) (pending "")
             (hash (secure-hash 'sha256 (prin1-to-string
                                         (list target pattern glob-filter context))))
             matches before active current-path truncated oversized encoding-loss
             input command temporary-file)
        (unless (or rg (and grep xargs))
          (signal 'ogent-tool-process-unavailable
                  '("Structured grep needs ripgrep or GNU grep with xargs; install ripgrep and retry")))
        (cl-labels
            ((bounded (text)
               (let* ((safe (ogent-tool-process--safe-text text))
                      (remaining (max 0 (- budget retained)))
                      (kept (substring safe 0 (min (length safe) remaining))))
                 (unless (equal safe text) (setq encoding-loss t))
                 (cl-incf retained (length kept))
                 (when (> (length text) remaining) (setq truncated t))
                 kept))
             (line (file number text matched)
               (unless (equal file (ogent-tool-process--safe-text file))
                 (signal 'ogent-tool-process-output-error
                         '("Search filename contains non-UTF-8 bytes; search a directory with UTF-8 filenames or rename the file before retrying")))
               (unless (equal file current-path)
                 (setq current-path file before nil active nil))
               (setq hash (secure-hash 'sha256
                                       (concat hash (prin1-to-string
                                                     (list file number text matched)))))
               (dolist (record active)
                 (when (<= (- number (plist-get record :line)) context)
                   (let* ((kept (bounded text))
                          (entry (list :line number :text kept)))
                     (unless (equal kept text)
                       (setq entry (plist-put entry :truncated t))
                       (plist-put record :truncated t))
                     (plist-put record :context_after
                                (vconcat (plist-get record :context_after)
                                         (vector entry))))))
               (setq active (cl-remove-if
                             (lambda (record)
                               (>= (- number (plist-get record :line)) context))
                             active))
               (when matched
                 (when (and (>= count start) (< count (+ start page-size)))
                   (let* ((kept (bounded text))
                          (record (list :path (expand-file-name file directory)
					:line number :text kept
					:truncated (if (equal kept text) :json-false t)
					:context_before
					(vconcat
                                         (mapcar
                                          (lambda (entry)
                                            (let* ((original (nth 1 entry))
                                                   (kept-context (bounded original))
                                                   (result (list :line (car entry)
                                                                 :text kept-context)))
                                              (when (or (nth 2 entry)
							(not (equal kept-context original)))
						(setq truncated t)
						(setq result (plist-put result :truncated t)))
                                              result))
                                          (reverse before)))
					:context_after [])))
                     (when (seq-some (lambda (entry) (eq (plist-get entry :truncated) t))
                                     (plist-get record :context_before))
                       (plist-put record :truncated t))
                     (push record matches)
                     (when (> context 0) (push record active))))
                 (cl-incf count))
               (when (> context 0)
                 ;; A bounded ring of source context, independent of page text.
                 (push (list number (substring text 0 (min budget (length text)))
                             (> (length text) budget)) before)
                 (when (> (length before) context)
                   (setcdr (nthcdr (1- context) before) nil))))
             (rg-line (text)
               (when (> (length text) wire-limit)
                 (signal 'ogent-tool-process-output-error
                         '("Search encountered a line larger than the structured wire limit; narrow the search path or read the file directly")))
               (let* ((event (json-parse-string text :object-type 'plist
                                                :array-type 'array
                                                :null-object :json-null
                                                :false-object :json-false))
                      (type (plist-get event :type))
                      (data (plist-get event :data)))
                 (when (member type '("match" "context"))
                   (line (ogent-tool-process--json-text (plist-get data :path))
                         (plist-get data :line_number)
                         (string-remove-suffix
                          "\n" (ogent-tool-process--json-text (plist-get data :lines)))
                         (equal type "match")))))
             (consume (chunk)
               (setq pending (concat pending chunk))
               (if rg
                   (let (end)
                     (while (setq end (string-match "\n" pending))
                       (rg-line (substring pending 0 end))
                       (setq pending (substring pending (1+ end)))))
                 (let (nul end)
                   (while (and (setq nul (string-match "\0" pending))
                               (setq end (string-match "\n" pending (1+ nul))))
                     (when (> end wire-limit)
                       (signal 'ogent-tool-process-output-error
                               '("Search encountered a line larger than the structured wire limit; narrow the search path or read the file directly")))
                     (let ((file (substring pending 0 nul))
                           (entry (substring pending (1+ nul) end)))
                       (unless (string-match "\\`\\([0-9]+\\)\\([:-]\\)" entry)
                         (signal 'ogent-tool-process-output-error
                                 '("GNU grep returned an unsupported record; install ripgrep and retry")))
                       (let ((number (string-to-number (match-string 1 entry)))
                             (matched (equal (match-string 2 entry) ":"))
                             (text (substring entry (match-end 0))))
                         (line file number text matched)))
                     (setq pending (substring pending (1+ end))))))
               ;; A pathological source line must not grow the retained wire
               ;; buffer without bound.  Fail explicitly instead of inventing
               ;; a complete count or dropping an unreported matching line.
               (when (> (length pending) wire-limit)
                 (setq oversized t)
                 (signal 'ogent-tool-process-output-error
                         '("Search encountered a line larger than the structured wire limit; narrow the search path or read the file directly"))))
             (finish (process-data error-data)
               (cond
                (error-data (ogent-tool-process--callback callback nil error-data))
                ((or (eq (plist-get process-data :timed_out) t)
                     (eq (plist-get process-data :cancelled) t))
                 (ogent-tool-process--callback
                  callback nil
                  (list (if (eq (plist-get process-data :timed_out) t)
                            'ogent-tool-process-search-timeout
                          'ogent-tool-process-search-cancelled)
                        (if (eq (plist-get process-data :timed_out) t)
                            "Search timed out; narrow path or glob_filter and retry"
                          "Search cancelled; retry the same search when ready"))))
                ((not (memq (plist-get process-data :exit_code) '(0 1)))
                 (ogent-tool-process--callback
                  callback nil
                  (list 'ogent-tool-process-search-failed
                        (ogent-tools--grep-failure
                         (plist-get process-data :exit_code)
                         (plist-get process-data :stderr)))))
                (t
                 (ogent-tool-process--callback
                  callback
                  (list :path target :matches (vconcat (nreverse matches))
                        :offset start :limit page-size :total_matches count
                        :has_more (if (> count (+ start page-size)) t :json-false)
                        :next_offset (if (> count (+ start page-size))
                                         (+ start page-size) :json-null)
                        :truncated (if (or truncated oversized) t :json-false)
                        :encoding_loss (if encoding-loss t :json-false)
                        :snapshot hash :engine engine)
                  nil)))))
          (if rg
              (setq command
                    (append (list rg "--json" "--sort" "path" "--color=never"
                                  "--hidden" "--no-ignore" "-g" "!**/.git/**"
                                  "-C" (number-to-string context))
                            (when glob-filter (list "-g" glob-filter))
                            (list "--" pattern target)))
            ;; xargs preserves ordered filename input and invokes grep in
            ;; argument-size-safe batches.  Normalize grep's no-match exit 1.
            (setq input (mapconcat #'identity
                                   (ogent-tool-process--grep-files target glob-filter)
                                   "\0"))
            (unless (string-empty-p input) (setq input (concat input "\0")))
            (setq temporary-file (make-temp-file "ogent-grep-files-"))
            (condition-case write-error
                (let ((coding-system-for-write 'utf-8-unix))
                  (with-temp-file temporary-file (insert input)))
              (error
               (when (file-exists-p temporary-file) (delete-file temporary-file))
               (signal (car write-error) (cdr write-error))))
            (setq command
                  (list shell-file-name shell-command-switch
                        (concat
                         (mapconcat
                          #'shell-quote-argument
                          (list xargs "-0" "-r" "-n" "128"
                                shell-file-name shell-command-switch
                                (concat
                                 (mapconcat
                                  #'shell-quote-argument
                                  (list grep "-HnZE" "--color=never"
                                        "--binary-files=without-match"
                                        "--no-group-separator" "-C"
                                        (number-to-string context) "--" pattern)
                                  " ")
                                 " \"$@\"; code=$?; test \"$code\" -le 1")
                                "ogent-grep")
                          " ")
                         " < " (shell-quote-argument temporary-file)))))
          (ogent-tool-process--run
           command directory ogent-tools-grep-timeout #'finish #'consume nil
           (lambda ()
             (when (and temporary-file (file-exists-p temporary-file))
               (delete-file temporary-file))))))
    (error (ogent-tool-process--callback callback nil err) nil)))

(defun ogent-tool-process-grep (pattern &optional path glob-filter context-lines offset limit)
  "Search PATTERN and return a structured match page.
Use PATH, GLOB-FILTER, CONTEXT-LINES, OFFSET and LIMIT as in
`ogent-tool-process-grep-async'.  Signal actionable errors on search failure."
  (ogent-tool-process--wait
   (lambda (callback)
     (ogent-tool-process-grep-async
      pattern path glob-filter context-lines offset limit callback))))

(provide 'ogent-tool-process)
;;; ogent-tool-process.el ends here
