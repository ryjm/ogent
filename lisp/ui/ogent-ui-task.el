;;; ogent-ui-task.el --- Native review of delegated work -*- lexical-binding: t; -*-

;;; Commentary:
;; Review a task patch with ordinary diff navigation and anchored feedback.

;;; Code:

(require 'ogent-task)
(require 'ogent-keys)
(require 'ogent-ui-layout)

(defvar ogent-task-patch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ogent-task-apply)
    (define-key map (kbd "C-c C-m") #'ogent-task-comment)
    (define-key map (kbd "C-c C-r") #'ogent-task-revise)
    (define-key map (kbd "C-c C-k") #'ogent-task-reject)
    (define-key map (kbd "C-c C-o") #'ogent-task-result)
    (define-key map (kbd "g") #'ogent-task-patch-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for delegated task patch review.")

(define-derived-mode ogent-task-patch-mode diff-mode "TaskPatch"
  "Review a patch returned to an Org TODO."
  (setq-local buffer-read-only t)
  (ogent-ui-layout-configure))

(ogent-evil-setup-display-mode 'ogent-task-patch-mode ogent-task-patch-mode-map
                               'ogent-task-patch-mode-hook
                               :refresh #'ogent-task-patch-refresh)

;;;###autoload
(defun ogent-task-review ()
  "Open the proposed patch attached to the current Org TODO."
  (interactive)
  (let* ((file (ogent-task--current-file))
         (record (ogent-task--read file))
         (buffer (get-buffer-create (format "*ogent-task:%s*" (plist-get record :id)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ogent-task-patch-mode) (ogent-task-patch-mode))
      (setq-local ogent-task-patch--file file)
      (setq-local default-directory (file-name-as-directory (plist-get record :workspace)))
      (ogent-task-patch-refresh))
    (pop-to-buffer buffer)))

(defun ogent-task-patch-refresh ()
  "Refresh the task patch while retaining point and the current window."
  (interactive)
  (let* ((record (ogent-task--read ogent-task-patch--file))
         (patch (ogent-task--file record "patch.diff"))
         (position (point))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (plist-get record :title) 'face 'bold) "\n"
            "State: " (plist-get record :status) "   Checks: "
            (plist-get record :checks) "\n"
            "C-c C-c apply   C-c C-m comment   C-c C-r revise\n"
            "C-c C-k reject   C-c C-o result and logs   q return\n\n")
    (if (and (file-readable-p patch)
             (> (file-attribute-size (file-attributes patch)) 0))
        (insert-file-contents patch)
      (insert (if (member (plist-get record :status) '("running" "checking"))
                  "Work is still running. Refresh to inspect the result.\n"
                "This run proposed no file changes. Open its result for details.\n")))
    (goto-char (min position (point-max)))))

(defun ogent-task-result ()
  "Visit the task record with its check output and conversation links."
  (interactive)
  (let* ((file (ogent-task--current-file))
         (record (ogent-task--read file))
         (conversation (ogent-armory-conversation-file
                        (plist-get record :root) (plist-get record :conversation))))
    (find-file file)
    (goto-char (point-min))
    (message "ogent: %s; checks %s; conversation %s"
             (plist-get record :status) (plist-get record :checks) conversation)))

(provide 'ogent-ui-task)
;;; ogent-ui-task.el ends here
