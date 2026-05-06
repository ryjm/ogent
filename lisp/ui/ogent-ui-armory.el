;;; ogent-ui-armory.el --- Richer Org Armory buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Interactive Armory surfaces over the Org-backed storage layer: agent lists,
;; single-agent profiles, attention lanes, search, and app artifact opening.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'ogent-armory)
(require 'ogent-armory-conversations)
(require 'ogent-armory-data)
(require 'ogent-armory-settings)
(require 'ogent-armory-runner)

(eval-and-compile
  (defvar ogent-armory-ui--magit-section-available
    (require 'magit-section nil t)
    "Non-nil when `magit-section' is available for Armory UI buffers.")
  (when ogent-armory-ui--magit-section-available
    (require 'magit-section)))

(autoload 'ogent-armory-status "ogent-armory-status" nil t)
(autoload 'ogent-armory-actions "ogent-armory-actions" nil t)
(autoload 'ogent-armory-schedule "ogent-armory-schedule" nil t)
(autoload 'ogent-armory-agenda "ogent-armory-schedule" nil t)
(autoload 'ogent-armory-git-status "ogent-armory-git" nil t)
(autoload 'ogent-armory-command-palette "ogent-armory-palette" nil t)

(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-make-overriding-map "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function evil-local-set-key "ext:evil-core")
(declare-function evil-goto-first-line "ext:evil-commands")
(declare-function evil-goto-line "ext:evil-commands")
(declare-function evil-next-line "ext:evil-commands")
(declare-function evil-previous-line "ext:evil-commands")
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
  "Return content strings from TURNS matching ROLE."
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
  "Append TYPE event with PAYLOAD for canonical conversation PATH."
  (when (ogent-armory-ui--canonical-conversation-path-p path)
    (ogent-armory-conversation-append-event
     root
     (ogent-armory-ui--canonical-conversation-id path)
     type
     :ts (ogent-armory-ui--iso-now)
     :payload payload)))

(defun ogent-armory-ui--conversation-update-properties
    (root path properties &optional event payload)
  "Update conversation PATH with Org PROPERTIES.
When EVENT is non-nil, append it to the canonical event log."
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

(defun ogent-armory-ui--read-string-default (prompt default)
  "Read string for PROMPT with DEFAULT shown as an Emacs default value."
  (let ((shown-prompt
         (if (and default (not (string-empty-p default)))
             (format "%s (default %s): "
                     (string-trim-right prompt "[: \t\n]+")
                     default)
           prompt)))
    (read-string shown-prompt nil nil default)))

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

(defun ogent-armory-ui--refresh-magit-section-availability ()
  "Refresh `magit-section' availability for Armory UI buffers."
  (setq ogent-armory-ui--magit-section-available
        (or ogent-armory-ui--magit-section-available
            (require 'magit-section nil t)))
  (when (and ogent-armory-ui--magit-section-available
             (not (featurep 'magit-section)))
    (require 'magit-section))
  ogent-armory-ui--magit-section-available)

(defun ogent-armory-ui--magit-section-usable-p ()
  "Return non-nil when Magit section APIs are usable."
  (and (ogent-armory-ui--refresh-magit-section-availability)
       (fboundp 'magit-current-section)
       (fboundp 'magit-insert-heading)
       (fboundp 'magit-section-toggle)
       (fboundp 'magit-section-forward-sibling)
       (fboundp 'magit-section-backward-sibling)))

(defmacro ogent-armory-ui--with-section (section heading &rest body)
  "Insert collapsible SECTION with HEADING around BODY when Magit is present."
  (declare (indent 2) (debug t))
  (let ((type (car section)))
    `(if (ogent-armory-ui--magit-section-usable-p)
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

(defmacro ogent-armory-ui--with-root-section (section &rest body)
  "Insert root SECTION around BODY when Magit is present."
  (declare (indent 1) (debug t))
  (let ((type (car section)))
    `(if (ogent-armory-ui--magit-section-usable-p)
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

(defmacro ogent-armory-ui--define-section-mode (mode name docstring &rest body)
  "Define section-capable Armory MODE with NAME, DOCSTRING, and BODY."
  (declare (indent 3) (debug t))
  (let ((parent (if (bound-and-true-p ogent-armory-ui--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ,mode ,parent ,name ,docstring
       :group 'ogent-ui-armory
       ,@body)))

(defun ogent-armory-ui-toggle-section ()
  "Toggle the current Armory UI section."
  (interactive)
  (if (ogent-armory-ui--magit-section-usable-p)
      (if-let ((section (magit-current-section)))
          (condition-case err
              (magit-section-toggle section)
            (user-error (message "%s" (error-message-string err))))
        (message "No section at point"))
    (message "Section toggling requires magit-section")))

(defun ogent-armory-ui-cycle-sections ()
  "Cycle visibility for all Armory UI sections."
  (interactive)
  (if (and (ogent-armory-ui--magit-section-usable-p)
           (fboundp 'magit-section-cycle-global))
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-armory-ui-next-section ()
  "Move to the next sibling Armory UI section."
  (interactive)
  (when (ogent-armory-ui--magit-section-usable-p)
    (magit-section-forward-sibling)))

(defun ogent-armory-ui-previous-section ()
  "Move to the previous sibling Armory UI section."
  (interactive)
  (when (ogent-armory-ui--magit-section-usable-p)
    (magit-section-backward-sibling)))

(defun ogent-armory-ui-up-section ()
  "Move to the parent Armory UI section."
  (interactive)
  (when (and (ogent-armory-ui--magit-section-usable-p)
             (fboundp 'magit-section-up))
    (magit-section-up)))

(defun ogent-armory-ui--configure-section-buffer ()
  "Configure local Magit section affordances for the current buffer."
  (when (ogent-armory-ui--magit-section-usable-p)
    (setq-local magit-section-visibility-indicator '("..." . t))))

(defun ogent-armory-ui--insert-kv (label value)
  "Insert LABEL and VALUE as one detail line."
  (insert (propertize (format "%-14s" label) 'face 'ogent-armory-ui-dim))
  (insert (format "%s\n" (or value ""))))

(defun ogent-armory-ui--item-at-point ()
  "Return Armory item metadata at point."
  (or (get-text-property (point) 'ogent-armory-item)
      (get-text-property (line-beginning-position) 'ogent-armory-item)
      (tabulated-list-get-id)))

(defun ogent-armory-ui--visible-property-position (property direction)
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

(defun ogent-armory-ui--insert-item-line (item text)
  "Insert TEXT with Armory ITEM metadata."
  (let ((start (point)))
    (insert text "\n")
    (add-text-properties
     start
     (point)
     `(ogent-armory-item ,item
                          mouse-face highlight
                          help-echo "RET visits this Armory item"))))

;;; Armory Home

(defvar ogent-armory-home-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-home-visit))
    (define-key map "m" #'ogent-armory-home-dispatch)
    (define-key map "?" #'ogent-armory-home-help)
    (define-key map "g" #'ogent-armory-home-refresh)
    (define-key map "q" #'quit-window)
    (define-key map "j" #'ogent-armory-jobs)
    (define-key map "J" #'ogent-armory-home-open-jobs)
    (define-key map "R" #'ogent-armory-home-run)
    (define-key map "E" #'ogent-armory-home-edit-item)
    (define-key map (kbd "TAB") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-armory-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-armory-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-armory-ui-previous-section)
    (define-key map (kbd "^") #'ogent-armory-ui-up-section)
    (define-key map "a" #'ogent-armory-agents)
    (define-key map "D" #'ogent-armory-data)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map "c" #'ogent-armory-conversations)
    (define-key map "u" #'ogent-armory-schedule)
    (define-key map "s" #'ogent-armory-search)
    (define-key map "A" #'ogent-armory-apps)
    (define-key map "h" #'ogent-armory-git-status)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "." #'ogent-armory-help)
    (define-key map "G" #'ogent-armory-status)
    (define-key map "e" #'ogent-armory-home-edit-metadata)
    (define-key map "n" #'ogent-armory-home-next-item)
    (define-key map "p" #'ogent-armory-home-previous-item)
    map)
  "Keymap for `ogent-armory-home-mode'.")

(ogent-armory-ui--define-section-mode ogent-armory-home-mode "Armory-Home"
                                       "Major mode for Armory Home."
                                       (setq-local revert-buffer-function #'ogent-armory-home-refresh)
                                       (setq-local truncate-lines t)
                                       (setq-local buffer-read-only t)
                                       (ogent-armory-ui--configure-section-buffer)
                                       (setq-local header-line-format (ogent-armory-home--header-line)))

(defun ogent-armory-home--header-line ()
  "Return header line for Armory Home."
  "m menu  ? home help  . Armory help  RET visit  TAB section  M-n/p sections  g refresh  q quit  / palette  , settings  j Jobs  J related jobs  D Data  a Agents  t Tasks  c Conversations  u Schedule  s Search  A Apps  h Git  G Graph  R run  E edit item  e Edit Armory  n/p move")

;;;###autoload
(defun ogent-armory-home (&optional directory)
  "Open Armory Home for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-home-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-home-mode)
      (setq ogent-armory-home--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-home-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-home-refresh (&rest _)
  "Refresh Armory Home."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-armory-home--insert-buffer)
    (goto-char (point-min))))

(defun ogent-armory-home--insert-nav (label key command)
  "Insert navigation LABEL for KEY dispatching to COMMAND."
  (ogent-armory-ui--insert-item-line
   (list :type 'command :command command)
   (format "  [%s] %s" key label)))

(defun ogent-armory-home--insert-buffer ()
  "Insert Armory Home contents."
  (ogent-armory-ui--with-root-section (ogent-armory-home-root)
                                       (ogent-armory-home--insert-buffer-content)))

(defun ogent-armory-home--insert-buffer-content ()
  "Insert Armory Home content sections."
  (let* ((root ogent-armory-home--root)
         (index (ogent-armory-read-index root))
         (agents (ogent-armory-ui--agent-slugs root))
         (jobs (ogent-armory-ui--all-jobs root))
         (sessions (ogent-armory-ui--all-sessions root))
         (failed (seq-filter
                  (lambda (session)
                    (not (zerop (or (plist-get session :exit-status) 0))))
                  sessions))
         (running (seq-filter #'ogent-armory-runner-running-p agents))
         (archived (seq-filter
                    (lambda (record)
                      (plist-get record :archived))
                    (append jobs sessions)))
         (apps (ogent-armory-list-apps root))
         (stale (seq-filter
                 (lambda (job)
                   (ogent-armory-ui--stale-job-p root job))
                 jobs))
         (missing-persona
          (seq-filter
           (lambda (slug)
             (let ((agent (ogent-armory-read-agent root slug)))
               (or (string-blank-p (or (plist-get agent :role) ""))
                   (string-blank-p (or (plist-get agent :provider) ""))
                   (string-blank-p (or (plist-get agent :body) "")))))
           agents)))
    (insert (propertize "Armory Home" 'face 'ogent-armory-ui-heading) "\n")
    (ogent-armory-ui--insert-kv "Title" (plist-get index :name))
    (ogent-armory-ui--insert-kv "Path" root)
    (ogent-armory-ui--insert-kv "Kind" (plist-get index :kind))
    (ogent-armory-ui--insert-kv "Tags" (ogent-armory-ui--format-tags
                                         (plist-get index :tags)))
    (ogent-armory-ui--insert-kv "Description" (plist-get index :description))
    (insert "\n")
    (ogent-armory-ui--with-section (ogent-armory-home-health)
                                    (ogent-armory-ui--heading-text "Health")
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
    (ogent-armory-ui--with-section (ogent-armory-home-navigate)
                                    (ogent-armory-ui--heading-text "Navigate")
                                    (ogent-armory-home--insert-nav "Data" "D" #'ogent-armory-data)
                                    (ogent-armory-home--insert-nav "Agents" "a" #'ogent-armory-agents)
                                    (ogent-armory-home--insert-nav "Jobs" "j" #'ogent-armory-jobs)
                                    (ogent-armory-home--insert-nav "Tasks" "t" #'ogent-armory-tasks)
                                    (ogent-armory-home--insert-nav "Conversations" "c" #'ogent-armory-conversations)
                                    (ogent-armory-home--insert-nav "Schedule" "u" #'ogent-armory-schedule)
                                    (ogent-armory-home--insert-nav "Search" "s" #'ogent-armory-search)
                                    (ogent-armory-home--insert-nav "Apps" "A" #'ogent-armory-apps)
                                    (ogent-armory-home--insert-nav "Git" "h" #'ogent-armory-git-status)
                                    (ogent-armory-home--insert-nav "Palette" "/" #'ogent-armory-command-palette)
                                    (ogent-armory-home--insert-nav "Settings" "," #'ogent-armory-settings)
                                    (ogent-armory-home--insert-nav "Help" "." #'ogent-armory-help)
                                    (ogent-armory-home--insert-nav "Graph" "G" #'ogent-armory-status)
                                    (ogent-armory-ui--insert-item-line
                                     (list :type 'file :path (ogent-armory-index-file root))
                                     "  [e] Armory metadata")
                                    (ogent-armory-ui--insert-item-line
                                     (list :type 'file :path (ogent-armory-index-file root))
                                     "  Source Org"))
    (insert "\n")
    (ogent-armory-home--insert-active-jobs jobs root)
    (insert "\n")
    (ogent-armory-ui--with-section (ogent-armory-home-recent)
                                    (ogent-armory-ui--heading-text "Recent Activity")
                                    (if sessions
                                        (dolist (session (seq-take sessions 5))
                                          (ogent-armory-ui--insert-item-line
                                           (list :type 'session :path (plist-get session :path)
                                                 :agent (plist-get session :agent)
                                                 :job-id (plist-get session :job-id))
                                           (format "  %s  %s  %s"
                                                   (or (plist-get session :status) "")
                                                   (or (plist-get session :name) "")
                                                   (or (plist-get session :finished) ""))))
                                      (insert (propertize "  No conversations yet\n" 'face 'ogent-armory-ui-dim))))
    (insert "\n")
    (ogent-armory-ui--with-section (ogent-armory-home-attention)
                                    (ogent-armory-ui--heading-text "Needs Attention")
                                    (if (or failed stale missing-persona)
                                        (progn
                                          (dolist (session failed)
                                            (ogent-armory-ui--insert-item-line
                                             (list :type 'session :path (plist-get session :path)
                                                   :agent (plist-get session :agent)
                                                   :job-id (plist-get session :job-id))
                                             (format "  failed session  %s" (plist-get session :name))))
                                          (dolist (job stale)
                                            (ogent-armory-ui--insert-item-line
                                             (list :type 'job :agent (plist-get job :agent)
                                                   :job-id (plist-get job :id)
                                                   :path (ogent-armory-job-file root
                                                                                 (plist-get job :agent)
                                                                                 (plist-get job :id)))
                                             (format "  stale job       %s" (plist-get job :name))))
                                          (dolist (slug missing-persona)
                                            (ogent-armory-ui--insert-item-line
                                             (list :type 'agent :agent slug
                                                   :path (ogent-armory-agent-file root slug))
                                             (format "  missing persona %s" slug))))
                                      (insert (propertize "  Nothing needs attention\n" 'face 'ogent-armory-ui-good))))))

(defun ogent-armory-home--insert-active-jobs (jobs root)
  "Insert active development JOBS for ROOT."
  (let ((active (seq-filter (lambda (job)
                              (and (plist-get job :enabled)
                                   (not (plist-get job :archived))))
                            jobs)))
    (ogent-armory-ui--with-section (ogent-armory-home-active-jobs)
                                    (ogent-armory-ui--heading-text "Active Jobs")
                                    (if active
                                        (dolist (job active)
                                          (let ((agent (plist-get job :agent))
                                                (job-id (plist-get job :id)))
                                            (ogent-armory-ui--insert-item-line
                                             (list :type 'job
                                                   :agent agent
                                                   :job-id job-id
                                                   :path (ogent-armory-job-file root agent job-id))
                                             (format "  %s  %s  %s  [R run] [E prompt] [J jobs]"
                                                     agent
                                                     (or (plist-get job :name) job-id)
                                                     (or (plist-get job :cron)
                                                         (plist-get job :heartbeat)
                                                         "manual")))))
                                      (insert (propertize "  No active jobs\n" 'face 'ogent-armory-ui-dim))))))

(defun ogent-armory-home-visit ()
  "Visit or dispatch the item at point in Armory Home."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('command (funcall (plist-get item :command) ogent-armory-home--root))
      ('session (ogent-armory-conversation ogent-armory-home--root
                                            (plist-get item :path)))
      ('job (ogent-armory-jobs ogent-armory-home--root
                                (plist-get item :agent)))
      ('agent (ogent-armory-agent ogent-armory-home--root
                                   (plist-get item :agent)))
      ('file (ogent-armory-ui--visit-path (plist-get item :path)))
      (_ (user-error "No Armory Home item at point")))))

(defun ogent-armory-home-run ()
  "Run or retry the Armory Home item at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-run-job
        ogent-armory-home--root
        (plist-get item :agent)
        (plist-get item :job-id)))
      ('session
       (if-let ((job-id (plist-get item :job-id)))
           (ogent-armory-run-job
            ogent-armory-home--root
            (plist-get item :agent)
            job-id)
         (ogent-armory-run-agent
          ogent-armory-home--root
          (plist-get item :agent)
          (read-string "Instruction: "))))
      ('agent
       (ogent-armory-run-agent
        ogent-armory-home--root
        (plist-get item :agent)
        (read-string "Instruction: ")))
      (_
       (user-error "No runnable Armory Home item at point")))))

(defun ogent-armory-home-edit-item ()
  "Visit the editable body or source for the Armory Home item at point."
  (interactive)
  (let* ((item (ogent-armory-ui--item-at-point))
         (path (plist-get item :path)))
    (unless (and path (file-exists-p path))
      (user-error "No editable Armory item at point"))
    (pcase (plist-get item :type)
      ((or 'job 'agent)
       (ogent-armory-ui--visit-body path))
      (_
       (ogent-armory-ui--visit-path path)))))

(defun ogent-armory-home-open-jobs ()
  "Open Armory jobs related to the item at point."
  (interactive)
  (let* ((item (ogent-armory-ui--item-at-point))
         (agent (plist-get item :agent))
         (job-id (plist-get item :job-id))
         (buffer (ogent-armory-jobs ogent-armory-home--root agent)))
    (when (and agent job-id (fboundp 'ogent-armory-jobs--goto))
      (with-current-buffer buffer
        (ogent-armory-jobs--goto agent job-id)))
    buffer))

(defun ogent-armory-home-edit-metadata ()
  "Visit the Armory index Org file for metadata edits."
  (interactive)
  (ogent-armory-ui--visit-path
   (ogent-armory-index-file ogent-armory-home--root)))

(defun ogent-armory-home-help ()
  "Show Armory Home keybindings and daily-work actions."
  (interactive)
  (with-help-window "*Ogent Armory Home Help*"
    (princ "Armory Home\n")
    (princ "============\n\n")
    (princ "Home is the cockpit for developing a project with Armory.\n\n")
    (princ "Daily work\n")
    (princ "----------\n")
    (princ "j opens Jobs. J opens jobs related to the item at point.\n")
    (princ "R runs or retries the selected agent, job, or conversation.\n")
    (princ "E edits the selected agent persona, job prompt, or source Org record.\n")
    (princ "RET opens the richer surface or durable source for the item at point.\n\n")
    (princ "Navigation\n")
    (princ "----------\n")
    (princ "D Data, a Agents, B Org chart, t Tasks, c Conversations, u Schedule, Q Agenda, N Actions, s Search, A Apps, h Git, / Palette, , Settings, . Help, G Graph.\n")
    (princ "n and p move between actionable rows. g refreshes. q quits.\n")
    (princ "TAB toggles a section. M-n/M-p move between sibling sections. ^ moves to the parent section.\n\n")
    (princ "Evil normal state keeps j/k movement, gg/G buffer movement, gr refresh, gj/gk section movement, and ZZ/ZQ quit.\n\n")
    (princ "Menus\n")
    (princ "-----\n")
    (princ "m opens the Transient menu. ? opens this help buffer.\n")))

(defun ogent-armory-home--transient-header ()
  "Return the header text for `ogent-armory-home-dispatch'."
  (let ((root (and (boundp 'ogent-armory-home--root)
                   ogent-armory-home--root)))
    (concat
     (propertize "Armory Home" 'face 'transient-heading)
     (if root
         (concat "  " (propertize (abbreviate-file-name root) 'face 'shadow))
       ""))))

;;;###autoload (autoload 'ogent-armory-home-dispatch "ogent-ui-armory" nil t)
(transient-define-prefix ogent-armory-home-dispatch ()
                         "Dispatch menu for Armory Home."
                         [:description ogent-armory-home--transient-header
                                       ["Daily Work"
                                        ("j" "Jobs" ogent-armory-jobs)
                                        ("J" "Related jobs" ogent-armory-home-open-jobs)
                                        ("R" "Run/retry selected" ogent-armory-home-run)
                                        ("E" "Edit selected" ogent-armory-home-edit-item)]
                                       ["Navigate"
                                        ("RET" "Visit selected" ogent-armory-home-visit)
                                        ("TAB" "Toggle section" ogent-armory-ui-toggle-section :transient t)
                                        ("M-n" "Next section" ogent-armory-ui-next-section :transient t)
                                        ("M-p" "Previous section" ogent-armory-ui-previous-section :transient t)
                                        ("^" "Up section" ogent-armory-ui-up-section :transient t)
                                        ("n" "Next item" ogent-armory-home-next-item :transient t)
                                        ("p" "Previous item" ogent-armory-home-previous-item :transient t)
                                        ("g" "Refresh" ogent-armory-home-refresh :transient t)]]
                         [["Surfaces"
                           ("D" "Data" ogent-armory-data)
                           ("a" "Agents" ogent-armory-agents)
                           ("B" "Org chart" ogent-armory-org-chart)
                           ("t" "Tasks" ogent-armory-tasks)
                           ("c" "Conversations" ogent-armory-conversations)
                           ("u" "Schedule" ogent-armory-schedule)
                           ("N" "Action approvals" ogent-armory-actions)
                           ("s" "Search" ogent-armory-search)
                           ("A" "Apps" ogent-armory-apps)
	                           ("h" "Git" ogent-armory-git-status)
	                           ("/" "Palette" ogent-armory-command-palette)
	                           ("," "Settings" ogent-armory-settings)
	                           ("." "Help" ogent-armory-help)
	                           ("G" "Graph" ogent-armory-status)]
	                          ["Armory"
	                           ("Q" "Agenda" ogent-armory-agenda)
	                           ("'" "Onboard" ogent-armory-onboard)
	                           ("=" "Registry import" ogent-armory-registry-import)
	                           ("_" "Backup" ogent-armory-backup)
	                           ("e" "Edit metadata" ogent-armory-home-edit-metadata)
	                           ("?" "Help" ogent-armory-home-help)
                           ("q" "Quit menu" transient-quit-one)]])

(defun ogent-armory-home-next-item ()
  "Move point to the next actionable Armory Home item."
  (interactive)
  (let ((next (ogent-armory-ui--visible-property-position
               'ogent-armory-item
               'next)))
    (when next
      (goto-char next))))

(defun ogent-armory-home-previous-item ()
  "Move point to the previous actionable Armory Home item."
  (interactive)
  (let ((previous (ogent-armory-ui--visible-property-position
                   'ogent-armory-item
                   'previous)))
    (when previous
      (goto-char previous))))

;;; Agent List

(defvar ogent-armory-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-agents-open-agent)
    (define-key map (kbd "<return>") #'ogent-armory-agents-open-agent)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-agents-open-agent)
    (define-key map "v" #'ogent-armory-agents-visit)
    (define-key map "R" #'ogent-armory-agents-run)
    (define-key map "g" #'ogent-armory-agents-refresh)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map "s" #'ogent-armory-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-agents-mode'.")

(define-derived-mode ogent-armory-agents-mode tabulated-list-mode "Armory-Agents"
  "Major mode for Armory agent lists."
  :group 'ogent-ui-armory
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
  (setq-local revert-buffer-function #'ogent-armory-agents-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-agents--entries ()
  "Return tabulated entries for the current Armory agents buffer."
  (mapcar
   (lambda (slug)
     (let* ((agent (ogent-armory-resolve-agent
                    ogent-armory-agents--root slug :include-visible t))
            (jobs (ogent-armory-ui--agent-jobs ogent-armory-agents--root slug))
            (sessions (ogent-armory-ui--agent-sessions ogent-armory-agents--root slug))
            (last-session (ogent-armory-ui--last-session sessions))
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
                               'ogent-armory-ui-good
                             'ogent-armory-ui-dim))
         (number-to-string (length jobs))
         (number-to-string (length sessions))
         (or (plist-get last-session :finished) "")
         (or (plist-get agent :workspace) "")
         (ogent-armory-ui--format-tags (plist-get agent :tags))))))
   (ogent-armory-ui--agent-slugs ogent-armory-agents--root)))

;;;###autoload
(defun ogent-armory-agents (&optional directory)
  "Open a tabulated Armory agent list for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-agents-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-agents-mode)
      (setq ogent-armory-agents--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-agents--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-agents-refresh (&rest _)
  "Refresh the Armory agents buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-agents--slug-at-point ()
  "Return the agent slug at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory agent at point")))

(defun ogent-armory-agents-open-agent ()
  "Open the Armory agent profile at point."
  (interactive)
  (ogent-armory-agent
   ogent-armory-agents--root
   (ogent-armory-agents--slug-at-point)))

(defun ogent-armory-agents-visit ()
  "Visit the persona Org file for the Armory agent at point."
  (interactive)
  (let ((agent (ogent-armory-resolve-agent
                ogent-armory-agents--root
                (ogent-armory-agents--slug-at-point)
                :include-visible t)))
    (ogent-armory-ui--visit-path (plist-get agent :path))))

(defun ogent-armory-agents-run ()
  "Run the Armory agent at point with an instruction."
  (interactive)
  (let ((slug (ogent-armory-agents--slug-at-point)))
    (ogent-armory-run-agent
     ogent-armory-agents--root
     slug
     (read-string "Instruction: "))))

;;; Org Chart

(defvar ogent-armory-org-chart-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-armory-org-chart-refresh)
    (define-key map (kbd "TAB") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-armory-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-armory-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-armory-ui-previous-section)
    (define-key map (kbd "^") #'ogent-armory-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-org-chart-mode'.")

(ogent-armory-ui--define-section-mode
 ogent-armory-org-chart-mode "Armory-Org-Chart"
 "Major mode for Armory department and lead charts."
 (setq-local revert-buffer-function #'ogent-armory-org-chart-refresh)
 (setq-local buffer-read-only t)
 (ogent-armory-ui--configure-section-buffer)
 (setq header-line-format
       "g refresh  TAB section  M-n/p sections  ^ up  q quit"))

;;;###autoload
(defun ogent-armory-org-chart (&optional directory)
  "Open a Armory org chart for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   "*ogent-armory-org-chart: %s*" root))))
    (with-current-buffer buffer
      (ogent-armory-org-chart-mode)
      (setq ogent-armory-org-chart--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-org-chart-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-org-chart-refresh (&rest _)
  "Refresh the current Armory org chart."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Armory Org Chart" 'face 'ogent-armory-ui-heading)
            "\n\n")
    (dolist (group (ogent-armory-agents-by-department
                    ogent-armory-org-chart--root
                    :include-visible t))
      (let ((department (plist-get group :department))
            (lead (plist-get group :lead)))
        (ogent-armory-ui--with-section
         (ogent-armory-org-chart-department)
         (ogent-armory-ui--heading-text department)
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

(defvar ogent-armory-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-agent-visit)
    (define-key map (kbd "<return>") #'ogent-armory-agent-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-agent-visit)
    (define-key map "c" #'ogent-armory-agent-compose)
    (define-key map "e" #'ogent-armory-agent-edit-property)
    (define-key map "R" #'ogent-armory-agent-run-at-point)
    (define-key map "v" #'ogent-armory-agent-visit)
    (define-key map "g" #'ogent-armory-agent-refresh)
    (define-key map (kbd "TAB") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-armory-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-armory-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-armory-ui-previous-section)
    (define-key map (kbd "^") #'ogent-armory-ui-up-section)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map "s" #'ogent-armory-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-agent-mode'.")

(ogent-armory-ui--define-section-mode ogent-armory-agent-mode "Armory-Agent"
                                       "Major mode for a single Armory agent profile."
                                       (setq-local revert-buffer-function #'ogent-armory-agent-refresh)
                                       (setq-local truncate-lines t)
                                       (setq-local buffer-read-only t)
                                       (ogent-armory-ui--configure-section-buffer)
                                       (setq header-line-format '(:eval (ogent-armory-agent--header-line))))

(defun ogent-armory-agent--header-line ()
  "Return header text for the current Armory agent buffer."
  (format "g refresh  RET/v visit  TAB section  M-n/p sections  c compose  e edit  R run/retry  t tasks  s search  q quit    %s/%s"
          (or (and ogent-armory-agent--root
                   (ogent-armory-ui--root-label ogent-armory-agent--root))
              "?")
          (or ogent-armory-agent--slug "?")))

;;;###autoload
(defun ogent-armory-agent (&optional directory agent-slug)
  "Open a single Armory AGENT-SLUG profile for DIRECTORY."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (slug (ogent-armory-ui--read-agent root)))
     (list root slug)))
  (let* ((root (ogent-armory-ui--root directory))
         (slug (or agent-slug (ogent-armory-ui--read-agent root)))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-agent-buffer-name-format root slug))))
    (with-current-buffer buffer
      (ogent-armory-agent-mode)
      (setq ogent-armory-agent--root root)
      (setq ogent-armory-agent--slug slug)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-agent-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-agent-refresh (&rest _)
  "Refresh the current Armory agent profile."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-armory-agent--insert-buffer)
    (goto-char (point-min))))

(defun ogent-armory-agent--insert-buffer ()
  "Insert the current Armory agent profile."
  (ogent-armory-ui--with-root-section (ogent-armory-agent-root)
                                       (ogent-armory-agent--insert-buffer-content)))

(defun ogent-armory-agent--insert-buffer-content ()
  "Insert the current Armory agent profile sections."
  (let* ((root ogent-armory-agent--root)
         (slug ogent-armory-agent--slug)
         (agent (ogent-armory-resolve-agent
                 root slug :include-visible t))
         (jobs (ogent-armory-ui--agent-jobs root slug))
         (sessions (ogent-armory-ui--agent-sessions root slug)))
    (insert (propertize (or (plist-get agent :display-name)
                            (plist-get agent :name)
                            slug)
                        'face 'ogent-armory-ui-heading)
            "\n")
    (insert (propertize
             (string-join
              (delq nil
                    (list (plist-get agent :role)
                          (plist-get agent :department)
                          (symbol-name (plist-get agent :scope))))
              "  ")
             'face 'ogent-armory-ui-dim)
            "\n\n")
    (ogent-armory-ui--with-section (ogent-armory-agent-composer)
                                    (ogent-armory-ui--heading-text "Composer")
                                    (insert "  c compose instruction and run this agent\n")
                                    (insert "  R run job or session at point\n"))
    (insert "\n")
    (ogent-armory-agent--insert-inbox jobs)
    (ogent-armory-agent--insert-conversations sessions)
    (ogent-armory-agent--insert-recent-work sessions)
    (ogent-armory-agent--insert-schedule jobs)
    (ogent-armory-agent--insert-memory root slug)
    (ogent-armory-agent--insert-tools agent)
    (ogent-armory-agent--insert-skills agent)
    (ogent-armory-agent--insert-details agent)
    (ogent-armory-agent--insert-persona agent)))

(defun ogent-armory-agent--insert-inbox (jobs)
  "Insert Inbox section from JOBS."
  (ogent-armory-ui--with-section (ogent-armory-agent-inbox)
                                  (ogent-armory-ui--heading-text "Inbox")
                                  (let ((enabled (seq-filter (lambda (job) (plist-get job :enabled)) jobs)))
                                    (if enabled
                                        (dolist (job enabled)
                                          (ogent-armory-ui--insert-item-line
                                           (list :type 'job
                                                 :agent (plist-get job :agent)
                                                 :job-id (plist-get job :id)
                                                 :path (ogent-armory-job-file
                                                        ogent-armory-agent--root
                                                        (plist-get job :agent)
                                                        (plist-get job :id)))
                                           (format "  TODO %s  %s"
                                                   (or (plist-get job :name) (plist-get job :id))
                                                   (or (plist-get job :cron) "manual"))))
                                      (insert (propertize "  No enabled jobs\n" 'face 'ogent-armory-ui-dim)))))
  (insert "\n"))

(defun ogent-armory-agent--insert-conversations (sessions)
  "Insert Conversations section from SESSIONS."
  (ogent-armory-ui--with-section (ogent-armory-agent-conversations)
                                  (ogent-armory-ui--heading-text "Conversations")
                                  (if sessions
                                      (dolist (session sessions)
                                        (ogent-armory-ui--insert-item-line
                                         (list :type 'session
                                               :agent (plist-get session :agent)
                                               :job-id (plist-get session :job-id)
                                               :path (plist-get session :path))
                                         (format "  %s  %s  %s"
                                                 (or (plist-get session :status) "DONE")
                                                 (or (plist-get session :name) (plist-get session :id))
                                                 (or (plist-get session :finished) ""))))
                                    (insert (propertize "  No conversations yet\n" 'face 'ogent-armory-ui-dim))))
  (insert "\n"))

(defun ogent-armory-agent--insert-recent-work (sessions)
  "Insert Recent Work section from SESSIONS."
  (ogent-armory-ui--with-section (ogent-armory-agent-recent-work)
                                  (ogent-armory-ui--heading-text "Recent Work")
                                  (let ((recent (seq-take sessions 5)))
                                    (if recent
                                        (dolist (session recent)
                                          (ogent-armory-ui--insert-item-line
                                           (list :type 'session
                                                 :agent (plist-get session :agent)
                                                 :job-id (plist-get session :job-id)
                                                 :path (plist-get session :path))
                                           (format "  %s  %s"
                                                   (or (plist-get session :status) "DONE")
                                                   (or (plist-get session :name)
                                                       (plist-get session :id)))))
                                      (insert (propertize "  No recent work\n" 'face 'ogent-armory-ui-dim)))))
  (insert "\n"))

(defun ogent-armory-agent--insert-schedule (jobs)
  "Insert Schedule section from JOBS."
  (ogent-armory-ui--with-section (ogent-armory-agent-schedule)
                                  (ogent-armory-ui--heading-text "Schedule")
                                  (if jobs
                                      (dolist (job jobs)
                                        (ogent-armory-ui--insert-item-line
                                         (list :type 'job
                                               :agent (plist-get job :agent)
                                               :job-id (plist-get job :id)
                                               :path (ogent-armory-job-file
                                                      ogent-armory-agent--root
                                                      (plist-get job :agent)
                                                      (plist-get job :id)))
                                         (format "  %s  %s  %s"
                                                 (if (plist-get job :enabled) "enabled" "disabled")
                                                 (or (plist-get job :name) (plist-get job :id))
                                                 (or (plist-get job :cron) "manual"))))
                                    (insert (propertize "  No scheduled jobs\n" 'face 'ogent-armory-ui-dim))))
  (insert "\n"))

(defun ogent-armory-agent--insert-memory (root slug)
  "Insert Memory section for agent SLUG under ROOT."
  (ogent-armory-ui--with-section (ogent-armory-agent-memory)
                                  (ogent-armory-ui--heading-text "Memory")
                                  (dolist (file (list (ogent-armory-agent-memory-file root slug "context.org")
                                                      (ogent-armory-agent-memory-file root slug "decisions.org")
                                                      (ogent-armory-agent-memory-file root slug "learnings.org")
                                                      (ogent-armory-agent-inbox-file root slug)
                                                      (ogent-armory-agent-schedule-file root slug)))
                                    (ogent-armory-ui--insert-item-line
                                     (list :type 'file :path file)
                                     (format "  %s" (file-relative-name file (ogent-armory-agent-directory
                                                                              root slug))))))
  (insert "\n"))

(defun ogent-armory-agent--insert-tools (agent)
  "Insert Tools/Permissions section from AGENT."
  (ogent-armory-ui--with-section (ogent-armory-agent-tools)
                                  (ogent-armory-ui--heading-text "Tools/Permissions")
                                  (ogent-armory-ui--insert-kv "Provider" (plist-get agent :provider))
                                  (ogent-armory-ui--insert-kv "Adapter" (plist-get agent :adapter))
                                  (ogent-armory-ui--insert-kv "Model" (plist-get agent :model))
                                  (ogent-armory-ui--insert-kv "Effort" (plist-get agent :effort))
                                  (ogent-armory-ui--insert-kv "Runtime" (plist-get agent :runtime-mode))
                                  (ogent-armory-ui--insert-kv "Budget" (plist-get agent :budget))
                                  (ogent-armory-ui--insert-kv "Permission" (plist-get agent :permission-mode)))
  (insert "\n"))

(defun ogent-armory-agent--insert-skills (agent)
  "Insert Skills section from AGENT."
  (ogent-armory-ui--with-section (ogent-armory-agent-skills)
                                  (ogent-armory-ui--heading-text "Skills")
                                  (ogent-armory-ui--insert-kv "Selected"
                                                               (string-join
                                                                (or (plist-get agent :skills) nil)
                                                                ", "))
                                  (ogent-armory-ui--insert-kv "Recommended"
                                                               (string-join
                                                                (or (plist-get agent :recommended-skills) nil)
                                                                ", ")))
  (insert "\n"))

(defun ogent-armory-agent--insert-details (agent)
  "Insert Details section from AGENT."
  (ogent-armory-ui--with-section (ogent-armory-agent-details)
                                  (ogent-armory-ui--heading-text "Details")
                                  (ogent-armory-ui--insert-kv "Slug" (plist-get agent :slug))
                                  (ogent-armory-ui--insert-kv "Scope" (symbol-name (plist-get agent :scope)))
                                  (ogent-armory-ui--insert-kv "Display" (plist-get agent :display-name))
                                  (ogent-armory-ui--insert-kv "Icon" (plist-get agent :icon))
                                  (ogent-armory-ui--insert-kv "Color" (plist-get agent :color))
                                  (ogent-armory-ui--insert-kv "Avatar" (plist-get agent :avatar))
                                  (ogent-armory-ui--insert-kv "Department" (plist-get agent :department))
                                  (ogent-armory-ui--insert-kv "Type" (plist-get agent :type))
                                  (ogent-armory-ui--insert-kv "Can Dispatch"
                                                               (if (plist-get agent :can-dispatch) "t" "nil"))
                                  (ogent-armory-ui--insert-kv "Role" (plist-get agent :role))
                                  (ogent-armory-ui--insert-kv "Provider" (plist-get agent :provider))
                                  (ogent-armory-ui--insert-kv "Model" (plist-get agent :model))
                                  (ogent-armory-ui--insert-kv "Heartbeat" (plist-get agent :heartbeat))
                                  (ogent-armory-ui--insert-kv "Last Heartbeat" (plist-get agent :last-heartbeat))
                                  (ogent-armory-ui--insert-kv "Next Heartbeat" (plist-get agent :next-heartbeat))
                                  (ogent-armory-ui--insert-kv "Active" (if (plist-get agent :active) "t" "nil"))
                                  (ogent-armory-ui--insert-kv "Setup Complete"
                                                               (if (plist-get agent :setup-complete) "t" "nil"))
                                  (ogent-armory-ui--insert-kv "Workspace" (plist-get agent :workspace))
                                  (ogent-armory-ui--insert-kv "Focus" (string-join (or (plist-get agent :focus) nil) ", "))
                                  (ogent-armory-ui--insert-kv "Goals" (string-join (or (plist-get agent :goals) nil) ", "))
                                  (ogent-armory-ui--insert-kv "Channels" (string-join (or (plist-get agent :channels) nil) ", "))
                                  (ogent-armory-ui--insert-kv "Tags" (string-join (or (plist-get agent :tags) nil) ", ")))
  (insert "\n"))

(defun ogent-armory-agent--insert-persona (agent)
  "Insert Persona Instructions section from AGENT."
  (ogent-armory-ui--with-section (ogent-armory-agent-persona)
                                  (ogent-armory-ui--heading-text "Persona Instructions")
                                  (let ((body (plist-get agent :body)))
                                    (if (and body (not (string-blank-p body)))
                                        (insert body "\n")
                                      (insert (propertize "No persona instructions.\n" 'face 'ogent-armory-ui-dim))))))

(defun ogent-armory-agent-visit ()
  "Visit the Armory item at point or this agent's persona file."
  (interactive)
  (let* ((item (ogent-armory-ui--item-at-point))
         (agent (ogent-armory-resolve-agent
                 ogent-armory-agent--root
                 ogent-armory-agent--slug
                 :include-visible t))
         (path (or (plist-get item :path)
                   (plist-get agent :path))))
    (ogent-armory-ui--visit-path path)))

(defun ogent-armory-agent-compose ()
  "Run this Armory agent with an instruction."
  (interactive)
  (ogent-armory-run-agent
   ogent-armory-agent--root
   ogent-armory-agent--slug
   (read-string "Instruction: ")))

(defun ogent-armory-agent-run-at-point ()
  "Run the Armory job or session at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-run-job
        ogent-armory-agent--root
        (plist-get item :agent)
        (plist-get item :job-id)))
      ('session
       (if-let ((job-id (plist-get item :job-id)))
           (ogent-armory-run-job
            ogent-armory-agent--root
            (plist-get item :agent)
            job-id)
         (ogent-armory-run-agent
          ogent-armory-agent--root
          (plist-get item :agent)
          (read-string "Instruction: "))))
      (_
       (ogent-armory-agent-compose)))))

(defun ogent-armory-agent-edit-property ()
  "Edit one identity property in this agent's Org persona."
  (interactive)
  (let* ((agent (ogent-armory-resolve-agent
                 ogent-armory-agent--root
                 ogent-armory-agent--slug
                 :include-visible t))
         (file (plist-get agent :path))
         (property (completing-read
                    "Property: "
                    ogent-armory-agent-editable-properties
                    nil t))
         (current (with-temp-buffer
                    (insert-file-contents file)
                    (ogent-armory--org-mode)
                    (ogent-armory--first-heading-title)
                    (org-entry-get nil property)))
         (value (read-string (format "%s: " property) current)))
    (ogent-armory-ui--put-property file property value)
    (ogent-armory-agent-refresh)))

;;; Agent Management Commands

;;;###autoload
(defun ogent-armory-create-agent (&optional directory)
  "Create a Armory agent under DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (name (read-string "Name: "))
         (slug (ogent-armory-ui--read-string-default
                "Slug: "
                (ogent-armory--slug name "agent")))
         (role (ogent-armory-ui--read-string-default "Role: " "Agent"))
         (provider (ogent-armory-ui--read-string-default
                    "Provider: "
                    ogent-armory-default-agent-provider))
         (model (read-string "Model: "))
         (workspace (ogent-armory-ui--read-string-default "Workspace: " "/"))
         (tags (ogent-armory--tags-from-string (read-string "Tags: ")))
         (persona (read-string "Persona: ")))
    (when (file-exists-p (ogent-armory-agent-file root slug))
      (user-error "Agent already exists: %s" slug))
    (let ((file (ogent-armory-write-agent
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
      (ogent-armory-ui--refresh-home-buffer root)
      file)))

;;;###autoload
(defun ogent-armory-clone-agent (&optional directory agent-slug new-slug)
  "Clone AGENT-SLUG under DIRECTORY to NEW-SLUG."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (slug (ogent-armory-ui--read-agent root)))
     (list root slug (read-string "New slug: " (concat slug "-copy")))))
  (let* ((root (ogent-armory-ui--root directory))
         (agent (copy-sequence (ogent-armory-read-agent root agent-slug)))
         (target (or new-slug (read-string "New slug: " (concat agent-slug "-copy")))))
    (when (file-exists-p (ogent-armory-agent-file root target))
      (user-error "Agent already exists: %s" target))
    (plist-put agent :slug target)
    (plist-put agent :name (format "%s Copy" (or (plist-get agent :name)
                                                 agent-slug)))
    (plist-put agent :active t)
    (plist-put agent :archived nil)
    (ogent-armory-write-agent root agent (plist-get agent :body))))

;;;###autoload
(defun ogent-armory-archive-agent (&optional directory agent-slug)
  "Deactivate and archive AGENT-SLUG under DIRECTORY."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (slug (ogent-armory-ui--read-agent root)))
     (list root slug)))
  (let ((root (ogent-armory-ui--root directory)))
    (ogent-armory-update-agent-property root agent-slug "OGENT_ACTIVE" "nil")
    (ogent-armory-update-agent-property root agent-slug "OGENT_ARCHIVED" "t")))

;;; Jobs

(defvar ogent-armory-jobs-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-jobs-visit))
    (define-key map "c" #'ogent-armory-create-job)
    (define-key map "e" #'ogent-armory-jobs-edit)
    (define-key map "P" #'ogent-armory-jobs-edit-prompt)
    (define-key map "R" #'ogent-armory-jobs-run)
    (define-key map "T" #'ogent-armory-jobs-toggle-enabled)
    (define-key map "A" #'ogent-armory-jobs-archive)
    (define-key map "g" #'ogent-armory-jobs-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-jobs-mode'.")

(define-derived-mode ogent-armory-jobs-mode tabulated-list-mode "Armory-Jobs"
  "Major mode for Armory jobs."
  :group 'ogent-ui-armory
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
  (setq-local revert-buffer-function #'ogent-armory-jobs-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-job-next-run (job)
  "Return a friendly next-run description for JOB."
  (cond
   ((plist-get job :archived) "archived")
   ((not (plist-get job :enabled)) "disabled")
   ((ogent-armory--blank-to-nil (plist-get job :cron))
    (format "cron %s" (plist-get job :cron)))
   ((ogent-armory--blank-to-nil (plist-get job :run-after))
    (format "run after %s" (plist-get job :run-after)))
   ((ogent-armory--blank-to-nil (plist-get job :heartbeat))
    (format "heartbeat %s" (plist-get job :heartbeat)))
   (t "manual")))

(defun ogent-armory-jobs--entry (job)
  "Return a tabulated entry for JOB."
  (let* ((agent (plist-get job :agent))
         (job-id (plist-get job :id))
         (file (ogent-armory-job-file ogent-armory-jobs--root agent job-id)))
    (list
     (append (list :type 'job :path file :agent agent :job-id job-id) job)
     (vector
      agent
      (format "%s (%s)" (or (plist-get job :name) job-id) job-id)
      (if (plist-get job :enabled) "yes" "no")
      (ogent-armory-job-next-run job)
      (or (plist-get job :provider) "")
      (or (plist-get job :model) "")
      (or (plist-get job :workspace) "")
      (ogent-armory-ui--format-tags (plist-get job :tags))))))

(defun ogent-armory-jobs--entries ()
  "Return tabulated entries for the current jobs buffer."
  (mapcar #'ogent-armory-jobs--entry
          (ogent-armory-ui--all-jobs ogent-armory-jobs--root
                                      ogent-armory-jobs--agent)))

;;;###autoload
(defun ogent-armory-jobs (&optional directory agent)
  "Open Armory jobs for DIRECTORY, optionally narrowed to AGENT."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))
         nil))
  (let* ((root (ogent-armory-ui--root directory))
         (suffix (or agent "all"))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-jobs-buffer-name-format root suffix))))
    (with-current-buffer buffer
      (ogent-armory-jobs-mode)
      (setq ogent-armory-jobs--root root)
      (setq ogent-armory-jobs--agent agent)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-jobs--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-agent-jobs (&optional directory agent)
  "Open jobs for AGENT under DIRECTORY."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (slug (ogent-armory-ui--read-agent root)))
     (list root slug)))
  (ogent-armory-jobs directory agent))

(defun ogent-armory-jobs-refresh (&rest _)
  "Refresh the Armory jobs buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-jobs--goto (agent job-id)
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

(defun ogent-armory-jobs--item ()
  "Return the job item at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory job at point")))

(defun ogent-armory-jobs-visit ()
  "Visit the Org file for the job at point."
  (interactive)
  (ogent-armory-ui--visit-path (plist-get (ogent-armory-jobs--item) :path)))

(defun ogent-armory-jobs-run ()
  "Run the job at point."
  (interactive)
  (let ((item (ogent-armory-jobs--item)))
    (ogent-armory-run-job ogent-armory-jobs--root
                           (plist-get item :agent)
                           (plist-get item :job-id))))

(defun ogent-armory-jobs-toggle-enabled ()
  "Toggle enabled state for the job at point."
  (interactive)
  (let* ((item (ogent-armory-jobs--item))
         (agent (plist-get item :agent))
         (job-id (plist-get item :job-id))
         (enabled (plist-get item :enabled)))
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     agent
     job-id
     "OGENT_ENABLED"
     (if enabled "nil" "t"))
    (ogent-armory-jobs-refresh)
    (ogent-armory-jobs--goto agent job-id)))

(defun ogent-armory-jobs-archive ()
  "Archive the job at point."
  (interactive)
  (let ((item (ogent-armory-jobs--item)))
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ARCHIVED"
     "t")
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ENABLED"
     "nil")
    (ogent-armory-jobs-refresh)))

(defun ogent-armory-jobs-edit ()
  "Edit one metadata property for the job at point."
  (interactive)
  (let* ((item (ogent-armory-jobs--item))
         (property (completing-read "Property: "
                                    ogent-armory-job-editable-properties
                                    nil t))
         (value (read-string (format "%s: " property)))
         (candidate (ogent-armory-ui--job-with-property item property value)))
    (ogent-armory-validate-job candidate)
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     property
     value)
    (ogent-armory-jobs-refresh)))

(defun ogent-armory-jobs-edit-prompt ()
  "Visit the job prompt/body for the job at point."
  (interactive)
  (ogent-armory-ui--visit-body
   (plist-get (ogent-armory-jobs--item) :path)))

;;;###autoload
(defun ogent-armory-create-job (&optional directory agent)
  "Create a Armory job under DIRECTORY for AGENT."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (slug (ogent-armory-ui--read-agent root)))
     (list root slug)))
  (let* ((root (ogent-armory-ui--root directory))
         (slug (or agent (ogent-armory-ui--read-agent root)))
         (name (read-string "Job name: "))
         (job-id (ogent-armory-ui--read-string-default
                  "Job id: "
                  (ogent-armory--slug name "job")))
         (cron (read-string "Cron: "))
         (heartbeat (read-string "Heartbeat: "))
         (provider (read-string "Provider override: "))
         (model (read-string "Model override: "))
         (workspace (ogent-armory-ui--read-string-default "Workspace: " "/"))
         (tags (ogent-armory--tags-from-string (read-string "Tags: ")))
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
    (when (file-exists-p (ogent-armory-job-file root slug job-id))
      (user-error "Job already exists: %s" job-id))
    (ogent-armory-validate-job job)
    (let ((file (ogent-armory-write-job root slug job prompt)))
      (ogent-armory-ui--refresh-home-buffer root)
      file)))

;;; Tasks

(defvar ogent-armory-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-tasks-visit)
    (define-key map (kbd "<return>") #'ogent-armory-tasks-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-tasks-visit)
    (define-key map "R" #'ogent-armory-tasks-run)
    (define-key map "A" #'ogent-armory-tasks-archive)
    (define-key map "U" #'ogent-armory-tasks-unarchive)
    (define-key map "b" #'ogent-armory-tasks-board-view)
    (define-key map "l" #'ogent-armory-tasks-list-view)
    (define-key map "S" #'ogent-armory-tasks-schedule-view)
    (define-key map "e" #'ogent-armory-tasks-edit)
    (define-key map "f" #'ogent-armory-tasks-filter)
    (define-key map "g" #'ogent-armory-tasks-refresh)
    (define-key map "s" #'ogent-armory-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-tasks-mode'.")

(define-derived-mode ogent-armory-tasks-mode tabulated-list-mode "Armory-Tasks"
  "Major mode for Armory attention lanes."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Lane" 16 t)
               ("Type" 10 t)
               ("Agent" 14 t)
               ("Item" 32 t)
               ("State" 18 t)
               ("When" 24 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-tasks-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-tasks--job-item (root job)
  "Return a task item for JOB under ROOT."
  (let ((stale (ogent-armory-ui--stale-job-p root job))
        (scheduled (or (ogent-armory--blank-to-nil (plist-get job :cron))
                       (ogent-armory--blank-to-nil
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
          :path (ogent-armory-job-file
                 root
                 (plist-get job :agent)
                 (plist-get job :id)))))

(defun ogent-armory-tasks--session-lane (session)
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

(defun ogent-armory-tasks--session-item (session)
  "Return a task item for SESSION."
  (list :type 'session
        :lane (ogent-armory-tasks--session-lane session)
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

(defun ogent-armory-tasks--running-items (root)
  "Return live runner task items under ROOT."
  (delq
   nil
   (mapcar
    (lambda (slug)
      (when (ogent-armory-runner-running-p slug)
        (list :type 'agent
              :lane "Running"
              :agent slug
              :name slug
              :state "running"
              :when ""
              :path (ogent-armory-agent-file root slug))))
    (ogent-armory-ui--agent-slugs root))))

(defun ogent-armory-tasks--items ()
  "Return task items for the current Armory task buffer."
  (let ((root ogent-armory-tasks--root)
        items)
    (dolist (slug (ogent-armory-ui--agent-slugs root))
      (dolist (job (ogent-armory-ui--agent-jobs root slug))
        (push (ogent-armory-tasks--job-item root job) items)))
    (dolist (session (ogent-armory-ui--all-sessions root))
      (push (ogent-armory-tasks--session-item session) items))
    (setq items (append (ogent-armory-tasks--running-items root) items))
    (let ((filters ogent-armory-tasks--filters))
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
    (ogent-armory-tasks--sort-items (nreverse items))))

(defun ogent-armory-tasks--item-time (item)
  "Return the best sortable timestamp for ITEM."
  (or (plist-get item :scheduled-at)
      (plist-get item :last-activity)
      (plist-get item :when)
      ""))

(defun ogent-armory-tasks--item-less-p (left right)
  "Return non-nil when LEFT should sort before RIGHT."
  (let ((left-order (plist-get left :board-order))
        (right-order (plist-get right :board-order)))
    (cond
     ((and left-order right-order (not (= left-order right-order)))
      (< left-order right-order))
     (left-order t)
     (right-order nil)
     ((not (equal (ogent-armory-tasks--item-time left)
                  (ogent-armory-tasks--item-time right)))
      (string> (ogent-armory-tasks--item-time left)
               (ogent-armory-tasks--item-time right)))
     (t
      (string< (or (plist-get left :name) "")
               (or (plist-get right :name) ""))))))

(defun ogent-armory-tasks--sort-items (items)
  "Return ITEMS in task-board display order."
  (seq-sort #'ogent-armory-tasks--item-less-p items))

(defun ogent-armory-tasks--scheduled-item-p (item)
  "Return non-nil when ITEM has scheduling metadata."
  (or (ogent-armory--blank-to-nil (plist-get item :scheduled))
      (ogent-armory--blank-to-nil (plist-get item :scheduled-at))
      (ogent-armory--blank-to-nil (plist-get item :scheduled-key))))

(defun ogent-armory-tasks--entry (item)
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

(defun ogent-armory-tasks--entries ()
  "Return tabulated list entries for the current Armory task buffer."
  (let ((items (ogent-armory-tasks--items)))
    (pcase ogent-armory-tasks--view
      ('list
       (mapcar #'ogent-armory-tasks--entry items))
      ('schedule
       (mapcar #'ogent-armory-tasks--entry
               (seq-filter #'ogent-armory-tasks--scheduled-item-p items)))
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
                 (mapcar #'ogent-armory-tasks--entry
                         (ogent-armory-tasks--sort-items lane-items))
               (list (ogent-armory-tasks--entry
                      (list :type 'empty
                            :lane lane
                            :agent ""
                            :name "(empty)"
                            :state ""
                            :when ""))))))
         ogent-armory-task-lanes))))))

;;;###autoload
(defun ogent-armory-tasks (&optional directory)
  "Open Armory attention lanes for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-tasks-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-tasks-mode)
      (setq ogent-armory-tasks--root root)
      (setq ogent-armory-tasks--filters nil)
      (setq ogent-armory-tasks--view 'board)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-tasks--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-tasks-refresh (&rest _)
  "Refresh the Armory task lane buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-tasks-board-view ()
  "Show Armory tasks as attention lanes."
  (interactive)
  (setq ogent-armory-tasks--view 'board)
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-list-view ()
  "Show Armory tasks as a flat list."
  (interactive)
  (setq ogent-armory-tasks--view 'list)
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-schedule-view ()
  "Show Armory tasks with scheduling metadata."
  (interactive)
  (setq ogent-armory-tasks--view 'schedule)
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-visit ()
  "Visit the Armory task item at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (when (eq (plist-get item :type) 'empty)
      (user-error "No Armory task at point"))
    (ogent-armory-ui--visit-path (plist-get item :path))))

(defun ogent-armory-tasks-run ()
  "Run or retry the Armory task at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-run-job
        ogent-armory-tasks--root
        (plist-get item :agent)
        (plist-get item :job-id)))
      ('session
       (if-let ((job-id (plist-get item :job-id)))
           (ogent-armory-run-job
            ogent-armory-tasks--root
            (plist-get item :agent)
            job-id)
         (ogent-armory-run-agent
          ogent-armory-tasks--root
          (plist-get item :agent)
          (read-string "Instruction: "))))
      (_
       (user-error "No runnable Armory task at point")))))

(defun ogent-armory-tasks-archive ()
  "Archive the Armory task at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-ui--put-property
        (plist-get item :path)
        "OGENT_ENABLED"
        "nil"))
      ('session
       (ogent-armory-ui--put-property
        (plist-get item :path)
        "OGENT_ARCHIVED"
        "t"))
      (_
       (user-error "No archivable Armory task at point"))))
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-unarchive ()
  "Unarchive the Armory task at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil")
       (ogent-armory-ui--put-property (plist-get item :path) "OGENT_ENABLED" "t"))
      ('session
       (ogent-armory-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil"))
      (_
       (user-error "No archived Armory task at point"))))
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-edit ()
  "Edit metadata for the Armory task at point."
  (interactive)
  (let* ((item (ogent-armory-ui--item-at-point))
         (property (pcase (plist-get item :type)
                     ('job (completing-read "Property: "
                                            ogent-armory-job-editable-properties
                                            nil t))
                     ('session (completing-read "Property: "
                                                '("OGENT_ARCHIVED" "OGENT_TAGS")
                                                nil t))
                     (_ (user-error "No editable Armory task at point"))))
         (value (read-string (format "%s: " property))))
    (when (eq (plist-get item :type) 'job)
      (ogent-armory-validate-job
       (ogent-armory-ui--job-with-property item property value)))
    (ogent-armory-ui--put-property (plist-get item :path) property value)
    (ogent-armory-tasks-refresh)))

(defun ogent-armory-tasks-filter ()
  "Set simple task board filters."
  (interactive)
  (setq ogent-armory-tasks--filters
        (list :agent (ogent-armory--blank-to-nil
                      (read-string "Agent filter: "))
              :status (ogent-armory--blank-to-nil
                       (read-string "Status filter: "))))
  (ogent-armory-tasks-refresh))

;;; Conversations

(defvar ogent-armory-conversations-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-conversations-open))
    (define-key map "R" #'ogent-armory-conversations-retry)
    (define-key map "A" #'ogent-armory-conversations-archive)
    (define-key map "U" #'ogent-armory-conversations-unarchive)
    (define-key map "v" #'ogent-armory-conversations-visit-source)
    (define-key map "s" #'ogent-armory-conversations-search)
    (define-key map "f" #'ogent-armory-conversations-filter)
    (define-key map "g" #'ogent-armory-conversations-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-conversations-mode'.")

(define-derived-mode ogent-armory-conversations-mode tabulated-list-mode
  "Armory-Conversations"
  "Major mode for Armory conversation lists."
  :group 'ogent-ui-armory
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
  (setq-local revert-buffer-function #'ogent-armory-conversations-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-conversations--matches-p (session)
  "Return non-nil when SESSION matches current filters."
  (let ((filters ogent-armory-conversations--filters))
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
                 (ogent-armory--truth-value (plist-get filters :archived)))))))

(defun ogent-armory-conversations--entry (session)
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

(defun ogent-armory-conversations--entries ()
  "Return conversation entries for the current buffer."
  (let* ((sessions (ogent-armory-ui--all-sessions
                    ogent-armory-conversations--root))
         (matches (seq-filter #'ogent-armory-conversations--matches-p
                              sessions)))
    (if matches
        (mapcar #'ogent-armory-conversations--entry matches)
      (list
       (list nil
             (vector "" "" ""
                     (if sessions
                         "No conversations match filters"
                       "No conversations yet")
                     "" "" "" "" ""))))))

;;;###autoload
(defun ogent-armory-conversations (&optional directory filters)
  "Open Armory conversations for DIRECTORY with optional FILTERS."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))
         nil))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-conversations-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-conversations-mode)
      (setq ogent-armory-conversations--root root)
      (setq ogent-armory-conversations--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-conversations--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-conversations-refresh (&rest _)
  "Refresh the Armory conversations buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-conversations--item ()
  "Return the conversation at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory conversation at point")))

(defun ogent-armory-conversations-open ()
  "Open the conversation at point."
  (interactive)
  (ogent-armory-conversation
   ogent-armory-conversations--root
   (plist-get (ogent-armory-conversations--item) :path)))

(defun ogent-armory-conversations-visit-source ()
  "Visit the Org source file for the conversation at point."
  (interactive)
  (ogent-armory-ui--visit-path
   (plist-get (ogent-armory-conversations--item) :path)))

(defun ogent-armory-conversations-retry ()
  "Retry the conversation at point when it links to a job."
  (interactive)
  (let ((item (ogent-armory-conversations--item)))
    (if-let ((job-id (plist-get item :job-id)))
        (ogent-armory-run-job ogent-armory-conversations--root
                               (plist-get item :agent)
                               job-id)
      (ogent-armory-run-agent ogent-armory-conversations--root
                               (plist-get item :agent)
                               (read-string "Instruction: ")))))

(defun ogent-armory-conversations-archive ()
  "Archive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-armory-conversations--item) :path)))
    (ogent-armory-ui--conversation-update-properties
     ogent-armory-conversations--root path
     '(("OGENT_ARCHIVED" . "t")
       ("OGENT_STATUS" . "archived"))
     "conversation.archived"))
  (ogent-armory-conversations-refresh))

(defun ogent-armory-conversations-unarchive ()
  "Unarchive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-armory-conversations--item) :path)))
    (ogent-armory-ui--conversation-update-properties
     ogent-armory-conversations--root path
     '(("OGENT_ARCHIVED" . "nil")
       ("OGENT_STATUS" . "done"))
     "conversation.unarchived"))
  (ogent-armory-conversations-refresh))

(defun ogent-armory-conversations-filter ()
  "Set simple conversation filters."
  (interactive)
  (setq ogent-armory-conversations--filters
        (list :agent (ogent-armory--blank-to-nil
                      (read-string "Agent filter: "))
              :status (ogent-armory--blank-to-nil
                       (read-string "Status filter: "))
              :tag (ogent-armory--blank-to-nil
                    (read-string "Tag filter: "))))
  (ogent-armory-conversations-refresh))

(defun ogent-armory-conversations-search ()
  "Search within Armory conversations."
  (interactive)
  (ogent-armory-search ogent-armory-conversations--root
                        (read-string "Search conversations: ")
                        (list :kind 'session)))

(defvar ogent-armory-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>" "v"))
      (define-key map (kbd key) #'ogent-armory-conversation-visit-source))
    (define-key map "c" #'ogent-armory-conversation-continue)
    (define-key map "k" #'ogent-armory-conversation-stop)
    (define-key map "R" #'ogent-armory-conversation-retry)
    (define-key map "d" #'ogent-armory-conversation-mark-done)
    (define-key map "A" #'ogent-armory-conversation-archive)
    (define-key map "U" #'ogent-armory-conversation-unarchive)
    (define-key map "m" #'ogent-armory-conversation-mute)
    (define-key map "M" #'ogent-armory-conversation-unmute)
    (define-key map "C" #'ogent-armory-conversation-compact)
    (define-key map "D" #'ogent-armory-conversation-delete)
    (define-key map "y" #'ogent-armory-conversation-copy-link)
    (define-key map "o" #'ogent-armory-conversation-open-artifacts)
    (define-key map "l" #'ogent-armory-conversation-open-logs)
    (define-key map "g" #'ogent-armory-conversation-refresh)
    (define-key map (kbd "TAB") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-armory-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-armory-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-armory-ui-previous-section)
    (define-key map (kbd "^") #'ogent-armory-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-conversation-mode'.")

(ogent-armory-ui--define-section-mode ogent-armory-conversation-mode
                                       "Armory-Conversation"
                                       "Major mode for a single Armory conversation."
                                       (setq-local revert-buffer-function #'ogent-armory-conversation-refresh)
                                       (setq-local truncate-lines nil)
                                       (setq-local buffer-read-only t)
                                       (ogent-armory-ui--configure-section-buffer)
                                       (setq header-line-format
                                             "c continue  k stop  R retry  d done  A/U archive  m/M mute  C compact  D delete  y link  o artifacts  l logs"))

;;;###autoload
(defun ogent-armory-conversation (&optional directory file)
  "Open Armory conversation FILE under DIRECTORY."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (session (completing-read
                    "Conversation: "
                    (mapcar (lambda (item)
                              (plist-get item :path))
                            (ogent-armory-ui--all-sessions root))
                    nil t)))
     (list root session)))
  (let* ((root (ogent-armory-ui--root directory))
         (raw-path (or file (plist-get (ogent-armory-conversations--item) :path)))
         (path (if (and raw-path (file-exists-p raw-path))
                   (file-truename raw-path)
                 raw-path))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-conversation-buffer-name-format
                   root
                   (file-name-base path)))))
    (with-current-buffer buffer
      (ogent-armory-conversation-mode)
      (setq ogent-armory-conversation--root root)
      (setq ogent-armory-conversation--file path)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-conversation-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-conversation-refresh (&rest _)
  "Refresh this conversation detail buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-armory-conversation--insert-buffer)
    (goto-char (point-min))))

(defun ogent-armory-conversation--insert-buffer ()
  "Insert the current conversation detail."
  (ogent-armory-ui--with-root-section (ogent-armory-conversation-root)
                                       (ogent-armory-conversation--insert-buffer-content)))

(defun ogent-armory-conversation--insert-actions (detail)
  "Insert the action panel for DETAIL."
  (ogent-armory-ui--with-section (ogent-armory-conversation-actions)
                                  (ogent-armory-ui--heading-text "Actions")
                                  (insert "  c continue   k stop       R retry      d mark done\n")
                                  (insert "  A archive    U unarchive  m mute       M unmute\n")
                                  (insert "  C compact    D delete     y copy link  o artifacts  l logs\n")
                                  (when (plist-get detail :awaiting-input)
                                    (insert (propertize "  Awaiting user input\n"
                                                        'face 'ogent-armory-ui-warning)))))

(defun ogent-armory-conversation--insert-turns (turns)
  "Insert conversation TURNS."
  (ogent-armory-ui--with-section (ogent-armory-conversation-turns)
                                  (ogent-armory-ui--heading-text "Turns")
                                  (if turns
                                      (dolist (turn turns)
                                        (insert
                                         (propertize
                                          (format "  %03d %s %s\n"
                                                  (or (plist-get turn :turn) 0)
                                                  (upcase (or (plist-get turn :role) "turn"))
                                                  (or (plist-get turn :ts) ""))
                                          'face 'ogent-armory-ui-dim))
                                        (when-let ((tokens (plist-get turn :tokens)))
                                          (insert
                                           (format "  tokens input=%s output=%s cache=%s\n"
                                                   (or (plist-get tokens :input) "")
                                                   (or (plist-get tokens :output) "")
                                                   (or (plist-get tokens :cache) ""))))
                                        (insert (string-trim-right (or (plist-get turn :content) "")) "\n\n"))
                                    (insert (propertize "  No turn files recorded\n"
                                                        'face 'ogent-armory-ui-dim)))))

(defun ogent-armory-conversation--insert-artifacts (root detail)
  "Insert artifacts listed by DETAIL under ROOT."
  (let ((artifacts (ogent-armory-ui--conversation-artifacts detail)))
    (ogent-armory-ui--with-section (ogent-armory-conversation-artifacts)
                                    (ogent-armory-ui--heading-text "Artifacts")
                                    (if artifacts
                                        (dolist (artifact artifacts)
                                          (let ((path (ogent-armory-ui--artifact-path root artifact)))
                                            (ogent-armory-ui--insert-item-line
                                             (list :type 'artifact :path path)
                                             (format "  %s" artifact))))
                                      (insert (propertize "  No artifacts recorded\n"
                                                          'face 'ogent-armory-ui-dim))))))

(defun ogent-armory-conversation--insert-events (events)
  "Insert conversation EVENTS."
  (ogent-armory-ui--with-section (ogent-armory-conversation-events)
                                  (ogent-armory-ui--heading-text "Events")
                                  (if events
                                      (dolist (event events)
                                        (insert
                                         (format "  %06d %-24s %s\n"
                                                 (or (plist-get event :seq) 0)
                                                 (or (plist-get event :type) "")
                                                 (or (plist-get event :ts) "")))
                                        (when-let ((payload (ogent-armory--blank-to-nil
                                                             (plist-get event :payload))))
                                          (insert "  " (string-trim payload) "\n")))
                                    (insert (propertize "  No events recorded\n"
                                                        'face 'ogent-armory-ui-dim)))))

(defun ogent-armory-conversation--insert-runtime (detail)
  "Insert runtime metadata for DETAIL."
  (ogent-armory-ui--with-section (ogent-armory-conversation-runtime)
                                  (ogent-armory-ui--heading-text "Runtime")
                                  (ogent-armory-ui--insert-kv "Adapter" (plist-get detail :adapter))
                                  (ogent-armory-ui--insert-kv "Runtime" (plist-get detail :runtime-mode))
                                  (ogent-armory-ui--insert-kv "Effort" (plist-get detail :effort))
                                  (ogent-armory-ui--insert-kv "Context" (plist-get detail :context-window))
                                  (ogent-armory-ui--insert-kv "Resume" (plist-get detail :last-resume-result))
                                  (when (or (plist-get detail :tokens-input)
                                            (plist-get detail :tokens-output)
                                            (plist-get detail :tokens-cache)
                                            (plist-get detail :tokens-total))
                                    (ogent-armory-ui--insert-kv
                                     "Tokens"
                                     (format "input=%s output=%s cache=%s total=%s"
                                             (or (plist-get detail :tokens-input) "")
                                             (or (plist-get detail :tokens-output) "")
                                             (or (plist-get detail :tokens-cache) "")
                                             (or (plist-get detail :tokens-total) ""))))))

(defun ogent-armory-conversation--insert-buffer-content ()
  "Insert the current conversation detail sections."
  (let ((detail (ogent-armory-ui--conversation-detail
                 ogent-armory-conversation--root
                 ogent-armory-conversation--file)))
    (insert (propertize (or (plist-get detail :name)
                            (plist-get detail :id))
                        'face 'ogent-armory-ui-heading)
            "\n\n")
    (ogent-armory-conversation--insert-actions detail)
    (insert "\n")
    (ogent-armory-ui--with-section (ogent-armory-conversation-metadata)
                                    (ogent-armory-ui--heading-text "Metadata")
                                    (ogent-armory-ui--insert-kv "Status" (plist-get detail :status))
                                    (ogent-armory-ui--insert-kv "Agent" (plist-get detail :agent))
                                    (ogent-armory-ui--insert-kv "Job" (plist-get detail :job-id))
                                    (ogent-armory-ui--insert-kv "Trigger" (plist-get detail :trigger))
                                    (ogent-armory-ui--insert-kv "Provider" (plist-get detail :provider))
                                    (ogent-armory-ui--insert-kv "Model" (plist-get detail :model))
                                    (ogent-armory-ui--insert-kv "Exit status"
                                                                 (when (plist-get detail :exit-status)
                                                                   (number-to-string
                                                                    (plist-get detail :exit-status))))
                                    (ogent-armory-ui--insert-kv "Duration" (plist-get detail :duration))
                                    (ogent-armory-ui--insert-kv "Started" (plist-get detail :started))
                                    (ogent-armory-ui--insert-kv "Finished" (plist-get detail :finished))
                                    (ogent-armory-ui--insert-kv "Last activity"
                                                                 (plist-get detail :last-activity))
                                    (ogent-armory-ui--insert-kv "Archived"
                                                                 (if (plist-get detail :archived) "yes" "no"))
                                    (ogent-armory-ui--insert-kv "Muted"
                                                                 (if (plist-get detail :muted) "yes" "no")))
    (insert "\n")
    (ogent-armory-conversation--insert-runtime detail)
    (insert "\n")
    (when (or (plist-get detail :summary)
              (plist-get detail :context-summary))
      (ogent-armory-ui--with-section (ogent-armory-conversation-summary)
                                      (ogent-armory-ui--heading-text "Summary")
                                      (when-let ((summary (plist-get detail :summary)))
                                        (insert summary "\n"))
                                      (when-let ((context (plist-get detail :context-summary)))
                                        (insert "\nContext\n" context "\n")))
      (insert "\n"))
    (when (plist-get detail :turns)
      (ogent-armory-conversation--insert-turns (plist-get detail :turns))
      (insert "\n"))
    (ogent-armory-ui--with-section (ogent-armory-conversation-prompt)
                                    (ogent-armory-ui--heading-text "Prompt")
                                    (insert (or (plist-get detail :prompt) "") "\n"))
    (insert "\n")
    (ogent-armory-ui--with-section (ogent-armory-conversation-output)
                                    (ogent-armory-ui--heading-text "Output")
                                    (insert (or (plist-get detail :output) "") "\n"))
    (insert "\n")
    (when (plist-get detail :tools)
      (ogent-armory-ui--with-section (ogent-armory-conversation-tools)
                                      (ogent-armory-ui--heading-text "Tool Blocks")
                                      (dolist (tool (plist-get detail :tools))
                                        (insert (format "  %s\n%s\n" (plist-get tool :header)
                                                        (plist-get tool :body)))))
      (insert "\n"))
    (when (ogent-armory--blank-to-nil (plist-get detail :runtime-trace))
      (ogent-armory-ui--with-section (ogent-armory-conversation-runtime-trace)
                                      (ogent-armory-ui--heading-text "Runtime Trace")
                                      (insert (plist-get detail :runtime-trace) "\n"))
      (insert "\n"))
    (when (ogent-armory--blank-to-nil (plist-get detail :error))
      (ogent-armory-ui--with-section (ogent-armory-conversation-error)
                                      (ogent-armory-ui--heading-text "Error")
                                      (insert (plist-get detail :error) "\n"))
      (insert "\n"))
    (ogent-armory-conversation--insert-artifacts
     ogent-armory-conversation--root detail)
    (insert "\n")
    (ogent-armory-conversation--insert-events (plist-get detail :events))
    (insert "\n")
    (ogent-armory-ui--with-section (ogent-armory-conversation-source)
                                    (ogent-armory-ui--heading-text "Source Org")
                                    (ogent-armory-ui--insert-item-line
                                     (list :type 'file :path (plist-get detail :path))
                                     (format "  %s" (plist-get detail :path))))))

(defun ogent-armory-conversation-visit-source ()
  "Visit the Org source for this conversation."
  (interactive)
  (ogent-armory-ui--visit-path ogent-armory-conversation--file))

(defun ogent-armory-conversation--detail ()
  "Return detail for the current conversation buffer."
  (ogent-armory-ui--conversation-detail
   ogent-armory-conversation--root
   ogent-armory-conversation--file))

(defun ogent-armory-conversation--canonical-id ()
  "Return current canonical conversation id or nil."
  (when (ogent-armory-ui--canonical-conversation-path-p
         ogent-armory-conversation--file)
    (ogent-armory-ui--canonical-conversation-id
     ogent-armory-conversation--file)))

(defun ogent-armory-conversation-continue (instruction)
  "Continue this conversation with INSTRUCTION."
  (interactive (list (read-string "Continue: ")))
  (let* ((detail (ogent-armory-conversation--detail))
         (agent (plist-get detail :agent))
         (job-id (plist-get detail :job-id))
         (conversation-id (ogent-armory-conversation--canonical-id)))
    (unless agent
      (user-error "Conversation has no agent"))
    (if conversation-id
        (let* ((replay
                (ogent-armory-conversation-replay-prompt
                 ogent-armory-conversation--root conversation-id instruction))
               (keywords
                (append
                 (when job-id (list :job-id job-id))
                 (list :instruction replay
                       :conversation-id conversation-id
                       :conversation-title (plist-get detail :name)
                       :turn-content instruction
                       :trigger "manual"
                       :last-resume-result "replay")))
               (plan (apply #'ogent-armory-runner-plan
                            ogent-armory-conversation--root
                            agent
                            keywords)))
          (when (ogent-armory-runner--confirm plan)
            (ogent-armory-runner-start plan)
            (ogent-armory-conversation-refresh)))
      (ogent-armory-run-agent
       ogent-armory-conversation--root agent instruction))))

(defun ogent-armory-conversation-stop ()
  "Stop this conversation when it has a live process."
  (interactive)
  (let ((conversation-id (ogent-armory-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be stopped"))
    (unless (ogent-armory-runner-stop-conversation
             ogent-armory-conversation--root conversation-id)
      (user-error "No live process for conversation %s" conversation-id)))
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-retry ()
  "Retry this conversation."
  (interactive)
  (let ((detail (ogent-armory-conversation--detail)))
    (if-let ((job-id (plist-get detail :job-id)))
        (ogent-armory-run-job ogent-armory-conversation--root
                               (plist-get detail :agent)
                               job-id)
      (ogent-armory-run-agent ogent-armory-conversation--root
                               (plist-get detail :agent)
                               (read-string "Instruction: ")))))

(defun ogent-armory-conversation-mark-done ()
  "Mark this conversation done."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   `(("OGENT_STATUS" . "done")
     ("OGENT_AWAITING_INPUT" . "nil")
     ("OGENT_EXIT_CODE" . "0")
     ("OGENT_COMPLETED_AT" . ,(ogent-armory-ui--iso-now)))
   "conversation.marked_done")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-archive ()
  "Archive this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_ARCHIVED" . "t")
     ("OGENT_STATUS" . "archived"))
   "conversation.archived")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-unarchive ()
  "Unarchive this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_ARCHIVED" . "nil")
     ("OGENT_STATUS" . "done"))
   "conversation.unarchived")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-mute ()
  "Mute this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_MUTED" . "t"))
   "conversation.muted")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-unmute ()
  "Unmute this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_MUTED" . "nil"))
   "conversation.unmuted")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-compact (&optional summary)
  "Compact this canonical conversation with optional SUMMARY."
  (interactive)
  (let ((conversation-id (ogent-armory-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be compacted"))
    (ogent-armory-conversation-compact-record
     ogent-armory-conversation--root
     conversation-id
     summary))
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-delete (&optional force)
  "Delete this conversation.
With FORCE, skip confirmation."
  (interactive "P")
  (let ((path ogent-armory-conversation--file)
        (buffer (current-buffer)))
    (when (or force
              (yes-or-no-p
               (format "Delete Armory conversation %s? "
                       (abbreviate-file-name path))))
      (if (ogent-armory-ui--canonical-conversation-path-p path)
          (delete-directory (file-name-directory path) t)
        (delete-file path))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-armory-conversation-copy-link ()
  "Copy a stable link to this conversation."
  (interactive)
  (let ((link (if-let ((conversation-id
                        (ogent-armory-conversation--canonical-id)))
                  (format "ogent-armory:%s" conversation-id)
                ogent-armory-conversation--file)))
    (kill-new link)
    (message "Copied %s" link)))

(defun ogent-armory-conversation-open-artifacts ()
  "Open the first artifact declared by this conversation."
  (interactive)
  (let* ((detail (ogent-armory-conversation--detail))
         (artifact (car (ogent-armory-ui--conversation-artifacts detail)))
         (path (ogent-armory-ui--artifact-path
                ogent-armory-conversation--root artifact)))
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

(defun ogent-armory-conversation-open-logs ()
  "Open the event log for this conversation."
  (interactive)
  (if-let ((conversation-id (ogent-armory-conversation--canonical-id)))
      (find-file
       (ogent-armory-conversation-events-file
        ogent-armory-conversation--root conversation-id))
    (ogent-armory-conversation-visit-source)))

;;; Search

(defvar ogent-armory-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-search-visit)
    (define-key map (kbd "<return>") #'ogent-armory-search-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-search-visit)
    (define-key map "g" #'ogent-armory-search-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-search-mode'.")

(define-derived-mode ogent-armory-search-mode tabulated-list-mode "Armory-Search"
  "Major mode for Armory search results."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Kind" 10 t)
               ("File" 30 t)
               ("Line" 6 nil :right-align t)
               ("Match" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-search-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-search--entries ()
  "Return tabulated entries for the current Armory search buffer."
  (if (string-blank-p (or ogent-armory-search--query ""))
      (list (list nil (vector "" "" "" "Enter a search query to search this Armory.")))
    (mapcar
     (lambda (result)
       (let ((path (plist-get result :path)))
         (list
          result
          (vector
           (symbol-name (plist-get result :kind))
           (file-relative-name path ogent-armory-search--root)
           (number-to-string (plist-get result :line))
           (plist-get result :text)))))
     (apply #'ogent-armory-search-records
            ogent-armory-search--root
            ogent-armory-search--query
            ogent-armory-search--filters))))

;;;###autoload
(defun ogent-armory-search (&optional directory query filters)
  "Search Armory Org records under DIRECTORY for QUERY and FILTERS."
  (interactive
   (let ((root (ogent-armory-ui--root
                (or (ogent-armory-find-root)
                    (read-directory-name "Armory root: ")))))
     (list root (read-string "Search Armory: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (search-query (or query (read-string "Search Armory: ")))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-search-buffer-name-format
                   root
                   search-query))))
    (with-current-buffer buffer
      (ogent-armory-search-mode)
      (setq ogent-armory-search--root root)
      (setq ogent-armory-search--query search-query)
      (setq ogent-armory-search--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-search--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-search-refresh (&rest _)
  "Refresh the current Armory search results."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-search-visit ()
  "Visit the Armory search result at point."
  (interactive)
  (let ((result (tabulated-list-get-id)))
    (unless result
      (user-error "No Armory search result at point"))
    (ogent-armory-ui--file-line
     (plist-get result :path)
     (plist-get result :line))))

;;; Apps

(defvar ogent-armory-apps-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-apps-open))
    (define-key map "v" #'ogent-armory-apps-visit-directory)
    (define-key map "g" #'ogent-armory-apps-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-apps-mode'.")

(define-derived-mode ogent-armory-apps-mode tabulated-list-mode "Armory-Apps"
  "Major mode for Armory app artifacts."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Label" 30 t)
               ("Owner" 18 t)
               ("Modified" 18 t)
               ("Path" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Modified" . t))
  (setq-local revert-buffer-function #'ogent-armory-apps-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-apps--entry (app)
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

(defun ogent-armory-apps--entries ()
  "Return app entries for the current Armory apps buffer."
  (let ((apps (ogent-armory-list-apps ogent-armory-apps--root)))
    (if apps
        (mapcar #'ogent-armory-apps--entry apps)
      (list (list nil (vector "No app artifacts" "" "" ""))))))

;;;###autoload
(defun ogent-armory-apps (&optional directory)
  "Open the Armory app artifact list for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-apps-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-apps-mode)
      (setq ogent-armory-apps--root root)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-apps--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-apps-refresh (&rest _)
  "Refresh the Armory apps buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-apps--item ()
  "Return the app item at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory app at point")))

(defun ogent-armory-apps-open ()
  "Open the app artifact at point in a browser."
  (interactive)
  (ogent-armory-open-file (plist-get (ogent-armory-apps--item) :path)))

(defun ogent-armory-apps-visit-directory ()
  "Visit the app directory at point."
  (interactive)
  (dired (plist-get (ogent-armory-apps--item) :directory)))

;;;###autoload
(defun ogent-armory-open-app (&optional directory)
  "Open an index.html app artifact under DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (apps (ogent-armory-list-apps root)))
    (unless apps
      (user-error "No Armory index.html apps under %s" root))
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

(defun ogent-armory-ui--section-keymaps ()
  "Return Armory UI keymaps that contain collapsible sections."
  (list ogent-armory-home-mode-map
        ogent-armory-agent-mode-map
        ogent-armory-conversation-mode-map))

(defun ogent-armory-ui--setup-section-keymaps ()
  "Wire Magit section parent keymaps into section-capable Armory buffers."
  (when (and (ogent-armory-ui--magit-section-usable-p)
             (boundp 'magit-section-mode-map))
    (dolist (map (ogent-armory-ui--section-keymaps))
      (set-keymap-parent map magit-section-mode-map))))

(ogent-armory-ui--setup-section-keymaps)

(with-eval-after-load 'magit-section
  (ogent-armory-ui--setup-section-keymaps))

(defun ogent-armory-ui--evil-refresh-command ()
  "Return the refresh command for the current Armory UI mode."
  (pcase major-mode
    ('ogent-armory-home-mode 'ogent-armory-home-refresh)
    ('ogent-armory-agents-mode 'ogent-armory-agents-refresh)
    ('ogent-armory-agent-mode 'ogent-armory-agent-refresh)
    ('ogent-armory-jobs-mode 'ogent-armory-jobs-refresh)
    ('ogent-armory-tasks-mode 'ogent-armory-tasks-refresh)
    ('ogent-armory-conversations-mode 'ogent-armory-conversations-refresh)
    ('ogent-armory-conversation-mode 'ogent-armory-conversation-refresh)
    ('ogent-armory-search-mode 'ogent-armory-search-refresh)
    ('ogent-armory-apps-mode 'ogent-armory-apps-refresh)))

(defun ogent-armory-ui--evil-section-mode-p ()
  "Return non-nil when the current Armory UI mode has collapsible sections."
  (memq major-mode
        '(ogent-armory-home-mode
          ogent-armory-agent-mode
          ogent-armory-conversation-mode)))

(defun ogent-armory-ui--evil-bind-local (key command)
  "Bind Evil normal-state KEY to COMMAND when COMMAND is available."
  (when (and (fboundp 'evil-local-set-key)
             (fboundp command))
    (evil-local-set-key 'normal key command)))

(defun ogent-armory-ui--evil-local-keys ()
  "Install local Evil normal-state keys for Armory UI buffers."
  (ogent-armory-ui--evil-bind-local "j" 'evil-next-line)
  (ogent-armory-ui--evil-bind-local "k" 'evil-previous-line)
  (ogent-armory-ui--evil-bind-local "gg" 'evil-goto-first-line)
  (ogent-armory-ui--evil-bind-local "G" 'evil-goto-line)
  (when-let ((refresh (ogent-armory-ui--evil-refresh-command)))
    (ogent-armory-ui--evil-bind-local "gr" refresh))
  (when (ogent-armory-ui--evil-section-mode-p)
    (ogent-armory-ui--evil-bind-local "gj" 'ogent-armory-ui-next-section)
    (ogent-armory-ui--evil-bind-local "gk" 'ogent-armory-ui-previous-section))
  (ogent-armory-ui--evil-bind-local "ZZ" 'quit-window)
  (ogent-armory-ui--evil-bind-local "ZQ" 'quit-window))

(defun ogent-armory-ui--setup-evil ()
  "Set up Evil integration for Armory UI buffers."
  (when (fboundp 'evil-set-initial-state)
    (dolist (mode '(ogent-armory-home-mode
                    ogent-armory-agents-mode
                    ogent-armory-agent-mode
                    ogent-armory-jobs-mode
                    ogent-armory-tasks-mode
                    ogent-armory-conversations-mode
                    ogent-armory-conversation-mode
                    ogent-armory-search-mode
                    ogent-armory-apps-mode))
      (evil-set-initial-state mode 'normal))
    (dolist (map (list ogent-armory-home-mode-map
                       ogent-armory-agents-mode-map
                       ogent-armory-agent-mode-map
                       ogent-armory-jobs-mode-map
                       ogent-armory-tasks-mode-map
                       ogent-armory-conversations-mode-map
                       ogent-armory-conversation-mode-map
                       ogent-armory-search-mode-map
                       ogent-armory-apps-mode-map))
      (evil-make-overriding-map map 'all))
    (dolist (hook '(ogent-armory-home-mode-hook
                    ogent-armory-agents-mode-hook
                    ogent-armory-agent-mode-hook
                    ogent-armory-jobs-mode-hook
                    ogent-armory-tasks-mode-hook
                    ogent-armory-conversations-mode-hook
                    ogent-armory-conversation-mode-hook
                    ogent-armory-search-mode-hook
                    ogent-armory-apps-mode-hook))
      (add-hook hook #'ogent-armory-ui--evil-local-keys)
      (add-hook hook #'evil-normalize-keymaps))))

(with-eval-after-load 'evil
  (ogent-armory-ui--setup-evil))

(provide 'ogent-ui-armory)

;;; ogent-ui-armory.el ends here
