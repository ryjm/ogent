;;; ogent-ui-task.el --- Native review of delegated work -*- lexical-binding: t; -*-

;;; Commentary:
;; Review a task patch with ordinary diff navigation and anchored feedback.

;;; Code:

(require 'ogent-task)
(require 'ogent-keys)
(require 'ogent-ui-layout)
(require 'ogent-ui-section)

(defvar-local ogent-task-patch--record nil
  "Durable record currently displayed in this reader.")

(defvar ogent-task-patch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'ogent-task-patch-apply)
    (define-key map (kbd "C-c C-m") #'ogent-task-comment)
    (define-key map (kbd "C-c C-r") #'ogent-task-patch-revise)
    (define-key map (kbd "C-c C-k") #'ogent-task-patch-reject)
    (define-key map (kbd "C-c C-x") #'ogent-task-patch-cancel)
    (define-key map (kbd "C-c C-v") #'ogent-task-check-output)
    (define-key map (kbd "C-c C-n") #'ogent-task-patch-next-hunk)
    (define-key map (kbd "C-c C-p") #'ogent-task-patch-previous-hunk)
    (define-key map (kbd "n") #'ogent-task-patch-next-hunk)
    (define-key map (kbd "p") #'ogent-task-patch-previous-hunk)
    (define-key map (kbd "C-c C-o") #'ogent-task-result)
    (define-key map (kbd "g") #'ogent-task-patch-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for delegated task patch review.")

(define-derived-mode ogent-task-patch-mode diff-mode "TaskPatch"
  "Review a patch returned to an Org TODO."
  (setq-local buffer-read-only t)
  (ogent-ui-layout-configure)
  (setq-local header-line-format
              '(:eval (ogent-section-header-line
                       "Task patch" (plist-get ogent-task-patch--record :status)
                       '("C-c C-v" . "checks") '("g" . "refresh") '("q" . "return")))))

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
  "Refresh the task patch while retaining its selected hunk and viewport."
  (interactive)
  (let* ((record (ogent-task--read ogent-task-patch--file))
         (patch (ogent-task--file record "patch.diff"))
         (has-patch (and (file-readable-p patch)
                         (> (file-attribute-size (file-attributes patch)) 0)))
         (inhibit-read-only t))
    (ogent-ui-layout-preserve-location 'ogent-task-location
      (erase-buffer)
      (setq ogent-task-patch--record record)
      (ogent-task-patch--insert-summary record has-patch)
      (insert "\n" (propertize
                    (if (and has-patch (member (plist-get record :status) '("running" "checking")))
                        "Previous proposed changes (revision in progress)\n"
                      "Proposed changes\n")
                    'font-lock-face 'ogent-theme-section-heading))
      (if has-patch
          (let ((start (point)))
            (insert-file-contents patch)
            (ogent-task-patch--mark-locations start))
        (insert (if (member (plist-get record :status) '("running" "checking"))
                    "Work is still running. Refresh to inspect the result.\n"
                  "This run proposed no file changes. Open its result for details.\n"))))
    (set-buffer-modified-p nil)))

(defun ogent-task-patch--insert-summary (record has-patch)
  "Insert RECORD context, verification and available actions for HAS-PATCH."
  (let* ((status (plist-get record :status))
         (checks (plist-get record :checks))
         (active (member status '("running" "checking")))
         (applied (equal status "applied")))
    (insert (propertize (plist-get record :title) 'font-lock-face 'ogent-theme-section-heading)
            "\nState: "
            (propertize status 'font-lock-face
                        (cond ((member status '("failed" "check-failed")) 'ogent-theme-error)
                              (applied 'ogent-theme-success)
                              (t 'ogent-theme-info)))
            "   Checks: "
            (propertize checks 'font-lock-face
                        (cond ((equal checks "passed") 'ogent-theme-success)
                              ((equal checks "failed") 'ogent-theme-error)
                              ((equal checks "running") 'ogent-theme-info)
                              (t 'ogent-theme-warning))) "\n"
            "Workspace: " (plist-get record :workspace) "\n"
            "Agent: " (plist-get record :agent)
            "   Model: " (let ((model (plist-get record :model)))
                           (if (string-empty-p (or model "")) "runner default" model)) "\n\n"
            (cond
             (active "Work is in progress. Refresh here or cancel the run.\n")
             (applied "Patch applied. Return to your TODO and decide whether it is done.\n")
             ((equal status "rejected") "Patch rejected. Its artifacts remain available for review or revision.\n")
             ((equal status "cancelled") "Run cancelled. Partial changes remain available for review or revision.\n")
             ((equal status "failed") "Task failed. Inspect its result before using any partial changes.\n")
             ((equal checks "failed") "Checks failed. Read the output before deciding what to keep.\n")
             ((not (equal checks "passed")) "Checks were not run. Review the changes and verification command.\n")
             (has-patch "Review the changes, then apply or comment for a revision.\n")
             (t "No changes to apply. Open the result or request a revision.\n")))
    (cond
     (active (insert "C-c C-x cancel run or checks\n"))
     (applied nil)
     (t
      (when (and has-patch (not (member status '("rejected" "cancelled"))))
        (insert "C-c C-c apply complete patch   C-c C-k reject\n"))
      (when has-patch (insert "C-c C-m comment on hunk   "))
      (insert "C-c C-r revise\n")))
    (insert "C-c C-v check output   C-c C-o full result\n"
            (if (and (keymapp (key-binding (kbd "g")))
                     (commandp (key-binding (kbd "g r")))) "gr" "g")
            " refresh   n/p hunks   q return\n")))

(defun ogent-task-patch-next-hunk ()
  "Move to the next patch hunk, including from the task summary."
  (interactive)
  (let ((position (point))
        (start (text-property-not-all (point-min) (point-max) 'ogent-task-location nil)))
    (unless start (user-error "This task has no patch hunks"))
    (goto-char (max (point) start))
    (when (looking-at "^@@ ") (forward-line 1))
    (if (re-search-forward "^@@ " nil t)
        (beginning-of-line)
      (goto-char position)
      (user-error "No later patch hunk"))))

(defun ogent-task-patch-previous-hunk ()
  "Move to the previous patch hunk without entering the task summary."
  (interactive)
  (let ((position (point))
        (start (text-property-not-all (point-min) (point-max) 'ogent-task-location nil)))
    (unless start (user-error "This task has no patch hunks"))
    (if (and (> (point) start) (re-search-backward "^@@ " start t))
        (beginning-of-line)
      (goto-char position)
      (user-error "No earlier patch hunk"))))

(defun ogent-task-patch--mark-locations (start)
  "Mark stable file and hunk locations in the diff beginning at START."
  (save-excursion
    (goto-char start)
    (let (file location)
      (while (not (eobp))
        (cond
         ((looking-at "diff --git .+")
          (setq file (match-string-no-properties 0) location (list file)))
         ((looking-at "@@.+")
          (setq location (list file (match-string-no-properties 0)))))
        (let ((begin (point)))
          (forward-line 1)
          (when location
            (put-text-property begin (point) 'ogent-task-location location)))))))

(defun ogent-task-patch--act (command)
  "Run task COMMAND and immediately refresh its review state."
  (let ((result (call-interactively command)))
    (ogent-task-patch-refresh)
    result))

(defun ogent-task-patch-apply ()
  "Apply the complete task patch and show its updated review state."
  (interactive)
  (ogent-task-patch--act #'ogent-task-apply))

(defun ogent-task-patch-reject ()
  "Reject the task patch and show its updated review state."
  (interactive)
  (ogent-task-patch--act #'ogent-task-reject))

(defun ogent-task-patch-revise ()
  "Request a task revision and show its running state."
  (interactive)
  (ogent-task-patch--act #'ogent-task-revise))

(defun ogent-task-patch-cancel ()
  "Cancel task work and show its retained review state."
  (interactive)
  (ogent-task-patch--act #'ogent-task-cancel))

(defvar ogent-task-check-output-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ogent-task-check-output-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for full task verification output.")

(define-derived-mode ogent-task-check-output-mode special-mode "TaskChecks"
  "Read full verification output without editing the saved artifact."
  (ogent-ui-layout-configure)
  (setq-local header-line-format
              '(:eval (ogent-section-header-line
                       "Task checks" nil '("g" . "refresh") '("q" . "return")))))

(ogent-evil-setup-display-mode 'ogent-task-check-output-mode ogent-task-check-output-mode-map
                               'ogent-task-check-output-mode-hook
                               :refresh #'ogent-task-check-output-refresh)

(defun ogent-task-check-output ()
  "Read the task's full check command, exit status and saved output."
  (interactive)
  (let* ((file (ogent-task--current-file))
         (record (ogent-task--read file))
         (buffer (get-buffer-create (format "*ogent-checks:%s*" (plist-get record :id)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ogent-task-check-output-mode) (ogent-task-check-output-mode))
      (setq-local ogent-task-patch--file file)
      (ogent-task-check-output-refresh))
    (pop-to-buffer buffer)))

(defun ogent-task-check-output-refresh ()
  "Refresh saved verification output without moving the reader's point."
  (interactive)
  (let* ((record (ogent-task--read ogent-task-patch--file))
         (log (ogent-task--file record "checks.log"))
         (position (point))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (plist-get record :title) 'font-lock-face 'ogent-theme-section-heading)
            "\nChecks: " (plist-get record :checks)
            "   Exit: " (let ((exit (plist-get record :check-exit)))
                          (if (and (member (plist-get record :checks) '("passed" "failed"))
                                   (not (string-empty-p (or exit ""))))
                              exit "not available")) "\n"
            "Command: " (let ((check (plist-get record :check)))
                          (if (string-empty-p (or check "")) "not configured" check))
            "\nWorktree: " (plist-get record :worktree) "\n\n")
    (cond
     ((equal (plist-get record :status) "checking")
      (insert "Checks are still running. Refresh after completion for their output.\n\n"))
     ((equal (plist-get record :status) "running")
      (insert "Waiting for the agent result. Checks have not started.\n\n")))
    (if (file-readable-p log) (insert-file-contents log)
      (insert "No saved check output is available.\n"))
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

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
