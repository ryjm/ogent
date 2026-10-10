;;; ogent-ui-workbench.el --- Passage review reader -*- lexical-binding: t; -*-

;;; Commentary:
;; Show full comments with context, native navigation, and revision actions.

;;; Code:

(require 'ogent-workbench)
(require 'ogent-keys)
(require 'ogent-ui-layout)
(require 'transient)

(autoload 'ogent-task-delegate "ogent-task" nil t)
(autoload 'ogent-task-review "ogent-ui-task" nil t)
(autoload 'ogent-task-revise "ogent-task" nil t)
(autoload 'ogent-task-cancel "ogent-task" nil t)
(autoload 'ogent-task-apply "ogent-task" nil t)
(autoload 'ogent-task-reject "ogent-task" nil t)

(defvar-local ogent-workbench--source nil
  "Source buffer associated with this comment reader.")

(defvar ogent-workbench-comments-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-workbench-comment-visit)
    (define-key map (kbd "n") #'ogent-workbench-comment-next)
    (define-key map (kbd "p") #'ogent-workbench-comment-previous)
    (define-key map (kbd "r") #'ogent-workbench-comments-revise)
    (define-key map (kbd "d") #'ogent-workbench-comment-dismiss)
    (define-key map (kbd "g") #'ogent-workbench-comments-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for the passage comment reader.")

(define-derived-mode ogent-workbench-comments-mode special-mode "WorkReview"
  "Read comments attached to editable work."
  (ogent-ui-layout-configure)
  (setq-local header-line-format
              '(:eval (ogent-ui-layout-header
                       "Review" nil '(("RET" . "passage") ("r" . "revise")
                                      ("d" . "dismiss") ("q" . "return"))))))

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
  "Refresh comments while retaining the selected comment."
  (interactive)
  (unless (buffer-live-p ogent-workbench--source) (user-error "Source buffer was closed"))
  (let ((selected (get-text-property (point) 'ogent-comment))
        (records (buffer-local-value 'ogent-workbench--records ogent-workbench--source))
        (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (buffer-name ogent-workbench--source) 'face 'bold) "\n\n")
    (if (null records)
        (insert "Select a passage and add a comment to start.\n")
      (dolist (record (reverse records))
        (let* ((start (point))
               (stale (with-current-buffer ogent-workbench--source
                        (condition-case nil
                            (progn (ogent-workbench--anchor record) nil)
                          (user-error t)))))
          (insert (propertize (upcase (if stale "stale" (plist-get record :status)))
                              'face (if stale 'warning 'font-lock-keyword-face))
                  "  " (plist-get record :note) "\n")
          (insert (propertize (plist-get record :text) 'face 'shadow) "\n\n")
          (add-text-properties start (point) (list 'ogent-comment record)))))
    (goto-char (point-min))
    (when selected
      (while (and (< (point) (point-max))
                  (not (eq selected (get-text-property (point) 'ogent-comment))))
        (goto-char (next-single-property-change (point) 'ogent-comment nil (point-max)))))))

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
