;;; ogent-issues-transient.el --- Transient menus for ogent-issues -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides transient command menus for ogent-issues, following magit patterns.
;; Main entry point is `ogent-issues-dispatch' bound to ? in ogent-issues-mode.

;;; Code:

(require 'cl-lib)
(require 'transient)
(require 'ogent-issues-bd)

;; Forward declarations
(declare-function project-root "project" (project))
(declare-function which-function "which-func" ())
(declare-function ogent-issues-refresh "ogent-issues")
(declare-function ogent-issues-refresh-force "ogent-issues")
(declare-function ogent-issues--current-issue "ogent-issues")
(declare-function ogent-issues--current-issue-id "ogent-issues")
(declare-function ogent-issues-next-issue "ogent-issues")
(declare-function ogent-issues-prev-issue "ogent-issues")
(declare-function ogent-issues-next-ready "ogent-issues")
(declare-function ogent-issues--issue-ready-p "ogent-issues")
(declare-function ogent-issues-visit "ogent-issues")
(declare-function ogent-issues-toggle-section "ogent-issues")
(declare-function ogent-issues-create "ogent-issues")
(declare-function ogent-issues-close "ogent-issues")
(declare-function ogent-issues-reopen "ogent-issues")
(declare-function ogent-issues-start "ogent-issues")
(declare-function ogent-issues-comment "ogent-issues")
(declare-function ogent-issues-edit "ogent-issues-edit")
(declare-function ogent-issues-sync "ogent-issues")
(declare-function ogent-issues-filter-status "ogent-issues")
(declare-function ogent-issues-filter-type "ogent-issues")
(declare-function ogent-issues-filter-priority "ogent-issues")
(declare-function ogent-issues-clear-filters "ogent-issues")
(declare-function ogent-issues-view-list "ogent-issues")
(declare-function ogent-issues-view-ready "ogent-issues")
(declare-function ogent-issues-view-kanban "ogent-issues-kanban")
(declare-function ogent-issues-view-deps "ogent-issues-kanban")

(defvar ogent-issues--current-view)
(defvar ogent-issues--filters)
(defvar ogent-issues--issues)

;;; Context Capture

(defvar-local ogent-issues-create--context nil
  "Captured context from the buffer where issue creation was initiated.")

(defun ogent-issues--capture-context ()
  "Capture context from current buffer for issue creation.
Returns a plist with :file, :line, :function, and :formatted keys."
  (let* ((file (buffer-file-name))
         (line (line-number-at-pos))
         (func (ignore-errors (which-function)))
         (project-root (ignore-errors
                         (when-let ((proj (project-current)))
                           (project-root proj))))
         (relative-file (when (and file project-root)
                          (file-relative-name file project-root)))
         (formatted (when file
                      (concat (or relative-file (file-name-nondirectory file))
                              ":" (number-to-string line)
                              (when func (format " (%s)" func))))))
    (when file
      (list :file (or relative-file file)
            :line line
            :function func
            :formatted formatted))))

(defun ogent-issues--format-context-for-description (context)
  "Format CONTEXT plist as markdown for issue description."
  (when context
    (let ((file (plist-get context :file))
          (line (plist-get context :line))
          (func (plist-get context :function)))
      (concat "**Context:** `" file ":" (number-to-string line) "`"
              (when func (format " in `%s`" func))
              "\n\n"))))

;;; Header Formatting

(defvar ogent-issues-transient--cached-stats nil
  "Cached stats for transient header, updated on each open.")

(defun ogent-issues-transient--refresh-stats ()
  "Refresh cached stats for transient display."
  (when-let ((issues ogent-issues--issues))
    (let ((open 0) (in-progress 0) (blocked 0) (closed 0) (ready 0))
      (dolist (issue issues)
        (let ((status (plist-get issue :status)))
          (pcase status
            ("open" (cl-incf open)
             (when (ogent-issues--issue-ready-p issue)
               (cl-incf ready)))
            ("in_progress" (cl-incf in-progress))
            ("blocked" (cl-incf blocked))
            ("closed" (cl-incf closed)))))
      (setq ogent-issues-transient--cached-stats
            (list :open open :in-progress in-progress :blocked blocked
                  :closed closed :ready ready :total (length issues))))))

(defun ogent-issues-transient--format-header ()
  "Format header showing project stats and current issue context."
  (ogent-issues-transient--refresh-stats)
  (let* ((project (or (ignore-errors (ogent-issues-bd-project-name)) "unknown"))
         (stats ogent-issues-transient--cached-stats)
         (issue (ignore-errors (ogent-issues--current-issue)))
         (id (when issue (plist-get issue :id)))
         (title (when issue (plist-get issue :title)))
         (status (when issue (plist-get issue :status)))
         (view (symbol-name (or ogent-issues--current-view 'list))))
    (concat
     (propertize "Issues" 'face 'transient-heading)
     " "
     (propertize project 'face 'transient-value)
     " "
     (propertize (format "[%s]" (capitalize view)) 'face 'transient-inactive-value)
     ;; Stats line
     (when stats
       (concat
        "\n"
        (propertize (format "%d ready" (or (plist-get stats :ready) 0))
                    'face (if (> (or (plist-get stats :ready) 0) 0)
                              'success 'transient-inactive-value))
        (propertize " | " 'face 'transient-inactive-value)
        (propertize (format "%d open" (or (plist-get stats :open) 0))
                    'face 'transient-inactive-value)
        (propertize " | " 'face 'transient-inactive-value)
        (propertize (format "%d in-progress" (or (plist-get stats :in-progress) 0))
                    'face 'transient-inactive-value)
        (when (> (or (plist-get stats :blocked) 0) 0)
          (concat
           (propertize " | " 'face 'transient-inactive-value)
           (propertize (format "%d blocked" (plist-get stats :blocked))
                       'face 'warning)))))
     ;; Current issue context
     (when id
       (concat "\n"
               (propertize "At: " 'face 'transient-inactive-argument)
               (propertize id 'face 'transient-argument)
               " "
               (propertize (or status "") 'face 'transient-inactive-value)
               " "
               (truncate-string-to-width (or title "") 40 nil nil "…"))))))

;;; Main Dispatch Menu

;;;###autoload (autoload 'ogent-issues-dispatch "ogent-issues-transient" nil t)
(transient-define-prefix ogent-issues-dispatch ()
  "Dispatch menu for ogent-issues."
  [:description ogent-issues-transient--format-header
                ["Navigation"
                 ("n" "Next issue" ogent-issues-next-issue :transient t)
                 ("p" "Previous issue" ogent-issues-prev-issue :transient t)
                 ("N" "Next ready" ogent-issues-next-ready :transient t)
                 ("RET" "View details" ogent-issues-visit)
                 ("TAB" "Toggle section" ogent-issues-toggle-section :transient t)]
                ["Actions"
                 ("c" "Create issue" ogent-issues-create-dispatch)
                 ("e" "Edit issue" ogent-issues-edit)
                 ("s" "Start working" ogent-issues-start)
                 ("K" "Close issue" ogent-issues-close)
                 ("R" "Reopen issue" ogent-issues-reopen)
                 ("C" "Add comment" ogent-issues-comment)]]
  [["Filters"
    ("fs" "By status" ogent-issues-filter-status)
    ("ft" "By type" ogent-issues-filter-type)
    ("fp" "By priority" ogent-issues-filter-priority)
    ("fx" "Clear filters" ogent-issues-clear-filters)]
   ["Views"
    ("vl" "List view" ogent-issues-view-list)
    ("vr" "Ready work" ogent-issues-view-ready)
    ("vk" "Kanban board" ogent-issues-view-kanban)
    ("vd" "Dependencies" ogent-issues-view-deps)]]
  [["Sync"
    ("g" "Refresh" ogent-issues-refresh :transient t)
    ("G" "Force refresh" ogent-issues-refresh-force :transient t)
    ("S" "Run br sync" ogent-issues-sync)]
   ["Quit"
    ("q" "Quit menu" transient-quit-one)
    ("Q" "Quit buffer" quit-window)]])

;;; Create Issue Transient

(transient-define-prefix ogent-issues-create-dispatch ()
  "Create a new issue."
  ["Options"
   ("-t" "Type" "--type="
    :choices ("task" "bug" "feature" "chore" "epic")
    :init-value (lambda (obj) (oset obj value "task")))
   ("-p" "Priority" "--priority="
    :choices ("0" "1" "2" "3")
    :init-value (lambda (obj) (oset obj value "2")))]
  ["Create"
   ("c" "Quick create (title only)" ogent-issues-create-quick)
   ("C" "Full create (with description)" ogent-issues-create-full)
   ("e" "Create epic with subtasks" ogent-issues-create-epic)]
  ["Cancel"
   ("q" "Cancel" transient-quit-one)])

(defun ogent-issues-create-quick ()
  "Create issue with just a title, using transient options.
Automatically captures context (file, line) if invoked from a file buffer."
  (interactive)
  (let* ((args (transient-args 'ogent-issues-create-dispatch))
         (type (or (transient-arg-value "--type=" args) "task"))
         (priority (string-to-number (or (transient-arg-value "--priority=" args) "2")))
         (context (ogent-issues--capture-context))
         (title (read-string "Issue title: ")))
    (when (string-empty-p title)
      (user-error "Title cannot be empty"))
    (ogent-issues-bd-create title
                            (lambda (result)
                              (message "Created: %s%s"
                                       (plist-get result :id)
                                       (if context " (with context)" ""))
                              (ogent-issues-refresh))
                            :type type
                            :priority priority
                            :description (when context
                                           (ogent-issues--format-context-for-description context)))))

(defun ogent-issues-create-full ()
  "Create issue with full description in a buffer.
Captures context (file, line, function) from the current buffer."
  (interactive)
  (let* ((args (transient-args 'ogent-issues-create-dispatch))
         (type (or (transient-arg-value "--type=" args) "task"))
         (priority (or (transient-arg-value "--priority=" args) "2"))
         (context (ogent-issues--capture-context))
         (buf (get-buffer-create "*ogent-issue-create*")))
    (with-current-buffer buf
      (erase-buffer)
      (ogent-issues-create-mode)
      (setq-local ogent-issues-create--context context)
      (insert "# New Issue\n\n")
      (insert "Title: \n")
      (insert (format "Type: %s\n" type))
      (insert (format "Priority: %s\n" priority))
      (insert "Labels: \n")
      (insert "Parent: \n")
      (insert "\n## Description\n\n")
      ;; Insert context if captured
      (when context
        (insert (ogent-issues--format-context-for-description context)))
      (insert "\n\n")
      (insert "<!-- C-c C-c to create, C-c C-k to cancel -->\n")
      (goto-char (point-min))
      (search-forward "Title: "))
    (pop-to-buffer buf)))

(defun ogent-issues-create-epic ()
  "Create an epic with subtasks."
  (interactive)
  (let* ((title (read-string "Epic title: "))
         (description (read-string "Description: "))
         (subtasks-input (read-string "Subtasks (comma-separated): "))
         (subtasks (mapcar #'string-trim (split-string subtasks-input ","))))
    (when (string-empty-p title)
      (user-error "Title cannot be empty"))
    ;; For now, create epic as a regular issue with subtasks in description
    ;; Full epic support requires br CLI epic creation
    (let ((full-desc (concat description "\n\n## Subtasks\n"
                             (mapconcat (lambda (s) (format "- [ ] %s" s))
                                        subtasks "\n"))))
      (ogent-issues-bd-create title
                              (lambda (result)
                                (message "Created epic: %s with %d subtasks"
                                         (plist-get result :id)
                                         (length subtasks))
                                (ogent-issues-refresh))
                              :type "epic"
                              :priority 1
                              :description full-desc))))

;;; Create Mode for Full Issue Creation

(defvar ogent-issues-create-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ogent-issues-create-submit)
    (define-key map (kbd "C-c C-k") #'ogent-issues-create-cancel)
    map)
  "Keymap for `ogent-issues-create-mode'.")

(define-derived-mode ogent-issues-create-mode text-mode "Issue-Create"
  "Mode for creating issues with full description."
  (setq-local header-line-format
              '(" Create Issue | C-c C-c: submit | C-c C-k: cancel")))

(defun ogent-issues-create-submit ()
  "Submit the issue from the create buffer."
  (interactive)
  (let ((content (buffer-string)))
    ;; Parse the buffer content
    (let ((title nil)
          (type "task")
          (priority 2)
          (description nil))
      ;; Extract title
      (when (string-match "^Title: \\(.+\\)$" content)
        (setq title (string-trim (match-string 1 content))))
      ;; Extract type
      (when (string-match "^Type: \\(.+\\)$" content)
        (setq type (string-trim (match-string 1 content))))
      ;; Extract priority
      (when (string-match "^Priority: \\([0-3]\\)" content)
        (setq priority (string-to-number (match-string 1 content))))
      ;; Extract description (everything after ## Description)
      (when (string-match "## Description\n\n\\(\\(?:.\\|\n\\)*?\\)\n\n<!--" content)
        (setq description (string-trim (match-string 1 content))))
      ;; Validate
      (unless (and title (not (string-empty-p title)))
        (user-error "Title is required"))
      ;; Create the issue
      (ogent-issues-bd-create title
                              (lambda (result)
                                (message "Created: %s" (plist-get result :id))
                                (kill-buffer)
                                (when-let ((buf (get-buffer "*ogent-issues*")))
                                  (with-current-buffer buf
                                    (ogent-issues-refresh))))
                              :type type
                              :priority priority
                              :description description))))

(defun ogent-issues-create-cancel ()
  "Cancel issue creation."
  (interactive)
  (when (yes-or-no-p "Cancel issue creation? ")
    (kill-buffer)))

;;; Filter Transient

(transient-define-prefix ogent-issues-filter-dispatch ()
  "Filter issues."
  :value '("--status=open")
  ["Filters"
   ("-s" "Status" "--status="
    :choices ("all" "open" "in_progress" "blocked" "closed"))
   ("-t" "Type" "--type="
    :choices ("all" "bug" "feature" "task" "epic" "chore"))
   ("-p" "Priority" "--priority="
    :choices ("all" "0" "1" "2" "3"))]
  ["Actions"
   ("RET" "Apply filters" ogent-issues-filter-apply)
   ("x" "Clear all" ogent-issues-clear-filters)
   ("q" "Cancel" transient-quit-one)])

(defun ogent-issues-filter-apply ()
  "Apply filters from transient arguments."
  (interactive)
  (let* ((args (transient-args 'ogent-issues-filter-dispatch))
         (status (transient-arg-value "--status=" args))
         (type (transient-arg-value "--type=" args))
         (priority (transient-arg-value "--priority=" args)))
    ;; Apply each filter if not "all"
    (when (and status (not (string= status "all")))
      (ogent-issues-filter-status status))
    (when (and type (not (string= type "all")))
      (ogent-issues-filter-type type))
    (when (and priority (not (string= priority "all")))
      (ogent-issues-filter-priority priority))))

(provide 'ogent-issues-transient)

;;; ogent-issues-transient.el ends here
