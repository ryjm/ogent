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
(require 'ogent-cabinet)
(require 'ogent-cabinet-runner)

(defgroup ogent-ui-cabinet nil
  "Richer UI surfaces for Org Cabinet records."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-")

(defcustom ogent-cabinet-agents-buffer-name-format "*ogent-cabinet-agents: %s*"
  "Format string used for Cabinet agent list buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-agent-buffer-name-format "*ogent-cabinet-agent: %s*"
  "Format string used for single Cabinet agent buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-tasks-buffer-name-format "*ogent-cabinet-tasks: %s*"
  "Format string used for Cabinet task lane buffers."
  :type 'string
  :group 'ogent-ui-cabinet)

(defcustom ogent-cabinet-search-buffer-name-format "*ogent-cabinet-search: %s*"
  "Format string used for Cabinet search buffers."
  :type 'string
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
  '("OGENT_ROLE"
    "OGENT_PROVIDER"
    "OGENT_MODEL"
    "OGENT_PERMISSION_MODE"
    "OGENT_HEARTBEAT"
    "OGENT_ACTIVE"
    "OGENT_WORKSPACE"
    "OGENT_TAGS")
  "Agent identity properties editable from the profile buffer.")

(defconst ogent-cabinet-task-lanes
  '("Inbox" "Needs Reply" "Running" "Just Finished" "Archive")
  "Attention lanes displayed by `ogent-cabinet-tasks'.")

(defvar-local ogent-cabinet-agents--root nil
  "Cabinet root for the current agents buffer.")

(defvar-local ogent-cabinet-agent--root nil
  "Cabinet root for the current single-agent buffer.")

(defvar-local ogent-cabinet-agent--slug nil
  "Agent slug for the current single-agent buffer.")

(defvar-local ogent-cabinet-tasks--root nil
  "Cabinet root for the current task buffer.")

(defvar-local ogent-cabinet-search--root nil
  "Cabinet root for the current search buffer.")

(defvar-local ogent-cabinet-search--query nil
  "Search query for the current search buffer.")

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
  (or (ogent-cabinet-list-agents root) nil))

(defun ogent-cabinet-ui--read-agent (root)
  "Read an agent slug from ROOT."
  (completing-read "Agent: " (ogent-cabinet-ui--agent-slugs root) nil t))

(defun ogent-cabinet-ui--agent-jobs (root slug)
  "Return jobs for SLUG under ROOT."
  (or (ogent-cabinet-list-jobs root slug) nil))

(defun ogent-cabinet-ui--agent-sessions (root slug)
  "Return sessions for SLUG under ROOT."
  (or (ogent-cabinet-list-sessions root slug) nil))

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

(defun ogent-cabinet-ui--put-property (file property value)
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

(defun ogent-cabinet-ui--insert-heading (label)
  "Insert Cabinet section heading LABEL."
  (insert (propertize label 'face 'ogent-cabinet-ui-heading) "\n"))

(defun ogent-cabinet-ui--insert-kv (label value)
  "Insert LABEL and VALUE as one detail line."
  (insert (propertize (format "%-14s" label) 'face 'ogent-cabinet-ui-dim))
  (insert (format "%s\n" (or value ""))))

(defun ogent-cabinet-ui--item-at-point ()
  "Return Cabinet item metadata at point."
  (or (get-text-property (point) 'ogent-cabinet-item)
      (get-text-property (line-beginning-position) 'ogent-cabinet-item)
      (tabulated-list-get-id)))

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

;;; Agent List

(defvar ogent-cabinet-agents-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-agents-open-agent)
    (define-key map (kbd "<return>") #'ogent-cabinet-agents-open-agent)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-agents-open-agent)
    (define-key map "v" #'ogent-cabinet-agents-visit)
    (define-key map "R" #'ogent-cabinet-agents-run)
    (define-key map "g" #'ogent-cabinet-agents-refresh)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-agents-mode'.")

(define-derived-mode ogent-cabinet-agents-mode tabulated-list-mode "Cabinet-Agents"
  "Major mode for Cabinet agent lists."
  :group 'ogent-ui-cabinet
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
  (setq-local revert-buffer-function #'ogent-cabinet-agents-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-agents--entries ()
  "Return tabulated entries for the current Cabinet agents buffer."
  (mapcar
   (lambda (slug)
     (let* ((agent (ogent-cabinet-read-agent ogent-cabinet-agents--root slug))
            (jobs (ogent-cabinet-ui--agent-jobs ogent-cabinet-agents--root slug))
            (sessions (ogent-cabinet-ui--agent-sessions ogent-cabinet-agents--root slug))
            (active (if (plist-get agent :active) "yes" "no")))
       (list
        slug
        (vector
         (or (plist-get agent :name) slug)
         (or (plist-get agent :role) "")
         (or (plist-get agent :provider) "")
         (propertize active
                     'face (if (plist-get agent :active)
                               'ogent-cabinet-ui-good
                             'ogent-cabinet-ui-dim))
         (number-to-string (length jobs))
         (number-to-string (length sessions))
         (or (plist-get agent :workspace) "")))))
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
  (ogent-cabinet-ui--visit-path
   (ogent-cabinet-agent-file
    ogent-cabinet-agents--root
    (ogent-cabinet-agents--slug-at-point))))

(defun ogent-cabinet-agents-run ()
  "Run the Cabinet agent at point with an instruction."
  (interactive)
  (let ((slug (ogent-cabinet-agents--slug-at-point)))
    (ogent-cabinet-run-agent
     ogent-cabinet-agents--root
     slug
     (read-string "Instruction: "))))

;;; Single Agent Profile

(defvar ogent-cabinet-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-agent-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-agent-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-agent-visit)
    (define-key map "c" #'ogent-cabinet-agent-compose)
    (define-key map "e" #'ogent-cabinet-agent-edit-property)
    (define-key map "R" #'ogent-cabinet-agent-run-at-point)
    (define-key map "g" #'ogent-cabinet-agent-refresh)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-agent-mode'.")

(define-derived-mode ogent-cabinet-agent-mode special-mode "Cabinet-Agent"
  "Major mode for a single Cabinet agent profile."
  :group 'ogent-ui-cabinet
  (setq-local revert-buffer-function #'ogent-cabinet-agent-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq header-line-format '(:eval (ogent-cabinet-agent--header-line))))

(defun ogent-cabinet-agent--header-line ()
  "Return header text for the current Cabinet agent buffer."
  (format "g refresh  RET visit  c compose  e edit  R run  t tasks  s search  q quit    %s/%s"
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
  (let* ((root ogent-cabinet-agent--root)
         (slug ogent-cabinet-agent--slug)
         (agent (ogent-cabinet-read-agent root slug))
         (jobs (ogent-cabinet-ui--agent-jobs root slug))
         (sessions (ogent-cabinet-ui--agent-sessions root slug)))
    (insert (propertize (or (plist-get agent :name) slug)
                        'face 'ogent-cabinet-ui-heading)
            "\n")
    (insert (propertize (or (plist-get agent :role) "Agent")
                        'face 'ogent-cabinet-ui-dim)
            "\n\n")
    (ogent-cabinet-ui--insert-heading "Composer")
    (insert "  c compose instruction and run this agent\n")
    (insert "  R run job or session at point\n\n")
    (ogent-cabinet-agent--insert-inbox jobs)
    (ogent-cabinet-agent--insert-conversations sessions)
    (ogent-cabinet-agent--insert-recent-work sessions)
    (ogent-cabinet-agent--insert-schedule jobs)
    (ogent-cabinet-agent--insert-details agent)
    (ogent-cabinet-agent--insert-persona agent)))

(defun ogent-cabinet-agent--insert-inbox (jobs)
  "Insert Inbox section from JOBS."
  (ogent-cabinet-ui--insert-heading "Inbox")
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
      (insert (propertize "  No enabled jobs\n" 'face 'ogent-cabinet-ui-dim))))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-conversations (sessions)
  "Insert Conversations section from SESSIONS."
  (ogent-cabinet-ui--insert-heading "Conversations")
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
    (insert (propertize "  No conversations yet\n" 'face 'ogent-cabinet-ui-dim)))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-recent-work (sessions)
  "Insert Recent Work section from SESSIONS."
  (ogent-cabinet-ui--insert-heading "Recent Work")
  (let ((recent (seq-take sessions 5)))
    (if recent
        (dolist (session recent)
          (insert (format "  %s  %s\n"
                          (or (plist-get session :status) "DONE")
                          (or (plist-get session :name)
                              (plist-get session :id)))))
      (insert (propertize "  No recent work\n" 'face 'ogent-cabinet-ui-dim))))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-schedule (jobs)
  "Insert Schedule section from JOBS."
  (ogent-cabinet-ui--insert-heading "Schedule")
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
    (insert (propertize "  No scheduled jobs\n" 'face 'ogent-cabinet-ui-dim)))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-details (agent)
  "Insert Details section from AGENT."
  (ogent-cabinet-ui--insert-heading "Details")
  (ogent-cabinet-ui--insert-kv "Slug" (plist-get agent :slug))
  (ogent-cabinet-ui--insert-kv "Role" (plist-get agent :role))
  (ogent-cabinet-ui--insert-kv "Provider" (plist-get agent :provider))
  (ogent-cabinet-ui--insert-kv "Model" (plist-get agent :model))
  (ogent-cabinet-ui--insert-kv "Heartbeat" (plist-get agent :heartbeat))
  (ogent-cabinet-ui--insert-kv "Active" (if (plist-get agent :active) "t" "nil"))
  (ogent-cabinet-ui--insert-kv "Workspace" (plist-get agent :workspace))
  (ogent-cabinet-ui--insert-kv "Tags" (string-join (or (plist-get agent :tags) nil) ", "))
  (insert "\n"))

(defun ogent-cabinet-agent--insert-persona (agent)
  "Insert Persona Instructions section from AGENT."
  (ogent-cabinet-ui--insert-heading "Persona Instructions")
  (let ((body (plist-get agent :body)))
    (if (and body (not (string-blank-p body)))
        (insert body "\n")
      (insert (propertize "No persona instructions.\n" 'face 'ogent-cabinet-ui-dim)))))

(defun ogent-cabinet-agent-visit ()
  "Visit the Cabinet item at point or this agent's persona file."
  (interactive)
  (let* ((item (ogent-cabinet-ui--item-at-point))
         (path (or (plist-get item :path)
                   (ogent-cabinet-agent-file
                    ogent-cabinet-agent--root
                    ogent-cabinet-agent--slug))))
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
  (let* ((file (ogent-cabinet-agent-file
                ogent-cabinet-agent--root
                ogent-cabinet-agent--slug))
         (property (completing-read
                    "Property: "
                    ogent-cabinet-agent-editable-properties
                    nil t))
         (current (with-temp-buffer
                    (insert-file-contents file)
                    (org-mode)
                    (ogent-cabinet--first-heading-title)
                    (org-entry-get nil property)))
         (value (read-string (format "%s: " property) current)))
    (ogent-cabinet-ui--put-property file property value)
    (ogent-cabinet-agent-refresh)))

;;; Tasks

(defvar ogent-cabinet-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-tasks-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-tasks-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-tasks-visit)
    (define-key map "R" #'ogent-cabinet-tasks-run)
    (define-key map "A" #'ogent-cabinet-tasks-archive)
    (define-key map "g" #'ogent-cabinet-tasks-refresh)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-tasks-mode'.")

(define-derived-mode ogent-cabinet-tasks-mode tabulated-list-mode "Cabinet-Tasks"
  "Major mode for Cabinet attention lanes."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Type" 10 t)
               ("Agent" 14 t)
               ("Item" 32 t)
               ("State" 18 t)
               ("When" 24 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-tasks-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-tasks--job-item (root job)
  "Return a task item for JOB under ROOT."
  (list :type 'job
        :lane (if (plist-get job :enabled) "Inbox" "Archive")
        :agent (plist-get job :agent)
        :job-id (plist-get job :id)
        :name (or (plist-get job :name) (plist-get job :id))
        :state (if (plist-get job :enabled) "enabled" "disabled")
        :when (or (plist-get job :cron) "manual")
        :path (ogent-cabinet-job-file
               root
               (plist-get job :agent)
               (plist-get job :id))))

(defun ogent-cabinet-tasks--session-lane (session)
  "Return the attention lane for SESSION."
  (cond
   ((plist-get session :archived) "Archive")
   ((not (zerop (or (plist-get session :exit-status) 0))) "Needs Reply")
   (t "Just Finished")))

(defun ogent-cabinet-tasks--session-item (session)
  "Return a task item for SESSION."
  (list :type 'session
        :lane (ogent-cabinet-tasks--session-lane session)
        :agent (plist-get session :agent)
        :job-id (plist-get session :job-id)
        :name (or (plist-get session :name) (plist-get session :id))
        :state (or (plist-get session :status) "DONE")
        :when (or (plist-get session :finished) "")
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
    (dolist (session (ogent-cabinet-list-sessions root))
      (push (ogent-cabinet-tasks--session-item session) items))
    (setq items (append (ogent-cabinet-tasks--running-items root) items))
    (nreverse items)))

(defun ogent-cabinet-tasks--entry (item)
  "Return a tabulated list entry for ITEM."
  (list
   item
   (vector
    (symbol-name (plist-get item :type))
    (or (plist-get item :agent) "")
    (or (plist-get item :name) "")
    (or (plist-get item :state) "")
    (or (plist-get item :when) ""))))

(defun ogent-cabinet-tasks--groups ()
  "Return tabulated list groups for the current Cabinet task buffer."
  (let ((items (ogent-cabinet-tasks--items)))
    (mapcar
     (lambda (lane)
       (let ((lane-items (seq-filter
                          (lambda (item)
                            (equal (plist-get item :lane) lane))
                          items)))
        (cons lane
              (if lane-items
                  (mapcar #'ogent-cabinet-tasks--entry lane-items)
                (list (ogent-cabinet-tasks--entry
                       (list :type 'empty
                             :lane lane
                             :agent ""
                             :name "(empty)"
                             :state ""
                             :when "")))))))
     ogent-cabinet-task-lanes)))

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
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-groups #'ogent-cabinet-tasks--groups)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-tasks-refresh (&rest _)
  "Refresh the Cabinet task lane buffer."
  (interactive)
  (tabulated-list-print t))

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

;;; Search

(defvar ogent-cabinet-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-search-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-search-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-search-visit)
    (define-key map "g" #'ogent-cabinet-search-refresh)
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
   (ogent-cabinet-search-records
    ogent-cabinet-search--root
    ogent-cabinet-search--query)))

;;;###autoload
(defun ogent-cabinet-search (&optional directory query)
  "Search Cabinet Org records under DIRECTORY for QUERY."
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

(provide 'ogent-ui-cabinet)

;;; ogent-ui-cabinet.el ends here
