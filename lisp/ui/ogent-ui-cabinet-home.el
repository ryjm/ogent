;;; ogent-ui-cabinet-home.el --- Cabinet Home cockpit buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Cabinet Home cockpit buffer with the dispatch transient and navigation.

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

(declare-function ogent-cabinet-agent "ogent-ui-cabinet-agent")
(declare-function ogent-cabinet-agents "ogent-ui-cabinet-agents")
(declare-function ogent-cabinet-apps "ogent-ui-cabinet-apps")
(declare-function ogent-cabinet-conversation "ogent-ui-cabinet-conversations")
(declare-function ogent-cabinet-conversations "ogent-ui-cabinet-conversations")
(declare-function ogent-cabinet-jobs "ogent-ui-cabinet-jobs")
(declare-function ogent-cabinet-jobs--goto "ogent-ui-cabinet-jobs")
(declare-function ogent-cabinet-org-chart "ogent-ui-cabinet-org-chart")
(declare-function ogent-cabinet-search "ogent-ui-cabinet-search")
(declare-function ogent-cabinet-tasks "ogent-ui-cabinet-tasks")

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

(provide 'ogent-ui-cabinet-home)
;;; ogent-ui-cabinet-home.el ends here
