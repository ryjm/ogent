;;; ogent-ui-workbench.el --- Passage review reader -*- lexical-binding: t; -*-

;;; Commentary:
;; Show full comments with context, native navigation, and revision actions.

;;; Code:

(require 'ogent-workbench)
(require 'ogent-keys)
(require 'ogent-ui-layout)
(require 'ogent-ui-section)
(require 'transient)

(autoload 'ogent-task-delegate "ogent-task" nil t)
(autoload 'ogent-task-review "ogent-ui-task" nil t)
(autoload 'ogent-task-revise "ogent-task" nil t)
(autoload 'ogent-task-cancel "ogent-task" nil t)
(autoload 'ogent-task-apply "ogent-task" nil t)
(autoload 'ogent-task-reject "ogent-task" nil t)

(defvar-local ogent-workbench--source nil
  "Source buffer associated with this comment reader.")

(defvar-local ogent-workbench--summary nil
  "Current comment counts for the reader header.")

(defvar ogent-workbench-comments-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-workbench-comment-visit)
    (define-key map (kbd "n") #'ogent-workbench-comment-next)
    (define-key map (kbd "p") #'ogent-workbench-comment-previous)
    (define-key map (kbd "r") #'ogent-workbench-comments-revise)
    (define-key map (kbd "e") #'ogent-workbench-comment-review)
    (define-key map (kbd "d") #'ogent-workbench-comment-dismiss)
    (define-key map (kbd "g") #'ogent-workbench-comments-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for the passage comment reader.")

(define-derived-mode ogent-workbench-comments-mode special-mode "WorkReview"
  "Read comments attached to editable work."
  (ogent-ui-layout-configure)
  (setq-local header-line-format
              '(:eval (ogent-section-header-line
                       "Review" ogent-workbench--summary
                       '("RET" . "passage") '("e" . "proposal")
                       '("g" . "refresh") '("q" . "return")))))

(ogent-evil-setup-display-mode 'ogent-workbench-comments-mode
                               ogent-workbench-comments-mode-map
                               'ogent-workbench-comments-mode-hook
                               :refresh #'ogent-workbench-comments-refresh)

;;;###autoload
(defun ogent-workbench-comments ()
  "Display full passage comments for the current source."
  (interactive)
  (let* ((source (if (derived-mode-p 'ogent-workbench-comments-mode)
                     ogent-workbench--source (current-buffer)))
         (buffer (get-buffer-create
                  (format "*ogent-review:%s*" (buffer-name source)))))
    (with-current-buffer source (ogent-workbench--load))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ogent-workbench-comments-mode)
        (ogent-workbench-comments-mode))
      (setq-local ogent-workbench--source source)
      (ogent-workbench-comments-refresh))
    (pop-to-buffer buffer)))

(defun ogent-workbench-comments-refresh ()
  "Refresh comments while retaining the selected passage and viewport."
  (interactive)
  (unless (buffer-live-p ogent-workbench--source) (user-error "Source buffer was closed"))
  (let ((records (buffer-local-value 'ogent-workbench--records ogent-workbench--source))
        (inhibit-read-only t))
    (ogent-ui-layout-preserve-location 'ogent-comment
      (erase-buffer)
      (setq ogent-workbench--summary
            (let ((states (mapcar #'ogent-workbench-comments--state records)))
              (or (when states
                    (string-join
                     (cl-loop for status in '("open" "proposed" "stale" "kept" "dismissed")
                              for count = (cl-count status states :test #'equal)
                              when (> count 0) collect (format "%d %s" count status)) " / "))
                  "No comments")))
      (insert (propertize (buffer-name ogent-workbench--source)
                          'font-lock-face 'ogent-theme-section-heading) "\n"
			  ogent-workbench--summary "\n"
			  "n/p comments   RET passage   e proposal\n"
			  "r revise open comments   d dismiss or release keep\n\n")
      (if (null records)
          (insert "No passage comments yet. Return with q, select text,\n"
                  "and use C-c . C-l to add a comment.\n")
        (cl-loop for record in (reverse records) for number from 1 do
                 (ogent-workbench-comments--insert record number))))
    (set-buffer-modified-p nil)))

(defun ogent-workbench-comments--state (record)
  "Return RECORD's visible state, including changed or ambiguous anchors."
  (let ((status (plist-get record :status)))
    (if (and (not (equal status "dismissed"))
             (with-current-buffer ogent-workbench--source
               (condition-case nil
                   (progn (ogent-workbench--anchor record) nil)
                 (user-error t))))
        "stale" status)))

(defun ogent-workbench-comments--insert (record number)
  "Insert full feedback RECORD with its NUMBER and recoverable state."
  (let* ((start (point))
         (status (plist-get record :status))
         (stale (equal (ogent-workbench-comments--state record) "stale"))
         (face (cond (stale 'ogent-theme-warning)
                     ((equal status "kept") 'ogent-theme-success)
                     ((equal status "dismissed") 'ogent-theme-muted)
                     (t 'ogent-theme-primary))))
    (insert (propertize (format "%02d  %s" number (upcase (if stale "stale" status)))
                        'font-lock-face face) "\n")
    (when stale
      (insert "Source changed or is ambiguous. Mark the passage again.\n"
              (if (equal status "proposed")
                  "Reject the pending proposal with e before dismissing this comment.\n"
                "Dismiss this saved comment when it is no longer needed.\n")))
    (when (equal status "proposed")
      (insert "e reviews this replacement; accept or reject in the diff.\n"))
    (when (equal status "kept")
      (insert "Protected from revision. d releases this keep marker.\n"))
    (insert (propertize "Comment\n" 'font-lock-face 'ogent-theme-section-heading)
            (plist-get record :note) "\n\n"
            (propertize "Passage\n" 'font-lock-face 'ogent-theme-muted)
            (plist-get record :text) "\n")
    (when-let ((draft (plist-get record :draft)))
      (insert "\n" (propertize (if (equal status "proposed")
                                   "Proposed replacement\n" "Saved draft\n")
                               'font-lock-face 'ogent-theme-section-heading)
              draft "\n"))
    (insert "\n")
    (add-text-properties start (point) (list 'ogent-comment record))))

(defun ogent-workbench-comment-review ()
  "Open the live replacement proposal for the comment at point."
  (interactive)
  (let* ((record (get-text-property (point) 'ogent-comment))
         (edit (plist-get record :proposal)))
    (unless (and (equal (plist-get record :status) "proposed") edit)
      (user-error "This comment has no pending proposal; revise open comments with r"))
    (pop-to-buffer (ogent-edit-diff-show (list edit)))))

(defun ogent-workbench-comment-visit ()
  "Visit the exact passage of the comment at point."
  (interactive)
  (let ((record (get-text-property (point) 'ogent-comment))
        (source ogent-workbench--source))
    (unless record (user-error "Move to a comment"))
    (let ((bounds (with-current-buffer source (ogent-workbench--anchor record))))
      (pop-to-buffer source)
      (goto-char (car bounds))
      (push-mark (cdr bounds) t t))))

(defun ogent-workbench-comment-next ()
  "Move to the next comment."
  (interactive)
  (goto-char (next-single-property-change (point) 'ogent-comment nil (point-max)))
  (unless (get-text-property (point) 'ogent-comment)
    (goto-char (next-single-property-change (point) 'ogent-comment nil (point-max)))))

(defun ogent-workbench-comment-previous ()
  "Move to the previous comment."
  (interactive)
  (when (get-text-property (point) 'ogent-comment)
    (goto-char (or (previous-single-property-change (point) 'ogent-comment) (point-min))))
  (unless (get-text-property (point) 'ogent-comment)
    (goto-char (or (previous-single-property-change (point) 'ogent-comment) (point-min)))))

(defun ogent-workbench-comment-dismiss ()
  "Dismiss the comment at point without changing its source passage."
  (interactive)
  (let ((record (get-text-property (point) 'ogent-comment)))
    (unless record (user-error "Move to a comment"))
    (when (equal (plist-get record :status) "proposed")
      (user-error "Accept or reject the pending proposal before dismissing"))
    (plist-put record :status "dismissed")
    (ogent-workbench--write record)
    (with-current-buffer ogent-workbench--source (ogent-workbench--decorate record))
    (ogent-workbench-comments-refresh)))

(defun ogent-workbench-comments-revise ()
  "Revise open comments in the originating source."
  (interactive)
  (with-current-buffer ogent-workbench--source (ogent-workbench-revise)))

;;;###autoload (autoload 'ogent-work-menu "ogent-ui-workbench" nil t)
(transient-define-prefix ogent-work-menu ()
  "Review passages or delegate the current Org TODO."
  [["Passages"
    ("c" "Comment on selection" ogent-workbench-comment)
    ("k" "Keep selection unchanged" ogent-workbench-keep)
    ("r" "Revise all open comments" ogent-workbench-revise)
    ("l" "Read comments" ogent-workbench-comments)]
   ["Org TODO"
    ("d" "Delegate task" ogent-task-delegate)
    ("p" "Review patch" ogent-task-review)
    ("a" "Apply reviewed patch" ogent-task-apply)
    ("X" "Reject patch" ogent-task-reject)
    ("R" "Revise task patch" ogent-task-revise)
    ("x" "Cancel run or checks" ogent-task-cancel)]])

(provide 'ogent-ui-workbench)
;;; ogent-ui-workbench.el ends here
