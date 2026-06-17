;;; ogent-cabinet-runner.el --- Run Org cabinet agents via local CLIs -*- lexical-binding: t; -*-

;;; Commentary:
;; Runs Cabinet agents through locally authenticated coding CLIs.  The runner
;; plans commands from Org persona and job records, starts the process, and
;; stores the resulting transcript in the canonical Org conversation store.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'subr-x)
(require 'ogent-cabinet)
(require 'ogent-cabinet-adapter)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-settings)
(require 'ogent-issues-bd)

(declare-function ogent-cabinet-actions-parse "ogent-cabinet-actions" (text))
(declare-function ogent-cabinet-actions-validate "ogent-cabinet-actions")
(declare-function ogent-cabinet-actions-store "ogent-cabinet-actions"
                  (directory conversation-id actions))

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

(defcustom ogent-cabinet-gemini-executable "gemini"
  "Executable used for Gemini CLI agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-cursor-executable "cursor-agent"
  "Executable used for Cursor Agent CLI agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-opencode-executable "opencode"
  "Executable used for OpenCode agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-pi-executable "pi"
  "Executable used for Pi CLI agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-grok-executable "grok"
  "Executable used for Grok CLI agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-copilot-executable "copilot"
  "Executable used for GitHub Copilot CLI agents."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-confirm-before-run t
  "When non-nil, ask before starting a CLI agent from an interactive command."
  :type 'boolean
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-response-contract
  (string-join
   '("Cabinet response contract:"
     "Output grammar:"
     "- Return one Org subtree body that can be inserted below an existing level-one turn heading."
     "- Start visible sections at level ** or deeper. Never emit a single-star Org heading."
     "- Use Org markup and syntax, not Markdown # headings or [label](url) links."
     "- Use Org lists, TODO items, tables, links, and named src blocks where they improve navigation."
     "- Use #+begin_src and #+end_src for code or logs. Do not use Markdown triple-backtick fences."
     "- Use Org file links for durable artifacts, for example [[file:notes/plan.org][plan]]."
     "- Keep preambles out. Begin with the first useful Org heading or list item."
     "Common failures to avoid:"
     "- Do not emit raw JSON outside Cabinet protocol blocks."
     "- Do not put the answer in a Markdown code fence."
     "- Do not write naked file paths when an Org file link is clearer."
     "- Do not copy the example content below.")
   "\n")
  "Shared Cabinet response grammar appended to runner prompts."
  :type 'string
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-response-templates
  '((implementation .
                    "Implementation response shape:
** Changed
- ...
** Verification
- ...
** Notes
- ...")
    (review .
            "Review response shape:
** Findings
- ...
** Risks
- ...
** Tests
- ...")
    (research .
              "Research response shape:
** Answer
- ...
** Sources
- ...
** Open Questions
- ...")
    (planning .
              "Planning response shape:
** Decision
- ...
** Tradeoffs
- ...
** Milestones
- ...")
    (general .
             "General response shape:
** Summary
- ...
** Details
- ...
** Next Actions
- ..."))
  "Response shape templates keyed by Cabinet run type."
  :type '(alist :key-type symbol :value-type string)
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-codex-sandbox "workspace-write"
  "Sandbox mode passed to `codex exec'."
  :type '(choice (const "read-only")
                 (const "workspace-write")
                 (const "danger-full-access"))
  :group 'ogent-cabinet-runner)

(defcustom ogent-cabinet-runner-ensure-beads-redirect t
  "Ensure beads worktree redirects before starting agent runs.
When non-nil and a run's workspace lives inside a linked git
worktree, write the `.beads/redirect' pointer (see
`ogent-issues-bd-ensure-worktree-redirect') so the agent's br
commands operate on the main checkout's database instead of forking
a divergent per-worktree copy."
  :type 'boolean
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

(defcustom ogent-cabinet-runner-claude-permission-mode "dontAsk"
  "Permission mode passed to Claude Code background runs."
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
  (ogent-cabinet-adapter-normalize-provider provider))

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

(defun ogent-cabinet-runner--setting (settings key)
  "Return nonblank KEY from SETTINGS."
  (ogent-cabinet-runner--blank-to-nil (plist-get settings key)))

(defun ogent-cabinet-runner--runtime-symbol (value)
  "Return VALUE as a runtime mode symbol, or nil when VALUE is blank."
  (when-let ((text (ogent-cabinet-runner--blank-to-nil
                    (and value (format "%s" value)))))
    (intern text)))

(defun ogent-cabinet-runner--claude-permission-mode (agent)
  "Return the safe Claude Code permission mode for AGENT."
  (let ((mode (or (ogent-cabinet-runner--blank-to-nil
                   (plist-get agent :permission-mode))
                  (ogent-cabinet-runner--blank-to-nil
                   ogent-cabinet-runner-claude-permission-mode))))
    (if (or (null mode) (equal mode "default"))
        "dontAsk"
      mode)))

(defun ogent-cabinet-runner--format-context-value (label value)
  "Return a Cabinet run context line for LABEL and VALUE."
  (when-let ((text (ogent-cabinet-runner--blank-to-nil
                    (and value (format "%s" value)))))
    (format "- %s: %s" label text)))

(defun ogent-cabinet-runner--run-context-contract (context)
  "Return prompt text describing Cabinet runtime CONTEXT."
  (string-join
   (delq
    nil
    (list
     "Cabinet run context:"
     (ogent-cabinet-runner--format-context-value
      "Cabinet root" (plist-get context :root))
     (ogent-cabinet-runner--format-context-value
      "Workspace" (plist-get context :workspace))
     (ogent-cabinet-runner--format-context-value
      "Provider" (plist-get context :provider))
     (ogent-cabinet-runner--format-context-value
      "Model" (plist-get context :model))
     (ogent-cabinet-runner--format-context-value
      "Effort" (plist-get context :effort))
     (ogent-cabinet-runner--format-context-value
      "Runtime" (plist-get context :runtime-mode))))
   "\n"))

(defun ogent-cabinet-runner--response-kind (agent job instruction)
  "Return the response template kind for AGENT, JOB, and INSTRUCTION."
  (let* ((tags (append (plist-get agent :tags)
                       (and job (plist-get job :tags))))
         (text (downcase
                (string-join
                 (delq
                  nil
                  (append
                   (list (plist-get agent :role)
                         (plist-get agent :body)
                         (and job (plist-get job :id))
                         (and job (plist-get job :name))
                         (and job (plist-get job :body))
                         instruction)
                   tags))
                 " "))))
    (cond
     ((string-match-p
       "implement\\|build\\|fix\\|patch\\|refactor\\|ship\\|edit\\|code\\|change"
       text)
      'implementation)
     ((string-match-p
       "review\\|audit\\|critique\\|verify\\|validation\\|test\\|risk\\|qa"
       text)
      'review)
     ((string-match-p
       "research\\|investigate\\|source\\|study\\|compare\\|survey"
       text)
      'research)
     ((string-match-p
       "plan\\|design\\|spec\\|roadmap\\|milestone\\|tradeoff\\|decision"
       text)
      'planning)
     (t 'general))))

(defun ogent-cabinet-runner--response-template (agent job instruction)
  "Return the selected response template for AGENT, JOB, and INSTRUCTION."
  (or (cdr (assq (ogent-cabinet-runner--response-kind
                  agent job instruction)
                 ogent-cabinet-runner-response-templates))
      (cdr (assq 'general ogent-cabinet-runner-response-templates))))

(defun ogent-cabinet-runner--response-example ()
  "Return a compact good Cabinet response example."
  (string-join
   '("Example Cabinet response:"
     "** Summary"
     "- Shipped the focused change and kept the durable record readable."
     "** Findings"
     "- [[file:lisp/ogent-cabinet-runner.el][runner]] now emits a stricter Org response contract."
     "** Verification"
     "- =make test= passed for the touched Cabinet suites."
     "#+begin_cabinet"
     "SUMMARY: Tightened Cabinet output shape."
     "CONTEXT: Future runs should read cleanly in the conversation buffer."
     "ARTIFACT: lisp/ogent-cabinet-runner.el"
     "#+end_cabinet")
   "\n"))

(defun ogent-cabinet-runner--machine-footer-contract ()
  "Return the machine-readable Cabinet footer contract."
  (string-join
   '("Machine footer:"
     "- Put exactly one Cabinet metadata block at the very end of the response."
     "- The visible answer should stand alone without this footer."
     "- The metadata block may contain multiple ARTIFACT lines."
     "- Use ARTIFACT: none when no artifact exists."
     "#+begin_cabinet"
     "SUMMARY: one short sentence"
     "CONTEXT: optional durable memory note, or none"
     "ARTIFACT: relative/path/to/file.org"
     "#+end_cabinet")
   "\n"))

(defun ogent-cabinet-runner--action-contract (agent)
  "Return action proposal instructions for dispatch-capable AGENT."
  (when (plist-get agent :can-dispatch)
    (string-join
     '("Action proposal contract:"
       "- When clear follow-up work belongs to another agent, add an optional Cabinet actions block before the machine footer."
       "- Keep action prompts Org-ready and specific."
       "- Omit this block when there is no useful delegated work."
       "#+begin_cabinet-actions"
       "["
       "  {\"type\":\"launch-task\",\"target-agent\":\"agent-slug\",\"title\":\"Short title\",\"prompt\":\"Org-ready prompt\"}"
       "]"
       "#+end_cabinet-actions")
     "\n")))

(defun ogent-cabinet-runner--self-check-contract ()
  "Return the final response self-check."
  (string-join
   '("Before sending, verify:"
     "- The response can be inserted under a level-one Org turn heading without changing the tree shape."
     "- Visible sections begin at level ** or deeper."
     "- File references use Org links in the visible answer."
     "- The final block is one #+begin_cabinet metadata footer."
     "- Any <ask_user>...</ask_user> marker is present only when user input is mandatory.")
   "\n"))

(defun ogent-cabinet-runner--response-contract (agent job instruction context)
  "Return the Cabinet response contract for AGENT and JOB.
Use INSTRUCTION and CONTEXT to build the runner prompt."
  (string-join
   (delq
    nil
    (list
     (ogent-cabinet-runner--run-context-contract context)
     (ogent-cabinet-runner--blank-to-nil
      ogent-cabinet-runner-response-contract)
     (ogent-cabinet-runner--response-template agent job instruction)
     (ogent-cabinet-runner--response-example)
     (ogent-cabinet-runner--action-contract agent)
     (ogent-cabinet-runner--machine-footer-contract)
     (ogent-cabinet-runner--self-check-contract)))
   "\n\n"))

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

(defun ogent-cabinet-runner--conversation-id (&optional job-id)
  "Return a fresh canonical conversation id for optional JOB-ID."
  (format "%s-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%S")
          (or job-id "run")
          (random #x1000000)))

(defun ogent-cabinet-runner--prompt (agent &optional job instruction context)
  "Return a CLI prompt from AGENT, optional JOB, INSTRUCTION, and CONTEXT."
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
       (format "User instruction:\n%s" user-instruction))
     (ogent-cabinet-runner--response-contract
      agent job instruction context)))
   "\n\n"))

(cl-defun ogent-cabinet-runner-plan
    (directory agent-slug
               &key job-id instruction conversation-id conversation-title
               turn-content trigger last-resume-result runtime-mode mentions
               skills pending-attachment-id attachment-paths provider model
               effort adapter-id parent-task triggering-agent spawn-depth
               scheduled-at scheduled-key)
  "Return a process plan for AGENT-SLUG under DIRECTORY.
JOB-ID selects a recurring job.  INSTRUCTION supplies an ad hoc prompt."
  (let* ((candidate (ogent-cabinet--directory directory))
         (root (file-truename
                (ogent-cabinet--directory
                 (or (ogent-cabinet-find-root candidate)
                     candidate))))
         (agent (ogent-cabinet-resolve-agent
                 root agent-slug :include-visible t))
         (settings (ogent-cabinet-settings-read root))
         (job (when job-id
                (ogent-cabinet-validate-job
                 (ogent-cabinet-read-job root agent-slug job-id))))
         (adapter (if adapter-id
                      (ogent-cabinet-adapter-require adapter-id)
                    (ogent-cabinet-adapter-resolve-provider
                     (or (ogent-cabinet-runner--blank-to-nil provider)
                         (ogent-cabinet-runner--effective agent job :adapter)
                         (ogent-cabinet-runner--effective agent job :provider)
                         (ogent-cabinet-runner--setting
                          settings :default-provider)
                         (ogent-cabinet-runner--blank-to-nil
                          (plist-get agent :provider))))))
         (provider-symbol (plist-get adapter :provider-symbol))
         (workspace (ogent-cabinet-runner--workspace
                     root
                     (if (and job (plist-get job :workspace))
                         (plist-put (copy-sequence agent)
                                    :workspace
                                    (plist-get job :workspace))
                       agent)))
         (model (or (ogent-cabinet-runner--blank-to-nil model)
                    (ogent-cabinet-runner--effective agent job :model)
                    (ogent-cabinet-runner--setting
                     settings :default-model)))
         (effort (or (ogent-cabinet-runner--blank-to-nil effort)
                     (ogent-cabinet-runner--effective agent job :effort)
                     (ogent-cabinet-runner--setting
                      settings :default-effort)))
         (permission-mode (ogent-cabinet-runner--claude-permission-mode
                           agent))
         (runtime-mode (or (ogent-cabinet-runner--runtime-symbol
                            runtime-mode)
                           (ogent-cabinet-runner--runtime-symbol
                            (ogent-cabinet-runner--effective
                             agent job :runtime-mode))
                           (ogent-cabinet-runner--runtime-symbol
                            (ogent-cabinet-runner--setting
                             settings :default-runtime))
                           'native))
         (prompt (ogent-cabinet-runner--prompt
                  agent
                  job
                  instruction
                  (list :root root
                        :workspace workspace
                        :provider provider-symbol
                        :model model
                        :effort effort
                        :runtime-mode runtime-mode)))
         (conversation-id (or conversation-id
                              (ogent-cabinet-runner--conversation-id job-id)))
         (invocation
          (ogent-cabinet-adapter-build-invocation
           adapter
           (list :root root
                 :workspace workspace
                 :agent agent
                 :job job
                 :prompt prompt
                 :model model
                 :effort effort
                 :permission-mode permission-mode
                 :runtime-mode runtime-mode))))
    (unless (file-directory-p workspace)
      (user-error "Cabinet agent workspace not found: %s" workspace))
    (append
     (list :provider provider-symbol
           :adapter adapter
           :adapter-id (plist-get adapter :id)
           :program (plist-get invocation :program)
           :args (plist-get invocation :args)
           :prompt prompt
           :stdin (plist-get invocation :stdin)
           :root root
           :workspace workspace
           :agent agent
           :job job
           :conversation-id conversation-id
           :conversation-title conversation-title
           :turn-content turn-content
           :trigger trigger
           :model model
           :effort effort
           :runtime-mode (plist-get invocation :runtime-mode)
           :mentions mentions
           :skills skills
           :skill-mounts (ogent-cabinet-adapter-skill-mounts adapter skills)
           :pending-attachment-id pending-attachment-id
           :attachment-paths attachment-paths
           :parent-task parent-task
           :triggering-agent triggering-agent
           :spawn-depth spawn-depth
           :scheduled-at scheduled-at
           :scheduled-key scheduled-key
           :last-resume-result last-resume-result))))

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
        ("OGENT_MODEL" . ,(or (plist-get plan :model) ""))
        ("OGENT_EFFORT" . ,(or (plist-get plan :effort) ""))
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

(defun ogent-cabinet-runner--conversation-title (plan)
  "Return a user-facing conversation title for PLAN."
  (or (plist-get plan :conversation-title)
      (let ((agent (plist-get plan :agent))
            (job (plist-get plan :job)))
        (format "%s %s"
                (or (plist-get agent :name) (plist-get agent :slug))
                (or (plist-get job :name) "Run")))))

(defun ogent-cabinet-runner--iso-now ()
  "Return the current time as an ISO-like local timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun ogent-cabinet-runner--create-conversation (plan started)
  "Prepare the running canonical conversation for PLAN at STARTED."
  (let* ((root (plist-get plan :root))
         (agent (plist-get plan :agent))
         (job (plist-get plan :job))
         (conversation-id (plist-get plan :conversation-id))
         (file (ogent-cabinet-conversation-file root conversation-id))
         (existing (file-exists-p file))
         (attachments (if-let ((pending-id
                                (plist-get plan :pending-attachment-id)))
                          (ogent-cabinet-conversation-finalize-attachments
                           root pending-id conversation-id)
                        (plist-get plan :attachment-paths)))
         (trigger (or (plist-get plan :trigger)
                      (if job "job" "manual"))))
    (plist-put plan :attachment-paths attachments)
    (if existing
        (ogent-cabinet-conversation-update-properties
         root conversation-id
         `(("OGENT_STATUS" . "running")
           ("OGENT_LAST_ACTIVITY_AT" . ,started)
           ("OGENT_STARTED_AT" . ,started)
           ("OGENT_COMPLETED_AT" . "")
           ("OGENT_EXIT_CODE" . "")
           ("OGENT_DURATION" . "")
           ("OGENT_TRIGGER" . ,trigger)
           ("OGENT_ADAPTER" . ,(plist-get plan :adapter-id))
           ("OGENT_RUNTIME_MODE" .
            ,(symbol-name (or (plist-get plan :runtime-mode) 'native)))
           ("OGENT_MODEL" . ,(plist-get plan :model))
           ("OGENT_EFFORT" . ,(plist-get plan :effort))
           ("OGENT_MENTIONS" . ,(plist-get plan :mentions))
           ("OGENT_SKILLS" . ,(plist-get plan :skills))
           ("OGENT_ATTACHMENTS" . ,attachments)
           ("OGENT_SCHEDULED_AT" . ,(plist-get plan :scheduled-at))
           ("OGENT_SCHEDULED_KEY" . ,(plist-get plan :scheduled-key))
           ("OGENT_PARENT_TASK" . ,(plist-get plan :parent-task))
           ("OGENT_TRIGGERING_AGENT" . ,(plist-get plan :triggering-agent))
           ("OGENT_SPAWN_DEPTH" . ,(plist-get plan :spawn-depth))
           ("OGENT_LAST_RESUME_RESULT" .
            ,(plist-get plan :last-resume-result))))
      (setq file
            (ogent-cabinet-conversation-create
             root
             (list
              :id conversation-id
              :agent (plist-get agent :slug)
              :title (ogent-cabinet-runner--conversation-title plan)
              :trigger trigger
              :status "running"
              :started started
              :last-activity started
              :provider (plist-get plan :provider)
              :adapter (plist-get plan :adapter-id)
              :model (plist-get plan :model)
              :effort (plist-get plan :effort)
              :job-id (plist-get job :id)
              :job-name (plist-get job :name)
              :scheduled-at (plist-get plan :scheduled-at)
              :scheduled-key (plist-get plan :scheduled-key)
              :mentioned-paths (plist-get plan :mentions)
              :skills (plist-get plan :skills)
              :attachment-paths attachments
              :parent-task (plist-get plan :parent-task)
              :triggering-agent (plist-get plan :triggering-agent)
              :spawn-depth (plist-get plan :spawn-depth)
              :runtime-mode (symbol-name
                             (or (plist-get plan :runtime-mode) 'native))))))
    (ogent-cabinet-conversation-append-turn
     root conversation-id "user"
     (or (plist-get plan :turn-content)
         (plist-get plan :prompt))
     :ts started
     :mentioned-paths (plist-get plan :mentions)
     :attachment-paths attachments
     :skills (plist-get plan :skills))
    (ogent-cabinet-conversation-append-event
     root conversation-id
     (if existing "conversation.continued" "task.started")
     :ts started
     :payload (format "trigger=%s" trigger))
    file))

(defun ogent-cabinet-runner--final-status (plan exit-status parsed)
  "Return canonical final status for PLAN, EXIT-STATUS, and PARSED metadata."
  (cond
   ((plist-get plan :cancelled) "cancelled")
   ((not (zerop exit-status)) "failed")
   ((plist-get parsed :awaiting-input) "awaiting-input")
   (t "done")))

(defun ogent-cabinet-runner--finalize-conversation
    (plan output error-output exit-status)
  "Finalize PLAN conversation with OUTPUT, ERROR-OUTPUT, and EXIT-STATUS."
  (let* ((root (plist-get plan :root))
         (conversation-id (plist-get plan :conversation-id))
         (finished (ogent-cabinet-runner--iso-now))
         (parsed (ogent-cabinet-conversation-parse-output output))
         (app-paths (ogent-cabinet-runner--app-paths-from-output
                     root output error-output))
         (artifact-paths (delete-dups
                          (append (copy-sequence
                                   (plist-get parsed :artifact-paths))
                                  app-paths)))
         (status (ogent-cabinet-runner--final-status plan exit-status parsed))
         (error-info (unless (zerop exit-status)
                       (ogent-cabinet-adapter-classify-error
                        (plist-get plan :adapter)
                        error-output
                        exit-status))))
    (ogent-cabinet-conversation-append-turn
     root conversation-id "agent" output
     :ts finished
     :exit-code exit-status
     :error (unless (zerop exit-status) error-output)
     :awaiting-input (plist-get parsed :awaiting-input)
     :artifacts artifact-paths)
    (ogent-cabinet-conversation-update-properties
     root conversation-id
     `(("OGENT_STATUS" . ,status)
       ("OGENT_COMPLETED_AT" . ,finished)
       ("OGENT_LAST_ACTIVITY_AT" . ,finished)
       ("OGENT_EXIT_CODE" . ,exit-status)
       ("OGENT_DURATION" . ,(or (plist-get plan :duration) ""))
       ("OGENT_ARTIFACTS" . ,artifact-paths)
       ("OGENT_SUMMARY" . ,(plist-get parsed :summary))
       ("OGENT_CONTEXT_SUMMARY" . ,(plist-get parsed :context-summary))
       ("OGENT_AWAITING_INPUT" . ,(plist-get parsed :awaiting-input))
       ("OGENT_ERROR_KIND" . ,(plist-get error-info :kind))
       ("OGENT_ERROR_HINT" . ,(plist-get error-info :message))))
    (ogent-cabinet-conversation-append-event
     root conversation-id "task.updated"
     :ts finished
     :payload (format "status=%s" status))
    (ogent-cabinet-conversation-file root conversation-id)))

(defun ogent-cabinet-runner--capture-actions (plan output exit-status)
  "Parse lead action proposals from OUTPUT for PLAN.
Store proposals as pending actions.  Run only for lead agents on zero
EXIT-STATUS.  Return stored actions or nil."
  (condition-case err
      (when (and (eq exit-status 0)
                 (ogent-cabinet-agent-lead-p (plist-get plan :agent)))
        (require 'ogent-cabinet-actions)
        (when-let ((actions (ogent-cabinet-actions-parse output)))
          (let ((validated (ogent-cabinet-actions-validate
                            (plist-get plan :root)
                            actions
                            :triggering-agent
                            (plist-get (plist-get plan :agent) :slug))))
            (ogent-cabinet-actions-store
             (plist-get plan :root)
             (plist-get plan :conversation-id)
             validated)
            (message "ogent: %d lead action(s) pending approval — M-x ogent-cabinet-actions"
                     (length validated))
            validated)))
    (error
     (message "ogent: failed to capture lead action proposals: %s"
              (error-message-string err))
     nil)))

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
         (started (ogent-cabinet-runner--iso-now))
         proc)
    (unless (executable-find program)
      (user-error "Cabinet runner executable not found: %s" program))
    (when ogent-cabinet-runner-ensure-beads-redirect
      (ogent-issues-bd-ensure-worktree-redirect workspace))
    (let ((conversation-file
           (ogent-cabinet-runner--create-conversation plan started)))
      (plist-put plan :conversation-file conversation-file))
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
                        (conversation-file
                         (progn
                           (plist-put plan
                                      :duration
                                      (format "%.2fs"
                                              (- (float-time) started-at)))
                           (ogent-cabinet-runner--finalize-conversation
                            plan output error-output exit-status))))
                   (ogent-cabinet-runner--capture-actions
                    plan output exit-status)
                   (process-put process 'ogent-cabinet-conversation-file
                                conversation-file)
                   (process-put process 'ogent-cabinet-conversation-id
                                (plist-get plan :conversation-id))
                   (when (buffer-live-p stderr-buffer)
                     (kill-buffer stderr-buffer))
                   (message "Cabinet agent finished: %s (%s)"
                            conversation-file
                            (string-trim event))))))))
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'ogent-cabinet-plan plan)
    (process-put proc 'ogent-cabinet-output-start output-start)
    (process-put proc 'ogent-cabinet-conversation-id
                 (plist-get plan :conversation-id))
    (process-put proc 'ogent-cabinet-conversation-file
                 (plist-get plan :conversation-file))
    (push proc ogent-cabinet-runner--processes)
    (when stdin
      (process-send-string proc stdin)
      (process-send-eof proc))
    proc))

(defun ogent-cabinet-runner-display-process (process)
  "Display PROCESS output buffer and return PROCESS."
  (when (and (processp process)
             (buffer-live-p (process-buffer process)))
    (pop-to-buffer (process-buffer process))
    (goto-char (point-max))
    (message "Cabinet agent started: %s"
             (or (process-get process 'ogent-cabinet-conversation-id)
                 (process-name process))))
  process)

(defun ogent-cabinet-runner-stop-conversation (directory conversation-id)
  "Stop the live process for CONVERSATION-ID under DIRECTORY.
Return non-nil when a process was found."
  (let* ((root (file-truename (ogent-cabinet--directory directory)))
         (process
          (seq-find
           (lambda (candidate)
             (let ((plan (process-get candidate 'ogent-cabinet-plan)))
               (and (process-live-p candidate)
                    (equal (file-truename
                            (ogent-cabinet--directory (plist-get plan :root)))
                           root)
                    (equal (plist-get plan :conversation-id)
                           conversation-id))))
           ogent-cabinet-runner--processes)))
    (when process
      (let ((plan (process-get process 'ogent-cabinet-plan)))
        (plist-put plan :cancelled t)
        (process-put process 'ogent-cabinet-plan plan))
      (delete-process process)
      t)))

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
      (let ((process (ogent-cabinet-runner-start plan)))
        (when (called-interactively-p 'interactive)
          (ogent-cabinet-runner-display-process process))
        process))))

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
      (let ((process (ogent-cabinet-runner-start plan)))
        (when (called-interactively-p 'interactive)
          (ogent-cabinet-runner-display-process process))
        process))))

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
