;;; ogent-armory-runner.el --- Run Org armory agents via local CLIs -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs Armory agents through locally authenticated coding CLIs.  The runner
;; plans commands from Org persona and job records, starts the process, and
;; stores the resulting transcript in the canonical Org conversation store.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'subr-x)
(require 'ogent-armory)
(require 'ogent-armory-conversations)

(defgroup ogent-armory-runner nil
  "Run Org Armory agents through subscription-authenticated CLIs."
  :group 'ogent-armory
  :prefix "ogent-armory-runner-")

(defcustom ogent-armory-codex-executable "codex"
  "Executable used for Codex CLI agents."
  :type 'string
  :group 'ogent-armory-runner)

(defcustom ogent-armory-claude-executable "claude"
  "Executable used for Claude Code agents."
  :type 'string
  :group 'ogent-armory-runner)

(defcustom ogent-armory-runner-confirm-before-run t
  "When non-nil, ask before starting a CLI agent from an interactive command."
  :type 'boolean
  :group 'ogent-armory-runner)

(defcustom ogent-armory-runner-codex-sandbox "workspace-write"
  "Sandbox mode passed to `codex exec'."
  :type '(choice (const "read-only")
                 (const "workspace-write")
                 (const "danger-full-access"))
  :group 'ogent-armory-runner)

(defcustom ogent-armory-runner-codex-approval "on-request"
  "Approval policy passed to the Codex CLI."
  :type '(choice (const "untrusted")
                 (const "on-request")
                 (const "never"))
  :group 'ogent-armory-runner)

(defcustom ogent-armory-runner-codex-skip-git-repo-check t
  "When non-nil, pass `--skip-git-repo-check' to `codex exec'."
  :type 'boolean
  :group 'ogent-armory-runner)

(defcustom ogent-armory-runner-claude-permission-mode "default"
  "Permission mode passed to Claude Code."
  :type '(choice (const "default")
                 (const "plan")
                 (const "acceptEdits")
                 (const "auto")
                 (const "bypassPermissions")
                 (const "dontAsk"))
  :group 'ogent-armory-runner)

(defvar ogent-armory-runner--processes nil
  "Active Armory runner processes.")

(defun ogent-armory-runner-running-p (agent-slug)
  "Return non-nil when AGENT-SLUG has a live Armory runner process."
  (cl-some
   (lambda (process)
     (let* ((plan (process-get process 'ogent-armory-plan))
            (agent (plist-get plan :agent)))
       (and (process-live-p process)
            (equal (plist-get agent :slug) agent-slug))))
   ogent-armory-runner--processes))

(defun ogent-armory-runner--blank-to-nil (value)
  "Return nil when VALUE is nil or blank."
  (when (and value (not (string-blank-p value)))
    value))

(defun ogent-armory-runner-normalize-provider (provider)
  "Return canonical provider symbol for PROVIDER."
  (let ((value (downcase (string-trim (format "%s" (or provider "codex"))))))
    (cond
     ((member value '("" "default" "codex" "codex-cli" "openai-codex"))
      'codex)
     ((member value '("claude" "claude-code" "anthropic" "anthropic-claude"))
      'claude)
     (t (intern value)))))

(defun ogent-armory-runner--workspace (root agent)
  "Return the workspace path for AGENT under ROOT."
  (let ((workspace (ogent-armory-runner--blank-to-nil
                    (plist-get agent :workspace))))
    (file-name-as-directory
     (file-truename
      (cond
       ((or (null workspace) (equal workspace "/")) root)
       ((file-name-absolute-p workspace) workspace)
       (t (expand-file-name workspace root)))))))

(defun ogent-armory-runner--effective (agent job key)
  "Return KEY from JOB when present, otherwise from AGENT."
  (or (and job (ogent-armory-runner--blank-to-nil (plist-get job key)))
      (ogent-armory-runner--blank-to-nil (plist-get agent key))))

(defun ogent-armory-runner--session-file (root agent-slug &optional job-id)
  "Return a fresh session file under ROOT for AGENT-SLUG and JOB-ID."
  (let* ((timestamp (format-time-string "%Y%m%dT%H%M%S"))
         (name (if job-id
                   (format "%s-%s.org" timestamp job-id)
                 (format "%s-run.org" timestamp)))
         (file (expand-file-name
                name
                (expand-file-name "sessions"
                                  (ogent-armory-agent-directory
                                   root agent-slug)))))
    (make-directory (file-name-directory file) t)
    file))

(defun ogent-armory-runner--conversation-id (&optional job-id)
  "Return a fresh canonical conversation id for optional JOB-ID."
  (format "%s-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%S")
          (or job-id "run")
          (random #x1000000)))

(defun ogent-armory-runner--prompt (agent &optional job instruction)
  "Return a CLI prompt from AGENT, optional JOB, and INSTRUCTION."
  (string-join
   (delq
    nil
    (list
     (format "You are the Org Armory agent named %s."
             (or (plist-get agent :name) (plist-get agent :slug) "agent"))
     (when-let ((role (ogent-armory-runner--blank-to-nil
                       (plist-get agent :role))))
       (format "Role: %s" role))
     (when-let ((body (ogent-armory-runner--blank-to-nil
                       (plist-get agent :body))))
       (format "Persona instructions:\n%s" body))
     (when job
       (format "Run this Armory job: %s."
               (or (plist-get job :name) (plist-get job :id))))
     (when-let ((job-body (and job
                               (ogent-armory-runner--blank-to-nil
                                (plist-get job :body)))))
       (format "Job instructions:\n%s" job-body))
     (when-let ((user-instruction
                 (ogent-armory-runner--blank-to-nil instruction)))
       (format "User instruction:\n%s" user-instruction))))
   "\n\n"))

(defun ogent-armory-runner--append-option (args option value)
  "Append OPTION and VALUE to ARGS when VALUE is nonblank."
  (if (ogent-armory-runner--blank-to-nil value)
      (append args (list option value))
    args))

(cl-defun ogent-armory-runner-plan
    (directory agent-slug
               &key job-id instruction conversation-id conversation-title
               turn-content trigger last-resume-result)
  "Return a process plan for AGENT-SLUG under DIRECTORY.
JOB-ID selects a recurring job.  INSTRUCTION supplies an ad hoc prompt."
  (let* ((candidate (ogent-armory--directory directory))
         (root (file-truename
                (ogent-armory--directory
                 (or (ogent-armory-find-root candidate)
                     candidate))))
         (agent (ogent-armory-read-agent root agent-slug))
         (job (when job-id
                (ogent-armory-validate-job
                 (ogent-armory-read-job root agent-slug job-id))))
         (provider (ogent-armory-runner-normalize-provider
                    (or (ogent-armory-runner--effective agent job :provider)
                        (plist-get agent :provider))))
         (workspace (ogent-armory-runner--workspace
                     root
                     (if (and job (plist-get job :workspace))
                         (plist-put (copy-sequence agent)
                                    :workspace
                                    (plist-get job :workspace))
                       agent)))
         (prompt (ogent-armory-runner--prompt agent job instruction))
         (model (ogent-armory-runner--effective agent job :model))
         (permission-mode (or (ogent-armory-runner--blank-to-nil
                               (plist-get agent :permission-mode))
                              ogent-armory-runner-claude-permission-mode))
         (conversation-id (or conversation-id
                              (ogent-armory-runner--conversation-id job-id))))
    (unless (file-directory-p workspace)
      (user-error "Armory agent workspace not found: %s" workspace))
    (pcase provider
      ('codex
       (let ((args (list "--ask-for-approval"
                         ogent-armory-runner-codex-approval
                         "exec"
                         "--cd" workspace
                         "--sandbox" ogent-armory-runner-codex-sandbox)))
         (when ogent-armory-runner-codex-skip-git-repo-check
           (setq args (append args (list "--skip-git-repo-check"))))
         (setq args (ogent-armory-runner--append-option args "--model" model))
         (list :provider provider
               :program ogent-armory-codex-executable
               :args (append args (list "-"))
               :prompt prompt
               :stdin prompt
               :root root
	       :workspace workspace
	       :agent agent
	       :job job
               :conversation-id conversation-id
               :conversation-title conversation-title
               :turn-content turn-content
               :trigger trigger
               :last-resume-result last-resume-result)))
      ('claude
       (let ((args (list "-p"
                         "--permission-mode" permission-mode
                         "--add-dir" root)))
         (setq args (ogent-armory-runner--append-option args "--model" model))
         (list :provider provider
               :program ogent-armory-claude-executable
               :args (append args (list prompt))
               :prompt prompt
               :stdin nil
               :root root
	       :workspace workspace
	       :agent agent
	       :job job
               :conversation-id conversation-id
               :conversation-title conversation-title
               :turn-content turn-content
               :trigger trigger
               :last-resume-result last-resume-result)))
      (_
       (user-error "Unsupported Armory agent provider: %s" provider)))))

(defun ogent-armory-runner--org-src-text (text)
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

(defun ogent-armory-runner--command-preview (plan)
  "Return a shell-like command preview for PLAN."
  (let* ((program (plist-get plan :program))
         (provider (plist-get plan :provider))
         (args (copy-sequence (plist-get plan :args))))
    (when (and (eq provider 'claude) args)
      (setcar (last args) "<prompt>"))
    (string-join (mapcar #'shell-quote-argument (cons program args)) " ")))

(defun ogent-armory-runner--app-paths-from-output (root output error-output)
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

(defun ogent-armory-runner--buffer-output (process)
  "Return generated stdout from PROCESS."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (buffer-substring-no-properties
       (let ((start (process-get process 'ogent-armory-output-start)))
         (cond
          ((integerp start) start)
          ((markerp start) (marker-position start))
          (t (point-min))))
       (point-max)))))

(defun ogent-armory-runner--format-session (plan output error-output exit-status)
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
     (ogent-armory--format-properties
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
        ("OGENT_APP_PATHS" . ,(ogent-armory-runner--app-paths-from-output
                               (plist-get plan :root)
                               output
                               error-output))
        ("OGENT_FINISHED" . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z"))))
     "\n** Prompt\n"
     "#+begin_src text\n"
     (ogent-armory-runner--org-src-text (plist-get plan :prompt))
     "#+end_src\n\n"
     "** Output\n"
     "#+begin_src text\n"
     (ogent-armory-runner--org-src-text output)
     "#+end_src\n"
     (when (ogent-armory-runner--blank-to-nil error-output)
       (concat "\n** "
               (if (zerop exit-status) "Runtime Trace" "Error")
               "\n#+begin_src text\n"
               (ogent-armory-runner--org-src-text error-output)
               "#+end_src\n")))))

(defun ogent-armory-runner--write-session (plan output error-output exit-status)
  "Write PLAN transcript with OUTPUT, ERROR-OUTPUT, and EXIT-STATUS."
  (let ((file (plist-get plan :session-file)))
    (ogent-armory--write-file
     file
     (ogent-armory-runner--format-session
      plan output error-output exit-status))
    file))

(defun ogent-armory-runner--conversation-title (plan)
  "Return a user-facing conversation title for PLAN."
  (or (plist-get plan :conversation-title)
      (let ((agent (plist-get plan :agent))
            (job (plist-get plan :job)))
        (format "%s %s"
                (or (plist-get agent :name) (plist-get agent :slug))
                (or (plist-get job :name) "Run")))))

(defun ogent-armory-runner--iso-now ()
  "Return the current time as an ISO-like local timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun ogent-armory-runner--create-conversation (plan started)
  "Prepare the running canonical conversation for PLAN at STARTED."
  (let* ((root (plist-get plan :root))
         (agent (plist-get plan :agent))
         (job (plist-get plan :job))
         (conversation-id (plist-get plan :conversation-id))
         (file (ogent-armory-conversation-file root conversation-id))
         (existing (file-exists-p file))
         (trigger (or (plist-get plan :trigger)
                      (if job "job" "manual"))))
    (if existing
        (ogent-armory-conversation-update-properties
         root conversation-id
         `(("OGENT_STATUS" . "running")
           ("OGENT_LAST_ACTIVITY_AT" . ,started)
           ("OGENT_STARTED_AT" . ,started)
           ("OGENT_COMPLETED_AT" . "")
           ("OGENT_EXIT_CODE" . "")
           ("OGENT_DURATION" . "")
           ("OGENT_TRIGGER" . ,trigger)
           ("OGENT_LAST_RESUME_RESULT" .
            ,(plist-get plan :last-resume-result))))
      (setq file
            (ogent-armory-conversation-create
             root
             (list
              :id conversation-id
              :agent (plist-get agent :slug)
              :title (ogent-armory-runner--conversation-title plan)
              :trigger trigger
              :status "running"
              :started started
              :last-activity started
              :provider (plist-get plan :provider)
              :model (or (plist-get job :model)
                         (plist-get agent :model))
              :job-id (plist-get job :id)
              :job-name (plist-get job :name)
              :runtime-mode "native"))))
    (ogent-armory-conversation-append-turn
     root conversation-id "user"
     (or (plist-get plan :turn-content)
         (plist-get plan :prompt))
     :ts started)
    (ogent-armory-conversation-append-event
     root conversation-id
     (if existing "conversation.continued" "task.started")
     :ts started
     :payload (format "trigger=%s" trigger))
    file))

(defun ogent-armory-runner--final-status (plan exit-status parsed)
  "Return canonical final status for PLAN, EXIT-STATUS, and PARSED metadata."
  (cond
   ((plist-get plan :cancelled) "cancelled")
   ((not (zerop exit-status)) "failed")
   ((plist-get parsed :awaiting-input) "awaiting-input")
   (t "done")))

(defun ogent-armory-runner--finalize-conversation
    (plan output error-output exit-status)
  "Finalize PLAN conversation with OUTPUT, ERROR-OUTPUT, and EXIT-STATUS."
  (let* ((root (plist-get plan :root))
         (conversation-id (plist-get plan :conversation-id))
         (finished (ogent-armory-runner--iso-now))
         (parsed (ogent-armory-conversation-parse-output output))
         (app-paths (ogent-armory-runner--app-paths-from-output
                     root output error-output))
         (artifact-paths (delete-dups
                          (append (copy-sequence
                                   (plist-get parsed :artifact-paths))
                                  app-paths)))
         (status (ogent-armory-runner--final-status plan exit-status parsed)))
    (ogent-armory-conversation-append-turn
     root conversation-id "agent" output
     :ts finished
     :exit-code exit-status
     :error (unless (zerop exit-status) error-output)
     :awaiting-input (plist-get parsed :awaiting-input)
     :artifacts artifact-paths)
    (ogent-armory-conversation-update-properties
     root conversation-id
     `(("OGENT_STATUS" . ,status)
       ("OGENT_COMPLETED_AT" . ,finished)
       ("OGENT_LAST_ACTIVITY_AT" . ,finished)
       ("OGENT_EXIT_CODE" . ,exit-status)
       ("OGENT_DURATION" . ,(or (plist-get plan :duration) ""))
       ("OGENT_ARTIFACTS" . ,artifact-paths)
       ("OGENT_SUMMARY" . ,(plist-get parsed :summary))
       ("OGENT_CONTEXT_SUMMARY" . ,(plist-get parsed :context-summary))
       ("OGENT_AWAITING_INPUT" . ,(plist-get parsed :awaiting-input))))
    (ogent-armory-conversation-append-event
     root conversation-id "task.updated"
     :ts finished
     :payload (format "status=%s" status))
    (ogent-armory-conversation-file root conversation-id)))

(defun ogent-armory-runner-start (plan)
  "Start PLAN and return its process."
  (let* ((program (plist-get plan :program))
         (args (plist-get plan :args))
         (stdin (plist-get plan :stdin))
         (workspace (plist-get plan :workspace))
         (buffer (get-buffer-create
                 (format "*ogent-armory-agent:%s*"
                          (plist-get (plist-get plan :agent) :slug))))
         (stderr-buffer (generate-new-buffer " *ogent-armory-agent-stderr*"))
         output-start
         (started-at (float-time))
         (started (ogent-armory-runner--iso-now))
         proc)
    (unless (executable-find program)
      (user-error "Armory runner executable not found: %s" program))
    (let ((conversation-file
           (ogent-armory-runner--create-conversation plan started)))
      (plist-put plan :conversation-file conversation-file))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "$ %s\n\n"
                        (ogent-armory-runner--command-preview plan)))
        (setq output-start (point))))
    (let ((default-directory workspace))
      (setq proc
            (make-process
             :name "ogent-armory-agent"
             :buffer buffer
             :stderr stderr-buffer
             :command (cons program args)
             :connection-type 'pipe
             :sentinel
             (lambda (process event)
               (unless (process-live-p process)
                 (setq ogent-armory-runner--processes
                       (delq process ogent-armory-runner--processes))
                 (let* ((exit-status (process-exit-status process))
                        (output (ogent-armory-runner--buffer-output process))
                        (error-output
                         (when (buffer-live-p stderr-buffer)
                           (string-trim
                            (with-current-buffer stderr-buffer
                              (buffer-string)))))
                        (conversation-file
                         (progn
                           (plist-put plan
                                      :duration
                                      (format "%.2fs"
                                              (- (float-time) started-at)))
                           (ogent-armory-runner--finalize-conversation
                            plan output error-output exit-status))))
                   (process-put process 'ogent-armory-conversation-file
                                conversation-file)
                   (process-put process 'ogent-armory-conversation-id
                                (plist-get plan :conversation-id))
                   (when (buffer-live-p stderr-buffer)
                     (kill-buffer stderr-buffer))
                   (message "Armory agent finished: %s (%s)"
                            conversation-file
                            (string-trim event))))))))
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'ogent-armory-plan plan)
    (process-put proc 'ogent-armory-output-start output-start)
    (push proc ogent-armory-runner--processes)
    (when stdin
      (process-send-string proc stdin)
      (process-send-eof proc))
	    proc))

(defun ogent-armory-runner-stop-conversation (directory conversation-id)
  "Stop the live process for CONVERSATION-ID under DIRECTORY.
Return non-nil when a process was found."
  (let* ((root (file-truename (ogent-armory--directory directory)))
         (process
          (seq-find
           (lambda (candidate)
             (let ((plan (process-get candidate 'ogent-armory-plan)))
               (and (process-live-p candidate)
                    (equal (file-truename
                            (ogent-armory--directory (plist-get plan :root)))
                           root)
                    (equal (plist-get plan :conversation-id)
                           conversation-id))))
           ogent-armory-runner--processes)))
    (when process
      (let ((plan (process-get process 'ogent-armory-plan)))
        (plist-put plan :cancelled t)
        (process-put process 'ogent-armory-plan plan))
      (delete-process process)
      t)))

(defun ogent-armory-runner--read-agent (root)
  "Read an agent slug from ROOT."
  (completing-read "Agent: " (ogent-armory-list-agents root) nil t))

(defun ogent-armory-runner--read-job (root agent-slug)
  "Read a job id for AGENT-SLUG under ROOT."
  (completing-read
   "Job: "
   (mapcar (lambda (job) (plist-get job :id))
           (ogent-armory-list-jobs root agent-slug))
   nil t))

(defun ogent-armory-runner--confirm (plan)
  "Return non-nil when PLAN may start."
  (or (not ogent-armory-runner-confirm-before-run)
      (yes-or-no-p
       (format "Run %s agent %s in %s and send prompt text to the CLI provider? "
               (plist-get plan :provider)
               (plist-get (plist-get plan :agent) :slug)
               (abbreviate-file-name (plist-get plan :workspace))))))

;;;###autoload
(defun ogent-armory-run-agent (directory agent-slug instruction)
  "Run AGENT-SLUG under DIRECTORY with INSTRUCTION."
  (interactive
   (let* ((root (or (ogent-armory-find-root)
                    (read-directory-name "Armory root: ")))
          (agent (ogent-armory-runner--read-agent root)))
     (list root agent (read-string "Instruction: "))))
  (let ((plan (ogent-armory-runner-plan
               directory agent-slug :instruction instruction)))
    (when (ogent-armory-runner--confirm plan)
      (ogent-armory-runner-start plan))))

;;;###autoload
(defun ogent-armory-run-job (directory agent-slug job-id)
  "Run JOB-ID for AGENT-SLUG under DIRECTORY."
  (interactive
   (let* ((root (or (ogent-armory-find-root)
                    (read-directory-name "Armory root: ")))
          (agent (ogent-armory-runner--read-agent root))
          (job (ogent-armory-runner--read-job root agent)))
     (list root agent job)))
  (let ((plan (ogent-armory-runner-plan
               directory agent-slug :job-id job-id)))
    (when (ogent-armory-runner--confirm plan)
      (ogent-armory-runner-start plan))))

(defun ogent-armory-runner-auth-status (provider)
  "Return local subscription auth status for PROVIDER."
  (pcase (ogent-armory-runner-normalize-provider provider)
    ('codex
     (let* ((program ogent-armory-codex-executable)
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
     (let* ((program ogent-armory-claude-executable)
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

(provide 'ogent-armory-runner)

;;; ogent-armory-runner.el ends here
