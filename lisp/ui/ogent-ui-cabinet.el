;;; ogent-ui-cabinet.el --- Richer Org Cabinet buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Interactive Cabinet surfaces over the Org-backed storage layer: agent lists,
;; single-agent profiles, attention lanes, search, and app artifact opening.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'ogent-cabinet)
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

;;; Cabinet Home

(defvar ogent-cabinet-home-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-home-visit))
    (define-key map "m" #'ogent-cabinet-home-dispatch)
    (define-key map (kbd "C-c m") #'ogent-cabinet-home-dispatch)
    (define-key map "?" #'ogent-cabinet-home-help)
    (define-key map (kbd "C-c ?") #'ogent-cabinet-home-help)
    (define-key map "g" #'ogent-cabinet-home-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-home-refresh)
    (define-key map "q" #'quit-window)
    (define-key map "j" #'ogent-cabinet-jobs)
    (define-key map (kbd "C-c j") #'ogent-cabinet-jobs)
    (define-key map "J" #'ogent-cabinet-home-open-jobs)
    (define-key map (kbd "C-c J") #'ogent-cabinet-home-open-jobs)
    (define-key map "R" #'ogent-cabinet-home-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-home-run)
    (define-key map "E" #'ogent-cabinet-home-edit-item)
    (define-key map (kbd "C-c E") #'ogent-cabinet-home-edit-item)
    (define-key map (kbd "TAB") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-cabinet-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-cabinet-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-cabinet-ui-previous-section)
    (define-key map (kbd "^") #'ogent-cabinet-ui-up-section)
    (define-key map (kbd "C-c u") #'ogent-cabinet-ui-up-section)
    (define-key map "a" #'ogent-cabinet-agents)
    (define-key map (kbd "C-c a") #'ogent-cabinet-agents)
    (define-key map "D" #'ogent-cabinet-data)
    (define-key map (kbd "C-c D") #'ogent-cabinet-data)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map (kbd "C-c t") #'ogent-cabinet-tasks)
    (define-key map "c" #'ogent-cabinet-conversations)
    (define-key map (kbd "C-c c") #'ogent-cabinet-conversations)
    (define-key map "u" #'ogent-cabinet-schedule)
    (define-key map (kbd "C-c S") #'ogent-cabinet-schedule)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-search)
    (define-key map "A" #'ogent-cabinet-apps)
    (define-key map (kbd "C-c A") #'ogent-cabinet-apps)
    (define-key map "h" #'ogent-cabinet-git-status)
    (define-key map (kbd "C-c h") #'ogent-cabinet-git-status)
    (define-key map "/" #'ogent-cabinet-command-palette)
    (define-key map (kbd "C-c /") #'ogent-cabinet-command-palette)
    (define-key map "," #'ogent-cabinet-settings)
    (define-key map (kbd "C-c ,") #'ogent-cabinet-settings)
    (define-key map "." #'ogent-cabinet-help)
    (define-key map (kbd "C-c .") #'ogent-cabinet-help)
    (define-key map "G" #'ogent-cabinet-status)
    (define-key map (kbd "C-c G") #'ogent-cabinet-status)
    (define-key map "e" #'ogent-cabinet-home-edit-metadata)
    (define-key map (kbd "C-c e") #'ogent-cabinet-home-edit-metadata)
    (define-key map "n" #'ogent-cabinet-home-next-item)
    (define-key map (kbd "C-c n") #'ogent-cabinet-home-next-item)
    (define-key map "p" #'ogent-cabinet-home-previous-item)
    (define-key map (kbd "C-c p") #'ogent-cabinet-home-previous-item)
    map)
  "Keymap for `ogent-cabinet-home-mode'.")

(ogent-cabinet-ui--define-section-mode ogent-cabinet-home-mode "Cabinet-Home"
                                       "Major mode for Cabinet Home."
                                       (setq-local revert-buffer-function #'ogent-cabinet-home-refresh)
                                       (setq-local truncate-lines t)
                                       (setq-local buffer-read-only t)
                                       (ogent-cabinet-ui--configure-section-buffer)
                                       (setq-local header-line-format (ogent-cabinet-home--header-line)))

(defun ogent-cabinet-home--header-line ()
  "Return header line for Cabinet Home."
  "C-c m menu  C-c ? help  C-c . docs  RET visit  TAB section  M-n/p sections  C-c g refresh  q quit  C-c / palette  C-c , settings  C-c j Jobs  C-c a Agents  C-c t Tasks  C-c c Conversations  C-c s Search")

;;;###autoload
(defun ogent-cabinet-home (&optional directory)
  "Open Cabinet Home for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-home-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-home-mode)
      (setq ogent-cabinet-home--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-home-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-home-refresh (&rest _)
  "Refresh Cabinet Home."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-cabinet-home--insert-buffer)
    (goto-char (point-min))))

(defun ogent-cabinet-home--insert-nav (label key command)
  "Insert navigation LABEL for KEY dispatching to COMMAND."
  (ogent-cabinet-ui--insert-item-line
   (list :type 'command :command command)
   (format "  [%s] %s" key label)))

(defun ogent-cabinet-home--insert-buffer ()
  "Insert Cabinet Home contents."
  (ogent-cabinet-ui--with-root-section (ogent-cabinet-home-root)
                                       (ogent-cabinet-home--insert-buffer-content)))

(defun ogent-cabinet-home--insert-buffer-content ()
  "Insert Cabinet Home content sections."
  (let* ((root ogent-cabinet-home--root)
         (index (ogent-cabinet-read-index root))
         (agents (ogent-cabinet-ui--agent-slugs root))
         (jobs (ogent-cabinet-ui--all-jobs root))
         (sessions (ogent-cabinet-ui--all-sessions root))
         (failed (seq-filter
                  (lambda (session)
                    (not (zerop (or (plist-get session :exit-status) 0))))
                  sessions))
         (running (seq-filter #'ogent-cabinet-runner-running-p agents))
         (archived (seq-filter
                    (lambda (record)
                      (plist-get record :archived))
                    (append jobs sessions)))
         (apps (ogent-cabinet-list-apps root))
         (stale (seq-filter
                 (lambda (job)
                   (ogent-cabinet-ui--stale-job-p root job))
                 jobs))
         (missing-persona
          (seq-filter
           (lambda (slug)
             (let ((agent (ogent-cabinet-read-agent root slug)))
               (or (string-blank-p (or (plist-get agent :role) ""))
                   (string-blank-p (or (plist-get agent :provider) ""))
                   (string-blank-p (or (plist-get agent :body) "")))))
           agents)))
    (insert (propertize "Cabinet Home" 'face 'ogent-cabinet-ui-heading) "\n")
    (ogent-cabinet-ui--insert-kv "Title" (plist-get index :name))
    (ogent-cabinet-ui--insert-kv "Path" root)
    (ogent-cabinet-ui--insert-kv "Kind" (plist-get index :kind))
    (ogent-cabinet-ui--insert-kv "Tags" (ogent-cabinet-ui--format-tags
                                         (plist-get index :tags)))
    (ogent-cabinet-ui--insert-kv "Description" (plist-get index :description))
    (insert "\n")
    (ogent-cabinet-ui--with-section (ogent-cabinet-home-health)
                                    (ogent-cabinet-ui--heading-text "Health")
                                    (insert (format "  agents: %d  enabled jobs: %d  failed conversations: %d  running sessions: %d  archived items: %d  app artifacts: %d\n"
                                                    (length agents)
                                                    (length (seq-filter (lambda (job)
                                                                          (and (plist-get job :enabled)
                                                                               (not (plist-get job :archived))))
                                                                        jobs))
                                                    (length failed)
                                                    (length running)
                                                    (length archived)
                                                    (length apps))))
    (insert "\n")
    (ogent-cabinet-ui--with-section (ogent-cabinet-home-navigate)
                                    (ogent-cabinet-ui--heading-text "Navigate")
                                    (ogent-cabinet-home--insert-nav "Data" "C-c D" #'ogent-cabinet-data)
                                    (ogent-cabinet-home--insert-nav "Agents" "C-c a" #'ogent-cabinet-agents)
                                    (ogent-cabinet-home--insert-nav "Jobs" "C-c j" #'ogent-cabinet-jobs)
                                    (ogent-cabinet-home--insert-nav "Tasks" "C-c t" #'ogent-cabinet-tasks)
                                    (ogent-cabinet-home--insert-nav "Conversations" "C-c c" #'ogent-cabinet-conversations)
                                    (ogent-cabinet-home--insert-nav "Schedule" "C-c S" #'ogent-cabinet-schedule)
                                    (ogent-cabinet-home--insert-nav "Search" "C-c s" #'ogent-cabinet-search)
                                    (ogent-cabinet-home--insert-nav "Apps" "C-c A" #'ogent-cabinet-apps)
                                    (ogent-cabinet-home--insert-nav "Git" "C-c h" #'ogent-cabinet-git-status)
                                    (ogent-cabinet-home--insert-nav "Palette" "C-c /" #'ogent-cabinet-command-palette)
                                    (ogent-cabinet-home--insert-nav "Settings" "C-c ," #'ogent-cabinet-settings)
                                    (ogent-cabinet-home--insert-nav "Help" "C-c ." #'ogent-cabinet-help)
                                    (ogent-cabinet-home--insert-nav "Graph" "C-c G" #'ogent-cabinet-status)
                                    (ogent-cabinet-ui--insert-item-line
                                     (list :type 'file :path (ogent-cabinet-index-file root))
                                     "  [C-c e] Cabinet metadata")
                                    (ogent-cabinet-ui--insert-item-line
                                     (list :type 'file :path (ogent-cabinet-index-file root))
                                     "  Source Org"))
    (insert "\n")
    (ogent-cabinet-home--insert-active-jobs jobs root)
    (insert "\n")
    (ogent-cabinet-ui--with-section (ogent-cabinet-home-recent)
                                    (ogent-cabinet-ui--heading-text "Recent Activity")
                                    (if sessions
                                        (dolist (session (seq-take sessions 5))
                                          (ogent-cabinet-ui--insert-item-line
                                           (list :type 'session :path (plist-get session :path)
                                                 :agent (plist-get session :agent)
                                                 :job-id (plist-get session :job-id))
                                           (format "  %s  %s  %s"
                                                   (or (plist-get session :status) "")
                                                   (or (plist-get session :name) "")
                                                   (or (plist-get session :finished) ""))))
                                      (insert (propertize "  No conversations yet\n" 'face 'ogent-cabinet-ui-dim))))
    (insert "\n")
    (ogent-cabinet-ui--with-section (ogent-cabinet-home-attention)
                                    (ogent-cabinet-ui--heading-text "Needs Attention")
                                    (if (or failed stale missing-persona)
                                        (progn
                                          (dolist (session failed)
                                            (ogent-cabinet-ui--insert-item-line
                                             (list :type 'session :path (plist-get session :path)
                                                   :agent (plist-get session :agent)
                                                   :job-id (plist-get session :job-id))
                                             (format "  failed session  %s" (plist-get session :name))))
                                          (dolist (job stale)
                                            (ogent-cabinet-ui--insert-item-line
                                             (list :type 'job :agent (plist-get job :agent)
                                                   :job-id (plist-get job :id)
                                                   :path (ogent-cabinet-job-file root
                                                                                 (plist-get job :agent)
                                                                                 (plist-get job :id)))
                                             (format "  stale job       %s" (plist-get job :name))))
                                          (dolist (slug missing-persona)
                                            (ogent-cabinet-ui--insert-item-line
                                             (list :type 'agent :agent slug
                                                   :path (ogent-cabinet-agent-file root slug))
                                             (format "  missing persona %s" slug))))
                                      (insert (propertize "  Nothing needs attention\n" 'face 'ogent-cabinet-ui-good))))))

(defun ogent-cabinet-home--insert-active-jobs (jobs root)
  "Insert active development JOBS for ROOT."
  (let ((active (seq-filter (lambda (job)
                              (and (plist-get job :enabled)
                                   (not (plist-get job :archived))))
                            jobs)))
    (ogent-cabinet-ui--with-section (ogent-cabinet-home-active-jobs)
                                    (ogent-cabinet-ui--heading-text "Active Jobs")
                                    (if active
                                        (dolist (job active)
                                          (let ((agent (plist-get job :agent))
                                                (job-id (plist-get job :id)))
                                            (ogent-cabinet-ui--insert-item-line
                                             (list :type 'job
                                                   :agent agent
                                                   :job-id job-id
                                                   :path (ogent-cabinet-job-file root agent job-id))
                                             (format "  %s  %s  %s  [C-c r run] [C-c E prompt] [C-c J jobs]"
                                                     agent
                                                     (or (plist-get job :name) job-id)
                                                     (or (plist-get job :cron)
                                                         (plist-get job :heartbeat)
                                                         "manual")))))
                                      (insert (propertize "  No active jobs\n" 'face 'ogent-cabinet-ui-dim))))))

(defun ogent-cabinet-home-visit ()
  "Visit or dispatch the item at point in Cabinet Home."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('command (funcall (plist-get item :command) ogent-cabinet-home--root))
      ('session (ogent-cabinet-conversation ogent-cabinet-home--root
                                            (plist-get item :path)))
      ('job (ogent-cabinet-jobs ogent-cabinet-home--root
                                (plist-get item :agent)))
      ('agent (ogent-cabinet-agent ogent-cabinet-home--root
                                   (plist-get item :agent)))
      ('file (ogent-cabinet-ui--visit-path (plist-get item :path)))
      (_ (user-error "No Cabinet Home item at point")))))

(defun ogent-cabinet-home-run ()
  "Run or retry the Cabinet Home item at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-run-job
        ogent-cabinet-home--root
        (plist-get item :agent)
        (plist-get item :job-id)))
      ('session
       (if-let ((job-id (plist-get item :job-id)))
           (ogent-cabinet-run-job
            ogent-cabinet-home--root
            (plist-get item :agent)
            job-id)
         (ogent-cabinet-run-agent
          ogent-cabinet-home--root
          (plist-get item :agent)
          (read-string "Instruction: "))))
      ('agent
       (ogent-cabinet-run-agent
        ogent-cabinet-home--root
        (plist-get item :agent)
        (read-string "Instruction: ")))
      (_
       (user-error "No runnable Cabinet Home item at point")))))

(defun ogent-cabinet-home-edit-item ()
  "Visit the editable body or source for the Cabinet Home item at point."
  (interactive)
  (let* ((item (ogent-cabinet-ui--item-at-point))
         (path (plist-get item :path)))
    (unless (and path (file-exists-p path))
      (user-error "No editable Cabinet item at point"))
    (pcase (plist-get item :type)
      ((or 'job 'agent)
       (ogent-cabinet-ui--visit-body path))
      (_
       (ogent-cabinet-ui--visit-path path)))))

(defun ogent-cabinet-home-open-jobs ()
  "Open Cabinet jobs related to the item at point."
  (interactive)
  (let* ((item (ogent-cabinet-ui--item-at-point))
         (agent (plist-get item :agent))
         (job-id (plist-get item :job-id))
         (buffer (ogent-cabinet-jobs ogent-cabinet-home--root agent)))
    (when (and agent job-id (fboundp 'ogent-cabinet-jobs--goto))
      (with-current-buffer buffer
        (ogent-cabinet-jobs--goto agent job-id)))
    buffer))

(defun ogent-cabinet-home-edit-metadata ()
  "Visit the Cabinet index Org file for metadata edits."
  (interactive)
  (ogent-cabinet-ui--visit-path
   (ogent-cabinet-index-file ogent-cabinet-home--root)))

(defun ogent-cabinet-home-help ()
  "Show Cabinet Home keybindings and daily-work actions."
  (interactive)
  (with-help-window "*Ogent Cabinet Home Help*"
    (princ "Cabinet Home\n")
    (princ "============\n\n")
    (princ "Home is the cockpit for developing a project with Cabinet.\n\n")
    (princ "Daily work\n")
    (princ "----------\n")
    (princ "C-c j opens Jobs. C-c J opens jobs related to the item at point.\n")
    (princ "C-c r runs or retries the selected agent, job, or conversation.\n")
    (princ "C-c E edits the selected agent persona, job prompt, or source Org record.\n")
    (princ "RET opens the richer surface or durable source for the item at point.\n\n")
    (princ "Navigation\n")
    (princ "----------\n")
    (princ "C-c D Data, C-c a Agents, C-c t Tasks, C-c c Conversations, C-c S Schedule, C-c s Search, C-c A Apps, C-c h Git, C-c / Palette, C-c , Settings, C-c . Help, C-c G Graph.\n")
    (princ "C-c n and C-c p move between actionable rows. C-c g refreshes. q quits.\n")
    (princ "TAB toggles a section. M-n/M-p move between sibling sections. C-c u moves to the parent section.\n\n")
    (princ "Evil normal state keeps bare Vim navigation and exposes Cabinet actions through these chords.\n\n")
    (princ "Menus\n")
    (princ "-----\n")
    (princ "C-c m opens the Transient menu. C-c ? opens this help buffer.\n")))

(defun ogent-cabinet-home--transient-header ()
  "Return the header text for `ogent-cabinet-home-dispatch'."
  (let ((root (and (boundp 'ogent-cabinet-home--root)
                   ogent-cabinet-home--root)))
    (concat
     (propertize "Cabinet Home" 'face 'transient-heading)
     (if root
         (concat "  " (propertize (abbreviate-file-name root) 'face 'shadow))
       ""))))

;;;###autoload (autoload 'ogent-cabinet-home-dispatch "ogent-ui-cabinet" nil t)
(transient-define-prefix ogent-cabinet-home-dispatch ()
                         "Dispatch menu for Cabinet Home."
                         [:description ogent-cabinet-home--transient-header
                                       ["Daily Work"
                                        ("j" "Jobs" ogent-cabinet-jobs)
                                        ("J" "Related jobs" ogent-cabinet-home-open-jobs)
                                        ("R" "Run/retry selected" ogent-cabinet-home-run)
                                        ("E" "Edit selected" ogent-cabinet-home-edit-item)]
                                       ["Navigate"
                                        ("RET" "Visit selected" ogent-cabinet-home-visit)
                                        ("TAB" "Toggle section" ogent-cabinet-ui-toggle-section :transient t)
                                        ("M-n" "Next section" ogent-cabinet-ui-next-section :transient t)
                                        ("M-p" "Previous section" ogent-cabinet-ui-previous-section :transient t)
                                        ("^" "Up section" ogent-cabinet-ui-up-section :transient t)
                                        ("n" "Next item" ogent-cabinet-home-next-item :transient t)
                                        ("p" "Previous item" ogent-cabinet-home-previous-item :transient t)
                                        ("g" "Refresh" ogent-cabinet-home-refresh :transient t)]]
                         [["Surfaces"
                           ("D" "Data" ogent-cabinet-data)
                           ("a" "Agents" ogent-cabinet-agents)
                           ("B" "Org chart" ogent-cabinet-org-chart)
                           ("t" "Tasks" ogent-cabinet-tasks)
                           ("c" "Conversations" ogent-cabinet-conversations)
                           ("u" "Schedule" ogent-cabinet-schedule)
                           ("N" "Action approvals" ogent-cabinet-actions)
                           ("s" "Search" ogent-cabinet-search)
                           ("A" "Apps" ogent-cabinet-apps)
	                           ("h" "Git" ogent-cabinet-git-status)
	                           ("/" "Palette" ogent-cabinet-command-palette)
	                           ("," "Settings" ogent-cabinet-settings)
	                           ("." "Help" ogent-cabinet-help)
	                           ("G" "Graph" ogent-cabinet-status)]
	                          ["Cabinet"
	                           ("Q" "Agenda" ogent-cabinet-agenda)
	                           ("'" "Onboard" ogent-cabinet-onboard)
	                           ("=" "Registry import" ogent-cabinet-registry-import)
	                           ("_" "Backup" ogent-cabinet-backup)
	                           ("e" "Edit metadata" ogent-cabinet-home-edit-metadata)
	                           ("?" "Help" ogent-cabinet-home-help)
                           ("q" "Quit menu" transient-quit-one)]])

(defun ogent-cabinet-home-next-item ()
  "Move point to the next actionable Cabinet Home item."
  (interactive)
  (let ((next (ogent-cabinet-ui--visible-property-position
               'ogent-cabinet-item
               'next)))
    (when next
      (goto-char next))))

(defun ogent-cabinet-home-previous-item ()
  "Move point to the previous actionable Cabinet Home item."
  (interactive)
  (let ((previous (ogent-cabinet-ui--visible-property-position
                   'ogent-cabinet-item
                   'previous)))
    (when previous
      (goto-char previous))))

;;; Agent List

(defvar ogent-cabinet-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-agents-open-agent)
    (define-key map (kbd "<return>") #'ogent-cabinet-agents-open-agent)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-agents-open-agent)
    (define-key map "v" #'ogent-cabinet-agents-visit)
    (define-key map (kbd "C-c v") #'ogent-cabinet-agents-visit)
    (define-key map "R" #'ogent-cabinet-agents-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-agents-run)
    (define-key map "g" #'ogent-cabinet-agents-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-agents-refresh)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map (kbd "C-c t") #'ogent-cabinet-tasks)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-agents-mode'.")

(define-derived-mode ogent-cabinet-agents-mode tabulated-list-mode "Cabinet-Agents"
  "Major mode for Cabinet agent lists."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Name" 18 t)
               ("Slug" 14 t)
               ("Scope" 9 t)
               ("Dept" 14 t)
               ("Type" 10 t)
               ("Role" 18 t)
               ("Provider" 10 t)
               ("Model" 12 t)
               ("Active" 8 t)
               ("Jobs" 6 nil :right-align t)
               ("Conversations" 13 nil :right-align t)
               ("Last Run" 18 t)
               ("Workspace" 16 t)
               ("Tags" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Name" . nil))
  (setq-local revert-buffer-function #'ogent-cabinet-agents-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-agents--entries ()
  "Return tabulated entries for the current Cabinet agents buffer."
  (mapcar
   (lambda (slug)
     (let* ((agent (ogent-cabinet-resolve-agent
                    ogent-cabinet-agents--root slug :include-visible t))
            (jobs (ogent-cabinet-ui--agent-jobs ogent-cabinet-agents--root slug))
            (sessions (ogent-cabinet-ui--agent-sessions ogent-cabinet-agents--root slug))
            (last-session (ogent-cabinet-ui--last-session sessions))
            (active (if (plist-get agent :active) "yes" "no")))
       (list
        slug
        (vector
         (or (plist-get agent :display-name)
             (plist-get agent :name)
             slug)
         slug
         (symbol-name (plist-get agent :scope))
         (or (plist-get agent :department) "")
         (or (plist-get agent :type) "")
         (or (plist-get agent :role) "")
         (or (plist-get agent :provider) "")
         (or (plist-get agent :model) "")
         (propertize active
                     'face (if (plist-get agent :active)
                               'ogent-cabinet-ui-good
                             'ogent-cabinet-ui-dim))
         (number-to-string (length jobs))
         (number-to-string (length sessions))
         (or (plist-get last-session :finished) "")
         (or (plist-get agent :workspace) "")
         (ogent-cabinet-ui--format-tags (plist-get agent :tags))))))
   (ogent-cabinet-ui--agent-slugs ogent-cabinet-agents--root)))

;;;###autoload
(defun ogent-cabinet-agents (&optional directory)
  "Open a tabulated Cabinet agent list for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-agents-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-agents-mode)
      (setq ogent-cabinet-agents--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-agents--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-agents-refresh (&rest _)
  "Refresh the Cabinet agents buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-agents--slug-at-point ()
  "Return the agent slug at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet agent at point")))

(defun ogent-cabinet-agents-open-agent ()
  "Open the Cabinet agent profile at point."
  (interactive)
  (ogent-cabinet-agent
   ogent-cabinet-agents--root
   (ogent-cabinet-agents--slug-at-point)))

(defun ogent-cabinet-agents-visit ()
  "Visit the persona Org file for the Cabinet agent at point."
  (interactive)
  (let ((agent (ogent-cabinet-resolve-agent
                ogent-cabinet-agents--root
                (ogent-cabinet-agents--slug-at-point)
                :include-visible t)))
    (ogent-cabinet-ui--visit-path (plist-get agent :path))))

(defun ogent-cabinet-agents-run ()
  "Run the Cabinet agent at point with an instruction."
  (interactive)
  (let ((slug (ogent-cabinet-agents--slug-at-point)))
    (ogent-cabinet-run-agent
     ogent-cabinet-agents--root
     slug
     (read-string "Instruction: "))))

;;; Org Chart

(defvar ogent-cabinet-org-chart-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-cabinet-org-chart-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-org-chart-refresh)
    (define-key map (kbd "TAB") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-cabinet-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-cabinet-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-cabinet-ui-previous-section)
    (define-key map (kbd "^") #'ogent-cabinet-ui-up-section)
    (define-key map (kbd "C-c u") #'ogent-cabinet-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-org-chart-mode'.")

(ogent-cabinet-ui--define-section-mode
 ogent-cabinet-org-chart-mode "Cabinet-Org-Chart"
 "Major mode for Cabinet department and lead charts."
 (setq-local revert-buffer-function #'ogent-cabinet-org-chart-refresh)
 (setq-local buffer-read-only t)
 (ogent-cabinet-ui--configure-section-buffer)
 (setq header-line-format
       "C-c g refresh  TAB section  M-n/p sections  C-c u up  q quit"))

;;;###autoload
(defun ogent-cabinet-org-chart (&optional directory)
  "Open a Cabinet org chart for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   "*ogent-cabinet-org-chart: %s*" root))))
    (with-current-buffer buffer
      (ogent-cabinet-org-chart-mode)
      (setq ogent-cabinet-org-chart--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-org-chart-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-org-chart-refresh (&rest _)
  "Refresh the current Cabinet org chart."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Cabinet Org Chart" 'face 'ogent-cabinet-ui-heading)
            "\n\n")
    (dolist (group (ogent-cabinet-agents-by-department
                    ogent-cabinet-org-chart--root
                    :include-visible t))
      (let ((department (plist-get group :department))
            (lead (plist-get group :lead)))
        (ogent-cabinet-ui--with-section
         (ogent-cabinet-org-chart-department)
         (ogent-cabinet-ui--heading-text department)
         (when lead
           (insert (format "  Lead: %s (%s)\n"
                           (or (plist-get lead :display-name)
                               (plist-get lead :name)
                               (plist-get lead :slug))
                           (plist-get lead :slug))))
         (dolist (agent (plist-get group :agents))
           (insert (format "  %s  %s  %s  %s\n"
                           (plist-get agent :slug)
                           (symbol-name (plist-get agent :scope))
                           (or (plist-get agent :type) "agent")
                           (or (plist-get agent :role) "")))))
        (insert "\n")))
    (goto-char (point-min))))

;;; Single Agent Profile

(defvar ogent-cabinet-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-agent-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-agent-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-agent-visit)
    (define-key map "c" #'ogent-cabinet-agent-compose)
    (define-key map (kbd "C-c c") #'ogent-cabinet-agent-compose)
    (define-key map "e" #'ogent-cabinet-agent-edit-property)
    (define-key map (kbd "C-c e") #'ogent-cabinet-agent-edit-property)
    (define-key map "R" #'ogent-cabinet-agent-run-at-point)
    (define-key map (kbd "C-c r") #'ogent-cabinet-agent-run-at-point)
    (define-key map "v" #'ogent-cabinet-agent-visit)
    (define-key map (kbd "C-c v") #'ogent-cabinet-agent-visit)
    (define-key map "g" #'ogent-cabinet-agent-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-agent-refresh)
    (define-key map (kbd "TAB") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-cabinet-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-cabinet-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-cabinet-ui-previous-section)
    (define-key map (kbd "^") #'ogent-cabinet-ui-up-section)
    (define-key map (kbd "C-c u") #'ogent-cabinet-ui-up-section)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map (kbd "C-c t") #'ogent-cabinet-tasks)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-agent-mode'.")

(ogent-cabinet-ui--define-section-mode ogent-cabinet-agent-mode "Cabinet-Agent"
                                       "Major mode for a single Cabinet agent profile."
                                       (setq-local revert-buffer-function #'ogent-cabinet-agent-refresh)
                                       (setq-local truncate-lines t)
                                       (setq-local buffer-read-only t)
                                       (ogent-cabinet-ui--configure-section-buffer)
                                       (setq header-line-format '(:eval (ogent-cabinet-agent--header-line))))

(defun ogent-cabinet-agent--header-line ()
  "Return header text for the current Cabinet agent buffer."
  (format "C-c g refresh  RET visit  TAB section  M-n/p sections  C-c c compose  C-c e edit  C-c r run/retry  C-c t tasks  C-c s search  q quit    %s/%s"
          (or (and ogent-cabinet-agent--root
                   (ogent-cabinet-ui--root-label ogent-cabinet-agent--root))
              "?")
          (or ogent-cabinet-agent--slug "?")))

;;;###autoload
(defun ogent-cabinet-agent (&optional directory agent-slug)
  "Open a single Cabinet AGENT-SLUG profile for DIRECTORY."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (slug (ogent-cabinet-ui--read-agent root)))
     (list root slug)))
  (let* ((root (ogent-cabinet-ui--root directory))
         (slug (or agent-slug (ogent-cabinet-ui--read-agent root)))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-agent-buffer-name-format root slug))))
    (with-current-buffer buffer
      (ogent-cabinet-agent-mode)
      (setq ogent-cabinet-agent--root root)
      (setq ogent-cabinet-agent--slug slug)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-agent-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-agent-refresh (&rest _)
  "Refresh the current Cabinet agent profile."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-cabinet-agent--insert-buffer)
    (goto-char (point-min))))

(defun ogent-cabinet-agent--insert-buffer ()
  "Insert the current Cabinet agent profile."
  (ogent-cabinet-ui--with-root-section (ogent-cabinet-agent-root)
                                       (ogent-cabinet-agent--insert-buffer-content)))

(defun ogent-cabinet-agent--insert-buffer-content ()
  "Insert the current Cabinet agent profile sections."
  (let* ((root ogent-cabinet-agent--root)
         (slug ogent-cabinet-agent--slug)
         (agent (ogent-cabinet-resolve-agent
                 root slug :include-visible t))
         (jobs (ogent-cabinet-ui--agent-jobs root slug))
         (sessions (ogent-cabinet-ui--agent-sessions root slug)))
    (insert (propertize (or (plist-get agent :display-name)
                            (plist-get agent :name)
                            slug)
                        'face 'ogent-cabinet-ui-heading)
            "\n")
    (insert (propertize
             (string-join
              (delq nil
                    (list (plist-get agent :role)
                          (plist-get agent :department)
                          (symbol-name (plist-get agent :scope))))
              "  ")
             'face 'ogent-cabinet-ui-dim)
            "\n\n")
    (ogent-cabinet-ui--with-section (ogent-cabinet-agent-composer)
                                    (ogent-cabinet-ui--heading-text "Composer")
                                    (insert "  c compose instruction and run this agent\n")
                                    (insert "  R run job or session at point\n"))
    (insert "\n")
    (ogent-cabinet-agent--insert-inbox jobs)
    (ogent-cabinet-agent--insert-conversations sessions)
    (ogent-cabinet-agent--insert-recent-work sessions)
    (ogent-cabinet-agent--insert-schedule jobs)
    (ogent-cabinet-agent--insert-memory root slug)
    (ogent-cabinet-agent--insert-tools agent)
    (ogent-cabinet-agent--insert-skills agent)
    (ogent-cabinet-agent--insert-details agent)
    (ogent-cabinet-agent--insert-persona agent)))

(defun ogent-cabinet-agent--insert-inbox (jobs)
  "Insert Inbox section from JOBS."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-inbox)
                                  (ogent-cabinet-ui--heading-text "Inbox")
                                  (let ((enabled (seq-filter (lambda (job) (plist-get job :enabled)) jobs)))
                                    (if enabled
                                        (dolist (job enabled)
                                          (ogent-cabinet-ui--insert-item-line
                                           (list :type 'job
                                                 :agent (plist-get job :agent)
                                                 :job-id (plist-get job :id)
                                                 :path (ogent-cabinet-job-file
                                                        ogent-cabinet-agent--root
                                                        (plist-get job :agent)
                                                        (plist-get job :id)))
                                           (format "  TODO %s  %s"
                                                   (or (plist-get job :name) (plist-get job :id))
                                                   (or (plist-get job :cron) "manual"))))
                                      (insert (propertize "  No enabled jobs\n" 'face 'ogent-cabinet-ui-dim)))))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-conversations (sessions)
  "Insert Conversations section from SESSIONS."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-conversations)
                                  (ogent-cabinet-ui--heading-text "Conversations")
                                  (if sessions
                                      (dolist (session sessions)
                                        (ogent-cabinet-ui--insert-item-line
                                         (list :type 'session
                                               :agent (plist-get session :agent)
                                               :job-id (plist-get session :job-id)
                                               :path (plist-get session :path))
                                         (format "  %s  %s  %s"
                                                 (or (plist-get session :status) "DONE")
                                                 (or (plist-get session :name) (plist-get session :id))
                                                 (or (plist-get session :finished) ""))))
                                    (insert (propertize "  No conversations yet\n" 'face 'ogent-cabinet-ui-dim))))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-recent-work (sessions)
  "Insert Recent Work section from SESSIONS."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-recent-work)
                                  (ogent-cabinet-ui--heading-text "Recent Work")
                                  (let ((recent (seq-take sessions 5)))
                                    (if recent
                                        (dolist (session recent)
                                          (ogent-cabinet-ui--insert-item-line
                                           (list :type 'session
                                                 :agent (plist-get session :agent)
                                                 :job-id (plist-get session :job-id)
                                                 :path (plist-get session :path))
                                           (format "  %s  %s"
                                                   (or (plist-get session :status) "DONE")
                                                   (or (plist-get session :name)
                                                       (plist-get session :id)))))
                                      (insert (propertize "  No recent work\n" 'face 'ogent-cabinet-ui-dim)))))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-schedule (jobs)
  "Insert Schedule section from JOBS."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-schedule)
                                  (ogent-cabinet-ui--heading-text "Schedule")
                                  (if jobs
                                      (dolist (job jobs)
                                        (ogent-cabinet-ui--insert-item-line
                                         (list :type 'job
                                               :agent (plist-get job :agent)
                                               :job-id (plist-get job :id)
                                               :path (ogent-cabinet-job-file
                                                      ogent-cabinet-agent--root
                                                      (plist-get job :agent)
                                                      (plist-get job :id)))
                                         (format "  %s  %s  %s"
                                                 (if (plist-get job :enabled) "enabled" "disabled")
                                                 (or (plist-get job :name) (plist-get job :id))
                                                 (or (plist-get job :cron) "manual"))))
                                    (insert (propertize "  No scheduled jobs\n" 'face 'ogent-cabinet-ui-dim))))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-memory (root slug)
  "Insert Memory section for agent SLUG under ROOT."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-memory)
                                  (ogent-cabinet-ui--heading-text "Memory")
                                  (dolist (file (list (ogent-cabinet-agent-memory-file root slug "context.org")
                                                      (ogent-cabinet-agent-memory-file root slug "decisions.org")
                                                      (ogent-cabinet-agent-memory-file root slug "learnings.org")
                                                      (ogent-cabinet-agent-inbox-file root slug)
                                                      (ogent-cabinet-agent-schedule-file root slug)))
                                    (ogent-cabinet-ui--insert-item-line
                                     (list :type 'file :path file)
                                     (format "  %s" (file-relative-name file (ogent-cabinet-agent-directory
                                                                              root slug))))))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-tools (agent)
  "Insert Tools/Permissions section from AGENT."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-tools)
                                  (ogent-cabinet-ui--heading-text "Tools/Permissions")
                                  (ogent-cabinet-ui--insert-kv "Provider" (plist-get agent :provider))
                                  (ogent-cabinet-ui--insert-kv "Adapter" (plist-get agent :adapter))
                                  (ogent-cabinet-ui--insert-kv "Model" (plist-get agent :model))
                                  (ogent-cabinet-ui--insert-kv "Effort" (plist-get agent :effort))
                                  (ogent-cabinet-ui--insert-kv "Runtime" (plist-get agent :runtime-mode))
                                  (ogent-cabinet-ui--insert-kv "Budget" (plist-get agent :budget))
                                  (ogent-cabinet-ui--insert-kv "Permission" (plist-get agent :permission-mode)))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-skills (agent)
  "Insert Skills section from AGENT."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-skills)
                                  (ogent-cabinet-ui--heading-text "Skills")
                                  (ogent-cabinet-ui--insert-kv "Selected"
                                                               (string-join
                                                                (or (plist-get agent :skills) nil)
                                                                ", "))
                                  (ogent-cabinet-ui--insert-kv "Recommended"
                                                               (string-join
                                                                (or (plist-get agent :recommended-skills) nil)
                                                                ", ")))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-details (agent)
  "Insert Details section from AGENT."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-details)
                                  (ogent-cabinet-ui--heading-text "Details")
                                  (ogent-cabinet-ui--insert-kv "Slug" (plist-get agent :slug))
                                  (ogent-cabinet-ui--insert-kv "Scope" (symbol-name (plist-get agent :scope)))
                                  (ogent-cabinet-ui--insert-kv "Display" (plist-get agent :display-name))
                                  (ogent-cabinet-ui--insert-kv "Icon" (plist-get agent :icon))
                                  (ogent-cabinet-ui--insert-kv "Color" (plist-get agent :color))
                                  (ogent-cabinet-ui--insert-kv "Avatar" (plist-get agent :avatar))
                                  (ogent-cabinet-ui--insert-kv "Department" (plist-get agent :department))
                                  (ogent-cabinet-ui--insert-kv "Type" (plist-get agent :type))
                                  (ogent-cabinet-ui--insert-kv "Can Dispatch"
                                                               (if (plist-get agent :can-dispatch) "t" "nil"))
                                  (ogent-cabinet-ui--insert-kv "Role" (plist-get agent :role))
                                  (ogent-cabinet-ui--insert-kv "Provider" (plist-get agent :provider))
                                  (ogent-cabinet-ui--insert-kv "Model" (plist-get agent :model))
                                  (ogent-cabinet-ui--insert-kv "Heartbeat" (plist-get agent :heartbeat))
                                  (ogent-cabinet-ui--insert-kv "Last Heartbeat" (plist-get agent :last-heartbeat))
                                  (ogent-cabinet-ui--insert-kv "Next Heartbeat" (plist-get agent :next-heartbeat))
                                  (ogent-cabinet-ui--insert-kv "Active" (if (plist-get agent :active) "t" "nil"))
                                  (ogent-cabinet-ui--insert-kv "Setup Complete"
                                                               (if (plist-get agent :setup-complete) "t" "nil"))
                                  (ogent-cabinet-ui--insert-kv "Workspace" (plist-get agent :workspace))
                                  (ogent-cabinet-ui--insert-kv "Focus" (string-join (or (plist-get agent :focus) nil) ", "))
                                  (ogent-cabinet-ui--insert-kv "Goals" (string-join (or (plist-get agent :goals) nil) ", "))
                                  (ogent-cabinet-ui--insert-kv "Channels" (string-join (or (plist-get agent :channels) nil) ", "))
                                  (ogent-cabinet-ui--insert-kv "Tags" (string-join (or (plist-get agent :tags) nil) ", ")))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-persona (agent)
  "Insert Persona Instructions section from AGENT."
  (ogent-cabinet-ui--with-section (ogent-cabinet-agent-persona)
                                  (ogent-cabinet-ui--heading-text "Persona Instructions")
                                  (let ((body (plist-get agent :body)))
                                    (if (and body (not (string-blank-p body)))
                                        (insert body "\n")
                                      (insert (propertize "No persona instructions.\n" 'face 'ogent-cabinet-ui-dim))))))

(defun ogent-cabinet-agent-visit ()
  "Visit the Cabinet item at point or this agent's persona file."
  (interactive)
  (let* ((item (ogent-cabinet-ui--item-at-point))
         (agent (ogent-cabinet-resolve-agent
                 ogent-cabinet-agent--root
                 ogent-cabinet-agent--slug
                 :include-visible t))
         (path (or (plist-get item :path)
                   (plist-get agent :path))))
    (ogent-cabinet-ui--visit-path path)))

(defun ogent-cabinet-agent-compose ()
  "Run this Cabinet agent with an instruction."
  (interactive)
  (ogent-cabinet-run-agent
   ogent-cabinet-agent--root
   ogent-cabinet-agent--slug
   (read-string "Instruction: ")))

(defun ogent-cabinet-agent-run-at-point ()
  "Run the Cabinet job or session at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-run-job
        ogent-cabinet-agent--root
        (plist-get item :agent)
        (plist-get item :job-id)))
      ('session
       (if-let ((job-id (plist-get item :job-id)))
           (ogent-cabinet-run-job
            ogent-cabinet-agent--root
            (plist-get item :agent)
            job-id)
         (ogent-cabinet-run-agent
          ogent-cabinet-agent--root
          (plist-get item :agent)
          (read-string "Instruction: "))))
      (_
       (ogent-cabinet-agent-compose)))))

(defun ogent-cabinet-agent-edit-property ()
  "Edit one identity property in this agent's Org persona."
  (interactive)
  (let* ((agent (ogent-cabinet-resolve-agent
                 ogent-cabinet-agent--root
                 ogent-cabinet-agent--slug
                 :include-visible t))
         (file (plist-get agent :path))
         (property (completing-read
                    "Property: "
                    ogent-cabinet-agent-editable-properties
                    nil t))
         (current (with-temp-buffer
                    (insert-file-contents file)
                    (ogent-cabinet--org-mode)
                    (ogent-cabinet--first-heading-title)
                    (org-entry-get nil property)))
         (value (read-string (format "%s: " property) current)))
    (ogent-cabinet-ui--put-property file property value)
    (ogent-cabinet-agent-refresh)))

;;; Agent Management Commands

;;;###autoload
(defun ogent-cabinet-create-agent (&optional directory)
  "Create a Cabinet agent under DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (name (read-string "Name: "))
         (slug (ogent-cabinet-ui--read-string-default
                "Slug: "
                (ogent-cabinet--slug name "agent")))
         (role (ogent-cabinet-ui--read-string-default "Role: " "Agent"))
         (provider (ogent-cabinet-ui--read-string-default
                    "Provider: "
                    ogent-cabinet-default-agent-provider))
         (model (read-string "Model: "))
         (workspace (ogent-cabinet-ui--read-string-default "Workspace: " "/"))
         (tags (ogent-cabinet--tags-from-string (read-string "Tags: ")))
         (persona (read-string "Persona: ")))
    (when (file-exists-p (ogent-cabinet-agent-file root slug))
      (user-error "Agent already exists: %s" slug))
    (let ((file (ogent-cabinet-write-agent
                 root
                 (list :slug slug
                       :name name
                       :role role
                       :provider provider
                       :model model
                       :active t
                       :workspace workspace
                       :tags tags)
                 persona)))
      (ogent-cabinet-ui--refresh-home-buffer root)
      file)))

;;;###autoload
(defun ogent-cabinet-clone-agent (&optional directory agent-slug new-slug)
  "Clone AGENT-SLUG under DIRECTORY to NEW-SLUG."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (slug (ogent-cabinet-ui--read-agent root)))
     (list root slug (read-string "New slug: " (concat slug "-copy")))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (agent (copy-sequence (ogent-cabinet-read-agent root agent-slug)))
         (target (or new-slug (read-string "New slug: " (concat agent-slug "-copy")))))
    (when (file-exists-p (ogent-cabinet-agent-file root target))
      (user-error "Agent already exists: %s" target))
    (plist-put agent :slug target)
    (plist-put agent :name (format "%s Copy" (or (plist-get agent :name)
                                                 agent-slug)))
    (plist-put agent :active t)
    (plist-put agent :archived nil)
    (ogent-cabinet-write-agent root agent (plist-get agent :body))))

;;;###autoload
(defun ogent-cabinet-archive-agent (&optional directory agent-slug)
  "Deactivate and archive AGENT-SLUG under DIRECTORY."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (slug (ogent-cabinet-ui--read-agent root)))
     (list root slug)))
  (let ((root (ogent-cabinet-ui--root directory)))
    (ogent-cabinet-update-agent-property root agent-slug "OGENT_ACTIVE" "nil")
    (ogent-cabinet-update-agent-property root agent-slug "OGENT_ARCHIVED" "t")))

;;; Jobs

(defvar ogent-cabinet-jobs-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-jobs-visit))
    (define-key map "c" #'ogent-cabinet-create-job)
    (define-key map (kbd "C-c c") #'ogent-cabinet-create-job)
    (define-key map "e" #'ogent-cabinet-jobs-edit)
    (define-key map (kbd "C-c e") #'ogent-cabinet-jobs-edit)
    (define-key map "P" #'ogent-cabinet-jobs-edit-prompt)
    (define-key map (kbd "C-c p") #'ogent-cabinet-jobs-edit-prompt)
    (define-key map "R" #'ogent-cabinet-jobs-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-jobs-run)
    (define-key map "T" #'ogent-cabinet-jobs-toggle-enabled)
    (define-key map (kbd "C-c t") #'ogent-cabinet-jobs-toggle-enabled)
    (define-key map "A" #'ogent-cabinet-jobs-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-jobs-archive)
    (define-key map "g" #'ogent-cabinet-jobs-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-jobs-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-jobs-mode'.")

(define-derived-mode ogent-cabinet-jobs-mode tabulated-list-mode "Cabinet-Jobs"
  "Major mode for Cabinet jobs."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Agent" 14 t)
               ("Job" 22 t)
               ("Enabled" 8 t)
               ("Next" 18 t)
               ("Provider" 10 t)
               ("Model" 12 t)
               ("Workspace" 16 t)
               ("Tags" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Agent" . nil))
  (setq-local revert-buffer-function #'ogent-cabinet-jobs-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-job-next-run (job)
  "Return a friendly next-run description for JOB."
  (cond
   ((plist-get job :archived) "archived")
   ((not (plist-get job :enabled)) "disabled")
   ((ogent-cabinet--blank-to-nil (plist-get job :cron))
    (format "cron %s" (plist-get job :cron)))
   ((ogent-cabinet--blank-to-nil (plist-get job :run-after))
    (format "run after %s" (plist-get job :run-after)))
   ((ogent-cabinet--blank-to-nil (plist-get job :heartbeat))
    (format "heartbeat %s" (plist-get job :heartbeat)))
   (t "manual")))

(defun ogent-cabinet-jobs--entry (job)
  "Return a tabulated entry for JOB."
  (let* ((agent (plist-get job :agent))
         (job-id (plist-get job :id))
         (file (ogent-cabinet-job-file ogent-cabinet-jobs--root agent job-id)))
    (list
     (append (list :type 'job :path file :agent agent :job-id job-id) job)
     (vector
      agent
      (format "%s (%s)" (or (plist-get job :name) job-id) job-id)
      (if (plist-get job :enabled) "yes" "no")
      (ogent-cabinet-job-next-run job)
      (or (plist-get job :provider) "")
      (or (plist-get job :model) "")
      (or (plist-get job :workspace) "")
      (ogent-cabinet-ui--format-tags (plist-get job :tags))))))

(defun ogent-cabinet-jobs--entries ()
  "Return tabulated entries for the current jobs buffer."
  (mapcar #'ogent-cabinet-jobs--entry
          (ogent-cabinet-ui--all-jobs ogent-cabinet-jobs--root
                                      ogent-cabinet-jobs--agent)))

;;;###autoload
(defun ogent-cabinet-jobs (&optional directory agent)
  "Open Cabinet jobs for DIRECTORY, optionally narrowed to AGENT."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))
         nil))
  (let* ((root (ogent-cabinet-ui--root directory))
         (suffix (or agent "all"))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-jobs-buffer-name-format root suffix))))
    (with-current-buffer buffer
      (ogent-cabinet-jobs-mode)
      (setq ogent-cabinet-jobs--root root)
      (setq ogent-cabinet-jobs--agent agent)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-jobs--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-agent-jobs (&optional directory agent)
  "Open jobs for AGENT under DIRECTORY."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (slug (ogent-cabinet-ui--read-agent root)))
     (list root slug)))
  (ogent-cabinet-jobs directory agent))

(defun ogent-cabinet-jobs-refresh (&rest _)
  "Refresh the Cabinet jobs buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-jobs--goto (agent job-id)
  "Move to AGENT JOB-ID in the current jobs buffer when visible."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (let ((item (tabulated-list-get-id)))
        (when (and item
                   (equal (plist-get item :agent) agent)
                   (equal (plist-get item :job-id) job-id))
          (setq found t)))
      (unless found
        (forward-line 1)))))

(defun ogent-cabinet-jobs--item ()
  "Return the job item at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet job at point")))

(defun ogent-cabinet-jobs-visit ()
  "Visit the Org file for the job at point."
  (interactive)
  (ogent-cabinet-ui--visit-path (plist-get (ogent-cabinet-jobs--item) :path)))

(defun ogent-cabinet-jobs-run ()
  "Run the job at point."
  (interactive)
  (let ((item (ogent-cabinet-jobs--item)))
    (ogent-cabinet-run-job ogent-cabinet-jobs--root
                           (plist-get item :agent)
                           (plist-get item :job-id))))

(defun ogent-cabinet-jobs-toggle-enabled ()
  "Toggle enabled state for the job at point."
  (interactive)
  (let* ((item (ogent-cabinet-jobs--item))
         (agent (plist-get item :agent))
         (job-id (plist-get item :job-id))
         (enabled (plist-get item :enabled)))
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     agent
     job-id
     "OGENT_ENABLED"
     (if enabled "nil" "t"))
    (ogent-cabinet-jobs-refresh)
    (ogent-cabinet-jobs--goto agent job-id)))

(defun ogent-cabinet-jobs-archive ()
  "Archive the job at point."
  (interactive)
  (let ((item (ogent-cabinet-jobs--item)))
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ARCHIVED"
     "t")
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ENABLED"
     "nil")
    (ogent-cabinet-jobs-refresh)))

(defun ogent-cabinet-jobs-edit ()
  "Edit one metadata property for the job at point."
  (interactive)
  (let* ((item (ogent-cabinet-jobs--item))
         (property (completing-read "Property: "
                                    ogent-cabinet-job-editable-properties
                                    nil t))
         (value (read-string (format "%s: " property)))
         (candidate (ogent-cabinet-ui--job-with-property item property value)))
    (ogent-cabinet-validate-job candidate)
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     property
     value)
    (ogent-cabinet-jobs-refresh)))

(defun ogent-cabinet-jobs-edit-prompt ()
  "Visit the job prompt/body for the job at point."
  (interactive)
  (ogent-cabinet-ui--visit-body
   (plist-get (ogent-cabinet-jobs--item) :path)))

;;;###autoload
(defun ogent-cabinet-create-job (&optional directory agent)
  "Create a Cabinet job under DIRECTORY for AGENT."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (slug (ogent-cabinet-ui--read-agent root)))
     (list root slug)))
  (let* ((root (ogent-cabinet-ui--root directory))
         (slug (or agent (ogent-cabinet-ui--read-agent root)))
         (name (read-string "Job name: "))
         (job-id (ogent-cabinet-ui--read-string-default
                  "Job id: "
                  (ogent-cabinet--slug name "job")))
         (cron (read-string "Cron: "))
         (heartbeat (read-string "Heartbeat: "))
         (provider (read-string "Provider override: "))
         (model (read-string "Model override: "))
         (workspace (ogent-cabinet-ui--read-string-default "Workspace: " "/"))
         (tags (ogent-cabinet--tags-from-string (read-string "Tags: ")))
         (prompt (read-string "Prompt: "))
         (job (list :id job-id
                    :agent slug
                    :name name
                    :cron cron
                    :heartbeat heartbeat
                    :enabled t
                    :enabled-raw "t"
                    :provider provider
                    :model model
                    :workspace workspace
                    :tags tags)))
    (when (file-exists-p (ogent-cabinet-job-file root slug job-id))
      (user-error "Job already exists: %s" job-id))
    (ogent-cabinet-validate-job job)
    (let ((file (ogent-cabinet-write-job root slug job prompt)))
      (ogent-cabinet-ui--refresh-home-buffer root)
      file)))

;;; Tasks

(defvar ogent-cabinet-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-tasks-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-tasks-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-tasks-visit)
    (define-key map "R" #'ogent-cabinet-tasks-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-tasks-run)
    (define-key map "A" #'ogent-cabinet-tasks-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-tasks-archive)
    (define-key map "U" #'ogent-cabinet-tasks-unarchive)
    (define-key map (kbd "C-c u") #'ogent-cabinet-tasks-unarchive)
    (define-key map "b" #'ogent-cabinet-tasks-board-view)
    (define-key map (kbd "C-c b") #'ogent-cabinet-tasks-board-view)
    (define-key map "l" #'ogent-cabinet-tasks-list-view)
    (define-key map (kbd "C-c l") #'ogent-cabinet-tasks-list-view)
    (define-key map "S" #'ogent-cabinet-tasks-schedule-view)
    (define-key map (kbd "C-c S") #'ogent-cabinet-tasks-schedule-view)
    (define-key map "e" #'ogent-cabinet-tasks-edit)
    (define-key map (kbd "C-c e") #'ogent-cabinet-tasks-edit)
    (define-key map "f" #'ogent-cabinet-tasks-filter)
    (define-key map (kbd "C-c f") #'ogent-cabinet-tasks-filter)
    (define-key map "g" #'ogent-cabinet-tasks-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-tasks-refresh)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-tasks-mode'.")

(define-derived-mode ogent-cabinet-tasks-mode tabulated-list-mode "Cabinet-Tasks"
  "Major mode for Cabinet attention lanes."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Lane" 16 t)
               ("Type" 10 t)
               ("Agent" 14 t)
               ("Item" 32 t)
               ("State" 18 t)
               ("When" 24 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-tasks-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-tasks--job-item (root job)
  "Return a task item for JOB under ROOT."
  (let ((stale (ogent-cabinet-ui--stale-job-p root job))
        (scheduled (or (ogent-cabinet--blank-to-nil (plist-get job :cron))
                       (ogent-cabinet--blank-to-nil
                        (plist-get job :run-after)))))
    (list :type 'job
          :lane (cond
                 ((plist-get job :archived) "Archive")
                 ((not (plist-get job :enabled)) "Archive")
                 (stale "Needs Reply")
                 (t "Inbox"))
          :agent (plist-get job :agent)
          :job-id (plist-get job :id)
          :name (or (plist-get job :name) (plist-get job :id))
          :state (cond
                  ((plist-get job :archived) "archived")
                  ((not (plist-get job :enabled)) "disabled")
                  (stale "stale")
                  (scheduled "scheduled")
                  (t "enabled"))
          :scheduled scheduled
          :stale stale
          :when (or scheduled "manual")
          :path (ogent-cabinet-job-file
                 root
                 (plist-get job :agent)
                 (plist-get job :id)))))

(defun ogent-cabinet-tasks--session-lane (session)
  "Return the attention lane for SESSION."
  (let ((status (upcase (or (plist-get session :status) ""))))
    (cond
     ((plist-get session :archived) "Archive")
     ((equal status "RUNNING") "Running")
     ((member status '("AWAITING-INPUT" "FAILED")) "Needs Reply")
     ((not (zerop (or (plist-get session :exit-status) 0))) "Needs Reply")
     ((and (plist-get session :muted)
           (member status '("DONE" "CANCELLED")))
      "Archive")
     ((member status '("TODO" "IDLE")) "Inbox")
     (t "Just Finished"))))

(defun ogent-cabinet-tasks--session-item (session)
  "Return a task item for SESSION."
  (list :type 'session
        :lane (ogent-cabinet-tasks--session-lane session)
        :agent (plist-get session :agent)
        :job-id (plist-get session :job-id)
        :name (or (plist-get session :name) (plist-get session :id))
        :state (or (plist-get session :status) "DONE")
        :when (or (plist-get session :finished) "")
        :last-activity (or (plist-get session :last-activity)
                           (plist-get session :finished))
        :scheduled-at (plist-get session :scheduled-at)
        :scheduled-key (plist-get session :scheduled-key)
        :board-order (plist-get session :board-order)
        :muted (plist-get session :muted)
        :path (plist-get session :path)))

(defun ogent-cabinet-tasks--running-items (root)
  "Return live runner task items under ROOT."
  (delq
   nil
   (mapcar
    (lambda (slug)
      (when (ogent-cabinet-runner-running-p slug)
        (list :type 'agent
              :lane "Running"
              :agent slug
              :name slug
              :state "running"
              :when ""
              :path (ogent-cabinet-agent-file root slug))))
    (ogent-cabinet-ui--agent-slugs root))))

(defun ogent-cabinet-tasks--items ()
  "Return task items for the current Cabinet task buffer."
  (let ((root ogent-cabinet-tasks--root)
        items)
    (dolist (slug (ogent-cabinet-ui--agent-slugs root))
      (dolist (job (ogent-cabinet-ui--agent-jobs root slug))
        (push (ogent-cabinet-tasks--job-item root job) items)))
    (dolist (session (ogent-cabinet-ui--all-sessions root))
      (push (ogent-cabinet-tasks--session-item session) items))
    (setq items (append (ogent-cabinet-tasks--running-items root) items))
    (let ((filters ogent-cabinet-tasks--filters))
      (setq items
            (seq-filter
             (lambda (item)
               (and (or (null (plist-get filters :agent))
                        (equal (plist-get item :agent)
                               (plist-get filters :agent)))
                    (or (null (plist-get filters :status))
                        (equal (plist-get item :state)
                               (plist-get filters :status)))))
             items)))
    (ogent-cabinet-tasks--sort-items (nreverse items))))

(defun ogent-cabinet-tasks--item-time (item)
  "Return the best sortable timestamp for ITEM."
  (or (plist-get item :scheduled-at)
      (plist-get item :last-activity)
      (plist-get item :when)
      ""))

(defun ogent-cabinet-tasks--item-less-p (left right)
  "Return non-nil when LEFT should sort before RIGHT."
  (let ((left-order (plist-get left :board-order))
        (right-order (plist-get right :board-order)))
    (cond
     ((and left-order right-order (not (= left-order right-order)))
      (< left-order right-order))
     (left-order t)
     (right-order nil)
     ((not (equal (ogent-cabinet-tasks--item-time left)
                  (ogent-cabinet-tasks--item-time right)))
      (string> (ogent-cabinet-tasks--item-time left)
               (ogent-cabinet-tasks--item-time right)))
     (t
      (string< (or (plist-get left :name) "")
               (or (plist-get right :name) ""))))))

(defun ogent-cabinet-tasks--sort-items (items)
  "Return ITEMS in task-board display order."
  (seq-sort #'ogent-cabinet-tasks--item-less-p items))

(defun ogent-cabinet-tasks--scheduled-item-p (item)
  "Return non-nil when ITEM has scheduling metadata."
  (or (ogent-cabinet--blank-to-nil (plist-get item :scheduled))
      (ogent-cabinet--blank-to-nil (plist-get item :scheduled-at))
      (ogent-cabinet--blank-to-nil (plist-get item :scheduled-key))))

(defun ogent-cabinet-tasks--entry (item)
  "Return a tabulated list entry for ITEM."
  (list
   item
   (vector
    (or (plist-get item :lane) "")
    (symbol-name (plist-get item :type))
    (or (plist-get item :agent) "")
    (or (plist-get item :name) "")
    (or (plist-get item :state) "")
    (or (plist-get item :when) ""))))

(defun ogent-cabinet-tasks--entries ()
  "Return tabulated list entries for the current Cabinet task buffer."
  (let ((items (ogent-cabinet-tasks--items)))
    (pcase ogent-cabinet-tasks--view
      ('list
       (mapcar #'ogent-cabinet-tasks--entry items))
      ('schedule
       (mapcar #'ogent-cabinet-tasks--entry
               (seq-filter #'ogent-cabinet-tasks--scheduled-item-p items)))
      (_
       (apply
        #'append
        (mapcar
         (lambda (lane)
           (let ((lane-items (seq-filter
                              (lambda (item)
                                (equal (plist-get item :lane) lane))
                              items)))
             (if lane-items
                 (mapcar #'ogent-cabinet-tasks--entry
                         (ogent-cabinet-tasks--sort-items lane-items))
               (list (ogent-cabinet-tasks--entry
                      (list :type 'empty
                            :lane lane
                            :agent ""
                            :name "(empty)"
                            :state ""
                            :when ""))))))
         ogent-cabinet-task-lanes))))))

;;;###autoload
(defun ogent-cabinet-tasks (&optional directory)
  "Open Cabinet attention lanes for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-tasks-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-tasks-mode)
      (setq ogent-cabinet-tasks--root root)
      (setq ogent-cabinet-tasks--filters nil)
      (setq ogent-cabinet-tasks--view 'board)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-tasks--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-tasks-refresh (&rest _)
  "Refresh the Cabinet task lane buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-tasks-board-view ()
  "Show Cabinet tasks as attention lanes."
  (interactive)
  (setq ogent-cabinet-tasks--view 'board)
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-list-view ()
  "Show Cabinet tasks as a flat list."
  (interactive)
  (setq ogent-cabinet-tasks--view 'list)
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-schedule-view ()
  "Show Cabinet tasks with scheduling metadata."
  (interactive)
  (setq ogent-cabinet-tasks--view 'schedule)
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-visit ()
  "Visit the Cabinet task item at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (when (eq (plist-get item :type) 'empty)
      (user-error "No Cabinet task at point"))
    (ogent-cabinet-ui--visit-path (plist-get item :path))))

(defun ogent-cabinet-tasks-run ()
  "Run or retry the Cabinet task at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-run-job
        ogent-cabinet-tasks--root
        (plist-get item :agent)
        (plist-get item :job-id)))
      ('session
       (if-let ((job-id (plist-get item :job-id)))
           (ogent-cabinet-run-job
            ogent-cabinet-tasks--root
            (plist-get item :agent)
            job-id)
         (ogent-cabinet-run-agent
          ogent-cabinet-tasks--root
          (plist-get item :agent)
          (read-string "Instruction: "))))
      (_
       (user-error "No runnable Cabinet task at point")))))

(defun ogent-cabinet-tasks-archive ()
  "Archive the Cabinet task at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-ui--put-property
        (plist-get item :path)
        "OGENT_ENABLED"
        "nil"))
      ('session
       (ogent-cabinet-ui--put-property
        (plist-get item :path)
        "OGENT_ARCHIVED"
        "t"))
      (_
       (user-error "No archivable Cabinet task at point"))))
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-unarchive ()
  "Unarchive the Cabinet task at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil")
       (ogent-cabinet-ui--put-property (plist-get item :path) "OGENT_ENABLED" "t"))
      ('session
       (ogent-cabinet-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil"))
      (_
       (user-error "No archived Cabinet task at point"))))
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-edit ()
  "Edit metadata for the Cabinet task at point."
  (interactive)
  (let* ((item (ogent-cabinet-ui--item-at-point))
         (property (pcase (plist-get item :type)
                     ('job (completing-read "Property: "
                                            ogent-cabinet-job-editable-properties
                                            nil t))
                     ('session (completing-read "Property: "
                                                '("OGENT_ARCHIVED" "OGENT_TAGS")
                                                nil t))
                     (_ (user-error "No editable Cabinet task at point"))))
         (value (read-string (format "%s: " property))))
    (when (eq (plist-get item :type) 'job)
      (ogent-cabinet-validate-job
       (ogent-cabinet-ui--job-with-property item property value)))
    (ogent-cabinet-ui--put-property (plist-get item :path) property value)
    (ogent-cabinet-tasks-refresh)))

(defun ogent-cabinet-tasks-filter ()
  "Set simple task board filters."
  (interactive)
  (setq ogent-cabinet-tasks--filters
        (list :agent (ogent-cabinet--blank-to-nil
                      (read-string "Agent filter: "))
              :status (ogent-cabinet--blank-to-nil
                       (read-string "Status filter: "))))
  (ogent-cabinet-tasks-refresh))

;;; Conversations

(defvar ogent-cabinet-conversations-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-conversations-open))
    (define-key map "R" #'ogent-cabinet-conversations-retry)
    (define-key map (kbd "C-c r") #'ogent-cabinet-conversations-retry)
    (define-key map "A" #'ogent-cabinet-conversations-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-conversations-archive)
    (define-key map "U" #'ogent-cabinet-conversations-unarchive)
    (define-key map (kbd "C-c u") #'ogent-cabinet-conversations-unarchive)
    (define-key map "v" #'ogent-cabinet-conversations-visit-source)
    (define-key map (kbd "C-c v") #'ogent-cabinet-conversations-visit-source)
    (define-key map "s" #'ogent-cabinet-conversations-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-conversations-search)
    (define-key map "f" #'ogent-cabinet-conversations-filter)
    (define-key map (kbd "C-c f") #'ogent-cabinet-conversations-filter)
    (define-key map "g" #'ogent-cabinet-conversations-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-conversations-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-conversations-mode'.")

(define-derived-mode ogent-cabinet-conversations-mode tabulated-list-mode
  "Cabinet-Conversations"
  "Major mode for Cabinet conversation lists."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Status" 10 t)
               ("Agent" 14 t)
               ("Job" 18 t)
               ("Conversation" 28 t)
               ("Provider" 10 t)
               ("Model" 12 t)
               ("Duration" 10 t)
               ("Finished" 22 t)
               ("Archived" 8 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Finished" . t))
  (setq-local revert-buffer-function #'ogent-cabinet-conversations-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-conversations--matches-p (session)
  "Return non-nil when SESSION matches current filters."
  (let ((filters ogent-cabinet-conversations--filters))
    (and (or (null (plist-get filters :agent))
             (equal (plist-get session :agent) (plist-get filters :agent)))
         (or (null (plist-get filters :job-id))
             (equal (plist-get session :job-id) (plist-get filters :job-id)))
         (or (null (plist-get filters :status))
             (equal (plist-get session :status) (plist-get filters :status)))
         (or (null (plist-get filters :provider))
             (equal (plist-get session :provider) (plist-get filters :provider)))
         (or (null (plist-get filters :model))
             (equal (plist-get session :model) (plist-get filters :model)))
         (or (null (plist-get filters :tag))
             (member (plist-get filters :tag) (plist-get session :tags)))
         (or (null (plist-get filters :archived))
             (eq (plist-get session :archived)
                 (ogent-cabinet--truth-value (plist-get filters :archived)))))))

(defun ogent-cabinet-conversations--entry (session)
  "Return tabulated entry for SESSION."
  (list
   (append (list :type 'session) session)
   (vector
    (or (plist-get session :status) "")
    (or (plist-get session :agent) "")
    (or (plist-get session :job-id) "")
    (or (plist-get session :name) (plist-get session :id))
    (or (plist-get session :provider) "")
    (or (plist-get session :model) "")
    (or (plist-get session :duration) "")
    (or (plist-get session :finished) "")
    (if (plist-get session :archived) "yes" "no"))))

(defun ogent-cabinet-conversations--entries ()
  "Return conversation entries for the current buffer."
  (let* ((sessions (ogent-cabinet-ui--all-sessions
                    ogent-cabinet-conversations--root))
         (matches (seq-filter #'ogent-cabinet-conversations--matches-p
                              sessions)))
    (if matches
        (mapcar #'ogent-cabinet-conversations--entry matches)
      (list
       (list nil
             (vector "" "" ""
                     (if sessions
                         "No conversations match filters"
                       "No conversations yet")
                     "" "" "" "" ""))))))

;;;###autoload
(defun ogent-cabinet-conversations (&optional directory filters)
  "Open Cabinet conversations for DIRECTORY with optional FILTERS."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))
         nil))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-conversations-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-conversations-mode)
      (setq ogent-cabinet-conversations--root root)
      (setq ogent-cabinet-conversations--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-conversations--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-conversations-refresh (&rest _)
  "Refresh the Cabinet conversations buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-conversations--item ()
  "Return the conversation at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet conversation at point")))

(defun ogent-cabinet-conversations-open ()
  "Open the conversation at point."
  (interactive)
  (ogent-cabinet-conversation
   ogent-cabinet-conversations--root
   (plist-get (ogent-cabinet-conversations--item) :path)))

(defun ogent-cabinet-conversations-visit-source ()
  "Visit the Org source file for the conversation at point."
  (interactive)
  (ogent-cabinet-ui--visit-path
   (plist-get (ogent-cabinet-conversations--item) :path)))

(defun ogent-cabinet-conversations-retry ()
  "Retry the conversation at point when it links to a job."
  (interactive)
  (let ((item (ogent-cabinet-conversations--item)))
    (if-let ((job-id (plist-get item :job-id)))
        (ogent-cabinet-run-job ogent-cabinet-conversations--root
                               (plist-get item :agent)
                               job-id)
      (ogent-cabinet-run-agent ogent-cabinet-conversations--root
                               (plist-get item :agent)
                               (read-string "Instruction: ")))))

(defun ogent-cabinet-conversations-archive ()
  "Archive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-cabinet-conversations--item) :path)))
    (ogent-cabinet-ui--conversation-update-properties
     ogent-cabinet-conversations--root path
     '(("OGENT_ARCHIVED" . "t")
       ("OGENT_STATUS" . "archived"))
     "conversation.archived"))
  (ogent-cabinet-conversations-refresh))

(defun ogent-cabinet-conversations-unarchive ()
  "Unarchive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-cabinet-conversations--item) :path)))
    (ogent-cabinet-ui--conversation-update-properties
     ogent-cabinet-conversations--root path
     '(("OGENT_ARCHIVED" . "nil")
       ("OGENT_STATUS" . "done"))
     "conversation.unarchived"))
  (ogent-cabinet-conversations-refresh))

(defun ogent-cabinet-conversations-filter ()
  "Set simple conversation filters."
  (interactive)
  (setq ogent-cabinet-conversations--filters
        (list :agent (ogent-cabinet--blank-to-nil
                      (read-string "Agent filter: "))
              :status (ogent-cabinet--blank-to-nil
                       (read-string "Status filter: "))
              :tag (ogent-cabinet--blank-to-nil
                    (read-string "Tag filter: "))))
  (ogent-cabinet-conversations-refresh))

(defun ogent-cabinet-conversations-search ()
  "Search within Cabinet conversations."
  (interactive)
  (ogent-cabinet-search ogent-cabinet-conversations--root
                        (read-string "Search conversations: ")
                        (list :kind 'session)))

(defvar ogent-cabinet-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>" "v"))
      (define-key map (kbd key) #'ogent-cabinet-conversation-visit-source))
    (define-key map (kbd "C-c v") #'ogent-cabinet-conversation-visit-source)
    (define-key map "c" #'ogent-cabinet-conversation-continue)
    (define-key map (kbd "C-c c") #'ogent-cabinet-conversation-continue)
    (define-key map "k" #'ogent-cabinet-conversation-stop)
    (define-key map (kbd "C-c k") #'ogent-cabinet-conversation-stop)
    (define-key map "R" #'ogent-cabinet-conversation-retry)
    (define-key map (kbd "C-c r") #'ogent-cabinet-conversation-retry)
    (define-key map "d" #'ogent-cabinet-conversation-mark-done)
    (define-key map (kbd "C-c d") #'ogent-cabinet-conversation-mark-done)
    (define-key map "A" #'ogent-cabinet-conversation-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-conversation-archive)
    (define-key map "U" #'ogent-cabinet-conversation-unarchive)
    (define-key map (kbd "C-c u") #'ogent-cabinet-conversation-unarchive)
    (define-key map "m" #'ogent-cabinet-conversation-mute)
    (define-key map (kbd "C-c m") #'ogent-cabinet-conversation-mute)
    (define-key map "M" #'ogent-cabinet-conversation-unmute)
    (define-key map (kbd "C-c M") #'ogent-cabinet-conversation-unmute)
    (define-key map "C" #'ogent-cabinet-conversation-compact)
    (define-key map (kbd "C-c C") #'ogent-cabinet-conversation-compact)
    (define-key map "D" #'ogent-cabinet-conversation-delete)
    (define-key map (kbd "C-c D") #'ogent-cabinet-conversation-delete)
    (define-key map "y" #'ogent-cabinet-conversation-copy-link)
    (define-key map (kbd "C-c y") #'ogent-cabinet-conversation-copy-link)
    (define-key map "o" #'ogent-cabinet-conversation-open-artifacts)
    (define-key map (kbd "C-c o") #'ogent-cabinet-conversation-open-artifacts)
    (define-key map "l" #'ogent-cabinet-conversation-open-logs)
    (define-key map (kbd "C-c l") #'ogent-cabinet-conversation-open-logs)
    (define-key map "g" #'ogent-cabinet-conversation-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-conversation-refresh)
    (define-key map (kbd "TAB") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-cabinet-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-cabinet-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-cabinet-ui-previous-section)
    (define-key map (kbd "^") #'ogent-cabinet-ui-up-section)
    (define-key map (kbd "C-c U") #'ogent-cabinet-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-conversation-mode'.")

(ogent-cabinet-ui--define-section-mode ogent-cabinet-conversation-mode
                                       "Cabinet-Conversation"
                                       "Major mode for a single Cabinet conversation."
                                       (setq-local revert-buffer-function #'ogent-cabinet-conversation-refresh)
                                       (setq-local truncate-lines nil)
                                       (setq-local buffer-read-only t)
                                       (ogent-cabinet-ui--configure-section-buffer)
                                       (setq header-line-format
                                             "RET source  C-c g refresh  C-c r retry  C-c c continue  C-c o artifacts  C-c l logs  TAB fold"))

;;;###autoload
(defun ogent-cabinet-conversation (&optional directory file)
  "Open Cabinet conversation FILE under DIRECTORY."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (session (completing-read
                    "Conversation: "
                    (mapcar (lambda (item)
                              (plist-get item :path))
                            (ogent-cabinet-ui--all-sessions root))
                    nil t)))
     (list root session)))
  (let* ((root (ogent-cabinet-ui--root directory))
         (raw-path (or file (plist-get (ogent-cabinet-conversations--item) :path)))
         (path (if (and raw-path (file-exists-p raw-path))
                   (file-truename raw-path)
                 raw-path))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-conversation-buffer-name-format
                   root
                   (file-name-base path)))))
    (with-current-buffer buffer
      (ogent-cabinet-conversation-mode)
      (setq ogent-cabinet-conversation--root root)
      (setq ogent-cabinet-conversation--file path)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-conversation-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-conversation-refresh (&rest _)
  "Refresh this conversation detail buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-cabinet-conversation--insert-buffer)
    (goto-char (point-min))))

(defun ogent-cabinet-conversation--insert-buffer ()
  "Insert the current conversation detail."
  (ogent-cabinet-ui--with-root-section (ogent-cabinet-conversation-root)
                                       (ogent-cabinet-conversation--insert-buffer-content)))

(defun ogent-cabinet-conversation--insert-overview (detail)
  "Insert compact run overview for DETAIL."
  (let ((parts (delq nil
                     (list
                      (plist-get detail :status)
                      (plist-get detail :agent)
                      (plist-get detail :job-id)
                      (plist-get detail :provider)
                      (plist-get detail :model)
                      (plist-get detail :duration)
                      (plist-get detail :finished)))))
    (when parts
      (insert (propertize (string-join parts "  ")
                          'face 'ogent-cabinet-ui-dim)
              "\n"))))

(defun ogent-cabinet-conversation--insert-details (detail)
  "Insert detailed metadata for DETAIL."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-metadata)
                                  (ogent-cabinet-ui--heading-text "Details")
                                  (ogent-cabinet-ui--insert-kv "Status" (plist-get detail :status))
                                  (ogent-cabinet-ui--insert-kv "Agent" (plist-get detail :agent))
                                  (ogent-cabinet-ui--insert-kv "Job" (plist-get detail :job-id))
                                  (ogent-cabinet-ui--insert-kv "Trigger" (plist-get detail :trigger))
                                  (ogent-cabinet-ui--insert-kv "Provider" (plist-get detail :provider))
                                  (ogent-cabinet-ui--insert-kv "Model" (plist-get detail :model))
                                  (ogent-cabinet-ui--insert-kv
                                   "Exit status"
                                   (when (plist-get detail :exit-status)
                                     (number-to-string
                                      (plist-get detail :exit-status))))
                                  (ogent-cabinet-ui--insert-kv "Duration" (plist-get detail :duration))
                                  (ogent-cabinet-ui--insert-kv "Started" (plist-get detail :started))
                                  (ogent-cabinet-ui--insert-kv "Finished" (plist-get detail :finished))
                                  (ogent-cabinet-ui--insert-kv "Last activity"
                                                               (plist-get detail :last-activity))
                                  (ogent-cabinet-ui--insert-kv "Archived"
                                                               (if (plist-get detail :archived) "yes" "no"))
                                  (ogent-cabinet-ui--insert-kv "Muted"
                                                               (if (plist-get detail :muted) "yes" "no"))))

(defun ogent-cabinet-conversation--insert-turns (turns)
  "Insert conversation TURNS."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-turns)
                                  (ogent-cabinet-ui--heading-text "Turns")
                                  (if turns
                                      (dolist (turn turns)
                                        (insert
                                         (propertize
                                          (format "  %03d %s %s\n"
                                                  (or (plist-get turn :turn) 0)
                                                  (upcase (or (plist-get turn :role) "turn"))
                                                  (or (plist-get turn :ts) ""))
                                          'face 'ogent-cabinet-ui-dim))
                                        (when-let ((tokens (plist-get turn :tokens)))
                                          (insert
                                           (format "  tokens input=%s output=%s cache=%s\n"
                                                   (or (plist-get tokens :input) "")
                                                   (or (plist-get tokens :output) "")
                                                   (or (plist-get tokens :cache) ""))))
                                        (insert (string-trim-right (or (plist-get turn :content) "")) "\n\n"))
                                    (insert (propertize "  No turn files recorded\n"
                                                        'face 'ogent-cabinet-ui-dim)))))

(defun ogent-cabinet-conversation--insert-artifacts (root detail)
  "Insert artifacts listed by DETAIL under ROOT."
  (let ((artifacts (ogent-cabinet-ui--conversation-artifacts detail)))
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-artifacts)
                                    (ogent-cabinet-ui--heading-text "Artifacts")
                                    (if artifacts
                                        (dolist (artifact artifacts)
                                          (let ((path (ogent-cabinet-ui--artifact-path root artifact)))
                                            (ogent-cabinet-ui--insert-item-line
                                             (list :type 'artifact :path path)
                                             (format "  %s" artifact))))
                                      (insert (propertize "  No artifacts recorded\n"
                                                          'face 'ogent-cabinet-ui-dim))))))

(defun ogent-cabinet-conversation--insert-events (events)
  "Insert conversation EVENTS."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-events)
                                  (ogent-cabinet-ui--heading-text "Events")
                                  (if events
                                      (dolist (event events)
                                        (insert
                                         (format "  %06d %-24s %s\n"
                                                 (or (plist-get event :seq) 0)
                                                 (or (plist-get event :type) "")
                                                 (or (plist-get event :ts) "")))
                                        (when-let ((payload (ogent-cabinet--blank-to-nil
                                                             (plist-get event :payload))))
                                          (insert "  " (string-trim payload) "\n")))
                                    (insert (propertize "  No events recorded\n"
                                                        'face 'ogent-cabinet-ui-dim)))))

(defun ogent-cabinet-conversation--insert-runtime (detail)
  "Insert runtime metadata for DETAIL."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-runtime)
                                  (ogent-cabinet-ui--heading-text "Runtime")
                                  (ogent-cabinet-ui--insert-kv "Adapter" (plist-get detail :adapter))
                                  (ogent-cabinet-ui--insert-kv "Runtime" (plist-get detail :runtime-mode))
                                  (ogent-cabinet-ui--insert-kv "Effort" (plist-get detail :effort))
                                  (ogent-cabinet-ui--insert-kv "Context" (plist-get detail :context-window))
                                  (ogent-cabinet-ui--insert-kv "Resume" (plist-get detail :last-resume-result))
                                  (when (or (plist-get detail :tokens-input)
                                            (plist-get detail :tokens-output)
                                            (plist-get detail :tokens-cache)
                                            (plist-get detail :tokens-total))
                                    (ogent-cabinet-ui--insert-kv
                                     "Tokens"
                                     (format "input=%s output=%s cache=%s total=%s"
                                             (or (plist-get detail :tokens-input) "")
                                             (or (plist-get detail :tokens-output) "")
                                             (or (plist-get detail :tokens-cache) "")
                                             (or (plist-get detail :tokens-total) ""))))))

(defun ogent-cabinet-conversation--runtime-present-p (detail)
  "Return non-nil when DETAIL has runtime fields worth showing."
  (seq-some
   (lambda (key)
     (plist-get detail key))
   '(:adapter
     :runtime-mode
     :effort
     :context-window
     :last-resume-result
     :tokens-input
     :tokens-output
     :tokens-cache
     :tokens-total)))

(defun ogent-cabinet-conversation--insert-runtime-trace (trace)
  "Insert runtime TRACE as a preview."
  (when (ogent-cabinet--blank-to-nil trace)
    (let* ((preview (ogent-cabinet-ui--preview-lines
                     trace
                     ogent-cabinet-conversation-runtime-trace-preview-lines))
           (hidden (plist-get preview :hidden)))
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-runtime-trace)
                                      (ogent-cabinet-ui--heading-text "Runtime Trace")
                                      (ogent-cabinet-ui--insert-readable-text
                                       (plist-get preview :text)
                                       "  No runtime trace recorded\n")
                                      (when (> hidden 0)
                                        (insert
                                         (propertize
                                          (format "  %d more lines. Press l for logs or v for source Org.\n"
                                                  hidden)
                                          'face 'ogent-cabinet-ui-dim)))))))

(defun ogent-cabinet-conversation--insert-buffer-content ()
  "Insert the current conversation detail sections."
  (let ((detail (ogent-cabinet-ui--conversation-detail
                 ogent-cabinet-conversation--root
                 ogent-cabinet-conversation--file)))
    (insert (propertize (or (plist-get detail :name)
                            (plist-get detail :id))
                        'face 'ogent-cabinet-ui-heading)
            "\n")
    (ogent-cabinet-conversation--insert-overview detail)
    (when (plist-get detail :awaiting-input)
      (insert (propertize "Awaiting user input\n"
                          'face 'ogent-cabinet-ui-warning)))
    (insert "\n")
    (when (or (plist-get detail :summary)
              (plist-get detail :context-summary))
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-summary)
                                      (ogent-cabinet-ui--heading-text "Summary")
                                      (when-let ((summary (plist-get detail :summary)))
                                        (insert summary "\n"))
                                      (when-let ((context (plist-get detail :context-summary)))
                                        (insert "\nContext\n" context "\n")))
      (insert "\n"))
    (when (plist-get detail :turns)
      (ogent-cabinet-conversation--insert-turns (plist-get detail :turns))
      (insert "\n"))
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-output)
                                    (ogent-cabinet-ui--heading-text "Output")
                                    (ogent-cabinet-ui--insert-readable-text
                                     (plist-get detail :output)
                                     "  No output recorded\n"))
    (insert "\n")
    (ogent-cabinet-conversation--insert-artifacts
     ogent-cabinet-conversation--root detail)
    (insert "\n")
    (ogent-cabinet-conversation--insert-details detail)
    (insert "\n")
    (when (ogent-cabinet-conversation--runtime-present-p detail)
      (ogent-cabinet-conversation--insert-runtime detail)
      (insert "\n"))
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-prompt)
                                    (ogent-cabinet-ui--heading-text "Prompt")
                                    (ogent-cabinet-ui--insert-readable-text
                                     (plist-get detail :prompt)
                                     "  No prompt recorded\n"))
    (insert "\n")
    (when (plist-get detail :tools)
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-tools)
                                      (ogent-cabinet-ui--heading-text "Tool Blocks")
                                      (dolist (tool (plist-get detail :tools))
                                        (insert (format "  %s\n%s\n" (plist-get tool :header)
                                                        (plist-get tool :body)))))
      (insert "\n"))
    (when (ogent-cabinet--blank-to-nil (plist-get detail :error))
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-error)
                                      (ogent-cabinet-ui--heading-text "Error")
                                      (ogent-cabinet-ui--insert-readable-text
                                       (plist-get detail :error)
                                       "  No error recorded\n"))
      (insert "\n"))
    (ogent-cabinet-conversation--insert-runtime-trace
     (plist-get detail :runtime-trace))
    (when (ogent-cabinet--blank-to-nil (plist-get detail :runtime-trace))
      (insert "\n"))
    (ogent-cabinet-conversation--insert-events (plist-get detail :events))
    (insert "\n")
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-source)
                                    (ogent-cabinet-ui--heading-text "Source Org")
                                    (ogent-cabinet-ui--insert-item-line
                                     (list :type 'file :path (plist-get detail :path))
                                     (format "  %s" (plist-get detail :path))))))

(defun ogent-cabinet-conversation-visit-source ()
  "Visit the Org source for this conversation."
  (interactive)
  (ogent-cabinet-ui--visit-path ogent-cabinet-conversation--file))

(defun ogent-cabinet-conversation--detail ()
  "Return detail for the current conversation buffer."
  (ogent-cabinet-ui--conversation-detail
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file))

(defun ogent-cabinet-conversation--canonical-id ()
  "Return current canonical conversation id or nil."
  (when (ogent-cabinet-ui--canonical-conversation-path-p
         ogent-cabinet-conversation--file)
    (ogent-cabinet-ui--canonical-conversation-id
     ogent-cabinet-conversation--file)))

(defun ogent-cabinet-conversation-continue (instruction)
  "Continue this conversation with INSTRUCTION."
  (interactive (list (read-string "Continue: ")))
  (let* ((detail (ogent-cabinet-conversation--detail))
         (agent (plist-get detail :agent))
         (job-id (plist-get detail :job-id))
         (conversation-id (ogent-cabinet-conversation--canonical-id)))
    (unless agent
      (user-error "Conversation has no agent"))
    (if conversation-id
        (let* ((replay
                (ogent-cabinet-conversation-replay-prompt
                 ogent-cabinet-conversation--root conversation-id instruction))
               (keywords
                (append
                 (when job-id (list :job-id job-id))
                 (list :instruction replay
                       :conversation-id conversation-id
                       :conversation-title (plist-get detail :name)
                       :turn-content instruction
                       :trigger "manual"
                       :last-resume-result "replay")))
               (plan (apply #'ogent-cabinet-runner-plan
                            ogent-cabinet-conversation--root
                            agent
                            keywords)))
          (when (ogent-cabinet-runner--confirm plan)
            (ogent-cabinet-runner-start plan)
            (ogent-cabinet-conversation-refresh)))
      (ogent-cabinet-run-agent
       ogent-cabinet-conversation--root agent instruction))))

(defun ogent-cabinet-conversation-stop ()
  "Stop this conversation when it has a live process."
  (interactive)
  (let ((conversation-id (ogent-cabinet-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be stopped"))
    (unless (ogent-cabinet-runner-stop-conversation
             ogent-cabinet-conversation--root conversation-id)
      (user-error "No live process for conversation %s" conversation-id)))
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-retry ()
  "Retry this conversation."
  (interactive)
  (let ((detail (ogent-cabinet-conversation--detail)))
    (if-let ((job-id (plist-get detail :job-id)))
        (ogent-cabinet-run-job ogent-cabinet-conversation--root
                               (plist-get detail :agent)
                               job-id)
      (ogent-cabinet-run-agent ogent-cabinet-conversation--root
                               (plist-get detail :agent)
                               (read-string "Instruction: ")))))

(defun ogent-cabinet-conversation-mark-done ()
  "Mark this conversation done."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   `(("OGENT_STATUS" . "done")
     ("OGENT_AWAITING_INPUT" . "nil")
     ("OGENT_EXIT_CODE" . "0")
     ("OGENT_COMPLETED_AT" . ,(ogent-cabinet-ui--iso-now)))
   "conversation.marked_done")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-archive ()
  "Archive this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_ARCHIVED" . "t")
     ("OGENT_STATUS" . "archived"))
   "conversation.archived")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-unarchive ()
  "Unarchive this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_ARCHIVED" . "nil")
     ("OGENT_STATUS" . "done"))
   "conversation.unarchived")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-mute ()
  "Mute this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_MUTED" . "t"))
   "conversation.muted")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-unmute ()
  "Unmute this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_MUTED" . "nil"))
   "conversation.unmuted")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-compact (&optional summary)
  "Compact this canonical conversation with optional SUMMARY."
  (interactive)
  (let ((conversation-id (ogent-cabinet-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be compacted"))
    (ogent-cabinet-conversation-compact-record
     ogent-cabinet-conversation--root
     conversation-id
     summary))
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-delete (&optional force)
  "Delete this conversation.
With FORCE, skip confirmation."
  (interactive "P")
  (let ((path ogent-cabinet-conversation--file)
        (buffer (current-buffer)))
    (when (or force
              (yes-or-no-p
               (format "Delete Cabinet conversation %s? "
                       (abbreviate-file-name path))))
      (if (ogent-cabinet-ui--canonical-conversation-path-p path)
          (delete-directory (file-name-directory path) t)
        (delete-file path))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-cabinet-conversation-copy-link ()
  "Copy a stable link to this conversation."
  (interactive)
  (let ((link (if-let ((conversation-id
                        (ogent-cabinet-conversation--canonical-id)))
                  (format "ogent-cabinet:%s" conversation-id)
                ogent-cabinet-conversation--file)))
    (kill-new link)
    (message "Copied %s" link)))

(defun ogent-cabinet-conversation-open-artifacts ()
  "Open the first artifact declared by this conversation."
  (interactive)
  (let* ((detail (ogent-cabinet-conversation--detail))
         (artifact (car (ogent-cabinet-ui--conversation-artifacts detail)))
         (path (ogent-cabinet-ui--artifact-path
                ogent-cabinet-conversation--root artifact)))
    (unless (and path (file-exists-p path))
      (user-error "No artifact path recorded for this conversation"))
    (cond
     ((and (file-directory-p path)
           (file-exists-p (expand-file-name "index.html" path)))
      (browse-url-of-file (expand-file-name "index.html" path)))
     ((string-suffix-p ".html" path t)
      (browse-url-of-file path))
     (t
      (find-file path)))))

(defun ogent-cabinet-conversation-open-logs ()
  "Open the event log for this conversation."
  (interactive)
  (if-let ((conversation-id (ogent-cabinet-conversation--canonical-id)))
      (find-file
       (ogent-cabinet-conversation-events-file
        ogent-cabinet-conversation--root conversation-id))
    (ogent-cabinet-conversation-visit-source)))

;;; Search

(defvar ogent-cabinet-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-search-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-search-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-search-visit)
    (define-key map "g" #'ogent-cabinet-search-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-search-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-search-mode'.")

(define-derived-mode ogent-cabinet-search-mode tabulated-list-mode "Cabinet-Search"
  "Major mode for Cabinet search results."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Kind" 10 t)
               ("File" 30 t)
               ("Line" 6 nil :right-align t)
               ("Match" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-search-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-search--entries ()
  "Return tabulated entries for the current Cabinet search buffer."
  (if (string-blank-p (or ogent-cabinet-search--query ""))
      (list (list nil (vector "" "" "" "Enter a search query to search this Cabinet.")))
    (mapcar
     (lambda (result)
       (let ((path (plist-get result :path)))
         (list
          result
          (vector
           (symbol-name (plist-get result :kind))
           (file-relative-name path ogent-cabinet-search--root)
           (number-to-string (plist-get result :line))
           (plist-get result :text)))))
     (apply #'ogent-cabinet-search-records
            ogent-cabinet-search--root
            ogent-cabinet-search--query
            ogent-cabinet-search--filters))))

;;;###autoload
(defun ogent-cabinet-search (&optional directory query filters)
  "Search Cabinet Org records under DIRECTORY for QUERY and FILTERS."
  (interactive
   (let ((root (ogent-cabinet-ui--root
                (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))))
     (list root (read-string "Search Cabinet: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (search-query (or query (read-string "Search Cabinet: ")))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-search-buffer-name-format
                   root
                   search-query))))
    (with-current-buffer buffer
      (ogent-cabinet-search-mode)
      (setq ogent-cabinet-search--root root)
      (setq ogent-cabinet-search--query search-query)
      (setq ogent-cabinet-search--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-search--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-search-refresh (&rest _)
  "Refresh the current Cabinet search results."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-search-visit ()
  "Visit the Cabinet search result at point."
  (interactive)
  (let ((result (tabulated-list-get-id)))
    (unless result
      (user-error "No Cabinet search result at point"))
    (ogent-cabinet-ui--file-line
     (plist-get result :path)
     (plist-get result :line))))

;;; Apps

(defvar ogent-cabinet-apps-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-apps-open))
    (define-key map "v" #'ogent-cabinet-apps-visit-directory)
    (define-key map (kbd "C-c v") #'ogent-cabinet-apps-visit-directory)
    (define-key map "g" #'ogent-cabinet-apps-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-apps-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-apps-mode'.")

(define-derived-mode ogent-cabinet-apps-mode tabulated-list-mode "Cabinet-Apps"
  "Major mode for Cabinet app artifacts."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Label" 30 t)
               ("Owner" 18 t)
               ("Modified" 18 t)
               ("Path" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Modified" . t))
  (setq-local revert-buffer-function #'ogent-cabinet-apps-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-apps--entry (app)
  "Return a tabulated entry for APP."
  (let ((owner (string-join
                (delq nil (list (plist-get app :agent)
                                (plist-get app :job-id)))
                "/")))
    (list
     app
     (vector
      (plist-get app :label)
      owner
      (or (plist-get app :modified) "")
      (plist-get app :path)))))

(defun ogent-cabinet-apps--entries ()
  "Return app entries for the current Cabinet apps buffer."
  (let ((apps (ogent-cabinet-list-apps ogent-cabinet-apps--root)))
    (if apps
        (mapcar #'ogent-cabinet-apps--entry apps)
      (list (list nil (vector "No app artifacts" "" "" ""))))))

;;;###autoload
(defun ogent-cabinet-apps (&optional directory)
  "Open the Cabinet app artifact list for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-apps-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-apps-mode)
      (setq ogent-cabinet-apps--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-apps--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-apps-refresh (&rest _)
  "Refresh the Cabinet apps buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-apps--item ()
  "Return the app item at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet app at point")))

(defun ogent-cabinet-apps-open ()
  "Open the app artifact at point in a browser."
  (interactive)
  (ogent-cabinet-open-file (plist-get (ogent-cabinet-apps--item) :path)))

(defun ogent-cabinet-apps-visit-directory ()
  "Visit the app directory at point."
  (interactive)
  (dired (plist-get (ogent-cabinet-apps--item) :directory)))

;;;###autoload
(defun ogent-cabinet-open-app (&optional directory)
  "Open an index.html app artifact under DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (apps (ogent-cabinet-list-apps root)))
    (unless apps
      (user-error "No Cabinet index.html apps under %s" root))
    (let* ((app
            (if (= (length apps) 1)
                (car apps)
              (let* ((labels (mapcar (lambda (item)
                                       (plist-get item :label))
                                     apps))
                     (choice (completing-read "App: " labels nil t)))
                (seq-find
                 (lambda (item)
                   (equal (plist-get item :label) choice))
                 apps))))
           (path (plist-get app :path)))
      (browse-url-of-file path)
      path)))

(defun ogent-cabinet-ui--section-keymaps ()
  "Return Cabinet UI keymaps that contain collapsible sections."
  (list ogent-cabinet-home-mode-map
        ogent-cabinet-org-chart-mode-map
        ogent-cabinet-agent-mode-map
        ogent-cabinet-conversation-mode-map))

(defun ogent-cabinet-ui--setup-section-keymaps ()
  "Wire Magit section parent keymaps into section-capable Cabinet buffers."
  (when (and (ogent-cabinet-ui--magit-section-usable-p)
             (boundp 'magit-section-mode-map))
    (dolist (map (ogent-cabinet-ui--section-keymaps))
      (set-keymap-parent map magit-section-mode-map))))

(ogent-cabinet-ui--setup-section-keymaps)

(with-eval-after-load 'magit-section
  (ogent-cabinet-ui--setup-section-keymaps))

(defun ogent-cabinet-ui--evil-mode-map ()
  "Return the Cabinet UI keymap for the current buffer."
  (pcase major-mode
    ('ogent-cabinet-home-mode ogent-cabinet-home-mode-map)
    ('ogent-cabinet-agents-mode ogent-cabinet-agents-mode-map)
    ('ogent-cabinet-org-chart-mode ogent-cabinet-org-chart-mode-map)
    ('ogent-cabinet-agent-mode ogent-cabinet-agent-mode-map)
    ('ogent-cabinet-jobs-mode ogent-cabinet-jobs-mode-map)
    ('ogent-cabinet-tasks-mode ogent-cabinet-tasks-mode-map)
    ('ogent-cabinet-conversations-mode ogent-cabinet-conversations-mode-map)
    ('ogent-cabinet-conversation-mode ogent-cabinet-conversation-mode-map)
    ('ogent-cabinet-search-mode ogent-cabinet-search-mode-map)
    ('ogent-cabinet-apps-mode ogent-cabinet-apps-mode-map)))

(defun ogent-cabinet-ui--evil-local-keys ()
  "Install local Evil keys for Cabinet UI buffers."
  (when-let ((map (ogent-cabinet-ui--evil-mode-map)))
    (ogent-cabinet-evil-install-local-bindings map)))

(defun ogent-cabinet-ui--evil-mode-specs ()
  "Return Cabinet UI Evil setup specs."
  `((ogent-cabinet-home-mode
     ,ogent-cabinet-home-mode-map
     ogent-cabinet-home-mode-hook)
    (ogent-cabinet-agents-mode
     ,ogent-cabinet-agents-mode-map
     ogent-cabinet-agents-mode-hook)
    (ogent-cabinet-org-chart-mode
     ,ogent-cabinet-org-chart-mode-map
     ogent-cabinet-org-chart-mode-hook)
    (ogent-cabinet-agent-mode
     ,ogent-cabinet-agent-mode-map
     ogent-cabinet-agent-mode-hook)
    (ogent-cabinet-jobs-mode
     ,ogent-cabinet-jobs-mode-map
     ogent-cabinet-jobs-mode-hook)
    (ogent-cabinet-tasks-mode
     ,ogent-cabinet-tasks-mode-map
     ogent-cabinet-tasks-mode-hook)
    (ogent-cabinet-conversations-mode
     ,ogent-cabinet-conversations-mode-map
     ogent-cabinet-conversations-mode-hook)
    (ogent-cabinet-conversation-mode
     ,ogent-cabinet-conversation-mode-map
     ogent-cabinet-conversation-mode-hook)
    (ogent-cabinet-search-mode
     ,ogent-cabinet-search-mode-map
     ogent-cabinet-search-mode-hook)
    (ogent-cabinet-apps-mode
     ,ogent-cabinet-apps-mode-map
     ogent-cabinet-apps-mode-hook)))

(defun ogent-cabinet-ui--setup-evil ()
  "Set up Evil integration for Cabinet UI buffers."
  (dolist (spec (ogent-cabinet-ui--evil-mode-specs))
    (pcase-let ((`(,mode ,map ,hook) spec))
      (ogent-cabinet-evil-setup-mode
       mode map hook #'ogent-cabinet-ui--evil-local-keys))))

(with-eval-after-load 'evil
  (ogent-cabinet-ui--setup-evil))

(provide 'ogent-ui-cabinet)

;;; ogent-ui-cabinet.el ends here
