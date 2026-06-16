;;; ogent-ui-cabinet-jobs.el --- Cabinet job list buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated list of Cabinet jobs and job lifecycle commands.

;;; Code:

(require 'ogent-ui-cabinet-core)

(defvar ogent-cabinet-jobs-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-jobs-visit))
    (define-key map "c" #'ogent-cabinet-create-job)
    (define-key map (kbd "C-c c") #'ogent-cabinet-create-job)
    (define-key map "e" #'ogent-cabinet-jobs-edit)
    (define-key map (kbd "C-c e") #'ogent-cabinet-jobs-edit)
    (define-key map "P" #'ogent-cabinet-jobs-edit-prompt)
    (define-key map (kbd "C-c p") #'ogent-cabinet-jobs-edit-prompt)
    (define-key map "R" #'ogent-cabinet-jobs-run)
    (define-key map (kbd "C-c r") #'ogent-cabinet-jobs-run)
    (define-key map "T" #'ogent-cabinet-jobs-toggle-enabled)
    (define-key map (kbd "C-c t") #'ogent-cabinet-jobs-toggle-enabled)
    (define-key map "A" #'ogent-cabinet-jobs-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-jobs-archive)
    (define-key map "g" #'ogent-cabinet-jobs-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-jobs-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-jobs-mode'.")

(define-derived-mode ogent-cabinet-jobs-mode tabulated-list-mode "Cabinet-Jobs"
  "Major mode for Cabinet jobs."
  :group 'ogent-ui-cabinet
  (setq-local tabulated-list-format
              [("Agent" 14 t)
               ("Job" 22 t)
               ("Enabled" 8 t)
               ("Next" 18 t)
               ("Provider" 10 t)
               ("Model" 12 t)
               ("Workspace" 16 t)
               ("Tags" 0 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Agent" . nil))
  (setq-local revert-buffer-function #'ogent-cabinet-jobs-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-job-next-run (job)
  "Return a friendly next-run description for JOB."
  (cond
   ((plist-get job :archived) "archived")
   ((not (plist-get job :enabled)) "disabled")
   ((ogent-cabinet--blank-to-nil (plist-get job :cron))
    (format "cron %s" (plist-get job :cron)))
   ((ogent-cabinet--blank-to-nil (plist-get job :run-after))
    (format "run after %s" (plist-get job :run-after)))
   ((ogent-cabinet--blank-to-nil (plist-get job :heartbeat))
    (format "heartbeat %s" (plist-get job :heartbeat)))
   (t "manual")))

(defun ogent-cabinet-jobs--entry (job)
  "Return a tabulated entry for JOB."
  (let* ((agent (plist-get job :agent))
         (job-id (plist-get job :id))
         (file (ogent-cabinet-job-file ogent-cabinet-jobs--root agent job-id)))
    (list
     (append (list :type 'job :path file :agent agent :job-id job-id) job)
     (vector
      agent
      (format "%s (%s)" (or (plist-get job :name) job-id) job-id)
      (if (plist-get job :enabled) "yes" "no")
      (ogent-cabinet-job-next-run job)
      (or (plist-get job :provider) "")
      (or (plist-get job :model) "")
      (or (plist-get job :workspace) "")
      (ogent-cabinet-ui--format-tags (plist-get job :tags))))))

(defun ogent-cabinet-jobs--entries ()
  "Return tabulated entries for the current jobs buffer."
  (mapcar #'ogent-cabinet-jobs--entry
          (ogent-cabinet-ui--all-jobs ogent-cabinet-jobs--root
                                      ogent-cabinet-jobs--agent)))

(defun ogent-cabinet-jobs (&optional directory agent)
  "Open Cabinet jobs for DIRECTORY, optionally narrowed to AGENT."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))
         nil))
  (let* ((root (ogent-cabinet-ui--root directory))
         (suffix (or agent "all"))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-jobs-buffer-name-format root suffix))))
    (with-current-buffer buffer
      (ogent-cabinet-jobs-mode)
      (setq ogent-cabinet-jobs--root root)
      (setq ogent-cabinet-jobs--agent agent)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-jobs--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-agent-jobs (&optional directory agent)
  "Open jobs for AGENT under DIRECTORY."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (slug (ogent-cabinet-ui--read-agent root)))
     (list root slug)))
  (ogent-cabinet-jobs directory agent))

(defun ogent-cabinet-jobs-refresh (&rest _)
  "Refresh the Cabinet jobs buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-jobs--goto (agent job-id)
  "Move to AGENT JOB-ID in the current jobs buffer when visible."
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

(defun ogent-cabinet-jobs--item ()
  "Return the job item at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet job at point")))

(defun ogent-cabinet-jobs-visit ()
  "Visit the Org file for the job at point."
  (interactive)
  (ogent-cabinet-ui--visit-path (plist-get (ogent-cabinet-jobs--item) :path)))

(defun ogent-cabinet-jobs-run ()
  "Run the job at point."
  (interactive)
  (let ((item (ogent-cabinet-jobs--item)))
    (ogent-cabinet-run-job ogent-cabinet-jobs--root
                           (plist-get item :agent)
                           (plist-get item :job-id))))

(defun ogent-cabinet-jobs-toggle-enabled ()
  "Toggle enabled state for the job at point."
  (interactive)
  (let* ((item (ogent-cabinet-jobs--item))
         (agent (plist-get item :agent))
         (job-id (plist-get item :job-id))
         (enabled (plist-get item :enabled)))
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     agent
     job-id
     "OGENT_ENABLED"
     (if enabled "nil" "t"))
    (ogent-cabinet-jobs-refresh)
    (ogent-cabinet-jobs--goto agent job-id)))

(defun ogent-cabinet-jobs-archive ()
  "Archive the job at point."
  (interactive)
  (let ((item (ogent-cabinet-jobs--item)))
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ARCHIVED"
     "t")
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ENABLED"
     "nil")
    (ogent-cabinet-jobs-refresh)))

(defun ogent-cabinet-jobs-edit ()
  "Edit one metadata property for the job at point."
  (interactive)
  (let* ((item (ogent-cabinet-jobs--item))
         (property (completing-read "Property: "
                                    ogent-cabinet-job-editable-properties
                                    nil t))
         (key (cdr (assoc property ogent-cabinet-job-property-keys)))
         (current (when key
                    (format "%s" (or (plist-get item key) ""))))
         (value (ogent-cabinet-ui--read-property-value
                 ogent-cabinet-jobs--root
                 property
                 current
                 item))
         (candidate (ogent-cabinet-ui--job-with-property item property value)))
    (ogent-cabinet-validate-job candidate)
    (ogent-cabinet-update-job-property
     ogent-cabinet-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     property
     value)
    (ogent-cabinet-jobs-refresh)))

(defun ogent-cabinet-jobs-edit-prompt ()
  "Visit the job prompt/body for the job at point."
  (interactive)
  (ogent-cabinet-ui--visit-body
   (plist-get (ogent-cabinet-jobs--item) :path)))

(defun ogent-cabinet-create-job (&optional directory agent)
  "Create a Cabinet job under DIRECTORY for AGENT."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (slug (ogent-cabinet-ui--read-agent root)))
     (list root slug)))
  (let* ((root (ogent-cabinet-ui--root directory))
         (slug (or agent (ogent-cabinet-ui--read-agent root)))
         (agent-record (ogent-cabinet-resolve-agent
                        root slug :include-visible t))
         (name (read-string "Job name: "))
         (job-id (ogent-cabinet-ui--read-string-default
                  "Job id: "
                  (ogent-cabinet--slug name "job")))
         (cron (read-string "Cron: "))
         (heartbeat (read-string "Heartbeat: "))
         (provider (or (ogent-cabinet-ui--read-provider
                        "Provider override: "
                        "")
                       ""))
         (model-provider (or (ogent-cabinet--blank-to-nil provider)
                             (plist-get agent-record :provider)
                             (ogent-cabinet-ui--default-provider root)))
         (model (or (ogent-cabinet-ui--read-model
                     model-provider
                     "Model override: "
                     "")
                    ""))
         (workspace (ogent-cabinet-ui--read-string-default "Workspace: " "/"))
         (tags (ogent-cabinet--tags-from-string (read-string "Tags: ")))
         (prompt (read-string "Prompt: "))
         (job (list :id job-id
                    :agent slug
                    :name name
                    :cron cron
                    :heartbeat heartbeat
                    :enabled t
                    :enabled-raw "t"
                    :provider provider
                    :model model
                    :workspace workspace
                    :tags tags)))
    (when (file-exists-p (ogent-cabinet-job-file root slug job-id))
      (user-error "Job already exists: %s" job-id))
    (ogent-cabinet-validate-job job)
    (let ((file (ogent-cabinet-write-job root slug job prompt)))
      (ogent-cabinet-ui--refresh-home-buffer root)
      file)))

(provide 'ogent-ui-cabinet-jobs)
;;; ogent-ui-cabinet-jobs.el ends here
