;;; ogent-issues-detail.el --- Issue detail view for ogent-issues -*- lexical-binding: t; -*-

;;; Commentary:
;; Issue detail buffer (mode, rendering, and per-issue actions) for
;; ogent-issues, extracted from the ogent-issues facade.  Required by the
;; facade at load time so `(require 'ogent-issues)' still loads the detail view.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'iso8601)
(require 'ogent-ops-style)
(require 'ogent-issues-bd)

;; Core ogent-issues helpers and buffer-local state referenced below live in
;; the facade (`ogent-issues').  Declare them here so this file byte-compiles
;; on its own; it avoids requiring the facade to keep the load graph acyclic.
(declare-function ogent-issues--issue-ready-p "ogent-issues")
(declare-function ogent-issues--priority-indicator "ogent-issues")
(declare-function ogent-issues--status-label "ogent-issues")
(declare-function ogent-issues--status-face "ogent-issues")
(declare-function ogent-issues--ready-indicator "ogent-issues")
(defvar ogent-issues-use-unicode)
(defvar ogent-issues-detail-auto-refresh)
(defvar ogent-issues-detail-display-action)

;;; Detail View

(defvar ogent-issues-detail-buffer-name "*ogent-issue*"
  "Base name of the issue detail buffer.
Actual buffer name includes project: `*ogent-issue: <project>*'.")

(defun ogent-issues--detail-buffer-name ()
  "Return the detail buffer name for the current project."
  (let ((project (ogent-issues-bd-project-name)))
    (format "*ogent-issue: %s*" (or project "unknown"))))

(defvar ogent-issues-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'quit-window)
    (define-key map "g" #'ogent-issues-detail-refresh)
    (define-key map "K" #'ogent-issues-detail-close)
    ;; k is NOT bound here so evil users get normal up movement
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
  (setq-local word-wrap t)
  (ogent-ops-protect-face-properties))

(defvar-local ogent-issues-detail--issue nil
  "The issue being displayed in this detail buffer.")

(defun ogent-issues--show-detail (issue)
  "Show detailed view for ISSUE in a dedicated buffer.
Renders immediately with available data for instant feedback.
Optionally refreshes in background if
`ogent-issues-detail-auto-refresh' is non-nil."
  ;; Capture project root from current buffer (the issues buffer)
  ;; so detail buffer and callbacks use the correct project
  (let ((project-root (ogent-issues-bd-project-root))
        (detail-buf-name (ogent-issues--detail-buffer-name)))
    ;; Render immediately with the data we have (no waiting for bd show)
    (ogent-issues--render-detail issue project-root detail-buf-name)
    ;; Background refresh to get fresh data (comments, full description, etc.)
    (when (and (boundp 'ogent-issues-detail-auto-refresh)
               ogent-issues-detail-auto-refresh)
      (let ((id (plist-get issue :id))
            (buf (get-buffer detail-buf-name)))
        ;; Run bd from the correct project directory
        (let ((default-directory project-root))
          (ogent-issues-bd-get id
                               (lambda (fresh-issue)
                                 (when (and (buffer-live-p buf)
                                            fresh-issue
                                            ;; Only re-render if still viewing same issue
                                            (with-current-buffer buf
                                              (equal (plist-get ogent-issues-detail--issue :id)
                                                     (plist-get fresh-issue :id))))
                                   (ogent-issues--render-detail fresh-issue project-root detail-buf-name)))
                               nil))))))

(defun ogent-issues--render-detail (issue &optional project-root buffer-name)
  "Render ISSUE in the detail buffer.
PROJECT-ROOT is the beads project directory (for setting `default-directory').
BUFFER-NAME is the detail buffer name (defaults to project-specific name).
By default, displays in a side-by-side split to the right of the
issues buffer, like magit's two-pane layouts.  Customize
`ogent-issues-detail-display-action' to change this behavior."
  (let* ((proj-root (or project-root (ogent-issues-bd-project-root)))
         (buf-name (or buffer-name (ogent-issues--detail-buffer-name)))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-issues-detail-mode)
        ;; Set default-directory so bd commands run in correct project
        (setq default-directory proj-root)
        (setq ogent-issues-detail--issue issue)
        (ogent-issues--insert-detail-header issue)
        (ogent-issues--insert-detail-description issue)
        (ogent-issues--insert-detail-subtasks issue)
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
               (propertize "K" 'face 'ogent-issues-header-line-key)
               (propertize ":close" 'face 'ogent-issues-dimmed)))))
    ;; Display based on customization (default to 'right if not set).
    ;; The right/below layouts go through
    ;; `display-buffer-overriding-action' so the user's explicit choice
    ;; here beats generic catch-all popup rules.
    (pcase (if (boundp 'ogent-issues-detail-display-action)
               ogent-issues-detail-display-action
             'right)
      ('below
       ;; Split below, like magit-show-commit
       (let* ((display-buffer-overriding-action
               '((display-buffer-below-selected)
                 (window-height . 0.4)
                 (preserve-size . (nil . t))))
              (window (display-buffer buf)))
         (when window
           (select-window window))))
      ('other-window
       (pop-to-buffer buf))
      ('default
       (display-buffer buf))
      (_
       ;; Default: side-by-side to the right, reusing a right-hand
       ;; window when one exists (magit-style two-pane layout).
       (let* ((display-buffer-overriding-action
               '((display-buffer-in-direction)
                 (direction . right)
                 (window-width . 0.5)))
              (window (display-buffer buf)))
         (when window
           (select-window window)))))))

(defun ogent-issues--insert-detail-header (issue)
  "Insert header section for ISSUE."
  (let* ((title (plist-get issue :title))
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

(defun ogent-issues--insert-detail-subtasks (issue)
  "Insert subtasks section for ISSUE (child issues)."
  (let* ((dependents (plist-get issue :dependents))
         (subtasks (seq-filter
                    (lambda (dep)
                      (string= (plist-get dep :dependency_type) "parent-child"))
                    dependents)))
    (when (and subtasks (> (length subtasks) 0))
      (insert (propertize (format "Subtasks (%d)" (length subtasks))
                          'face 'ogent-issues-section-heading))
      (insert "\n")
      (dolist (subtask subtasks)
        (ogent-issues--insert-subtask-line subtask))
      (insert "\n"))))

(defun ogent-issues--insert-subtask-line (subtask)
  "Insert a single SUBTASK as a line in the detail view."
  (let* ((id (plist-get subtask :id))
         (title (plist-get subtask :title))
         (status (plist-get subtask :status))
         (priority (or (plist-get subtask :priority) 2))
         (type (or (plist-get subtask :issue_type) "task"))
         (closed-p (string= status "closed"))
         (status-indicator (if closed-p
                               (propertize "✓" 'face 'ogent-issues-status-closed)
                             (propertize "○" 'face 'ogent-issues-status-open))))
    (insert "  ")
    (insert status-indicator)
    (insert " ")
    (insert (ogent-issues--format-dep-link id))
    (insert " ")
    (insert (ogent-issues--priority-indicator priority))
    (insert " ")
    (insert (propertize (format "[%s]" type) 'face 'ogent-issues-type))
    (insert " ")
    (insert (propertize (truncate-string-to-width (or title "") 50 nil nil "…")
                        'face (if closed-p 'ogent-issues-status-closed nil)))
    (insert "\n")))

(defun ogent-issues--insert-detail-dependencies (issue)
  "Insert dependencies section for ISSUE."
  (let* ((dependents (plist-get issue :dependents))
         ;; Filter out parent-child relationships (those are shown in Subtasks)
         (other-deps (seq-filter
                      (lambda (dep)
                        (not (string= (plist-get dep :dependency_type) "parent-child")))
                      dependents))
         (blocks (plist-get issue :blocks))
         (blocked-by (plist-get issue :blocked_by)))
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
    ;; Show other dependents (not parent-child) if any
    (when (and other-deps (> (length other-deps) 0))
      (insert (propertize "Dependents " 'face 'ogent-issues-dimmed))
      (insert (mapconcat (lambda (dep) (ogent-issues--format-dep-link (plist-get dep :id)))
                         other-deps ", "))
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
  (if (and iso-time
           (stringp iso-time)
           (not (string-empty-p iso-time)))
      (condition-case nil
          (let ((time (encode-time (iso8601-parse iso-time))))
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

(defvar ogent-issues-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-issues-detail-follow-link)
    (define-key map [mouse-1] #'ogent-issues-detail-follow-link)
    map)
  "Keymap for issue links.")

(defun ogent-issues--format-dep-link (id)
  "Format ID as a clickable link."
  (propertize id
              'face 'link
              'mouse-face 'highlight
              'help-echo (format "Visit issue %s" id)
              'ogent-issue-id id
              'keymap ogent-issues-link-map))

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
  (message "q:quit g:refresh s:start K:close r:reopen C:comment RET:follow-link"))

(provide 'ogent-issues-detail)

;;; ogent-issues-detail.el ends here
