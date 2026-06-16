;;; ogent-ui-armory-tasks.el --- Armory attention lanes (task board) -*- lexical-binding: t; -*-

;;; Commentary:
;; Armory attention lanes and task board views.

;;; Code:

(require 'ogent-ui-armory-core)

(declare-function ogent-armory-search "ogent-ui-armory-search")

(defvar ogent-armory-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-armory-tasks-visit)
    (define-key map (kbd "<return>") #'ogent-armory-tasks-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-armory-tasks-visit)
    (define-key map "c" #'ogent-armory-create-task)
    (define-key map (kbd "C-c c") #'ogent-armory-create-task)
    (define-key map "R" #'ogent-armory-tasks-run)
    (define-key map (kbd "C-c r") #'ogent-armory-tasks-run)
    (define-key map "A" #'ogent-armory-tasks-archive)
    (define-key map (kbd "C-c a") #'ogent-armory-tasks-archive)
    (define-key map "U" #'ogent-armory-tasks-unarchive)
    (define-key map (kbd "C-c u") #'ogent-armory-tasks-unarchive)
    (define-key map "b" #'ogent-armory-tasks-board-view)
    (define-key map (kbd "C-c b") #'ogent-armory-tasks-board-view)
    (define-key map "l" #'ogent-armory-tasks-list-view)
    (define-key map (kbd "C-c l") #'ogent-armory-tasks-list-view)
    (define-key map "S" #'ogent-armory-tasks-schedule-view)
    (define-key map (kbd "C-c S") #'ogent-armory-tasks-schedule-view)
    (define-key map "e" #'ogent-armory-tasks-edit)
    (define-key map (kbd "C-c e") #'ogent-armory-tasks-edit)
    (define-key map "f" #'ogent-armory-tasks-filter)
    (define-key map (kbd "C-c f") #'ogent-armory-tasks-filter)
    (define-key map "g" #'ogent-armory-tasks-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-tasks-refresh)
    (define-key map "s" #'ogent-armory-search)
    (define-key map (kbd "C-c s") #'ogent-armory-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-tasks-mode'.")

(define-derived-mode ogent-armory-tasks-mode tabulated-list-mode "Armory-Tasks"
  "Major mode for Armory attention lanes."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Lane" 16 t)
               ("Type" 10 t)
               ("Agent" 14 t)
               ("Item" 32 t)
               ("State" 18 t)
               ("When" 24 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-tasks-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-tasks--help-line ()
  "Return the task board action hint."
  (propertize
   "c create task  RET visit  R run  A archive  U unarchive  b board  l list  S schedule  f filter  g refresh  q quit\n\n"
   'face 'shadow))

(defun ogent-armory-tasks--print ()
  "Print the current task board with its action hint."
  (tabulated-list-print t)
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (insert (ogent-armory-tasks--help-line))))

(defun ogent-armory-tasks--job-item (root job)
  "Return a task item for JOB under ROOT."
  (let ((stale (ogent-armory-ui--stale-job-p root job))
        (scheduled (or (ogent-armory--blank-to-nil (plist-get job :cron))
                       (ogent-armory--blank-to-nil
                        (plist-get job :run-after)))))
    (list :type 'job
          :lane (cond
                 ((plist-get job :archived) "Archive")
                 ((not (plist-get job :enabled)) "Archive")
                 (stale "Needs Reply")
                 (t "Inbox"))
          :agent (plist-get job :agent)
          :job-id (plist-get job :id)
          :name (or (plist-get job :name) (plist-get job :id))
          :state (cond
                  ((plist-get job :archived) "archived")
                  ((not (plist-get job :enabled)) "disabled")
                  (stale "stale")
                  (scheduled "scheduled")
                  (t "enabled"))
          :scheduled scheduled
          :stale stale
          :when (or scheduled "manual")
          :path (ogent-armory-job-file
                 root
                 (plist-get job :agent)
                 (plist-get job :id)))))

(defun ogent-armory-tasks--session-lane (session)
  "Return the attention lane for SESSION."
  (let ((status (upcase (or (plist-get session :status) ""))))
    (cond
     ((plist-get session :archived) "Archive")
     ((equal status "RUNNING") "Running")
     ((member status '("AWAITING-INPUT" "FAILED")) "Needs Reply")
     ((not (zerop (or (plist-get session :exit-status) 0))) "Needs Reply")
     ((and (plist-get session :muted)
           (member status '("DONE" "CANCELLED")))
      "Archive")
     ((member status '("TODO" "IDLE")) "Inbox")
     (t "Just Finished"))))

(defun ogent-armory-tasks--session-item (session)
  "Return a task item for SESSION."
  (list :type 'session
        :lane (ogent-armory-tasks--session-lane session)
        :agent (plist-get session :agent)
        :job-id (plist-get session :job-id)
        :name (or (plist-get session :name) (plist-get session :id))
        :state (or (plist-get session :status) "DONE")
        :when (or (plist-get session :finished) "")
        :last-activity (or (plist-get session :last-activity)
                           (plist-get session :finished))
        :scheduled-at (plist-get session :scheduled-at)
        :scheduled-key (plist-get session :scheduled-key)
        :board-order (plist-get session :board-order)
        :muted (plist-get session :muted)
        :path (plist-get session :path)))

(defun ogent-armory-tasks--running-items (root)
  "Return live runner task items under ROOT."
  (delq
   nil
   (mapcar
    (lambda (slug)
      (when (ogent-armory-runner-running-p slug)
        (list :type 'agent
              :lane "Running"
              :agent slug
              :name slug
              :state "running"
              :when ""
              :path (ogent-armory-agent-file root slug))))
    (ogent-armory-ui--agent-slugs root))))

(defun ogent-armory-tasks--items ()
  "Return task items for the current Armory task buffer."
  (let ((root ogent-armory-tasks--root)
        items)
    (dolist (slug (ogent-armory-ui--agent-slugs root))
      (dolist (job (ogent-armory-ui--agent-jobs root slug))
        (push (ogent-armory-tasks--job-item root job) items)))
    (dolist (session (ogent-armory-ui--all-sessions root))
      (push (ogent-armory-tasks--session-item session) items))
    (setq items (append (ogent-armory-tasks--running-items root) items))
    (let ((filters ogent-armory-tasks--filters))
      (setq items
            (seq-filter
             (lambda (item)
               (and (or (null (plist-get filters :agent))
                        (equal (plist-get item :agent)
                               (plist-get filters :agent)))
                    (or (null (plist-get filters :status))
                        (equal (plist-get item :state)
                               (plist-get filters :status)))))
             items)))
    (ogent-armory-tasks--sort-items (nreverse items))))

(defun ogent-armory-tasks--item-time (item)
  "Return the best sortable timestamp for ITEM."
  (or (plist-get item :scheduled-at)
      (plist-get item :last-activity)
      (plist-get item :when)
      ""))

(defun ogent-armory-tasks--item-less-p (left right)
  "Return non-nil when LEFT should sort before RIGHT."
  (let ((left-order (plist-get left :board-order))
        (right-order (plist-get right :board-order)))
    (cond
     ((and left-order right-order (not (= left-order right-order)))
      (< left-order right-order))
     (left-order t)
     (right-order nil)
     ((not (equal (ogent-armory-tasks--item-time left)
                  (ogent-armory-tasks--item-time right)))
      (string> (ogent-armory-tasks--item-time left)
               (ogent-armory-tasks--item-time right)))
     (t
      (string< (or (plist-get left :name) "")
               (or (plist-get right :name) ""))))))

(defun ogent-armory-tasks--sort-items (items)
  "Return ITEMS in task-board display order."
  (seq-sort #'ogent-armory-tasks--item-less-p items))

(defun ogent-armory-tasks--unique-job-id (root agent title)
  "Return a unique job id under ROOT and AGENT for TITLE."
  (let* ((base (ogent-armory--slug title "task"))
         (candidate base)
         (index 2))
    (while (file-exists-p (ogent-armory-job-file root agent candidate))
      (setq candidate (format "%s-%d" base index))
      (setq index (1+ index)))
    candidate))

(defun ogent-armory-tasks--current-agent ()
  "Return the task item agent at point when present."
  (when-let ((item (ignore-errors (ogent-armory-ui--item-at-point))))
    (ogent-armory--blank-to-nil (plist-get item :agent))))

(defun ogent-armory-tasks--read-agent (root)
  "Read an agent for a new task under ROOT."
  (ogent-armory-ui--read-agent-default
   root
   (ogent-armory-tasks--current-agent)))

(defun ogent-armory-tasks--goto (agent job-id)
  "Move to AGENT JOB-ID in the current task buffer when visible."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (let ((item (tabulated-list-get-id)))
        (when (and item
                   (equal (plist-get item :agent) agent)
                   (equal (plist-get item :job-id) job-id))
          (setq found t)))
      (unless found
        (forward-line 1)))))

(defun ogent-armory-tasks--refresh-open-buffer (root &optional agent job-id)
  "Refresh the open task board for ROOT, then move to AGENT JOB-ID."
  (when-let ((buffer (get-buffer
                      (ogent-armory-ui--buffer-name
                       ogent-armory-tasks-buffer-name-format root))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'ogent-armory-tasks-mode)
          (setq ogent-armory-tasks--root root)
          (ogent-armory-tasks-refresh)
          (when (and agent job-id)
            (ogent-armory-tasks--goto agent job-id)))))))

(defun ogent-armory-tasks--root (&optional directory)
  "Return a Armory root for task commands.
When DIRECTORY is non-nil, prefer it as the root."
  (ogent-armory-ui--root
   (or directory
       ogent-armory-tasks--root
       (ogent-armory-find-root)
       (read-directory-name "Armory root: "))))

(defun ogent-armory-create-task (&optional directory agent title details)
  "Capture a manual Armory task under DIRECTORY for AGENT.
TITLE names the task and DETAILS provides its body; both are prompted when nil."
  (interactive)
  (let* ((root (ogent-armory-tasks--root directory))
         (slug (or agent (ogent-armory-tasks--read-agent root)))
         (name (or (ogent-armory--blank-to-nil title)
                   (string-trim (read-string "Task: "))))
         (body-input (if (null details)
                         (ogent-armory-ui--read-string-default
                          "Details: "
                          name)
                       details)))
    (when (string-blank-p name)
      (user-error "Task title is required"))
    (let* ((job-id (ogent-armory-tasks--unique-job-id root slug name))
           (now (ogent-armory-ui--iso-now))
           (body (or (ogent-armory--blank-to-nil body-input) name))
           (job (list :id job-id
                      :agent slug
                      :name name
                      :cron ""
                      :heartbeat ""
                      :enabled t
                      :enabled-raw "t"
                      :archived nil
                      :archived-raw "nil"
                      :workspace "/"
                      :created-at now
                      :updated-at now)))
      (ogent-armory-validate-job job)
      (let ((file (ogent-armory-write-job root slug job body)))
        (ogent-armory-ui--refresh-home-buffer root)
        (ogent-armory-tasks--refresh-open-buffer root slug job-id)
        (message "Created Armory task: %s" name)
        file))))

(defun ogent-armory-tasks--scheduled-item-p (item)
  "Return non-nil when ITEM has scheduling metadata."
  (or (ogent-armory--blank-to-nil (plist-get item :scheduled))
      (ogent-armory--blank-to-nil (plist-get item :scheduled-at))
      (ogent-armory--blank-to-nil (plist-get item :scheduled-key))))

(defun ogent-armory-tasks--entry (item)
  "Return a tabulated list entry for ITEM."
  (list
   item
   (vector
    (or (plist-get item :lane) "")
    (symbol-name (plist-get item :type))
    (or (plist-get item :agent) "")
    (or (plist-get item :name) "")
    (or (plist-get item :state) "")
    (or (plist-get item :when) ""))))

(defun ogent-armory-tasks--entries ()
  "Return tabulated list entries for the current Armory task buffer."
  (let ((items (ogent-armory-tasks--items)))
    (pcase ogent-armory-tasks--view
      ('list
       (mapcar #'ogent-armory-tasks--entry items))
      ('schedule
       (mapcar #'ogent-armory-tasks--entry
               (seq-filter #'ogent-armory-tasks--scheduled-item-p items)))
      (_
       (apply
        #'append
        (mapcar
         (lambda (lane)
           (let ((lane-items (seq-filter
                              (lambda (item)
                                (equal (plist-get item :lane) lane))
                              items)))
             (if lane-items
                 (mapcar #'ogent-armory-tasks--entry
                         (ogent-armory-tasks--sort-items lane-items))
               (list (ogent-armory-tasks--entry
                      (list :type 'empty
                            :lane lane
                            :agent ""
                            :name "(empty)"
                            :state ""
                            :when ""))))))
         ogent-armory-task-lanes))))))

(defun ogent-armory-tasks (&optional directory)
  "Open Armory attention lanes for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-tasks-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-tasks-mode)
      (setq ogent-armory-tasks--root root)
      (setq ogent-armory-tasks--filters nil)
      (setq ogent-armory-tasks--view 'board)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-tasks--entries)
      (ogent-armory-tasks--print))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-tasks-refresh (&rest _)
  "Refresh the Armory task lane buffer."
  (interactive)
  (ogent-armory-tasks--print))

(defun ogent-armory-tasks-board-view ()
  "Show Armory tasks as attention lanes."
  (interactive)
  (setq ogent-armory-tasks--view 'board)
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-list-view ()
  "Show Armory tasks as a flat list."
  (interactive)
  (setq ogent-armory-tasks--view 'list)
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-schedule-view ()
  "Show Armory tasks with scheduling metadata."
  (interactive)
  (setq ogent-armory-tasks--view 'schedule)
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks--after-run (process)
  "Refresh the task board, display PROCESS, and return PROCESS."
  (ogent-armory-tasks-refresh)
  (when process
    (ogent-armory-runner-display-process process))
  process)

(defun ogent-armory-tasks-visit ()
  "Visit the Armory task item at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (when (eq (plist-get item :type) 'empty)
      (user-error "No Armory task at point"))
    (ogent-armory-ui--visit-path (plist-get item :path))))

(defun ogent-armory-tasks-run ()
  "Run or retry the Armory task at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-tasks--after-run
        (ogent-armory-run-job
         ogent-armory-tasks--root
         (plist-get item :agent)
         (plist-get item :job-id))))
      ('session
       (ogent-armory-tasks--after-run
        (if-let ((job-id (plist-get item :job-id)))
            (ogent-armory-run-job
             ogent-armory-tasks--root
             (plist-get item :agent)
             job-id)
          (ogent-armory-run-agent
           ogent-armory-tasks--root
           (plist-get item :agent)
           (read-string "Instruction: ")))))
      (_
       (user-error "No runnable Armory task at point")))))

(defun ogent-armory-tasks-archive ()
  "Archive the Armory task at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-ui--put-property
        (plist-get item :path)
        "OGENT_ENABLED"
        "nil"))
      ('session
       (ogent-armory-ui--put-property
        (plist-get item :path)
        "OGENT_ARCHIVED"
        "t"))
      (_
       (user-error "No archivable Armory task at point"))))
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-unarchive ()
  "Unarchive the Armory task at point."
  (interactive)
  (let ((item (ogent-armory-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-armory-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil")
       (ogent-armory-ui--put-property (plist-get item :path) "OGENT_ENABLED" "t"))
      ('session
       (ogent-armory-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil"))
      (_
       (user-error "No archived Armory task at point"))))
  (ogent-armory-tasks-refresh))

(defun ogent-armory-tasks-edit ()
  "Edit metadata for the Armory task at point."
  (interactive)
  (let* ((item (ogent-armory-ui--item-at-point))
         (property (pcase (plist-get item :type)
                     ('job (completing-read "Property: "
                                            ogent-armory-job-editable-properties
                                            nil t))
                     ('session (completing-read "Property: "
                                                '("OGENT_ARCHIVED" "OGENT_TAGS")
                                                nil t))
                     (_ (user-error "No editable Armory task at point"))))
         (key (cdr (assoc property ogent-armory-job-property-keys)))
         (current (cond
                   ((and key (eq (plist-get item :type) 'job))
                    (format "%s" (or (plist-get item key) "")))
                   ((eq (plist-get item :type) 'session)
                    (with-temp-buffer
                      (insert-file-contents (plist-get item :path))
                      (ogent-armory--org-mode)
                      (ogent-armory--first-heading-title)
                      (org-entry-get nil property)))
                   (t "")))
         (value (ogent-armory-ui--read-property-value
                 ogent-armory-tasks--root
                 property
                 current
                 item)))
    (when (eq (plist-get item :type) 'job)
      (ogent-armory-validate-job
       (ogent-armory-ui--job-with-property item property value)))
    (ogent-armory-ui--put-property (plist-get item :path) property value)
    (ogent-armory-tasks-refresh)))

(defun ogent-armory-tasks-filter ()
  "Set simple task board filters."
  (interactive)
  (setq ogent-armory-tasks--filters
        (list :agent (ogent-armory--blank-to-nil
                      (ogent-armory-ui--read-optional-choice
                       "Agent filter: "
                       (ogent-armory-ui--agent-slugs
                        ogent-armory-tasks--root)))
              :status (ogent-armory--blank-to-nil
                       (ogent-armory-ui--read-optional-choice
                        "Status filter: "
                        (ogent-armory-ui--task-status-candidates
                         ogent-armory-tasks--root)))))
  (ogent-armory-tasks-refresh))

(provide 'ogent-ui-armory-tasks)
;;; ogent-ui-armory-tasks.el ends here
