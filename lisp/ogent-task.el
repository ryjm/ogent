;;; ogent-task.el --- Delegate an Org TODO and review its patch -*- lexical-binding: t; -*-

;;; Commentary:
;; Attach isolated asynchronous Armory runs to ordinary Org headings.  Keep
;; original checkouts untouched until the user explicitly applies a patch.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'org)
(require 'org-id)
(require 'ogent-armory-runner)
(require 'ogent-workbench)

(declare-function ogent-task-review "ogent-ui-task")

(defgroup ogent-task nil
  "Work delegated from Org TODOs."
  :group 'ogent)

(defcustom ogent-task-directory
  (expand-file-name "ogent/tasks/" user-emacs-directory)
  "Directory for task Org records and isolated Git worktrees."
  :type 'directory
  :group 'ogent-task)

(defcustom ogent-task-check-command nil
  "Shell command run after a delegated task finishes.
An inherited OGENT_CHECK property overrides this default.  Nil records
checks as not run.  Commands execute asynchronously in the task worktree."
  :type '(choice (const nil) string)
  :group 'ogent-task)

(defvar-local ogent-task-patch--file nil
  "Task record associated with this patch buffer.")

(defvar ogent-task--active (make-hash-table :test #'equal)
  "Live task records, including their process and source marker.")

(defconst ogent-task--fields
  '(:id :title :workspace :worktree :baseline :root :agent :model :adapter
	:conversation :status :check :checks :check-exit :source :source-id)
  "Durable string-valued task fields stored in Org properties.")

(defun ogent-task--property (key)
  "Return the Org property name for task KEY."
  (concat "OGENT_TASK_" (upcase (substring (symbol-name key) 1))))

(defun ogent-task--git (directory &rest args)
  "Run Git ARGS in DIRECTORY and return exact output or signal an error."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory directory)))
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (user-error "Task Git operation failed: %s" (string-trim (buffer-string))))
      (buffer-string))))

(defun ogent-task--file (record name)
  "Return the path of artifact NAME beside RECORD."
  (expand-file-name name (file-name-directory (plist-get record :file))))

(defun ogent-task--write (record)
  "Persist RECORD without replacing its instruction or feedback."
  (let ((file (plist-get record :file)))
    (make-directory (file-name-directory file) t)
    (with-current-buffer (find-file-noselect file)
      (unless (derived-mode-p 'org-mode) (org-mode))
      (save-excursion
        (when (= (buffer-size) 0)
          (insert "#+title: " (plist-get record :title) "\n\n* "
                  (plist-get record :title) "\n\n** Task\n"
                  (ogent-workbench--src (plist-get record :instruction))
                  "\n** Review\n"
                  "[[file:patch.diff][Proposed changes]]\n"
                  "[[file:checks.log][Check output]]\n"
                  (when (plist-get record :conversation)
                    (concat "[[file:"
                            (org-link-escape
                             (ogent-armory-conversation-file
                              (plist-get record :root) (plist-get record :conversation)))
                            "][Conversation]]\n"))
                  (concat "[[id:" (plist-get record :source-id) "][Source TODO]]\n")
                  "\n** Feedback\n"))
        (goto-char (point-min))
        (org-next-visible-heading 1)
        (dolist (key ogent-task--fields)
          (org-entry-put (point) (ogent-task--property key)
                         (or (plist-get record key) "")))
        (when-let ((conversation (plist-get record :conversation)))
          (org-entry-put (point) "OGENT_CONVERSATION_FILE"
                         (ogent-armory-conversation-file
                          (plist-get record :root) conversation))))
      (save-buffer)))
  (when-let ((marker (plist-get record :source-marker)))
    (when (marker-buffer marker)
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          (when (org-at-heading-p)
            (org-entry-put (point) "OGENT_TASK_FILE" (plist-get record :file))
            (org-entry-put (point) "OGENT_TASK_STATUS" (plist-get record :status))
            (let* ((end (line-end-position))
                   (overlay (or (cl-find-if
                                 (lambda (ov) (equal (overlay-get ov 'ogent-task)
                                                     (plist-get record :id)))
                                 (append (car (overlay-lists)) (cdr (overlay-lists))))
                                (make-overlay end end))))
              (move-overlay overlay end end)
              (overlay-put overlay 'ogent-task (plist-get record :id))
              (overlay-put overlay 'after-string
                           (propertize (concat "  [" (plist-get record :status)
                                               "; checks " (or (plist-get record :checks) "not run")
                                               "]") 'face 'shadow))))))))
  record)

(defun ogent-task--read (file)
  "Return the durable task at FILE, including its original instruction."
  (unless (file-readable-p file) (user-error "Task record was not found: %s" file))
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (org-next-visible-heading 1)
      (unless (org-entry-get (point) "OGENT_TASK_ID") (user-error "Not an ogent task"))
      (let ((record (list :file file)))
        (dolist (key ogent-task--fields)
          (setq record (plist-put record key
                                  (org-entry-get (point) (ogent-task--property key)))))
        (plist-put record :instruction
                   (org-element-map (org-element-parse-buffer) 'src-block
		     (lambda (element)
		       (org-unescape-code-in-string (org-element-property :value element)))
		     nil t))
        (when-let ((source (and (plist-get record :source)
                                (find-buffer-visiting (plist-get record :source)))))
          (with-current-buffer source
            (save-excursion
              (when-let ((heading (org-find-property "ID" (plist-get record :source-id))))
                (plist-put record :source-marker (copy-marker heading))))))
        record))))

(defun ogent-task--current-file ()
  "Return the task record belonging to the current heading or patch."
  (or ogent-task-patch--file
      (when (derived-mode-p 'org-mode)
        (or (org-entry-get nil "OGENT_TASK_FILE" t)
            (when (org-entry-get nil "OGENT_TASK_ID" t) buffer-file-name)))
      (user-error "This heading has no delegated task")))

(defun ogent-task--snapshot (workspace directory)
  "Create a detached task worktree in DIRECTORY from WORKSPACE.
Include tracked disk edits; leave the original index and checkout untouched."
  (let* ((worktree (expand-file-name "worktree" directory))
         (snapshot (expand-file-name "snapshot.diff" directory)))
    (make-directory directory t)
    (with-temp-file snapshot (insert (ogent-task--git workspace "diff" "--binary" "HEAD")))
    (ogent-task--git workspace "worktree" "add" "--detach" worktree "HEAD")
    (condition-case err
        (progn
          (unless (zerop (file-attribute-size (file-attributes snapshot)))
            (ogent-task--git worktree "apply" "--binary" snapshot))
          (ogent-task--git worktree "add" "--all")
          (list :worktree worktree
                :baseline (string-trim (ogent-task--git worktree "write-tree"))))
      (error
       (ogent-task--git workspace "worktree" "remove" "--force" worktree)
       (signal (car err) (cdr err))))))

(defun ogent-task--instruction (record &optional feedback)
  "Build the agent instruction from RECORD and optional FEEDBACK."
  (concat "Complete this task in your assigned isolated workspace:\n"
          (plist-get record :instruction)
          "\nMake the changes on disk. Keep changes focused. "
          "Do not change the original checkout or remove this worktree.\n"
          "Explain the result and any remaining decisions.\n"
          (when-let ((check (plist-get record :check)))
            (unless (string-empty-p check)
              (concat "The requested verification command is: " check "\n")))
          feedback))

(defun ogent-task--start (record &optional feedback)
  "Start RECORD's Armory run, optionally incorporating FEEDBACK."
  (let ((plan (ogent-armory-runner-plan
               (plist-get record :root) (plist-get record :agent)
               :workspace (plist-get record :worktree)
               :instruction (ogent-task--instruction record feedback)
               :conversation-id (plist-get record :conversation)
               :conversation-title (plist-get record :title)
               :model (plist-get record :model)
               :adapter-id (plist-get record :adapter)
               :trigger "org-todo")))
    (plist-put record :conversation (plist-get plan :conversation-id))
    (plist-put record :model (or (plist-get plan :model) ""))
    (plist-put record :adapter (plist-get plan :adapter-id))
    (plist-put record :status "running")
    (plist-put record :checks "not run")
    (plist-put plan :org-task-file (plist-get record :file))
    (with-temp-file (ogent-task--file record "checks.log")
      (insert "Checks not run: waiting for the agent result.\n"))
    (unless (ogent-armory-runner--confirm plan)
      (plist-put record :status "cancelled")
      (ogent-task--write record)
      (user-error "Task run cancelled before dispatch"))
    (ogent-task--write record)
    (puthash (plist-get record :file) record ogent-task--active)
    (condition-case err
        (plist-put record :handle (ogent-armory-runner-start plan))
      (error
       (remhash (plist-get record :file) ogent-task--active)
       (plist-put record :status "failed")
       (ogent-task--write record)
       (signal (car err) (cdr err))))
    record))

;;;###autoload
(defun ogent-task-delegate (&optional agent directory)
  "Delegate the current Org TODO to AGENT in DIRECTORY's Git workspace.
Use inherited OGENT_WORKSPACE, OGENT_AGENT, OGENT_ARMORY and OGENT_CHECK
properties when present.  With no Armory, use the selected native model."
  (interactive)
  (unless (derived-mode-p 'org-mode) (user-error "Delegate an Org TODO heading"))
  (unless buffer-file-name (user-error "Save this Org file before delegating"))
  (org-back-to-heading t)
  (unless (member (org-get-todo-state) org-not-done-keywords)
    (user-error "Mark this heading TODO before delegating"))
  (when-let ((previous (org-entry-get nil "OGENT_TASK_FILE")))
    (when (member (plist-get (ogent-task--read previous) :status)
                  '("running" "checking" "ready" "check-failed"))
      (user-error "This task already has a run or patch; review or revise it")))
  (let* ((source (current-buffer))
         (source-marker (point-marker))
         (title (org-get-heading t t t t))
         (source-id (org-id-get-create))
         (workspace (string-trim
                     (ogent-task--git
                      (or directory (org-entry-get nil "OGENT_WORKSPACE" t)
                          default-directory) "rev-parse" "--show-toplevel")))
         (id (org-id-new))
         (task-dir (expand-file-name id ogent-task-directory))
         (root (or (org-entry-get nil "OGENT_ARMORY" t)
                   (ogent-armory-find-root (or directory default-directory))))
         (slug (or agent (org-entry-get nil "OGENT_AGENT" t)))
         (check (or (org-entry-get nil "OGENT_CHECK" t) ogent-task-check-command))
         (instruction (buffer-substring-no-properties
                       (save-excursion (org-end-of-meta-data t) (point))
                       (save-excursion (org-end-of-subtree t t) (point))))
         record)
    (when (file-remote-p workspace) (user-error "Task worktrees require a local Git workspace"))
    (dolist (buffer (buffer-list))
      (when (and (not (eq buffer source)) (buffer-file-name buffer)
                 (file-in-directory-p (buffer-file-name buffer) workspace)
                 (buffer-modified-p buffer))
        (user-error "Save %s before taking the task snapshot" (buffer-name buffer))))
    (if root
        (setq slug (or slug (ogent-armory-runner--read-agent root)))
      (when slug (user-error "Set OGENT_ARMORY to use agent %s" slug))
      (setq root (expand-file-name "armory" task-dir) slug "editor")
      (ogent-armory-scaffold root "Org task" :create-editor nil)
      (ogent-armory-write-agent
       root (list :slug slug :name "Editor" :role "Complete the Org task"
                  :provider "gptel" :model (ogent-ui--model-id-or-default)
                  :workspace workspace :active t)
       "Work on the user's task. Preserve unrelated work."))
    (setq record
          (append (list :id id :file (expand-file-name "task.org" task-dir)
                        :title title :workspace workspace :root root :agent slug
                        :instruction (concat title "\n" instruction)
                        :check (or check "") :source (or buffer-file-name "")
                        :source-id source-id :source-marker source-marker)
                  (ogent-task--snapshot workspace task-dir)))
    (ogent-task--start record)
    (message "ogent: %s is running; keep working, then review from this heading" title)
    record))

(defun ogent-task--collect (record)
  "Save RECORD's proposed patch relative to its initial snapshot."
  (let ((worktree (plist-get record :worktree)))
    (ogent-task--git worktree "add" "--all")
    (with-temp-file (ogent-task--file record "patch.diff")
      (insert (ogent-task--git worktree "diff" "--cached" "--binary"
                               (plist-get record :baseline))))))

(defun ogent-task--complete (record)
  "Collect RECORD's patch and publish its final review state."
  (condition-case err
      (progn
        (ogent-task--collect record)
        (ogent-task--write record)
        (remhash (plist-get record :file) ogent-task--active)
        (message "ogent: %s — %s; patch and check output are ready to review"
                 (plist-get record :title) (plist-get record :checks)))
    (error
     (plist-put record :status "failed")
     (ogent-task--write record)
     (remhash (plist-get record :file) ogent-task--active)
     (message "ogent: task result could not be collected: %s" (error-message-string err)))))

(defun ogent-task--finished (plan exit-status)
  "Collect the delegated PLAN after its agent exits with EXIT-STATUS."
  (when-let* ((file (plist-get plan :org-task-file))
              (record (gethash file ogent-task--active)))
    (condition-case err
        (let ((check (plist-get record :check)))
          (cond
           ((plist-get plan :cancelled)
            (plist-put record :status "cancelled")
            (with-temp-file (ogent-task--file record "checks.log")
              (insert "Checks not run: agent run cancelled.\n"))
            (ogent-task--complete record))
           ((not (zerop exit-status))
            (plist-put record :status "failed")
            (with-temp-file (ogent-task--file record "checks.log")
              (insert (format "Checks not run: agent exited with status %d.\n" exit-status)))
            (ogent-task--complete record))
           ((string-empty-p (or check ""))
            (plist-put record :status "ready")
            (with-temp-file (ogent-task--file record "checks.log")
              (insert "Checks not run: set OGENT_CHECK on the task or its parent.\n"))
            (ogent-task--complete record))
           (t
            (plist-put record :status "checking")
            (ogent-task--write record)
            (let ((default-directory (file-name-as-directory (plist-get record :worktree)))
                  (buffer (generate-new-buffer " *ogent-task-check*")))
              (plist-put
               record :check-process
               (make-process
                :name "ogent-task-check" :buffer buffer
                :command (list shell-file-name shell-command-switch check)
                :connection-type 'pipe :noquery t
                :sentinel
                (lambda (process _event)
                  (unless (process-live-p process)
                    (with-temp-file (ogent-task--file record "checks.log")
                      (insert "$ " check "\n\n"
                              (with-current-buffer buffer (buffer-string))))
                    (kill-buffer buffer)
                    (plist-put record :check-exit (number-to-string (process-exit-status process)))
                    (unless (equal (plist-get record :status) "cancelled")
                      (plist-put record :checks
                                 (if (zerop (process-exit-status process)) "passed" "failed"))
                      (plist-put record :status
                                 (if (zerop (process-exit-status process)) "ready" "check-failed")))
                    (ogent-task--complete record)))))))))
      (error
       (plist-put record :status "failed")
       (ogent-task--write record)
       (remhash file ogent-task--active)
       (message "ogent: task completion failed: %s" (error-message-string err))))))

(defun ogent-task-comment (&optional note)
  "Attach NOTE to the current delegated patch hunk."
  (interactive)
  (unless ogent-task-patch--file (user-error "Open the task patch first"))
  (let* ((file ogent-task-patch--file)
         (hunk (save-excursion
                 (diff-beginning-of-hunk)
                 (let* ((start (point))
                        (header (save-excursion
                                  (diff-beginning-of-file)
                                  (let ((begin (point)))
                                    (re-search-forward "^@@" start t)
                                    (buffer-substring-no-properties begin (line-beginning-position))))))
                   (diff-end-of-hunk)
                   (concat header (buffer-substring-no-properties start (point))))))
         (comment (or note (read-string "Hunk comment: "))))
    (when (string-empty-p (string-trim comment)) (user-error "Comment is empty"))
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-max))
        (insert "\n*** OPEN Hunk comment\n")
        (forward-line -1)
        (org-entry-put (point) "OGENT_FEEDBACK_STATUS" "open")
        (org-end-of-meta-data t)
        (insert (ogent-workbench--src comment) (ogent-workbench--src hunk)))
      (save-buffer))
    (message "ogent: hunk comment saved; add more, then revise the patch")))

(defun ogent-task--feedback (file)
  "Return all open hunk comments at FILE with their exact patch context."
  (with-current-buffer (find-file-noselect file)
    (let (comments)
      (org-map-entries
       (lambda ()
         (when (equal (org-entry-get (point) "OGENT_FEEDBACK_STATUS") "open")
           (push (buffer-substring-no-properties
                  (point) (save-excursion (org-end-of-subtree t t) (point))) comments)))
       nil 'file)
      (mapconcat #'identity (nreverse comments) "\n"))))

;;;###autoload
(defun ogent-task-revise (&optional instruction)
  "Revise the task patch using its hunk comments and INSTRUCTION."
  (interactive)
  (let* ((file (ogent-task--current-file))
         (record (ogent-task--read file))
         (feedback (ogent-task--feedback file)))
    (when (member (plist-get record :status) '("running" "checking" "applied"))
      (user-error "Task is %s; review its current result first" (plist-get record :status)))
    (when (and (string-empty-p feedback) (null instruction))
      (setq instruction (read-string "Revision: ")))
    (let ((checks (ogent-task--file record "checks.log")))
      (ogent-task--start
       record
       (concat "\nRevise your current patch using this feedback:\n" feedback
               (when instruction (concat "\n" instruction))
               (when (file-readable-p checks)
                 (concat "\nActual verification output:\n"
                         (with-temp-buffer
                           (insert-file-contents checks nil 0 20000) (buffer-string)))))))
    (with-current-buffer (find-file-noselect file)
      (org-map-entries
       (lambda ()
         (when (equal (org-entry-get (point) "OGENT_FEEDBACK_STATUS") "open")
           (org-entry-put (point) "OGENT_FEEDBACK_STATUS" "submitted"))) nil 'file)
      (save-buffer))
    record))

;;;###autoload
(defun ogent-task-apply ()
  "Apply the reviewed task patch after checking disk and unsaved buffers."
  (interactive)
  (let* ((record (ogent-task--read (ogent-task--current-file)))
         (workspace (plist-get record :workspace))
         (patch (ogent-task--file record "patch.diff"))
         (paths (split-string (ogent-task--git workspace "apply" "--numstat" "-z" patch)
                              "\0" t))
         buffers)
    (when (member (plist-get record :status) '("running" "checking" "applied" "cancelled" "rejected"))
      (user-error "Task is %s; no patch can be applied" (plist-get record :status)))
    (unless paths (user-error "This task has no proposed file changes"))
    (dolist (row paths)
      (unless (string-match "\t[^\t]*\t" row) (user-error "Unsupported patch file record"))
      (let ((path (expand-file-name (substring row (match-end 0)) workspace)))
        (when-let ((buffer (find-buffer-visiting path)))
          (when (buffer-modified-p buffer)
            (user-error "Save or undo changes in %s before applying this patch" (buffer-name buffer)))
          (push buffer buffers))))
    (ogent-task--git workspace "apply" "--check" "--binary" patch)
    (ogent-task--git workspace "apply" "--binary" patch)
    (dolist (buffer buffers)
      (with-current-buffer buffer (revert-buffer t t)))
    (plist-put record :status "applied")
    (ogent-task--write record)
    (message "ogent: patch applied; review your task before marking it DONE")))

;;;###autoload
(defun ogent-task-reject ()
  "Reject the current task patch while retaining its record and artifacts."
  (interactive)
  (let ((record (ogent-task--read (ogent-task--current-file))))
    (when (member (plist-get record :status) '("running" "checking" "applied"))
      (user-error "Task is %s; cancel active work before rejecting" (plist-get record :status)))
    (plist-put record :status "rejected")
    (ogent-task--write record)
    (message "ogent: patch rejected; the original checkout is unchanged")))

;;;###autoload
(defun ogent-task-cancel ()
  "Cancel the heading's active run or check, preserving its artifacts."
  (interactive)
  (let* ((file (ogent-task--current-file))
         (record (or (gethash file ogent-task--active) (ogent-task--read file))))
    (unless (member (plist-get record :status) '("running" "checking"))
      (user-error "Task is not running; reject its patch to leave it unapplied"))
    (plist-put record :status "cancelled")
    (if-let ((process (plist-get record :check-process)))
        (when (process-live-p process) (delete-process process))
      (ogent-armory-runner-stop-conversation (plist-get record :root)
                                             (plist-get record :conversation)))
    (ogent-task--write record)))

(add-hook 'ogent-armory-runner-finished-hook #'ogent-task--finished)

(provide 'ogent-task)
;;; ogent-task.el ends here
