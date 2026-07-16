;;; ogent-ui-armory-home.el --- Armory Home cockpit buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Armory Home cockpit buffer with the dispatch transient and navigation.

;;; Code:

(require 'ogent-ui-armory-core)
(require 'ogent-armory-cache)

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

(declare-function ogent-armory-agent "ogent-ui-armory-agent")
(declare-function ogent-armory-agents "ogent-ui-armory-agents")
(declare-function ogent-armory-apps "ogent-ui-armory-apps")
(declare-function ogent-armory-conversation "ogent-ui-armory-conversations")
(declare-function ogent-armory-conversations "ogent-ui-armory-conversations")
(declare-function ogent-armory-jobs "ogent-ui-armory-jobs")
(declare-function ogent-armory-jobs--goto "ogent-ui-armory-jobs")
(declare-function ogent-armory-org-chart "ogent-ui-armory-org-chart")
(declare-function ogent-armory-search "ogent-ui-armory-search")
(declare-function ogent-armory-tasks "ogent-ui-armory-tasks")
(declare-function ogent-armory-ql-available-p "ogent-armory-ql")

(defvar ogent-armory-home-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-home-visit))
    (define-key map "?" #'ogent-armory-home-dispatch)
    (define-key map "g" #'ogent-armory-home-refresh)
    (define-key map "q" #'quit-window)
    (define-key map "J" #'ogent-armory-home-open-jobs)
    (define-key map "R" #'ogent-armory-home-run)
    (define-key map "E" #'ogent-armory-home-edit-item)
    (define-key map "e" #'ogent-armory-home-edit-metadata)
    (define-key map (kbd "TAB") #'ogent-section-toggle)
    (define-key map (kbd "<tab>") #'ogent-section-toggle)
    (define-key map (kbd "<backtab>") #'ogent-section-cycle)
    (define-key map (kbd "M-n") #'ogent-section-next)
    (define-key map (kbd "M-p") #'ogent-section-prev)
    (define-key map (kbd "^") #'ogent-section-up)
    (define-key map "j" ogent-armory-jump-map)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "n" #'ogent-armory-home-next-item)
    (define-key map "p" #'ogent-armory-home-previous-item)
    map)
  "Keymap for `ogent-armory-home-mode'.")

(defcustom ogent-armory-home-show-logo t
  "Non-nil means render the ASCII crest banner atop Armory Home."
  :type 'boolean
  :group 'ogent-ui-armory)

(ogent-armory-ui--define-section-mode ogent-armory-home-mode "Armory-Home"
                                      "Major mode for Armory Home."
  (setq-local revert-buffer-function #'ogent-armory-home-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (ogent-armory-ui--configure-section-buffer)
  (setq header-line-format '(:eval (ogent-armory-home--header-line))))

(defun ogent-armory-home--header-line ()
  "Return header line for Armory Home."
  (ogent-section-header-line
   "Armory Home"
   (and ogent-armory-home--root
        (ogent-armory-ui--root-label ogent-armory-home--root))
   '("?" . "menu") '("j" . "jump") '("g" . "refresh")))

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

(defun ogent-armory-home-refresh (&optional force &rest _)
  "Refresh Armory Home.
With FORCE non-nil, invalidate cached Armory data before fetching."
  (interactive "P")
  (let ((inhibit-read-only t))
    (ogent-armory-ui--invalidate-cache-when-force
     force ogent-armory-home--root)
    (ogent-section-preserve-point
        ((lambda ()
           (when-let ((item (ogent-section-item-at-point 'ogent-armory-item)))
             (cons (plist-get item :type) (plist-get item :path)))))
      (erase-buffer)
      (ogent-armory-home--insert-buffer))))

(defun ogent-armory-home--insert-nav (label key command)
  "Insert navigation LABEL for KEY dispatching to COMMAND."
  (ogent-armory-ui--insert-item-line
   (list :type 'command :command command)
   (format "  [%s] %s" key label)))

(defconst ogent-armory-home--logo
  "╭──────────────────────────────────────╮
│                  █                   │
│                 ███                  │
│                █████                 │
│               ╱  █  ╲                │
│              ╱   █   ╲               │
│             ┌┘   █   └┐              │
│             │  ╔═╩═╗  │              │
│             │  ║ ✦ ║  │              │
│             │  ╚═╦═╝  │              │
│             ┌┴───┴───┴┐              │
│            │ ◣█▏   ▕█◢ │             │
│            │  ▀▀   ▀▀  │             │
│            ├┐ ┌─────┐ ┌┤             │
│            │║ │▆▆▆▆▆│ ║│             │
│            │║ └─────┘ ║│             │
│             └╨───────╨┘              │
│                                      │
│    _____ _____  _____ _   _ _____    │
│   |  _  |  __ \\|  ___| \\ | |_   _|   │
│   | | | | |  \\/| |__ |  \\| | | |     │
│   | | | | | __ |  __|| . ` | | |     │
│   \\ \\_/ / |_\\ \\| |___| |\\  | | |     │
│    \\___/ \\____/\\____/\\_| \\_/ \\_/     │
│                                      │
│         · agentic org-mode ·         │
╰──────────────────────────────────────╯"
  "ASCII crest banner shown atop Armory Home.")

(defun ogent-armory-home--insert-logo ()
  "Insert the ogent crest banner when `ogent-armory-home-show-logo'."
  (when ogent-armory-home-show-logo
    (insert (propertize ogent-armory-home--logo
                        'face 'ogent-armory-ui-logo)
            "\n\n")))

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
    (ogent-armory-home--insert-logo)
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
      (ogent-armory-home--insert-nav "Data" "j d" #'ogent-armory-data)
      (ogent-armory-home--insert-nav "Agents" "j a" #'ogent-armory-agents)
      (ogent-armory-home--insert-nav "Jobs" "j j" #'ogent-armory-jobs)
      (ogent-armory-home--insert-nav "Tasks" "j t" #'ogent-armory-tasks)
      (ogent-armory-home--insert-nav "Conversations" "j c" #'ogent-armory-conversations)
      (ogent-armory-home--insert-nav "Schedule" "j u" #'ogent-armory-schedule)
      (ogent-armory-home--insert-nav "Search" "j s" #'ogent-armory-search)
      (ogent-armory-home--insert-nav "Apps" "j A" #'ogent-armory-apps)
      (ogent-armory-home--insert-nav "Git" "j v" #'ogent-armory-git-status)
      (ogent-armory-home--insert-nav "Palette" "/" #'ogent-armory-command-palette)
      (ogent-armory-home--insert-nav "Settings" "," #'ogent-armory-settings)
      (ogent-armory-home--insert-nav "Help" "? ." #'ogent-armory-help)
      (ogent-armory-home--insert-nav "Graph" "j g" #'ogent-armory-status)
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
  (with-help-window "*ogent-armory-home-help*"
    (princ "Armory Home\n")
    (princ "============\n\n")
    (princ "Home is the cockpit for developing a project with Armory.\n\n")
    (princ "Daily work\n")
    (princ "----------\n")
    (princ "J opens jobs related to the item at point.\n")
    (princ "R runs or retries the selected agent, job, or conversation.\n")
    (princ "E edits the selected agent persona, job prompt, or source Org record.\n")
    (princ "e visits the Armory metadata (index Org file).\n")
    (princ "RET opens the richer surface or durable source for the item at point.\n\n")
    (princ "Jumps\n")
    (princ "-----\n")
    (princ "j h Home, j g Graph, j a Agents, j o Org chart, j t Tasks, j c Conversations,\n")
    (princ "j j Jobs, j s Search, j A Apps, j d Data, j u Schedule, j v Git.\n")
    (princ ", opens Settings. / opens the command palette.\n")
    (princ "n and p move between actionable rows. g refreshes; C-u g forces a rebuild. q quits.\n")
    (princ "TAB toggles a section. M-n/M-p move between sibling sections. ^ moves to the parent section.\n\n")
    (princ "Evil: keys the buffer binds win over Evil motion; unbound keys keep their Evil meaning.\n\n")
    (princ "Menus\n")
    (princ "-----\n")
    (princ "? opens the Transient menu (h inside it reopens this help).\n")))

(defun ogent-armory-home--transient-header ()
  "Return the header text for `ogent-armory-home-dispatch'."
  (let ((root (and (boundp 'ogent-armory-home--root)
                   ogent-armory-home--root)))
    (concat
     (propertize "Armory Home" 'face 'transient-heading)
     (if root
         (concat "  " (propertize (abbreviate-file-name root) 'face 'shadow))
       ""))))

(defun ogent-armory-home--ql-view-available-p ()
  "Return non-nil when the optional org-ql package backs saved QL views."
  (and (require 'ogent-armory-ql nil t)
       (fboundp 'ogent-armory-ql-available-p)
       (ogent-armory-ql-available-p)))

(defun ogent-armory-home--ql-view-description ()
  "Return the dispatch label for the saved Armory QL views row.
Dim the label and append an install hint when org-ql is missing so
users still discover the feature."
  (if (ogent-armory-home--ql-view-available-p)
      "Saved views"
    (concat (propertize "Saved views" 'face 'transient-inapt-suffix)
            " "
            (propertize "(install org-ql)" 'face 'shadow))))

(ogent-armory-ui--define-prefix ogent-armory-home-dispatch ()
  "Dispatch menu for Armory Home."
  [:description ogent-armory-home--transient-header
                ["Daily Work"
                 ("J" "Related jobs" ogent-armory-home-open-jobs)
                 ("R" "Run/retry selected" ogent-armory-home-run)
                 ("E" "Edit selected" ogent-armory-home-edit-item)
                 ("e" "Edit metadata" ogent-armory-home-edit-metadata)]
                ["Navigate"
                 ("RET" "Visit selected" ogent-armory-home-visit)
                 ("TAB" "Toggle section" ogent-section-toggle :transient t)
                 ("M-n" "Next section" ogent-section-next :transient t)
                 ("M-p" "Previous section" ogent-section-prev :transient t)
                 ("^" "Up section" ogent-section-up :transient t)
                 ("n" "Next item" ogent-armory-home-next-item :transient t)
                 ("p" "Previous item" ogent-armory-home-previous-item :transient t)
                 ("g" "Refresh" ogent-armory-home-refresh :transient t)]]
  ["Ops"
   ("Q" "Agenda" ogent-armory-agenda)
   ("C" "Control plane" ogent-armory-agenda-control-plane)
   ("V" ogent-armory-ql-view :description ogent-armory-home--ql-view-description)
   ("N" "Action approvals" ogent-armory-actions)
   ("'" "Onboard" ogent-armory-onboard)
   ("=" "Registry import" ogent-armory-registry-import)
   ("_" "Backup" ogent-armory-backup)
   ("o" "Org chart" ogent-armory-org-chart)]
  ["Help"
   ("h" "Help" ogent-armory-home-help)
   ("." "Docs" ogent-armory-help)
   ("q" "Quit menu" transient-quit-one)])

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

(defun ogent-armory-home--evil-local-keys ()
  "Install local Evil keys for Armory Home buffers."
  (ogent-armory-evil-install-local-bindings ogent-armory-home-mode-map))

(defun ogent-armory-home--setup-evil ()
  "Set up Evil integration for Armory Home buffers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-home-mode
   ogent-armory-home-mode-map
   'ogent-armory-home-mode-hook
   #'ogent-armory-home--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-home--setup-evil))

(provide 'ogent-ui-armory-home)
;;; ogent-ui-armory-home.el ends here
