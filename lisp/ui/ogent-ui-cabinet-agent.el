;;; ogent-ui-cabinet-agent.el --- Single Cabinet agent profile and management commands -*- lexical-binding: t; -*-

;;; Commentary:
;; Single-agent profile sections plus create/clone/archive commands.

;;; Code:

(require 'ogent-ui-cabinet-core)

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

(declare-function ogent-cabinet-search "ogent-ui-cabinet-search")
(declare-function ogent-cabinet-tasks "ogent-ui-cabinet-tasks")

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
         (value (ogent-cabinet-ui--read-property-value
                 ogent-cabinet-agent--root
                 property
                 current
                 agent)))
    (ogent-cabinet-ui--put-property file property value)
    (ogent-cabinet-agent-refresh)))

;;; Agent Management Commands

(defun ogent-cabinet-create-agent (&optional directory)
  "Create a Cabinet agent under DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (settings (ogent-cabinet-settings-read root))
         (name (read-string "Name: "))
         (slug (ogent-cabinet-ui--read-string-default
                "Slug: "
                (ogent-cabinet--slug name "agent")))
         (role (ogent-cabinet-ui--read-string-default "Role: " "Agent"))
         (provider (ogent-cabinet-ui--read-provider
                    "Provider: "
                    (or (plist-get settings :default-provider)
                        ogent-cabinet-default-agent-provider)))
         (model (or (ogent-cabinet-ui--read-model
                     provider
                     "Model: "
                     (plist-get settings :default-model)
                     t)
                    ""))
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

(provide 'ogent-ui-cabinet-agent)
;;; ogent-ui-cabinet-agent.el ends here
