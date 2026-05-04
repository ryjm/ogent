;;; ogent-cabinet-status.el --- Operational view for Org cabinets -*- lexical-binding: t; -*-

;;; Commentary:
;; Renders the Org cabinet graph as an operational buffer with the same
;; refresh, visit, and bridge conventions used by Ogent Issues and Gas Town.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ogent-cabinet)
(require 'ogent-cabinet-runner)
(require 'ogent-ops-style)

(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-gastown-status "ogent-gastown-status" nil t)
(autoload 'ogent-cabinet-agents "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-tasks "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-search "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-open-app "ogent-ui-cabinet" nil t)

(declare-function ogent-issues-bd-initialized-p "ogent-issues-bd" (&optional directory))

(defgroup ogent-cabinet-status nil
  "Operational status view for Org cabinets."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-status-")

(defcustom ogent-cabinet-status-buffer-name-format "*ogent-cabinet: %s*"
  "Format string used for Cabinet status buffer names."
  :type 'string
  :group 'ogent-cabinet-status)

(defface ogent-cabinet-status-heading
  '((((class color) (background light))
     :foreground "#263238" :background "#eceff1" :weight bold :extend t)
    (((class color) (background dark))
     :foreground "#eceff4" :background "#3b4252" :weight bold :extend t)
    (t :weight bold))
  "Face for Cabinet status section headings."
  :group 'ogent-cabinet-status)

(defface ogent-cabinet-status-id
  '((((class color) (background light)) :foreground "#546e7a")
    (((class color) (background dark)) :foreground "#81a1c1")
    (t :inherit shadow))
  "Face for Cabinet graph identifiers."
  :group 'ogent-cabinet-status)

(defface ogent-cabinet-status-label
  '((((class color) (background light)) :foreground "#263238" :weight bold)
    (((class color) (background dark)) :foreground "#eceff4" :weight bold)
    (t :weight bold))
  "Face for Cabinet graph labels."
  :group 'ogent-cabinet-status)

(defface ogent-cabinet-status-dimmed
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#677489")
    (t :inherit shadow))
  "Face for secondary Cabinet status text."
  :group 'ogent-cabinet-status)

(defface ogent-cabinet-status-connected
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c")
    (t :inherit success))
  "Face for connected operational bridges."
  :group 'ogent-cabinet-status)

(defface ogent-cabinet-status-disconnected
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#5c6370")
    (t :inherit shadow))
  "Face for inactive operational bridges."
  :group 'ogent-cabinet-status)

(defvar-local ogent-cabinet-status--root nil
  "Cabinet root shown by the current status buffer.")

(defvar-local ogent-cabinet-status--graph nil
  "Cabinet graph shown by the current status buffer.")

(defvar ogent-cabinet-status-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-cabinet-status-refresh)
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-status-visit))
    (define-key map "n" #'ogent-cabinet-status-next-item)
    (define-key map "p" #'ogent-cabinet-status-previous-item)
    (define-key map "i" #'ogent-cabinet-status-open-issues)
    (define-key map "G" #'ogent-cabinet-status-open-gastown)
    (define-key map "R" #'ogent-cabinet-status-run)
    (define-key map "a" #'ogent-cabinet-agents)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map "o" #'ogent-cabinet-open-app)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-status-mode'.")

(define-derived-mode ogent-cabinet-status-mode special-mode "Cabinet"
  "Major mode for Cabinet graph status.

\\<ogent-cabinet-status-mode-map>
\\[ogent-cabinet-status-refresh] refreshes the graph.
\\[ogent-cabinet-status-visit] visits the Org record at point.
\\[ogent-cabinet-status-open-issues] opens Ogent Issues.
\\[ogent-cabinet-status-open-gastown] opens Gas Town status."
  :group 'ogent-cabinet-status
  (setq-local revert-buffer-function #'ogent-cabinet-status-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (font-lock-mode -1)
  (ogent-ops-protect-face-properties)
  (setq header-line-format '(:eval (ogent-cabinet-status--header-line))))

(defun ogent-cabinet-status--buffer-name (root)
  "Return the Cabinet status buffer name for ROOT."
  (format ogent-cabinet-status-buffer-name-format
          (file-name-nondirectory (directory-file-name root))))

;;;###autoload
(defun ogent-cabinet-status (&optional directory)
  "Open a Cabinet status buffer for DIRECTORY.
When DIRECTORY is nil, use the nearest cabinet root or prompt for one."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((candidate (ogent-cabinet--directory
                     (or directory default-directory)))
         (root (directory-file-name
                (file-truename
                 (or (ogent-cabinet-find-root candidate)
                     candidate))))
         (buffer (get-buffer-create (ogent-cabinet-status--buffer-name root))))
    (with-current-buffer buffer
      (ogent-cabinet-status-mode)
      (setq ogent-cabinet-status--root root)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-status-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-status-refresh (&rest _)
  "Refresh the current Cabinet status buffer."
  (interactive)
  (unless ogent-cabinet-status--root
    (setq ogent-cabinet-status--root
          (or (ogent-cabinet-find-root)
              (read-directory-name "Cabinet root: "))))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq ogent-cabinet-status--graph
          (ogent-cabinet-build-graph ogent-cabinet-status--root))
    (ogent-cabinet-status--insert-buffer)
    (goto-char (point-min))))

(defun ogent-cabinet-status--header-line ()
  "Return header line text for the current Cabinet status buffer."
  (concat
   "g refresh  RET visit  n/p move  a agents  t tasks  s search  o app  i issues  G gastown  R run  q quit"
   (when ogent-cabinet-status--root
     (concat "    "
             (propertize
              (abbreviate-file-name ogent-cabinet-status--root)
              'face 'ogent-cabinet-status-dimmed)))))

(defun ogent-cabinet-status--nodes-by-kind (kind)
  "Return graph nodes whose `:kind' is KIND."
  (seq-filter
   (lambda (node)
     (eq (plist-get node :kind) kind))
   (plist-get ogent-cabinet-status--graph :nodes)))

(defun ogent-cabinet-status--edges-from (node-id kind)
  "Return graph edges from NODE-ID whose `:kind' is KIND."
  (seq-filter
   (lambda (edge)
     (and (equal (plist-get edge :from) node-id)
          (eq (plist-get edge :kind) kind)))
   (plist-get ogent-cabinet-status--graph :edges)))

(defun ogent-cabinet-status--node-by-id (node-id)
  "Return graph node NODE-ID."
  (seq-find
   (lambda (node)
     (equal (plist-get node :id) node-id))
   (plist-get ogent-cabinet-status--graph :nodes)))

(defun ogent-cabinet-status--insert-buffer ()
  "Insert the Cabinet status buffer contents."
  (ogent-cabinet-status--insert-summary)
  (insert "\n")
  (ogent-cabinet-status--insert-agents)
  (insert "\n")
  (ogent-cabinet-status--insert-bridges))

(defun ogent-cabinet-status--insert-heading (icon ascii label &optional count)
  "Insert a heading with ICON, ASCII fallback, LABEL, and optional COUNT."
  (insert
   (propertize
    (ogent-ops-section-heading
     (ogent-ops-section-prefix icon ascii)
     label
     count
     'ogent-cabinet-status-dimmed)
    'face 'ogent-cabinet-status-heading)
   "\n"))

(defun ogent-cabinet-status--insert-summary ()
  "Insert graph summary section."
  (let* ((cabinet (car (ogent-cabinet-status--nodes-by-kind 'cabinet)))
         (nodes (plist-get ogent-cabinet-status--graph :nodes))
         (edges (plist-get ogent-cabinet-status--graph :edges)))
    (ogent-cabinet-status--insert-heading "◇" "C" "Cabinet Graph" 1)
    (when cabinet
      (ogent-cabinet-status--insert-node-line
       cabinet
       (format "%s  %s nodes, %s edges"
               (propertize (or (plist-get cabinet :label) "Cabinet")
                           'face 'ogent-cabinet-status-label)
               (length nodes)
               (length edges))))
    (insert "  ")
    (insert (propertize "Projection: " 'face 'ogent-cabinet-status-dimmed))
    (insert "Org files -> typed graph -> operational views\n")))

(defun ogent-cabinet-status--insert-agents ()
  "Insert agents and their scheduled jobs."
  (let ((agents (ogent-cabinet-status--nodes-by-kind 'agent)))
    (ogent-cabinet-status--insert-heading "◆" "A" "Agents" (length agents))
    (if agents
        (dolist (agent agents)
          (let* ((data (plist-get agent :data))
                 (id (plist-get agent :id))
                 (jobs (mapcar
                        (lambda (edge)
                          (ogent-cabinet-status--node-by-id
                           (plist-get edge :to)))
                        (ogent-cabinet-status--edges-from id 'owns)))
                 (provider (or (plist-get data :provider) "codex"))
                 (status (cond
                          ((ogent-cabinet-runner-running-p
                            (plist-get data :slug))
                           'working)
                          ((plist-get data :active) 'active)
                          (t 'idle))))
            (ogent-cabinet-status--insert-node-line
             agent
             (format "%s %s  %s  %s  %s"
                     (propertize (ogent-ops-activity-symbol status)
                                 'face (if (memq status '(active working))
                                           'ogent-cabinet-status-connected
                                         'ogent-cabinet-status-disconnected))
                     (propertize (plist-get agent :label)
                                 'face 'ogent-cabinet-status-label)
                     (propertize
                      (or (plist-get data :role) "Agent")
                      'face 'ogent-cabinet-status-dimmed)
                     (propertize provider
                                 'face 'ogent-cabinet-status-dimmed)
                     (propertize
                      (format "%d jobs" (length jobs))
                      'face 'ogent-cabinet-status-dimmed)))
            (dolist (job jobs)
              (when job
                (ogent-cabinet-status--insert-node-line
                 job
                 (ogent-cabinet-status--format-job-line job)
                 "    ")))))
      (insert (propertize "  No agents yet\n"
                          'face 'ogent-cabinet-status-dimmed)))))

(defun ogent-cabinet-status--format-job-line (job)
  "Return display text for JOB."
  (let* ((data (plist-get job :data))
         (enabled (plist-get data :enabled))
         (state (if enabled 'ready 'waiting)))
    (format "%s %s  %s"
            (propertize (ogent-ops-status-symbol state)
                        'face (if enabled
                                  'ogent-cabinet-status-connected
                                'ogent-cabinet-status-disconnected))
            (propertize (plist-get job :label)
                        'face 'ogent-cabinet-status-label)
            (propertize (or (plist-get data :cron) "manual")
                        'face 'ogent-cabinet-status-dimmed))))

(defun ogent-cabinet-status--insert-bridges ()
  "Insert operational bridge section."
  (ogent-cabinet-status--insert-heading "◈" "B" "Operational Bridges")
  (ogent-cabinet-status--insert-bridge-line
   "Ogent Issues"
   (ogent-cabinet-status--issues-state)
   "i")
  (ogent-cabinet-status--insert-bridge-line
   "Gas Town"
   (ogent-cabinet-status--gastown-state)
   "G"))

(defun ogent-cabinet-status--insert-node-line (node text &optional prefix)
  "Insert TEXT for NODE with optional PREFIX and visit metadata."
  (let ((start (point)))
    (insert (or prefix "  "))
    (insert text)
    (insert "  ")
    (insert (propertize (plist-get node :id)
                        'face 'ogent-cabinet-status-id))
    (insert "\n")
    (add-text-properties
     start
     (point)
     `(ogent-cabinet-node ,node
                          mouse-face highlight
                          help-echo "RET visits this Org record"))))

(defun ogent-cabinet-status--insert-bridge-line (name state key)
  "Insert bridge NAME with STATE and activation KEY."
  (let* ((active (plist-get state :active))
         (face (if active
                   'ogent-cabinet-status-connected
                 'ogent-cabinet-status-disconnected)))
    (insert "  ")
    (insert (propertize (if active
                            (ogent-ops-status-symbol 'closed)
                          (ogent-ops-status-symbol 'waiting))
                        'face face))
    (insert " ")
    (insert (propertize name 'face 'ogent-cabinet-status-label))
    (insert "  ")
    (insert (propertize (plist-get state :message)
                        'face 'ogent-cabinet-status-dimmed))
    (insert "  ")
    (insert (propertize (format "[%s]" key)
                        'face 'ogent-cabinet-status-id))
    (insert "\n")))

(defun ogent-cabinet-status--issues-state ()
  "Return current Ogent Issues bridge state."
  (cond
   ((not (require 'ogent-issues-bd nil t))
    (list :active nil :message "issue backend unavailable"))
   ((ogent-issues-bd-initialized-p ogent-cabinet-status--root)
    (list :active t :message "beads database detected"))
   (t
    (list :active nil :message "no beads database under this cabinet"))))

(defun ogent-cabinet-status--gastown-state ()
  "Return current Gas Town bridge state."
  (let ((town-root (and ogent-cabinet-status--root
                        (locate-dominating-file
                         ogent-cabinet-status--root
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

(defun ogent-cabinet-status--node-at-point ()
  "Return the graph node at point."
  (or (get-text-property (point) 'ogent-cabinet-node)
      (get-text-property (line-beginning-position) 'ogent-cabinet-node)))

(defun ogent-cabinet-status-visit ()
  "Visit the Org record at point."
  (interactive)
  (let* ((node (ogent-cabinet-status--node-at-point))
         (path (plist-get node :path)))
    (unless (and path (file-exists-p path))
      (user-error "No Cabinet record at point"))
    (find-file path)))

(defun ogent-cabinet-status-open-issues ()
  "Open Ogent Issues from the current Cabinet root."
  (interactive)
  (let ((default-directory (or ogent-cabinet-status--root default-directory)))
    (call-interactively #'ogent-issues)))

(defun ogent-cabinet-status-open-gastown ()
  "Open Gas Town status from the current Cabinet root."
  (interactive)
  (let ((default-directory (or ogent-cabinet-status--root default-directory)))
    (call-interactively #'ogent-gastown-status)))

(defun ogent-cabinet-status-run ()
  "Run the Cabinet agent or job at point."
  (interactive)
  (let* ((node (ogent-cabinet-status--node-at-point))
         (kind (plist-get node :kind))
         (data (plist-get node :data)))
    (pcase kind
      ('agent
       (ogent-cabinet-run-agent
        ogent-cabinet-status--root
        (plist-get data :slug)
        (read-string "Instruction: ")))
      ('job
       (ogent-cabinet-run-job
        ogent-cabinet-status--root
        (plist-get data :agent)
        (plist-get data :id)))
      (_
       (user-error "No runnable Cabinet agent or job at point")))))

(defun ogent-cabinet-status-next-item ()
  "Move point to the next Cabinet record line."
  (interactive)
  (let ((next (next-single-property-change
               (point)
               'ogent-cabinet-node
               nil
               (point-max))))
    (when next
      (goto-char next)
      (unless (get-text-property (point) 'ogent-cabinet-node)
        (setq next (next-single-property-change
                    (point)
                    'ogent-cabinet-node
                    nil
                    (point-max)))
        (when next
          (goto-char next))))))

(defun ogent-cabinet-status-previous-item ()
  "Move point to the previous Cabinet record line."
  (interactive)
  (let ((previous (previous-single-property-change
                   (point)
                   'ogent-cabinet-node
                   nil
                   (point-min))))
    (when previous
      (goto-char (max (point-min) (1- previous)))
      (unless (get-text-property (point) 'ogent-cabinet-node)
        (setq previous (previous-single-property-change
                        (point)
                        'ogent-cabinet-node
                        nil
                        (point-min)))
        (when previous
          (goto-char (max (point-min) (1- previous))))))))

(provide 'ogent-cabinet-status)

;;; ogent-cabinet-status.el ends here
