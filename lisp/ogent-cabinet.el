;;; ogent-cabinet.el --- Org-native cabinet storage -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides the file-backed storage foundation for Cabinet-style knowledge
;; bases using Org files as the source of truth.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)

(defgroup ogent-cabinet nil
  "Org-native Cabinet-style knowledge bases."
  :group 'ogent)

(defcustom ogent-cabinet-default-agent-provider "default"
  "Default provider identifier for newly scaffolded agents."
  :type 'string
  :group 'ogent-cabinet)

(defcustom ogent-cabinet-default-heartbeat "0 9 * * 1-5"
  "Default cron expression for newly scaffolded agents."
  :type 'string
  :group 'ogent-cabinet)

(defconst ogent-cabinet--index-file "index.org"
  "File name for the root Org entry in a cabinet.")

(defconst ogent-cabinet--managed-directories
  '(".agents" ".agents/.conversations" ".jobs" ".cabinet-state")
  "Directories managed by the Org cabinet scaffold.")

(defun ogent-cabinet--directory (directory)
  "Return DIRECTORY as an expanded directory path."
  (file-name-as-directory (expand-file-name directory)))

(defun ogent-cabinet--slug (value &optional fallback)
  "Return VALUE normalized as a filesystem-safe slug.
Use FALLBACK when VALUE normalizes to the empty string."
  (let* ((base (downcase (string-trim (format "%s" (or value "")))))
         (spaced (replace-regexp-in-string "[[:space:]]+" "-" base))
         (clean (replace-regexp-in-string "[^[:alnum:]-]" "" spaced)))
    (if (string-empty-p clean)
        (or fallback "item")
      clean)))

(defun ogent-cabinet--truth-value (value)
  "Return t when VALUE represents true."
  (cond
   ((eq value t) t)
   ((null value) nil)
   ((stringp value)
    (not (null (member (downcase (string-trim value))
                       '("t" "true" "yes" "1")))))
   (t nil)))

(defun ogent-cabinet--property-value (value)
  "Return VALUE formatted for an Org property drawer."
  (cond
   ((eq value t) "t")
   ((null value) "")
   ((listp value)
    (string-join (mapcar (lambda (item) (format "%s" item)) value) ", "))
   (t (format "%s" value))))

(defun ogent-cabinet--format-properties (properties)
  "Return PROPERTIES as an Org property drawer.
PROPERTIES is an alist of property names to values."
  (concat
   ":PROPERTIES:\n"
   (mapconcat
    (lambda (property)
      (format ":%s: %s"
              (car property)
              (ogent-cabinet--property-value (cdr property))))
    properties
    "\n")
   "\n:END:\n"))

(defun ogent-cabinet--write-file (file content)
  "Write CONTENT to FILE, creating parent directories first."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert content)))

(defun ogent-cabinet--write-file-if-missing (file content)
  "Write CONTENT to FILE when FILE does not exist."
  (unless (file-exists-p file)
    (ogent-cabinet--write-file file content)))

(defun ogent-cabinet--tags-from-string (value)
  "Return tags parsed from VALUE."
  (if (string-blank-p (or value ""))
      nil
    (split-string value "[ \t]*,[ \t]*" t)))

(defun ogent-cabinet--heading-body ()
  "Return the body text under the current Org heading."
  (save-excursion
    (org-back-to-heading t)
    (org-end-of-meta-data t)
    (let ((begin (point))
          (end (save-excursion
                 (org-end-of-subtree t t)
                 (point))))
      (string-trim (buffer-substring-no-properties begin end)))))

(defun ogent-cabinet--first-heading-title ()
  "Return the title of the first Org heading in the current buffer."
  (goto-char (point-min))
  (unless (re-search-forward org-heading-regexp nil t)
    (user-error "No Org heading found"))
  (org-back-to-heading t)
  (nth 4 (org-heading-components)))

(defun ogent-cabinet-index-file (directory)
  "Return the cabinet index Org file under DIRECTORY."
  (expand-file-name ogent-cabinet--index-file
                    (ogent-cabinet--directory directory)))

(defun ogent-cabinet-agents-directory (directory)
  "Return the cabinet agents directory under DIRECTORY."
  (expand-file-name ".agents" (ogent-cabinet--directory directory)))

(defun ogent-cabinet-agent-directory (directory slug)
  "Return the directory for agent SLUG under DIRECTORY."
  (expand-file-name slug (ogent-cabinet-agents-directory directory)))

(defun ogent-cabinet-agent-file (directory slug)
  "Return the persona file for agent SLUG under DIRECTORY."
  (expand-file-name "persona.org"
                    (ogent-cabinet-agent-directory directory slug)))

(defun ogent-cabinet-job-file (directory agent-slug job-id)
  "Return the job file for JOB-ID owned by AGENT-SLUG under DIRECTORY."
  (expand-file-name
   (concat job-id ".org")
   (expand-file-name "jobs"
                     (ogent-cabinet-agent-directory directory agent-slug))))

(defun ogent-cabinet-root-p (directory)
  "Return non-nil when DIRECTORY contains an Org cabinet index."
  (let ((index (ogent-cabinet-index-file directory)))
    (and (file-exists-p index)
         (with-temp-buffer
           (insert-file-contents index nil 0 4096)
           (goto-char (point-min))
           (re-search-forward "^[ \t]*:OGENT_CABINET:[ \t]+t[ \t]*$" nil t)))))

(defun ogent-cabinet-find-root (&optional start)
  "Return the nearest cabinet root at or above START.
START defaults to `default-directory'."
  (let ((dir (ogent-cabinet--directory (or start default-directory)))
        (found nil)
        parent)
    (while (and dir (not found))
      (if (ogent-cabinet-root-p dir)
          (setq found dir)
        (setq parent (file-name-directory (directory-file-name dir)))
        (setq dir (unless (or (null parent) (equal parent dir))
                    parent))))
    (when found
      (directory-file-name found))))

(defun ogent-cabinet--format-index (name kind description body tags)
  "Return an Org index document for a cabinet."
  (let ((cabinet-id (format "%s-%s" (ogent-cabinet--slug name "cabinet") kind)))
    (concat
     (format "#+title: %s\n\n" name)
     (format "* %s\n" name)
     (ogent-cabinet--format-properties
      `(("OGENT_CABINET" . t)
        ("OGENT_CABINET_ID" . ,cabinet-id)
        ("OGENT_KIND" . ,kind)
        ("OGENT_DESCRIPTION" . ,(or description ""))
        ("OGENT_TAGS" . ,tags)))
     "\n"
     (when (and description (not (string-empty-p description)))
       (concat description "\n\n"))
     (when body
       (concat (string-trim body) "\n")))))

;;;###autoload
(cl-defun ogent-cabinet-scaffold
    (directory name &key (kind "root") description body tags create-editor skip-existing)
  "Create an Org-native cabinet named NAME in DIRECTORY.
When CREATE-EDITOR is non-nil, also create the built-in editor agent.
When SKIP-EXISTING is non-nil, keep an existing index file."
  (interactive
   (list (read-directory-name "Cabinet directory: ")
         (read-string "Cabinet name: ")))
  (let* ((root (ogent-cabinet--directory directory))
         (index (ogent-cabinet-index-file root)))
    (make-directory root t)
    (dolist (relative ogent-cabinet--managed-directories)
      (make-directory (expand-file-name relative root) t))
    (if (and skip-existing (file-exists-p index))
        index
      (ogent-cabinet--write-file
       index
       (ogent-cabinet--format-index name kind description body tags)))
    (when create-editor
      (ogent-cabinet-write-agent
       root
       `(:slug "editor"
         :name "Editor"
         :role "Knowledge base editor"
         :provider ,ogent-cabinet-default-agent-provider
         :heartbeat ,ogent-cabinet-default-heartbeat
         :active t
         :workspace "/"
         :tags ("editor" "knowledge"))
       "Maintain Org pages, links, summaries, and agent-facing context."))
    root))

(defun ogent-cabinet--agent-plist-value (agent key fallback)
  "Return AGENT plist KEY or FALLBACK."
  (if (plist-member agent key)
      (plist-get agent key)
    fallback))

(defun ogent-cabinet--ensure-agent-support-files (agent-dir)
  "Create support directories and memory files below AGENT-DIR."
  (let ((memory-dir (expand-file-name "memory" agent-dir)))
    (make-directory (expand-file-name "jobs" agent-dir) t)
    (make-directory (expand-file-name "sessions" agent-dir) t)
    (make-directory memory-dir t)
    (dolist (file '("context.org" "decisions.org" "learnings.org"))
      (ogent-cabinet--write-file-if-missing
       (expand-file-name file memory-dir)
       (format "#+title: %s\n\n" (file-name-base file))))))

(defun ogent-cabinet--format-agent (agent body)
  "Return AGENT and BODY formatted as an Org persona."
  (let* ((slug (ogent-cabinet--slug
                (ogent-cabinet--agent-plist-value agent :slug nil)
                "agent"))
         (name (ogent-cabinet--agent-plist-value agent :name slug))
         (role (ogent-cabinet--agent-plist-value agent :role "Agent"))
         (provider (ogent-cabinet--agent-plist-value
                    agent :provider ogent-cabinet-default-agent-provider))
         (heartbeat (ogent-cabinet--agent-plist-value
                     agent :heartbeat ogent-cabinet-default-heartbeat))
         (active (ogent-cabinet--agent-plist-value agent :active t))
         (workspace (ogent-cabinet--agent-plist-value agent :workspace "/"))
         (tags (ogent-cabinet--agent-plist-value agent :tags nil)))
    (concat
     (format "#+title: %s\n\n" name)
     (format "* %s\n" name)
     (ogent-cabinet--format-properties
      `(("OGENT_AGENT" . t)
        ("OGENT_SLUG" . ,slug)
        ("OGENT_ROLE" . ,role)
        ("OGENT_PROVIDER" . ,provider)
        ("OGENT_HEARTBEAT" . ,heartbeat)
        ("OGENT_ACTIVE" . ,active)
        ("OGENT_WORKSPACE" . ,workspace)
        ("OGENT_TAGS" . ,tags)))
     "\n"
     (when body
       (concat (string-trim body) "\n")))))

(defun ogent-cabinet-write-agent (directory agent &optional body)
  "Write AGENT persona under DIRECTORY using BODY as instructions.
AGENT is a plist.  Required key: `:slug'.  Common keys include `:name',
`:role', `:provider', `:heartbeat', `:active', `:workspace', and `:tags'."
  (let* ((slug (ogent-cabinet--slug
                (ogent-cabinet--agent-plist-value agent :slug nil)
                "agent"))
         (agent-dir (ogent-cabinet-agent-directory directory slug))
         (file (ogent-cabinet-agent-file directory slug)))
    (make-directory agent-dir t)
    (ogent-cabinet--ensure-agent-support-files agent-dir)
    (ogent-cabinet--write-file file (ogent-cabinet--format-agent agent body))
    file))

(defun ogent-cabinet-read-agent (directory slug)
  "Read agent SLUG from DIRECTORY and return a plist."
  (let ((file (ogent-cabinet-agent-file directory slug)))
    (unless (file-readable-p file)
      (user-error "Agent persona not found: %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let ((name (ogent-cabinet--first-heading-title)))
        (list :slug (or (org-entry-get nil "OGENT_SLUG") slug)
              :name name
              :role (org-entry-get nil "OGENT_ROLE")
              :provider (org-entry-get nil "OGENT_PROVIDER")
              :heartbeat (org-entry-get nil "OGENT_HEARTBEAT")
              :active (ogent-cabinet--truth-value
                       (org-entry-get nil "OGENT_ACTIVE"))
              :workspace (org-entry-get nil "OGENT_WORKSPACE")
              :tags (ogent-cabinet--tags-from-string
                     (org-entry-get nil "OGENT_TAGS"))
              :body (ogent-cabinet--heading-body))))))

(defun ogent-cabinet-list-agents (directory)
  "Return agent slugs present in DIRECTORY."
  (let ((agents-dir (ogent-cabinet-agents-directory directory)))
    (when (file-directory-p agents-dir)
      (seq-sort
       #'string<
       (seq-filter
        (lambda (name)
          (and (not (string-prefix-p "." name))
               (file-exists-p
                (ogent-cabinet-agent-file directory name))))
        (directory-files agents-dir nil directory-files-no-dot-files-regexp))))))

(defun ogent-cabinet--format-job (agent-slug job body)
  "Return JOB and BODY formatted as an Org task file for AGENT-SLUG."
  (let* ((id (ogent-cabinet--slug (plist-get job :id) "job"))
         (name (or (plist-get job :name) id))
         (cron (or (plist-get job :cron) ""))
         (enabled (if (plist-member job :enabled)
                      (plist-get job :enabled)
                    t)))
    (concat
     (format "#+title: %s\n\n" name)
     (format "* TODO %s\n" name)
     (ogent-cabinet--format-properties
      `(("OGENT_JOB" . t)
        ("OGENT_JOB_ID" . ,id)
        ("OGENT_AGENT" . ,agent-slug)
        ("OGENT_CRON" . ,cron)
        ("OGENT_ENABLED" . ,enabled)))
     "\n"
     (when body
       (concat (string-trim body) "\n")))))

(defun ogent-cabinet-write-job (directory agent-slug job &optional body)
  "Write JOB for AGENT-SLUG under DIRECTORY using BODY as instructions."
  (let* ((slug (ogent-cabinet--slug agent-slug "agent"))
         (id (ogent-cabinet--slug (plist-get job :id) "job"))
         (file (ogent-cabinet-job-file directory slug id)))
    (ogent-cabinet--write-file
     file
     (ogent-cabinet--format-job slug job body))
    file))

(defun ogent-cabinet-read-job (directory agent-slug job-id)
  "Read JOB-ID for AGENT-SLUG under DIRECTORY and return a plist."
  (let ((file (ogent-cabinet-job-file directory agent-slug job-id)))
    (unless (file-readable-p file)
      (user-error "Agent job not found: %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (let ((name (ogent-cabinet--first-heading-title)))
        (list :id (or (org-entry-get nil "OGENT_JOB_ID") job-id)
              :agent (or (org-entry-get nil "OGENT_AGENT") agent-slug)
              :name (replace-regexp-in-string "\\`TODO[ \t]+" "" name)
              :cron (org-entry-get nil "OGENT_CRON")
              :enabled (ogent-cabinet--truth-value
                        (org-entry-get nil "OGENT_ENABLED"))
              :body (ogent-cabinet--heading-body))))))

(provide 'ogent-cabinet)

;;; ogent-cabinet.el ends here
