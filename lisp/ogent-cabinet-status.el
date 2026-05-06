;;; ogent-cabinet-status.el --- Operational view for Org cabinets -*- lexical-binding: t; -*-

;;; Commentary:
;; Renders the Org cabinet graph as an operational buffer with the same
;; refresh, visit, and bridge conventions used by Ogent Issues and Gas Town.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'time-date)
(require 'transient)
(require 'ogent-cabinet)
(require 'ogent-cabinet-evil)
(require 'ogent-cabinet-runner)
(require 'ogent-ops-style)

(eval-and-compile
  (defvar ogent-cabinet-status--magit-section-available
    (require 'magit-section nil t)
    "Non-nil when `magit-section' is available for Cabinet status.")
  (when ogent-cabinet-status--magit-section-available
    (require 'magit-section)))

(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-gastown-status "ogent-gastown-status" nil t)
(autoload 'ogent-cabinet-agents "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-tasks "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-conversations "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-search "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-apps "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-home "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-agent "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-jobs "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-create-job "ogent-ui-cabinet" nil t)
(autoload 'ogent-cabinet-conversation "ogent-ui-cabinet" nil t)

(declare-function ogent-issues-bd-initialized-p "ogent-issues-bd" (&optional directory))
(declare-function ogent-cabinet-jobs--goto "ogent-ui-cabinet" (agent job-id))
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

(defgroup ogent-cabinet-status nil
  "Operational status view for Org cabinets."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-status-")

(defcustom ogent-cabinet-status-buffer-name-format "*ogent-cabinet: %s*"
  "Format string used for Cabinet status buffer names."
  :type 'string
  :group 'ogent-cabinet-status)

(defcustom ogent-cabinet-status-show-node-ids nil
  "Non-nil means show graph node ids in Cabinet status rows."
  :type 'boolean
  :group 'ogent-cabinet-status)

(defcustom ogent-cabinet-status-max-related-items 6
  "Maximum recent work and artifact rows shown before summarizing the rest."
  :type 'integer
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

(defconst ogent-cabinet-status-agent-editable-properties
  '("OGENT_ROLE"
    "OGENT_PROVIDER"
    "OGENT_MODEL"
    "OGENT_PERMISSION_MODE"
    "OGENT_HEARTBEAT"
    "OGENT_ACTIVE"
    "OGENT_WORKSPACE"
    "OGENT_TAGS")
  "Agent properties editable from Cabinet status.")

(defconst ogent-cabinet-status-job-editable-properties
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
    "OGENT_CABINET_PATH"
    "OGENT_CREATED_AT"
    "OGENT_UPDATED_AT"
    "OGENT_RUN_AFTER"
    "OGENT_OWNER_TASK"
    "OGENT_ONE_SHOT_STATE"
    "OGENT_LAST_RUN"
    "OGENT_NEXT_RUN"
    "OGENT_TAGS"
    "OGENT_ARCHIVED")
  "Job properties editable from Cabinet status.")

(defconst ogent-cabinet-status-job-property-keys
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
    ("OGENT_CABINET_PATH" . :cabinet-path)
    ("OGENT_CREATED_AT" . :created-at)
    ("OGENT_UPDATED_AT" . :updated-at)
    ("OGENT_RUN_AFTER" . :run-after)
    ("OGENT_OWNER_TASK" . :owner-task)
    ("OGENT_ONE_SHOT_STATE" . :one-shot-state)
    ("OGENT_LAST_RUN" . :last-run)
    ("OGENT_NEXT_RUN" . :next-run)
    ("OGENT_TAGS" . :tags)
    ("OGENT_ARCHIVED" . :archived-raw))
  "Map editable job Org properties to Cabinet job plist keys.")

(defvar-local ogent-cabinet-status--root nil
  "Cabinet root shown by the current status buffer.")

(defvar-local ogent-cabinet-status--graph nil
  "Cabinet graph shown by the current status buffer.")

(defvar ogent-cabinet-status-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-cabinet-status-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-status-refresh)
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-status-visit))
    (define-key map "n" #'ogent-cabinet-status-next-item)
    (define-key map (kbd "C-c n") #'ogent-cabinet-status-next-item)
    (define-key map "p" #'ogent-cabinet-status-previous-item)
    (define-key map (kbd "C-c p") #'ogent-cabinet-status-previous-item)
    (define-key map "i" #'ogent-cabinet-status-open-issues)
    (define-key map (kbd "C-c i") #'ogent-cabinet-status-open-issues)
    (define-key map "G" #'ogent-cabinet-status-open-gastown)
    (define-key map (kbd "C-c G") #'ogent-cabinet-status-open-gastown)
    (define-key map "R" #'ogent-cabinet-status-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-status-run)
    (define-key map "m" #'ogent-cabinet-status-dispatch)
    (define-key map (kbd "C-c m") #'ogent-cabinet-status-dispatch)
    (define-key map "?" #'ogent-cabinet-status-help)
    (define-key map (kbd "C-c ?") #'ogent-cabinet-status-help)
    (define-key map "e" #'ogent-cabinet-status-edit)
    (define-key map (kbd "C-c e") #'ogent-cabinet-status-edit)
    (define-key map "E" #'ogent-cabinet-status-edit-body)
    (define-key map (kbd "C-c E") #'ogent-cabinet-status-edit-body)
    (define-key map "P" #'ogent-cabinet-status-open-agent-profile)
    (define-key map (kbd "C-c P") #'ogent-cabinet-status-open-agent-profile)
    (define-key map "J" #'ogent-cabinet-status-open-agent-jobs)
    (define-key map (kbd "C-c J") #'ogent-cabinet-status-open-agent-jobs)
    (define-key map "C" #'ogent-cabinet-status-create-job)
    (define-key map (kbd "C-c N") #'ogent-cabinet-status-create-job)
    (define-key map (kbd "TAB") #'ogent-cabinet-status-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-cabinet-status-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-cabinet-status-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-cabinet-status-next-section)
    (define-key map (kbd "M-p") #'ogent-cabinet-status-previous-section)
    (define-key map (kbd "^") #'ogent-cabinet-status-up-section)
    (define-key map (kbd "C-c u") #'ogent-cabinet-status-up-section)
    (define-key map "h" #'ogent-cabinet-home)
    (define-key map (kbd "C-c h") #'ogent-cabinet-home)
    (define-key map "a" #'ogent-cabinet-agents)
    (define-key map (kbd "C-c a") #'ogent-cabinet-agents)
    (define-key map "t" #'ogent-cabinet-tasks)
    (define-key map (kbd "C-c t") #'ogent-cabinet-tasks)
    (define-key map "c" #'ogent-cabinet-conversations)
    (define-key map (kbd "C-c c") #'ogent-cabinet-conversations)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-search)
    (define-key map "A" #'ogent-cabinet-apps)
    (define-key map (kbd "C-c A") #'ogent-cabinet-apps)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-status-mode'.")

(defun ogent-cabinet-status--refresh-magit-section-availability ()
  "Refresh `magit-section' availability for Cabinet status."
  (setq ogent-cabinet-status--magit-section-available
        (or ogent-cabinet-status--magit-section-available
            (require 'magit-section nil t)))
  (when (and ogent-cabinet-status--magit-section-available
             (not (featurep 'magit-section)))
    (require 'magit-section))
  ogent-cabinet-status--magit-section-available)

(defun ogent-cabinet-status--magit-section-usable-p ()
  "Return non-nil when Magit section APIs are usable."
  (and (ogent-cabinet-status--refresh-magit-section-availability)
       (fboundp 'magit-current-section)
       (fboundp 'magit-insert-heading)
       (fboundp 'magit-section-toggle)
       (fboundp 'magit-section-forward-sibling)
       (fboundp 'magit-section-backward-sibling)))

(defun ogent-cabinet-status--mode-parent ()
  "Return the parent mode for Cabinet status."
  (if (ogent-cabinet-status--magit-section-usable-p)
      'magit-section-mode
    'special-mode))

(defun ogent-cabinet-status--mode-setup ()
  "Set up local state for Cabinet status buffers."
  (setq-local revert-buffer-function #'ogent-cabinet-status-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (font-lock-mode -1)
  (ogent-ops-protect-face-properties)
  (when (ogent-cabinet-status--magit-section-usable-p)
    (when (boundp 'magit-section-mode-map)
      (set-keymap-parent ogent-cabinet-status-mode-map magit-section-mode-map))
    (setq-local magit-section-visibility-indicator '("..." . t)))
  (setq header-line-format '(:eval (ogent-cabinet-status--header-line))))

(defmacro ogent-cabinet-status--define-mode ()
  "Define `ogent-cabinet-status-mode' with the available parent mode."
  (let ((parent (if (bound-and-true-p ogent-cabinet-status--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ogent-cabinet-status-mode ,parent "Cabinet"
       "Major mode for Cabinet graph status.

\\<ogent-cabinet-status-mode-map>
\\[ogent-cabinet-status-refresh] refreshes the graph.
\\[ogent-cabinet-status-visit] visits the Org record at point.
\\[ogent-cabinet-status-dispatch] opens the status action menu.
\\[ogent-cabinet-status-help] shows status help.
\\[ogent-cabinet-status-toggle-section] toggles section visibility.
\\[ogent-cabinet-status-open-issues] opens Ogent Issues.
\\[ogent-cabinet-status-open-gastown] opens Gas Town status."
       :group 'ogent-cabinet-status
       (ogent-cabinet-status--mode-setup))))

(ogent-cabinet-status--define-mode)

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
  (let* ((node (ignore-errors (ogent-cabinet-status--node-at-point)))
         (context (when node
                    (format "    %s %s"
                            (symbol-name (plist-get node :kind))
                            (or (plist-get node :label) "")))))
    (concat
     "C-c m menu  C-c ? help  C-c g refresh  RET visit  TAB fold  M-n/p sections  C-c n/p items  q quit"
     (when context
       (propertize context 'face 'ogent-cabinet-status-dimmed))
     (when ogent-cabinet-status--root
       (concat "    "
               (propertize
                (abbreviate-file-name ogent-cabinet-status--root)
                'face 'ogent-cabinet-status-dimmed))))))

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

(defun ogent-cabinet-status--plural (count singular &optional plural)
  "Return COUNT followed by SINGULAR or PLURAL label."
  (format "%d %s" count (if (= count 1) singular (or plural (concat singular "s")))))

(defun ogent-cabinet-status--node-count (kind)
  "Return the number of graph nodes whose kind is KIND."
  (length (ogent-cabinet-status--nodes-by-kind kind)))

(defun ogent-cabinet-status--agent-state (data)
  "Return operational state for agent DATA."
  (cond
   ((ogent-cabinet-runner-running-p (plist-get data :slug)) 'working)
   ((plist-get data :active) 'active)
   (t 'idle)))

(defun ogent-cabinet-status--state-face (state)
  "Return face for operational STATE."
  (if (memq state '(active working ready connected closed merged processing))
      'ogent-cabinet-status-connected
    'ogent-cabinet-status-disconnected))

(defun ogent-cabinet-status--runtime-label (data)
  "Return provider/model label for DATA."
  (ogent-cabinet--blank-to-nil
   (string-join
    (delq nil
          (list (ogent-cabinet--blank-to-nil (plist-get data :provider))
                (ogent-cabinet--blank-to-nil (plist-get data :model))))
    "/")))

(defun ogent-cabinet-status--clock-label (minute hour)
  "Return HH:MM for cron MINUTE and HOUR fields when they are simple."
  (when (and (string-match-p "\\`[0-9]+\\'" minute)
             (string-match-p "\\`[0-9]+\\'" hour))
    (let ((minute-number (string-to-number minute))
          (hour-number (string-to-number hour)))
      (when (and (<= 0 minute-number 59)
                 (<= 0 hour-number 23))
        (format "%02d:%02d" hour-number minute-number)))))

(defun ogent-cabinet-status--weekday-label (day)
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

(defun ogent-cabinet-status--cron-label (cron)
  "Return a readable label for common CRON schedules."
  (let ((fields (split-string cron "[ \t]+" t)))
    (if (/= (length fields) 5)
        (concat "cron " cron)
      (let* ((minute (nth 0 fields))
             (hour (nth 1 fields))
             (day-of-month (nth 2 fields))
             (month (nth 3 fields))
             (day-of-week (nth 4 fields))
             (time (ogent-cabinet-status--clock-label minute hour))
             (weekday (ogent-cabinet-status--weekday-label day-of-week)))
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

(defun ogent-cabinet-status--schedule-label (data)
  "Return a quiet schedule label for job DATA."
  (cond
   ((ogent-cabinet--blank-to-nil (plist-get data :cron))
    (ogent-cabinet-status--cron-label (plist-get data :cron)))
   ((ogent-cabinet--blank-to-nil (plist-get data :run-after))
    (concat "at " (plist-get data :run-after)))
   ((ogent-cabinet--blank-to-nil (plist-get data :heartbeat))
    (concat "heartbeat " (plist-get data :heartbeat)))
   (t "manual")))

(defun ogent-cabinet-status--session-time (node)
  "Return sortable completion time for session NODE."
  (or (plist-get (plist-get node :data) :finished) ""))

(defun ogent-cabinet-status--session-state (status)
  "Return display state for session STATUS."
  (cond
   ((string= status "DONE") 'closed)
   ((string= status "FAILED") 'failed)
   ((string= status "RUNNING") 'processing)
   (t 'waiting)))

(defun ogent-cabinet-status--short-time (timestamp)
  "Return a compact display label for TIMESTAMP."
  (when-let ((value (ogent-cabinet--blank-to-nil timestamp)))
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

(defun ogent-cabinet-status--take-with-rest (items limit)
  "Return plist containing visible ITEMS and hidden count after LIMIT."
  (let* ((limit (max 0 (or limit 0)))
         (visible (seq-take items limit))
         (rest (- (length items) (length visible))))
    (list :visible visible :rest rest)))

(defmacro ogent-cabinet-status--with-section (section heading &rest body)
  "Insert collapsible SECTION with HEADING around BODY when Magit is present."
  (declare (indent 2) (debug t))
  (let ((type (car section)))
    `(if (ogent-cabinet-status--magit-section-usable-p)
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

(defmacro ogent-cabinet-status--with-root-section (section &rest body)
  "Insert root SECTION around BODY when Magit is present."
  (declare (indent 1) (debug t))
  (let ((type (car section)))
    `(if (ogent-cabinet-status--magit-section-usable-p)
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

(defun ogent-cabinet-status--insert-buffer ()
  "Insert the Cabinet status buffer contents."
  (ogent-cabinet-status--with-root-section (ogent-cabinet-status-root)
    (ogent-cabinet-status--insert-buffer-content)))

(defun ogent-cabinet-status--insert-buffer-content ()
  "Insert the Cabinet status content sections."
  (ogent-cabinet-status--insert-summary)
  (insert "\n")
  (ogent-cabinet-status--insert-agents)
  (insert "\n")
  (ogent-cabinet-status--insert-recent-work)
  (insert "\n")
  (ogent-cabinet-status--insert-artifacts)
  (insert "\n")
  (ogent-cabinet-status--insert-bridges))

(defun ogent-cabinet-status--heading-text (icon ascii label &optional count)
  "Return heading text with ICON, ASCII fallback, LABEL, and optional COUNT."
  (propertize
   (ogent-ops-section-heading
    (ogent-ops-section-prefix icon ascii)
    label
    count
    'ogent-cabinet-status-dimmed)
   'face 'ogent-cabinet-status-heading))

(defun ogent-cabinet-status--insert-heading (icon ascii label &optional count)
  "Insert a heading with ICON, ASCII fallback, LABEL, and optional COUNT."
  (insert (ogent-cabinet-status--heading-text icon ascii label count) "\n"))

(defun ogent-cabinet-status--insert-summary ()
  "Insert graph summary section."
  (let* ((cabinet (car (ogent-cabinet-status--nodes-by-kind 'cabinet)))
         (agents (ogent-cabinet-status--node-count 'agent))
         (jobs (ogent-cabinet-status--node-count 'job))
         (sessions (ogent-cabinet-status--node-count 'session))
         (apps (ogent-cabinet-status--node-count 'app))
         (issues (ogent-cabinet-status--node-count 'issue)))
    (ogent-cabinet-status--with-section (ogent-cabinet-status-summary)
        (ogent-cabinet-status--heading-text "◇" "O" "Overview")
      (when cabinet
        (ogent-cabinet-status--insert-node-line
         cabinet
         (format "%s  %s  %s  %s  %s  %s"
                 (propertize (or (plist-get cabinet :label) "Cabinet")
                             'face 'ogent-cabinet-status-label)
                 (ogent-cabinet-status--plural agents "agent")
                 (ogent-cabinet-status--plural jobs "job")
                 (ogent-cabinet-status--plural sessions "run")
                 (ogent-cabinet-status--plural apps "app")
                 (ogent-cabinet-status--plural issues "issue")))))))

(defun ogent-cabinet-status--insert-agents ()
  "Insert agents and their scheduled jobs."
  (let ((agents (ogent-cabinet-status--nodes-by-kind 'agent)))
    (ogent-cabinet-status--with-section (ogent-cabinet-status-agents)
        (ogent-cabinet-status--heading-text "◆" "A" "Agents" (length agents))
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
                   (runtime (or (ogent-cabinet-status--runtime-label data)
                                provider))
                   (status (ogent-cabinet-status--agent-state data)))
              (ogent-cabinet-status--insert-node-line
               agent
               (format "%s %-28s %-9s %-18s %s"
                       (propertize (ogent-ops-activity-symbol status)
                                   'face (ogent-cabinet-status--state-face
                                          status))
                       (propertize (plist-get agent :label)
                                   'face 'ogent-cabinet-status-label)
                       (propertize
                        (symbol-name status)
                        'face 'ogent-cabinet-status-dimmed)
                       (propertize runtime
                                   'face 'ogent-cabinet-status-dimmed)
                       (propertize
                        (ogent-cabinet-status--plural (length jobs) "job")
                        'face 'ogent-cabinet-status-dimmed)))
              (dolist (job jobs)
                (when job
                  (ogent-cabinet-status--insert-node-line
                   job
                   (ogent-cabinet-status--format-job-line job)
                   "    ")))))
        (insert (propertize "  No agents yet\n"
                            'face 'ogent-cabinet-status-dimmed))))))

(defun ogent-cabinet-status--insert-recent-work ()
  "Insert recent session nodes."
  (let* ((sessions (seq-sort-by
                    #'ogent-cabinet-status--session-time
                    #'string>
                    (ogent-cabinet-status--nodes-by-kind 'session)))
         (split (ogent-cabinet-status--take-with-rest
                 sessions
                 ogent-cabinet-status-max-related-items))
         (visible (plist-get split :visible))
         (rest (plist-get split :rest)))
    (ogent-cabinet-status--with-section (ogent-cabinet-status-recent-work)
        (ogent-cabinet-status--heading-text "◇" "W" "Recent Work" (length sessions))
      (if visible
          (progn
            (dolist (node visible)
              (ogent-cabinet-status--insert-node-line
               node
               (ogent-cabinet-status--format-session-line node)))
            (when (> rest 0)
              (insert (propertize
                       (format "  %s more. Press c for the conversation list.\n"
                               rest)
                       'face 'ogent-cabinet-status-dimmed))))
        (insert (propertize "  No completed sessions yet\n"
                            'face 'ogent-cabinet-status-dimmed))))))

(defun ogent-cabinet-status--insert-artifacts ()
  "Insert app and issue nodes."
  (let* ((nodes (seq-filter
                 (lambda (node)
                   (memq (plist-get node :kind) '(app issue)))
                 (plist-get ogent-cabinet-status--graph :nodes)))
         (split (ogent-cabinet-status--take-with-rest
                 nodes
                 ogent-cabinet-status-max-related-items))
         (visible (plist-get split :visible))
         (rest (plist-get split :rest)))
    (ogent-cabinet-status--with-section (ogent-cabinet-status-artifacts)
        (ogent-cabinet-status--heading-text "◇" "F" "Artifacts" (length nodes))
      (if visible
          (progn
            (dolist (node visible)
              (ogent-cabinet-status--insert-node-line
               node
               (ogent-cabinet-status--format-artifact-line node)))
            (when (> rest 0)
              (insert (propertize
                       (format "  %s more. Press A for apps or i for issues.\n"
                               rest)
                       'face 'ogent-cabinet-status-dimmed))))
        (insert (propertize "  No apps or linked issues yet\n"
                            'face 'ogent-cabinet-status-dimmed))))))

(defun ogent-cabinet-status--format-job-line (job)
  "Return display text for JOB."
  (let* ((data (plist-get job :data))
         (enabled (plist-get data :enabled))
         (state (if enabled 'ready 'waiting))
         (label (if enabled "enabled" "paused")))
    (format "%s %-28s %-9s %s"
            (propertize (ogent-ops-status-symbol state)
                        'face (ogent-cabinet-status--state-face state))
            (propertize (plist-get job :label)
                        'face 'ogent-cabinet-status-label)
            (propertize label
                        'face 'ogent-cabinet-status-dimmed)
            (propertize (ogent-cabinet-status--schedule-label data)
                        'face 'ogent-cabinet-status-dimmed))))

(defun ogent-cabinet-status--format-session-line (node)
  "Return display text for session NODE."
  (let* ((data (plist-get node :data))
         (status (format "%s" (or (plist-get data :status) "session")))
         (state (ogent-cabinet-status--session-state status))
         (duration (or (plist-get data :duration) ""))
         (finished (ogent-cabinet-status--short-time
                    (plist-get data :finished))))
    (format "%s %-42s %-9s %s"
            (propertize (ogent-ops-status-symbol state)
                        'face (ogent-cabinet-status--state-face state))
            (propertize (or (plist-get node :label) "")
                        'face 'ogent-cabinet-status-label)
            (propertize (downcase status) 'face 'ogent-cabinet-status-dimmed)
            (propertize
             (string-join (delq nil
                                (list (ogent-cabinet--blank-to-nil duration)
                                      (ogent-cabinet--blank-to-nil finished)))
                          "  ")
             'face 'ogent-cabinet-status-dimmed))))

(defun ogent-cabinet-status--format-artifact-line (node)
  "Return display text for app or issue NODE."
  (let ((kind (symbol-name (plist-get node :kind)))
        (label (or (plist-get node :label) ""))
        (data (plist-get node :data)))
    (format "%s %-9s %s%s"
            (propertize (ogent-ops-status-symbol 'ready)
                        'face 'ogent-cabinet-status-connected)
            (propertize kind 'face 'ogent-cabinet-status-dimmed)
            (propertize label 'face 'ogent-cabinet-status-label)
            (if-let ((agent (plist-get data :agent)))
                (propertize (format "  %s" agent)
                            'face 'ogent-cabinet-status-dimmed)
              ""))))

(defun ogent-cabinet-status--insert-bridges ()
  "Insert operational bridge section."
  (ogent-cabinet-status--with-section (ogent-cabinet-status-bridges)
      (ogent-cabinet-status--heading-text "◈" "B" "Bridges")
    (ogent-cabinet-status--insert-bridge-line
     "Ogent Issues"
     (ogent-cabinet-status--issues-state)
     "i")
    (ogent-cabinet-status--insert-bridge-line
     "Gas Town"
     (ogent-cabinet-status--gastown-state)
     "G")))

(defun ogent-cabinet-status--insert-node-line (node text &optional prefix)
  "Insert TEXT for NODE with optional PREFIX and visit metadata."
  (let ((start (point)))
    (insert (or prefix "  "))
    (insert text)
    (when ogent-cabinet-status-show-node-ids
      (insert "  ")
      (insert (propertize (plist-get node :id)
                          'face 'ogent-cabinet-status-id)))
    (insert "\n")
    (add-text-properties
     start
     (point)
     `(ogent-cabinet-node ,node
                          mouse-face highlight
                          help-echo ,(ogent-cabinet-status--node-help node)))))

(defun ogent-cabinet-status--node-help (node)
  "Return hover help for graph NODE."
  (pcase (plist-get node :kind)
    ('agent "RET visits source, C-c P opens profile, C-c N creates a job, C-c e edits properties, C-c r runs")
    ('job "RET visits source, C-c r runs job, C-c e edits metadata, C-c E edits prompt/body")
    ('session "RET visits transcript, C-c r retries linked work, C-c e edits archive/tags")
    ('app "RET visits source, C-c E visits source body")
    (_ "RET visits this Org record")))

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
    (insert (propertize (format "  %s" key)
                        'face 'ogent-cabinet-status-dimmed))
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

(defun ogent-cabinet-status--visible-node-position (direction)
  "Return the next visible node position in DIRECTION.
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
                (next-single-property-change
                 pos
                 'ogent-cabinet-node
                 nil
                 limit)
              (previous-single-property-change
               pos
               'ogent-cabinet-node
               nil
               limit)))
      (when pos
        (when (eq direction 'previous)
          (setq pos (max (point-min) (1- pos))))
        (if (and (get-text-property pos 'ogent-cabinet-node)
                 (not (invisible-p pos)))
            (setq found pos)
          (setq pos (if (eq direction 'next)
                        (min (point-max) (1+ pos))
                      (max (point-min) (1- pos)))))))
    found))

(defun ogent-cabinet-status--require-node ()
  "Return the graph node at point or signal a Cabinet status error."
  (or (ogent-cabinet-status--node-at-point)
      (user-error "No Cabinet record at point")))

(defun ogent-cabinet-status--node-agent (node)
  "Return the agent slug associated with NODE."
  (let ((data (plist-get node :data)))
    (pcase (plist-get node :kind)
      ('agent (plist-get data :slug))
      ((or 'job 'session 'app) (plist-get data :agent))
      (_ nil))))

(defun ogent-cabinet-status--node-job-id (node)
  "Return the job id associated with NODE."
  (let ((data (plist-get node :data)))
    (pcase (plist-get node :kind)
      ('job (plist-get data :id))
      ((or 'session 'app) (plist-get data :job-id))
      (_ nil))))

(defun ogent-cabinet-status--job-with-property (job property value)
  "Return JOB copied with Org PROPERTY set to VALUE."
  (let* ((copy (copy-sequence job))
         (key (cdr (assoc property
                          ogent-cabinet-status-job-property-keys))))
    (unless key
      (user-error "Unsupported Cabinet job property: %s" property))
    (pcase property
      ("OGENT_TAGS"
       (plist-put copy key (ogent-cabinet--tags-from-string value)))
      ("OGENT_ENABLED"
       (plist-put copy :enabled-raw value)
       (plist-put copy :enabled (ogent-cabinet--truth-value value)))
      ("OGENT_ARCHIVED"
       (plist-put copy :archived-raw value)
       (plist-put copy :archived (ogent-cabinet--truth-value value)))
      (_
       (plist-put copy key value)))
    copy))

(defun ogent-cabinet-status--read-current-property (file property)
  "Return PROPERTY from the first Org heading in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (ogent-cabinet--org-mode)
    (ogent-cabinet--first-heading-title)
    (org-entry-get nil property)))

(defun ogent-cabinet-status--visit-body (file)
  "Visit FILE and move to the first body line."
  (find-file file)
  (org-mode)
  (goto-char (point-min))
  (unless (re-search-forward org-heading-regexp nil t)
    (user-error "No Org heading found in %s" file))
  (org-back-to-heading t)
  (org-end-of-meta-data t)
  (skip-chars-forward " \t\n"))

(defun ogent-cabinet-status-visit ()
  "Visit the Org record at point."
  (interactive)
  (let* ((node (ogent-cabinet-status--require-node))
         (kind (plist-get node :kind))
         (path (plist-get node :path)))
    (unless (and path (file-exists-p path))
      (user-error "No Cabinet record at point"))
    (if (eq kind 'session)
        (let ((display-buffer-overriding-action
               '((display-buffer-same-window))))
          (ogent-cabinet-conversation ogent-cabinet-status--root path))
      (find-file path))))

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
  (let* ((node (ogent-cabinet-status--require-node))
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
      ('session
       (if-let ((job-id (plist-get data :job-id)))
           (ogent-cabinet-run-job
            ogent-cabinet-status--root
            (plist-get data :agent)
            job-id)
         (ogent-cabinet-run-agent
          ogent-cabinet-status--root
          (plist-get data :agent)
          (read-string "Instruction: "))))
      (_
       (user-error "No runnable Cabinet agent or job at point")))))

(defun ogent-cabinet-status-edit ()
  "Edit metadata for the Cabinet agent, job, or session at point."
  (interactive)
  (let* ((node (ogent-cabinet-status--require-node))
         (kind (plist-get node :kind))
         (data (plist-get node :data))
         (path (plist-get node :path)))
    (pcase kind
      ('agent
       (let* ((slug (plist-get data :slug))
              (property (completing-read
                         "Agent property: "
                         ogent-cabinet-status-agent-editable-properties
                         nil t))
              (current (ogent-cabinet-status--read-current-property
                        (ogent-cabinet-agent-file ogent-cabinet-status--root
                                                  slug)
                        property))
              (value (read-string (format "%s: " property) current)))
         (ogent-cabinet-update-agent-property
          ogent-cabinet-status--root slug property value)))
      ('job
       (let* ((agent (plist-get data :agent))
              (job-id (plist-get data :id))
              (property (completing-read
                         "Job property: "
                         ogent-cabinet-status-job-editable-properties
                         nil t))
              (current (ogent-cabinet-status--read-current-property
                        (ogent-cabinet-job-file ogent-cabinet-status--root
                                                agent
                                                job-id)
                        property))
              (value (read-string (format "%s: " property) current))
              (candidate (ogent-cabinet-status--job-with-property
                          data property value)))
         (ogent-cabinet-validate-job candidate)
         (ogent-cabinet-update-job-property
          ogent-cabinet-status--root agent job-id property value)))
      ('session
       (let* ((property (completing-read
                         "Session property: "
                         '("OGENT_ARCHIVED" "OGENT_TAGS")
                         nil t))
              (current (ogent-cabinet-status--read-current-property
                        path property))
              (value (read-string (format "%s: " property) current)))
         (ogent-cabinet-update-session-property path property value)))
      (_
       (user-error "No editable Cabinet record at point"))))
  (ogent-cabinet-status-refresh))

(defun ogent-cabinet-status-edit-body ()
  "Visit the selected Cabinet Org body or prompt."
  (interactive)
  (let* ((node (ogent-cabinet-status--require-node))
         (path (plist-get node :path)))
    (unless (and path (file-exists-p path))
      (user-error "No Cabinet file at point"))
    (ogent-cabinet-status--visit-body path)))

(defun ogent-cabinet-status-open-agent-profile ()
  "Open the agent profile associated with the current Cabinet node."
  (interactive)
  (let* ((node (ogent-cabinet-status--require-node))
         (slug (ogent-cabinet-status--node-agent node)))
    (unless slug
      (user-error "No Cabinet agent at point"))
    (ogent-cabinet-agent ogent-cabinet-status--root slug)))

(defun ogent-cabinet-status-open-agent-jobs ()
  "Open the jobs surface for the agent associated with the current node."
  (interactive)
  (let* ((node (ogent-cabinet-status--require-node))
         (slug (ogent-cabinet-status--node-agent node))
         (job-id (ogent-cabinet-status--node-job-id node)))
    (unless slug
      (user-error "No Cabinet agent at point"))
    (let ((buffer (ogent-cabinet-jobs ogent-cabinet-status--root slug)))
      (when (and job-id (fboundp 'ogent-cabinet-jobs--goto))
        (with-current-buffer buffer
          (ogent-cabinet-jobs--goto slug job-id)))
      buffer)))

(defun ogent-cabinet-status-create-job ()
  "Create a Cabinet job for the agent associated with the current node."
  (interactive)
  (let* ((node (ogent-cabinet-status--require-node))
         (slug (ogent-cabinet-status--node-agent node)))
    (unless slug
      (user-error "No Cabinet agent at point"))
    (ogent-cabinet-create-job ogent-cabinet-status--root slug)))

(defun ogent-cabinet-status-help ()
  "Show Cabinet status keybindings and node actions."
  (interactive)
  (with-help-window "*Ogent Cabinet Status Help*"
    (princ "Cabinet Status\n")
    (princ "==============\n\n")
    (princ "Rows stay quiet by default. Use C-c m for actions on the item at point.\n")
    (princ "Use Vim motions in Evil, C-c n/C-c p for actionable rows, and RET for the durable Org source.\n\n")
    (princ "Node actions\n")
    (princ "------------\n")
    (princ "Agent:   C-c P opens profile, C-c e edits identity properties, C-c N creates a job, C-c r runs with a prompt.\n")
    (princ "Job:     C-c r runs the job, C-c e edits metadata, C-c E edits the prompt/body, C-c J opens the job list.\n")
    (princ "Session: C-c r retries linked work, C-c e edits archive/tags, RET visits the transcript.\n")
    (princ "App:     RET visits the source record when available.\n\n")
    (princ "Surfaces\n")
    (princ "--------\n")
    (princ "C-c h Home, C-c a Agents, C-c t Tasks, C-c c Conversations, C-c s Search, C-c A Apps, C-c i Issues, C-c G Gas Town.\n\n")
    (princ "Menus\n")
    (princ "-----\n")
    (princ "C-c m opens the Transient menu. C-c ? opens this help buffer. C-c g refreshes. q quits.\n")
    (princ "TAB toggles a section. M-n/M-p move between sibling sections. C-c u moves to the parent section.\n")
    (princ "Set `ogent-cabinet-status-show-node-ids' to show graph ids inline.\n")
    (princ "Evil normal and motion states keep bare Vim navigation and expose Cabinet actions through these chords.\n")))

(defun ogent-cabinet-status-toggle-section ()
  "Toggle the current Cabinet status section."
  (interactive)
  (if (ogent-cabinet-status--magit-section-usable-p)
      (if-let ((section (magit-current-section)))
          (condition-case err
              (magit-section-toggle section)
            (user-error (message "%s" (error-message-string err))))
        (message "No section at point"))
    (message "Section toggling requires magit-section")))

(defun ogent-cabinet-status-cycle-sections ()
  "Cycle visibility for all Cabinet status sections."
  (interactive)
  (if (and (ogent-cabinet-status--magit-section-usable-p)
           (fboundp 'magit-section-cycle-global))
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-cabinet-status-next-section ()
  "Move to the next sibling Cabinet status section."
  (interactive)
  (when (ogent-cabinet-status--magit-section-usable-p)
    (magit-section-forward-sibling)))

(defun ogent-cabinet-status-previous-section ()
  "Move to the previous sibling Cabinet status section."
  (interactive)
  (when (ogent-cabinet-status--magit-section-usable-p)
    (magit-section-backward-sibling)))

(defun ogent-cabinet-status-up-section ()
  "Move to the parent Cabinet status section."
  (interactive)
  (when (and (ogent-cabinet-status--magit-section-usable-p)
             (fboundp 'magit-section-up))
    (magit-section-up)))

(defun ogent-cabinet-status-next-item ()
  "Move point to the next Cabinet record line."
  (interactive)
  (let ((next (ogent-cabinet-status--visible-node-position 'next)))
    (when next
      (goto-char next))))

(defun ogent-cabinet-status-previous-item ()
  "Move point to the previous Cabinet record line."
  (interactive)
  (let ((previous (ogent-cabinet-status--visible-node-position 'previous)))
    (when previous
      (goto-char previous))))

(defun ogent-cabinet-status--transient-header ()
  "Return the header text for `ogent-cabinet-status-dispatch'."
  (let* ((root (and (boundp 'ogent-cabinet-status--root)
                    ogent-cabinet-status--root))
         (node (ignore-errors (ogent-cabinet-status--node-at-point)))
         (kind (and node (plist-get node :kind)))
         (label (and node (plist-get node :label))))
    (concat
     (propertize "Cabinet Status" 'face 'transient-heading)
     (if root
         (concat "  " (propertize (abbreviate-file-name root) 'face 'shadow))
       "")
     (if node
         (format "  %s %s"
                 (propertize (symbol-name kind) 'face 'transient-heading)
                 (propertize (or label "") 'face 'shadow))
       ""))))

;;;###autoload (autoload 'ogent-cabinet-status-dispatch "ogent-cabinet-status" nil t)
(transient-define-prefix ogent-cabinet-status-dispatch ()
  "Dispatch menu for Cabinet status buffers."
  [:description ogent-cabinet-status--transient-header
   ["Run"
    ("R" "Run/retry selected" ogent-cabinet-status-run)
    ("C" "Create job for agent" ogent-cabinet-status-create-job)]
   ["Edit"
    ("e" "Edit metadata" ogent-cabinet-status-edit)
    ("E" "Edit body/prompt" ogent-cabinet-status-edit-body)
    ("P" "Agent profile" ogent-cabinet-status-open-agent-profile)
    ("J" "Agent jobs" ogent-cabinet-status-open-agent-jobs)]
   ["Navigate"
    ("RET" "Visit Org source" ogent-cabinet-status-visit)
    ("TAB" "Toggle section" ogent-cabinet-status-toggle-section :transient t)
    ("M-n" "Next section" ogent-cabinet-status-next-section :transient t)
    ("M-p" "Previous section" ogent-cabinet-status-previous-section :transient t)
    ("^" "Up section" ogent-cabinet-status-up-section :transient t)
    ("n" "Next item" ogent-cabinet-status-next-item :transient t)
    ("p" "Previous item" ogent-cabinet-status-previous-item :transient t)
    ("g" "Refresh" ogent-cabinet-status-refresh :transient t)]]
  [["Surfaces"
    ("h" "Home" ogent-cabinet-home)
    ("a" "Agents" ogent-cabinet-agents)
    ("t" "Tasks" ogent-cabinet-tasks)
    ("c" "Conversations" ogent-cabinet-conversations)
    ("s" "Search" ogent-cabinet-search)
    ("A" "Apps" ogent-cabinet-apps)]
   ["Bridges"
    ("i" "Ogent Issues" ogent-cabinet-status-open-issues)
    ("G" "Gas Town" ogent-cabinet-status-open-gastown)]
   ["Help"
    ("?" "Help" ogent-cabinet-status-help)
    ("q" "Quit menu" transient-quit-one)]])

(defun ogent-cabinet-status--evil-local-keys ()
  "Install local Evil keys for Cabinet status."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-status-mode-map))

(defun ogent-cabinet-status--setup-evil ()
  "Set up Evil integration for Cabinet status buffers."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-status-mode
   ogent-cabinet-status-mode-map
   'ogent-cabinet-status-mode-hook
   #'ogent-cabinet-status--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-cabinet-status--setup-evil))

(provide 'ogent-cabinet-status)

;;; ogent-cabinet-status.el ends here
