;;; ogent-armory-status.el --- Operational view for Org armories -*- lexical-binding: t; -*-

;;; Commentary:
;; Renders the Org armory graph as an operational buffer with the same
;; refresh, visit, and bridge conventions used by Ogent Issues.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'time-date)
(require 'transient)
(require 'ogent-armory)
(require 'ogent-armory-adapter)
(require 'ogent-armory-evil)
(require 'ogent-armory-runner)
(require 'ogent-armory-settings)
(require 'ogent-ops-style)
(require 'ogent-ui-theme)
(require 'ogent-ui-section)
(require 'ogent-ui-armory-core)

(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-armory-agents "ogent-ui-armory" nil t)
(autoload 'ogent-armory-tasks "ogent-ui-armory" nil t)
(autoload 'ogent-armory-conversations "ogent-ui-armory" nil t)
(autoload 'ogent-armory-search "ogent-ui-armory" nil t)
(autoload 'ogent-armory-apps "ogent-ui-armory" nil t)
(autoload 'ogent-armory-home "ogent-ui-armory" nil t)
(autoload 'ogent-armory-agent "ogent-ui-armory" nil t)
(autoload 'ogent-armory-jobs "ogent-ui-armory" nil t)
(autoload 'ogent-armory-create-job "ogent-ui-armory" nil t)
(autoload 'ogent-armory-conversation "ogent-ui-armory" nil t)

(declare-function ogent-issues-bd-initialized-p "ogent-issues-bd" (&optional directory))
(declare-function ogent-armory-jobs--goto "ogent-ui-armory-jobs" (agent job-id))
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

(defgroup ogent-armory-status nil
  "Operational status view for Org armories."
  :group 'ogent-armory
  :prefix "ogent-armory-status-")

(defcustom ogent-armory-status-buffer-name-format "*ogent-armory: %s*"
  "Format string used for Armory status buffer names."
  :type 'string
  :group 'ogent-armory-status)

(defcustom ogent-armory-status-show-node-ids nil
  "Non-nil means show graph node ids in Armory status rows."
  :type 'boolean
  :group 'ogent-armory-status)

(defcustom ogent-armory-status-max-related-items 6
  "Maximum recent work and artifact rows shown before summarizing the rest."
  :type 'integer
  :group 'ogent-armory-status)

(defface ogent-armory-status-heading
  '((t :inherit ogent-theme-section-heading :extend t))
  "Face for Armory status section headings."
  :group 'ogent-armory-status)

(defface ogent-armory-status-id
  '((t :inherit ogent-theme-muted))
  "Face for Armory graph identifiers."
  :group 'ogent-armory-status)

(defface ogent-armory-status-label
  '((t :inherit ogent-theme-info :weight bold))
  "Face for Armory graph labels."
  :group 'ogent-armory-status)

(defface ogent-armory-status-dimmed
  '((t :inherit ogent-theme-muted))
  "Face for secondary Armory status text."
  :group 'ogent-armory-status)

(defface ogent-armory-status-connected
  '((t :inherit ogent-theme-success))
  "Face for connected operational bridges."
  :group 'ogent-armory-status)

(defface ogent-armory-status-disconnected
  '((t :inherit ogent-theme-error))
  "Face for inactive operational bridges."
  :group 'ogent-armory-status)

(defvar-local ogent-armory-status--root nil
  "Armory root shown by the current status buffer.")

(defvar-local ogent-armory-status--graph nil
  "Armory graph shown by the current status buffer.")

(defvar ogent-armory-status-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-armory-status-refresh)
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-status-visit))
    (define-key map "n" #'ogent-armory-status-next-item)
    (define-key map "p" #'ogent-armory-status-previous-item)
    (define-key map "i" #'ogent-armory-status-open-issues)
    (define-key map "R" #'ogent-armory-status-run)
    (define-key map "?" #'ogent-armory-status-dispatch)
    (define-key map "e" #'ogent-armory-status-edit)
    (define-key map "E" #'ogent-armory-status-edit-body)
    (define-key map "P" #'ogent-armory-status-open-agent-profile)
    (define-key map "J" #'ogent-armory-status-open-agent-jobs)
    (define-key map "C" #'ogent-armory-status-create-job)
    (define-key map (kbd "TAB") #'ogent-section-toggle)
    (define-key map (kbd "<tab>") #'ogent-section-toggle)
    (define-key map (kbd "<backtab>") #'ogent-section-cycle)
    (define-key map (kbd "M-n") #'ogent-section-next)
    (define-key map (kbd "M-p") #'ogent-section-prev)
    (define-key map (kbd "^") #'ogent-section-up)
    (define-key map "j" ogent-armory-jump-map)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-status-mode'.")

(ogent-section-define-mode ogent-armory-status-mode "Armory"
                           "Major mode for Armory graph status.

\\<ogent-armory-status-mode-map>
\\[ogent-armory-status-refresh] refreshes the graph.
\\[ogent-armory-status-visit] visits the Org record at point.
\\[ogent-armory-status-dispatch] opens the status action menu.
\\[ogent-armory-status-help] shows status help.
\\[ogent-section-toggle] toggles section visibility.
\\[ogent-armory-status-open-issues] opens Ogent Issues."
  :group 'ogent-armory-status
  (setq-local revert-buffer-function #'ogent-armory-status-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (font-lock-mode -1)
  (ogent-ops-protect-face-properties)
  (when (and (ogent-section-usable-p)
             (boundp 'magit-section-mode-map))
    (set-keymap-parent ogent-armory-status-mode-map magit-section-mode-map))
  (ogent-section-configure-buffer)
  (setq header-line-format '(:eval (ogent-armory-status--header-line))))

(defun ogent-armory-status--buffer-name (root)
  "Return the Armory status buffer name for ROOT."
  (format ogent-armory-status-buffer-name-format
          (file-name-nondirectory (directory-file-name root))))

;;;###autoload
(defun ogent-armory-status (&optional directory)
  "Open a Armory status buffer for DIRECTORY.
When DIRECTORY is nil, use the nearest armory root or prompt for one."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((candidate (ogent-armory--directory
                     (or directory default-directory)))
         (root (directory-file-name
                (file-truename
                 (or (ogent-armory-find-root candidate)
                     candidate))))
         (buffer (get-buffer-create (ogent-armory-status--buffer-name root))))
    (with-current-buffer buffer
      (ogent-armory-status-mode)
      (setq ogent-armory-status--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-status-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-status-refresh (&optional force &rest _)
  "Refresh the current Armory status buffer.
With FORCE (interactively, a prefix argument), rebuild the Armory
graph even when the cached copy is still fresh."
  (interactive "P")
  (unless ogent-armory-status--root
    (setq ogent-armory-status--root
          (or (ogent-armory-find-root)
              (read-directory-name "Armory root: "))))
  (let ((inhibit-read-only t))
    (ogent-section-preserve-point
        ((lambda ()
           (when-let ((node (ogent-section-item-at-point 'ogent-armory-node)))
             (plist-get node :id))))
      (erase-buffer)
      (setq ogent-armory-status--graph
            (ogent-armory-build-graph ogent-armory-status--root force))
      (ogent-armory-status--insert-buffer))))

(defun ogent-armory-status--header-line ()
  "Return header line text for the current Armory status buffer."
  (let* ((node (ignore-errors (ogent-armory-status--node-at-point)))
         (context (concat
                   (when ogent-armory-status--root
                     (abbreviate-file-name ogent-armory-status--root))
                   (when node
                     (format "  %s %s"
                             (symbol-name (plist-get node :kind))
                             (or (plist-get node :label) ""))))))
    (ogent-section-header-line "Armory Graph" context
                               '("?" . "menu") '("j" . "jump")
                               '("g" . "refresh"))))

(defun ogent-armory-status--nodes-by-kind (kind)
  "Return graph nodes whose `:kind' is KIND."
  (seq-filter
   (lambda (node)
     (eq (plist-get node :kind) kind))
   (plist-get ogent-armory-status--graph :nodes)))

(defun ogent-armory-status--edges-from (node-id kind)
  "Return graph edges from NODE-ID whose `:kind' is KIND."
  (seq-filter
   (lambda (edge)
     (and (equal (plist-get edge :from) node-id)
          (eq (plist-get edge :kind) kind)))
   (plist-get ogent-armory-status--graph :edges)))

(defun ogent-armory-status--node-by-id (node-id)
  "Return graph node NODE-ID."
  (seq-find
   (lambda (node)
     (equal (plist-get node :id) node-id))
   (plist-get ogent-armory-status--graph :nodes)))

(defun ogent-armory-status--plural (count singular &optional plural)
  "Return COUNT followed by SINGULAR or PLURAL label."
  (format "%d %s" count (if (= count 1) singular (or plural (concat singular "s")))))

(defun ogent-armory-status--node-count (kind)
  "Return the number of graph nodes whose kind is KIND."
  (length (ogent-armory-status--nodes-by-kind kind)))

(defun ogent-armory-status--agent-state (data)
  "Return operational state for agent DATA."
  (cond
   ((ogent-armory-runner-running-p (plist-get data :slug)) 'working)
   ((plist-get data :active) 'active)
   (t 'idle)))

(defun ogent-armory-status--state-face (state)
  "Return face for operational STATE."
  (if (memq state '(active working ready connected closed merged processing))
      'ogent-armory-status-connected
    'ogent-armory-status-disconnected))

(defun ogent-armory-status--runtime-label (data)
  "Return provider/model label for DATA."
  (ogent-armory--blank-to-nil
   (string-join
    (delq nil
          (list (ogent-armory--blank-to-nil (plist-get data :provider))
                (ogent-armory--blank-to-nil (plist-get data :model))))
    "/")))

(defun ogent-armory-status--clock-label (minute hour)
  "Return HH:MM for cron MINUTE and HOUR fields when they are simple."
  (when (and (string-match-p "\\`[0-9]+\\'" minute)
             (string-match-p "\\`[0-9]+\\'" hour))
    (let ((minute-number (string-to-number minute))
          (hour-number (string-to-number hour)))
      (when (and (<= 0 minute-number 59)
                 (<= 0 hour-number 23))
        (format "%02d:%02d" hour-number minute-number)))))

(defun ogent-armory-status--weekday-label (day)
  "Return short weekday label for cron DAY."
  (cdr (assoc day
              '(("0" . "Sun")
                ("1" . "Mon")
                ("2" . "Tue")
                ("3" . "Wed")
                ("4" . "Thu")
                ("5" . "Fri")
                ("6" . "Sat")
                ("7" . "Sun")))))

(defun ogent-armory-status--cron-label (cron)
  "Return a readable label for common CRON schedules."
  (let ((fields (split-string cron "[ \t]+" t)))
    (if (/= (length fields) 5)
        (concat "cron " cron)
      (let* ((minute (nth 0 fields))
             (hour (nth 1 fields))
             (day-of-month (nth 2 fields))
             (month (nth 3 fields))
             (day-of-week (nth 4 fields))
             (time (ogent-armory-status--clock-label minute hour))
             (weekday (ogent-armory-status--weekday-label day-of-week)))
        (cond
         ((and (string= minute "0")
               (string= hour "*")
               (string= day-of-month "*")
               (string= month "*")
               (string= day-of-week "*"))
          "hourly")
         ((and (string-match "\\`\\*/\\([0-9]+\\)\\'" minute)
               (string= hour "*")
               (string= day-of-month "*")
               (string= month "*")
               (string= day-of-week "*"))
          (format "every %s min" (match-string 1 minute)))
         ((and time
               (string= day-of-month "*")
               (string= month "*")
               (string= day-of-week "*"))
          (format "daily %s" time))
         ((and time
               weekday
               (string= day-of-month "*")
               (string= month "*"))
          (format "weekly %s %s" weekday time))
         ((and time
               (string-match-p "\\`[0-9]+\\'" day-of-month)
               (string= month "*")
               (string= day-of-week "*"))
          (format "monthly day %s %s" day-of-month time))
         (t
          (concat "cron " cron)))))))

(defun ogent-armory-status--schedule-label (data)
  "Return a quiet schedule label for job DATA."
  (cond
   ((ogent-armory--blank-to-nil (plist-get data :cron))
    (ogent-armory-status--cron-label (plist-get data :cron)))
   ((ogent-armory--blank-to-nil (plist-get data :run-after))
    (concat "at " (plist-get data :run-after)))
   ((ogent-armory--blank-to-nil (plist-get data :heartbeat))
    (concat "heartbeat " (plist-get data :heartbeat)))
   (t "manual")))

(defun ogent-armory-status--session-time (node)
  "Return sortable completion time for session NODE."
  (or (plist-get (plist-get node :data) :finished) ""))

(defun ogent-armory-status--session-state (status)
  "Return display state for session STATUS."
  (cond
   ((string= status "DONE") 'closed)
   ((string= status "FAILED") 'failed)
   ((string= status "RUNNING") 'processing)
   (t 'waiting)))

(defun ogent-armory-status--short-time (timestamp)
  "Return a compact display label for TIMESTAMP."
  (when-let ((value (ogent-armory--blank-to-nil timestamp)))
    (or (ignore-errors
          (let* ((time (date-to-time value))
                 (time-year (format-time-string "%Y" time))
                 (current-year (format-time-string "%Y" (current-time))))
            (format-time-string
             (if (string= time-year current-year)
                 "%b %d %H:%M"
               "%Y-%m-%d %H:%M")
             time)))
        value)))

(defun ogent-armory-status--take-with-rest (items limit)
  "Return plist containing visible ITEMS and hidden count after LIMIT."
  (let* ((limit (max 0 (or limit 0)))
         (visible (seq-take items limit))
         (rest (- (length items) (length visible))))
    (list :visible visible :rest rest)))

(defun ogent-armory-status--insert-buffer ()
  "Insert the Armory status buffer contents."
  (ogent-section-with-root (ogent-armory-status-root)
    (ogent-armory-status--insert-buffer-content)))

(defun ogent-armory-status--insert-buffer-content ()
  "Insert the Armory status content sections."
  (ogent-armory-status--insert-summary)
  (insert "\n")
  (ogent-armory-status--insert-agents)
  (insert "\n")
  (ogent-armory-status--insert-recent-work)
  (insert "\n")
  (ogent-armory-status--insert-artifacts)
  (insert "\n")
  (ogent-armory-status--insert-bridges))

(defun ogent-armory-status--heading-text (icon ascii label &optional count)
  "Return heading text with ICON, ASCII fallback, LABEL, and optional COUNT."
  (propertize
   (ogent-ops-section-heading
    (ogent-ops-section-prefix icon ascii)
    label
    count
    'ogent-armory-status-dimmed)
   'face 'ogent-armory-status-heading))

(defun ogent-armory-status--insert-heading (icon ascii label &optional count)
  "Insert a heading with ICON, ASCII fallback, LABEL, and optional COUNT."
  (insert (ogent-armory-status--heading-text icon ascii label count) "\n"))

(defun ogent-armory-status--insert-summary ()
  "Insert graph summary section."
  (let* ((armory (car (ogent-armory-status--nodes-by-kind 'armory)))
         (agents (ogent-armory-status--node-count 'agent))
         (jobs (ogent-armory-status--node-count 'job))
         (sessions (ogent-armory-status--node-count 'session))
         (apps (ogent-armory-status--node-count 'app))
         (issues (ogent-armory-status--node-count 'issue)))
    (ogent-section-with (ogent-armory-status-summary)
        (ogent-armory-status--heading-text "◇" "O" "Overview")
      (when armory
        (ogent-armory-status--insert-node-line
         armory
         (format "%s  %s  %s  %s  %s  %s"
                 (propertize (or (plist-get armory :label) "Armory")
                             'face 'ogent-armory-status-label)
                 (ogent-armory-status--plural agents "agent")
                 (ogent-armory-status--plural jobs "job")
                 (ogent-armory-status--plural sessions "run")
                 (ogent-armory-status--plural apps "app")
                 (ogent-armory-status--plural issues "issue")))))))

(defun ogent-armory-status--insert-agents ()
  "Insert agents and their scheduled jobs."
  (let ((agents (ogent-armory-status--nodes-by-kind 'agent)))
    (ogent-section-with (ogent-armory-status-agents)
        (ogent-armory-status--heading-text "◆" "A" "Agents" (length agents))
      (if agents
          (dolist (agent agents)
            (let* ((data (plist-get agent :data))
                   (id (plist-get agent :id))
                   (jobs (mapcar
                          (lambda (edge)
                            (ogent-armory-status--node-by-id
                             (plist-get edge :to)))
                          (ogent-armory-status--edges-from id 'owns)))
                   (provider (or (plist-get data :provider) "codex"))
                   (runtime (or (ogent-armory-status--runtime-label data)
                                provider))
                   (status (ogent-armory-status--agent-state data)))
              (ogent-armory-status--insert-node-line
               agent
               (format "%s %-28s %-9s %-18s %s"
                       (propertize (ogent-ops-activity-symbol status)
                                   'face (ogent-armory-status--state-face
                                          status))
                       (propertize (plist-get agent :label)
                                   'face 'ogent-armory-status-label)
                       (propertize
                        (symbol-name status)
                        'face 'ogent-armory-status-dimmed)
                       (propertize runtime
                                   'face 'ogent-armory-status-dimmed)
                       (propertize
                        (ogent-armory-status--plural (length jobs) "job")
                        'face 'ogent-armory-status-dimmed)))
              (dolist (job jobs)
                (when job
                  (ogent-armory-status--insert-node-line
                   job
                   (ogent-armory-status--format-job-line job)
                   "    ")))))
        (insert (propertize "  No agents yet\n"
                            'face 'ogent-armory-status-dimmed))))))

(defun ogent-armory-status--insert-recent-work ()
  "Insert recent session nodes."
  (let* ((sessions (seq-sort-by
                    #'ogent-armory-status--session-time
                    #'string>
                    (ogent-armory-status--nodes-by-kind 'session)))
         (split (ogent-armory-status--take-with-rest
                 sessions
                 ogent-armory-status-max-related-items))
         (visible (plist-get split :visible))
         (rest (plist-get split :rest)))
    (ogent-section-with (ogent-armory-status-recent-work)
        (ogent-armory-status--heading-text "◇" "W" "Recent Work" (length sessions))
      (if visible
          (progn
            (dolist (node visible)
              (ogent-armory-status--insert-node-line
               node
               (ogent-armory-status--format-session-line node)))
            (when (> rest 0)
              (insert (propertize
                       (format "  %s more. Press c for the conversation list.\n"
                               rest)
                       'face 'ogent-armory-status-dimmed))))
        (insert (propertize "  No completed sessions yet\n"
                            'face 'ogent-armory-status-dimmed))))))

(defun ogent-armory-status--insert-artifacts ()
  "Insert app and issue nodes."
  (let* ((nodes (seq-filter
                 (lambda (node)
                   (memq (plist-get node :kind) '(app issue)))
                 (plist-get ogent-armory-status--graph :nodes)))
         (split (ogent-armory-status--take-with-rest
                 nodes
                 ogent-armory-status-max-related-items))
         (visible (plist-get split :visible))
         (rest (plist-get split :rest)))
    (ogent-section-with (ogent-armory-status-artifacts)
        (ogent-armory-status--heading-text "◇" "F" "Artifacts" (length nodes))
      (if visible
          (progn
            (dolist (node visible)
              (ogent-armory-status--insert-node-line
               node
               (ogent-armory-status--format-artifact-line node)))
            (when (> rest 0)
              (insert (propertize
                       (format "  %s more. Press A for apps or i for issues.\n"
                               rest)
                       'face 'ogent-armory-status-dimmed))))
        (insert (propertize "  No apps or linked issues yet\n"
                            'face 'ogent-armory-status-dimmed))))))

(defun ogent-armory-status--format-job-line (job)
  "Return display text for JOB."
  (let* ((data (plist-get job :data))
         (enabled (plist-get data :enabled))
         (state (if enabled 'ready 'waiting))
         (label (if enabled "enabled" "paused")))
    (format "%s %-28s %-9s %s"
            (propertize (ogent-ops-status-symbol state)
                        'face (ogent-armory-status--state-face state))
            (propertize (plist-get job :label)
                        'face 'ogent-armory-status-label)
            (propertize label
                        'face 'ogent-armory-status-dimmed)
            (propertize (ogent-armory-status--schedule-label data)
                        'face 'ogent-armory-status-dimmed))))

(defun ogent-armory-status--format-session-line (node)
  "Return display text for session NODE."
  (let* ((data (plist-get node :data))
         (status (format "%s" (or (plist-get data :status) "session")))
         (state (ogent-armory-status--session-state status))
         (duration (or (plist-get data :duration) ""))
         (finished (ogent-armory-status--short-time
                    (plist-get data :finished))))
    (format "%s %-42s %-9s %s"
            (propertize (ogent-ops-status-symbol state)
                        'face (ogent-armory-status--state-face state))
            (propertize (or (plist-get node :label) "")
                        'face 'ogent-armory-status-label)
            (propertize (downcase status) 'face 'ogent-armory-status-dimmed)
            (propertize
             (string-join (delq nil
                                (list (ogent-armory--blank-to-nil duration)
                                      (ogent-armory--blank-to-nil finished)))
                          "  ")
             'face 'ogent-armory-status-dimmed))))

(defun ogent-armory-status--format-artifact-line (node)
  "Return display text for app or issue NODE."
  (let ((kind (symbol-name (plist-get node :kind)))
        (label (or (plist-get node :label) ""))
        (data (plist-get node :data)))
    (format "%s %-9s %s%s"
            (propertize (ogent-ops-status-symbol 'ready)
                        'face 'ogent-armory-status-connected)
            (propertize kind 'face 'ogent-armory-status-dimmed)
            (propertize label 'face 'ogent-armory-status-label)
            (if-let ((agent (plist-get data :agent)))
                (propertize (format "  %s" agent)
                            'face 'ogent-armory-status-dimmed)
              ""))))

(defun ogent-armory-status--insert-bridges ()
  "Insert operational bridge section."
  (ogent-section-with (ogent-armory-status-bridges)
      (ogent-armory-status--heading-text "◈" "B" "Bridges")
    (ogent-armory-status--insert-bridge-line
     "Ogent Issues"
     (ogent-armory-status--issues-state)
     "i")))

(defun ogent-armory-status--insert-node-line (node text &optional prefix)
  "Insert TEXT for NODE with optional PREFIX and visit metadata."
  (ogent-section-insert-item-line
   (concat (or prefix "  ")
           text
           (when ogent-armory-status-show-node-ids
             (concat "  " (propertize (plist-get node :id)
                                      'face 'ogent-armory-status-id))))
   'ogent-armory-node node
   (ogent-armory-status--node-help node)))

(defun ogent-armory-status--node-help (node)
  "Return hover help for graph NODE."
  (pcase (plist-get node :kind)
    ('agent "RET visits source, C-c P opens profile, C-c N creates a job, C-c e edits properties, C-c r runs")
    ('job "RET visits source, C-c r runs job, C-c e edits metadata, C-c E edits prompt/body")
    ('session "RET visits transcript, C-c r retries linked work, C-c e edits archive/tags")
    ('app "RET visits source, C-c E visits source body")
    (_ "RET visits this Org record")))

(defun ogent-armory-status--insert-bridge-line (name state key)
  "Insert bridge NAME with STATE and activation KEY."
  (let* ((active (plist-get state :active))
         (face (if active
                   'ogent-armory-status-connected
                 'ogent-armory-status-disconnected)))
    (insert "  ")
    (insert (propertize (if active
                            (ogent-ops-status-symbol 'closed)
                          (ogent-ops-status-symbol 'waiting))
                        'face face))
    (insert " ")
    (insert (propertize name 'face 'ogent-armory-status-label))
    (insert "  ")
    (insert (propertize (plist-get state :message)
                        'face 'ogent-armory-status-dimmed))
    (insert (propertize (format "  %s" key)
                        'face 'ogent-armory-status-dimmed))
    (insert "\n")))

(defun ogent-armory-status--issues-state ()
  "Return current Ogent Issues bridge state."
  (cond
   ((not (require 'ogent-issues-bd nil t))
    (list :active nil :message "issue backend unavailable"))
   ((ogent-issues-bd-initialized-p ogent-armory-status--root)
    (list :active t :message "beads database detected"))
   (t
    (list :active nil :message "no beads database under this armory"))))

(defun ogent-armory-status--node-at-point ()
  "Return the graph node at point."
  (or (get-text-property (point) 'ogent-armory-node)
      (get-text-property (line-beginning-position) 'ogent-armory-node)))

(defun ogent-armory-status--require-node ()
  "Return the graph node at point or signal a Armory status error."
  (or (ogent-armory-status--node-at-point)
      (user-error "No Armory record at point")))

(defun ogent-armory-status--node-agent (node)
  "Return the agent slug associated with NODE."
  (let ((data (plist-get node :data)))
    (pcase (plist-get node :kind)
      ('agent (plist-get data :slug))
      ((or 'job 'session 'app) (plist-get data :agent))
      (_ nil))))

(defun ogent-armory-status--node-job-id (node)
  "Return the job id associated with NODE."
  (let ((data (plist-get node :data)))
    (pcase (plist-get node :kind)
      ('job (plist-get data :id))
      ((or 'session 'app) (plist-get data :job-id))
      (_ nil))))

(defun ogent-armory-status-visit ()
  "Visit the Org record at point."
  (interactive)
  (let* ((node (ogent-armory-status--require-node))
         (kind (plist-get node :kind))
         (path (plist-get node :path)))
    (unless (and path (file-exists-p path))
      (user-error "No Armory record at point"))
    (if (eq kind 'session)
        (let ((display-buffer-overriding-action
               '((display-buffer-same-window))))
          (ogent-armory-conversation ogent-armory-status--root path))
      (find-file path))))

(defun ogent-armory-status-open-issues ()
  "Open Ogent Issues from the current Armory root."
  (interactive)
  (let ((default-directory (or ogent-armory-status--root default-directory)))
    (call-interactively #'ogent-issues)))

(defun ogent-armory-status-run ()
  "Run the Armory agent or job at point."
  (interactive)
  (let* ((node (ogent-armory-status--require-node))
         (kind (plist-get node :kind))
         (data (plist-get node :data)))
    (pcase kind
      ('agent
       (ogent-armory-run-agent
        ogent-armory-status--root
        (plist-get data :slug)
        (read-string "Instruction: ")))
      ('job
       (ogent-armory-run-job
        ogent-armory-status--root
        (plist-get data :agent)
        (plist-get data :id)))
      ('session
       (if-let ((job-id (plist-get data :job-id)))
           (ogent-armory-run-job
            ogent-armory-status--root
            (plist-get data :agent)
            job-id)
         (ogent-armory-run-agent
          ogent-armory-status--root
          (plist-get data :agent)
          (read-string "Instruction: "))))
      (_
       (user-error "No runnable Armory agent or job at point")))))

(defun ogent-armory-status-edit ()
  "Edit metadata for the Armory agent, job, or session at point."
  (interactive)
  (let* ((node (ogent-armory-status--require-node))
         (kind (plist-get node :kind))
         (data (plist-get node :data))
         (path (plist-get node :path)))
    (pcase kind
      ('agent
       (let* ((slug (plist-get data :slug))
              (property (completing-read
                         "Agent property: "
                         ogent-armory-agent-editable-properties
                         nil t))
              (current (ogent-armory-ui--read-current-property
                        (ogent-armory-agent-file ogent-armory-status--root
                                                 slug)
                        property))
              (value (or (ogent-armory-ui--read-property-value
                          ogent-armory-status--root
                          property
                          current
                          data)
                         "")))
         (ogent-armory-update-agent-property
          ogent-armory-status--root slug property value)))
      ('job
       (let* ((agent (plist-get data :agent))
              (job-id (plist-get data :id))
              (property (completing-read
                         "Job property: "
                         ogent-armory-job-editable-properties
                         nil t))
              (current (ogent-armory-ui--read-current-property
                        (ogent-armory-job-file ogent-armory-status--root
                                               agent
                                               job-id)
                        property))
              (value (or (ogent-armory-ui--read-property-value
                          ogent-armory-status--root
                          property
                          current
                          data)
                         ""))
              (candidate (ogent-armory-ui--job-with-property
                          data property value)))
         (ogent-armory-validate-job candidate)
         (ogent-armory-update-job-property
          ogent-armory-status--root agent job-id property value)))
      ('session
       (let* ((property (completing-read
                         "Session property: "
                         '("OGENT_ARCHIVED" "OGENT_TAGS")
                         nil t))
              (current (ogent-armory-ui--read-current-property
                        path property))
              (value (or (ogent-armory-ui--read-property-value
                          ogent-armory-status--root
                          property
                          current
                          data)
                         "")))
         (ogent-armory-update-session-property path property value)))
      (_
       (user-error "No editable Armory record at point"))))
  (ogent-armory-status-refresh))

(defun ogent-armory-status-edit-body ()
  "Visit the selected Armory Org body or prompt."
  (interactive)
  (let* ((node (ogent-armory-status--require-node))
         (path (plist-get node :path)))
    (unless (and path (file-exists-p path))
      (user-error "No Armory file at point"))
    (ogent-armory-ui--visit-body path)))

(defun ogent-armory-status-open-agent-profile ()
  "Open the agent profile associated with the current Armory node."
  (interactive)
  (let* ((node (ogent-armory-status--require-node))
         (slug (ogent-armory-status--node-agent node)))
    (unless slug
      (user-error "No Armory agent at point"))
    (ogent-armory-agent ogent-armory-status--root slug)))

(defun ogent-armory-status-open-agent-jobs ()
  "Open the jobs surface for the agent associated with the current node."
  (interactive)
  (let* ((node (ogent-armory-status--require-node))
         (slug (ogent-armory-status--node-agent node))
         (job-id (ogent-armory-status--node-job-id node)))
    (unless slug
      (user-error "No Armory agent at point"))
    (let ((buffer (ogent-armory-jobs ogent-armory-status--root slug)))
      (when (and job-id (fboundp 'ogent-armory-jobs--goto))
        (with-current-buffer buffer
          (ogent-armory-jobs--goto slug job-id)))
      buffer)))

(defun ogent-armory-status-create-job ()
  "Create a Armory job for the agent associated with the current node."
  (interactive)
  (let* ((node (ogent-armory-status--require-node))
         (slug (ogent-armory-status--node-agent node)))
    (unless slug
      (user-error "No Armory agent at point"))
    (ogent-armory-create-job ogent-armory-status--root slug)))

(defun ogent-armory-status-help ()
  "Show Armory status keybindings and node actions."
  (interactive)
  (with-help-window "*Ogent Armory Status Help*"
    (princ "Armory Status\n")
    (princ "==============\n\n")
    (princ "Rows stay quiet by default. Press ? for the action menu on the item at point.\n")
    (princ "n/p move between actionable rows; RET visits the durable Org source.\n\n")
    (princ "Node actions\n")
    (princ "------------\n")
    (princ "Agent:   P opens profile, e edits identity properties, C creates a job, R runs with a prompt.\n")
    (princ "Job:     R runs the job, e edits metadata, E edits the prompt/body, J opens the job list.\n")
    (princ "Session: R retries linked work, e edits archive/tags, RET visits the transcript.\n")
    (princ "App:     RET visits the source record when available.\n\n")
    (princ "Jumps\n")
    (princ "-----\n")
    (princ "j h Home, j g Graph, j a Agents, j o Org chart, j t Tasks, j c Conversations,\n")
    (princ "j j Jobs, j s Search, j A Apps, j d Data, j u Schedule, j v Git.  i opens Issues.\n\n")
    (princ "Menus\n")
    (princ "-----\n")
    (princ "? opens the Transient menu (h inside it reopens this help). g refreshes; C-u g forces a rebuild. q quits.\n")
    (princ ", opens Settings. / opens the command palette.\n")
    (princ "TAB toggles a section. M-n/M-p move between sibling sections. ^ moves to the parent section.\n")
    (princ "Set `ogent-armory-status-show-node-ids' to show graph ids inline.\n")
    (princ "Evil: keys the buffer binds win over Evil motion; unbound keys keep their Evil meaning.\n")))

(defun ogent-armory-status-next-item ()
  "Move point to the next Armory record line."
  (interactive)
  (let ((next (ogent-section-visible-item-position 'ogent-armory-node 'next)))
    (when next
      (goto-char next))))

(defun ogent-armory-status-previous-item ()
  "Move point to the previous Armory record line."
  (interactive)
  (let ((previous (ogent-section-visible-item-position 'ogent-armory-node
                                                       'previous)))
    (when previous
      (goto-char previous))))

(defun ogent-armory-status--transient-header ()
  "Return the header text for `ogent-armory-status-dispatch'."
  (let* ((root (and (boundp 'ogent-armory-status--root)
                    ogent-armory-status--root))
         (node (ignore-errors (ogent-armory-status--node-at-point)))
         (kind (and node (plist-get node :kind)))
         (label (and node (plist-get node :label))))
    (concat
     (propertize "Armory Status" 'face 'transient-heading)
     (if root
         (concat "  " (propertize (abbreviate-file-name root) 'face 'shadow))
       "")
     (if node
         (format "  %s %s"
                 (propertize (symbol-name kind) 'face 'transient-heading)
                 (propertize (or label "") 'face 'shadow))
       ""))))

;;;###autoload (autoload 'ogent-armory-status-dispatch "ogent-armory-status" nil t)
(ogent-armory-ui--define-prefix ogent-armory-status-dispatch ()
  "Dispatch menu for Armory status buffers."
  [:description ogent-armory-status--transient-header
                ["Run"
                 ("R" "Run/retry selected" ogent-armory-status-run)
                 ("C" "Create job for agent" ogent-armory-status-create-job)]
                ["Edit"
                 ("e" "Edit metadata" ogent-armory-status-edit)
                 ("E" "Edit body/prompt" ogent-armory-status-edit-body)
                 ("P" "Agent profile" ogent-armory-status-open-agent-profile)
                 ("J" "Agent jobs" ogent-armory-status-open-agent-jobs)]
                ["Navigate"
                 ("RET" "Visit Org source" ogent-armory-status-visit)
                 ("TAB" "Toggle section" ogent-section-toggle :transient t)
                 ("M-n" "Next section" ogent-section-next :transient t)
                 ("M-p" "Previous section" ogent-section-prev :transient t)
                 ("^" "Up section" ogent-section-up :transient t)
                 ("n" "Next item" ogent-armory-status-next-item :transient t)
                 ("p" "Previous item" ogent-armory-status-previous-item :transient t)
                 ("g" "Refresh" ogent-armory-status-refresh :transient t)]]
  ["Bridges"
   ("i" "Ogent Issues" ogent-armory-status-open-issues)]
  ["Help"
   ("h" "Help" ogent-armory-status-help)
   ("q" "Quit menu" transient-quit-one)])

(defun ogent-armory-status--evil-local-keys ()
  "Install local Evil keys for Armory status."
  (ogent-armory-evil-install-local-bindings ogent-armory-status-mode-map))

(defun ogent-armory-status--setup-evil ()
  "Set up Evil integration for Armory status buffers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-status-mode
   ogent-armory-status-mode-map
   'ogent-armory-status-mode-hook
   #'ogent-armory-status--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-status--setup-evil))

(provide 'ogent-armory-status)

;;; ogent-armory-status.el ends here
