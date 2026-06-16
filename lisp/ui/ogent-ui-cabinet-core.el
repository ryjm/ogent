;;; ogent-ui-cabinet-core.el --- Core helpers for Org Cabinet UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared customization, faces, buffer-local state, helpers, and section macros
;; for the Cabinet UI surfaces.  Required by `ogent-ui-cabinet' and every
;; `ogent-ui-cabinet-*' view module.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'ogent-cabinet)
(require 'ogent-cabinet-adapter)
(require 'ogent-cabinet-evil)
(require 'ogent-cabinet-conversations)
(require 'ogent-cabinet-data)
(require 'ogent-cabinet-settings)
(require 'ogent-cabinet-runner)

(eval-and-compile
  (defvar ogent-cabinet-ui--magit-section-available
    (require 'magit-section nil t)
    "Non-nil when `magit-section' is available for Cabinet UI buffers.")
  (when ogent-cabinet-ui--magit-section-available
    (require 'magit-section)))

(autoload 'ogent-cabinet-status "ogent-cabinet-status" nil t)
(autoload 'ogent-cabinet-actions "ogent-cabinet-actions" nil t)
(autoload 'ogent-cabinet-schedule "ogent-cabinet-schedule" nil t)
(autoload 'ogent-cabinet-agenda "ogent-cabinet-schedule" nil t)
(autoload 'ogent-cabinet-git-status "ogent-cabinet-git" nil t)
(autoload 'ogent-cabinet-command-palette "ogent-cabinet-palette" nil t)

(declare-function magit-current-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-insert-section--create "ext:magit-section")
(declare-function magit-insert-section--finish "ext:magit-section")
(declare-function magit-section-backward-sibling "ext:magit-section")
(declare-function magit-section-cycle-global "ext:magit-section")
(declare-function magit-section-forward-sibling "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-section-up "ext:magit-section")
(defvar magit-section-mode-map)
(defvar magit-section-visibility-indicator)
(defvar magit-insert-section--current)
(defvar magit-insert-section--oldroot)
(defvar magit-insert-section--parent)
(defvar magit-root-section)

(declare-function ogent-cabinet-home-refresh "ogent-ui-cabinet-home")

(defgroup ogent-ui-cabinet nil
  "Richer UI surfaces for Org Cabinet records."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-")

(defcustom ogent-cabinet-agents-buffer-name-format "*ogent-cabinet-agents: %s*"
  "Format string used for Cabinet agent list buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-home-buffer-name-format "*ogent-cabinet-home: %s*"
  "Format string used for Cabinet Home buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-agent-buffer-name-format "*ogent-cabinet-agent: %s*"
  "Format string used for single Cabinet agent buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-jobs-buffer-name-format "*ogent-cabinet-jobs: %s*"
  "Format string used for Cabinet job buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-conversations-buffer-name-format
  "*ogent-cabinet-conversations: %s*"
  "Format string used for Cabinet conversation buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-conversation-buffer-name-format
  "*ogent-cabinet-conversation: %s*"
  "Format string used for a single Cabinet conversation buffer."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-conversation-runtime-trace-preview-lines 12
  "Maximum runtime trace lines shown in conversation reader buffers."
  :type 'integer
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-tasks-buffer-name-format "*ogent-cabinet-tasks: %s*"
  "Format string used for Cabinet task lane buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-search-buffer-name-format "*ogent-cabinet-search: %s*"
  "Format string used for Cabinet search buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-apps-buffer-name-format "*ogent-cabinet-apps: %s*"
  "Format string used for Cabinet app artifact buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-stale-days 7
  "Days after which scheduled Cabinet jobs count as stale."
  :type 'integer
  :group 'ogent-ui-cabinet)

(defface ogent-cabinet-ui-heading
  '((t :weight bold))
  "Face for Cabinet UI section headings."
  :group 'ogent-ui-cabinet)

(defface ogent-cabinet-ui-dim
  '((t :inherit shadow))
  "Face for secondary Cabinet UI text."
  :group 'ogent-ui-cabinet)

(defface ogent-cabinet-ui-good
  '((t :inherit success))
  "Face for healthy Cabinet UI state."
  :group 'ogent-ui-cabinet)

(defface ogent-cabinet-ui-warning
  '((t :inherit warning))
  "Face for Cabinet UI state requiring attention."
  :group 'ogent-ui-cabinet)

(defconst ogent-cabinet-agent-editable-properties
  '("OGENT_DISPLAY_NAME"
    "OGENT_ICON"
    "OGENT_COLOR"
    "OGENT_AVATAR"
    "OGENT_ROLE"
    "OGENT_DEPARTMENT"
    "OGENT_TYPE"
    "OGENT_CAN_DISPATCH"
    "OGENT_PROVIDER"
    "OGENT_ADAPTER"
    "OGENT_ADAPTER_CONFIG"
    "OGENT_MODEL"
    "OGENT_EFFORT"
    "OGENT_RUNTIME_MODE"
    "OGENT_PERMISSION_MODE"
    "OGENT_BUDGET"
    "OGENT_FOCUS"
    "OGENT_GOALS"
    "OGENT_CHANNELS"
    "OGENT_SKILLS"
    "OGENT_RECOMMENDED_SKILLS"
    "OGENT_SETUP_COMPLETE"
    "OGENT_HEARTBEAT"
    "OGENT_LAST_HEARTBEAT"
    "OGENT_NEXT_HEARTBEAT"
    "OGENT_ACTIVE"
    "OGENT_WORKSPACE"
    "OGENT_TAGS")
  "Agent identity properties editable from the profile buffer.")

(defconst ogent-cabinet-job-editable-properties
  '("OGENT_JOB_ID"
    "OGENT_AGENT"
    "OGENT_CRON"
    "OGENT_HEARTBEAT"
    "OGENT_ENABLED"
    "OGENT_ADAPTER"
    "OGENT_ADAPTER_CONFIG"
    "OGENT_PROVIDER"
    "OGENT_MODEL"
    "OGENT_EFFORT"
    "OGENT_RUNTIME_MODE"
    "OGENT_WORKSPACE"
    "OGENT_TIMEOUT"
    "OGENT_ON_COMPLETE"
    "OGENT_ON_FAILURE"
    "OGENT_CABINET_PATH"
    "OGENT_CREATED_AT"
    "OGENT_UPDATED_AT"
    "OGENT_RUN_AFTER"
    "OGENT_OWNER_TASK"
    "OGENT_ONE_SHOT_STATE"
    "OGENT_LAST_RUN"
    "OGENT_NEXT_RUN"
    "OGENT_TAGS"
    "OGENT_ARCHIVED")
  "Job properties editable from Cabinet job buffers.")

(defconst ogent-cabinet-job-property-keys
  '(("OGENT_JOB_ID" . :id)
    ("OGENT_AGENT" . :agent)
    ("OGENT_CRON" . :cron)
    ("OGENT_HEARTBEAT" . :heartbeat)
    ("OGENT_ENABLED" . :enabled-raw)
    ("OGENT_ADAPTER" . :adapter)
    ("OGENT_ADAPTER_CONFIG" . :adapter-config)
    ("OGENT_PROVIDER" . :provider)
    ("OGENT_MODEL" . :model)
    ("OGENT_EFFORT" . :effort)
    ("OGENT_RUNTIME_MODE" . :runtime-mode)
    ("OGENT_WORKSPACE" . :workspace)
    ("OGENT_TIMEOUT" . :timeout)
    ("OGENT_ON_COMPLETE" . :on-complete)
    ("OGENT_ON_FAILURE" . :on-failure)
    ("OGENT_CABINET_PATH" . :cabinet-path)
    ("OGENT_CREATED_AT" . :created-at)
    ("OGENT_UPDATED_AT" . :updated-at)
    ("OGENT_RUN_AFTER" . :run-after)
    ("OGENT_OWNER_TASK" . :owner-task)
    ("OGENT_ONE_SHOT_STATE" . :one-shot-state)
    ("OGENT_LAST_RUN" . :last-run)
    ("OGENT_NEXT_RUN" . :next-run)
    ("OGENT_TAGS" . :tags)
    ("OGENT_ARCHIVED" . :archived-raw))
  "Map job Org property names to plist keys.")

(defconst ogent-cabinet-task-lanes
  '("Inbox" "Needs Reply" "Running" "Just Finished" "Archive")
  "Attention lanes displayed by `ogent-cabinet-tasks'.")

(defvar-local ogent-cabinet-home--root nil
  "Cabinet root for the current home buffer.")

(defvar-local ogent-cabinet-agents--root nil
  "Cabinet root for the current agents buffer.")

(defvar-local ogent-cabinet-org-chart--root nil
  "Cabinet root for the current org chart buffer.")

(defvar-local ogent-cabinet-agent--root nil
  "Cabinet root for the current single-agent buffer.")

(defvar-local ogent-cabinet-agent--slug nil
  "Agent slug for the current single-agent buffer.")

(defvar-local ogent-cabinet-jobs--root nil
  "Cabinet root for the current jobs buffer.")

(defvar-local ogent-cabinet-jobs--agent nil
  "Optional agent filter for the current jobs buffer.")

(defvar-local ogent-cabinet-conversations--root nil
  "Cabinet root for the current conversations buffer.")

(defvar-local ogent-cabinet-conversations--filters nil
  "Filters for the current conversations buffer.")

(defvar-local ogent-cabinet-conversation--root nil
  "Cabinet root for the current conversation detail buffer.")

(defvar-local ogent-cabinet-conversation--file nil
  "Conversation file for the current detail buffer.")

(defvar-local ogent-cabinet-tasks--root nil
  "Cabinet root for the current task buffer.")

(defvar-local ogent-cabinet-tasks--filters nil
  "Filters for the current task buffer.")

(defvar-local ogent-cabinet-tasks--view 'board
  "Current task view: `board', `list', or `schedule'.")

(defvar-local ogent-cabinet-search--root nil
  "Cabinet root for the current search buffer.")

(defvar-local ogent-cabinet-search--query nil
  "Search query for the current search buffer.")

(defvar-local ogent-cabinet-search--filters nil
  "Search filters for the current search buffer.")

(defvar-local ogent-cabinet-apps--root nil
  "Cabinet root for the current apps buffer.")

(defun ogent-cabinet-ui--root (&optional directory)
  "Return the Cabinet root for DIRECTORY or the current context."
  (let* ((candidate (ogent-cabinet--directory
                     (or directory default-directory)))
         (root (or (ogent-cabinet-find-root candidate)
                   candidate)))
    (directory-file-name (file-truename root))))

(defun ogent-cabinet-ui--root-label (root)
  "Return a compact label for ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun ogent-cabinet-ui--buffer-name (format-string root &optional suffix)
  "Return a Cabinet UI buffer name for FORMAT-STRING, ROOT, and SUFFIX."
  (format format-string
          (if suffix
              (format "%s/%s" (ogent-cabinet-ui--root-label root) suffix)
            (ogent-cabinet-ui--root-label root))))

(defun ogent-cabinet-ui--agent-slugs (root)
  "Return agent slugs under ROOT."
  (or (ogent-cabinet-list-visible-agents root :include-visible t) nil))

(defun ogent-cabinet-ui--read-agent (root)
  "Read an agent slug from ROOT."
  (completing-read "Agent: " (ogent-cabinet-ui--agent-slugs root) nil t))

(defun ogent-cabinet-ui--read-agent-default (root &optional default)
  "Read an agent slug from ROOT, using DEFAULT when provided."
  (let ((agents (ogent-cabinet-ui--agent-slugs root)))
    (cond
     ((null agents)
      (user-error "No Cabinet agents exist"))
     ((and (= (length agents) 1)
           (or (null default)
               (equal default (car agents))))
      (car agents))
     ((ogent-cabinet--blank-to-nil default)
      (completing-read
       (format "Agent (default %s): " default)
       agents nil t nil nil default))
     (t
      (completing-read "Agent: " agents nil t)))))

(defun ogent-cabinet-ui--agent-jobs (root slug)
  "Return jobs for SLUG under ROOT."
  (if (file-exists-p (ogent-cabinet-agent-file root slug))
      (or (ogent-cabinet-list-jobs root slug) nil)
    nil))

(defun ogent-cabinet-ui--agent-sessions (root slug)
  "Return sessions for SLUG under ROOT."
  (or (ogent-cabinet-ui--all-sessions root slug) nil))

(defun ogent-cabinet-ui--all-sessions (root &optional agent)
  "Return canonical conversations and legacy sessions under ROOT.
When AGENT is non-nil, narrow to that agent."
  (seq-sort
   (lambda (left right)
     (string> (or (plist-get left :finished) "")
              (or (plist-get right :finished) "")))
   (append
    (ogent-cabinet-conversation-list-sessions root :agent agent)
    (ogent-cabinet-list-sessions root agent))))

(defun ogent-cabinet-ui--all-jobs (root &optional agent)
  "Return all Cabinet jobs under ROOT, optionally narrowed to AGENT."
  (let (jobs)
    (dolist (slug (if agent (list agent) (ogent-cabinet-ui--agent-slugs root)))
      (setq jobs (append jobs (ogent-cabinet-ui--agent-jobs root slug))))
    jobs))

(defun ogent-cabinet-ui--last-session (sessions)
  "Return the most recent session from SESSIONS."
  (car (seq-sort
        (lambda (left right)
          (string> (or (plist-get left :finished) "")
                   (or (plist-get right :finished) "")))
        (copy-sequence sessions))))

(defun ogent-cabinet-ui--stale-job-p (root job)
  "Return non-nil when JOB under ROOT has no recent successful session."
  (let* ((agent (plist-get job :agent))
         (job-id (plist-get job :id))
         (sessions (seq-filter
                    (lambda (session)
                      (and (equal (plist-get session :agent) agent)
                           (equal (plist-get session :job-id) job-id)
                           (zerop (or (plist-get session :exit-status) 0))))
                    (ogent-cabinet-ui--all-sessions root agent)))
         (last (ogent-cabinet-ui--last-session sessions))
         (finished (plist-get last :finished)))
    (and (plist-get job :enabled)
         (not (plist-get job :archived))
         finished
         (> (float-time
             (time-subtract
              (current-time)
              (date-to-time finished)))
            (* ogent-cabinet-stale-days 24 60 60)))))

(defun ogent-cabinet-ui--format-tags (tags)
  "Return TAGS as comma-separated text."
  (string-join (or tags nil) ", "))

(defun ogent-cabinet-ui--file-line (file line)
  "Visit FILE and move to LINE."
  (find-file file)
  (goto-char (point-min))
  (forward-line (max 0 (1- (or line 1)))))

(defun ogent-cabinet-ui--visit-path (path)
  "Visit PATH or signal a user error."
  (unless (and path (file-exists-p path))
    (user-error "No Cabinet file at point"))
  (find-file path))

(defun ogent-cabinet-ui--canonical-conversation-path-p (path)
  "Return non-nil when PATH is a canonical conversation index."
  (and path
       (file-readable-p path)
       (string-equal (file-name-nondirectory path) "index.org")
       (string-match-p "/\\.agents/\\.conversations/[^/]+/index\\.org\\'"
                       path)
       (with-temp-buffer
         (insert-file-contents path nil 0 4096)
         (goto-char (point-min))
         (re-search-forward
          "^[ \t]*:OGENT_CONVERSATION:[ \t]+t[ \t]*$"
          nil t))))

(defun ogent-cabinet-ui--turns-by-role (turns role)
  "Return content strings from TURNS matching ROLE."
  (delq
   nil
   (mapcar
    (lambda (turn)
      (when (equal (plist-get turn :role) role)
        (plist-get turn :content)))
    turns)))

(defun ogent-cabinet-ui--canonical-conversation-detail (root path)
  "Return a detail plist for canonical conversation PATH under ROOT."
  (let* ((id (file-name-nondirectory
              (directory-file-name (file-name-directory path))))
         (detail (ogent-cabinet-conversation-detail root id))
         (turns (plist-get detail :turns))
         (agent-turns (seq-filter
                       (lambda (turn)
                         (equal (plist-get turn :role) "agent"))
                       turns))
         (last-agent (car (last agent-turns))))
    (append
     (list :name (plist-get detail :title)
           :status (ogent-cabinet-conversations--session-status
                    (plist-get detail :status))
           :finished (or (plist-get detail :completed)
                         (plist-get detail :last-activity)
                         (plist-get detail :started))
           :exit-status (plist-get detail :exit-code)
           :prompt (string-join
                    (ogent-cabinet-ui--turns-by-role turns "user")
                    "\n\n---\n\n")
           :output (string-join
                    (ogent-cabinet-ui--turns-by-role turns "agent")
                    "\n\n---\n\n")
           :error (plist-get last-agent :error)
           :runtime-trace nil
           :tools nil)
     detail)))

(defun ogent-cabinet-ui--conversation-detail (root path)
  "Return detail metadata for conversation PATH under ROOT."
  (if (ogent-cabinet-ui--canonical-conversation-path-p path)
      (ogent-cabinet-ui--canonical-conversation-detail root path)
    (ogent-cabinet-session-detail path)))

(defun ogent-cabinet-ui--canonical-conversation-id (path)
  "Return the canonical conversation id from PATH."
  (file-name-nondirectory
   (directory-file-name (file-name-directory path))))

(defun ogent-cabinet-ui--iso-now ()
  "Return the current time as a UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun ogent-cabinet-ui--conversation-append-event
    (root path type &optional payload)
  "Append TYPE event with PAYLOAD for canonical conversation PATH."
  (when (ogent-cabinet-ui--canonical-conversation-path-p path)
    (ogent-cabinet-conversation-append-event
     root
     (ogent-cabinet-ui--canonical-conversation-id path)
     type
     :ts (ogent-cabinet-ui--iso-now)
     :payload payload)))

(defun ogent-cabinet-ui--conversation-update-properties
    (root path properties &optional event payload)
  "Update conversation PATH with Org PROPERTIES.
When EVENT is non-nil, append it to the canonical event log."
  (if (ogent-cabinet-ui--canonical-conversation-path-p path)
      (let ((id (ogent-cabinet-ui--canonical-conversation-id path)))
        (ogent-cabinet-conversation-update-properties root id properties)
        (when event
          (ogent-cabinet-conversation-append-event
           root id event
           :ts (ogent-cabinet-ui--iso-now)
           :payload payload)))
    (dolist (property properties)
      (ogent-cabinet-update-session-property path (car property) (cdr property)))))

(defun ogent-cabinet-ui--conversation-artifacts (detail)
  "Return artifact paths declared by DETAIL and its turns."
  (delete-dups
   (delq
    nil
    (append
     (copy-sequence (plist-get detail :artifact-paths))
     (copy-sequence (plist-get detail :app-paths))
     (apply
      #'append
      (mapcar (lambda (turn)
                (copy-sequence (plist-get turn :artifacts)))
              (plist-get detail :turns)))))))

(defun ogent-cabinet-ui--artifact-path (root artifact)
  "Return ARTIFACT expanded under ROOT when needed."
  (when artifact
    (if (file-name-absolute-p artifact)
        artifact
      (expand-file-name artifact root))))

(defun ogent-cabinet-ui--put-property (file property value)
  "Set PROPERTY to VALUE in the first Org heading of FILE."
  (ogent-cabinet--update-first-heading-property file property value))

(defun ogent-cabinet-ui--job-with-property (job property value)
  "Return JOB copied with Org PROPERTY set to VALUE."
  (let* ((copy (copy-sequence job))
         (key (cdr (assoc property ogent-cabinet-job-property-keys))))
    (unless key
      (user-error "Unsupported Cabinet job property: %s" property))
    (pcase property
      ("OGENT_TAGS"
       (plist-put copy key (ogent-cabinet--tags-from-string value)))
      ("OGENT_ENABLED"
       (plist-put copy :enabled-raw value)
       (plist-put copy :enabled (ogent-cabinet--truth-value value)))
      ("OGENT_ARCHIVED"
       (plist-put copy :archived-raw value)
       (plist-put copy :archived (ogent-cabinet--truth-value value)))
      (_
       (plist-put copy key value)))
    copy))

(defun ogent-cabinet-ui--visit-body (file)
  "Visit FILE and move point to the first body line."
  (find-file file)
  (org-mode)
  (goto-char (point-min))
  (unless (re-search-forward org-heading-regexp nil t)
    (user-error "No Org heading found in %s" file))
  (org-back-to-heading t)
  (org-end-of-meta-data t)
  (skip-chars-forward " \t\n"))

(defun ogent-cabinet-ui--read-string-default (prompt default)
  "Read string for PROMPT with DEFAULT shown as an Emacs default value."
  (let ((shown-prompt
         (if (and default (not (string-empty-p default)))
             (format "%s (default %s): "
                     (string-trim-right prompt "[: \t\n]+")
                     default)
           prompt)))
    (read-string shown-prompt nil nil default)))

(defun ogent-cabinet-ui--read-optional-choice
    (prompt candidates &optional current)
  "Read PROMPT from CANDIDATES, allowing a blank value."
  (let ((completion-ignore-case t))
    (ogent-cabinet--blank-to-nil
     (completing-read prompt
                      (delete-dups
                       (seq-filter
                        (lambda (candidate)
                          (not (string-blank-p candidate)))
                        (mapcar (lambda (candidate)
                                  (format "%s" candidate))
                                candidates)))
                      nil nil nil nil current))))

(defun ogent-cabinet-ui--default-provider (root)
  "Return the default provider configured for ROOT."
  (or (plist-get (ogent-cabinet-settings-read root) :default-provider)
      ogent-cabinet-default-agent-provider))

(defun ogent-cabinet-ui--default-model (root)
  "Return the default model configured for ROOT."
  (plist-get (ogent-cabinet-settings-read root) :default-model))

(defun ogent-cabinet-ui--read-provider (prompt current)
  "Read a Cabinet provider with PROMPT and CURRENT."
  (ogent-cabinet-settings--read-provider prompt current))

(defun ogent-cabinet-ui--read-model
    (provider prompt current &optional prefer-first)
  "Read a Cabinet model for PROVIDER with PROMPT and CURRENT."
  (ogent-cabinet-settings--read-model provider current prompt prefer-first))

(defun ogent-cabinet-ui--provider-for-record (root record)
  "Return the provider to use for model completion in RECORD under ROOT."
  (or (ogent-cabinet--blank-to-nil (plist-get record :provider))
      (ogent-cabinet-ui--default-provider root)))

(defun ogent-cabinet-ui--effort-candidates (provider)
  "Return effort candidates for PROVIDER."
  (or (ignore-errors
        (plist-get (ogent-cabinet-adapter-resolve-provider provider)
                   :effort-levels))
      '("low" "medium" "high" "xhigh")))

(defun ogent-cabinet-ui--read-property-value
    (root property current &optional record)
  "Read PROPERTY value under ROOT using CURRENT and RECORD for completions."
  (let* ((record-provider (ogent-cabinet-ui--provider-for-record
                           root
                           (or record nil)))
         (prompt (format "%s: " property)))
    (pcase property
      ((or "OGENT_PROVIDER" "OGENT_ADAPTER")
       (or (ogent-cabinet-ui--read-provider prompt current) ""))
      ("OGENT_MODEL"
       (ogent-cabinet-ui--read-model record-provider prompt current))
      ("OGENT_EFFORT"
       (or (ogent-cabinet-ui--read-optional-choice
            prompt
            (ogent-cabinet-ui--effort-candidates record-provider)
            current)
           ""))
      ("OGENT_RUNTIME_MODE"
       (or (ogent-cabinet-ui--read-optional-choice
            prompt '("native" "terminal") current)
           ""))
      ((or "OGENT_ACTIVE" "OGENT_ARCHIVED" "OGENT_CAN_DISPATCH"
           "OGENT_ENABLED" "OGENT_SETUP_COMPLETE")
       (or (ogent-cabinet-ui--read-optional-choice
            prompt '("t" "nil") current)
           ""))
      ("OGENT_AGENT"
       (or (ogent-cabinet-ui--read-optional-choice
            prompt
            (ogent-cabinet-ui--agent-slugs root)
            current)
           ""))
      (_
       (read-string prompt current)))))

(defun ogent-cabinet-ui--task-status-candidates (root)
  "Return task status filter candidates for ROOT."
  (delete-dups
   (seq-filter
    (lambda (status)
      (not (string-blank-p status)))
    (append
     '("enabled" "disabled" "stale" "scheduled" "DONE" "FAILED"
       "RUNNING" "AWAITING-INPUT" "TODO" "CANCELLED")
     (mapcar (lambda (session)
               (or (plist-get session :status) ""))
             (ogent-cabinet-ui--all-sessions root))))))

(defun ogent-cabinet-ui--conversation-status-candidates (root)
  "Return conversation status filter candidates for ROOT."
  (delete-dups
   (seq-filter
    (lambda (status)
      (not (string-blank-p status)))
    (append
     '("DONE" "FAILED" "RUNNING" "AWAITING-INPUT" "ARCHIVED"
       "CANCELLED" "TODO")
     (mapcar (lambda (session)
               (or (plist-get session :status) ""))
             (ogent-cabinet-ui--all-sessions root))))))

(defun ogent-cabinet-ui--conversation-tag-candidates (root)
  "Return conversation tag filter candidates for ROOT."
  (delete-dups
   (apply
    #'append
    (mapcar (lambda (session)
              (copy-sequence (or (plist-get session :tags) nil)))
            (ogent-cabinet-ui--all-sessions root)))))

(defun ogent-cabinet-ui--refresh-home-buffer (root)
  "Refresh the Cabinet Home buffer for ROOT when it is already open."
  (when-let ((buffer (get-buffer
                      (ogent-cabinet-ui--buffer-name
                       ogent-cabinet-home-buffer-name-format root))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'ogent-cabinet-home-mode)
          (setq ogent-cabinet-home--root root)
          (ogent-cabinet-home-refresh))))))

(defun ogent-cabinet-ui--heading-text (label)
  "Return Cabinet section heading LABEL."
  (propertize label 'face 'ogent-cabinet-ui-heading))

(defun ogent-cabinet-ui--insert-heading (label)
  "Insert Cabinet section heading LABEL."
  (insert (ogent-cabinet-ui--heading-text label) "\n"))

(defun ogent-cabinet-ui--refresh-magit-section-availability ()
  "Refresh `magit-section' availability for Cabinet UI buffers."
  (setq ogent-cabinet-ui--magit-section-available
        (or ogent-cabinet-ui--magit-section-available
            (require 'magit-section nil t)))
  (when (and ogent-cabinet-ui--magit-section-available
             (not (featurep 'magit-section)))
    (require 'magit-section))
  ogent-cabinet-ui--magit-section-available)

(defun ogent-cabinet-ui--magit-section-usable-p ()
  "Return non-nil when Magit section APIs are usable."
  (and (ogent-cabinet-ui--refresh-magit-section-availability)
       (fboundp 'magit-current-section)
       (fboundp 'magit-insert-heading)
       (fboundp 'magit-section-toggle)
       (fboundp 'magit-section-forward-sibling)
       (fboundp 'magit-section-backward-sibling)))

(defmacro ogent-cabinet-ui--with-section (section heading &rest body)
  "Insert collapsible SECTION with HEADING around BODY when Magit is present."
  (declare (indent 2) (debug t))
  (let ((type (car section)))
    `(if (ogent-cabinet-ui--magit-section-usable-p)
         (let* ((section (magit-insert-section--create ',type nil nil))
                (magit-insert-section--current section)
                (magit-insert-section--oldroot
                 (or magit-insert-section--oldroot
                     (and (not magit-insert-section--parent)
                          (prog1 magit-root-section
                            (setq magit-root-section section)))))
                (magit-insert-section--parent section))
           (catch 'cancel-section
             (magit-insert-heading ,heading)
             ,@body
             (magit-insert-section--finish section))
           section)
       (insert ,heading "\n")
       ,@body)))

(defmacro ogent-cabinet-ui--with-root-section (section &rest body)
  "Insert root SECTION around BODY when Magit is present."
  (declare (indent 1) (debug t))
  (let ((type (car section)))
    `(if (ogent-cabinet-ui--magit-section-usable-p)
         (let* ((section (magit-insert-section--create ',type nil nil))
                (magit-insert-section--current section)
                (magit-insert-section--oldroot
                 (or magit-insert-section--oldroot
                     (and (not magit-insert-section--parent)
                          (prog1 magit-root-section
                            (setq magit-root-section section)))))
                (magit-insert-section--parent section))
           (catch 'cancel-section
             ,@body
             (magit-insert-section--finish section))
           section)
       ,@body)))

(defmacro ogent-cabinet-ui--define-section-mode (mode name docstring &rest body)
  "Define section-capable Cabinet MODE with NAME, DOCSTRING, and BODY."
  (declare (indent 3) (debug t))
  (let ((parent (if (bound-and-true-p ogent-cabinet-ui--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ,mode ,parent ,name ,docstring
       :group 'ogent-ui-cabinet
       ,@body)))

(defun ogent-cabinet-ui-toggle-section ()
  "Toggle the current Cabinet UI section."
  (interactive)
  (if (ogent-cabinet-ui--magit-section-usable-p)
      (if-let ((section (magit-current-section)))
          (condition-case err
              (magit-section-toggle section)
            (user-error (message "%s" (error-message-string err))))
        (message "No section at point"))
    (message "Section toggling requires magit-section")))

(defun ogent-cabinet-ui-cycle-sections ()
  "Cycle visibility for all Cabinet UI sections."
  (interactive)
  (if (and (ogent-cabinet-ui--magit-section-usable-p)
           (fboundp 'magit-section-cycle-global))
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-cabinet-ui-next-section ()
  "Move to the next sibling Cabinet UI section."
  (interactive)
  (when (ogent-cabinet-ui--magit-section-usable-p)
    (magit-section-forward-sibling)))

(defun ogent-cabinet-ui-previous-section ()
  "Move to the previous sibling Cabinet UI section."
  (interactive)
  (when (ogent-cabinet-ui--magit-section-usable-p)
    (magit-section-backward-sibling)))

(defun ogent-cabinet-ui-up-section ()
  "Move to the parent Cabinet UI section."
  (interactive)
  (when (and (ogent-cabinet-ui--magit-section-usable-p)
             (fboundp 'magit-section-up))
    (magit-section-up)))

(defun ogent-cabinet-ui--configure-section-buffer ()
  "Configure local Magit section affordances for the current buffer."
  (when (ogent-cabinet-ui--magit-section-usable-p)
    (setq-local magit-section-visibility-indicator '("..." . t))))

(defun ogent-cabinet-ui--insert-kv (label value)
  "Insert LABEL and VALUE as one detail line."
  (insert (propertize (format "%-14s" label) 'face 'ogent-cabinet-ui-dim))
  (insert (format "%s\n" (or value ""))))

(defun ogent-cabinet-ui--insert-readable-text (text &optional empty-label)
  "Insert TEXT as reader content, or EMPTY-LABEL when blank."
  (let ((content (string-trim-right (or text ""))))
    (if (string-empty-p content)
        (insert (propertize (or empty-label "  No content recorded\n")
                            'face 'ogent-cabinet-ui-dim))
      (insert content "\n"))))

(defun ogent-cabinet-ui--preview-lines (text limit)
  "Return a preview plist for TEXT with at most LIMIT lines."
  (let* ((lines (split-string (or text "") "\n"))
         (lines (if (and lines (string-empty-p (car (last lines))))
                    (butlast lines)
                  lines))
         (limit (max 0 (or limit 0)))
         (visible (seq-take lines limit))
         (hidden (- (length lines) (length visible))))
    (list :text (string-join visible "\n")
          :hidden hidden)))

(defun ogent-cabinet-ui--item-at-point ()
  "Return Cabinet item metadata at point."
  (or (get-text-property (point) 'ogent-cabinet-item)
      (get-text-property (line-beginning-position) 'ogent-cabinet-item)
      (tabulated-list-get-id)))

(defun ogent-cabinet-ui--visible-property-position (property direction)
  "Return the next visible position with PROPERTY in DIRECTION.
DIRECTION is either `next' or `previous'."
  (let ((limit (if (eq direction 'next) (point-max) (point-min)))
        (pos (point))
        found)
    (while (and (not found)
                (if (eq direction 'next)
                    (< pos limit)
                  (> pos limit)))
      (setq pos
            (if (eq direction 'next)
                (next-single-property-change pos property nil limit)
              (previous-single-property-change pos property nil limit)))
      (when pos
        (when (eq direction 'previous)
          (setq pos (max (point-min) (1- pos))))
        (if (and (get-text-property pos property)
                 (not (invisible-p pos)))
            (setq found pos)
          (setq pos (if (eq direction 'next)
                        (min (point-max) (1+ pos))
                      (max (point-min) (1- pos)))))))
    found))

(defun ogent-cabinet-ui--insert-item-line (item text)
  "Insert TEXT with Cabinet ITEM metadata."
  (let ((start (point)))
    (insert text "\n")
    (add-text-properties
     start
     (point)
     `(ogent-cabinet-item ,item
                          mouse-face highlight
                          help-echo "RET visits this Cabinet item"))))

(provide 'ogent-ui-cabinet-core)
;;; ogent-ui-cabinet-core.el ends here
