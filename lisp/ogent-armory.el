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

(defcustom ogent-armory-default-agent-provider "default"
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

(defun ogent-armory-root-p (directory)
  "Return non-nil when DIRECTORY contains an Org armory index."
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
  "Return an Org index document for a armory."
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
         (heartbeat (ogent-armory--agent-plist-value
                     agent :heartbeat ogent-armory-default-heartbeat))
         (active (ogent-armory--agent-plist-value agent :active t))
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
        ("OGENT_HEARTBEAT" . ,heartbeat)
        ("OGENT_ACTIVE" . ,active)
        ("OGENT_WORKSPACE" . ,workspace)
        ("OGENT_TAGS" . ,tags)))
     "\n"
     (when body
       (concat (string-trim body) "\n")))))

(defun ogent-armory-write-agent (directory agent &optional body)
  "Write AGENT persona under DIRECTORY using BODY as instructions.
AGENT is a plist.  Required key: `:slug'.  Common keys include `:name',
`:role', `:provider', `:heartbeat', `:active', `:workspace', and `:tags'."
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
              :heartbeat (org-entry-get nil "OGENT_HEARTBEAT")
              :active (ogent-armory--truth-value
                       (org-entry-get nil "OGENT_ACTIVE"))
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
        ("OGENT_ENABLED" . ,enabled)))
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
              :enabled (ogent-armory--truth-value
                        (org-entry-get nil "OGENT_ENABLED"))
              :body (ogent-armory--heading-body))))))

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
                  edges)))))
    (list :root (directory-file-name root)
          :nodes (nreverse nodes)
          :edges (nreverse edges))))

(provide 'ogent-armory)

;;; ogent-armory.el ends here
