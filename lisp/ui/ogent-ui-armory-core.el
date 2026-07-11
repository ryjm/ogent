;;; ogent-ui-armory-core.el --- Core helpers for Org Armory UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared customization, faces, buffer-local state, helpers, and section macros
;; for the Armory UI surfaces.  Required by `ogent-ui-armory' and every
;; `ogent-ui-armory-*' view module.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'ogent-armory)
(require 'ogent-armory-adapter)
(require 'ogent-armory-evil)
(require 'ogent-armory-conversations)
(require 'ogent-armory-data)
(require 'ogent-armory-settings)
(require 'ogent-armory-runner)
(require 'ogent-ui-section)

;; magit-section availability probing lives in `ogent-ui-section' now.

(autoload 'ogent-armory-status "ogent-armory-status" nil t)
(autoload 'ogent-armory-actions "ogent-armory-actions" nil t)
(autoload 'ogent-armory-schedule "ogent-armory-schedule" nil t)
(autoload 'ogent-armory-agenda "ogent-armory-schedule" nil t)
(autoload 'ogent-armory-git-status "ogent-armory-git" nil t)
(autoload 'ogent-armory-command-palette "ogent-armory-palette" nil t)
(autoload 'ogent-armory-home "ogent-ui-armory" nil t)
(autoload 'ogent-armory-agents "ogent-ui-armory" nil t)
(autoload 'ogent-armory-org-chart "ogent-ui-armory" nil t)
(autoload 'ogent-armory-tasks "ogent-ui-armory" nil t)
(autoload 'ogent-armory-conversations "ogent-ui-armory" nil t)
(autoload 'ogent-armory-jobs "ogent-ui-armory" nil t)
(autoload 'ogent-armory-search "ogent-ui-armory" nil t)
(autoload 'ogent-armory-apps "ogent-ui-armory" nil t)
(autoload 'ogent-armory-data "ogent-armory-data" nil t)
(autoload 'ogent-armory-settings "ogent-armory-settings" nil t)

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
(defvar magit-section-visibility-indicators)
(defvar magit-insert-section--current)
(defvar magit-insert-section--oldroot)
(defvar magit-insert-section--parent)
(defvar magit-root-section)

(declare-function ogent-armory-home-refresh "ogent-ui-armory-home")

(defvar ogent-armory-jump-map
  (let ((map (make-sparse-keymap)))
    (define-key map "h" #'ogent-armory-home)
    (define-key map "g" #'ogent-armory-status)      ; g = graph
    (define-key map "a" #'ogent-armory-agents)
    (define-key map "o" #'ogent-armory-org-chart)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map "c" #'ogent-armory-conversations)
    (define-key map "j" #'ogent-armory-jobs)
    (define-key map "s" #'ogent-armory-search)
    (define-key map "A" #'ogent-armory-apps)
    (define-key map "d" #'ogent-armory-data)
    (define-key map "u" #'ogent-armory-schedule)
    (define-key map "v" #'ogent-armory-git-status)
    map)
  "Cross-surface Armory jumps, bound to `j' in every Armory buffer.")

(defmacro ogent-armory-ui--define-prefix (name arglist docstring primary-group &rest extra-groups)
  "Define NAME as an Armory Transient prefix.
ARGLIST, DOCSTRING, PRIMARY-GROUP, and EXTRA-GROUPS follow
`transient-define-prefix'.  The shared Armory jump group is spliced
into the expanded prefix as a literal group vector so older Transient
releases never have to resolve a named group reference."
  (declare (indent defun)
           (debug (&define name lambda-list stringp sexp &rest sexp)))
  `(transient-define-prefix ,name ,arglist
     ,docstring
     ,primary-group
     ,(vconcat
       [["Armory"
         :pad-keys t
         ("j h" "Home" ogent-armory-home)
         ("j g" "Graph" ogent-armory-status)
         ("j a" "Agents" ogent-armory-agents)
         ("j o" "Org chart" ogent-armory-org-chart)
         ("j t" "Tasks" ogent-armory-tasks)
         ("j c" "Conversations" ogent-armory-conversations)
         ("j j" "Jobs" ogent-armory-jobs)
         ("j s" "Search" ogent-armory-search)
         ("j A" "Apps" ogent-armory-apps)
         ("j d" "Data" ogent-armory-data)
         ("j u" "Schedule" ogent-armory-schedule)
         ("j v" "Git" ogent-armory-git-status)
         ("," "Settings" ogent-armory-settings)
         ("/" "Palette" ogent-armory-command-palette)]]
       (apply #'vector extra-groups))))

(defgroup ogent-ui-armory nil
  "Richer UI surfaces for Org Armory records."
  :group 'ogent-armory
  :prefix "ogent-armory-")

(defcustom ogent-armory-agents-buffer-name-format "*ogent-armory-agents: %s*"
  "Format string used for Armory agent list buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-home-buffer-name-format "*ogent-armory-home: %s*"
  "Format string used for Armory Home buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-agent-buffer-name-format "*ogent-armory-agent: %s*"
  "Format string used for single Armory agent buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-jobs-buffer-name-format "*ogent-armory-jobs: %s*"
  "Format string used for Armory job buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-conversations-buffer-name-format
  "*ogent-armory-conversations: %s*"
  "Format string used for Armory conversation buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-conversation-buffer-name-format
  "*ogent-armory-conversation: %s*"
  "Format string used for a single Armory conversation buffer."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-conversation-runtime-trace-preview-lines 12
  "Maximum runtime trace lines shown in conversation reader buffers."
  :type 'integer
  :group 'ogent-ui-armory)

(defcustom ogent-armory-tasks-buffer-name-format "*ogent-armory-tasks: %s*"
  "Format string used for Armory task lane buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-search-buffer-name-format "*ogent-armory-search: %s*"
  "Format string used for Armory search buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-apps-buffer-name-format "*ogent-armory-apps: %s*"
  "Format string used for Armory app artifact buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-stale-days 7
  "Days after which scheduled Armory jobs count as stale."
  :type 'integer
  :group 'ogent-ui-armory)

(defface ogent-armory-ui-heading
  '((t :weight bold))
  "Face for Armory UI section headings."
  :group 'ogent-ui-armory)

(defface ogent-armory-ui-dim
  '((t :inherit shadow))
  "Face for secondary Armory UI text."
  :group 'ogent-ui-armory)

(defface ogent-armory-ui-good
  '((t :inherit success))
  "Face for healthy Armory UI state."
  :group 'ogent-ui-armory)

(defface ogent-armory-ui-warning
  '((t :inherit warning))
  "Face for Armory UI state requiring attention."
  :group 'ogent-ui-armory)

(defface ogent-armory-ui-logo
  '((((class color) (background dark)) :foreground "#b98aff" :weight bold)
    (((class color) (background light)) :foreground "#7a3fb0" :weight bold)
    (t :inherit font-lock-keyword-face :weight bold))
  "Face for the Armory Home crest banner."
  :group 'ogent-ui-armory)

(defconst ogent-armory-agent-editable-properties
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

(defconst ogent-armory-job-editable-properties
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
    "OGENT_ARMORY_PATH"
    "OGENT_CREATED_AT"
    "OGENT_UPDATED_AT"
    "OGENT_RUN_AFTER"
    "OGENT_OWNER_TASK"
    "OGENT_ONE_SHOT_STATE"
    "OGENT_LAST_RUN"
    "OGENT_NEXT_RUN"
    "OGENT_TAGS"
    "OGENT_ARCHIVED")
  "Job properties editable from Armory job buffers.")

(defconst ogent-armory-job-property-keys
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
    ("OGENT_ARMORY_PATH" . :armory-path)
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

(defconst ogent-armory-task-lanes
  '("Inbox" "Needs Reply" "Running" "Just Finished" "Archive")
  "Attention lanes displayed by `ogent-armory-tasks'.")

(defvar-local ogent-armory-home--root nil
  "Armory root for the current home buffer.")

(defvar-local ogent-armory-agents--root nil
  "Armory root for the current agents buffer.")

(defvar-local ogent-armory-org-chart--root nil
  "Armory root for the current org chart buffer.")

(defvar-local ogent-armory-agent--root nil
  "Armory root for the current single-agent buffer.")

(defvar-local ogent-armory-agent--slug nil
  "Agent slug for the current single-agent buffer.")

(defvar-local ogent-armory-jobs--root nil
  "Armory root for the current jobs buffer.")

(defvar-local ogent-armory-jobs--agent nil
  "Optional agent filter for the current jobs buffer.")

(defvar-local ogent-armory-conversations--root nil
  "Armory root for the current conversations buffer.")

(defvar-local ogent-armory-conversations--filters nil
  "Filters for the current conversations buffer.")

(defvar-local ogent-armory-conversation--root nil
  "Armory root for the current conversation detail buffer.")

(defvar-local ogent-armory-conversation--file nil
  "Conversation file for the current detail buffer.")

(defvar-local ogent-armory-tasks--root nil
  "Armory root for the current task buffer.")

(defvar-local ogent-armory-tasks--filters nil
  "Filters for the current task buffer.")

(defvar-local ogent-armory-tasks--view 'board
  "Current task view: `board', `list', or `schedule'.")

(defvar-local ogent-armory-search--root nil
  "Armory root for the current search buffer.")

(defvar-local ogent-armory-search--query nil
  "Search query for the current search buffer.")

(defvar-local ogent-armory-search--filters nil
  "Search filters for the current search buffer.")

(defvar-local ogent-armory-apps--root nil
  "Armory root for the current apps buffer.")

(defun ogent-armory-ui--root (&optional directory)
  "Return the Armory root for DIRECTORY or the current context."
  (let* ((candidate (ogent-armory--directory
                     (or directory default-directory)))
         (root (or (ogent-armory-find-root candidate)
                   candidate)))
    (directory-file-name (file-truename root))))

(defun ogent-armory-ui--invalidate-cache-when-force (force root)
  "Invalidate cached Armory data for ROOT when FORCE is non-nil."
  (when (and force root)
    (ogent-armory-cache-invalidate (ogent-armory-ui--root root))))

(defun ogent-armory-ui--root-label (root)
  "Return a compact label for ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun ogent-armory-ui--buffer-name (format-string root &optional suffix)
  "Return a Armory UI buffer name for FORMAT-STRING, ROOT, and SUFFIX."
  (format format-string
          (if suffix
              (format "%s/%s" (ogent-armory-ui--root-label root) suffix)
            (ogent-armory-ui--root-label root))))

(defun ogent-armory-ui--agent-slugs (root)
  "Return agent slugs under ROOT."
  (or (ogent-armory-list-visible-agents root :include-visible t) nil))

(defun ogent-armory-ui--read-agent (root)
  "Read an agent slug from ROOT."
  (completing-read "Agent: " (ogent-armory-ui--agent-slugs root) nil t))

(defun ogent-armory-ui--read-agent-default (root &optional default)
  "Read an agent slug from ROOT, using DEFAULT when provided."
  (let ((agents (ogent-armory-ui--agent-slugs root)))
    (cond
     ((null agents)
      (user-error "No Armory agents exist"))
     ((and (= (length agents) 1)
           (or (null default)
               (equal default (car agents))))
      (car agents))
     ((ogent-armory--blank-to-nil default)
      (completing-read
       (format "Agent (default %s): " default)
       agents nil t nil nil default))
     (t
      (completing-read "Agent: " agents nil t)))))

(defun ogent-armory-ui--agent-jobs (root slug)
  "Return jobs for SLUG under ROOT."
  (if (file-exists-p (ogent-armory-agent-file root slug))
      (or (ogent-armory-list-jobs root slug) nil)
    nil))

(defun ogent-armory-ui--agent-sessions (root slug)
  "Return sessions for SLUG under ROOT."
  (or (ogent-armory-ui--all-sessions root slug) nil))

(defun ogent-armory-ui--all-sessions (root &optional agent)
  "Return canonical conversations and legacy sessions under ROOT.
When AGENT is non-nil, narrow to that agent."
  (seq-sort
   (lambda (left right)
     (string> (or (plist-get left :finished) "")
              (or (plist-get right :finished) "")))
   (append
    (ogent-armory-conversation-list-sessions root :agent agent)
    (ogent-armory-list-sessions root agent))))

(defun ogent-armory-ui--all-jobs (root &optional agent)
  "Return all Armory jobs under ROOT, optionally narrowed to AGENT."
  (let (jobs)
    (dolist (slug (if agent (list agent) (ogent-armory-ui--agent-slugs root)))
      (setq jobs (append jobs (ogent-armory-ui--agent-jobs root slug))))
    jobs))

(defun ogent-armory-ui--last-session (sessions)
  "Return the most recent session from SESSIONS."
  (car (seq-sort
        (lambda (left right)
          (string> (or (plist-get left :finished) "")
                   (or (plist-get right :finished) "")))
        (copy-sequence sessions))))

(defun ogent-armory-ui--stale-job-p (root job)
  "Return non-nil when JOB under ROOT has no recent successful session."
  (let* ((agent (plist-get job :agent))
         (job-id (plist-get job :id))
         (sessions (seq-filter
                    (lambda (session)
                      (and (equal (plist-get session :agent) agent)
                           (equal (plist-get session :job-id) job-id)
                           (zerop (or (plist-get session :exit-status) 0))))
                    (ogent-armory-ui--all-sessions root agent)))
         (last (ogent-armory-ui--last-session sessions))
         (finished (plist-get last :finished)))
    (and (plist-get job :enabled)
         (not (plist-get job :archived))
         finished
         (> (float-time
             (time-subtract
              (current-time)
              (date-to-time finished)))
            (* ogent-armory-stale-days 24 60 60)))))

(defun ogent-armory-ui--format-tags (tags)
  "Return TAGS as comma-separated text."
  (string-join (or tags nil) ", "))

(defun ogent-armory-ui--file-line (file line)
  "Visit FILE and move to LINE."
  (find-file file)
  (goto-char (point-min))
  (forward-line (max 0 (1- (or line 1)))))

(defun ogent-armory-ui--visit-path (path)
  "Visit PATH or signal a user error."
  (unless (and path (file-exists-p path))
    (user-error "No Armory file at point"))
  (find-file path))

(defun ogent-armory-ui--canonical-conversation-path-p (path)
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

(defun ogent-armory-ui--turns-by-role (turns role)
  "Return matching conversation content strings.
TURNS is the turn list; return content for turns matching ROLE."
  (delq
   nil
   (mapcar
    (lambda (turn)
      (when (equal (plist-get turn :role) role)
        (plist-get turn :content)))
    turns)))

(defun ogent-armory-ui--canonical-conversation-detail (root path)
  "Return a detail plist for canonical conversation PATH under ROOT."
  (let* ((id (file-name-nondirectory
              (directory-file-name (file-name-directory path))))
         (detail (ogent-armory-conversation-detail root id))
         (turns (plist-get detail :turns))
         (agent-turns (seq-filter
                       (lambda (turn)
                         (equal (plist-get turn :role) "agent"))
                       turns))
         (last-agent (car (last agent-turns))))
    (append
     (list :name (plist-get detail :title)
           :status (ogent-armory-conversations--session-status
                    (plist-get detail :status))
           :finished (or (plist-get detail :completed)
                         (plist-get detail :last-activity)
                         (plist-get detail :started))
           :exit-status (plist-get detail :exit-code)
           :prompt (string-join
                    (ogent-armory-ui--turns-by-role turns "user")
                    "\n\n---\n\n")
           :output (string-join
                    (ogent-armory-ui--turns-by-role turns "agent")
                    "\n\n---\n\n")
           :error (plist-get last-agent :error)
           :runtime-trace nil
           :tools nil)
     detail)))

(defun ogent-armory-ui--conversation-detail (root path)
  "Return detail metadata for conversation PATH under ROOT."
  (if (ogent-armory-ui--canonical-conversation-path-p path)
      (ogent-armory-ui--canonical-conversation-detail root path)
    (ogent-armory-session-detail path)))

(defun ogent-armory-ui--canonical-conversation-id (path)
  "Return the canonical conversation id from PATH."
  (file-name-nondirectory
   (directory-file-name (file-name-directory path))))

(defun ogent-armory-ui--iso-now ()
  "Return the current time as a UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))

(defun ogent-armory-ui--conversation-append-event
    (root path type &optional payload)
  "Append TYPE event with PAYLOAD for canonical conversation PATH under ROOT."
  (when (ogent-armory-ui--canonical-conversation-path-p path)
    (ogent-armory-conversation-append-event
     root
     (ogent-armory-ui--canonical-conversation-id path)
     type
     :ts (ogent-armory-ui--iso-now)
     :payload payload)))

(defun ogent-armory-ui--conversation-update-properties
    (root path properties &optional event payload)
  "Update conversation PATH under ROOT with Org PROPERTIES.
When EVENT is non-nil, append it to the canonical event log with PAYLOAD."
  (if (ogent-armory-ui--canonical-conversation-path-p path)
      (let ((id (ogent-armory-ui--canonical-conversation-id path)))
        (ogent-armory-conversation-update-properties root id properties)
        (when event
          (ogent-armory-conversation-append-event
           root id event
           :ts (ogent-armory-ui--iso-now)
           :payload payload)))
    (dolist (property properties)
      (ogent-armory-update-session-property path (car property) (cdr property)))))

(defun ogent-armory-ui--conversation-artifacts (detail)
  "Return artifact paths declared by DETAIL and each turn."
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

(defun ogent-armory-ui--artifact-path (root artifact)
  "Return ARTIFACT expanded under ROOT when needed."
  (when artifact
    (if (file-name-absolute-p artifact)
        artifact
      (expand-file-name artifact root))))

(defun ogent-armory-ui--put-property (file property value)
  "Set PROPERTY to VALUE in the first Org heading of FILE."
  (ogent-armory--update-first-heading-property file property value))

(defun ogent-armory-ui--job-with-property (job property value)
  "Return JOB copied with Org PROPERTY set to VALUE."
  (let* ((copy (copy-sequence job))
         (key (cdr (assoc property ogent-armory-job-property-keys))))
    (unless key
      (user-error "Unsupported Armory job property: %s" property))
    (pcase property
      ("OGENT_TAGS"
       (plist-put copy key (ogent-armory--tags-from-string value)))
      ("OGENT_ENABLED"
       (plist-put copy :enabled-raw value)
       (plist-put copy :enabled (ogent-armory--truth-value value)))
      ("OGENT_ARCHIVED"
       (plist-put copy :archived-raw value)
       (plist-put copy :archived (ogent-armory--truth-value value)))
      (_
       (plist-put copy key value)))
    copy))

(defun ogent-armory-ui--visit-body (file)
  "Visit FILE and move point to the first body line."
  (find-file file)
  (org-mode)
  (goto-char (point-min))
  (unless (re-search-forward org-heading-regexp nil t)
    (user-error "No Org heading found in %s" file))
  (org-back-to-heading t)
  (org-end-of-meta-data t)
  (skip-chars-forward " \t\n"))

(defun ogent-armory-ui--read-current-property (file property)
  "Return PROPERTY from the first Org heading in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (ogent-armory--org-mode)
    (ogent-armory--first-heading-title)
    (org-entry-get nil property)))

(defun ogent-armory-ui--read-string-default (prompt default)
  "Read string for PROMPT with DEFAULT shown as an Emacs default value."
  (let ((shown-prompt
         (if (and default (not (string-empty-p default)))
             (format "%s (default %s): "
                     (string-trim-right prompt "[: \t\n]+")
                     default)
           prompt)))
    (read-string shown-prompt nil nil default)))

(defun ogent-armory-ui--read-optional-choice
    (prompt candidates &optional current)
  "Read PROMPT from CANDIDATES, allowing a blank value.
CURRENT is offered as the default value."
  (let ((completion-ignore-case t))
    (ogent-armory--blank-to-nil
     (completing-read prompt
                      (delete-dups
                       (seq-filter
                        (lambda (candidate)
                          (not (string-blank-p candidate)))
                        (mapcar (lambda (candidate)
                                  (format "%s" candidate))
                                candidates)))
                      nil nil nil nil current))))

(defun ogent-armory-ui--default-provider (root)
  "Return the default provider configured for ROOT."
  (or (plist-get (ogent-armory-settings-read root) :default-provider)
      ogent-armory-default-agent-provider))

(defun ogent-armory-ui--default-model (root)
  "Return the default model configured for ROOT."
  (plist-get (ogent-armory-settings-read root) :default-model))

(defun ogent-armory-ui--read-provider (prompt current)
  "Read a Armory provider with PROMPT and CURRENT."
  (ogent-armory-settings--read-provider prompt current))

(defun ogent-armory-ui--read-model
    (provider prompt current &optional prefer-first)
  "Read a Armory model for PROVIDER with PROMPT and CURRENT.
When PREFER-FIRST is non-nil, default to the first provider model."
  (ogent-armory-settings--read-model provider current prompt prefer-first))

(defun ogent-armory-ui--provider-for-record (root record)
  "Return the provider to use for model completion in RECORD under ROOT."
  (or (ogent-armory--blank-to-nil (plist-get record :provider))
      (ogent-armory-ui--default-provider root)))

(defun ogent-armory-ui--effort-candidates (provider)
  "Return effort candidates for PROVIDER."
  (or (ignore-errors
        (plist-get (ogent-armory-adapter-resolve-provider provider)
                   :effort-levels))
      '("low" "medium" "high" "xhigh")))

(defun ogent-armory-ui--read-property-value
    (root property current &optional record)
  "Read PROPERTY value under ROOT using CURRENT and RECORD for completions."
  (let* ((record-provider (ogent-armory-ui--provider-for-record
                           root
                           (or record nil)))
         (prompt (format "%s: " property)))
    (pcase property
      ((or "OGENT_PROVIDER" "OGENT_ADAPTER")
       (or (ogent-armory-ui--read-provider prompt current) ""))
      ("OGENT_MODEL"
       (ogent-armory-ui--read-model record-provider prompt current))
      ("OGENT_EFFORT"
       (or (ogent-armory-ui--read-optional-choice
            prompt
            (ogent-armory-ui--effort-candidates record-provider)
            current)
           ""))
      ("OGENT_RUNTIME_MODE"
       (or (ogent-armory-ui--read-optional-choice
            prompt '("native" "terminal") current)
           ""))
      ((or "OGENT_ACTIVE" "OGENT_ARCHIVED" "OGENT_CAN_DISPATCH"
           "OGENT_ENABLED" "OGENT_SETUP_COMPLETE")
       (or (ogent-armory-ui--read-optional-choice
            prompt '("t" "nil") current)
           ""))
      ("OGENT_AGENT"
       (or (ogent-armory-ui--read-optional-choice
            prompt
            (ogent-armory-ui--agent-slugs root)
            current)
           ""))
      (_
       (read-string prompt current)))))

(defun ogent-armory-ui--task-status-candidates (root)
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
             (ogent-armory-ui--all-sessions root))))))

(defun ogent-armory-ui--conversation-status-candidates (root)
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
             (ogent-armory-ui--all-sessions root))))))

(defun ogent-armory-ui--conversation-tag-candidates (root)
  "Return conversation tag filter candidates for ROOT."
  (delete-dups
   (apply
    #'append
    (mapcar (lambda (session)
              (copy-sequence (or (plist-get session :tags) nil)))
            (ogent-armory-ui--all-sessions root)))))

(defun ogent-armory-ui--refresh-home-buffer (root)
  "Refresh the Armory Home buffer for ROOT when it is already open."
  (when-let ((buffer (get-buffer
                      (ogent-armory-ui--buffer-name
                       ogent-armory-home-buffer-name-format root))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'ogent-armory-home-mode)
          (setq ogent-armory-home--root root)
          (ogent-armory-home-refresh))))))

(defun ogent-armory-ui--heading-text (label)
  "Return Armory section heading LABEL."
  (propertize label 'face 'ogent-armory-ui-heading))

(defun ogent-armory-ui--insert-heading (label)
  "Insert Armory section heading LABEL."
  (insert (ogent-armory-ui--heading-text label) "\n"))

(defalias 'ogent-armory-ui--refresh-magit-section-availability
  #'ogent-section-available-p)

(defalias 'ogent-armory-ui--magit-section-usable-p
  #'ogent-section-usable-p)

(defmacro ogent-armory-ui--with-section (section heading &rest body)
  "Compatibility wrapper for `ogent-section-with'.
Insert collapsible SECTION with HEADING around BODY."
  (declare (indent 2) (debug t))
  `(ogent-section-with ,section ,heading ,@body))

(defmacro ogent-armory-ui--with-root-section (section &rest body)
  "Compatibility wrapper for `ogent-section-with-root'.
Insert root SECTION around BODY."
  (declare (indent 1) (debug t))
  `(ogent-section-with-root ,section ,@body))

(defmacro ogent-armory-ui--define-section-mode (mode name docstring &rest body)
  "Compatibility wrapper for `ogent-section-define-mode'.
Define section-capable Armory MODE with NAME, DOCSTRING, and BODY."
  (declare (indent 3) (debug t))
  `(ogent-section-define-mode ,mode ,name ,docstring
     :group 'ogent-ui-armory
     ,@body))

(defalias 'ogent-armory-ui-toggle-section #'ogent-section-toggle)
(defalias 'ogent-armory-ui-cycle-sections #'ogent-section-cycle)
(defalias 'ogent-armory-ui-next-section #'ogent-section-next)
(defalias 'ogent-armory-ui-previous-section #'ogent-section-prev)
(defalias 'ogent-armory-ui-up-section #'ogent-section-up)

(defalias 'ogent-armory-ui--configure-section-buffer
  #'ogent-section-configure-buffer)

(defun ogent-armory-ui--insert-kv (label value)
  "Insert LABEL and VALUE as one detail line."
  (insert (propertize (format "%-14s" label) 'face 'ogent-armory-ui-dim))
  (insert (format "%s\n" (or value ""))))

(defun ogent-armory-ui--insert-readable-text (text &optional empty-label)
  "Insert TEXT as reader content, or EMPTY-LABEL when blank."
  (let ((content (string-trim-right (or text ""))))
    (if (string-empty-p content)
        (insert (propertize (or empty-label "  No content recorded\n")
                            'face 'ogent-armory-ui-dim))
      (insert content "\n"))))

(defun ogent-armory-ui--preview-lines (text limit)
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

(defun ogent-armory-ui--item-at-point ()
  "Return Armory item metadata at point."
  (or (get-text-property (point) 'ogent-armory-item)
      (ogent-section-item-at-point 'ogent-armory-item)
      (tabulated-list-get-id)))

(defalias 'ogent-armory-ui--visible-property-position
  #'ogent-section-visible-item-position)

(defun ogent-armory-ui--tabulated-item-position (direction)
  "Return the next tabulated-list row position in DIRECTION.
DIRECTION is `next' or `previous'."
  (when (derived-mode-p 'tabulated-list-mode)
    (save-excursion
      (let ((step (if (eq direction 'next) 1 -1))
            found)
        (while (and (not found)
                    (zerop (forward-line step)))
          (when (tabulated-list-get-id)
            (setq found (line-beginning-position))))
        found))))


(defun ogent-armory-ui--insert-item-line (item text)
  "Insert TEXT with Armory ITEM metadata."
  (ogent-section-insert-item-line text 'ogent-armory-item item
                                  "RET visits this Armory item"))

(defun ogent-armory-ui-next-item ()
  "Move point to the next actionable Armory item line."
  (interactive)
  (when-let ((next (or (ogent-section-visible-item-position
                        'ogent-armory-item 'next)
                       (ogent-armory-ui--tabulated-item-position 'next))))
    (goto-char next)))

(defun ogent-armory-ui-previous-item ()
  "Move point to the previous actionable Armory item line."
  (interactive)
  (when-let ((previous (or (ogent-section-visible-item-position
                            'ogent-armory-item 'previous)
                           (ogent-armory-ui--tabulated-item-position 'previous))))
    (goto-char previous)))

(provide 'ogent-ui-armory-core)
;;; ogent-ui-armory-core.el ends here
