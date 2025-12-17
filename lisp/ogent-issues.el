;;; ogent-issues.el --- Magit-style beads issue viewer -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-section based buffer for viewing and managing beads issues.
;; Designed to feel native to magit users with familiar keybindings and visual style.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;; Soft dependency on magit-section - provide fallback if not available
(defvar ogent-issues--magit-section-available
  (require 'magit-section nil t)
  "Non-nil if magit-section is available.")

(when ogent-issues--magit-section-available
  (require 'magit-section))

(require 'ogent-issues-bd)

;; Load transient menu if available
(declare-function ogent-issues-dispatch "ogent-issues-transient" nil t)
(autoload 'ogent-issues-dispatch "ogent-issues-transient" nil t)
(autoload 'ogent-issues-create-dispatch "ogent-issues-transient" nil t)

;;; Customization

(defgroup ogent-issues nil
  "Magit-style beads issue viewer."
  :group 'ogent
  :prefix "ogent-issues-")

(defcustom ogent-issues-buffer-name "*ogent-issues*"
  "Name of the ogent-issues buffer."
  :type 'string
  :group 'ogent-issues)

(defcustom ogent-issues-default-view 'list
  "Default view when opening ogent-issues.
Options: `list', `ready', `kanban'."
  :type '(choice (const :tag "List view" list)
                 (const :tag "Ready work" ready)
                 (const :tag "Kanban board" kanban))
  :group 'ogent-issues)

(defcustom ogent-issues-collapsed-statuses '("closed")
  "List of statuses that should be collapsed by default."
  :type '(repeat string)
  :group 'ogent-issues)

(defcustom ogent-issues-use-unicode t
  "Whether to use Unicode characters for icons.
Set to nil for ASCII-only terminals."
  :type 'boolean
  :group 'ogent-issues)

(defcustom ogent-issues-show-counts t
  "Whether to show issue counts in section headings."
  :type 'boolean
  :group 'ogent-issues)

;;; Faces - Following magit conventions

(defgroup ogent-issues-faces nil
  "Faces for ogent-issues."
  :group 'ogent-issues
  :group 'faces)

;; Section headings - like magit-section-heading
(defface ogent-issues-section-heading
  '((((class color) (background light)) :foreground "DarkGoldenrod4" :weight bold)
    (((class color) (background dark)) :foreground "LightGoldenrod2" :weight bold))
  "Face for section headings."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading-selection
  '((((class color) (background light)) :foreground "salmon4" :weight bold)
    (((class color) (background dark)) :foreground "LightSalmon3" :weight bold))
  "Face for selected section headings."
  :group 'ogent-issues-faces)

;; Issue ID - like magit-hash
(defface ogent-issues-id
  '((((class color) (background light)) :foreground "grey40")
    (((class color) (background dark)) :foreground "grey60"))
  "Face for issue IDs."
  :group 'ogent-issues-faces)

;; Priority faces - traffic light colors
(defface ogent-issues-priority-critical
  '((t :foreground "#ff5555" :weight bold))
  "Face for P0 (critical) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-high
  '((t :foreground "#ffb86c" :weight bold))
  "Face for P1 (high) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-medium
  '((t :foreground "#f1fa8c"))
  "Face for P2 (medium) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-low
  '((t :foreground "#50fa7b"))
  "Face for P3 (low) issues."
  :group 'ogent-issues-faces)

;; Status faces
(defface ogent-issues-status-open
  '((((class color) (background light)) :foreground "ForestGreen")
    (((class color) (background dark)) :foreground "#8be9fd"))
  "Face for open issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-in-progress
  '((((class color) (background light)) :foreground "DarkOrange")
    (((class color) (background dark)) :foreground "#bd93f9"))
  "Face for in-progress issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-blocked
  '((t :foreground "#ff5555" :slant italic))
  "Face for blocked issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-closed
  '((((class color) (background light)) :foreground "grey50")
    (((class color) (background dark)) :foreground "#6272a4"))
  "Face for closed issues."
  :group 'ogent-issues-faces)

;; Ready indicator
(defface ogent-issues-ready
  '((t :foreground "#f1fa8c" :weight bold))
  "Face for ready issue indicator."
  :group 'ogent-issues-faces)

;; Dimmed text - like magit-dimmed
(defface ogent-issues-dimmed
  '((((class color) (background light)) :foreground "grey50")
    (((class color) (background dark)) :foreground "grey50"))
  "Face for less important text."
  :group 'ogent-issues-faces)

;; Type badge
(defface ogent-issues-type
  '((((class color) (background light)) :foreground "grey30" :box (:line-width -1 :color "grey70"))
    (((class color) (background dark)) :foreground "grey70" :box (:line-width -1 :color "grey40")))
  "Face for issue type badges."
  :group 'ogent-issues-faces)

;; Header line
(defface ogent-issues-header-line
  '((t :inherit header-line :weight bold))
  "Face for the header line."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line-key
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for keybindings in header line."
  :group 'ogent-issues-faces)

;;; Type Icons

(defcustom ogent-issues-type-icons
  '(("bug" . ("🐛" . "B"))
    ("feature" . ("✨" . "F"))
    ("task" . ("📋" . "T"))
    ("epic" . ("🎯" . "E"))
    ("chore" . ("🔧" . "C")))
  "Icons for issue types.
Each entry is (TYPE . (UNICODE . ASCII))."
  :type '(alist :key-type string
                :value-type (cons string string))
  :group 'ogent-issues)

;;; Buffer-local State

(defvar-local ogent-issues--current-view 'list
  "Current view mode: `list', `ready', or `kanban'.")

(defvar-local ogent-issues--filters nil
  "Current active filters as plist (:status :type :priority :assignee).")

(defvar-local ogent-issues--issues nil
  "Cached list of issues for the current buffer.")

(defvar-local ogent-issues--last-position nil
  "Last cursor position for restoration after refresh.")

;;; Section Classes (when magit-section available)

(when ogent-issues--magit-section-available
  (defclass ogent-issues-root-section (magit-section) ()
    "Root section for ogent-issues buffer.")

  (defclass ogent-issues-status-section (magit-section)
    ((status :initarg :status))
    "Section for a status group (open, in_progress, etc.).")

  (defclass ogent-issues-issue-section (magit-section)
    ((issue :initarg :issue))
    "Section for a single issue."))

;;; Keymap - Following magit conventions

(defvar ogent-issues-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Inherit from magit-section if available
    (when (and ogent-issues--magit-section-available
               (boundp 'magit-section-mode-map))
      (set-keymap-parent map magit-section-mode-map))
    
    ;; Navigation (magit-style)
    (define-key map "n" #'ogent-issues-next-issue)
    (define-key map "p" #'ogent-issues-prev-issue)
    (define-key map "j" #'ogent-issues-next-issue)
    (define-key map "k" #'ogent-issues-prev-issue)
    (define-key map (kbd "M-n") #'ogent-issues-next-section)
    (define-key map (kbd "M-p") #'ogent-issues-prev-section)
    (define-key map (kbd "RET") #'ogent-issues-visit)
    (define-key map (kbd "TAB") #'ogent-issues-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-issues-cycle-sections)
    (define-key map (kbd "^") #'ogent-issues-up-section)
    
    ;; Refresh (magit-style: g)
    (define-key map "g" #'ogent-issues-refresh)
    (define-key map "G" #'ogent-issues-refresh-force)
    
    ;; Actions - single keys for common ops
    (define-key map "c" #'ogent-issues-create)
    (define-key map "s" #'ogent-issues-start)
    (define-key map "k" #'ogent-issues-close)  ; like magit kill
    (define-key map "K" #'ogent-issues-close)
    (define-key map "x" #'ogent-issues-close)  ; alternative
    (define-key map "r" #'ogent-issues-reopen)
    (define-key map "C" #'ogent-issues-comment)
    
    ;; Help/dispatch (magit-style: ?)
    (define-key map "?" #'ogent-issues-dispatch)
    (define-key map "h" #'ogent-issues-dispatch)
    
    ;; Filters (f prefix like magit fetch)
    (define-key map "f" nil)  ; prefix
    (define-key map "fs" #'ogent-issues-filter-status)
    (define-key map "ft" #'ogent-issues-filter-type)
    (define-key map "fp" #'ogent-issues-filter-priority)
    (define-key map "ff" #'ogent-issues-filter-dispatch)
    (define-key map "fc" #'ogent-issues-clear-filters)
    
    ;; Views (v prefix)
    (define-key map "v" nil)  ; prefix
    (define-key map "vl" #'ogent-issues-view-list)
    (define-key map "vr" #'ogent-issues-view-ready)
    (define-key map "vk" #'ogent-issues-view-kanban)
    (define-key map "vd" #'ogent-issues-view-deps)
    
    ;; Kanban-specific (work in all views, but most useful in Kanban)
    (define-key map "H" #'ogent-issues-kanban-move-left)
    (define-key map "L" #'ogent-issues-kanban-move-right)
    
    ;; Sync (like magit push/pull)
    (define-key map "S" #'ogent-issues-sync)
    
    ;; Quit
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-issues-mode'.")

;;; Mode Definition

(define-derived-mode ogent-issues-mode special-mode "Issues"
  "Major mode for viewing and managing beads issues.

Like magit-status but for your issue tracker.

\\<ogent-issues-mode-map>
Navigation:
  \\[ogent-issues-next-issue]     Move to next issue
  \\[ogent-issues-prev-issue]     Move to previous issue
  \\[ogent-issues-visit]   Visit issue details
  \\[ogent-issues-toggle-section]   Toggle section visibility

Actions:
  \\[ogent-issues-create]     Create new issue
  \\[ogent-issues-start]     Start working on issue
  \\[ogent-issues-close]     Close issue
  \\[ogent-issues-comment]     Add comment

Filters:
  \\[ogent-issues-filter-status]    Filter by status
  \\[ogent-issues-filter-type]    Filter by type
  \\[ogent-issues-filter-priority]    Filter by priority
  \\[ogent-issues-clear-filters]    Clear all filters

Views:
  \\[ogent-issues-view-list]    List view
  \\[ogent-issues-view-ready]    Ready work
  \\[ogent-issues-view-kanban]    Kanban board

Other:
  \\[ogent-issues-refresh]     Refresh
  \\[ogent-issues-sync]     Sync to git
  \\[ogent-issues-dispatch]     Show all commands

\\{ogent-issues-mode-map}"
  :group 'ogent-issues
  (setq-local revert-buffer-function #'ogent-issues-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq header-line-format '(:eval (ogent-issues--header-line)))
  ;; Enable magit-section features if available
  (when ogent-issues--magit-section-available
    (setq-local magit-section-visibility-indicator
                (if ogent-issues-use-unicode '("…" . t) '("..." . t)))
    (magit-section-mode)))

;;; Entry Point

;;;###autoload
(defun ogent-issues ()
  "Open the ogent-issues buffer."
  (interactive)
  (let ((buf (get-buffer-create ogent-issues-buffer-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'ogent-issues-mode)
        (ogent-issues-mode))
      (ogent-issues-refresh))
    (pop-to-buffer buf)))

;;; Header Line

(defun ogent-issues--header-line ()
  "Generate header line for ogent-issues buffer."
  (let* ((project (or (ogent-issues-bd-project-name) "unknown"))
         (view (symbol-name ogent-issues--current-view))
         (count (length ogent-issues--issues))
         (filters (ogent-issues--format-filters)))
    (concat
     " "
     (propertize "Issues" 'face 'ogent-issues-header-line)
     "  "
     (propertize project 'face 'font-lock-constant-face)
     "  "
     (propertize (format "[%s]" (capitalize view)) 'face 'font-lock-type-face)
     (propertize (format " %d" count) 'face 'ogent-issues-dimmed)
     (when filters
       (concat "  " (propertize "filtered:" 'face 'ogent-issues-dimmed) " " filters))
     "  "
     (propertize "?" 'face 'ogent-issues-header-line-key)
     (propertize ":help" 'face 'ogent-issues-dimmed))))

(defun ogent-issues--format-filters ()
  "Format current filters for display."
  (let ((parts nil))
    (when-let ((status (plist-get ogent-issues--filters :status)))
      (push (propertize status 'face 'font-lock-keyword-face) parts))
    (when-let ((type (plist-get ogent-issues--filters :type)))
      (push (propertize type 'face 'font-lock-type-face) parts))
    (when-let ((priority (plist-get ogent-issues--filters :priority)))
      (push (propertize (format "P%d" priority) 'face (ogent-issues--priority-face priority)) parts))
    (when parts
      (string-join (nreverse parts) " "))))

;;; Formatting Utilities

(defun ogent-issues--type-icon (type)
  "Return icon for issue TYPE."
  (let ((entry (cdr (assoc type ogent-issues-type-icons))))
    (if ogent-issues-use-unicode
        (or (car entry) "•")
      (or (cdr entry) "?"))))

(defun ogent-issues--priority-face (priority)
  "Return face for PRIORITY level."
  (pcase (or priority 2)
    (0 'ogent-issues-priority-critical)
    (1 'ogent-issues-priority-high)
    (2 'ogent-issues-priority-medium)
    (_ 'ogent-issues-priority-low)))

(defun ogent-issues--priority-indicator (priority)
  "Return formatted priority indicator for PRIORITY."
  (let ((p (or priority 2)))
    (propertize
     (if ogent-issues-use-unicode
         (pcase p
           (0 "●")
           (1 "◐")
           (2 "○")
           (_ "◌"))
       (format "P%d" p))
     'face (ogent-issues--priority-face p))))

(defun ogent-issues--status-face (status)
  "Return face for STATUS."
  (pcase status
    ("open" 'ogent-issues-status-open)
    ("in_progress" 'ogent-issues-status-in-progress)
    ("blocked" 'ogent-issues-status-blocked)
    ("closed" 'ogent-issues-status-closed)
    (_ 'default)))

(defun ogent-issues--status-label (status)
  "Return human-readable label for STATUS."
  (pcase status
    ("open" "Open")
    ("in_progress" "In Progress")
    ("blocked" "Blocked")
    ("closed" "Closed")
    (_ (capitalize (or status "unknown")))))

(defun ogent-issues--status-icon (status)
  "Return icon for STATUS."
  (if ogent-issues-use-unicode
      (pcase status
        ("open" "○")
        ("in_progress" "◐")
        ("blocked" "✗")
        ("closed" "●")
        (_ "?"))
    (pcase status
      ("open" "o")
      ("in_progress" ">")
      ("blocked" "x")
      ("closed" "*")
      (_ "?"))))

(defun ogent-issues--ready-indicator ()
  "Return the ready indicator string."
  (propertize (if ogent-issues-use-unicode "⚡" "!")
              'face 'ogent-issues-ready))

(defun ogent-issues--issue-ready-p (issue)
  "Return non-nil if ISSUE is ready (unblocked and actionable).
An issue is ready if it's open, not blocked, and has no blockers."
  (let ((status (plist-get issue :status))
        (blocked-by (plist-get issue :blocked_by)))
    (and (string= status "open")
         (or (null blocked-by)
             (= (length blocked-by) 0)))))

(defun ogent-issues--format-issue-line (issue)
  "Format ISSUE as a single line for the list view."
  (let* ((id (plist-get issue :id))
         (title (plist-get issue :title))
         (priority (plist-get issue :priority))
         (type (plist-get issue :issue_type))
         (status (plist-get issue :status))
         (deps (or (plist-get issue :dependency_count) 0))
         (ready (ogent-issues--issue-ready-p issue))
         ;; Calculate available width for title
         (id-width 12)
         (meta-width 15)
         (available-width (max 20 (- (window-width) id-width meta-width 10)))
         (truncated-title (truncate-string-to-width (or title "") available-width nil nil "…")))
    (concat
     ;; Ready indicator or space
     (if ready (ogent-issues--ready-indicator) " ")
     " "
     ;; Issue ID (fixed width, dimmed)
     (propertize (truncate-string-to-width (or id "???") id-width nil ?\s)
                 'face 'ogent-issues-id)
     " "
     ;; Priority indicator
     (ogent-issues--priority-indicator priority)
     " "
     ;; Type icon
     (ogent-issues--type-icon type)
     " "
     ;; Title with status-based face
     (propertize truncated-title 'face (ogent-issues--status-face status))
     ;; Dependencies count (if any)
     (when (and deps (> deps 0))
       (propertize (format " (%d)" deps) 'face 'ogent-issues-dimmed)))))

;;; Section Insertion

(defun ogent-issues--insert-buffer-contents (issues)
  "Insert ISSUES into the current buffer."
  (if (null issues)
      (ogent-issues--insert-empty-state)
    (if ogent-issues--magit-section-available
        (ogent-issues--insert-with-magit-section issues)
      (ogent-issues--insert-plain issues))))

(defun ogent-issues--insert-empty-state ()
  "Insert empty state message when no issues match."
  (insert "\n")
  (if ogent-issues--filters
      (progn
        (insert (propertize "  No issues match current filters\n\n"
                            'face 'font-lock-warning-face))
        (insert "  Active filters: " (or (ogent-issues--format-filters) "none") "\n\n")
        (insert (propertize "  fc " 'face 'ogent-issues-header-line-key))
        (insert (propertize "clear filters  " 'face 'ogent-issues-dimmed))
        (insert (propertize "ff " 'face 'ogent-issues-header-line-key))
        (insert (propertize "change filters\n" 'face 'ogent-issues-dimmed)))
    (insert (propertize "  No issues found\n\n" 'face 'ogent-issues-dimmed))
    (insert (propertize "  c " 'face 'ogent-issues-header-line-key))
    (insert (propertize "create new issue\n" 'face 'ogent-issues-dimmed))))

(defun ogent-issues--insert-with-magit-section (issues)
  "Insert ISSUES using magit-section."
  (magit-insert-section (ogent-issues-root-section)
    (ogent-issues--insert-header-section)
    (insert "\n")
    (let ((grouped (ogent-issues--group-by-status issues)))
      (dolist (status '("in_progress" "open" "blocked" "closed"))
        (when-let ((group (alist-get status grouped nil nil #'string=)))
          (ogent-issues--insert-status-section status group))))))

(defun ogent-issues--insert-plain (issues)
  "Insert ISSUES without magit-section (fallback)."
  (ogent-issues--insert-header-section)
  (insert "\n")
  (let ((grouped (ogent-issues--group-by-status issues)))
    (dolist (status '("in_progress" "open" "blocked" "closed"))
      (when-let ((group (alist-get status grouped nil nil #'string=)))
        (insert (propertize
                 (format "%s %s (%d)\n"
                         (ogent-issues--status-icon status)
                         (ogent-issues--status-label status)
                         (length group))
                 'face 'ogent-issues-section-heading))
        (dolist (issue group)
          (insert (ogent-issues--format-issue-line issue) "\n")
          (put-text-property (line-beginning-position 0)
                             (line-end-position 0)
                             'ogent-issue issue))
        (insert "\n")))))

(defun ogent-issues--insert-header-section ()
  "Insert buffer header with quick help."
  (let ((view-name (pcase ogent-issues--current-view
                     ('list "Issues")
                     ('ready "Ready Work")
                     ('kanban "Kanban")
                     (_ "Issues"))))
    (insert (propertize view-name 'face 'ogent-issues-section-heading))
    (insert "\n")))

(defun ogent-issues--insert-status-section (status issues)
  "Insert a section for STATUS containing ISSUES."
  (let ((collapsed (member status ogent-issues-collapsed-statuses))
        (icon (ogent-issues--status-icon status))
        (label (ogent-issues--status-label status))
        (count (length issues)))
    (magit-insert-section (ogent-issues-status-section status collapsed)
      (magit-insert-heading
        (concat
         (propertize icon 'face (ogent-issues--status-face status))
         " "
         (propertize label 'face 'ogent-issues-section-heading)
         (when ogent-issues-show-counts
           (propertize (format " (%d)" count) 'face 'ogent-issues-dimmed))))
      (dolist (issue issues)
        (ogent-issues--insert-issue issue))
      (insert "\n"))))

(defun ogent-issues--insert-issue (issue)
  "Insert a single ISSUE as a section."
  (if ogent-issues--magit-section-available
      (magit-insert-section (ogent-issues-issue-section issue)
        (insert (ogent-issues--format-issue-line issue) "\n"))
    (insert (ogent-issues--format-issue-line issue) "\n")
    (put-text-property (line-beginning-position 0)
                       (line-end-position 0)
                       'ogent-issue issue)))

(defun ogent-issues--group-by-status (issues)
  "Group ISSUES by status, returning an alist."
  (seq-group-by (lambda (i) (plist-get i :status)) issues))

;;; Navigation

(defun ogent-issues--current-issue ()
  "Return the issue at point, or nil."
  (if ogent-issues--magit-section-available
      (when-let ((section (magit-current-section)))
        (when (cl-typep section 'ogent-issues-issue-section)
          (oref section issue)))
    (get-text-property (point) 'ogent-issue)))

(defun ogent-issues--current-issue-id ()
  "Return the ID of the issue at point, or nil."
  (when-let ((issue (ogent-issues--current-issue)))
    (plist-get issue :id)))

(defun ogent-issues-next-issue ()
  "Move to the next issue."
  (interactive)
  (if ogent-issues--magit-section-available
      (progn
        (magit-section-forward)
        ;; Skip non-issue sections
        (while (and (not (eobp))
                    (not (ogent-issues--current-issue)))
          (magit-section-forward)))
    ;; Fallback: search for next issue property
    (let ((pos (next-single-property-change (point) 'ogent-issue)))
      (when pos
        (goto-char pos)))))

(defun ogent-issues-prev-issue ()
  "Move to the previous issue."
  (interactive)
  (if ogent-issues--magit-section-available
      (progn
        (magit-section-backward)
        ;; Skip non-issue sections
        (while (and (not (bobp))
                    (not (ogent-issues--current-issue)))
          (magit-section-backward)))
    ;; Fallback: search for previous issue property
    (let ((pos (previous-single-property-change (point) 'ogent-issue)))
      (when pos
        (goto-char pos)))))

(defun ogent-issues-next-section ()
  "Move to the next status section."
  (interactive)
  (when ogent-issues--magit-section-available
    (magit-section-forward-sibling)))

(defun ogent-issues-prev-section ()
  "Move to the previous status section."
  (interactive)
  (when ogent-issues--magit-section-available
    (magit-section-backward-sibling)))

(defun ogent-issues-up-section ()
  "Move to the parent section."
  (interactive)
  (when ogent-issues--magit-section-available
    (magit-section-up)))

(defun ogent-issues-toggle-section ()
  "Toggle the current section."
  (interactive)
  (if ogent-issues--magit-section-available
      (magit-section-toggle (magit-current-section))
    (message "Section toggling requires magit-section")))

(defun ogent-issues-cycle-sections ()
  "Cycle visibility of all sections."
  (interactive)
  (if ogent-issues--magit-section-available
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-issues-visit ()
  "Visit the issue at point (show details)."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (ogent-issues--show-detail issue)
    (user-error "No issue at point")))

;;; Detail View

(defvar ogent-issues-detail-buffer-name "*ogent-issue*"
  "Name of the issue detail buffer.")

(defvar ogent-issues-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'quit-window)
    (define-key map "g" #'ogent-issues-detail-refresh)
    (define-key map "K" #'ogent-issues-detail-close)
    (define-key map "k" #'ogent-issues-detail-close)
    (define-key map "R" #'ogent-issues-detail-reopen)
    (define-key map "r" #'ogent-issues-detail-reopen)
    (define-key map "s" #'ogent-issues-detail-start)
    (define-key map "C" #'ogent-issues-detail-comment)
    (define-key map (kbd "RET") #'ogent-issues-detail-follow-link)
    (define-key map "?" #'ogent-issues-detail-help)
    map)
  "Keymap for `ogent-issues-detail-mode'.")

(define-derived-mode ogent-issues-detail-mode special-mode "Issue"
  "Major mode for viewing issue details."
  :group 'ogent-issues
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defvar-local ogent-issues-detail--issue nil
  "The issue being displayed in this detail buffer.")

(defun ogent-issues--show-detail (issue)
  "Show detailed view for ISSUE in a dedicated buffer."
  (let ((id (plist-get issue :id)))
    ;; Fetch full issue details
    (ogent-issues-bd-get id
                         (lambda (full-issue)
                           (ogent-issues--render-detail full-issue))
                         (lambda (err)
                           ;; Fallback to cached data if fetch fails
                           (message "Could not fetch details: %s (using cached)" err)
                           (ogent-issues--render-detail issue)))))

(defun ogent-issues--render-detail (issue)
  "Render ISSUE in the detail buffer."
  (let ((buf (get-buffer-create ogent-issues-detail-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-issues-detail-mode)
        (setq ogent-issues-detail--issue issue)
        (ogent-issues--insert-detail-header issue)
        (ogent-issues--insert-detail-description issue)
        (ogent-issues--insert-detail-metadata issue)
        (ogent-issues--insert-detail-dependencies issue)
        (ogent-issues--insert-detail-comments issue)
        (goto-char (point-min))
        (setq header-line-format
              (concat
               " "
               (propertize (plist-get issue :id) 'face 'ogent-issues-id)
               "  "
               (propertize "q" 'face 'ogent-issues-header-line-key)
               (propertize ":quit " 'face 'ogent-issues-dimmed)
               (propertize "g" 'face 'ogent-issues-header-line-key)
               (propertize ":refresh " 'face 'ogent-issues-dimmed)
               (propertize "s" 'face 'ogent-issues-header-line-key)
               (propertize ":start " 'face 'ogent-issues-dimmed)
               (propertize "k" 'face 'ogent-issues-header-line-key)
               (propertize ":close" 'face 'ogent-issues-dimmed)))))
    (pop-to-buffer buf)))

(defun ogent-issues--insert-detail-header (issue)
  "Insert header section for ISSUE."
  (let* ((id (plist-get issue :id))
         (title (plist-get issue :title))
         (status (plist-get issue :status))
         (priority (plist-get issue :priority))
         (type (plist-get issue :issue_type))
         (ready (ogent-issues--issue-ready-p issue)))
    ;; Title line
    (insert (propertize (or title "Untitled") 'face '(:weight bold :height 1.1)))
    (insert "\n\n")
    ;; Status line with badges
    (insert (ogent-issues--priority-indicator priority))
    (insert " ")
    (insert (propertize (format "[%s]" (upcase (or type "task")))
                        'face 'ogent-issues-type))
    (insert " ")
    (insert (propertize (ogent-issues--status-label status)
                        'face (ogent-issues--status-face status)))
    (when ready
      (insert " ")
      (insert (ogent-issues--ready-indicator))
      (insert (propertize " ready" 'face 'ogent-issues-ready)))
    (insert "\n\n")))

(defun ogent-issues--insert-detail-description (issue)
  "Insert description section for ISSUE."
  (let ((desc (plist-get issue :description)))
    (insert (propertize "Description" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (if (and desc (not (string-empty-p desc)))
        (insert (ogent-issues--render-markdown desc))
      (insert (propertize "(No description)" 'face 'ogent-issues-dimmed)))
    (insert "\n\n")))

(defun ogent-issues--insert-detail-metadata (issue)
  "Insert metadata section for ISSUE."
  (let ((created (plist-get issue :created_at))
        (updated (plist-get issue :updated_at))
        (parent (plist-get issue :parent_id))
        (labels (plist-get issue :labels)))
    (insert (propertize "Metadata" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (propertize "Created  " 'face 'ogent-issues-dimmed))
    (insert (ogent-issues--format-time created))
    (insert "\n")
    (insert (propertize "Updated  " 'face 'ogent-issues-dimmed))
    (insert (ogent-issues--format-time updated))
    (insert "\n")
    (when parent
      (insert (propertize "Parent   " 'face 'ogent-issues-dimmed))
      (insert (ogent-issues--format-dep-link parent))
      (insert "\n"))
    (when labels
      (insert (propertize "Labels   " 'face 'ogent-issues-dimmed))
      (insert (if (listp labels)
                  (string-join labels ", ")
                labels))
      (insert "\n"))
    (insert "\n")))

(defun ogent-issues--insert-detail-dependencies (issue)
  "Insert dependencies section for ISSUE."
  (let ((blocks (plist-get issue :blocks))
        (blocked-by (plist-get issue :blocked_by))
        (children (plist-get issue :children)))
    (insert (propertize "Dependencies" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (propertize "Blocks     " 'face 'ogent-issues-dimmed))
    (if (and blocks (> (length blocks) 0))
        (insert (mapconcat #'ogent-issues--format-dep-link blocks ", "))
      (insert (propertize "none" 'face 'ogent-issues-dimmed)))
    (insert "\n")
    (insert (propertize "Blocked by " 'face 'ogent-issues-dimmed))
    (if (and blocked-by (> (length blocked-by) 0))
        (insert (mapconcat #'ogent-issues--format-dep-link blocked-by ", "))
      (insert (propertize "none" 'face 'ogent-issues-dimmed)))
    (insert "\n")
    (when (and children (> (length children) 0))
      (insert (propertize "Children   " 'face 'ogent-issues-dimmed))
      (insert (mapconcat #'ogent-issues--format-dep-link children ", "))
      (insert "\n"))
    (insert "\n")))

(defun ogent-issues--insert-detail-comments (issue)
  "Insert comments section for ISSUE."
  (let ((comments (plist-get issue :comments)))
    (insert (propertize (format "Comments (%d)" (length (or comments '())))
                        'face 'ogent-issues-section-heading))
    (insert "\n")
    (if (and comments (> (length comments) 0))
        (dolist (comment comments)
          (ogent-issues--insert-comment comment))
      (insert (propertize "(No comments)" 'face 'ogent-issues-dimmed)))
    (insert "\n")))

(defun ogent-issues--insert-comment (comment)
  "Insert a single COMMENT."
  (let ((author (or (plist-get comment :author) "unknown"))
        (time (plist-get comment :created_at))
        (text (or (plist-get comment :text)
                  (plist-get comment :body)
                  "")))
    (insert "\n")
    (insert (propertize (format "@%s" author) 'face 'font-lock-keyword-face))
    (insert " ")
    (insert (propertize (ogent-issues--format-time time) 'face 'ogent-issues-dimmed))
    (insert "\n")
    (insert (ogent-issues--indent-text text 2))
    (insert "\n")))

;;; Detail View Utilities

(defun ogent-issues--format-time (iso-time)
  "Format ISO-TIME as human-readable string."
  (if (and iso-time (not (string-empty-p iso-time)))
      (condition-case nil
          (let ((time (parse-iso8601-time-string iso-time)))
            (format-time-string "%Y-%m-%d %H:%M" time))
        (error iso-time))
    "unknown"))

(defun ogent-issues--render-markdown (text)
  "Render TEXT with basic markdown formatting."
  (if (null text)
      ""
    (with-temp-buffer
      (insert text)
      ;; Bold: **text** or __text__
      (goto-char (point-min))
      (while (re-search-forward "\\*\\*\\(.+?\\)\\*\\*" nil t)
        (replace-match (propertize (match-string 1) 'face 'bold) t t))
      (goto-char (point-min))
      (while (re-search-forward "__\\(.+?\\)__" nil t)
        (replace-match (propertize (match-string 1) 'face 'bold) t t))
      ;; Code: `text`
      (goto-char (point-min))
      (while (re-search-forward "`\\([^`\n]+?\\)`" nil t)
        (replace-match (propertize (match-string 1) 'face 'font-lock-constant-face) t t))
      ;; Headers: ## text
      (goto-char (point-min))
      (while (re-search-forward "^##+ \\(.+\\)$" nil t)
        (replace-match (propertize (match-string 1) 'face 'ogent-issues-section-heading) t t))
      ;; List items: - or *
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)[-*] " nil t)
        (replace-match (concat (match-string 1) (if ogent-issues-use-unicode "• " "- "))))
      ;; Checkbox: - [ ] or - [x]
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)• \\[ \\]" nil t)
        (replace-match (concat (match-string 1) (if ogent-issues-use-unicode "☐ " "[ ] "))))
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)• \\[x\\]" nil t)
        (replace-match (concat (match-string 1) (if ogent-issues-use-unicode "☑ " "[x] "))))
      (buffer-string))))

(defun ogent-issues--indent-text (text indent)
  "Indent TEXT by INDENT spaces."
  (if (null text)
      ""
    (let ((prefix (make-string indent ?\s)))
      (mapconcat (lambda (line) (concat prefix line))
                 (split-string text "\n")
                 "\n"))))

(defun ogent-issues--format-dep-link (id)
  "Format ID as a clickable link."
  (propertize id
              'face 'link
              'mouse-face 'highlight
              'help-echo (format "Visit issue %s" id)
              'ogent-issue-id id
              'keymap ogent-issues-link-map))

(defvar ogent-issues-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-issues-detail-follow-link)
    (define-key map [mouse-1] #'ogent-issues-detail-follow-link)
    map)
  "Keymap for issue links.")

;;; Detail View Actions

(defun ogent-issues-detail-refresh ()
  "Refresh the current detail view."
  (interactive)
  (when ogent-issues-detail--issue
    (ogent-issues--show-detail ogent-issues-detail--issue)))

(defun ogent-issues-detail-close ()
  "Close the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let* ((id (plist-get issue :id))
           (reason (read-string (format "Close %s with reason: " id))))
      (when (yes-or-no-p (format "Close issue %s? " id))
        (ogent-issues-bd-close id reason
                               (lambda ()
                                 (message "Closed: %s" id)
                                 (ogent-issues-detail-refresh))
                               (lambda (err)
                                 (message "Failed to close: %s" err)))))))

(defun ogent-issues-detail-reopen ()
  "Reopen the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let ((id (plist-get issue :id)))
      (ogent-issues-bd-reopen id
                              (lambda ()
                                (message "Reopened: %s" id)
                                (ogent-issues-detail-refresh))
                              (lambda (err)
                                (message "Failed to reopen: %s" err))))))

(defun ogent-issues-detail-start ()
  "Start working on the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let ((id (plist-get issue :id)))
      (ogent-issues-bd-start id
                             (lambda ()
                               (message "Started: %s" id)
                               (ogent-issues-detail-refresh))
                             (lambda (err)
                               (message "Failed to start: %s" err))))))

(defun ogent-issues-detail-comment ()
  "Add a comment to the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let* ((id (plist-get issue :id))
           (text (read-string (format "Comment on %s: " id))))
      (when (string-empty-p text)
        (user-error "Comment cannot be empty"))
      (ogent-issues-bd-comment id text
                               (lambda ()
                                 (message "Comment added to %s" id)
                                 (ogent-issues-detail-refresh))
                               (lambda (err)
                                 (message "Failed to comment: %s" err))))))

(defun ogent-issues-detail-follow-link ()
  "Follow the issue link at point."
  (interactive)
  (if-let ((id (get-text-property (point) 'ogent-issue-id)))
      (ogent-issues-bd-get id
                           #'ogent-issues--render-detail
                           (lambda (err)
                             (message "Could not fetch issue %s: %s" id err)))
    (user-error "No issue link at point")))

(defun ogent-issues-detail-help ()
  "Show help for detail view."
  (interactive)
  (message "q:quit g:refresh s:start k:close r:reopen C:comment RET:follow-link"))

;;; Refresh

(defun ogent-issues-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the issues buffer."
  (interactive)
  ;; Save position
  (setq ogent-issues--last-position
        (when-let ((issue (ogent-issues--current-issue)))
          (plist-get issue :id)))
  ;; Fetch and render
  (ogent-issues-bd-list
   (lambda (issues)
     (setq ogent-issues--issues (ogent-issues--apply-filters issues))
     (let ((inhibit-read-only t))
       (erase-buffer)
       (ogent-issues--insert-buffer-contents ogent-issues--issues)
       (ogent-issues--restore-position)))
   ogent-issues--filters
   (lambda (err)
     (message "Failed to refresh: %s" err))))

(defun ogent-issues-refresh-force ()
  "Force refresh, clearing cache."
  (interactive)
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-refresh))

(defun ogent-issues--restore-position ()
  "Restore cursor to last known position."
  (goto-char (point-min))
  (when ogent-issues--last-position
    (let ((found nil))
      (while (and (not found) (not (eobp)))
        (if (equal (ogent-issues--current-issue-id) ogent-issues--last-position)
            (setq found t)
          (ogent-issues-next-issue)))
      (unless found
        (goto-char (point-min))
        (ogent-issues-next-issue)))))

;;; Filtering

(defun ogent-issues--apply-filters (issues)
  "Apply current filters to ISSUES."
  (if (null ogent-issues--filters)
      issues
    (seq-filter
     (lambda (issue)
       (and (or (null (plist-get ogent-issues--filters :status))
                (string= (plist-get issue :status)
                         (plist-get ogent-issues--filters :status)))
            (or (null (plist-get ogent-issues--filters :type))
                (string= (plist-get issue :issue_type)
                         (plist-get ogent-issues--filters :type)))
            (or (null (plist-get ogent-issues--filters :priority))
                (= (or (plist-get issue :priority) 2)
                   (plist-get ogent-issues--filters :priority)))))
     issues)))

(defun ogent-issues-filter-status (status)
  "Filter issues by STATUS."
  (interactive
   (list (completing-read "Status: "
                          '("open" "in_progress" "blocked" "closed")
                          nil t)))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :status status))
  (ogent-issues-refresh))

(defun ogent-issues-filter-type (type)
  "Filter issues by TYPE."
  (interactive
   (list (completing-read "Type: "
                          '("bug" "feature" "task" "epic" "chore")
                          nil t)))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :type type))
  (ogent-issues-refresh))

(defun ogent-issues-filter-priority (priority)
  "Filter issues by PRIORITY."
  (interactive
   (list (string-to-number
          (completing-read "Priority: " '("0" "1" "2" "3") nil t))))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :priority priority))
  (ogent-issues-refresh))

(defun ogent-issues-clear-filters ()
  "Clear all filters."
  (interactive)
  (setq ogent-issues--filters nil)
  (ogent-issues-refresh))

(defun ogent-issues-filter-dispatch ()
  "Open filter transient menu."
  (interactive)
  (if (fboundp 'ogent-issues-filter-dispatch)
      (call-interactively 'ogent-issues-filter-dispatch)
    (message "ff:filter fc:clear fs:status ft:type fp:priority")))

;;; Actions

(defun ogent-issues-create ()
  "Create a new issue."
  (interactive)
  (if (fboundp 'ogent-issues-create-dispatch)
      (call-interactively 'ogent-issues-create-dispatch)
    (let* ((title (read-string "Issue title: "))
           (type (completing-read "Type: " '("task" "bug" "feature" "chore" "epic") nil t "task"))
           (priority (string-to-number (completing-read "Priority: " '("0" "1" "2" "3") nil t "2"))))
      (when (string-empty-p title)
        (user-error "Title cannot be empty"))
      (ogent-issues-bd-create title
                              (lambda (result)
                                (message "Created: %s" (plist-get result :id))
                                (ogent-issues-refresh))
                              :type type
                              :priority priority))))

(defun ogent-issues-close ()
  "Close the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let* ((id (plist-get issue :id))
             (reason (read-string (format "Close %s with reason: " id))))
        (when (yes-or-no-p (format "Close issue %s? " id))
          (ogent-issues-bd-close id reason
                                 (lambda ()
                                   (message "Closed: %s" id)
                                   (ogent-issues-refresh))
                                 (lambda (err)
                                   (message "Failed to close: %s" err)))))
    (user-error "No issue at point")))

(defun ogent-issues-reopen ()
  "Reopen the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let ((id (plist-get issue :id)))
        (ogent-issues-bd-reopen id
                                (lambda ()
                                  (message "Reopened: %s" id)
                                  (ogent-issues-refresh))
                                (lambda (err)
                                  (message "Failed to reopen: %s" err))))
    (user-error "No issue at point")))

(defun ogent-issues-start ()
  "Start working on the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let ((id (plist-get issue :id)))
        (ogent-issues-bd-start id
                               (lambda ()
                                 (message "Started: %s" id)
                                 (ogent-issues-refresh))
                               (lambda (err)
                                 (message "Failed to start: %s" err))))
    (user-error "No issue at point")))

(defun ogent-issues-comment ()
  "Add a comment to the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let* ((id (plist-get issue :id))
             (text (read-string (format "Comment on %s: " id))))
        (when (string-empty-p text)
          (user-error "Comment cannot be empty"))
        (ogent-issues-bd-comment id text
                                 (lambda ()
                                   (message "Comment added to %s" id)
                                   (ogent-issues-refresh))
                                 (lambda (err)
                                   (message "Failed to comment: %s" err))))
    (user-error "No issue at point")))

(defun ogent-issues-sync ()
  "Sync issues to git."
  (interactive)
  (ogent-issues-bd-sync
   (lambda ()
     (message "Synced to git")
     (ogent-issues-refresh))
   (lambda (err)
     (message "Failed to sync: %s" err))))

;;; Views

(defun ogent-issues-view-list ()
  "Switch to list view."
  (interactive)
  (setq ogent-issues--current-view 'list)
  (ogent-issues-refresh))

(defun ogent-issues-view-ready ()
  "Switch to ready work view."
  (interactive)
  (setq ogent-issues--current-view 'ready)
  (ogent-issues-bd-ready
   (lambda (issues)
     (setq ogent-issues--issues issues)
     (let ((inhibit-read-only t))
       (erase-buffer)
       (if issues
           (progn
             (insert (propertize "Ready Work" 'face 'ogent-issues-section-heading))
             (insert "\n")
             (insert (propertize "Issues with no blockers, sorted by priority\n\n"
                                 'face 'ogent-issues-dimmed))
             (if ogent-issues--magit-section-available
                 (magit-insert-section (ogent-issues-root-section)
                   (dolist (issue (seq-sort-by (lambda (i) (or (plist-get i :priority) 2)) #'< issues))
                     (ogent-issues--insert-issue issue)))
               (dolist (issue (seq-sort-by (lambda (i) (or (plist-get i :priority) 2)) #'< issues))
                 (insert (ogent-issues--format-issue-line issue) "\n"))))
         (insert (propertize "Ready Work" 'face 'ogent-issues-section-heading))
         (insert "\n\n")
         (insert (propertize "  No ready work! 🎉\n\n" 'face 'ogent-issues-dimmed))
         (insert (propertize "  All issues are either blocked, closed, or in progress.\n"
                             'face 'ogent-issues-dimmed)))
       (goto-char (point-min))))
   (lambda (err)
     (message "Failed to fetch ready work: %s" err))))

;;; Kanban View

(defconst ogent-issues-kanban-columns
  '(("in_progress" . "In Progress")
    ("open" . "Open")
    ("blocked" . "Blocked")
    ("closed" . "Closed"))
  "Kanban column definitions in display order.")

(defvar-local ogent-issues-kanban--column-width 20
  "Width of each Kanban column.")

(defun ogent-issues-view-kanban ()
  "Switch to Kanban board view."
  (interactive)
  (setq ogent-issues--current-view 'kanban)
  (ogent-issues-bd-list
   (lambda (issues)
     (setq ogent-issues--issues issues)
     (let ((inhibit-read-only t))
       (erase-buffer)
       (ogent-issues--insert-kanban-board issues)
       (goto-char (point-min))))
   nil  ; no filters
   (lambda (err)
     (message "Failed to fetch issues for Kanban: %s" err))))

(defun ogent-issues--kanban-column-width ()
  "Calculate column width based on window width."
  (let* ((num-cols (length ogent-issues-kanban-columns))
         (separators (1+ num-cols))  ; │ between and at edges
         (available (- (window-width) separators)))
    (max 15 (/ available num-cols))))

(defun ogent-issues--insert-kanban-board (issues)
  "Insert Kanban board with ISSUES."
  (let* ((col-width (ogent-issues--kanban-column-width))
         (grouped (ogent-issues--group-by-status issues))
         (max-rows (ogent-issues--kanban-max-rows grouped)))
    (setq-local ogent-issues-kanban--column-width col-width)
    ;; Header
    (insert (propertize "Kanban Board" 'face 'ogent-issues-section-heading))
    (insert "  ")
    (insert (propertize "h/l: move issue left/right  q: quit" 'face 'ogent-issues-dimmed))
    (insert "\n\n")
    ;; Column headers
    (ogent-issues--insert-kanban-headers col-width grouped)
    ;; Separator
    (ogent-issues--insert-kanban-separator col-width)
    ;; Issue rows
    (if (zerop max-rows)
        (progn
          (insert "│")
          (dolist (_col ogent-issues-kanban-columns)
            (insert (ogent-issues--kanban-pad "No issues" col-width))
            (insert "│"))
          (insert "\n"))
      (dotimes (row max-rows)
        (insert "│")
        (dolist (col-def ogent-issues-kanban-columns)
          (let* ((status (car col-def))
                 (issues-in-col (cdr (assoc status grouped))))
            (if (< row (length issues-in-col))
                (ogent-issues--insert-kanban-card (nth row issues-in-col) col-width)
              (insert (make-string col-width ?\s)))
            (insert "│")))
        (insert "\n")))
    ;; Bottom border
    (ogent-issues--insert-kanban-separator col-width)))

(defun ogent-issues--insert-kanban-headers (col-width grouped)
  "Insert Kanban column headers with COL-WIDTH and issue counts from GROUPED."
  (insert "┌")
  (dotimes (i (length ogent-issues-kanban-columns))
    (insert (make-string col-width ?─))
    (if (< i (1- (length ogent-issues-kanban-columns)))
        (insert "┬")
      (insert "┐")))
  (insert "\n│")
  (dolist (col-def ogent-issues-kanban-columns)
    (let* ((status (car col-def))
           (label (cdr col-def))
           (count (length (cdr (assoc status grouped))))
           (header (format "%s (%d)" label count))
           (padded (ogent-issues--kanban-pad header col-width)))
      (insert (propertize padded 'face 'ogent-issues-section-heading))
      (insert "│")))
  (insert "\n"))

(defun ogent-issues--insert-kanban-separator (col-width)
  "Insert horizontal separator for Kanban board."
  (insert "├")
  (dotimes (i (length ogent-issues-kanban-columns))
    (insert (make-string col-width ?─))
    (if (< i (1- (length ogent-issues-kanban-columns)))
        (insert "┼")
      (insert "┤")))
  (insert "\n"))

(defun ogent-issues--insert-kanban-card (issue col-width)
  "Insert ISSUE as a Kanban card with COL-WIDTH."
  (let* ((id (plist-get issue :id))
         (title (plist-get issue :title))
         (priority (or (plist-get issue :priority) 2))
         (status (plist-get issue :status))
         (priority-str (if ogent-issues-use-unicode
                           (pcase priority
                             (0 "●")
                             (1 "◐")
                             (2 "○")
                             (_ "◌"))
                         (format "P%d" priority)))
         ;; Reserve space for: priority + space + id + space + title
         (available (- col-width (length priority-str) 1 (length id) 1))
         (truncated-title (truncate-string-to-width (or title "") (max 1 available) nil nil "…"))
         (card-text (concat priority-str " " id " " truncated-title))
         (padded (ogent-issues--kanban-pad card-text col-width)))
    (insert (propertize padded
                        'ogent-issue-id id
                        'ogent-issue issue
                        'face (ogent-issues--status-face status)))))

(defun ogent-issues--kanban-pad (str width)
  "Pad STR to WIDTH, centering if shorter."
  (let ((len (length str)))
    (if (>= len width)
        (truncate-string-to-width str width nil nil "…")
      (let* ((padding (- width len))
             (left-pad (/ padding 2))
             (right-pad (- padding left-pad)))
        (concat (make-string left-pad ?\s) str (make-string right-pad ?\s))))))

(defun ogent-issues--kanban-max-rows (grouped)
  "Return max number of issues in any column from GROUPED."
  (let ((max-count 0))
    (dolist (col-def ogent-issues-kanban-columns)
      (let ((count (length (cdr (assoc (car col-def) grouped)))))
        (when (> count max-count)
          (setq max-count count))))
    max-count))

(defun ogent-issues-kanban-move-left ()
  "Move issue at point to previous status column."
  (interactive)
  (ogent-issues--kanban-move-issue -1))

(defun ogent-issues-kanban-move-right ()
  "Move issue at point to next status column."
  (interactive)
  (ogent-issues--kanban-move-issue 1))

(defun ogent-issues--kanban-move-issue (direction)
  "Move current issue by DIRECTION (-1 or 1) in status."
  (let* ((issue (ogent-issues--current-issue))
         (id (when issue (plist-get issue :id)))
         (current-status (when issue (plist-get issue :status)))
         (statuses (mapcar #'car ogent-issues-kanban-columns))
         (current-idx (when current-status
                        (cl-position current-status statuses :test #'string=)))
         (new-idx (when current-idx (+ current-idx direction)))
         (new-status (when (and new-idx (>= new-idx 0) (< new-idx (length statuses)))
                       (nth new-idx statuses))))
    (cond
     ((not issue)
      (message "No issue at point"))
     ((not new-status)
      (message "Cannot move %s further %s" id (if (< direction 0) "left" "right")))
     ((string= current-status new-status)
      (message "Issue already in %s" new-status))
     (t
      ;; Use bd CLI to update status
      (ogent-issues-bd-update id
        (lambda ()
          (message "Moved %s to %s" id new-status)
          (ogent-issues-refresh))
        :status new-status)))))

(defun ogent-issues-view-deps ()
  "Switch to dependency graph view."
  (interactive)
  (setq ogent-issues--current-view 'deps)
  (message "Dependency view not yet implemented"))

(provide 'ogent-issues)

;;; ogent-issues.el ends here
