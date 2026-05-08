;;; ogent-cabinet-settings.el --- Cabinet settings and onboarding -*- lexical-binding: t; -*-

;;; Commentary:
;; Cabinet-local settings, onboarding, registry import, backup, help, and demo
;; commands.  Durable state lives in Org files under the Cabinet root.

;;; Code:

(require 'cl-lib)
(require 'files)
(require 'json)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'ogent-cabinet)
(require 'ogent-cabinet-evil)
(require 'ogent-cabinet-adapter)
(require 'ogent-cabinet-data)

(defgroup ogent-cabinet-settings nil
  "Cabinet settings, onboarding, registry import, and help."
  :group 'ogent-cabinet)

(defcustom ogent-cabinet-settings-buffer-name-format "*ogent-cabinet-settings:%s*"
  "Format string used for Cabinet settings buffers."
  :type 'string
  :group 'ogent-cabinet-settings)

(defcustom ogent-cabinet-help-buffer-name "*ogent-cabinet-help*"
  "Buffer name used for Cabinet help."
  :type 'string
  :group 'ogent-cabinet-settings)

(defcustom ogent-cabinet-backup-directory-name ".cabinet-state/backups"
  "Directory under a Cabinet root where filtered backups are written."
  :type 'string
  :group 'ogent-cabinet-settings)

(defvar-local ogent-cabinet-settings--root nil
  "Cabinet root shown by the current settings buffer.")

(defconst ogent-cabinet-settings--fields
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
  "Cabinet settings fields persisted in the settings Org property drawer.")

(defconst ogent-cabinet-demo-manifest
  '((name . "Ogent Demo Cabinet")
    (kind . "root")
    (description . "A small Cabinet showing agents, jobs, pages, settings, and apps.")
    (settings . ((profile-name . "Demo Operator")
                 (default-provider . "codex")
                 (default-model . "gpt-5.4")
                 (default-effort . "medium")
                 (default-runtime . "native")
                 (notifications . t)
                 (theme . "system")))
    (agents . (((slug . "lead")
                (name . "Lead")
                (role . "Coordinate Cabinet work and approve delegated actions.")
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
              (body . "Review active Cabinet work and propose the next priorities."))
             ((agent . "researcher")
              (id . "context-refresh")
              (name . "Context Refresh")
              (cron . "0 10 * * 3")
              (body . "Refresh project context from recent Org records."))))
    (pages . (((title . "Welcome")
               (path . "pages/welcome.org")
               (tags . ("demo" "start"))
               (body . "This Cabinet is safe to edit, run, and inspect."))
              ((title . "Operating Notes")
               (path . "pages/operating-notes.org")
               (tags . ("demo" "ops"))
               (body . "Use Cabinet Home as the main operating surface.")))))
  "Built-in manifest used by `ogent-cabinet-demo'.")

(defun ogent-cabinet-settings--root (directory)
  "Return the Cabinet root for DIRECTORY."
  (let* ((candidate (ogent-cabinet--directory directory))
         (root (or (ogent-cabinet-find-root candidate) candidate)))
    (directory-file-name
     (if (file-exists-p root)
         (file-truename (ogent-cabinet--directory root))
       (expand-file-name root)))))

(defun ogent-cabinet-settings-file (directory)
  "Return the Cabinet-local settings Org file under DIRECTORY."
  (expand-file-name ".cabinet-state/settings.org"
                    (ogent-cabinet-settings--root directory)))

(defun ogent-cabinet-settings--now ()
  "Return a timestamp for settings metadata."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun ogent-cabinet-settings--version ()
  "Return the current ogent version string when available."
  (if (boundp 'ogent-version)
      (format "%s" ogent-version)
    "unknown"))

(defun ogent-cabinet-settings-defaults (directory)
  "Return default Cabinet settings for DIRECTORY."
  (let* ((root (ogent-cabinet-settings--root directory))
         (name (if (file-readable-p (ogent-cabinet-index-file root))
                   (plist-get (ogent-cabinet-read-index root) :name)
                 (file-name-nondirectory root)))
         (now (ogent-cabinet-settings--now)))
    (list :profile-name name
          :profile-avatar ""
          :default-provider ogent-cabinet-default-agent-provider
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
          :version (ogent-cabinet-settings--version)
          :created-at now
          :updated-at now
          :path (ogent-cabinet-settings-file root))))

(defun ogent-cabinet-settings--field (key)
  "Return settings field spec for KEY."
  (seq-find (lambda (field)
              (eq (plist-get field :key) key))
            ogent-cabinet-settings--fields))

(defun ogent-cabinet-settings--value-from-property (field value)
  "Return parsed settings FIELD VALUE."
  (pcase (plist-get field :type)
    ('boolean (ogent-cabinet--truth-value value))
    ('list (ogent-cabinet--tags-from-string value))
    (_ (or (ogent-cabinet--blank-to-nil value) ""))))

(defun ogent-cabinet-settings--read-file (file directory)
  "Read settings FILE with defaults from DIRECTORY."
  (let ((settings (ogent-cabinet-settings-defaults directory)))
    (with-temp-buffer
      (insert-file-contents file)
      (ogent-cabinet--org-mode)
      (ogent-cabinet--first-heading-title)
      (dolist (field ogent-cabinet-settings--fields)
        (setq settings
              (plist-put
               settings
               (plist-get field :key)
               (ogent-cabinet-settings--value-from-property
                field
                (org-entry-get nil (plist-get field :property))))))
      (setq settings
            (plist-put settings :created-at
                       (or (ogent-cabinet--blank-to-nil
                            (org-entry-get nil "OGENT_CREATED_AT"))
                           (plist-get settings :created-at))))
      (setq settings
            (plist-put settings :updated-at
                       (or (ogent-cabinet--blank-to-nil
                            (org-entry-get nil "OGENT_UPDATED_AT"))
                           (plist-get settings :updated-at))))
      (plist-put settings :path file))))

(defun ogent-cabinet-settings-read (directory)
  "Read Cabinet settings for DIRECTORY.
Missing settings files return defaults without writing a file."
  (let ((file (ogent-cabinet-settings-file directory)))
    (if (file-readable-p file)
        (ogent-cabinet-settings--read-file file directory)
      (ogent-cabinet-settings-defaults directory))))

(defun ogent-cabinet-settings--plist-merge (base updates)
  "Return BASE plist with UPDATES applied."
  (let ((merged (copy-sequence base))
        (tail updates))
    (while tail
      (setq merged (plist-put merged (car tail) (cadr tail)))
      (setq tail (cddr tail)))
    merged))

(defun ogent-cabinet-settings--field-properties (settings)
  "Return field properties for SETTINGS."
  (mapcar
   (lambda (field)
     (cons (plist-get field :property)
           (plist-get settings (plist-get field :key))))
   ogent-cabinet-settings--fields))

(defun ogent-cabinet-settings--format (settings)
  "Return SETTINGS formatted as Org."
  (let ((sections (delete-dups
                   (mapcar (lambda (field)
                             (plist-get field :section))
                           ogent-cabinet-settings--fields))))
    (concat
     "#+title: Cabinet Settings\n\n"
     "* Cabinet Settings\n"
     (ogent-cabinet--format-properties
      (append
       `(("OGENT_SETTINGS" . t)
         ("OGENT_CREATED_AT" . ,(plist-get settings :created-at))
         ("OGENT_UPDATED_AT" . ,(plist-get settings :updated-at)))
       (ogent-cabinet-settings--field-properties settings)))
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
                      ogent-cabinet-settings--fields)
          "\n")
         "\n"))
      sections
      "\n")
    "\n")))

(defun ogent-cabinet-settings-ensure (directory)
  "Ensure DIRECTORY has a settings file and return it."
  (let ((file (ogent-cabinet-settings-file directory)))
    (if (file-exists-p file)
        file
      (ogent-cabinet-settings-write directory nil :merge t))))

;;;###autoload
(cl-defun ogent-cabinet-settings-write (directory settings &key merge)
  "Write SETTINGS for DIRECTORY and return the settings file.
When MERGE is non-nil, existing settings and defaults fill missing keys."
  (let* ((root (ogent-cabinet-settings--root directory))
         (file (ogent-cabinet-settings-file root))
         (base (if merge
                   (ogent-cabinet-settings-read root)
                 (ogent-cabinet-settings-defaults root)))
         (settings (ogent-cabinet-settings--plist-merge base settings))
         (created (or (plist-get settings :created-at)
                      (plist-get base :created-at)
                      (ogent-cabinet-settings--now))))
    (setq settings (plist-put settings :created-at created))
    (setq settings (plist-put settings :updated-at
                              (ogent-cabinet-settings--now)))
    (setq settings (plist-put settings :path file))
    (make-directory (file-name-directory file) t)
    (ogent-cabinet--write-file file (ogent-cabinet-settings--format settings))
    file))

(defun ogent-cabinet-settings-update (directory &rest updates)
  "Merge UPDATES into Cabinet settings for DIRECTORY."
  (ogent-cabinet-settings-write directory updates :merge t))

;;;###autoload
(defun ogent-cabinet-settings-export (directory output)
  "Export Cabinet settings from DIRECTORY to OUTPUT as Org."
  (interactive
   (let* ((root (or (ogent-cabinet-find-root)
                    (read-directory-name "Cabinet root: ")))
          (output (read-file-name "Export settings to: " root nil nil
                                  "settings.org")))
     (list root output)))
  (let ((source (ogent-cabinet-settings-write directory nil :merge t)))
    (make-directory (file-name-directory output) t)
    (copy-file source output t)
    output))

;;;###autoload
(defun ogent-cabinet-settings-import (directory source)
  "Import Cabinet settings for DIRECTORY from Org SOURCE."
  (interactive
   (let ((root (or (ogent-cabinet-find-root)
                   (read-directory-name "Cabinet root: "))))
     (list root (read-file-name "Import settings from: "))))
  (let ((target (ogent-cabinet-settings-file directory)))
    (make-directory (file-name-directory target) t)
    (copy-file source target t)
    (ogent-cabinet-settings-read directory)))

(defvar ogent-cabinet-settings-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "e" #'ogent-cabinet-settings-edit)
    (define-key map (kbd "C-c e") #'ogent-cabinet-settings-edit)
    (define-key map "E" #'ogent-cabinet-settings-export-current)
    (define-key map (kbd "C-c E") #'ogent-cabinet-settings-export-current)
    (define-key map "I" #'ogent-cabinet-settings-import-current)
    (define-key map (kbd "C-c I") #'ogent-cabinet-settings-import-current)
    (define-key map "o" #'ogent-cabinet-onboard-current)
    (define-key map (kbd "C-c o") #'ogent-cabinet-onboard-current)
    (define-key map "b" #'ogent-cabinet-backup-current)
    (define-key map (kbd "C-c b") #'ogent-cabinet-backup-current)
    (define-key map "?" #'ogent-cabinet-help)
    (define-key map (kbd "C-c ?") #'ogent-cabinet-help)
    (define-key map "g" #'ogent-cabinet-settings-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-settings-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-settings-mode'.")

(define-derived-mode ogent-cabinet-settings-mode special-mode "Cabinet-Settings"
  "Major mode for Cabinet settings."
  :group 'ogent-cabinet-settings
  (setq-local revert-buffer-function #'ogent-cabinet-settings-refresh))

(defun ogent-cabinet-settings--insert (root)
  "Insert settings buffer content for ROOT."
  (let ((settings nil))
    (ogent-cabinet-settings-ensure root)
    (setq settings (ogent-cabinet-settings-read root))
    (insert (format "Cabinet Settings: %s\n" root))
    (insert "C-c e edit  C-c E export  C-c I import  C-c o onboard  C-c b backup  C-c ? help  C-c g refresh  q quit\n\n")
    (dolist (section (delete-dups
                      (mapcar (lambda (field)
                                (plist-get field :section))
                              ogent-cabinet-settings--fields)))
      (insert (format "%s\n" section))
      (insert (make-string (length section) ?-) "\n")
      (dolist (field (seq-filter
                      (lambda (candidate)
                        (equal (plist-get candidate :section) section))
                      ogent-cabinet-settings--fields))
        (let ((value (plist-get settings (plist-get field :key))))
          (insert (format "%-20s %s\n"
                          (plist-get field :label)
                          (if (listp value)
                              (string-join value ", ")
                            (format "%s" (or value "")))))))
      (insert "\n"))
    (insert (format "Settings file: %s\n" (plist-get settings :path)))))

;;;###autoload
(defun ogent-cabinet-settings (&optional directory)
  "Open Cabinet settings for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (let* ((root (ogent-cabinet-settings--root (or directory default-directory)))
         (buffer (get-buffer-create
                  (format ogent-cabinet-settings-buffer-name-format
                          (file-name-nondirectory root)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-cabinet-settings-mode)
        (setq ogent-cabinet-settings--root root)
        (setq default-directory (file-name-as-directory root))
        (ogent-cabinet-settings--insert root)
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-settings-refresh (&rest _)
  "Refresh the current Cabinet settings buffer."
  (interactive)
  (let ((root ogent-cabinet-settings--root)
        (inhibit-read-only t))
    (erase-buffer)
    (ogent-cabinet-settings--insert root)
    (goto-char (point-min))))

(defun ogent-cabinet-settings-edit ()
  "Edit one Cabinet setting in the current settings buffer."
  (interactive)
  (let* ((settings (ogent-cabinet-settings-read ogent-cabinet-settings--root))
         (choices (mapcar (lambda (field)
                            (cons (plist-get field :label) field))
                          ogent-cabinet-settings--fields))
         (field (cdr (assoc (completing-read "Setting: " choices nil t)
                            choices)))
         (key (plist-get field :key))
         (current (plist-get settings key))
         (value (cond
                 ((eq key :default-provider)
                  (ogent-cabinet-settings--read-provider
                   "Default provider: "
                   (format "%s" (or current ""))))
                 ((eq key :default-model)
                  (ogent-cabinet-settings--read-model
                   (plist-get settings :default-provider)
                   (format "%s" (or current ""))
                   nil
                   t))
                 (t
                  (pcase (plist-get field :type)
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
                        (format "%s" (or current "")))))))))
    (ogent-cabinet-settings-update ogent-cabinet-settings--root key value)
    (ogent-cabinet-settings-refresh)))

(defun ogent-cabinet-settings-export-current ()
  "Export settings for the current Cabinet settings buffer."
  (interactive)
  (ogent-cabinet-settings-export
   ogent-cabinet-settings--root
   (read-file-name "Export settings to: " ogent-cabinet-settings--root nil nil
                   "settings.org")))

(defun ogent-cabinet-settings-import-current ()
  "Import settings for the current Cabinet settings buffer."
  (interactive)
  (ogent-cabinet-settings-import
   ogent-cabinet-settings--root
   (read-file-name "Import settings from: ")))

(defun ogent-cabinet-onboard-current ()
  "Run Cabinet onboarding for the current settings buffer."
  (interactive)
  (ogent-cabinet-onboard ogent-cabinet-settings--root)
  (ogent-cabinet-settings-refresh))

(defun ogent-cabinet-backup-current ()
  "Create a backup for the current settings buffer."
  (interactive)
  (message "Cabinet backup: %s"
           (ogent-cabinet-backup ogent-cabinet-settings--root)))

(defun ogent-cabinet-settings--adapter-ids ()
  "Return adapter ids for onboarding completion."
  (mapcar (lambda (adapter)
            (plist-get adapter :id))
          (ogent-cabinet-adapter-list)))

(defun ogent-cabinet-settings--read-provider (&optional prompt current)
  "Read a Cabinet provider using PROMPT and CURRENT."
  (completing-read (or prompt "Provider: ")
                   (ogent-cabinet-settings--adapter-ids)
                   nil nil nil nil current))

(defun ogent-cabinet-settings--read-model
    (provider &optional current prompt prefer-first)
  "Read a model for PROVIDER.
CURRENT is used as the default when present.  PROMPT customizes the minibuffer
label.  When PREFER-FIRST is non-nil, the first provider model becomes the
fallback default."
  (let* ((adapter (ogent-cabinet-adapter-resolve-provider provider))
         (models (ogent-cabinet-adapter-models adapter))
         (default (or (and current
                           (not (string-blank-p current))
                           current)
                      (and prefer-first (car models))))
         (prompt (or prompt
                     (format "Default model (%s): "
                             (plist-get adapter :name)))))
    (if models
        (completing-read prompt models nil nil nil nil default)
      (read-string prompt default))))

(defconst ogent-cabinet-onboard-default-team
  '((:slug "lead" :name "Lead" :role "Lead agent and planning coordinator"
     :department "Leadership" :type "lead" :can-dispatch t :tags ("lead"))
    (:slug "researcher" :name "Researcher" :role "Research and context agent"
     :department "Research" :type "specialist" :tags ("research")))
  "Default team created by Cabinet onboarding.")

;;;###autoload
(cl-defun ogent-cabinet-onboard
    (directory &key name default-provider default-model default-effort runtime team)
  "Onboard a Cabinet in DIRECTORY and return its root.
NAME is the Cabinet name.  Provider/runtime defaults are written to settings.
TEAM is a list of agent plists, or nil for `ogent-cabinet-onboard-default-team'."
  (interactive
   (let* ((directory (read-directory-name "Cabinet directory: "))
          (name (read-string "Cabinet name: "
                             (file-name-nondirectory
                              (directory-file-name directory))))
          (provider (completing-read "Default provider: "
                                     (ogent-cabinet-settings--adapter-ids)
                                     nil nil nil nil
                                     ogent-cabinet-default-agent-provider))
          (model (ogent-cabinet-settings--read-model
                  provider nil nil t))
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
  (let* ((root (ogent-cabinet-settings--root directory))
         (name (or name (file-name-nondirectory root)))
         (provider (or default-provider ogent-cabinet-default-agent-provider))
         (runtime (or runtime "native"))
         (team (or team ogent-cabinet-onboard-default-team)))
    (ogent-cabinet-scaffold root name
                            :kind "root"
                            :description "Cabinet created by ogent onboarding."
                            :create-editor nil
                            :skip-existing t)
    (ogent-cabinet-settings-write
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
        (ogent-cabinet-write-agent
         root
         agent
         (or (plist-get agent :body)
             (format "Help operate the %s Cabinet." name)))))
    root))

(defun ogent-cabinet-registry--object-get-one (object key)
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

(defun ogent-cabinet-registry--object-get (object key)
  "Return OBJECT value for KEY, accepting keyword, hyphen, and underscore forms."
  (or (ogent-cabinet-registry--object-get-one object key)
      (when (symbolp key)
        (let* ((name (if (keywordp key)
                         (substring (symbol-name key) 1)
                       (symbol-name key)))
               (alternate (intern (replace-regexp-in-string "-" "_" name))))
          (ogent-cabinet-registry--object-get-one object alternate)))))

(defun ogent-cabinet-registry--sequence (value)
  "Return VALUE as a list."
  (cond
   ((null value) nil)
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t (list value))))

(defun ogent-cabinet-registry--string-list (value)
  "Return VALUE as a list of strings."
  (cond
   ((null value) nil)
   ((stringp value) (ogent-cabinet--tags-from-string value))
   (t (mapcar (lambda (item)
                (format "%s" item))
              (ogent-cabinet-registry--sequence value)))))

(defun ogent-cabinet-registry-read-manifest (file)
  "Read a Cabinet registry manifest from FILE."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol)
        (json-false nil))
    (json-read-file file)))

(defun ogent-cabinet-registry--settings (manifest root)
  "Return settings plist from MANIFEST for ROOT."
  (let ((settings (or (ogent-cabinet-registry--object-get manifest 'settings)
                      manifest)))
    (list :profile-name (or (ogent-cabinet-registry--object-get settings 'profile-name)
                            (ogent-cabinet-registry--object-get manifest 'name)
                            (file-name-nondirectory root))
          :default-provider (or (ogent-cabinet-registry--object-get
                                 settings 'default-provider)
                                ogent-cabinet-default-agent-provider)
          :default-model (or (ogent-cabinet-registry--object-get
                              settings 'default-model)
                             "")
          :default-effort (or (ogent-cabinet-registry--object-get
                               settings 'default-effort)
                              "medium")
          :default-runtime (or (ogent-cabinet-registry--object-get
                                settings 'default-runtime)
                               "native")
          :notifications (ogent-cabinet--truth-value
                          (ogent-cabinet-registry--object-get
                           settings 'notifications))
          :theme (or (ogent-cabinet-registry--object-get settings 'theme)
                     "system")
          :registry-source (or (ogent-cabinet-registry--object-get
                                manifest 'source)
                               ""))))

(defun ogent-cabinet-registry--agent-plist (agent defaults)
  "Return Cabinet agent plist for manifest AGENT with DEFAULTS."
  (let ((slug (ogent-cabinet-registry--object-get agent 'slug)))
    (list :slug slug
          :name (or (ogent-cabinet-registry--object-get agent 'name) slug)
          :display-name (ogent-cabinet-registry--object-get agent 'display-name)
          :role (or (ogent-cabinet-registry--object-get agent 'role) "Agent")
          :department (ogent-cabinet-registry--object-get agent 'department)
          :type (ogent-cabinet-registry--object-get agent 'type)
          :can-dispatch (ogent-cabinet--truth-value
                         (ogent-cabinet-registry--object-get
                          agent 'can-dispatch))
          :provider (or (ogent-cabinet-registry--object-get agent 'provider)
                        (plist-get defaults :default-provider))
          :model (or (ogent-cabinet-registry--object-get agent 'model)
                     (plist-get defaults :default-model))
          :effort (or (ogent-cabinet-registry--object-get agent 'effort)
                      (plist-get defaults :default-effort))
          :runtime-mode (or (ogent-cabinet-registry--object-get
                             agent 'runtime-mode)
                            (plist-get defaults :default-runtime))
          :tags (ogent-cabinet-registry--string-list
                 (ogent-cabinet-registry--object-get agent 'tags)))))

(defun ogent-cabinet-registry--job-plist (job defaults)
  "Return Cabinet job plist for manifest JOB with DEFAULTS."
  (list :id (ogent-cabinet-registry--object-get job 'id)
        :name (or (ogent-cabinet-registry--object-get job 'name)
                  (ogent-cabinet-registry--object-get job 'id))
        :cron (or (ogent-cabinet-registry--object-get job 'cron) "")
        :provider (or (ogent-cabinet-registry--object-get job 'provider)
                      (plist-get defaults :default-provider))
        :model (or (ogent-cabinet-registry--object-get job 'model)
                   (plist-get defaults :default-model))
        :effort (or (ogent-cabinet-registry--object-get job 'effort)
                    (plist-get defaults :default-effort))
        :runtime-mode (or (ogent-cabinet-registry--object-get job 'runtime-mode)
                          (plist-get defaults :default-runtime))
        :enabled t
        :tags (ogent-cabinet-registry--string-list
               (ogent-cabinet-registry--object-get job 'tags))))

;;;###autoload
(cl-defun ogent-cabinet-registry-import (manifest-file directory &key manifest)
  "Import Cabinet registry MANIFEST-FILE into DIRECTORY.
When MANIFEST is non-nil, import that object without reading MANIFEST-FILE."
  (interactive
   (list (read-file-name "Cabinet registry manifest: ")
         (read-directory-name "Import to Cabinet directory: ")))
  (let* ((manifest (or manifest
                       (ogent-cabinet-registry-read-manifest manifest-file)))
         (root (ogent-cabinet-settings--root directory))
         (name (or (ogent-cabinet-registry--object-get manifest 'name)
                   (file-name-nondirectory root)))
         (kind (or (ogent-cabinet-registry--object-get manifest 'kind) "root"))
         (description (or (ogent-cabinet-registry--object-get
                           manifest 'description)
                          "Imported Cabinet template."))
         (settings (ogent-cabinet-registry--settings manifest root))
         (agent-count 0)
         (job-count 0)
         (page-count 0))
    (ogent-cabinet-scaffold root name
                            :kind kind
                            :description description
                            :create-editor nil
                            :skip-existing t)
    (ogent-cabinet-settings-write root settings :merge t)
    (dolist (agent (ogent-cabinet-registry--sequence
                    (ogent-cabinet-registry--object-get manifest 'agents)))
      (let* ((agent-plist (ogent-cabinet-registry--agent-plist agent settings))
             (slug (plist-get agent-plist :slug))
             (body (or (ogent-cabinet-registry--object-get agent 'body)
                       (ogent-cabinet-registry--object-get agent 'persona)
                       (ogent-cabinet-registry--object-get agent 'instructions)
                       "")))
        (when slug
          (ogent-cabinet-write-agent root agent-plist body)
          (setq agent-count (1+ agent-count)))
        (dolist (job (ogent-cabinet-registry--sequence
                      (ogent-cabinet-registry--object-get agent 'jobs)))
          (when slug
            (ogent-cabinet-write-job
             root
             slug
             (ogent-cabinet-registry--job-plist job settings)
             (or (ogent-cabinet-registry--object-get job 'body)
                 (ogent-cabinet-registry--object-get job 'prompt)
                 ""))
            (setq job-count (1+ job-count))))))
    (dolist (job (ogent-cabinet-registry--sequence
                  (ogent-cabinet-registry--object-get manifest 'jobs)))
      (when-let ((agent (ogent-cabinet-registry--object-get job 'agent)))
        (ogent-cabinet-write-job
         root
         agent
         (ogent-cabinet-registry--job-plist job settings)
         (or (ogent-cabinet-registry--object-get job 'body)
             (ogent-cabinet-registry--object-get job 'prompt)
             ""))
        (setq job-count (1+ job-count))))
    (dolist (page (ogent-cabinet-registry--sequence
                   (ogent-cabinet-registry--object-get manifest 'pages)))
      (let ((title (or (ogent-cabinet-registry--object-get page 'title)
                       "Imported Page")))
        (ogent-cabinet-page-create
         root
         title
         :path (ogent-cabinet-registry--object-get page 'path)
         :kind (ogent-cabinet-registry--object-get page 'kind)
         :tags (ogent-cabinet-registry--string-list
                (ogent-cabinet-registry--object-get page 'tags))
         :body (or (ogent-cabinet-registry--object-get page 'body) ""))
        (setq page-count (1+ page-count))))
    (list :root root
          :settings (ogent-cabinet-settings-file root)
          :agents agent-count
          :jobs job-count
          :pages page-count)))

;;;###autoload
(defun ogent-cabinet-registry-import-into (directory)
  "Prompt for a registry manifest and import it into DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))))
  (ogent-cabinet-registry-import
   (read-file-name "Cabinet registry manifest: ")
   directory))

(defun ogent-cabinet-backup--inside-p (path directory)
  "Return non-nil when PATH is DIRECTORY or inside DIRECTORY."
  (let ((path (directory-file-name (file-truename path)))
        (directory (directory-file-name (file-truename directory))))
    (or (equal path directory)
        (file-in-directory-p path directory))))

(defun ogent-cabinet-backup--skip-p (root path &optional destination-root)
  "Return non-nil when PATH under ROOT should be excluded from backups."
  (let ((relative (file-relative-name path root)))
    (or (and destination-root
             (file-exists-p destination-root)
             (ogent-cabinet-backup--inside-p path destination-root))
        (member relative '("." ".." ".git" ".cabinet-state/backups"
                           ".cabinet-state/process"))
        (string-prefix-p ".git/" relative)
        (string-prefix-p ".cabinet-state/backups/" relative)
        (string-prefix-p ".cabinet-state/process/" relative)
        (equal relative ".cabinet-state/search.el")
        (string-suffix-p "~" relative)
        (string-prefix-p ".#" (file-name-nondirectory path)))))

(defun ogent-cabinet-backup--copy-tree
    (root source destination backup-destination)
  "Copy SOURCE under ROOT to DESTINATION while applying backup exclusions."
  (unless (ogent-cabinet-backup--skip-p root source backup-destination)
    (if (file-directory-p source)
        (progn
          (make-directory destination t)
          (dolist (entry (directory-files source t directory-files-no-dot-files-regexp))
            (ogent-cabinet-backup--copy-tree
             root
             entry
             (expand-file-name (file-name-nondirectory entry) destination)
             backup-destination)))
      (make-directory (file-name-directory destination) t)
      (copy-file source destination t t t t))))

;;;###autoload
(defun ogent-cabinet-backup (directory &optional destination)
  "Create a filtered backup of Cabinet DIRECTORY.
DESTINATION defaults under `.cabinet-state/backups'.  The backup excludes git
metadata, derived search indexes, process state, and prior backups."
  (interactive
   (let ((root (or (ogent-cabinet-find-root)
                   (read-directory-name "Cabinet root: "))))
     (list root nil)))
  (let* ((root (ogent-cabinet-settings--root directory))
         (index (ignore-errors (ogent-cabinet-read-index root)))
         (name (ogent-cabinet--slug
                (or (plist-get index :name)
                    (file-name-nondirectory root))
                "cabinet"))
         (destination (or destination
                          (expand-file-name
                           (format "%s-%s" name
                                   (format-time-string "%Y%m%dT%H%M%S"))
                           (expand-file-name
                            ogent-cabinet-backup-directory-name root)))))
    (when (file-exists-p destination)
      (user-error "Backup destination already exists: %s" destination))
    (make-directory destination t)
    (dolist (entry (directory-files root t directory-files-no-dot-files-regexp))
      (ogent-cabinet-backup--copy-tree
       root
       entry
       (expand-file-name (file-name-nondirectory entry) destination)
       destination))
    destination))

;;;###autoload
(defun ogent-cabinet-demo (&optional directory)
  "Create a demo Cabinet in DIRECTORY and return import metadata."
  (interactive
   (list (read-directory-name "Demo Cabinet directory: ")))
  (ogent-cabinet-registry-import
   nil
   (or directory (expand-file-name "ogent-demo-cabinet" temporary-file-directory))
   :manifest ogent-cabinet-demo-manifest))

(defvar ogent-cabinet-help-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "d" #'ogent-cabinet-demo)
    (define-key map (kbd "C-c d") #'ogent-cabinet-demo)
    (define-key map "s" #'ogent-cabinet-settings)
    (define-key map (kbd "C-c s") #'ogent-cabinet-settings)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-help-mode'.")

(define-derived-mode ogent-cabinet-help-mode special-mode "Cabinet-Help"
  "Major mode for Cabinet help."
  :group 'ogent-cabinet-settings)

;;;###autoload
(defun ogent-cabinet-help (&optional directory)
  "Open Cabinet help for DIRECTORY."
  (interactive
   (list (or (ogent-cabinet-find-root) default-directory)))
  (let ((buffer (get-buffer-create ogent-cabinet-help-buffer-name))
        (root (and directory
                   (ignore-errors (ogent-cabinet-settings--root directory)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-cabinet-help-mode)
        (insert "Ogent Cabinet Help\n")
        (insert "==================\n\n")
        (when root
          (insert (format "Cabinet: %s\n\n" root)))
        (insert "Core surfaces\n")
        (insert "-------------\n")
        (insert "Home, Data, Agents, Tasks, Conversations, Schedule, Apps, Git, Settings, and Help are available from Emacs commands and the Cabinet palette.\n\n")
        (insert "Getting started\n")
        (insert "---------------\n")
        (insert "1. Run M-x ogent-cabinet-onboard to create settings and an initial team.\n")
        (insert "2. Open M-x ogent-cabinet-home for daily work.\n")
        (insert "3. Use M-x ogent-cabinet-command-palette to jump across records.\n")
        (insert "4. Use M-x ogent-cabinet-backup before large migrations.\n\n")
        (insert "Registry and demo\n")
        (insert "-----------------\n")
        (insert "M-x ogent-cabinet-registry-import reads JSON Cabinet template manifests.\n")
        (insert "M-x ogent-cabinet-demo creates a complete demo Cabinet with agents, jobs, pages, and settings.\n\n")
        (insert "Keyboard\n")
        (insert "--------\n")
        (insert "Global Cabinet keys include j Home, ; Data, / Palette, : Git, , Settings, . Help, ' Onboard, = Registry import, and _ Backup under the ogent prefix.\n")
        (insert "Cabinet display buffers expose local actions through C-c chords, leaving Evil normal-state movement keys available.\n\n")
        (insert "Durable state\n")
        (insert "-------------\n")
        (insert "Cabinet records are Org files. Derived state lives in .cabinet-state and can be rebuilt from Org where possible.\n")
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-settings--evil-local-keys ()
  "Install local Evil keys for Cabinet settings."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-settings-mode-map))

(defun ogent-cabinet-help--evil-local-keys ()
  "Install local Evil keys for Cabinet help."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-help-mode-map))

(defun ogent-cabinet-settings--setup-evil ()
  "Set up Evil integration for Cabinet settings."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-settings-mode
   ogent-cabinet-settings-mode-map
   'ogent-cabinet-settings-mode-hook
   #'ogent-cabinet-settings--evil-local-keys))

(defun ogent-cabinet-help--setup-evil ()
  "Set up Evil integration for Cabinet help."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-help-mode
   ogent-cabinet-help-mode-map
   'ogent-cabinet-help-mode-hook
   #'ogent-cabinet-help--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-cabinet-settings--setup-evil)
  (ogent-cabinet-help--setup-evil))

(provide 'ogent-cabinet-settings)

;;; ogent-cabinet-settings.el ends here
