;;; ogent-armory.el --- Org-native armory storage -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides the file-backed storage foundation for Armory-style knowledge
;; bases using Org files as the source of truth.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)

(defgroup ogent-armory nil
  "Org-native Armory-style knowledge bases."
  :group 'ogent)

(defcustom ogent-armory-default-agent-provider "codex"
  "Default provider identifier for newly scaffolded agents."
  :type 'string
  :group 'ogent-armory)

(defcustom ogent-armory-default-heartbeat "0 9 * * 1-5"
  "Default cron expression for newly scaffolded agents."
  :type 'string
  :group 'ogent-armory)

(defconst ogent-armory--index-file "index.org"
  "File name for the root Org entry in a armory.")

(defconst ogent-armory--managed-directories
  '(".agents" ".agents/.conversations" ".jobs" ".armory-state")
  "Directories managed by the Org armory scaffold.")

(defun ogent-armory--directory (directory)
  "Return DIRECTORY as an expanded directory path."
  (file-name-as-directory (expand-file-name directory)))

(defun ogent-armory--slug (value &optional fallback)
  "Return VALUE normalized as a filesystem-safe slug.
Use FALLBACK when VALUE normalizes to the empty string."
  (let* ((base (downcase (string-trim (format "%s" (or value "")))))
         (spaced (replace-regexp-in-string "[[:space:]]+" "-" base))
         (clean (replace-regexp-in-string "[^[:alnum:]-]" "" spaced)))
    (if (string-empty-p clean)
        (or fallback "item")
      clean)))

(defun ogent-armory--truth-value (value)
  "Return t when VALUE represents true."
  (cond
   ((eq value t) t)
   ((null value) nil)
   ((stringp value)
    (not (null (member (downcase (string-trim value))
	                       '("t" "true" "yes" "1")))))
   (t nil)))

(defun ogent-armory--boolean-property-valid-p (value)
  "Return non-nil when VALUE is blank or a known boolean string."
  (or (null value)
      (string-blank-p value)
      (member (downcase (string-trim value))
              '("t" "true" "yes" "1" "nil" "false" "no" "0"))))

(defun ogent-armory--cron-expression-p (value)
  "Return non-nil when VALUE looks like a five-field cron expression."
  (let ((parts (split-string (string-trim (or value "")) "[ \t]+" t)))
    (= (length parts) 5)))

(defun ogent-armory--heartbeat-expression-p (value)
  "Return non-nil when VALUE looks like a heartbeat or cron expression."
  (let ((trimmed (string-trim (or value ""))))
    (or (string-match-p "\\`[0-9]+[smhdw]?\\'" trimmed)
        (ogent-armory--cron-expression-p trimmed))))

(defun ogent-armory--property-value (value)
  "Return VALUE formatted for an Org property drawer."
  (cond
   ((eq value t) "t")
   ((null value) "")
   ((listp value)
    (string-join (mapcar (lambda (item) (format "%s" item)) value) ", "))
   (t (format "%s" value))))

(defun ogent-armory--format-properties (properties)
  "Return PROPERTIES as an Org property drawer.
PROPERTIES is an alist of property names to values."
  (concat
   ":PROPERTIES:\n"
   (mapconcat
    (lambda (property)
      (format ":%s: %s"
              (car property)
              (ogent-armory--property-value (cdr property))))
    properties
    "\n")
   "\n:END:\n"))

(defun ogent-armory--write-file (file content)
  "Write CONTENT to FILE, creating parent directories first."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert content)))

(defun ogent-armory--write-file-if-missing (file content)
  "Write CONTENT to FILE when FILE does not exist."
  (unless (file-exists-p file)
    (ogent-armory--write-file file content)))

(defun ogent-armory--tags-from-string (value)
  "Return tags parsed from VALUE."
  (if (string-blank-p (or value ""))
      nil
    (split-string value "[ \t]*,[ \t]*" t)))

(defun ogent-armory--blank-to-nil (value)
  "Return nil when VALUE is nil or blank."
  (when (and value (not (string-blank-p value)))
    value))

(defun ogent-armory--heading-body ()
  "Return the body text under the current Org heading."
  (save-excursion
    (org-back-to-heading t)
    (org-end-of-meta-data t)
    (let ((begin (point))
          (end (save-excursion
                 (org-end-of-subtree t t)
                 (point))))
      (string-trim (buffer-substring-no-properties begin end)))))

(defun ogent-armory--first-heading-title ()
  "Return the title of the first Org heading in the current buffer."
  (goto-char (point-min))
  (unless (re-search-forward org-heading-regexp nil t)
    (user-error "No Org heading found"))
  (org-back-to-heading t)
  (nth 4 (org-heading-components)))

(defun ogent-armory-index-file (directory)
  "Return the armory index Org file under DIRECTORY."
  (expand-file-name ogent-armory--index-file
                    (ogent-armory--directory directory)))

(defun ogent-armory-agents-directory (directory)
  "Return the armory agents directory under DIRECTORY."
  (expand-file-name ".agents" (ogent-armory--directory directory)))

(defun ogent-armory-agent-directory (directory slug)
  "Return the directory for agent SLUG under DIRECTORY."
  (expand-file-name slug (ogent-armory-agents-directory directory)))

(defun ogent-armory-agent-file (directory slug)
  "Return the persona file for agent SLUG under DIRECTORY."
  (expand-file-name "persona.org"
                    (ogent-armory-agent-directory directory slug)))

(defun ogent-armory-job-file (directory agent-slug job-id)
  "Return the job file for JOB-ID owned by AGENT-SLUG under DIRECTORY."
  (expand-file-name
   (concat job-id ".org")
   (expand-file-name "jobs"
                     (ogent-armory-agent-directory directory agent-slug))))

(defun ogent-armory-jobs-directory (directory agent-slug)
  "Return the jobs directory for AGENT-SLUG under DIRECTORY."
  (expand-file-name "jobs"
                    (ogent-armory-agent-directory directory agent-slug)))

(defun ogent-armory-sessions-directory (directory agent-slug)
  "Return the sessions directory for AGENT-SLUG under DIRECTORY."
  (expand-file-name "sessions"
                    (ogent-armory-agent-directory directory agent-slug)))

(defun ogent-armory-agent-inbox-file (directory agent-slug)
  "Return the inbox Org file for AGENT-SLUG under DIRECTORY."
  (expand-file-name "inbox.org"
                    (ogent-armory-agent-directory directory agent-slug)))

(defun ogent-armory-agent-schedule-file (directory agent-slug)
  "Return the schedule Org file for AGENT-SLUG under DIRECTORY."
  (expand-file-name "schedule.org"
                    (ogent-armory-agent-directory directory agent-slug)))

(defun ogent-armory-agent-memory-directory (directory agent-slug)
  "Return the memory directory for AGENT-SLUG under DIRECTORY."
  (expand-file-name "memory"
                    (ogent-armory-agent-directory directory agent-slug)))

(defun ogent-armory-agent-memory-file (directory agent-slug name)
  "Return memory file NAME for AGENT-SLUG under DIRECTORY."
  (expand-file-name name
                    (ogent-armory-agent-memory-directory
                     directory agent-slug)))

(defun ogent-armory-root-p (directory)
  "Return non-nil when DIRECTORY has an Org armory index."
  (let ((index (ogent-armory-index-file directory)))
    (and (file-exists-p index)
         (with-temp-buffer
           (insert-file-contents index nil 0 4096)
           (goto-char (point-min))
           (re-search-forward "^[ \t]*:OGENT_ARMORY:[ \t]+t[ \t]*$" nil t)))))

(defun ogent-armory-find-root (&optional start)
  "Return the nearest armory root at or above START.
START defaults to `default-directory'."
  (let ((dir (ogent-armory--directory (or start default-directory)))
        (found nil)
        parent)
    (while (and dir (not found))
      (if (ogent-armory-root-p dir)
          (setq found dir)
        (setq parent (file-name-directory (directory-file-name dir)))
        (setq dir (unless (or (null parent) (equal parent dir))
                    parent))))
    (when found
      (directory-file-name found))))

(defun ogent-armory-read-index (directory)
  "Read the armory index under DIRECTORY and return a plist."
  (let ((file (ogent-armory-index-file directory)))
    (unless (file-readable-p file)
      (user-error "Armory index not found: %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let ((name (ogent-armory--first-heading-title)))
        (list :id (or (org-entry-get nil "OGENT_ARMORY_ID") "armory")
              :name name
              :kind (org-entry-get nil "OGENT_KIND")
              :description (org-entry-get nil "OGENT_DESCRIPTION")
              :tags (ogent-armory--tags-from-string
                     (org-entry-get nil "OGENT_TAGS"))
              :body (ogent-armory--heading-body)
              :path file)))))

(defun ogent-armory--format-index (name kind description body tags)
  "Return an Org index document for armory NAME.
KIND, DESCRIPTION, BODY, and TAGS supply the root metadata."
  (let ((armory-id (format "%s-%s" (ogent-armory--slug name "armory") kind)))
    (concat
     (format "#+title: %s\n\n" name)
     (format "* %s\n" name)
     (ogent-armory--format-properties
      `(("OGENT_ARMORY" . t)
        ("OGENT_ARMORY_ID" . ,armory-id)
        ("OGENT_KIND" . ,kind)
        ("OGENT_DESCRIPTION" . ,(or description ""))
        ("OGENT_TAGS" . ,tags)))
     "\n"
     (when (and description (not (string-empty-p description)))
       (concat description "\n\n"))
     (when body
       (concat (string-trim body) "\n")))))

;;;###autoload
(cl-defun ogent-armory-scaffold
    (directory name &key (kind "root") description body tags create-editor skip-existing)
  "Create an Org-native armory named NAME in DIRECTORY.
When CREATE-EDITOR is non-nil, also create the built-in editor agent.
When SKIP-EXISTING is non-nil, keep an existing index file."
  (interactive
   (list (read-directory-name "Armory directory: ")
         (read-string "Armory name: ")))
  (let* ((root (ogent-armory--directory directory))
         (index (ogent-armory-index-file root)))
    (make-directory root t)
    (dolist (relative ogent-armory--managed-directories)
      (make-directory (expand-file-name relative root) t))
    (if (and skip-existing (file-exists-p index))
        index
      (ogent-armory--write-file
       index
       (ogent-armory--format-index name kind description body tags)))
    (when create-editor
      (ogent-armory-write-agent
       root
       `(:slug "editor"
         :name "Editor"
         :role "Knowledge base editor"
         :provider ,ogent-armory-default-agent-provider
         :heartbeat ,ogent-armory-default-heartbeat
         :active t
         :workspace "/"
         :tags ("editor" "knowledge"))
       "Maintain Org pages, links, summaries, and agent-facing context."))
    root))

(defun ogent-armory--agent-plist-value (agent key fallback)
  "Return AGENT plist KEY or FALLBACK."
  (if (plist-member agent key)
      (plist-get agent key)
    fallback))

(defun ogent-armory--ensure-agent-support-files (agent-dir)
  "Create support directories and memory files below AGENT-DIR."
  (let ((memory-dir (expand-file-name "memory" agent-dir)))
    (make-directory (expand-file-name "jobs" agent-dir) t)
    (make-directory (expand-file-name "sessions" agent-dir) t)
    (make-directory memory-dir t)
    (ogent-armory--write-file-if-missing
     (expand-file-name "inbox.org" agent-dir)
     "#+title: Inbox\n\n* Inbox\n")
    (ogent-armory--write-file-if-missing
     (expand-file-name "schedule.org" agent-dir)
     "#+title: Schedule\n\n* Schedule\n")
    (dolist (file '("context.org" "decisions.org" "learnings.org"))
      (ogent-armory--write-file-if-missing
       (expand-file-name file memory-dir)
       (format "#+title: %s\n\n" (file-name-base file))))))

(defun ogent-armory--format-agent (agent body)
  "Return AGENT and BODY formatted as an Org persona."
  (let* ((slug (ogent-armory--slug
                (ogent-armory--agent-plist-value agent :slug nil)
                "agent"))
         (name (ogent-armory--agent-plist-value agent :name slug))
         (role (ogent-armory--agent-plist-value agent :role "Agent"))
         (provider (ogent-armory--agent-plist-value
                    agent :provider ogent-armory-default-agent-provider))
         (model (ogent-armory--agent-plist-value agent :model nil))
         (permission-mode (ogent-armory--agent-plist-value
                           agent :permission-mode nil))
         (heartbeat (ogent-armory--agent-plist-value
                     agent :heartbeat ogent-armory-default-heartbeat))
         (active (ogent-armory--agent-plist-value agent :active t))
         (archived (ogent-armory--agent-plist-value agent :archived nil))
         (workspace (ogent-armory--agent-plist-value agent :workspace "/"))
         (tags (ogent-armory--agent-plist-value agent :tags nil)))
    (concat
     (format "#+title: %s\n\n" name)
     (format "* %s\n" name)
     (ogent-armory--format-properties
      `(("OGENT_AGENT" . t)
        ("OGENT_SLUG" . ,slug)
        ("OGENT_ROLE" . ,role)
        ("OGENT_PROVIDER" . ,provider)
        ("OGENT_MODEL" . ,model)
        ("OGENT_PERMISSION_MODE" . ,permission-mode)
        ("OGENT_HEARTBEAT" . ,heartbeat)
        ("OGENT_ACTIVE" . ,active)
        ("OGENT_ARCHIVED" . ,archived)
        ("OGENT_WORKSPACE" . ,workspace)
        ("OGENT_TAGS" . ,tags)))
     "\n"
     (when body
       (concat (string-trim body) "\n")))))

(defun ogent-armory-write-agent (directory agent &optional body)
  "Write AGENT persona under DIRECTORY using BODY as instructions.
AGENT is a plist.  Required key: `:slug'.  Common keys include `:name',
`:role', `:provider', `:model', `:permission-mode', `:heartbeat',
`:active', `:workspace', and `:tags'."
  (let* ((slug (ogent-armory--slug
                (ogent-armory--agent-plist-value agent :slug nil)
                "agent"))
         (agent-dir (ogent-armory-agent-directory directory slug))
         (file (ogent-armory-agent-file directory slug)))
    (make-directory agent-dir t)
    (ogent-armory--ensure-agent-support-files agent-dir)
    (ogent-armory--write-file file (ogent-armory--format-agent agent body))
    file))

(defun ogent-armory-read-agent (directory slug)
  "Read agent SLUG from DIRECTORY and return a plist."
  (let ((file (ogent-armory-agent-file directory slug)))
    (unless (file-readable-p file)
      (user-error "Agent persona not found: %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let ((name (ogent-armory--first-heading-title)))
        (list :slug (or (org-entry-get nil "OGENT_SLUG") slug)
              :name name
              :role (org-entry-get nil "OGENT_ROLE")
              :provider (org-entry-get nil "OGENT_PROVIDER")
              :model (ogent-armory--blank-to-nil
                      (org-entry-get nil "OGENT_MODEL"))
              :permission-mode (ogent-armory--blank-to-nil
                                (org-entry-get nil "OGENT_PERMISSION_MODE"))
              :heartbeat (org-entry-get nil "OGENT_HEARTBEAT")
              :active (ogent-armory--truth-value
                       (org-entry-get nil "OGENT_ACTIVE"))
              :archived (ogent-armory--truth-value
                         (org-entry-get nil "OGENT_ARCHIVED"))
              :workspace (org-entry-get nil "OGENT_WORKSPACE")
              :tags (ogent-armory--tags-from-string
                     (org-entry-get nil "OGENT_TAGS"))
              :body (ogent-armory--heading-body))))))

(defun ogent-armory-list-agents (directory)
  "Return agent slugs present in DIRECTORY."
  (let ((agents-dir (ogent-armory-agents-directory directory)))
    (when (file-directory-p agents-dir)
      (seq-sort
       #'string<
       (seq-filter
        (lambda (name)
          (and (not (string-prefix-p "." name))
               (file-exists-p
                (ogent-armory-agent-file directory name))))
        (directory-files agents-dir nil directory-files-no-dot-files-regexp))))))

(defun ogent-armory-list-jobs (directory agent-slug)
  "Return jobs owned by AGENT-SLUG under DIRECTORY."
  (let ((jobs-dir (ogent-armory-jobs-directory directory agent-slug)))
    (when (file-directory-p jobs-dir)
      (seq-sort-by
       (lambda (job)
         (or (plist-get job :id) ""))
       #'string<
       (delq
        nil
        (mapcar
         (lambda (file)
           (when (and (file-regular-p file)
                      (string-equal (file-name-extension file) "org"))
             (ogent-armory-read-job directory agent-slug
                                     (file-name-base file))))
         (directory-files jobs-dir t "\\.org\\'")))))))

(defun ogent-armory--format-job (agent-slug job body)
  "Return JOB and BODY formatted as an Org task file for AGENT-SLUG."
  (let* ((id (ogent-armory--slug (plist-get job :id) "job"))
         (name (or (plist-get job :name) id))
         (cron (or (plist-get job :cron) ""))
         (heartbeat (or (plist-get job :heartbeat) ""))
         (provider (or (plist-get job :provider) ""))
         (model (or (plist-get job :model) ""))
         (workspace (or (plist-get job :workspace) ""))
         (tags (plist-get job :tags))
         (archived (plist-get job :archived))
         (enabled (if (plist-member job :enabled)
                      (plist-get job :enabled)
                    t)))
    (concat
     (format "#+title: %s\n\n" name)
     (format "* TODO %s\n" name)
     (ogent-armory--format-properties
      `(("OGENT_JOB" . t)
        ("OGENT_JOB_ID" . ,id)
        ("OGENT_AGENT" . ,agent-slug)
        ("OGENT_CRON" . ,cron)
        ("OGENT_HEARTBEAT" . ,heartbeat)
        ("OGENT_ENABLED" . ,enabled)
        ("OGENT_PROVIDER" . ,provider)
        ("OGENT_MODEL" . ,model)
        ("OGENT_WORKSPACE" . ,workspace)
        ("OGENT_TAGS" . ,tags)
        ("OGENT_ARCHIVED" . ,archived)))
     "\n"
     (when body
       (concat (string-trim body) "\n")))))

(defun ogent-armory-write-job (directory agent-slug job &optional body)
  "Write JOB for AGENT-SLUG under DIRECTORY using BODY as instructions."
  (let* ((slug (ogent-armory--slug agent-slug "agent"))
         (id (ogent-armory--slug (plist-get job :id) "job"))
         (file (ogent-armory-job-file directory slug id)))
    (ogent-armory--write-file
     file
     (ogent-armory--format-job slug job body))
    file))

(defun ogent-armory-read-job (directory agent-slug job-id)
  "Read JOB-ID for AGENT-SLUG under DIRECTORY and return a plist."
  (let ((file (ogent-armory-job-file directory agent-slug job-id)))
    (unless (file-readable-p file)
      (user-error "Agent job not found: %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let ((name (ogent-armory--first-heading-title)))
        (list :id (or (org-entry-get nil "OGENT_JOB_ID") job-id)
              :agent (or (org-entry-get nil "OGENT_AGENT") agent-slug)
              :name (replace-regexp-in-string "\\`TODO[ \t]+" "" name)
              :cron (org-entry-get nil "OGENT_CRON")
              :heartbeat (ogent-armory--blank-to-nil
                          (org-entry-get nil "OGENT_HEARTBEAT"))
              :enabled-raw (org-entry-get nil "OGENT_ENABLED")
              :enabled (ogent-armory--truth-value
                        (org-entry-get nil "OGENT_ENABLED"))
              :provider (ogent-armory--blank-to-nil
                         (org-entry-get nil "OGENT_PROVIDER"))
              :model (ogent-armory--blank-to-nil
                      (org-entry-get nil "OGENT_MODEL"))
              :workspace (ogent-armory--blank-to-nil
                          (org-entry-get nil "OGENT_WORKSPACE"))
              :tags (ogent-armory--tags-from-string
                     (org-entry-get nil "OGENT_TAGS"))
              :archived-raw (org-entry-get nil "OGENT_ARCHIVED")
              :archived (ogent-armory--truth-value
                         (org-entry-get nil "OGENT_ARCHIVED"))
              :body (ogent-armory--heading-body))))))

(defun ogent-armory-job-validation-errors (job)
  "Return a list of friendly validation errors for JOB metadata."
  (let (errors)
    (unless (ogent-armory--blank-to-nil (plist-get job :id))
      (push "OGENT_JOB_ID is required" errors))
    (unless (ogent-armory--blank-to-nil (plist-get job :agent))
      (push "OGENT_AGENT is required" errors))
    (unless (ogent-armory--blank-to-nil (plist-get job :name))
      (push "Job heading is required" errors))
    (when-let ((cron (ogent-armory--blank-to-nil (plist-get job :cron))))
      (unless (ogent-armory--cron-expression-p cron)
        (push (format "OGENT_CRON must have five fields: %s" cron) errors)))
    (when-let ((heartbeat (ogent-armory--blank-to-nil
                           (plist-get job :heartbeat))))
      (unless (ogent-armory--heartbeat-expression-p heartbeat)
        (push (format "OGENT_HEARTBEAT must be a number, interval, or five-field cron: %s"
                      heartbeat)
              errors)))
    (unless (ogent-armory--boolean-property-valid-p
             (plist-get job :enabled-raw))
      (push (format "OGENT_ENABLED must be t or nil: %s"
                    (plist-get job :enabled-raw))
            errors))
    (unless (ogent-armory--boolean-property-valid-p
             (plist-get job :archived-raw))
      (push (format "OGENT_ARCHIVED must be t or nil: %s"
                    (plist-get job :archived-raw))
            errors))
    (nreverse errors)))

(defun ogent-armory-validate-job (job)
  "Signal a friendly error when JOB metadata is malformed."
  (let ((errors (ogent-armory-job-validation-errors job)))
    (when errors
      (user-error "Malformed Armory job metadata for %s: %s"
                  (or (plist-get job :id) "<missing job id>")
                  (string-join errors "; "))))
  job)

(defun ogent-armory--update-first-heading-property (file property value)
  "Set PROPERTY to VALUE in the first Org heading of FILE."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (org-mode)
      (goto-char (point-min))
      (unless (re-search-forward org-heading-regexp nil t)
        (user-error "No Org heading found in %s" file))
      (org-back-to-heading t)
      (org-entry-put nil property (ogent-armory--property-value value))
      (save-buffer))))

(defun ogent-armory-update-index-property (directory property value)
  "Set Armory index PROPERTY to VALUE under DIRECTORY."
  (ogent-armory--update-first-heading-property
   (ogent-armory-index-file directory)
   property
   value))

(defun ogent-armory-update-agent-property (directory agent-slug property value)
  "Set AGENT-SLUG persona PROPERTY to VALUE under DIRECTORY."
  (ogent-armory--update-first-heading-property
   (ogent-armory-agent-file directory agent-slug)
   property
   value))

(defun ogent-armory-update-job-property (directory agent-slug job-id property value)
  "Set JOB-ID PROPERTY to VALUE for AGENT-SLUG under DIRECTORY."
  (ogent-armory--update-first-heading-property
   (ogent-armory-job-file directory agent-slug job-id)
   property
   value))

(defun ogent-armory-update-session-property (file property value)
  "Set session transcript FILE PROPERTY to VALUE."
  (ogent-armory--update-first-heading-property file property value))

(defun ogent-armory--status-symbol (status exit-status)
  "Return normalized session status from STATUS and EXIT-STATUS."
  (cond
   ((and exit-status (not (zerop exit-status))) "FAILED")
   ((and status (not (string-blank-p status))) status)
   (t "DONE")))

(defun ogent-armory-read-session-file (file &optional agent-slug)
  "Read Armory session transcript FILE and return a plist.
When AGENT-SLUG is non-nil, use it as a fallback for missing metadata."
  (unless (file-readable-p file)
    (user-error "Armory session not found: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let* ((name (ogent-armory--first-heading-title))
           (todo (nth 2 (org-heading-components)))
           (exit-status-text (ogent-armory--blank-to-nil
                              (org-entry-get nil "OGENT_EXIT_STATUS")))
           (exit-status (when exit-status-text
                          (string-to-number exit-status-text)))
           (agent (or (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_AGENT"))
                      agent-slug)))
      (list :id (file-name-base file)
            :name name
            :agent agent
            :provider (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_PROVIDER"))
            :model (ogent-armory--blank-to-nil
                    (org-entry-get nil "OGENT_MODEL"))
            :job-id (ogent-armory--blank-to-nil
                     (org-entry-get nil "OGENT_JOB_ID"))
            :exit-status exit-status
            :status (ogent-armory--status-symbol todo exit-status)
            :workspace (ogent-armory--blank-to-nil
                        (org-entry-get nil "OGENT_WORKSPACE"))
            :duration (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_DURATION"))
            :finished (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_FINISHED"))
            :tags (ogent-armory--tags-from-string
                   (org-entry-get nil "OGENT_TAGS"))
            :app-paths (ogent-armory--tags-from-string
                        (org-entry-get nil "OGENT_APP_PATHS"))
            :archived (ogent-armory--truth-value
                       (org-entry-get nil "OGENT_ARCHIVED"))
            :body (ogent-armory--heading-body)
            :path file))))

(defun ogent-armory--section-text (heading)
  "Return text under Org subsection HEADING in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t)
          found)
      (while (and (not found)
                  (re-search-forward org-heading-regexp nil t))
        (when (equal (downcase (string-trim (nth 4 (org-heading-components))))
                     (downcase heading))
          (setq found t)))
      (when found
        (org-end-of-meta-data t)
        (let ((begin (point))
              (end (save-excursion
                     (org-end-of-subtree t t)
                     (point))))
          (string-trim
           (buffer-substring-no-properties begin end)))))))

(defun ogent-armory--strip-src-wrapper (text)
  "Return TEXT with one surrounding Org src block removed when present."
  (let ((value (string-trim (or text ""))))
    (if (string-match
         "\\`#\\+begin_src[^\n]*\n\\(\\(?:.\\|\n\\)*?\\)\n#\\+end_src\\'"
         value)
        (string-trim (match-string 1 value))
      value)))

(defun ogent-armory--tool-blocks ()
  "Return Org tool blocks in the current buffer."
  (let (tools)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^#\\+begin_tool\\([^\n]*\\)$" nil t)
        (let ((header (string-trim (match-string 1)))
              (begin (line-beginning-position 2)))
          (when (re-search-forward "^#\\+end_tool" nil t)
            (push (list :header header
                        :body (string-trim
                               (buffer-substring-no-properties
                                begin
                                (line-beginning-position))))
                  tools)))))
    (nreverse tools)))

(defun ogent-armory-session-detail (file &optional agent-slug)
  "Read conversation FILE and return metadata plus transcript sections.
AGENT-SLUG is a fallback for older transcripts with sparse properties."
  (let ((record (ogent-armory-read-session-file file agent-slug)))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (append
       record
       (list :prompt (ogent-armory--strip-src-wrapper
                      (ogent-armory--section-text "Prompt"))
             :output (ogent-armory--strip-src-wrapper
                      (ogent-armory--section-text "Output"))
             :error (ogent-armory--strip-src-wrapper
                     (ogent-armory--section-text "Error"))
             :tools (ogent-armory--tool-blocks))))))

(defun ogent-armory-list-sessions (directory &optional agent-slug)
  "Return Armory sessions under DIRECTORY.
When AGENT-SLUG is non-nil, only return sessions for that agent."
  (let* ((root (ogent-armory--directory directory))
         (slugs (if agent-slug
                    (list agent-slug)
                  (ogent-armory-list-agents root)))
         sessions)
    (dolist (slug slugs)
      (let ((sessions-dir (ogent-armory-sessions-directory root slug)))
        (when (file-directory-p sessions-dir)
          (dolist (file (directory-files sessions-dir t "\\.org\\'"))
            (when (file-regular-p file)
              (push (ogent-armory-read-session-file file slug) sessions))))))
    (seq-sort
     (lambda (left right)
       (string> (or (plist-get left :finished) "")
                (or (plist-get right :finished) "")))
     sessions)))

(defun ogent-armory--hidden-path-p (root file)
  "Return non-nil when FILE below ROOT is internal Armory plumbing."
  (let ((relative (file-relative-name file root)))
    (string-match-p
     "\\`\\(?:\\.git\\|\\.armory-state\\|\\.agents/.conversations\\)/"
     relative)))

(defun ogent-armory-org-files (directory)
  "Return Armory Org files under DIRECTORY."
  (let* ((root (ogent-armory--directory directory))
         (files (directory-files-recursively root "\\.org\\'")))
    (seq-filter
     (lambda (file)
       (not (ogent-armory--hidden-path-p root file)))
     files)))

(defun ogent-armory-record-metadata (file)
  "Return metadata plist for the Armory Org record in FILE."
  (with-temp-buffer
    (insert-file-contents file nil 0 nil)
    (org-mode)
    (condition-case nil
        (progn
          (let ((heading (ogent-armory--first-heading-title)))
            (list
             :kind (cond
                    ((org-entry-get nil "OGENT_ARMORY") 'armory)
                    ((org-entry-get nil "OGENT_AGENT") 'agent)
                    ((org-entry-get nil "OGENT_JOB") 'job)
                    ((org-entry-get nil "OGENT_SESSION") 'session)
                    ((org-entry-get nil "OGENT_IMPORT") 'import)
                    ((org-entry-get nil "OGENT_ISSUE_ID") 'issue-link)
                    (t 'org))
             :heading heading
             :agent (or (ogent-armory--blank-to-nil
                         (org-entry-get nil "OGENT_AGENT"))
                        (ogent-armory--blank-to-nil
                         (org-entry-get nil "OGENT_SLUG")))
             :status (or (nth 2 (org-heading-components))
                         (ogent-armory--blank-to-nil
                          (org-entry-get nil "OGENT_STATUS")))
             :tags (append (org-get-tags nil t)
                           (ogent-armory--tags-from-string
                            (org-entry-get nil "OGENT_TAGS")))
             :archived (ogent-armory--truth-value
                        (org-entry-get nil "OGENT_ARCHIVED"))
             :issue-id (ogent-armory--blank-to-nil
                        (org-entry-get nil "OGENT_ISSUE_ID"))
             :assigned-worker (ogent-armory--blank-to-nil
                               (org-entry-get nil "OGENT_ASSIGNED_WORKER")))))
      (error (list :kind 'org :heading nil :tags nil)))))

(defun ogent-armory-record-kind (file)
  "Return the Armory record kind represented by FILE."
  (plist-get (ogent-armory-record-metadata file) :kind))

(defun ogent-armory--record-matches-filters-p (metadata kind agent status tag archived)
  "Return non-nil when METADATA matches supplied search filters."
  (and (or (null kind) (eq (plist-get metadata :kind) kind))
       (or (null agent) (equal (plist-get metadata :agent) agent))
       (or (null status) (equal (plist-get metadata :status) status))
       (or (null tag) (member tag (plist-get metadata :tags)))
       (or (null archived)
           (eq (plist-get metadata :archived)
               (ogent-armory--truth-value archived)))))

(cl-defun ogent-armory-search-records
    (directory query &key kind agent status tag archived)
  "Return Armory search matches for QUERY under DIRECTORY.
Optional filters narrow by KIND, AGENT, STATUS, TAG, and ARCHIVED state."
  (let ((root (ogent-armory--directory directory))
        (case-fold-search t)
        (regexp (regexp-quote (or query "")))
        results)
    (unless (string-blank-p (or query ""))
      (dolist (file (ogent-armory-org-files root))
        (let ((metadata (ogent-armory-record-metadata file)))
          (when (ogent-armory--record-matches-filters-p
                 metadata kind agent status tag archived)
            (let ((line-number 0))
              (with-temp-buffer
                (insert-file-contents file)
                (goto-char (point-min))
                (while (not (eobp))
                  (setq line-number (1+ line-number))
                  (let ((line (buffer-substring-no-properties
                               (line-beginning-position)
                               (line-end-position))))
                    (when (string-match-p regexp line)
                      (push (append
                             (list :path file
                                   :line line-number
                                   :text (string-trim line))
                             metadata)
                            results)))
                  (forward-line 1))))))))
    (nreverse results)))

(defun ogent-armory--app-owner (root relative)
  "Return owner metadata for app RELATIVE under ROOT."
  (or
   (seq-find
    (lambda (session)
      (member relative (plist-get session :app-paths)))
    (ogent-armory-list-sessions root))
   (let ((parts (split-string relative "/" t)))
     (when (and (equal (car parts) ".agents") (cadr parts))
       (list :agent (cadr parts))))))

(defun ogent-armory-list-apps (directory)
  "Return Armory app artifacts under DIRECTORY.
An app artifact is a directory containing an index.html file."
  (let* ((root (ogent-armory--directory directory))
         (files (directory-files-recursively root "index\\.html\\'"))
         apps)
    (dolist (file files)
      (unless (ogent-armory--hidden-path-p root file)
        (let* ((dir (file-name-directory file))
               (relative (directory-file-name
                          (file-relative-name dir root)))
               (owner (ogent-armory--app-owner root relative))
               (attrs (file-attributes file)))
          (push (list :label (if (string-empty-p relative) "." relative)
                      :directory (directory-file-name dir)
                      :path file
                      :modified (format-time-string
                                 "%Y-%m-%d %H:%M"
                                 (file-attribute-modification-time attrs))
                      :agent (plist-get owner :agent)
                      :job-id (plist-get owner :job-id)
                      :session-id (plist-get owner :id)
                      :session-path (plist-get owner :path))
                apps))))
    (seq-sort-by (lambda (app) (plist-get app :label)) #'string< apps)))

(defun ogent-armory--graph-node (id kind label path data)
  "Return a graph node plist for ID, KIND, LABEL, PATH, and DATA."
  (list :id id
        :kind kind
        :label label
        :path path
        :data data))

(defun ogent-armory--graph-edge (from to kind &optional data)
  "Return a graph edge plist from FROM to TO with KIND and DATA."
  (let ((edge (list :from from :to to :kind kind)))
    (if data
        (plist-put edge :data data)
      edge)))

(defun ogent-armory--issue-links (root)
  "Return Org records under ROOT with issue link metadata."
  (let (links)
    (dolist (file (ogent-armory-org-files root))
      (let ((metadata (ogent-armory-record-metadata file)))
        (when (plist-get metadata :issue-id)
          (push (append (list :path file) metadata) links))))
    (nreverse links)))

(defun ogent-armory--gastown-hook-node (root)
  "Return a Gas Town hook node for ROOT when one is discoverable."
  (let ((town-root (or (locate-dominating-file root ".gastown")
                       (getenv "GT_ROOT")
                       (getenv "GT_TOWN"))))
    (when town-root
      (list :id "gastown:hook"
            :kind 'gastown-hook
            :label "Gas Town Hook"
            :path (directory-file-name town-root)
            :data (list :root (directory-file-name town-root))))))

(defun ogent-armory-build-graph (directory)
  "Return a typed graph projection for the Org armory under DIRECTORY.
The returned plist has `:nodes' and `:edges' collections suitable for
status buffers, future incremental indexes, and automation planners."
  (let* ((candidate (ogent-armory--directory directory))
         (root (file-truename
                (ogent-armory--directory
                 (or (ogent-armory-find-root candidate)
                     candidate))))
         (index (ogent-armory-read-index root))
         (armory-id "armory:.")
         (nodes (list (ogent-armory--graph-node
                       armory-id
                       'armory
                       (plist-get index :name)
                       (plist-get index :path)
                       index)))
         (edges nil))
    (dolist (slug (ogent-armory-list-agents root))
      (let* ((agent (ogent-armory-read-agent root slug))
             (agent-id (format "agent:%s" slug)))
        (push (ogent-armory--graph-node
               agent-id
               'agent
               (or (plist-get agent :name) slug)
               (ogent-armory-agent-file root slug)
               agent)
              nodes)
        (push (ogent-armory--graph-edge armory-id agent-id 'contains)
              edges)
        (dolist (job (ogent-armory-list-jobs root slug))
          (let* ((job-id (plist-get job :id))
                 (node-id (format "job:%s/%s" slug job-id)))
            (push (ogent-armory--graph-node
                   node-id
                   'job
                   (or (plist-get job :name) job-id)
                   (ogent-armory-job-file root slug job-id)
                   job)
                  nodes)
            (push (ogent-armory--graph-edge agent-id node-id 'owns)
                  edges)
            (push (ogent-armory--graph-edge node-id agent-id 'scheduled-by)
                  edges)))
        (dolist (session (ogent-armory-list-sessions root slug))
          (let* ((session-id (plist-get session :id))
                 (node-id (format "session:%s/%s" slug session-id))
                 (job-id (plist-get session :job-id)))
            (push (ogent-armory--graph-node
                   node-id
                   'session
                   (or (plist-get session :name) session-id)
                   (plist-get session :path)
                   session)
                  nodes)
            (push (ogent-armory--graph-edge agent-id node-id 'produced)
                  edges)
            (when (plist-get session :archived)
              (push (ogent-armory--graph-edge armory-id node-id 'archived-from)
                    edges))
            (when (and job-id (not (string-empty-p job-id)))
              (push (ogent-armory--graph-edge
                     (format "job:%s/%s" slug job-id)
                     node-id
                     (if (equal (plist-get session :status) "FAILED")
                         'failed-from
                       'produced))
                    edges))))))
    (dolist (app (ogent-armory-list-apps root))
      (let* ((label (plist-get app :label))
             (node-id (format "app:%s" label)))
        (push (ogent-armory--graph-node
               node-id
               'app
               label
               (plist-get app :path)
               app)
              nodes)
        (push (ogent-armory--graph-edge armory-id node-id 'contains)
              edges)
        (when-let ((session-id (plist-get app :session-id)))
          (let ((session-node (format "session:%s/%s"
                                      (plist-get app :agent)
                                      session-id)))
            (push (ogent-armory--graph-edge session-node node-id 'produced)
                  edges)))))
    (dolist (issue (ogent-armory--issue-links root))
      (let* ((issue-id (plist-get issue :issue-id))
             (node-id (format "issue:%s" issue-id))
             (worker (plist-get issue :assigned-worker)))
        (push (ogent-armory--graph-node
               node-id
               'issue
               issue-id
               (plist-get issue :path)
               issue)
              nodes)
        (push (ogent-armory--graph-edge armory-id node-id 'linked-issue)
              edges)
        (when worker
          (push (ogent-armory--graph-edge node-id
                                           (format "agent:%s" worker)
                                           'assigned-worker)
                edges))))
    (when-let ((hook (ogent-armory--gastown-hook-node root)))
      (push hook nodes)
      (push (ogent-armory--graph-edge armory-id
                                       (plist-get hook :id)
                                       'contains)
            edges))
    (list :root (directory-file-name root)
          :nodes (nreverse nodes)
          :edges (nreverse edges))))

(defun ogent-armory--import-target-file (root source-file)
  "Return Org import target under ROOT for SOURCE-FILE."
  (expand-file-name
   (concat (ogent-armory--slug (file-name-base source-file) "import") ".org")
   (expand-file-name "imports" root)))

(defun ogent-armory--markdown-to-org (text)
  "Return a small Markdown-to-Org conversion for TEXT."
  (mapconcat
   (lambda (line)
     (if (string-match "\\`\\(#+\\)[ \t]+\\(.*\\)\\'" line)
         (format "%s %s"
                 (make-string (length (match-string 1 line)) ?*)
                 (match-string 2 line))
       line))
   (split-string (or text "") "\n")
   "\n"))

(defun ogent-armory--import-body (file text)
  "Return Org body for imported FILE containing TEXT."
  (pcase (downcase (or (file-name-extension file) ""))
    ("md" (ogent-armory--markdown-to-org text))
    ("html" (concat "#+begin_src html\n" text "\n#+end_src\n"))
    (_ text)))

(defun ogent-armory--import-record (root file)
  "Import FILE into ROOT as an Org record and return its metadata."
  (let* ((target (ogent-armory--import-target-file root file))
         (title (file-name-base file))
         (extension (downcase (or (file-name-extension file) "")))
         (text (with-temp-buffer
                 (insert-file-contents file)
                 (buffer-string)))
         (relative (file-relative-name file (file-name-directory file))))
    (ogent-armory--write-file
     target
     (concat
      (format "#+title: %s\n\n" title)
      (format "* %s\n" title)
      (ogent-armory--format-properties
       `(("OGENT_IMPORT" . t)
         ("OGENT_SOURCE_PATH" . ,file)
         ("OGENT_SOURCE_FORMAT" . ,extension)))
      "\n"
      (ogent-armory--import-body file text)
      "\n"))
    (list :path target
          :source file
          :label relative
          :kind 'import)))

(cl-defun ogent-armory-import-artifacts
    (directory artifact-directory &key (keep-originals t))
  "Import ARTIFACT-DIRECTORY artifacts into Armory DIRECTORY as Org records.
KEEP-ORIGINALS is accepted for the command contract.  Original files remain in
place by default; this importer only writes Org Armory records."
  (let* ((root (ogent-armory--directory directory))
         (source (ogent-armory--directory artifact-directory))
         (files (directory-files-recursively source "\\.\\(?:md\\|html\\|txt\\)\\'"))
         records)
    (unless keep-originals
      (user-error "Destructive import is not implemented; original files are kept"))
    (dolist (file files)
      (unless (file-directory-p file)
        (push (ogent-armory--import-record root file) records)))
    (nreverse records)))

(provide 'ogent-armory)

;;; ogent-armory.el ends here
