;;; ogent-issues.el --- Magit-style beads issue viewer -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-section based buffer for viewing and managing beads issues.
;; This is the main entry point for the ogent-issues module.

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

;;; Faces

(defgroup ogent-issues-faces nil
  "Faces for ogent-issues."
  :group 'ogent-issues)

(defface ogent-issues-id
  '((t :inherit font-lock-constant-face))
  "Face for issue IDs."
  :group 'ogent-issues-faces)

(defface ogent-issues-title
  '((t :inherit default))
  "Face for issue titles."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-0
  '((t :foreground "#ff5555" :weight bold))
  "Face for P0 (critical) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-1
  '((t :foreground "#ffb86c" :weight bold))
  "Face for P1 (high) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-2
  '((t :foreground "#f1fa8c"))
  "Face for P2 (medium) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-3
  '((t :foreground "#50fa7b"))
  "Face for P3 (low) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-open
  '((t :foreground "#8be9fd"))
  "Face for open issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-in-progress
  '((t :foreground "#bd93f9"))
  "Face for in-progress issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-blocked
  '((t :foreground "#ff5555" :slant italic))
  "Face for blocked issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-closed
  '((t :foreground "#6272a4" :strike-through t))
  "Face for closed issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading
  '((t :inherit magit-section-heading :weight bold))
  "Face for section headings."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line
  '((t :inherit header-line))
  "Face for the header line."
  :group 'ogent-issues-faces)

(defface ogent-issues-ready-indicator
  '((t :foreground "#f1fa8c" :weight bold))
  "Face for ready issue indicator (⚡)."
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

;;; Keymap

(defvar ogent-issues-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Inherit from magit-section if available
    (when (and ogent-issues--magit-section-available
               (boundp 'magit-section-mode-map))
      (set-keymap-parent map magit-section-mode-map))
    ;; Navigation
    (define-key map "j" #'ogent-issues-next-issue)
    (define-key map "k" #'ogent-issues-prev-issue)
    (define-key map "n" #'ogent-issues-next-issue)
    (define-key map "p" #'ogent-issues-prev-issue)
    (define-key map (kbd "RET") #'ogent-issues-visit)
    (define-key map (kbd "TAB") #'ogent-issues-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-issues-cycle-sections)
    ;; Actions
    (define-key map "c" #'ogent-issues-create)
    (define-key map "K" #'ogent-issues-close)
    (define-key map "R" #'ogent-issues-reopen)
    (define-key map "s" #'ogent-issues-start)
    (define-key map "C" #'ogent-issues-comment)
    (define-key map "g" #'ogent-issues-refresh)
    (define-key map "G" #'ogent-issues-refresh-force)
    (define-key map "?" #'ogent-issues-dispatch)
    ;; Filters
    (define-key map "fs" #'ogent-issues-filter-status)
    (define-key map "ft" #'ogent-issues-filter-type)
    (define-key map "fp" #'ogent-issues-filter-priority)
    (define-key map "fx" #'ogent-issues-clear-filters)
    ;; Views
    (define-key map "vl" #'ogent-issues-view-list)
    (define-key map "vr" #'ogent-issues-view-ready)
    (define-key map "vk" #'ogent-issues-view-kanban)
    (define-key map "vd" #'ogent-issues-view-deps)
    ;; Sync
    (define-key map "S" #'ogent-issues-sync)
    ;; Quit
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-issues-mode'.")

;;; Mode Definition

(define-derived-mode ogent-issues-mode special-mode "Ogent-Issues"
  "Major mode for viewing and managing beads issues.

\\{ogent-issues-mode-map}"
  :group 'ogent-issues
  (setq-local revert-buffer-function #'ogent-issues-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq header-line-format
        '(:eval (ogent-issues--header-line)))
  ;; Enable magit-section features if available
  (when ogent-issues--magit-section-available
    (magit-section-mode)))

;;; Header Line

(defun ogent-issues--header-line ()
  "Generate header line for ogent-issues buffer."
  (let* ((project (or (ogent-issues-bd-project-name) "unknown"))
         (view (symbol-name ogent-issues--current-view))
         (count (length ogent-issues--issues))
         (filters (ogent-issues--format-filters)))
    (concat
     (propertize " Ogent Issues" 'face 'ogent-issues-header-line)
     " | "
     (propertize project 'face 'font-lock-constant-face)
     " | "
     (propertize (capitalize view) 'face 'font-lock-keyword-face)
     (format " (%d)" count)
     (when filters
       (concat " | " filters)))))

(defun ogent-issues--format-filters ()
  "Format current filters for display."
  (let ((parts nil))
    (when-let ((status (plist-get ogent-issues--filters :status)))
      (push (format "status:%s" status) parts))
    (when-let ((type (plist-get ogent-issues--filters :type)))
      (push (format "type:%s" type) parts))
    (when-let ((priority (plist-get ogent-issues--filters :priority)))
      (push (format "P%d" priority) parts))
    (when parts
      (propertize (string-join (nreverse parts) " ")
                  'face 'font-lock-comment-face))))

;;; Formatting Utilities

(defun ogent-issues--type-icon (type)
  "Return icon for issue TYPE."
  (let ((entry (cdr (assoc type ogent-issues-type-icons))))
    (if ogent-issues-use-unicode
        (or (car entry) "📌")
      (or (cdr entry) "?"))))

(defun ogent-issues--priority-face (priority)
  "Return face for PRIORITY level."
  (intern (format "ogent-issues-priority-%d" (min (or priority 2) 3))))

(defun ogent-issues--priority-badge (priority)
  "Return formatted priority badge for PRIORITY."
  (propertize (format "[P%d]" (or priority 2))
              'face (ogent-issues--priority-face priority)))

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
    (_ (capitalize status))))

(defun ogent-issues--ready-indicator ()
  "Return the ready indicator string."
  (propertize (if ogent-issues-use-unicode "⚡" "*")
              'face 'ogent-issues-ready-indicator))

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
         (truncated-title (truncate-string-to-width (or title "") 55 nil nil "…")))
    (concat
     (if ready (concat (ogent-issues--ready-indicator) " ") "  ")
     (propertize (or id "???") 'face 'ogent-issues-id)
     "  "
     (ogent-issues--priority-badge priority)
     " "
     (ogent-issues--type-icon type)
     " "
     (propertize truncated-title 'face (ogent-issues--status-face status))
     (when (and deps (> deps 0))
       (propertize (format " [%d deps]" deps) 'face 'font-lock-comment-face)))))

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
  (ogent-issues--insert-header)
  (insert "\n")
  (if ogent-issues--filters
      (progn
        (insert (propertize "  No issues match current filters\n\n"
                            'face 'font-lock-warning-face))
        (insert "  Active filters: " (or (ogent-issues--format-filters) "none") "\n\n")
        (insert (propertize "  Press 'fx' to clear filters, or adjust with 'fs', 'ft', 'fp'\n"
                            'face 'font-lock-comment-face)))
    (insert (propertize "  No issues found\n\n" 'face 'font-lock-comment-face))
    (insert (propertize "  Press 'c' to create a new issue\n"
                        'face 'font-lock-comment-face))))

(defun ogent-issues--insert-with-magit-section (issues)
  "Insert ISSUES using magit-section."
  (magit-insert-section (ogent-issues-root-section)
    (ogent-issues--insert-header)
    (let ((grouped (ogent-issues--group-by-status issues)))
      (dolist (status '("open" "in_progress" "blocked" "closed"))
        (when-let ((group (alist-get status grouped nil nil #'string=)))
          (ogent-issues--insert-status-section status group))))))

(defun ogent-issues--insert-plain (issues)
  "Insert ISSUES without magit-section (fallback)."
  (ogent-issues--insert-header)
  (let ((grouped (ogent-issues--group-by-status issues)))
    (dolist (status '("open" "in_progress" "blocked" "closed"))
      (when-let ((group (alist-get status grouped nil nil #'string=)))
        (insert (propertize
                 (format "\n%s (%d)\n"
                         (ogent-issues--status-label status)
                         (length group))
                 'face 'ogent-issues-section-heading))
        (dolist (issue group)
          (insert "  " (ogent-issues--format-issue-line issue) "\n")
          (put-text-property (line-beginning-position 0)
                             (line-end-position 0)
                             'ogent-issue issue))))))

(defun ogent-issues--insert-header ()
  "Insert buffer header."
  (insert (propertize "Beads Issues" 'face 'ogent-issues-section-heading))
  (insert "\n")
  (insert (propertize "Press ? for help, g to refresh\n\n"
                      'face 'font-lock-comment-face)))

(defun ogent-issues--insert-status-section (status issues)
  "Insert a section for STATUS containing ISSUES."
  (let ((collapsed (member status ogent-issues-collapsed-statuses)))
    (magit-insert-section (ogent-issues-status-section status collapsed)
      (magit-insert-heading
        (propertize (format "%s (%d)"
                            (ogent-issues--status-label status)
                            (length issues))
                    'face 'ogent-issues-section-heading))
      (dolist (issue issues)
        (ogent-issues--insert-issue issue)))))

(defun ogent-issues--insert-issue (issue)
  "Insert a single ISSUE as a section."
  (if ogent-issues--magit-section-available
      (magit-insert-section (ogent-issues-issue-section issue)
        (insert "  " (ogent-issues--format-issue-line issue) "\n"))
    (insert "  " (ogent-issues--format-issue-line issue) "\n")
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

(defvar ogent-issues-detail-buffer-name "*ogent-issue-detail*"
  "Name of the issue detail buffer.")

(defvar ogent-issues-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'quit-window)
    (define-key map "g" #'ogent-issues-detail-refresh)
    (define-key map "K" #'ogent-issues-detail-close)
    (define-key map "R" #'ogent-issues-detail-reopen)
    (define-key map "s" #'ogent-issues-detail-start)
    (define-key map "C" #'ogent-issues-detail-comment)
    (define-key map (kbd "RET") #'ogent-issues-detail-follow-link)
    map)
  "Keymap for `ogent-issues-detail-mode'.")

(define-derived-mode ogent-issues-detail-mode special-mode "Issue-Detail"
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
              (format " Issue: %s | q=quit g=refresh K=close s=start C=comment"
                      (plist-get issue :id)))))
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
    (insert (propertize (or title "Untitled") 'face '(:weight bold :height 1.2)))
    (insert "\n\n")
    ;; Status line with badges
    (insert (propertize id 'face 'ogent-issues-id))
    (insert "  ")
    (insert (ogent-issues--priority-badge priority))
    (insert " ")
    (insert (ogent-issues--type-icon type))
    (insert " ")
    (insert (propertize (format "[%s]" (ogent-issues--status-label status))
                        'face (ogent-issues--status-face status)))
    (when ready
      (insert " ")
      (insert (ogent-issues--ready-indicator))
      (insert (propertize " Ready" 'face 'ogent-issues-ready-indicator)))
    (insert "\n\n")))

(defun ogent-issues--insert-detail-description (issue)
  "Insert description section for ISSUE."
  (let ((desc (plist-get issue :description)))
    (insert (propertize "Description" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (make-string 40 ?─))
    (insert "\n")
    (if (and desc (not (string-empty-p desc)))
        (insert (ogent-issues--render-markdown desc))
      (insert (propertize "(No description)" 'face 'font-lock-comment-face)))
    (insert "\n\n")))

(defun ogent-issues--insert-detail-metadata (issue)
  "Insert metadata section for ISSUE."
  (let ((created (plist-get issue :created_at))
        (updated (plist-get issue :updated_at))
        (parent (plist-get issue :parent_id))
        (labels (plist-get issue :labels)))
    (insert (propertize "Metadata" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (make-string 40 ?─))
    (insert "\n")
    (insert (format "  Created:  %s\n" (ogent-issues--format-time created)))
    (insert (format "  Updated:  %s\n" (ogent-issues--format-time updated)))
    (when parent
      (insert (format "  Parent:   %s\n" (ogent-issues--format-dep-link parent))))
    (when labels
      (insert (format "  Labels:   %s\n"
                      (if (listp labels)
                          (string-join labels ", ")
                        labels))))
    (insert "\n")))

(defun ogent-issues--insert-detail-dependencies (issue)
  "Insert dependencies section for ISSUE."
  (let ((blocks (plist-get issue :blocks))
        (blocked-by (plist-get issue :blocked_by))
        (children (plist-get issue :children)))
    (insert (propertize "Dependencies" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (make-string 40 ?─))
    (insert "\n")
    (insert (format "  Blocks:     %s\n"
                    (if (and blocks (> (length blocks) 0))
                        (mapconcat #'ogent-issues--format-dep-link blocks ", ")
                      (propertize "(none)" 'face 'font-lock-comment-face))))
    (insert (format "  Blocked by: %s\n"
                    (if (and blocked-by (> (length blocked-by) 0))
                        (mapconcat #'ogent-issues--format-dep-link blocked-by ", ")
                      (propertize "(none)" 'face 'font-lock-comment-face))))
    (when (and children (> (length children) 0))
      (insert (format "  Children:   %s\n"
                      (mapconcat #'ogent-issues--format-dep-link children ", "))))
    (insert "\n")))

(defun ogent-issues--insert-detail-comments (issue)
  "Insert comments section for ISSUE."
  (let ((comments (plist-get issue :comments)))
    (insert (propertize (format "Comments (%d)" (length (or comments '())))
                        'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (make-string 40 ?─))
    (insert "\n")
    (if (and comments (> (length comments) 0))
        (dolist (comment comments)
          (ogent-issues--insert-comment comment))
      (insert (propertize "  (No comments)\n" 'face 'font-lock-comment-face)))
    (insert "\n")))

(defun ogent-issues--insert-comment (comment)
  "Insert a single COMMENT."
  (let ((author (or (plist-get comment :author) "unknown"))
        (time (plist-get comment :created_at))
        (text (or (plist-get comment :text)
                  (plist-get comment :body)
                  "")))
    (insert "\n  ")
    (insert (propertize (format "@%s" author) 'face 'font-lock-keyword-face))
    (insert " ")
    (insert (propertize (format "[%s]" (ogent-issues--format-time time))
                        'face 'font-lock-comment-face))
    (insert "\n")
    (insert (ogent-issues--indent-text text 4))
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
      ;; Italic: *text* or _text_ (but not inside **)
      (goto-char (point-min))
      (while (re-search-forward "\\(?:^\\|[^*_]\\)\\([*_]\\)\\([^*_\n]+?\\)\\1\\(?:[^*_]\\|$\\)" nil t)
        (replace-match (propertize (match-string 2) 'face 'italic) t t nil 0))
      ;; Code: `text`
      (goto-char (point-min))
      (while (re-search-forward "`\\([^`\n]+?\\)`" nil t)
        (replace-match (propertize (match-string 1) 'face 'font-lock-constant-face) t t))
      ;; Headers: ## text
      (goto-char (point-min))
      (while (re-search-forward "^##+ \\(.+\\)$" nil t)
        (replace-match (propertize (match-string 1) 'face '(:weight bold :underline t)) t t))
      ;; List items: - or *
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)[-*] " nil t)
        (replace-match (concat (match-string 1) "• ")))
      ;; Checkbox: - [ ] or - [x]
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)• \\[ \\]" nil t)
        (replace-match (concat (match-string 1) "☐ ")))
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)• \\[x\\]" nil t)
        (replace-match (concat (match-string 1) "☑ ")))
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
  "Restore cursor position after refresh."
  (goto-char (point-min))
  (when ogent-issues--last-position
    ;; Try to find the issue we were on
    (let ((found nil))
      (save-excursion
        (while (and (not found) (not (eobp)))
          (when-let ((issue (ogent-issues--current-issue)))
            (when (string= (plist-get issue :id) ogent-issues--last-position)
              (setq found (point))))
          (forward-line 1)))
      (when found
        (goto-char found)))))

;;; Filtering

(defun ogent-issues--apply-filters (issues)
  "Apply current filters to ISSUES."
  (let ((status (plist-get ogent-issues--filters :status))
        (type (plist-get ogent-issues--filters :type))
        (priority (plist-get ogent-issues--filters :priority)))
    (seq-filter
     (lambda (issue)
       (and (or (null status)
                (string= (plist-get issue :status) status))
            (or (null type)
                (string= (plist-get issue :issue_type) type))
            (or (null priority)
                (= (plist-get issue :priority) priority))))
     issues)))

(defun ogent-issues-filter-status (status)
  "Filter issues by STATUS."
  (interactive
   (list (completing-read "Status: "
                          '("all" "open" "in_progress" "blocked" "closed")
                          nil t)))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :status
                   (unless (string= status "all") status)))
  (ogent-issues-refresh))

(defun ogent-issues-filter-type (type)
  "Filter issues by TYPE."
  (interactive
   (list (completing-read "Type: "
                          '("all" "bug" "feature" "task" "epic" "chore")
                          nil t)))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :type
                   (unless (string= type "all") type)))
  (ogent-issues-refresh))

(defun ogent-issues-filter-priority (priority)
  "Filter issues by PRIORITY."
  (interactive
   (list (completing-read "Priority: "
                          '("all" "0" "1" "2" "3")
                          nil t)))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :priority
                   (unless (string= priority "all")
                     (string-to-number priority))))
  (ogent-issues-refresh))

(defun ogent-issues-clear-filters ()
  "Clear all filters."
  (interactive)
  (setq ogent-issues--filters nil)
  (ogent-issues-refresh))

;;; Actions

(defun ogent-issues-create ()
  "Create a new issue.
This is a placeholder - full implementation in ogent-01g.6."
  (interactive)
  (let ((title (read-string "Issue title: ")))
    (when (string-empty-p title)
      (user-error "Title cannot be empty"))
    (let ((type (completing-read "Type: "
                                 '("task" "bug" "feature" "chore" "epic")
                                 nil t "task"))
          (priority (string-to-number
                     (completing-read "Priority: "
                                      '("0" "1" "2" "3")
                                      nil t "2"))))
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
  "Sync beads to git."
  (interactive)
  (ogent-issues-bd-sync
   (lambda ()
     (message "Beads synced to git")
     (ogent-issues-refresh))
   (lambda (err)
     (message "Sync failed: %s" err))))

;;; Views (placeholders for future implementation)

(defun ogent-issues-view-list ()
  "Switch to list view."
  (interactive)
  (setq ogent-issues--current-view 'list)
  (ogent-issues-refresh))

(defun ogent-issues-view-ready ()
  "Switch to ready work view.
This is a placeholder - full implementation in ogent-01g.7."
  (interactive)
  (setq ogent-issues--current-view 'ready)
  (ogent-issues-bd-ready
   (lambda (issues)
     (setq ogent-issues--issues issues)
     (let ((inhibit-read-only t))
       (erase-buffer)
       (insert (propertize "Ready Work\n" 'face 'ogent-issues-section-heading))
       (insert (propertize "Issues with no blockers\n\n" 'face 'font-lock-comment-face))
       (if issues
           (dolist (issue issues)
             (insert "  " (ogent-issues--format-issue-line issue) "\n"))
         (insert "  No ready work! 🎉\n"))))
   (lambda (err)
     (message "Failed to fetch ready issues: %s" err))))

(defun ogent-issues-view-kanban ()
  "Switch to Kanban board view.
This is a placeholder - full implementation in ogent-01g.8."
  (interactive)
  (setq ogent-issues--current-view 'kanban)
  (message "Kanban view not yet implemented"))

(defun ogent-issues-view-deps ()
  "Switch to dependency graph view.
This is a placeholder - full implementation in ogent-01g.9."
  (interactive)
  (message "Dependency view not yet implemented"))

;; Load transient menu if available
(declare-function ogent-issues-dispatch "ogent-issues-transient" nil t)
(autoload 'ogent-issues-dispatch "ogent-issues-transient" nil t)

;;; Entry Point

;;;###autoload
(defun ogent-issues ()
  "Open the ogent-issues buffer."
  (interactive)
  ;; Check requirements
  (when-let ((err (ogent-issues-bd-check-requirements)))
    (user-error "%s" err))
  ;; Get or create buffer
  (let ((buf (get-buffer-create ogent-issues-buffer-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'ogent-issues-mode)
        (ogent-issues-mode))
      (ogent-issues-refresh))
    (pop-to-buffer buf)))

(provide 'ogent-issues)

;;; ogent-issues.el ends here
