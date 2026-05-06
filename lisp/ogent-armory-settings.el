;;; ogent-armory-settings.el --- Armory settings and onboarding -*- lexical-binding: t; -*-

;;; Commentary:
;; Armory-local settings, onboarding, registry import, backup, help, and demo
;; commands.  Durable state lives in Org files under the Armory root.

;;; Code:

(require 'cl-lib)
(require 'files)
(require 'json)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'ogent-armory)
(require 'ogent-armory-adapter)
(require 'ogent-armory-data)

(defgroup ogent-armory-settings nil
  "Armory settings, onboarding, registry import, and help."
  :group 'ogent-armory)

(defcustom ogent-armory-settings-buffer-name-format "*ogent-armory-settings:%s*"
  "Format string used for Armory settings buffers."
  :type 'string
  :group 'ogent-armory-settings)

(defcustom ogent-armory-help-buffer-name "*ogent-armory-help*"
  "Buffer name used for Armory help."
  :type 'string
  :group 'ogent-armory-settings)

(defcustom ogent-armory-backup-directory-name ".armory-state/backups"
  "Directory under a Armory root where filtered backups are written."
  :type 'string
  :group 'ogent-armory-settings)

(defvar-local ogent-armory-settings--root nil
  "Armory root shown by the current settings buffer.")

(defconst ogent-armory-settings--fields
  '((:key :profile-name :property "OGENT_PROFILE_NAME" :section "Profile"
     :label "Profile name" :type string)
    (:key :profile-avatar :property "OGENT_PROFILE_AVATAR" :section "Profile"
     :label "Profile avatar" :type string)
    (:key :default-provider :property "OGENT_DEFAULT_PROVIDER"
     :section "Providers" :label "Default provider" :type string)
    (:key :default-model :property "OGENT_DEFAULT_MODEL"
     :section "Providers" :label "Default model" :type string)
    (:key :default-effort :property "OGENT_DEFAULT_EFFORT"
     :section "Runtime defaults" :label "Default effort" :type string)
    (:key :default-runtime :property "OGENT_DEFAULT_RUNTIME"
     :section "Runtime defaults" :label "Default runtime" :type string)
    (:key :skill-paths :property "OGENT_SKILL_PATHS" :section "Skills"
     :label "Skill paths" :type list)
    (:key :storage-root :property "OGENT_STORAGE_ROOT" :section "Storage"
     :label "Storage root" :type string)
    (:key :data-directory :property "OGENT_DATA_DIRECTORY" :section "Storage"
     :label "Data directory" :type string)
    (:key :registry-source :property "OGENT_REGISTRY_SOURCE"
     :section "Integrations" :label "Registry source" :type string)
    (:key :mcp-enabled :property "OGENT_MCP_ENABLED" :section "Integrations"
     :label "MCP enabled" :type boolean)
    (:key :notifications :property "OGENT_NOTIFICATIONS"
     :section "Notifications" :label "Notifications" :type boolean)
    (:key :theme :property "OGENT_THEME" :section "Appearance"
     :label "Theme" :type string)
    (:key :git-remote :property "OGENT_GIT_REMOTE" :section "Git"
     :label "Git remote" :type string)
    (:key :automation-mode :property "OGENT_AUTOMATION_MODE"
     :section "Automation" :label "Automation mode" :type string)
    (:key :telemetry :property "OGENT_TELEMETRY" :section "About"
     :label "Telemetry" :type boolean)
    (:key :version :property "OGENT_VERSION" :section "About"
     :label "Version" :type string))
  "Armory settings fields persisted in the settings Org property drawer.")

(defconst ogent-armory-demo-manifest
  '((name . "Ogent Demo Armory")
    (kind . "root")
    (description . "A small Armory showing agents, jobs, pages, settings, and apps.")
    (settings . ((profile-name . "Demo Operator")
                 (default-provider . "codex")
                 (default-model . "gpt-5.4")
                 (default-effort . "medium")
                 (default-runtime . "native")
                 (notifications . t)
                 (theme . "system")))
    (agents . (((slug . "lead")
                (name . "Lead")
                (role . "Coordinate Armory work and approve delegated actions.")
                (department . "Leadership")
                (type . "lead")
                (can-dispatch . t)
                (tags . ("lead" "planning"))
                (body . "Keep work moving through small reviewable decisions."))
               ((slug . "researcher")
                (name . "Researcher")
                (role . "Collect references and summarize project context.")
                (department . "Research")
                (type . "specialist")
                (tags . ("research" "context"))
                (body . "Maintain grounded research notes and citations."))))
    (jobs . (((agent . "lead")
              (id . "weekly-review")
              (name . "Weekly Review")
              (cron . "0 9 * * 1")
              (body . "Review active Armory work and propose the next priorities."))
             ((agent . "researcher")
              (id . "context-refresh")
              (name . "Context Refresh")
              (cron . "0 10 * * 3")
              (body . "Refresh project context from recent Org records."))))
    (pages . (((title . "Welcome")
               (path . "pages/welcome.org")
               (tags . ("demo" "start"))
               (body . "This Armory is safe to edit, run, and inspect."))
              ((title . "Operating Notes")
               (path . "pages/operating-notes.org")
               (tags . ("demo" "ops"))
               (body . "Use Armory Home as the main operating surface.")))))
  "Built-in manifest used by `ogent-armory-demo'.")

(defun ogent-armory-settings--root (directory)
  "Return the Armory root for DIRECTORY."
  (let* ((candidate (ogent-armory--directory directory))
         (root (or (ogent-armory-find-root candidate) candidate)))
    (directory-file-name
     (if (file-exists-p root)
         (file-truename (ogent-armory--directory root))
       (expand-file-name root)))))

(defun ogent-armory-settings-file (directory)
  "Return the Armory-local settings Org file under DIRECTORY."
  (expand-file-name ".armory-state/settings.org"
                    (ogent-armory-settings--root directory)))

(defun ogent-armory-settings--now ()
  "Return a timestamp for settings metadata."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun ogent-armory-settings--version ()
  "Return the current ogent version string when available."
  (if (boundp 'ogent-version)
      (format "%s" ogent-version)
    "unknown"))

(defun ogent-armory-settings-defaults (directory)
  "Return default Armory settings for DIRECTORY."
  (let* ((root (ogent-armory-settings--root directory))
         (name (if (file-readable-p (ogent-armory-index-file root))
                   (plist-get (ogent-armory-read-index root) :name)
                 (file-name-nondirectory root)))
         (now (ogent-armory-settings--now)))
    (list :profile-name name
          :profile-avatar ""
          :default-provider ogent-armory-default-agent-provider
          :default-model ""
          :default-effort "medium"
          :default-runtime "native"
          :skill-paths nil
          :storage-root root
          :data-directory root
          :registry-source ""
          :mcp-enabled t
          :notifications nil
          :theme "system"
          :git-remote ""
          :automation-mode "emacs"
          :telemetry nil
          :version (ogent-armory-settings--version)
          :created-at now
          :updated-at now
          :path (ogent-armory-settings-file root))))

(defun ogent-armory-settings--field (key)
  "Return settings field spec for KEY."
  (seq-find (lambda (field)
              (eq (plist-get field :key) key))
            ogent-armory-settings--fields))

(defun ogent-armory-settings--value-from-property (field value)
  "Return parsed settings FIELD VALUE."
  (pcase (plist-get field :type)
    ('boolean (ogent-armory--truth-value value))
    ('list (ogent-armory--tags-from-string value))
    (_ (or (ogent-armory--blank-to-nil value) ""))))

(defun ogent-armory-settings--read-file (file directory)
  "Read settings FILE with defaults from DIRECTORY."
  (let ((settings (ogent-armory-settings-defaults directory)))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (ogent-armory--first-heading-title)
      (dolist (field ogent-armory-settings--fields)
        (setq settings
              (plist-put
               settings
               (plist-get field :key)
               (ogent-armory-settings--value-from-property
                field
                (org-entry-get nil (plist-get field :property))))))
      (setq settings
            (plist-put settings :created-at
                       (or (ogent-armory--blank-to-nil
                            (org-entry-get nil "OGENT_CREATED_AT"))
                           (plist-get settings :created-at))))
      (setq settings
            (plist-put settings :updated-at
                       (or (ogent-armory--blank-to-nil
                            (org-entry-get nil "OGENT_UPDATED_AT"))
                           (plist-get settings :updated-at))))
      (plist-put settings :path file))))

(defun ogent-armory-settings-read (directory)
  "Read Armory settings for DIRECTORY.
Missing settings files return defaults without writing a file."
  (let ((file (ogent-armory-settings-file directory)))
    (if (file-readable-p file)
        (ogent-armory-settings--read-file file directory)
      (ogent-armory-settings-defaults directory))))

(defun ogent-armory-settings--plist-merge (base updates)
  "Return BASE plist with UPDATES applied."
  (let ((merged (copy-sequence base))
        (tail updates))
    (while tail
      (setq merged (plist-put merged (car tail) (cadr tail)))
      (setq tail (cddr tail)))
    merged))

(defun ogent-armory-settings--field-properties (settings)
  "Return field properties for SETTINGS."
  (mapcar
   (lambda (field)
     (cons (plist-get field :property)
           (plist-get settings (plist-get field :key))))
   ogent-armory-settings--fields))

(defun ogent-armory-settings--format (settings)
  "Return SETTINGS formatted as Org."
  (let ((sections (delete-dups
                   (mapcar (lambda (field)
                             (plist-get field :section))
                           ogent-armory-settings--fields))))
    (concat
     "#+title: Armory Settings\n\n"
     "* Armory Settings\n"
     (ogent-armory--format-properties
      (append
       `(("OGENT_SETTINGS" . t)
         ("OGENT_CREATED_AT" . ,(plist-get settings :created-at))
         ("OGENT_UPDATED_AT" . ,(plist-get settings :updated-at)))
       (ogent-armory-settings--field-properties settings)))
     "\n"
     (mapconcat
      (lambda (section)
        (concat
         (format "** %s\n" section)
         (mapconcat
          (lambda (field)
            (let ((value (plist-get settings (plist-get field :key))))
	      (format "- %s: %s"
	              (plist-get field :label)
	              (if (listp value)
	                  (string-join
	                   (mapcar (lambda (item)
	                             (format "%s" item))
	                           value)
	                   ", ")
	                (format "%s" (or value ""))))))
          (seq-filter (lambda (field)
                        (equal (plist-get field :section) section))
                      ogent-armory-settings--fields)
          "\n")
         "\n"))
      sections
      "\n")
    "\n")))

(defun ogent-armory-settings-ensure (directory)
  "Ensure DIRECTORY has a settings file and return it."
  (let ((file (ogent-armory-settings-file directory)))
    (if (file-exists-p file)
        file
      (ogent-armory-settings-write directory nil :merge t))))

;;;###autoload
(cl-defun ogent-armory-settings-write (directory settings &key merge)
  "Write SETTINGS for DIRECTORY and return the settings file.
When MERGE is non-nil, existing settings and defaults fill missing keys."
  (let* ((root (ogent-armory-settings--root directory))
         (file (ogent-armory-settings-file root))
         (base (if merge
                   (ogent-armory-settings-read root)
                 (ogent-armory-settings-defaults root)))
         (settings (ogent-armory-settings--plist-merge base settings))
         (created (or (plist-get settings :created-at)
                      (plist-get base :created-at)
                      (ogent-armory-settings--now))))
    (setq settings (plist-put settings :created-at created))
    (setq settings (plist-put settings :updated-at
                              (ogent-armory-settings--now)))
    (setq settings (plist-put settings :path file))
    (make-directory (file-name-directory file) t)
    (ogent-armory--write-file file (ogent-armory-settings--format settings))
    file))

(defun ogent-armory-settings-update (directory &rest updates)
  "Merge UPDATES into Armory settings for DIRECTORY."
  (ogent-armory-settings-write directory updates :merge t))

;;;###autoload
(defun ogent-armory-settings-export (directory output)
  "Export Armory settings from DIRECTORY to OUTPUT as Org."
  (interactive
   (let* ((root (or (ogent-armory-find-root)
                    (read-directory-name "Armory root: ")))
          (output (read-file-name "Export settings to: " root nil nil
                                  "settings.org")))
     (list root output)))
  (let ((source (ogent-armory-settings-write directory nil :merge t)))
    (make-directory (file-name-directory output) t)
    (copy-file source output t)
    output))

;;;###autoload
(defun ogent-armory-settings-import (directory source)
  "Import Armory settings for DIRECTORY from Org SOURCE."
  (interactive
   (let ((root (or (ogent-armory-find-root)
                   (read-directory-name "Armory root: "))))
     (list root (read-file-name "Import settings from: "))))
  (let ((target (ogent-armory-settings-file directory)))
    (make-directory (file-name-directory target) t)
    (copy-file source target t)
    (ogent-armory-settings-read directory)))

(defvar ogent-armory-settings-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "e" #'ogent-armory-settings-edit)
    (define-key map "E" #'ogent-armory-settings-export-current)
    (define-key map "I" #'ogent-armory-settings-import-current)
    (define-key map "o" #'ogent-armory-onboard-current)
    (define-key map "b" #'ogent-armory-backup-current)
    (define-key map "?" #'ogent-armory-help)
    (define-key map "g" #'ogent-armory-settings-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-settings-mode'.")

(define-derived-mode ogent-armory-settings-mode special-mode "Armory-Settings"
  "Major mode for Armory settings."
  :group 'ogent-armory-settings
  (setq-local revert-buffer-function #'ogent-armory-settings-refresh))

(defun ogent-armory-settings--insert (root)
  "Insert settings buffer content for ROOT."
  (let ((settings nil))
    (ogent-armory-settings-ensure root)
    (setq settings (ogent-armory-settings-read root))
    (insert (format "Armory Settings: %s\n" root))
    (insert "e edit  E export  I import  o onboard  b backup  ? help  g refresh  q quit\n\n")
    (dolist (section (delete-dups
                      (mapcar (lambda (field)
                                (plist-get field :section))
                              ogent-armory-settings--fields)))
      (insert (format "%s\n" section))
      (insert (make-string (length section) ?-) "\n")
      (dolist (field (seq-filter
                      (lambda (candidate)
                        (equal (plist-get candidate :section) section))
                      ogent-armory-settings--fields))
        (let ((value (plist-get settings (plist-get field :key))))
          (insert (format "%-20s %s\n"
                          (plist-get field :label)
                          (if (listp value)
                              (string-join value ", ")
                            (format "%s" (or value "")))))))
      (insert "\n"))
    (insert (format "Settings file: %s\n" (plist-get settings :path)))))

;;;###autoload
(defun ogent-armory-settings (&optional directory)
  "Open Armory settings for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (let* ((root (ogent-armory-settings--root (or directory default-directory)))
         (buffer (get-buffer-create
                  (format ogent-armory-settings-buffer-name-format
                          (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-armory-settings-mode)
        (setq ogent-armory-settings--root root)
        (setq default-directory (file-name-as-directory root))
        (ogent-armory-settings--insert root)
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-settings-refresh (&rest _)
  "Refresh the current Armory settings buffer."
  (interactive)
  (let ((root ogent-armory-settings--root)
        (inhibit-read-only t))
    (erase-buffer)
    (ogent-armory-settings--insert root)
    (goto-char (point-min))))

(defun ogent-armory-settings-edit ()
  "Edit one Armory setting in the current settings buffer."
  (interactive)
  (let* ((settings (ogent-armory-settings-read ogent-armory-settings--root))
         (choices (mapcar (lambda (field)
                            (cons (plist-get field :label) field))
                          ogent-armory-settings--fields))
         (field (cdr (assoc (completing-read "Setting: " choices nil t)
                            choices)))
         (key (plist-get field :key))
         (current (plist-get settings key))
         (value (pcase (plist-get field :type)
                  ('boolean (y-or-n-p (format "%s? "
                                              (plist-get field :label))))
                  ('list (split-string
                          (read-string
                           (format "%s: " (plist-get field :label))
                           (when current (string-join current ", ")))
                          "[ \t]*,[ \t]*"
                          t))
                  (_ (read-string
                      (format "%s: " (plist-get field :label))
                      (format "%s" (or current "")))))))
    (ogent-armory-settings-update ogent-armory-settings--root key value)
    (ogent-armory-settings-refresh)))

(defun ogent-armory-settings-export-current ()
  "Export settings for the current Armory settings buffer."
  (interactive)
  (ogent-armory-settings-export
   ogent-armory-settings--root
   (read-file-name "Export settings to: " ogent-armory-settings--root nil nil
                   "settings.org")))

(defun ogent-armory-settings-import-current ()
  "Import settings for the current Armory settings buffer."
  (interactive)
  (ogent-armory-settings-import
   ogent-armory-settings--root
   (read-file-name "Import settings from: ")))

(defun ogent-armory-onboard-current ()
  "Run Armory onboarding for the current settings buffer."
  (interactive)
  (ogent-armory-onboard ogent-armory-settings--root)
  (ogent-armory-settings-refresh))

(defun ogent-armory-backup-current ()
  "Create a backup for the current settings buffer."
  (interactive)
  (message "Armory backup: %s"
           (ogent-armory-backup ogent-armory-settings--root)))

(defun ogent-armory-settings--adapter-ids ()
  "Return adapter ids for onboarding completion."
  (mapcar (lambda (adapter)
            (plist-get adapter :id))
          (ogent-armory-adapter-list)))

(defconst ogent-armory-onboard-default-team
  '((:slug "lead" :name "Lead" :role "Lead agent and planning coordinator"
     :department "Leadership" :type "lead" :can-dispatch t :tags ("lead"))
    (:slug "researcher" :name "Researcher" :role "Research and context agent"
     :department "Research" :type "specialist" :tags ("research")))
  "Default team created by Armory onboarding.")

;;;###autoload
(cl-defun ogent-armory-onboard
    (directory &key name default-provider default-model default-effort runtime team)
  "Onboard a Armory in DIRECTORY and return its root.
NAME is the Armory name.  Provider/runtime defaults are written to settings.
TEAM is a list of agent plists, or nil for `ogent-armory-onboard-default-team'."
  (interactive
   (let* ((directory (read-directory-name "Armory directory: "))
          (name (read-string "Armory name: "
                             (file-name-nondirectory
                              (directory-file-name directory))))
          (provider (completing-read "Default provider: "
                                     (ogent-armory-settings--adapter-ids)
                                     nil nil nil nil
                                     ogent-armory-default-agent-provider))
          (model (read-string "Default model: "))
          (effort (completing-read "Default effort: "
                                   '("low" "medium" "high" "xhigh")
                                   nil nil nil nil "medium"))
          (runtime (completing-read "Default runtime: "
                                    '("native" "terminal")
                                    nil t nil nil "native")))
     (list directory
           :name name
           :default-provider provider
           :default-model model
           :default-effort effort
           :runtime runtime)))
  (let* ((root (ogent-armory-settings--root directory))
         (name (or name (file-name-nondirectory root)))
         (provider (or default-provider ogent-armory-default-agent-provider))
         (runtime (or runtime "native"))
         (team (or team ogent-armory-onboard-default-team)))
    (ogent-armory-scaffold root name
                            :kind "root"
                            :description "Armory created by ogent onboarding."
                            :create-editor nil
                            :skip-existing t)
    (ogent-armory-settings-write
     root
     (list :profile-name name
           :default-provider provider
           :default-model (or default-model "")
           :default-effort (or default-effort "medium")
           :default-runtime runtime
           :storage-root root
           :data-directory root)
     :merge t)
    (dolist (agent team)
      (let ((agent (copy-sequence agent)))
        (unless (plist-get agent :provider)
          (setq agent (plist-put agent :provider provider)))
        (unless (plist-get agent :runtime-mode)
          (setq agent (plist-put agent :runtime-mode runtime)))
        (ogent-armory-write-agent
         root
         agent
         (or (plist-get agent :body)
             (format "Help operate the %s Armory." name)))))
    root))

(defun ogent-armory-registry--object-get-one (object key)
  "Return OBJECT value for KEY."
  (cond
   ((hash-table-p object)
    (or (gethash key object)
        (gethash (format "%s" key) object)))
   ((and (listp object) (keywordp (car object)))
    (let* ((name (if (keywordp key)
                     (substring (symbol-name key) 1)
                   (symbol-name key)))
           (keyword (if (keywordp key)
                        key
                      (intern (concat ":" name)))))
      (or (plist-get object key)
          (plist-get object keyword))))
   ((listp object)
    (let ((symbol (if (keywordp key)
                      (intern (substring (symbol-name key) 1))
                    key))
          (string (if (keywordp key)
                      (substring (symbol-name key) 1)
                    (format "%s" key))))
      (or (cdr (assq symbol object))
          (cdr (assoc string object))
          (cdr (assoc (replace-regexp-in-string "-" "_" string) object))
          (cdr (assq (intern (replace-regexp-in-string "-" "_" string))
                     object)))))))

(defun ogent-armory-registry--object-get (object key)
  "Return OBJECT value for KEY, accepting keyword, hyphen, and underscore forms."
  (or (ogent-armory-registry--object-get-one object key)
      (when (symbolp key)
        (let* ((name (if (keywordp key)
                         (substring (symbol-name key) 1)
                       (symbol-name key)))
               (alternate (intern (replace-regexp-in-string "-" "_" name))))
          (ogent-armory-registry--object-get-one object alternate)))))

(defun ogent-armory-registry--sequence (value)
  "Return VALUE as a list."
  (cond
   ((null value) nil)
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t (list value))))

(defun ogent-armory-registry--string-list (value)
  "Return VALUE as a list of strings."
  (cond
   ((null value) nil)
   ((stringp value) (ogent-armory--tags-from-string value))
   (t (mapcar (lambda (item)
                (format "%s" item))
              (ogent-armory-registry--sequence value)))))

(defun ogent-armory-registry-read-manifest (file)
  "Read a Armory registry manifest from FILE."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol)
        (json-false nil))
    (json-read-file file)))

(defun ogent-armory-registry--settings (manifest root)
  "Return settings plist from MANIFEST for ROOT."
  (let ((settings (or (ogent-armory-registry--object-get manifest 'settings)
                      manifest)))
    (list :profile-name (or (ogent-armory-registry--object-get settings 'profile-name)
                            (ogent-armory-registry--object-get manifest 'name)
                            (file-name-nondirectory root))
          :default-provider (or (ogent-armory-registry--object-get
                                 settings 'default-provider)
                                ogent-armory-default-agent-provider)
          :default-model (or (ogent-armory-registry--object-get
                              settings 'default-model)
                             "")
          :default-effort (or (ogent-armory-registry--object-get
                               settings 'default-effort)
                              "medium")
          :default-runtime (or (ogent-armory-registry--object-get
                                settings 'default-runtime)
                               "native")
          :notifications (ogent-armory--truth-value
                          (ogent-armory-registry--object-get
                           settings 'notifications))
          :theme (or (ogent-armory-registry--object-get settings 'theme)
                     "system")
          :registry-source (or (ogent-armory-registry--object-get
                                manifest 'source)
                               ""))))

(defun ogent-armory-registry--agent-plist (agent defaults)
  "Return Armory agent plist for manifest AGENT with DEFAULTS."
  (let ((slug (ogent-armory-registry--object-get agent 'slug)))
    (list :slug slug
          :name (or (ogent-armory-registry--object-get agent 'name) slug)
          :display-name (ogent-armory-registry--object-get agent 'display-name)
          :role (or (ogent-armory-registry--object-get agent 'role) "Agent")
          :department (ogent-armory-registry--object-get agent 'department)
          :type (ogent-armory-registry--object-get agent 'type)
          :can-dispatch (ogent-armory--truth-value
                         (ogent-armory-registry--object-get
                          agent 'can-dispatch))
          :provider (or (ogent-armory-registry--object-get agent 'provider)
                        (plist-get defaults :default-provider))
          :model (or (ogent-armory-registry--object-get agent 'model)
                     (plist-get defaults :default-model))
          :effort (or (ogent-armory-registry--object-get agent 'effort)
                      (plist-get defaults :default-effort))
          :runtime-mode (or (ogent-armory-registry--object-get
                             agent 'runtime-mode)
                            (plist-get defaults :default-runtime))
          :tags (ogent-armory-registry--string-list
                 (ogent-armory-registry--object-get agent 'tags)))))

(defun ogent-armory-registry--job-plist (job defaults)
  "Return Armory job plist for manifest JOB with DEFAULTS."
  (list :id (ogent-armory-registry--object-get job 'id)
        :name (or (ogent-armory-registry--object-get job 'name)
                  (ogent-armory-registry--object-get job 'id))
        :cron (or (ogent-armory-registry--object-get job 'cron) "")
        :provider (or (ogent-armory-registry--object-get job 'provider)
                      (plist-get defaults :default-provider))
        :model (or (ogent-armory-registry--object-get job 'model)
                   (plist-get defaults :default-model))
        :effort (or (ogent-armory-registry--object-get job 'effort)
                    (plist-get defaults :default-effort))
        :runtime-mode (or (ogent-armory-registry--object-get job 'runtime-mode)
                          (plist-get defaults :default-runtime))
        :enabled t
        :tags (ogent-armory-registry--string-list
               (ogent-armory-registry--object-get job 'tags))))

;;;###autoload
(cl-defun ogent-armory-registry-import (manifest-file directory &key manifest)
  "Import Armory registry MANIFEST-FILE into DIRECTORY.
When MANIFEST is non-nil, import that object without reading MANIFEST-FILE."
  (interactive
   (list (read-file-name "Armory registry manifest: ")
         (read-directory-name "Import to Armory directory: ")))
  (let* ((manifest (or manifest
                       (ogent-armory-registry-read-manifest manifest-file)))
         (root (ogent-armory-settings--root directory))
         (name (or (ogent-armory-registry--object-get manifest 'name)
                   (file-name-nondirectory root)))
         (kind (or (ogent-armory-registry--object-get manifest 'kind) "root"))
         (description (or (ogent-armory-registry--object-get
                           manifest 'description)
                          "Imported Armory template."))
         (settings (ogent-armory-registry--settings manifest root))
         (agent-count 0)
         (job-count 0)
         (page-count 0))
    (ogent-armory-scaffold root name
                            :kind kind
                            :description description
                            :create-editor nil
                            :skip-existing t)
    (ogent-armory-settings-write root settings :merge t)
    (dolist (agent (ogent-armory-registry--sequence
                    (ogent-armory-registry--object-get manifest 'agents)))
      (let* ((agent-plist (ogent-armory-registry--agent-plist agent settings))
             (slug (plist-get agent-plist :slug))
             (body (or (ogent-armory-registry--object-get agent 'body)
                       (ogent-armory-registry--object-get agent 'persona)
                       (ogent-armory-registry--object-get agent 'instructions)
                       "")))
        (when slug
          (ogent-armory-write-agent root agent-plist body)
          (setq agent-count (1+ agent-count)))
        (dolist (job (ogent-armory-registry--sequence
                      (ogent-armory-registry--object-get agent 'jobs)))
          (when slug
            (ogent-armory-write-job
             root
             slug
             (ogent-armory-registry--job-plist job settings)
             (or (ogent-armory-registry--object-get job 'body)
                 (ogent-armory-registry--object-get job 'prompt)
                 ""))
            (setq job-count (1+ job-count))))))
    (dolist (job (ogent-armory-registry--sequence
                  (ogent-armory-registry--object-get manifest 'jobs)))
      (when-let ((agent (ogent-armory-registry--object-get job 'agent)))
        (ogent-armory-write-job
         root
         agent
         (ogent-armory-registry--job-plist job settings)
         (or (ogent-armory-registry--object-get job 'body)
             (ogent-armory-registry--object-get job 'prompt)
             ""))
        (setq job-count (1+ job-count))))
    (dolist (page (ogent-armory-registry--sequence
                   (ogent-armory-registry--object-get manifest 'pages)))
      (let ((title (or (ogent-armory-registry--object-get page 'title)
                       "Imported Page")))
        (ogent-armory-page-create
         root
         title
         :path (ogent-armory-registry--object-get page 'path)
         :kind (ogent-armory-registry--object-get page 'kind)
         :tags (ogent-armory-registry--string-list
                (ogent-armory-registry--object-get page 'tags))
         :body (or (ogent-armory-registry--object-get page 'body) ""))
        (setq page-count (1+ page-count))))
    (list :root root
          :settings (ogent-armory-settings-file root)
          :agents agent-count
          :jobs job-count
          :pages page-count)))

;;;###autoload
(defun ogent-armory-registry-import-into (directory)
  "Prompt for a registry manifest and import it into DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))))
  (ogent-armory-registry-import
   (read-file-name "Armory registry manifest: ")
   directory))

(defun ogent-armory-backup--inside-p (path directory)
  "Return non-nil when PATH is DIRECTORY or inside DIRECTORY."
  (let ((path (directory-file-name (file-truename path)))
        (directory (directory-file-name (file-truename directory))))
    (or (equal path directory)
        (file-in-directory-p path directory))))

(defun ogent-armory-backup--skip-p (root path &optional destination-root)
  "Return non-nil when PATH under ROOT should be excluded from backups."
  (let ((relative (file-relative-name path root)))
    (or (and destination-root
             (file-exists-p destination-root)
             (ogent-armory-backup--inside-p path destination-root))
        (member relative '("." ".." ".git" ".armory-state/backups"
                           ".armory-state/process"))
        (string-prefix-p ".git/" relative)
        (string-prefix-p ".armory-state/backups/" relative)
        (string-prefix-p ".armory-state/process/" relative)
        (equal relative ".armory-state/search.el")
        (string-suffix-p "~" relative)
        (string-prefix-p ".#" (file-name-nondirectory path)))))

(defun ogent-armory-backup--copy-tree
    (root source destination backup-destination)
  "Copy SOURCE under ROOT to DESTINATION while applying backup exclusions."
  (unless (ogent-armory-backup--skip-p root source backup-destination)
    (if (file-directory-p source)
        (progn
          (make-directory destination t)
          (dolist (entry (directory-files source t directory-files-no-dot-files-regexp))
            (ogent-armory-backup--copy-tree
             root
             entry
             (expand-file-name (file-name-nondirectory entry) destination)
             backup-destination)))
      (make-directory (file-name-directory destination) t)
      (copy-file source destination t t t t))))

;;;###autoload
(defun ogent-armory-backup (directory &optional destination)
  "Create a filtered backup of Armory DIRECTORY.
DESTINATION defaults under `.armory-state/backups'.  The backup excludes git
metadata, derived search indexes, process state, and prior backups."
  (interactive
   (let ((root (or (ogent-armory-find-root)
                   (read-directory-name "Armory root: "))))
     (list root nil)))
  (let* ((root (ogent-armory-settings--root directory))
         (index (ignore-errors (ogent-armory-read-index root)))
         (name (ogent-armory--slug
                (or (plist-get index :name)
                    (file-name-nondirectory root))
                "armory"))
         (destination (or destination
                          (expand-file-name
                           (format "%s-%s" name
                                   (format-time-string "%Y%m%dT%H%M%S"))
                           (expand-file-name
                            ogent-armory-backup-directory-name root)))))
    (when (file-exists-p destination)
      (user-error "Backup destination already exists: %s" destination))
    (make-directory destination t)
    (dolist (entry (directory-files root t directory-files-no-dot-files-regexp))
      (ogent-armory-backup--copy-tree
       root
       entry
       (expand-file-name (file-name-nondirectory entry) destination)
       destination))
    destination))

;;;###autoload
(defun ogent-armory-demo (&optional directory)
  "Create a demo Armory in DIRECTORY and return import metadata."
  (interactive
   (list (read-directory-name "Demo Armory directory: ")))
  (ogent-armory-registry-import
   nil
   (or directory (expand-file-name "ogent-demo-armory" temporary-file-directory))
   :manifest ogent-armory-demo-manifest))

(defvar ogent-armory-help-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "d" #'ogent-armory-demo)
    (define-key map "s" #'ogent-armory-settings)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-help-mode'.")

(define-derived-mode ogent-armory-help-mode special-mode "Armory-Help"
  "Major mode for Armory help."
  :group 'ogent-armory-settings)

;;;###autoload
(defun ogent-armory-help (&optional directory)
  "Open Armory help for DIRECTORY."
  (interactive
   (list (or (ogent-armory-find-root) default-directory)))
  (let ((buffer (get-buffer-create ogent-armory-help-buffer-name))
        (root (and directory
                   (ignore-errors (ogent-armory-settings--root directory)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-armory-help-mode)
        (insert "Ogent Armory Help\n")
        (insert "==================\n\n")
        (when root
          (insert (format "Armory: %s\n\n" root)))
        (insert "Core surfaces\n")
        (insert "-------------\n")
        (insert "Home, Data, Agents, Tasks, Conversations, Schedule, Apps, Git, Settings, and Help are available from Emacs commands and the Armory palette.\n\n")
        (insert "Getting started\n")
        (insert "---------------\n")
        (insert "1. Run M-x ogent-armory-onboard to create settings and an initial team.\n")
        (insert "2. Open M-x ogent-armory-home for daily work.\n")
        (insert "3. Use M-x ogent-armory-command-palette to jump across records.\n")
        (insert "4. Use M-x ogent-armory-backup before large migrations.\n\n")
        (insert "Registry and demo\n")
        (insert "-----------------\n")
        (insert "M-x ogent-armory-registry-import reads JSON Armory template manifests.\n")
        (insert "M-x ogent-armory-demo creates a complete demo Armory with agents, jobs, pages, and settings.\n\n")
        (insert "Keyboard\n")
        (insert "--------\n")
        (insert "Global Armory keys include j Home, ; Data, / Palette, : Git, , Settings, . Help, ' Onboard, = Registry import, and _ Backup under the ogent prefix.\n")
        (insert "Major buffers document local keys in their header lines and help buffers.\n\n")
        (insert "Durable state\n")
        (insert "-------------\n")
        (insert "Armory records are Org files. Derived state lives in .armory-state and can be rebuilt from Org where possible.\n")
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    buffer))

(provide 'ogent-armory-settings)

;;; ogent-armory-settings.el ends here
