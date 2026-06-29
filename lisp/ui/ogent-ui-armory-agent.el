;;; ogent-ui-armory-agent.el --- Single Armory agent profile and management commands -*- lexical-binding: t; -*-

;;; Commentary:
;; Single-agent profile sections plus create/clone/archive commands.

;;; Code:

(require 'ogent-ui-armory-core)

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

(declare-function ogent-armory-search "ogent-ui-armory-search")
(declare-function ogent-armory-tasks "ogent-ui-armory-tasks")

(defvar ogent-armory-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-agent-visit)
    (define-key map (kbd "<return>") #'ogent-armory-agent-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-agent-visit)
    (define-key map "c" #'ogent-armory-agent-compose)
    (define-key map (kbd "C-c c") #'ogent-armory-agent-compose)
    (define-key map "e" #'ogent-armory-agent-edit-property)
    (define-key map (kbd "C-c e") #'ogent-armory-agent-edit-property)
    (define-key map "R" #'ogent-armory-agent-run-at-point)
    (define-key map (kbd "C-c r") #'ogent-armory-agent-run-at-point)
    (define-key map "v" #'ogent-armory-agent-visit)
    (define-key map (kbd "C-c v") #'ogent-armory-agent-visit)
    (define-key map "g" #'ogent-armory-agent-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-agent-refresh)
    (define-key map (kbd "TAB") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-armory-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-armory-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-armory-ui-previous-section)
    (define-key map (kbd "^") #'ogent-armory-ui-up-section)
    (define-key map (kbd "C-c u") #'ogent-armory-ui-up-section)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map (kbd "C-c t") #'ogent-armory-tasks)
    (define-key map "s" #'ogent-armory-search)
    (define-key map (kbd "C-c s") #'ogent-armory-search)
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
  (format "C-c g refresh  RET visit  TAB section  M-n/p sections  C-c c compose  C-c e edit  C-c r run/retry  C-c t tasks  C-c s search  q quit    %s/%s"
          (or (and ogent-armory-agent--root
                   (ogent-armory-ui--root-label ogent-armory-agent--root))
              "?")
          (or ogent-armory-agent--slug "?")))

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
         (value (ogent-armory-ui--read-property-value
                 ogent-armory-agent--root
                 property
                 current
                 agent)))
    (ogent-armory-ui--put-property file property value)
    (ogent-armory-agent-refresh)))

;;; Agent Management Commands

(defun ogent-armory-create-agent (&optional directory)
  "Create a Armory agent under DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (settings (ogent-armory-settings-read root))
         (name (read-string "Name: "))
         (slug (ogent-armory-ui--read-string-default
                "Slug: "
                (ogent-armory--slug name "agent")))
         (role (ogent-armory-ui--read-string-default "Role: " "Agent"))
         (provider (ogent-armory-ui--read-provider
                    "Provider: "
                    (or (plist-get settings :default-provider)
                        ogent-armory-default-agent-provider)))
         (model (or (ogent-armory-ui--read-model
                     provider
                     "Model: "
                     (plist-get settings :default-model)
                     t)
                    ""))
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

(provide 'ogent-ui-armory-agent)
;;; ogent-ui-armory-agent.el ends here
