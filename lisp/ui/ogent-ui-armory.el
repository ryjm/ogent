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
(require 'ogent-armory)
(require 'ogent-armory-runner)

(defgroup ogent-ui-armory nil
  "Richer UI surfaces for Org Armory records."
  :group 'ogent-armory
  :prefix "ogent-armory-")

(defcustom ogent-armory-agents-buffer-name-format "*ogent-armory-agents: %s*"
  "Format string used for Armory agent list buffers."
  :type 'string
  :group 'ogent-ui-armory)

(defcustom ogent-armory-agent-buffer-name-format "*ogent-armory-agent: %s*"
  "Format string used for single Armory agent buffers."
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
  '("OGENT_ROLE"
    "OGENT_PROVIDER"
    "OGENT_MODEL"
    "OGENT_PERMISSION_MODE"
    "OGENT_HEARTBEAT"
    "OGENT_ACTIVE"
    "OGENT_WORKSPACE"
    "OGENT_TAGS")
  "Agent identity properties editable from the profile buffer.")

(defconst ogent-armory-task-lanes
  '("Inbox" "Needs Reply" "Running" "Just Finished" "Archive")
  "Attention lanes displayed by `ogent-armory-tasks'.")

(defvar-local ogent-armory-agents--root nil
  "Armory root for the current agents buffer.")

(defvar-local ogent-armory-agent--root nil
  "Armory root for the current single-agent buffer.")

(defvar-local ogent-armory-agent--slug nil
  "Agent slug for the current single-agent buffer.")

(defvar-local ogent-armory-tasks--root nil
  "Armory root for the current task buffer.")

(defvar-local ogent-armory-search--root nil
  "Armory root for the current search buffer.")

(defvar-local ogent-armory-search--query nil
  "Search query for the current search buffer.")

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
  (or (ogent-armory-list-agents root) nil))

(defun ogent-armory-ui--read-agent (root)
  "Read an agent slug from ROOT."
  (completing-read "Agent: " (ogent-armory-ui--agent-slugs root) nil t))

(defun ogent-armory-ui--agent-jobs (root slug)
  "Return jobs for SLUG under ROOT."
  (or (ogent-armory-list-jobs root slug) nil))

(defun ogent-armory-ui--agent-sessions (root slug)
  "Return sessions for SLUG under ROOT."
  (or (ogent-armory-list-sessions root slug) nil))

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

(defun ogent-armory-ui--put-property (file property value)
  "Set PROPERTY to VALUE in the first Org heading of FILE."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (org-mode)
      (goto-char (point-min))
      (unless (re-search-forward org-heading-regexp nil t)
        (user-error "No Org heading found in %s" file))
      (org-back-to-heading t)
      (org-entry-put nil property value)
      (save-buffer))))

(defun ogent-armory-ui--insert-heading (label)
  "Insert Armory section heading LABEL."
  (insert (propertize label 'face 'ogent-armory-ui-heading) "\n"))

(defun ogent-armory-ui--insert-kv (label value)
  "Insert LABEL and VALUE as one detail line."
  (insert (propertize (format "%-14s" label) 'face 'ogent-armory-ui-dim))
  (insert (format "%s\n" (or value ""))))

(defun ogent-armory-ui--item-at-point ()
  "Return Armory item metadata at point."
  (or (get-text-property (point) 'ogent-armory-item)
      (get-text-property (line-beginning-position) 'ogent-armory-item)
      (tabulated-list-get-id)))

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
              [("Agent" 22 t)
               ("Role" 24 t)
               ("Provider" 12 t)
               ("Active" 8 t)
               ("Jobs" 6 nil :right-align t)
               ("Sessions" 9 nil :right-align t)
               ("Workspace" 24 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Agent" . nil))
  (setq-local revert-buffer-function #'ogent-armory-agents-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-agents--entries ()
  "Return tabulated entries for the current Armory agents buffer."
  (mapcar
   (lambda (slug)
     (let* ((agent (ogent-armory-read-agent ogent-armory-agents--root slug))
            (jobs (ogent-armory-ui--agent-jobs ogent-armory-agents--root slug))
            (sessions (ogent-armory-ui--agent-sessions ogent-armory-agents--root slug))
            (active (if (plist-get agent :active) "yes" "no")))
       (list
        slug
        (vector
         (or (plist-get agent :name) slug)
         (or (plist-get agent :role) "")
         (or (plist-get agent :provider) "")
         (propertize active
                     'face (if (plist-get agent :active)
                               'ogent-armory-ui-good
                             'ogent-armory-ui-dim))
         (number-to-string (length jobs))
         (number-to-string (length sessions))
         (or (plist-get agent :workspace) "")))))
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
  (ogent-armory-ui--visit-path
   (ogent-armory-agent-file
    ogent-armory-agents--root
    (ogent-armory-agents--slug-at-point))))

(defun ogent-armory-agents-run ()
  "Run the Armory agent at point with an instruction."
  (interactive)
  (let ((slug (ogent-armory-agents--slug-at-point)))
    (ogent-armory-run-agent
     ogent-armory-agents--root
     slug
     (read-string "Instruction: "))))

;;; Single Agent Profile

(defvar ogent-armory-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-agent-visit)
    (define-key map (kbd "<return>") #'ogent-armory-agent-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-agent-visit)
    (define-key map "c" #'ogent-armory-agent-compose)
    (define-key map "e" #'ogent-armory-agent-edit-property)
    (define-key map "R" #'ogent-armory-agent-run-at-point)
    (define-key map "g" #'ogent-armory-agent-refresh)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map "s" #'ogent-armory-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-agent-mode'.")

(define-derived-mode ogent-armory-agent-mode special-mode "Armory-Agent"
  "Major mode for a single Armory agent profile."
  :group 'ogent-ui-armory
  (setq-local revert-buffer-function #'ogent-armory-agent-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq header-line-format '(:eval (ogent-armory-agent--header-line))))

(defun ogent-armory-agent--header-line ()
  "Return header text for the current Armory agent buffer."
  (format "g refresh  RET visit  c compose  e edit  R run  t tasks  s search  q quit    %s/%s"
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
  (let* ((root ogent-armory-agent--root)
         (slug ogent-armory-agent--slug)
         (agent (ogent-armory-read-agent root slug))
         (jobs (ogent-armory-ui--agent-jobs root slug))
         (sessions (ogent-armory-ui--agent-sessions root slug)))
    (insert (propertize (or (plist-get agent :name) slug)
                        'face 'ogent-armory-ui-heading)
            "\n")
    (insert (propertize (or (plist-get agent :role) "Agent")
                        'face 'ogent-armory-ui-dim)
            "\n\n")
    (ogent-armory-ui--insert-heading "Composer")
    (insert "  c compose instruction and run this agent\n")
    (insert "  R run job or session at point\n\n")
    (ogent-armory-agent--insert-inbox jobs)
    (ogent-armory-agent--insert-conversations sessions)
    (ogent-armory-agent--insert-recent-work sessions)
    (ogent-armory-agent--insert-schedule jobs)
    (ogent-armory-agent--insert-details agent)
    (ogent-armory-agent--insert-persona agent)))

(defun ogent-armory-agent--insert-inbox (jobs)
  "Insert Inbox section from JOBS."
  (ogent-armory-ui--insert-heading "Inbox")
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
      (insert (propertize "  No enabled jobs\n" 'face 'ogent-armory-ui-dim))))
  (insert "\n"))

(defun ogent-armory-agent--insert-conversations (sessions)
  "Insert Conversations section from SESSIONS."
  (ogent-armory-ui--insert-heading "Conversations")
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
    (insert (propertize "  No conversations yet\n" 'face 'ogent-armory-ui-dim)))
  (insert "\n"))

(defun ogent-armory-agent--insert-recent-work (sessions)
  "Insert Recent Work section from SESSIONS."
  (ogent-armory-ui--insert-heading "Recent Work")
  (let ((recent (seq-take sessions 5)))
    (if recent
        (dolist (session recent)
          (insert (format "  %s  %s\n"
                          (or (plist-get session :status) "DONE")
                          (or (plist-get session :name)
                              (plist-get session :id)))))
      (insert (propertize "  No recent work\n" 'face 'ogent-armory-ui-dim))))
  (insert "\n"))

(defun ogent-armory-agent--insert-schedule (jobs)
  "Insert Schedule section from JOBS."
  (ogent-armory-ui--insert-heading "Schedule")
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
    (insert (propertize "  No scheduled jobs\n" 'face 'ogent-armory-ui-dim)))
  (insert "\n"))

(defun ogent-armory-agent--insert-details (agent)
  "Insert Details section from AGENT."
  (ogent-armory-ui--insert-heading "Details")
  (ogent-armory-ui--insert-kv "Slug" (plist-get agent :slug))
  (ogent-armory-ui--insert-kv "Role" (plist-get agent :role))
  (ogent-armory-ui--insert-kv "Provider" (plist-get agent :provider))
  (ogent-armory-ui--insert-kv "Model" (plist-get agent :model))
  (ogent-armory-ui--insert-kv "Heartbeat" (plist-get agent :heartbeat))
  (ogent-armory-ui--insert-kv "Active" (if (plist-get agent :active) "t" "nil"))
  (ogent-armory-ui--insert-kv "Workspace" (plist-get agent :workspace))
  (ogent-armory-ui--insert-kv "Tags" (string-join (or (plist-get agent :tags) nil) ", "))
  (insert "\n"))

(defun ogent-armory-agent--insert-persona (agent)
  "Insert Persona Instructions section from AGENT."
  (ogent-armory-ui--insert-heading "Persona Instructions")
  (let ((body (plist-get agent :body)))
    (if (and body (not (string-blank-p body)))
        (insert body "\n")
      (insert (propertize "No persona instructions.\n" 'face 'ogent-armory-ui-dim)))))

(defun ogent-armory-agent-visit ()
  "Visit the Armory item at point or this agent's persona file."
  (interactive)
  (let* ((item (ogent-armory-ui--item-at-point))
         (path (or (plist-get item :path)
                   (ogent-armory-agent-file
                    ogent-armory-agent--root
                    ogent-armory-agent--slug))))
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
  (let* ((file (ogent-armory-agent-file
                ogent-armory-agent--root
                ogent-armory-agent--slug))
         (property (completing-read
                    "Property: "
                    ogent-armory-agent-editable-properties
                    nil t))
         (current (with-temp-buffer
                    (insert-file-contents file)
                    (org-mode)
                    (ogent-armory--first-heading-title)
                    (org-entry-get nil property)))
         (value (read-string (format "%s: " property) current)))
    (ogent-armory-ui--put-property file property value)
    (ogent-armory-agent-refresh)))

;;; Tasks

(defvar ogent-armory-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-tasks-visit)
    (define-key map (kbd "<return>") #'ogent-armory-tasks-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-tasks-visit)
    (define-key map "R" #'ogent-armory-tasks-run)
    (define-key map "A" #'ogent-armory-tasks-archive)
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
  (list :type 'job
        :lane (if (plist-get job :enabled) "Inbox" "Archive")
        :agent (plist-get job :agent)
        :job-id (plist-get job :id)
        :name (or (plist-get job :name) (plist-get job :id))
        :state (if (plist-get job :enabled) "enabled" "disabled")
        :when (or (plist-get job :cron) "manual")
        :path (ogent-armory-job-file
               root
               (plist-get job :agent)
               (plist-get job :id))))

(defun ogent-armory-tasks--session-lane (session)
  "Return the attention lane for SESSION."
  (cond
   ((plist-get session :archived) "Archive")
   ((not (zerop (or (plist-get session :exit-status) 0))) "Needs Reply")
   (t "Just Finished")))

(defun ogent-armory-tasks--session-item (session)
  "Return a task item for SESSION."
  (list :type 'session
        :lane (ogent-armory-tasks--session-lane session)
        :agent (plist-get session :agent)
        :job-id (plist-get session :job-id)
        :name (or (plist-get session :name) (plist-get session :id))
        :state (or (plist-get session :status) "DONE")
        :when (or (plist-get session :finished) "")
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
    (dolist (session (ogent-armory-list-sessions root))
      (push (ogent-armory-tasks--session-item session) items))
    (setq items (append (ogent-armory-tasks--running-items root) items))
    (nreverse items)))

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
    (apply
     #'append
     (mapcar
      (lambda (lane)
        (let ((lane-items (seq-filter
                           (lambda (item)
                             (equal (plist-get item :lane) lane))
                           items)))
          (if lane-items
              (mapcar #'ogent-armory-tasks--entry lane-items)
            (list (ogent-armory-tasks--entry
                   (list :type 'empty
                         :lane lane
                         :agent ""
                         :name "(empty)"
                         :state ""
                         :when ""))))))
      ogent-armory-task-lanes))))

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
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-tasks--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-tasks-refresh (&rest _)
  "Refresh the Armory task lane buffer."
  (interactive)
  (tabulated-list-print t))

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
   (ogent-armory-search-records
    ogent-armory-search--root
    ogent-armory-search--query)))

;;;###autoload
(defun ogent-armory-search (&optional directory query)
  "Search Armory Org records under DIRECTORY for QUERY."
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

(provide 'ogent-ui-armory)

;;; ogent-ui-armory.el ends here
