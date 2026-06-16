;;; ogent-issues-kanban.el --- Kanban and dependency-graph views for ogent-issues -*- lexical-binding: t; -*-

;;; Commentary:
;; Kanban board view and dependency-graph entry points for ogent-issues,
;; extracted from the ogent-issues facade.  Required by the facade at load
;; time so `(require 'ogent-issues)' still loads these views.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ogent-issues-bd)

;; Core ogent-issues helpers and buffer-local state referenced below live in
;; the facade (`ogent-issues').  Declare them here so this file byte-compiles
;; on its own; it avoids requiring the facade to keep the load graph acyclic.
(declare-function ogent-issues--start-loading "ogent-issues")
(declare-function ogent-issues--stop-loading "ogent-issues")
(declare-function ogent-issues--group-by-status "ogent-issues")
(declare-function ogent-issues--status-face "ogent-issues")
(declare-function ogent-issues--current-issue "ogent-issues")
(declare-function ogent-issues--current-issue-id "ogent-issues")
(declare-function ogent-issues-refresh "ogent-issues")
(defvar ogent-issues--source-directory)
(defvar ogent-issues--current-view)
(defvar ogent-issues--issues)
(defvar ogent-issues-use-unicode)

;; Load graph visualization if available
(declare-function ogent-issues-graph-view "ogent-issues-graph" (&optional issue-id) t)
(autoload 'ogent-issues-graph-view "ogent-issues-graph" nil t)

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
  (let ((buf (current-buffer)))
    (ogent-issues--start-loading)
    (ogent-issues-bd-list
     (lambda (issues)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-issues--stop-loading)
           (setq ogent-issues--issues issues)
           (let ((inhibit-read-only t))
             (erase-buffer)
             (ogent-issues--insert-kanban-board issues)
             (goto-char (point-min))))))
     nil  ; no filters
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-issues--stop-loading)))
       (message "Failed to fetch issues for Kanban: %s" err)))))

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
  "Insert horizontal separator for Kanban board, each column COL-WIDTH wide."
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
      ;; Use br CLI to update status
      (ogent-issues-bd-update id
			      (lambda ()
				(message "Moved %s to %s" id new-status)
				(ogent-issues-refresh))
			      :status new-status)))))

(defun ogent-issues--ensure-sibling-loadpath ()
  "Ensure the directory containing ogent-issues sibling files is in `load-path'.
This guards against `load-path' modifications after initial load."
  (when (and ogent-issues--source-directory
             (not (member ogent-issues--source-directory load-path)))
    (add-to-list 'load-path ogent-issues--source-directory)))

(defun ogent-issues-view-deps ()
  "Switch to dependency graph view."
  (interactive)
  (ogent-issues--ensure-sibling-loadpath)
  (require 'ogent-issues-graph)
  (if-let ((id (ogent-issues--current-issue-id)))
      (ogent-issues-graph-view id)
    (ogent-issues-graph-view)))

(defun ogent-issues-view-deps-current ()
  "View dependency graph centered on current issue."
  (interactive)
  (ogent-issues--ensure-sibling-loadpath)
  (require 'ogent-issues-graph)
  (if-let ((id (ogent-issues--current-issue-id)))
      (ogent-issues-graph-view id)
    (user-error "No issue at point")))

(provide 'ogent-issues-kanban)

;;; ogent-issues-kanban.el ends here
