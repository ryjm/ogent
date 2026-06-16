;;; ogent-ui-cabinet-tasks.el --- Cabinet attention lanes (task board) -*- lexical-binding: t; -*-

;;; Commentary:
;; Cabinet attention lanes and task board views.

;;; Code:

(require 'ogent-ui-cabinet-core)

(declare-function ogent-cabinet-search "ogent-ui-cabinet-search")

(defvar ogent-cabinet-tasks-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-cabinet-tasks-visit)
    (define-key map (kbd "<return>") #'ogent-cabinet-tasks-visit)
    (define-key map (kbd "<kp-enter>") #'ogent-cabinet-tasks-visit)
    (define-key map "c" #'ogent-cabinet-create-task)
    (define-key map (kbd "C-c c") #'ogent-cabinet-create-task)
    (define-key map "R" #'ogent-cabinet-tasks-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-tasks-run)
    (define-key map "A" #'ogent-cabinet-tasks-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-tasks-archive)
    (define-key map "U" #'ogent-cabinet-tasks-unarchive)
    (define-key map (kbd "C-c u") #'ogent-cabinet-tasks-unarchive)
    (define-key map "b" #'ogent-cabinet-tasks-board-view)
    (define-key map (kbd "C-c b") #'ogent-cabinet-tasks-board-view)
    (define-key map "l" #'ogent-cabinet-tasks-list-view)
    (define-key map (kbd "C-c l") #'ogent-cabinet-tasks-list-view)
    (define-key map "S" #'ogent-cabinet-tasks-schedule-view)
    (define-key map (kbd "C-c S") #'ogent-cabinet-tasks-schedule-view)
    (define-key map "e" #'ogent-cabinet-tasks-edit)
    (define-key map (kbd "C-c e") #'ogent-cabinet-tasks-edit)
    (define-key map "f" #'ogent-cabinet-tasks-filter)
    (define-key map (kbd "C-c f") #'ogent-cabinet-tasks-filter)
    (define-key map "g" #'ogent-cabinet-tasks-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-tasks-refresh)
    (define-key map "s" #'ogent-cabinet-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-search)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-tasks-mode'.")

(define-derived-mode ogent-cabinet-tasks-mode tabulated-list-mode "Cabinet-Tasks"
  "Major mode for Cabinet attention lanes."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Lane" 16 t)
               ("Type" 10 t)
               ("Agent" 14 t)
               ("Item" 32 t)
               ("State" 18 t)
               ("When" 24 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-tasks-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-tasks--help-line ()
  "Return the task board action hint."
  (propertize
   "c create task  RET visit  R run  A archive  U unarchive  b board  l list  S schedule  f filter  g refresh  q quit\n\n"
   'face 'shadow))

(defun ogent-cabinet-tasks--print ()
  "Print the current task board with its action hint."
  (tabulated-list-print t)
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (insert (ogent-cabinet-tasks--help-line))))

(defun ogent-cabinet-tasks--job-item (root job)
  "Return a task item for JOB under ROOT."
  (let ((stale (ogent-cabinet-ui--stale-job-p root job))
        (scheduled (or (ogent-cabinet--blank-to-nil (plist-get job :cron))
                       (ogent-cabinet--blank-to-nil
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
          :path (ogent-cabinet-job-file
                 root
                 (plist-get job :agent)
                 (plist-get job :id)))))

(defun ogent-cabinet-tasks--session-lane (session)
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

(defun ogent-cabinet-tasks--session-item (session)
  "Return a task item for SESSION."
  (list :type 'session
        :lane (ogent-cabinet-tasks--session-lane session)
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

(defun ogent-cabinet-tasks--running-items (root)
  "Return live runner task items under ROOT."
  (delq
   nil
   (mapcar
    (lambda (slug)
      (when (ogent-cabinet-runner-running-p slug)
        (list :type 'agent
              :lane "Running"
              :agent slug
              :name slug
              :state "running"
              :when ""
              :path (ogent-cabinet-agent-file root slug))))
    (ogent-cabinet-ui--agent-slugs root))))

(defun ogent-cabinet-tasks--items ()
  "Return task items for the current Cabinet task buffer."
  (let ((root ogent-cabinet-tasks--root)
        items)
    (dolist (slug (ogent-cabinet-ui--agent-slugs root))
      (dolist (job (ogent-cabinet-ui--agent-jobs root slug))
        (push (ogent-cabinet-tasks--job-item root job) items)))
    (dolist (session (ogent-cabinet-ui--all-sessions root))
      (push (ogent-cabinet-tasks--session-item session) items))
    (setq items (append (ogent-cabinet-tasks--running-items root) items))
    (let ((filters ogent-cabinet-tasks--filters))
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
    (ogent-cabinet-tasks--sort-items (nreverse items))))

(defun ogent-cabinet-tasks--item-time (item)
  "Return the best sortable timestamp for ITEM."
  (or (plist-get item :scheduled-at)
      (plist-get item :last-activity)
      (plist-get item :when)
      ""))

(defun ogent-cabinet-tasks--item-less-p (left right)
  "Return non-nil when LEFT should sort before RIGHT."
  (let ((left-order (plist-get left :board-order))
        (right-order (plist-get right :board-order)))
    (cond
     ((and left-order right-order (not (= left-order right-order)))
      (< left-order right-order))
     (left-order t)
     (right-order nil)
     ((not (equal (ogent-cabinet-tasks--item-time left)
                  (ogent-cabinet-tasks--item-time right)))
      (string> (ogent-cabinet-tasks--item-time left)
               (ogent-cabinet-tasks--item-time right)))
     (t
      (string< (or (plist-get left :name) "")
               (or (plist-get right :name) ""))))))

(defun ogent-cabinet-tasks--sort-items (items)
  "Return ITEMS in task-board display order."
  (seq-sort #'ogent-cabinet-tasks--item-less-p items))

(defun ogent-cabinet-tasks--unique-job-id (root agent title)
  "Return a unique job id under ROOT and AGENT for TITLE."
  (let* ((base (ogent-cabinet--slug title "task"))
         (candidate base)
         (index 2))
    (while (file-exists-p (ogent-cabinet-job-file root agent candidate))
      (setq candidate (format "%s-%d" base index))
      (setq index (1+ index)))
    candidate))

(defun ogent-cabinet-tasks--current-agent ()
  "Return the task item agent at point when present."
  (when-let ((item (ignore-errors (ogent-cabinet-ui--item-at-point))))
    (ogent-cabinet--blank-to-nil (plist-get item :agent))))

(defun ogent-cabinet-tasks--read-agent (root)
  "Read an agent for a new task under ROOT."
  (ogent-cabinet-ui--read-agent-default
   root
   (ogent-cabinet-tasks--current-agent)))

(defun ogent-cabinet-tasks--goto (agent job-id)
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

(defun ogent-cabinet-tasks--refresh-open-buffer (root &optional agent job-id)
  "Refresh the open task board for ROOT, then move to AGENT JOB-ID."
  (when-let ((buffer (get-buffer
                      (ogent-cabinet-ui--buffer-name
                       ogent-cabinet-tasks-buffer-name-format root))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'ogent-cabinet-tasks-mode)
          (setq ogent-cabinet-tasks--root root)
          (ogent-cabinet-tasks-refresh)
          (when (and agent job-id)
            (ogent-cabinet-tasks--goto agent job-id)))))))

(defun ogent-cabinet-tasks--root (&optional directory)
  "Return a Cabinet root for task commands.
When DIRECTORY is non-nil, prefer it as the root."
  (ogent-cabinet-ui--root
   (or directory
       ogent-cabinet-tasks--root
       (ogent-cabinet-find-root)
       (read-directory-name "Cabinet root: "))))

(defun ogent-cabinet-create-task (&optional directory agent title details)
  "Capture a manual Cabinet task under DIRECTORY for AGENT.
TITLE names the task and DETAILS provides its body; both are prompted when nil."
  (interactive)
  (let* ((root (ogent-cabinet-tasks--root directory))
         (slug (or agent (ogent-cabinet-tasks--read-agent root)))
         (name (or (ogent-cabinet--blank-to-nil title)
                   (string-trim (read-string "Task: "))))
         (body-input (if (null details)
                         (ogent-cabinet-ui--read-string-default
                          "Details: "
                          name)
                       details)))
    (when (string-blank-p name)
      (user-error "Task title is required"))
    (let* ((job-id (ogent-cabinet-tasks--unique-job-id root slug name))
           (now (ogent-cabinet-ui--iso-now))
           (body (or (ogent-cabinet--blank-to-nil body-input) name))
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
      (ogent-cabinet-validate-job job)
      (let ((file (ogent-cabinet-write-job root slug job body)))
        (ogent-cabinet-ui--refresh-home-buffer root)
        (ogent-cabinet-tasks--refresh-open-buffer root slug job-id)
        (message "Created Cabinet task: %s" name)
        file))))

(defun ogent-cabinet-tasks--scheduled-item-p (item)
  "Return non-nil when ITEM has scheduling metadata."
  (or (ogent-cabinet--blank-to-nil (plist-get item :scheduled))
      (ogent-cabinet--blank-to-nil (plist-get item :scheduled-at))
      (ogent-cabinet--blank-to-nil (plist-get item :scheduled-key))))

(defun ogent-cabinet-tasks--entry (item)
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

(defun ogent-cabinet-tasks--entries ()
  "Return tabulated list entries for the current Cabinet task buffer."
  (let ((items (ogent-cabinet-tasks--items)))
    (pcase ogent-cabinet-tasks--view
      ('list
       (mapcar #'ogent-cabinet-tasks--entry items))
      ('schedule
       (mapcar #'ogent-cabinet-tasks--entry
               (seq-filter #'ogent-cabinet-tasks--scheduled-item-p items)))
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
                 (mapcar #'ogent-cabinet-tasks--entry
                         (ogent-cabinet-tasks--sort-items lane-items))
               (list (ogent-cabinet-tasks--entry
                      (list :type 'empty
                            :lane lane
                            :agent ""
                            :name "(empty)"
                            :state ""
                            :when ""))))))
         ogent-cabinet-task-lanes))))))

(defun ogent-cabinet-tasks (&optional directory)
  "Open Cabinet attention lanes for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-tasks-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-tasks-mode)
      (setq ogent-cabinet-tasks--root root)
      (setq ogent-cabinet-tasks--filters nil)
      (setq ogent-cabinet-tasks--view 'board)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-tasks--entries)
      (ogent-cabinet-tasks--print))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-tasks-refresh (&rest _)
  "Refresh the Cabinet task lane buffer."
  (interactive)
  (ogent-cabinet-tasks--print))

(defun ogent-cabinet-tasks-board-view ()
  "Show Cabinet tasks as attention lanes."
  (interactive)
  (setq ogent-cabinet-tasks--view 'board)
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-list-view ()
  "Show Cabinet tasks as a flat list."
  (interactive)
  (setq ogent-cabinet-tasks--view 'list)
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-schedule-view ()
  "Show Cabinet tasks with scheduling metadata."
  (interactive)
  (setq ogent-cabinet-tasks--view 'schedule)
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks--after-run (process)
  "Refresh the task board, display PROCESS, and return PROCESS."
  (ogent-cabinet-tasks-refresh)
  (when process
    (ogent-cabinet-runner-display-process process))
  process)

(defun ogent-cabinet-tasks-visit ()
  "Visit the Cabinet task item at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (when (eq (plist-get item :type) 'empty)
      (user-error "No Cabinet task at point"))
    (ogent-cabinet-ui--visit-path (plist-get item :path))))

(defun ogent-cabinet-tasks-run ()
  "Run or retry the Cabinet task at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-tasks--after-run
        (ogent-cabinet-run-job
         ogent-cabinet-tasks--root
         (plist-get item :agent)
         (plist-get item :job-id))))
      ('session
       (ogent-cabinet-tasks--after-run
        (if-let ((job-id (plist-get item :job-id)))
            (ogent-cabinet-run-job
             ogent-cabinet-tasks--root
             (plist-get item :agent)
             job-id)
          (ogent-cabinet-run-agent
           ogent-cabinet-tasks--root
           (plist-get item :agent)
           (read-string "Instruction: ")))))
      (_
       (user-error "No runnable Cabinet task at point")))))

(defun ogent-cabinet-tasks-archive ()
  "Archive the Cabinet task at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-ui--put-property
        (plist-get item :path)
        "OGENT_ENABLED"
        "nil"))
      ('session
       (ogent-cabinet-ui--put-property
        (plist-get item :path)
        "OGENT_ARCHIVED"
        "t"))
      (_
       (user-error "No archivable Cabinet task at point"))))
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-unarchive ()
  "Unarchive the Cabinet task at point."
  (interactive)
  (let ((item (ogent-cabinet-ui--item-at-point)))
    (pcase (plist-get item :type)
      ('job
       (ogent-cabinet-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil")
       (ogent-cabinet-ui--put-property (plist-get item :path) "OGENT_ENABLED" "t"))
      ('session
       (ogent-cabinet-ui--put-property (plist-get item :path) "OGENT_ARCHIVED" "nil"))
      (_
       (user-error "No archived Cabinet task at point"))))
  (ogent-cabinet-tasks-refresh))

(defun ogent-cabinet-tasks-edit ()
  "Edit metadata for the Cabinet task at point."
  (interactive)
  (let* ((item (ogent-cabinet-ui--item-at-point))
         (property (pcase (plist-get item :type)
                     ('job (completing-read "Property: "
                                            ogent-cabinet-job-editable-properties
                                            nil t))
                     ('session (completing-read "Property: "
                                                '("OGENT_ARCHIVED" "OGENT_TAGS")
                                                nil t))
                     (_ (user-error "No editable Cabinet task at point"))))
         (key (cdr (assoc property ogent-cabinet-job-property-keys)))
         (current (cond
                   ((and key (eq (plist-get item :type) 'job))
                    (format "%s" (or (plist-get item key) "")))
                   ((eq (plist-get item :type) 'session)
                    (with-temp-buffer
                      (insert-file-contents (plist-get item :path))
                      (ogent-cabinet--org-mode)
                      (ogent-cabinet--first-heading-title)
                      (org-entry-get nil property)))
                   (t "")))
         (value (ogent-cabinet-ui--read-property-value
                 ogent-cabinet-tasks--root
                 property
                 current
                 item)))
    (when (eq (plist-get item :type) 'job)
      (ogent-cabinet-validate-job
       (ogent-cabinet-ui--job-with-property item property value)))
    (ogent-cabinet-ui--put-property (plist-get item :path) property value)
    (ogent-cabinet-tasks-refresh)))

(defun ogent-cabinet-tasks-filter ()
  "Set simple task board filters."
  (interactive)
  (setq ogent-cabinet-tasks--filters
        (list :agent (ogent-cabinet--blank-to-nil
                      (ogent-cabinet-ui--read-optional-choice
                       "Agent filter: "
                       (ogent-cabinet-ui--agent-slugs
                        ogent-cabinet-tasks--root)))
              :status (ogent-cabinet--blank-to-nil
                       (ogent-cabinet-ui--read-optional-choice
                        "Status filter: "
                        (ogent-cabinet-ui--task-status-candidates
                         ogent-cabinet-tasks--root)))))
  (ogent-cabinet-tasks-refresh))

(provide 'ogent-ui-cabinet-tasks)
;;; ogent-ui-cabinet-tasks.el ends here
