;;; ogent-armory-status.el --- Operational view for Org armories -*- lexical-binding: t; -*-

;;; Commentary:
;; Renders the Org armory graph as an operational buffer with the same
;; refresh, visit, and bridge conventions used by Ogent Issues and Gas Town.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ogent-armory)
(require 'ogent-armory-runner)
(require 'ogent-ops-style)

(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-gastown-status "ogent-gastown-status" nil t)
(autoload 'ogent-armory-agents "ogent-ui-armory" nil t)
(autoload 'ogent-armory-tasks "ogent-ui-armory" nil t)
(autoload 'ogent-armory-conversations "ogent-ui-armory" nil t)
(autoload 'ogent-armory-search "ogent-ui-armory" nil t)
(autoload 'ogent-armory-apps "ogent-ui-armory" nil t)
(autoload 'ogent-armory-home "ogent-ui-armory" nil t)

(declare-function ogent-issues-bd-initialized-p "ogent-issues-bd" (&optional directory))

(defgroup ogent-armory-status nil
  "Operational status view for Org armories."
  :group 'ogent-armory
  :prefix "ogent-armory-status-")

(defcustom ogent-armory-status-buffer-name-format "*ogent-armory: %s*"
  "Format string used for Armory status buffer names."
  :type 'string
  :group 'ogent-armory-status)

(defface ogent-armory-status-heading
  '((((class color) (background light))
     :foreground "#263238" :background "#eceff1" :weight bold :extend t)
    (((class color) (background dark))
     :foreground "#eceff4" :background "#3b4252" :weight bold :extend t)
    (t :weight bold))
  "Face for Armory status section headings."
  :group 'ogent-armory-status)

(defface ogent-armory-status-id
  '((((class color) (background light)) :foreground "#546e7a")
    (((class color) (background dark)) :foreground "#81a1c1")
    (t :inherit shadow))
  "Face for Armory graph identifiers."
  :group 'ogent-armory-status)

(defface ogent-armory-status-label
  '((((class color) (background light)) :foreground "#263238" :weight bold)
    (((class color) (background dark)) :foreground "#eceff4" :weight bold)
    (t :weight bold))
  "Face for Armory graph labels."
  :group 'ogent-armory-status)

(defface ogent-armory-status-dimmed
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#677489")
    (t :inherit shadow))
  "Face for secondary Armory status text."
  :group 'ogent-armory-status)

(defface ogent-armory-status-connected
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c")
    (t :inherit success))
  "Face for connected operational bridges."
  :group 'ogent-armory-status)

(defface ogent-armory-status-disconnected
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#5c6370")
    (t :inherit shadow))
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
    (define-key map "G" #'ogent-armory-status-open-gastown)
    (define-key map "R" #'ogent-armory-status-run)
    (define-key map "h" #'ogent-armory-home)
    (define-key map "a" #'ogent-armory-agents)
    (define-key map "t" #'ogent-armory-tasks)
    (define-key map "c" #'ogent-armory-conversations)
    (define-key map "s" #'ogent-armory-search)
    (define-key map "A" #'ogent-armory-apps)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-status-mode'.")

(define-derived-mode ogent-armory-status-mode special-mode "Armory"
  "Major mode for Armory graph status.

\\<ogent-armory-status-mode-map>
\\[ogent-armory-status-refresh] refreshes the graph.
\\[ogent-armory-status-visit] visits the Org record at point.
\\[ogent-armory-status-open-issues] opens Ogent Issues.
\\[ogent-armory-status-open-gastown] opens Gas Town status."
  :group 'ogent-armory-status
  (setq-local revert-buffer-function #'ogent-armory-status-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (font-lock-mode -1)
  (ogent-ops-protect-face-properties)
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

(defun ogent-armory-status-refresh (&rest _)
  "Refresh the current Armory status buffer."
  (interactive)
  (unless ogent-armory-status--root
    (setq ogent-armory-status--root
          (or (ogent-armory-find-root)
              (read-directory-name "Armory root: "))))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq ogent-armory-status--graph
          (ogent-armory-build-graph ogent-armory-status--root))
    (ogent-armory-status--insert-buffer)
    (goto-char (point-min))))

(defun ogent-armory-status--header-line ()
  "Return header line text for the current Armory status buffer."
  (concat
   "g refresh  RET visit  n/p move  h home  a agents  t tasks  c conversations  s search  A apps  i issues  G gastown  R run  q quit"
   (when ogent-armory-status--root
     (concat "    "
             (propertize
              (abbreviate-file-name ogent-armory-status--root)
              'face 'ogent-armory-status-dimmed)))))

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

(defun ogent-armory-status--insert-buffer ()
  "Insert the Armory status buffer contents."
  (ogent-armory-status--insert-summary)
  (insert "\n")
  (ogent-armory-status--insert-agents)
  (insert "\n")
  (ogent-armory-status--insert-related)
  (insert "\n")
  (ogent-armory-status--insert-bridges))

(defun ogent-armory-status--insert-heading (icon ascii label &optional count)
  "Insert a heading with ICON, ASCII fallback, LABEL, and optional COUNT."
  (insert
   (propertize
    (ogent-ops-section-heading
     (ogent-ops-section-prefix icon ascii)
     label
     count
     'ogent-armory-status-dimmed)
    'face 'ogent-armory-status-heading)
   "\n"))

(defun ogent-armory-status--insert-summary ()
  "Insert graph summary section."
  (let* ((armory (car (ogent-armory-status--nodes-by-kind 'armory)))
         (nodes (plist-get ogent-armory-status--graph :nodes))
         (edges (plist-get ogent-armory-status--graph :edges)))
    (ogent-armory-status--insert-heading "◇" "C" "Armory Graph" 1)
    (when armory
      (ogent-armory-status--insert-node-line
       armory
       (format "%s  %s nodes, %s edges"
               (propertize (or (plist-get armory :label) "Armory")
                           'face 'ogent-armory-status-label)
               (length nodes)
               (length edges))))
    (insert "  ")
    (insert (propertize "Projection: " 'face 'ogent-armory-status-dimmed))
    (insert "Org files -> typed graph -> operational views\n")))

(defun ogent-armory-status--insert-agents ()
  "Insert agents and their scheduled jobs."
  (let ((agents (ogent-armory-status--nodes-by-kind 'agent)))
    (ogent-armory-status--insert-heading "◆" "A" "Agents" (length agents))
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
                 (status (cond
                          ((ogent-armory-runner-running-p
                            (plist-get data :slug))
                           'working)
                          ((plist-get data :active) 'active)
                          (t 'idle))))
            (ogent-armory-status--insert-node-line
             agent
             (format "%s %s  %s  %s  %s"
                     (propertize (ogent-ops-activity-symbol status)
                                 'face (if (memq status '(active working))
                                           'ogent-armory-status-connected
                                         'ogent-armory-status-disconnected))
                     (propertize (plist-get agent :label)
                                 'face 'ogent-armory-status-label)
                     (propertize
                      (or (plist-get data :role) "Agent")
                      'face 'ogent-armory-status-dimmed)
                     (propertize provider
                                 'face 'ogent-armory-status-dimmed)
                     (propertize
                      (format "%d jobs" (length jobs))
                      'face 'ogent-armory-status-dimmed)))
            (dolist (job jobs)
              (when job
                (ogent-armory-status--insert-node-line
                 job
                 (ogent-armory-status--format-job-line job)
                 "    ")))))
      (insert (propertize "  No agents yet\n"
                          'face 'ogent-armory-status-dimmed)))))

(defun ogent-armory-status--insert-related ()
  "Insert non-agent graph nodes."
  (let ((nodes (seq-filter
                (lambda (node)
                  (memq (plist-get node :kind)
                        '(session app issue gastown-hook)))
                (plist-get ogent-armory-status--graph :nodes))))
    (ogent-armory-status--insert-heading "◇" "R" "Relationships" (length nodes))
    (if nodes
        (dolist (node nodes)
          (ogent-armory-status--insert-node-line
           node
           (format "%s  %s"
                   (propertize (symbol-name (plist-get node :kind))
                               'face 'ogent-armory-status-dimmed)
                   (propertize (or (plist-get node :label) "")
                               'face 'ogent-armory-status-label))))
      (insert (propertize "  No sessions, apps, issues, or hooks yet\n"
                          'face 'ogent-armory-status-dimmed)))))

(defun ogent-armory-status--format-job-line (job)
  "Return display text for JOB."
  (let* ((data (plist-get job :data))
         (enabled (plist-get data :enabled))
         (state (if enabled 'ready 'waiting)))
    (format "%s %s  %s"
            (propertize (ogent-ops-status-symbol state)
                        'face (if enabled
                                  'ogent-armory-status-connected
                                'ogent-armory-status-disconnected))
            (propertize (plist-get job :label)
                        'face 'ogent-armory-status-label)
            (propertize (or (plist-get data :cron) "manual")
                        'face 'ogent-armory-status-dimmed))))

(defun ogent-armory-status--insert-bridges ()
  "Insert operational bridge section."
  (ogent-armory-status--insert-heading "◈" "B" "Operational Bridges")
  (ogent-armory-status--insert-bridge-line
   "Ogent Issues"
   (ogent-armory-status--issues-state)
   "i")
  (ogent-armory-status--insert-bridge-line
   "Gas Town"
   (ogent-armory-status--gastown-state)
   "G"))

(defun ogent-armory-status--insert-node-line (node text &optional prefix)
  "Insert TEXT for NODE with optional PREFIX and visit metadata."
  (let ((start (point)))
    (insert (or prefix "  "))
    (insert text)
    (insert "  ")
    (insert (propertize (plist-get node :id)
                        'face 'ogent-armory-status-id))
    (insert "\n")
    (add-text-properties
     start
     (point)
     `(ogent-armory-node ,node
                          mouse-face highlight
                          help-echo "RET visits this Org record"))))

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
    (insert "  ")
    (insert (propertize (format "[%s]" key)
                        'face 'ogent-armory-status-id))
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

(defun ogent-armory-status--gastown-state ()
  "Return current Gas Town bridge state."
  (let ((town-root (and ogent-armory-status--root
                        (locate-dominating-file
                         ogent-armory-status--root
                         ".gastown"))))
    (cond
     ((not (executable-find "gt"))
      (list :active nil :message "gt command unavailable"))
     (town-root
      (list :active t
            :message (format "workspace %s"
                             (abbreviate-file-name town-root))))
     ((or (getenv "GT_ROOT") (getenv "GT_TOWN"))
      (list :active t :message "environment workspace configured"))
     (t
      (list :active nil :message "gt available, no workspace marker here")))))

(defun ogent-armory-status--node-at-point ()
  "Return the graph node at point."
  (or (get-text-property (point) 'ogent-armory-node)
      (get-text-property (line-beginning-position) 'ogent-armory-node)))

(defun ogent-armory-status-visit ()
  "Visit the Org record at point."
  (interactive)
  (let* ((node (ogent-armory-status--node-at-point))
         (path (plist-get node :path)))
    (unless (and path (file-exists-p path))
      (user-error "No Armory record at point"))
    (find-file path)))

(defun ogent-armory-status-open-issues ()
  "Open Ogent Issues from the current Armory root."
  (interactive)
  (let ((default-directory (or ogent-armory-status--root default-directory)))
    (call-interactively #'ogent-issues)))

(defun ogent-armory-status-open-gastown ()
  "Open Gas Town status from the current Armory root."
  (interactive)
  (let ((default-directory (or ogent-armory-status--root default-directory)))
    (call-interactively #'ogent-gastown-status)))

(defun ogent-armory-status-run ()
  "Run the Armory agent or job at point."
  (interactive)
  (let* ((node (ogent-armory-status--node-at-point))
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

(defun ogent-armory-status-next-item ()
  "Move point to the next Armory record line."
  (interactive)
  (let ((next (next-single-property-change
               (point)
               'ogent-armory-node
               nil
               (point-max))))
    (when next
      (goto-char next)
      (unless (get-text-property (point) 'ogent-armory-node)
        (setq next (next-single-property-change
                    (point)
                    'ogent-armory-node
                    nil
                    (point-max)))
        (when next
          (goto-char next))))))

(defun ogent-armory-status-previous-item ()
  "Move point to the previous Armory record line."
  (interactive)
  (let ((previous (previous-single-property-change
                   (point)
                   'ogent-armory-node
                   nil
                   (point-min))))
    (when previous
      (goto-char (max (point-min) (1- previous)))
      (unless (get-text-property (point) 'ogent-armory-node)
        (setq previous (previous-single-property-change
                        (point)
                        'ogent-armory-node
                        nil
                        (point-min)))
        (when previous
          (goto-char (max (point-min) (1- previous))))))))

(provide 'ogent-armory-status)

;;; ogent-armory-status.el ends here
