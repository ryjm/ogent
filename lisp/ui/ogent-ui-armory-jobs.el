;;; ogent-ui-armory-jobs.el --- Armory job list buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Tabulated list of Armory jobs and job lifecycle commands.

;;; Code:

(require 'ogent-ui-armory-core)

(defvar ogent-armory-jobs-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-jobs-visit))
    (define-key map "c" #'ogent-armory-create-job)
    (define-key map "e" #'ogent-armory-jobs-edit)
    (define-key map "P" #'ogent-armory-jobs-edit-prompt)
    (define-key map "R" #'ogent-armory-jobs-run)
    (define-key map "T" #'ogent-armory-jobs-toggle-enabled)
    (define-key map "A" #'ogent-armory-jobs-archive)
    (define-key map "g" #'ogent-armory-jobs-refresh)
    (define-key map "?" #'ogent-armory-jobs-dispatch)
    (define-key map "n" #'ogent-armory-ui-next-item)
    (define-key map "p" #'ogent-armory-ui-previous-item)
    (define-key map "j" ogent-armory-jump-map)
    (define-key map "," #'ogent-armory-settings)
    (define-key map "/" #'ogent-armory-command-palette)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-jobs-mode'.")

(ogent-armory-ui--define-prefix ogent-armory-jobs-dispatch ()
  "Dispatch menu for the Armory job list."
  [["Item"
    ("RET" "Visit job Org file" ogent-armory-jobs-visit)
    ("c" "Create job" ogent-armory-create-job)
    ("e" "Edit metadata" ogent-armory-jobs-edit)
    ("P" "Edit prompt/body" ogent-armory-jobs-edit-prompt)
    ("R" "Run job" ogent-armory-jobs-run)
    ("T" "Toggle enabled" ogent-armory-jobs-toggle-enabled)
    ("A" "Archive" ogent-armory-jobs-archive)]
   ["View"
    ("g" "Refresh" ogent-armory-jobs-refresh :transient t)]]
  ["Help"
   ("q" "Quit menu" transient-quit-one)])

(define-derived-mode ogent-armory-jobs-mode tabulated-list-mode "Armory-Jobs"
  "Major mode for Armory jobs."
  :group 'ogent-ui-armory
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
  (setq-local revert-buffer-function #'ogent-armory-jobs-refresh)
  (setq-local tabulated-list-use-header-line nil)
  (setq header-line-format
        '(:eval (ogent-section-header-line
                 "Jobs"
                 (concat (and ogent-armory-jobs--root
                              (ogent-armory-ui--root-label
                               ogent-armory-jobs--root))
                         (when ogent-armory-jobs--agent
                           (format " · %s" ogent-armory-jobs--agent)))
                 '("?" . "menu") '("j" . "jump") '("g" . "refresh"))))
  (tabulated-list-init-header))

(defun ogent-armory-job-next-run (job)
  "Return a friendly next-run description for JOB."
  (cond
   ((plist-get job :archived) "archived")
   ((not (plist-get job :enabled)) "disabled")
   ((ogent-armory--blank-to-nil (plist-get job :cron))
    (format "cron %s" (plist-get job :cron)))
   ((ogent-armory--blank-to-nil (plist-get job :run-after))
    (format "run after %s" (plist-get job :run-after)))
   ((ogent-armory--blank-to-nil (plist-get job :heartbeat))
    (format "heartbeat %s" (plist-get job :heartbeat)))
   (t "manual")))

(defun ogent-armory-jobs--entry (job)
  "Return a tabulated entry for JOB."
  (let* ((agent (plist-get job :agent))
         (job-id (plist-get job :id))
         (file (ogent-armory-job-file ogent-armory-jobs--root agent job-id)))
    (list
     (append (list :type 'job :path file :agent agent :job-id job-id) job)
     (vector
      agent
      (format "%s (%s)" (or (plist-get job :name) job-id) job-id)
      (if (plist-get job :enabled) "yes" "no")
      (ogent-armory-job-next-run job)
      (or (plist-get job :provider) "")
      (or (plist-get job :model) "")
      (or (plist-get job :workspace) "")
      (ogent-armory-ui--format-tags (plist-get job :tags))))))

(defun ogent-armory-jobs--entries ()
  "Return tabulated entries for the current jobs buffer."
  (mapcar #'ogent-armory-jobs--entry
          (ogent-armory-ui--all-jobs ogent-armory-jobs--root
                                     ogent-armory-jobs--agent)))

(defun ogent-armory-jobs (&optional directory agent)
  "Open Armory jobs for DIRECTORY, optionally narrowed to AGENT."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))
         nil))
  (let* ((root (ogent-armory-ui--root directory))
         (suffix (or agent "all"))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-jobs-buffer-name-format root suffix))))
    (with-current-buffer buffer
      (ogent-armory-jobs-mode)
      (setq ogent-armory-jobs--root root)
      (setq ogent-armory-jobs--agent agent)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-jobs--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-agent-jobs (&optional directory agent)
  "Open jobs for AGENT under DIRECTORY."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (slug (ogent-armory-ui--read-agent root)))
     (list root slug)))
  (ogent-armory-jobs directory agent))

(defun ogent-armory-jobs-refresh (&optional force &rest _)
  "Refresh the Armory jobs buffer.
With FORCE non-nil, invalidate cached Armory data first."
  (interactive "P")
  (ogent-armory-ui--invalidate-cache-when-force force ogent-armory-jobs--root)
  (tabulated-list-print t))

(defun ogent-armory-jobs--goto (agent job-id)
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

(defun ogent-armory-jobs--item ()
  "Return the job item at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory job at point")))

(defun ogent-armory-jobs-visit ()
  "Visit the Org file for the job at point."
  (interactive)
  (ogent-armory-ui--visit-path (plist-get (ogent-armory-jobs--item) :path)))

(defun ogent-armory-jobs-run ()
  "Run the job at point."
  (interactive)
  (let ((item (ogent-armory-jobs--item)))
    (ogent-armory-run-job ogent-armory-jobs--root
                          (plist-get item :agent)
                          (plist-get item :job-id))))

(defun ogent-armory-jobs-toggle-enabled ()
  "Toggle enabled state for the job at point."
  (interactive)
  (let* ((item (ogent-armory-jobs--item))
         (agent (plist-get item :agent))
         (job-id (plist-get item :job-id))
         (enabled (plist-get item :enabled)))
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     agent
     job-id
     "OGENT_ENABLED"
     (if enabled "nil" "t"))
    (ogent-armory-jobs-refresh)
    (ogent-armory-jobs--goto agent job-id)))

(defun ogent-armory-jobs-archive ()
  "Archive the job at point."
  (interactive)
  (let ((item (ogent-armory-jobs--item)))
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ARCHIVED"
     "t")
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     "OGENT_ENABLED"
     "nil")
    (ogent-armory-jobs-refresh)))

(defun ogent-armory-jobs-edit ()
  "Edit one metadata property for the job at point."
  (interactive)
  (let* ((item (ogent-armory-jobs--item))
         (property (completing-read "Property: "
                                    ogent-armory-job-editable-properties
                                    nil t))
         (key (cdr (assoc property ogent-armory-job-property-keys)))
         (current (when key
                    (format "%s" (or (plist-get item key) ""))))
         (value (ogent-armory-ui--read-property-value
                 ogent-armory-jobs--root
                 property
                 current
                 item))
         (candidate (ogent-armory-ui--job-with-property item property value)))
    (ogent-armory-validate-job candidate)
    (ogent-armory-update-job-property
     ogent-armory-jobs--root
     (plist-get item :agent)
     (plist-get item :job-id)
     property
     value)
    (ogent-armory-jobs-refresh)))

(defun ogent-armory-jobs-edit-prompt ()
  "Visit the job prompt/body for the job at point."
  (interactive)
  (ogent-armory-ui--visit-body
   (plist-get (ogent-armory-jobs--item) :path)))

(defun ogent-armory-create-job (&optional directory agent)
  "Create a Armory job under DIRECTORY for AGENT."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (slug (ogent-armory-ui--read-agent root)))
     (list root slug)))
  (let* ((root (ogent-armory-ui--root directory))
         (slug (or agent (ogent-armory-ui--read-agent root)))
         (agent-record (ogent-armory-resolve-agent
                        root slug :include-visible t))
         (name (read-string "Job name: "))
         (job-id (ogent-armory-ui--read-string-default
                  "Job id: "
                  (ogent-armory--slug name "job")))
         (cron (read-string "Cron: "))
         (heartbeat (read-string "Heartbeat: "))
         (provider (or (ogent-armory-ui--read-provider
                        "Provider override: "
                        "")
                       ""))
         (model-provider (or (ogent-armory--blank-to-nil provider)
                             (plist-get agent-record :provider)
                             (ogent-armory-ui--default-provider root)))
         (model (or (ogent-armory-ui--read-model
                     model-provider
                     "Model override: "
                     "")
                    ""))
         (workspace (ogent-armory-ui--read-string-default "Workspace: " "/"))
         (tags (ogent-armory--tags-from-string (read-string "Tags: ")))
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
    (when (file-exists-p (ogent-armory-job-file root slug job-id))
      (user-error "Job already exists: %s" job-id))
    (ogent-armory-validate-job job)
    (let ((file (ogent-armory-write-job root slug job prompt)))
      (ogent-armory-ui--refresh-home-buffer root)
      file)))

(defun ogent-armory-jobs--evil-local-keys ()
  "Install local Evil keys for Armory jobs buffers."
  (ogent-armory-evil-install-local-bindings ogent-armory-jobs-mode-map))

(defun ogent-armory-jobs--setup-evil ()
  "Set up Evil integration for Armory jobs buffers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-jobs-mode
   ogent-armory-jobs-mode-map
   'ogent-armory-jobs-mode-hook
   #'ogent-armory-jobs--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-jobs--setup-evil))

(provide 'ogent-ui-armory-jobs)
;;; ogent-ui-armory-jobs.el ends here
