;;; ogent-cabinet-runner.el --- Run Org cabinet agents via local CLIs -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs Cabinet agents through locally authenticated coding CLIs.  The runner
;; plans commands from Org persona and job records, starts the process, and
;; stores the resulting transcript back into the agent's Org session directory.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'subr-x)
(require 'ogent-cabinet)

(defgroup ogent-cabinet-runner nil
  "Run Org Cabinet agents through subscription-authenticated CLIs."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-runner-")

(defcustom ogent-cabinet-codex-executable "codex"
  "Executable used for Codex CLI agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-claude-executable "claude"
  "Executable used for Claude Code agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-confirm-before-run t
  "When non-nil, ask before starting a CLI agent from an interactive command."
  :type 'boolean
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-codex-sandbox "workspace-write"
  "Sandbox mode passed to `codex exec'."
  :type '(choice (const "read-only")
                 (const "workspace-write")
                 (const "danger-full-access"))
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-codex-approval "on-request"
  "Approval policy passed to the Codex CLI."
  :type '(choice (const "untrusted")
                 (const "on-request")
                 (const "never"))
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-codex-skip-git-repo-check t
  "When non-nil, pass `--skip-git-repo-check' to `codex exec'."
  :type 'boolean
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-claude-permission-mode "default"
  "Permission mode passed to Claude Code."
  :type '(choice (const "default")
                 (const "plan")
                 (const "acceptEdits")
                 (const "auto")
                 (const "bypassPermissions")
                 (const "dontAsk"))
  :group 'ogent-cabinet-runner)

(defvar ogent-cabinet-runner--processes nil
  "Active Cabinet runner processes.")

(defun ogent-cabinet-runner-running-p (agent-slug)
  "Return non-nil when AGENT-SLUG has a live Cabinet runner process."
  (cl-some
   (lambda (process)
     (let* ((plan (process-get process 'ogent-cabinet-plan))
            (agent (plist-get plan :agent)))
       (and (process-live-p process)
            (equal (plist-get agent :slug) agent-slug))))
   ogent-cabinet-runner--processes))

(defun ogent-cabinet-runner--blank-to-nil (value)
  "Return nil when VALUE is nil or blank."
  (when (and value (not (string-blank-p value)))
    value))

(defun ogent-cabinet-runner-normalize-provider (provider)
  "Return canonical provider symbol for PROVIDER."
  (let ((value (downcase (string-trim (format "%s" (or provider "codex"))))))
    (cond
     ((member value '("" "default" "codex" "codex-cli" "openai-codex"))
      'codex)
     ((member value '("claude" "claude-code" "anthropic" "anthropic-claude"))
      'claude)
     (t (intern value)))))

(defun ogent-cabinet-runner--workspace (root agent)
  "Return the workspace path for AGENT under ROOT."
  (let ((workspace (ogent-cabinet-runner--blank-to-nil
                    (plist-get agent :workspace))))
    (file-name-as-directory
     (file-truename
      (cond
       ((or (null workspace) (equal workspace "/")) root)
       ((file-name-absolute-p workspace) workspace)
       (t (expand-file-name workspace root)))))))

(defun ogent-cabinet-runner--effective (agent job key)
  "Return KEY from JOB when present, otherwise from AGENT."
  (or (and job (ogent-cabinet-runner--blank-to-nil (plist-get job key)))
      (ogent-cabinet-runner--blank-to-nil (plist-get agent key))))

(defun ogent-cabinet-runner--session-file (root agent-slug &optional job-id)
  "Return a fresh session file under ROOT for AGENT-SLUG and JOB-ID."
  (let* ((timestamp (format-time-string "%Y%m%dT%H%M%S"))
         (name (if job-id
                   (format "%s-%s.org" timestamp job-id)
                 (format "%s-run.org" timestamp)))
         (file (expand-file-name
                name
                (expand-file-name "sessions"
                                  (ogent-cabinet-agent-directory
                                   root agent-slug)))))
    (make-directory (file-name-directory file) t)
    file))

(defun ogent-cabinet-runner--prompt (agent &optional job instruction)
  "Return a CLI prompt from AGENT, optional JOB, and INSTRUCTION."
  (string-join
   (delq
    nil
    (list
     (format "You are the Org Cabinet agent named %s."
             (or (plist-get agent :name) (plist-get agent :slug) "agent"))
     (when-let ((role (ogent-cabinet-runner--blank-to-nil
                       (plist-get agent :role))))
       (format "Role: %s" role))
     (when-let ((body (ogent-cabinet-runner--blank-to-nil
                       (plist-get agent :body))))
       (format "Persona instructions:\n%s" body))
     (when job
       (format "Run this Cabinet job: %s."
               (or (plist-get job :name) (plist-get job :id))))
     (when-let ((job-body (and job
                               (ogent-cabinet-runner--blank-to-nil
                                (plist-get job :body)))))
       (format "Job instructions:\n%s" job-body))
     (when-let ((user-instruction
                 (ogent-cabinet-runner--blank-to-nil instruction)))
       (format "User instruction:\n%s" user-instruction))))
   "\n\n"))

(defun ogent-cabinet-runner--append-option (args option value)
  "Append OPTION and VALUE to ARGS when VALUE is nonblank."
  (if (ogent-cabinet-runner--blank-to-nil value)
      (append args (list option value))
    args))

(cl-defun ogent-cabinet-runner-plan
    (directory agent-slug &key job-id instruction)
  "Return a process plan for AGENT-SLUG under DIRECTORY.
JOB-ID selects a recurring job.  INSTRUCTION supplies an ad hoc prompt."
  (let* ((candidate (ogent-cabinet--directory directory))
         (root (file-truename
                (ogent-cabinet--directory
                 (or (ogent-cabinet-find-root candidate)
                     candidate))))
         (agent (ogent-cabinet-read-agent root agent-slug))
         (job (when job-id
                (ogent-cabinet-validate-job
                 (ogent-cabinet-read-job root agent-slug job-id))))
         (provider (ogent-cabinet-runner-normalize-provider
                    (or (ogent-cabinet-runner--effective agent job :provider)
                        (plist-get agent :provider))))
         (workspace (ogent-cabinet-runner--workspace
                     root
                     (if (and job (plist-get job :workspace))
                         (plist-put (copy-sequence agent)
                                    :workspace
                                    (plist-get job :workspace))
                       agent)))
         (prompt (ogent-cabinet-runner--prompt agent job instruction))
         (model (ogent-cabinet-runner--effective agent job :model))
         (permission-mode (or (ogent-cabinet-runner--blank-to-nil
                               (plist-get agent :permission-mode))
                              ogent-cabinet-runner-claude-permission-mode))
         (session-file (ogent-cabinet-runner--session-file
                        root agent-slug job-id)))
    (unless (file-directory-p workspace)
      (user-error "Cabinet agent workspace not found: %s" workspace))
    (pcase provider
      ('codex
       (let ((args (list "--ask-for-approval"
                         ogent-cabinet-runner-codex-approval
                         "exec"
                         "--cd" workspace
                         "--sandbox" ogent-cabinet-runner-codex-sandbox)))
         (when ogent-cabinet-runner-codex-skip-git-repo-check
           (setq args (append args (list "--skip-git-repo-check"))))
         (setq args (ogent-cabinet-runner--append-option args "--model" model))
         (list :provider provider
               :program ogent-cabinet-codex-executable
               :args (append args (list "-"))
               :prompt prompt
               :stdin prompt
               :root root
               :workspace workspace
               :agent agent
               :job job
               :session-file session-file)))
      ('claude
       (let ((args (list "-p"
                         "--permission-mode" permission-mode
                         "--add-dir" root)))
         (setq args (ogent-cabinet-runner--append-option args "--model" model))
         (list :provider provider
               :program ogent-cabinet-claude-executable
               :args (append args (list prompt))
               :prompt prompt
               :stdin nil
               :root root
               :workspace workspace
               :agent agent
               :job job
               :session-file session-file)))
      (_
       (user-error "Unsupported Cabinet agent provider: %s" provider)))))

(defun ogent-cabinet-runner--org-src-text (text)
  "Return TEXT escaped for insertion in an Org src block."
  (let ((escaped
         (mapconcat
          (lambda (line)
            (let ((case-fold-search t))
              (if (string-match-p "\\`[ \t]*#\\+end_src\\_>" line)
                  (concat "," line)
                line)))
          (split-string (or text "") "\n")
          "\n")))
    (cond
     ((string-empty-p escaped) "")
     ((string-suffix-p "\n" escaped) escaped)
     (t (concat escaped "\n")))))

(defun ogent-cabinet-runner--command-preview (plan)
  "Return a shell-like command preview for PLAN."
  (let* ((program (plist-get plan :program))
         (provider (plist-get plan :provider))
         (args (copy-sequence (plist-get plan :args))))
    (when (and (eq provider 'claude) args)
      (setcar (last args) "<prompt>"))
    (string-join (mapcar #'shell-quote-argument (cons program args)) " ")))

(defun ogent-cabinet-runner--app-paths-from-output (root output error-output)
  "Return app directories under ROOT mentioned in OUTPUT or ERROR-OUTPUT."
  (let ((text (concat (or output "") "\n" (or error-output "")))
        (true-root (file-name-as-directory (file-truename root)))
        (case-fold-search t)
        paths)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "\\([^[:space:]\n\r\"'()<>]+index\\.html\\)" nil t)
        (let* ((candidate (match-string 1))
               (file (file-truename
                      (if (file-name-absolute-p candidate)
                          candidate
                        (expand-file-name candidate root)))))
          (when (and (file-exists-p file)
                     (file-in-directory-p file true-root))
            (push (directory-file-name
                   (file-relative-name (file-name-directory file) true-root))
                  paths)))))
    (delete-dups (nreverse paths))))

(defun ogent-cabinet-runner--buffer-output (process)
  "Return generated stdout from PROCESS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (buffer-substring-no-properties
       (let ((start (process-get process 'ogent-cabinet-output-start)))
         (cond
          ((integerp start) start)
          ((markerp start) (marker-position start))
          (t (point-min))))
       (point-max)))))

(defun ogent-cabinet-runner--format-session (plan output error-output exit-status)
  "Return an Org session transcript for PLAN, OUTPUT, ERROR-OUTPUT, EXIT-STATUS."
  (let* ((agent (plist-get plan :agent))
         (job (plist-get plan :job))
         (provider (plist-get plan :provider))
         (status (if (zerop exit-status) "DONE" "FAILED"))
         (title (format "%s %s"
                        (or (plist-get agent :name) (plist-get agent :slug))
                        (or (plist-get job :name) "Run"))))
    (concat
     (format "#+title: %s\n\n" title)
     (format "* %s %s\n" status title)
     (ogent-cabinet--format-properties
      `(("OGENT_SESSION" . t)
        ("OGENT_AGENT" . ,(plist-get agent :slug))
        ("OGENT_PROVIDER" . ,provider)
        ("OGENT_MODEL" . ,(or (plist-get job :model)
                              (plist-get agent :model)
                              ""))
        ("OGENT_JOB_ID" . ,(or (plist-get job :id) ""))
        ("OGENT_EXIT_STATUS" . ,exit-status)
        ("OGENT_DURATION" . ,(or (plist-get plan :duration) ""))
        ("OGENT_WORKSPACE" . ,(plist-get plan :workspace))
        ("OGENT_APP_PATHS" . ,(ogent-cabinet-runner--app-paths-from-output
                               (plist-get plan :root)
                               output
                               error-output))
        ("OGENT_FINISHED" . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))))
     "\n** Prompt\n"
     "#+begin_src text\n"
     (ogent-cabinet-runner--org-src-text (plist-get plan :prompt))
     "#+end_src\n\n"
     "** Output\n"
     "#+begin_src text\n"
     (ogent-cabinet-runner--org-src-text output)
     "#+end_src\n"
     (when (ogent-cabinet-runner--blank-to-nil error-output)
       (concat "\n** "
               (if (zerop exit-status) "Runtime Trace" "Error")
               "\n#+begin_src text\n"
               (ogent-cabinet-runner--org-src-text error-output)
               "#+end_src\n")))))

(defun ogent-cabinet-runner--write-session (plan output error-output exit-status)
  "Write PLAN transcript with OUTPUT, ERROR-OUTPUT, and EXIT-STATUS."
  (let ((file (plist-get plan :session-file)))
    (ogent-cabinet--write-file
     file
     (ogent-cabinet-runner--format-session
      plan output error-output exit-status))
    file))

(defun ogent-cabinet-runner-start (plan)
  "Start PLAN and return its process."
  (let* ((program (plist-get plan :program))
         (args (plist-get plan :args))
         (stdin (plist-get plan :stdin))
         (workspace (plist-get plan :workspace))
         (buffer (get-buffer-create
                 (format "*ogent-cabinet-agent:%s*"
                          (plist-get (plist-get plan :agent) :slug))))
         (stderr-buffer (generate-new-buffer " *ogent-cabinet-agent-stderr*"))
         output-start
         (started-at (float-time))
         proc)
    (unless (executable-find program)
      (user-error "Cabinet runner executable not found: %s" program))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ %s\n\n"
                        (ogent-cabinet-runner--command-preview plan)))
        (setq output-start (point))))
    (let ((default-directory workspace))
      (setq proc
            (make-process
             :name "ogent-cabinet-agent"
             :buffer buffer
             :stderr stderr-buffer
             :command (cons program args)
             :connection-type 'pipe
             :sentinel
             (lambda (process event)
               (unless (process-live-p process)
                 (setq ogent-cabinet-runner--processes
                       (delq process ogent-cabinet-runner--processes))
                 (let* ((exit-status (process-exit-status process))
                        (output (ogent-cabinet-runner--buffer-output process))
                        (error-output
                         (when (buffer-live-p stderr-buffer)
                           (string-trim
                            (with-current-buffer stderr-buffer
                              (buffer-string)))))
                        (session-file
                         (progn
                           (plist-put plan
                                      :duration
                                      (format "%.2fs"
                                              (- (float-time) started-at)))
                           (ogent-cabinet-runner--write-session
                            plan output error-output exit-status))))
                   (process-put process 'ogent-cabinet-session-file session-file)
                   (when (buffer-live-p stderr-buffer)
                     (kill-buffer stderr-buffer))
                   (message "Cabinet agent finished: %s (%s)"
                            session-file
                            (string-trim event))))))))
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'ogent-cabinet-plan plan)
    (process-put proc 'ogent-cabinet-output-start output-start)
    (push proc ogent-cabinet-runner--processes)
    (when stdin
      (process-send-string proc stdin)
      (process-send-eof proc))
    proc))

(defun ogent-cabinet-runner--read-agent (root)
  "Read an agent slug from ROOT."
  (completing-read "Agent: " (ogent-cabinet-list-agents root) nil t))

(defun ogent-cabinet-runner--read-job (root agent-slug)
  "Read a job id for AGENT-SLUG under ROOT."
  (completing-read
   "Job: "
   (mapcar (lambda (job) (plist-get job :id))
           (ogent-cabinet-list-jobs root agent-slug))
   nil t))

(defun ogent-cabinet-runner--confirm (plan)
  "Return non-nil when PLAN may start."
  (or (not ogent-cabinet-runner-confirm-before-run)
      (yes-or-no-p
       (format "Run %s agent %s in %s and send prompt text to the CLI provider? "
               (plist-get plan :provider)
               (plist-get (plist-get plan :agent) :slug)
               (abbreviate-file-name (plist-get plan :workspace))))))

;;;###autoload
(defun ogent-cabinet-run-agent (directory agent-slug instruction)
  "Run AGENT-SLUG under DIRECTORY with INSTRUCTION."
  (interactive
   (let* ((root (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))
          (agent (ogent-cabinet-runner--read-agent root)))
     (list root agent (read-string "Instruction: "))))
  (let ((plan (ogent-cabinet-runner-plan
               directory agent-slug :instruction instruction)))
    (when (ogent-cabinet-runner--confirm plan)
      (ogent-cabinet-runner-start plan))))

;;;###autoload
(defun ogent-cabinet-run-job (directory agent-slug job-id)
  "Run JOB-ID for AGENT-SLUG under DIRECTORY."
  (interactive
   (let* ((root (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))
          (agent (ogent-cabinet-runner--read-agent root))
          (job (ogent-cabinet-runner--read-job root agent)))
     (list root agent job)))
  (let ((plan (ogent-cabinet-runner-plan
               directory agent-slug :job-id job-id)))
    (when (ogent-cabinet-runner--confirm plan)
      (ogent-cabinet-runner-start plan))))

(defun ogent-cabinet-runner-auth-status (provider)
  "Return local subscription auth status for PROVIDER."
  (pcase (ogent-cabinet-runner-normalize-provider provider)
    ('codex
     (let* ((program ogent-cabinet-codex-executable)
            (buffer (generate-new-buffer " *ogent-codex-auth*"))
            (exit (when (executable-find program)
                    (call-process program nil buffer nil "login" "status")))
            (output (when (buffer-live-p buffer)
                      (prog1 (string-trim
                              (with-current-buffer buffer (buffer-string)))
                        (kill-buffer buffer)))))
       (list :provider 'codex
             :logged-in (and (integerp exit) (zerop exit))
             :method output
             :raw output)))
    ('claude
     (let* ((program ogent-cabinet-claude-executable)
            (buffer (generate-new-buffer " *ogent-claude-auth*"))
            (exit (when (executable-find program)
                    (call-process program nil buffer nil "auth" "status")))
            (output (when (buffer-live-p buffer)
                      (prog1 (string-trim
                              (with-current-buffer buffer (buffer-string)))
                        (kill-buffer buffer))))
            (parsed (when (and output (not (string-empty-p output)))
                      (condition-case nil
                          (let ((json-object-type 'plist)
                                (json-array-type 'list)
                                (json-key-type 'keyword))
                            (json-read-from-string output))
                        (error nil)))))
       (list :provider 'claude
             :logged-in (and (integerp exit)
                             (zerop exit)
                             (plist-get parsed :loggedIn))
             :method (plist-get parsed :authMethod)
             :subscription (plist-get parsed :subscriptionType)
             :raw output)))
    (_ (list :provider provider :logged-in nil :raw "unsupported provider"))))

(provide 'ogent-cabinet-runner)

;;; ogent-cabinet-runner.el ends here
