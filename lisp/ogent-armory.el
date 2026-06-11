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

(defcustom ogent-armory-todo-keywords
  '("RUNNING(r)" "FAILED(f)")
  "Extra Org TODO keywords for Armory job/session states.
Registered (with the built-in TODO/DONE) so `org-agenda' recognizes
Armory records.  RUNNING is an active state; FAILED is a terminal
\(done-type) state.  The scaffolded armory index also declares them in
a `#+TODO:' line so single files are self-describing without global
registration."
  :type '(repeat string)
  :group 'ogent-armory)

(defun ogent-armory--todo-sequence ()
  "Return the Org `#+TODO:' keyword sequence for Armory files.
A list like (\"TODO\" \"RUNNING(r)\" \"|\" \"DONE(d)\" \"FAILED(f)\")."
  (let (active done)
    (dolist (kw ogent-armory-todo-keywords)
      (if (string-prefix-p "FAILED" kw) (push kw done) (push kw active)))
    (append '("TODO") (nreverse active)
            '("|" "DONE(d)") (nreverse done))))

(defun ogent-armory--todo-header ()
  "Return the `#+TODO:' header line declaring Armory keywords."
  (format "#+TODO: %s\n" (string-join (ogent-armory--todo-sequence) " ")))

;;;###autoload
(defun ogent-armory-register-todo-keywords ()
  "Register Armory TODO keywords in `org-todo-keywords'.
Idempotent: adds RUNNING/FAILED (and the standard TODO|DONE sequence)
so `org-agenda' recognizes Armory job and session states across all
armory files.  Safe to call repeatedly."
  (require 'org)
  (let ((seq (cons 'sequence (ogent-armory--todo-sequence))))
    (unless (member seq org-todo-keywords)
      (setq org-todo-keywords (append org-todo-keywords (list seq))))))

;; Register when Org is available, deferred so loading this file has no
;; global side effect at require time.
(with-eval-after-load 'org
  (ogent-armory-register-todo-keywords))

(defcustom ogent-armory-global-agents-root nil
  "Optional directory containing user-global Armory agents.
When nil, each Armory stores global agents in its own `.global-agents'
directory."
  :type '(choice (const :tag "Armory-local .global-agents" nil)
                 directory)
  :group 'ogent-armory)

(defconst ogent-armory--index-file "index.org"
  "File name for the root Org entry in a armory.")

(defconst ogent-armory--managed-directories
  '(".agents" ".agents/.conversations" ".global-agents" ".jobs" ".armory-state")
  "Directories managed by the Org armory scaffold.")

(defun ogent-armory--directory (directory)
  "Return DIRECTORY as an expanded directory path."
  (file-name-as-directory (expand-file-name directory)))

(defun ogent-armory--org-mode ()
  "Enable Org parsing for Armory machine readers without user hooks."
  (let ((org-inhibit-startup t))
    (delay-mode-hooks
      (org-mode))))

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

(defun ogent-armory--cron-number (value min max &optional sunday)
  "Return cron VALUE as a number between MIN and MAX.
When SUNDAY is non-nil, value 7 is accepted and normalized to 0."
  (when (string-match-p "\\`[0-9]+\\'" value)
    (let ((number (string-to-number value)))
      (cond
       ((and sunday (= number 7)) 0)
       ((and (<= min number) (<= number max)) number)
       (t nil)))))

(defun ogent-armory--cron-range-values (start end step min max &optional sunday)
  "Return values from START to END by STEP for one cron field.
MIN and MAX define the accepted bounds.  When SUNDAY is non-nil, day 7 maps
to day 0."
  (let ((start-number (when (string-match-p "\\`[0-9]+\\'" start)
                        (string-to-number start)))
        (end-number (when (string-match-p "\\`[0-9]+\\'" end)
                      (string-to-number end))))
    (when (and start-number end-number (> step 0)
               (<= min start-number)
               (<= start-number max)
               (<= min end-number)
               (<= end-number max)
               (<= start-number end-number))
      (let (values)
        (while (<= start-number end-number)
          (push (if (and sunday (= start-number 7)) 0 start-number) values)
          (setq start-number (+ start-number step)))
        (nreverse values)))))

(defun ogent-armory--cron-field-values (field min max &optional sunday)
  "Return numeric cron FIELD values within MIN and MAX.
When SUNDAY is non-nil, day of week value 7 is accepted as Sunday."
  (catch 'invalid
    (let (values)
      (dolist (part (split-string (or field "") "," t "[ \t\n\r]+"))
        (let* ((pieces (split-string part "/" t))
               (base (car pieces))
               (step (if (cadr pieces)
                         (string-to-number (cadr pieces))
                       1)))
          (when (or (null base)
                    (> (length pieces) 2)
                    (<= step 0)
                    (and (cadr pieces)
                         (not (string-match-p "\\`[0-9]+\\'" (cadr pieces)))))
            (throw 'invalid nil))
          (setq values
                (append
                 values
                 (cond
                  ((equal base "*")
                   (mapcar (lambda (number)
                             (if (and sunday (= number 7)) 0 number))
                           (number-sequence min max step)))
                  ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)\\'" base)
                   (or (ogent-armory--cron-range-values
                        (match-string 1 base)
                        (match-string 2 base)
                        step
                        min
                        max
                        sunday)
                       (throw 'invalid nil)))
                  ((string-match-p "\\`[0-9]+\\'" base)
                   (let ((number (ogent-armory--cron-number
                                  base min max sunday)))
                     (unless number
                       (throw 'invalid nil))
                     (if (cadr pieces)
                         (mapcar (lambda (candidate)
                                   (if (and sunday (= candidate 7))
                                       0
                                     candidate))
                                 (number-sequence number max step))
                       (list number))))
                  (t
                   (throw 'invalid nil)))))))
      (seq-sort #'< (delete-dups values)))))

(defun ogent-armory--cron-expression-fields (value)
  "Return parsed cron fields for VALUE, or nil when invalid."
  (let ((parts (split-string (string-trim (or value "")) "[ \t]+" t)))
    (when (= (length parts) 5)
      (let ((minute (ogent-armory--cron-field-values (nth 0 parts) 0 59))
            (hour (ogent-armory--cron-field-values (nth 1 parts) 0 23))
            (day (ogent-armory--cron-field-values (nth 2 parts) 1 31))
            (month (ogent-armory--cron-field-values (nth 3 parts) 1 12))
            (weekday (ogent-armory--cron-field-values
                      (nth 4 parts)
                      0
                      7
                      t)))
        (when (and minute hour day month weekday)
          (list minute hour day month weekday))))))

(defun ogent-armory--cron-expression-p (value)
  "Return non-nil when VALUE is a supported five-field cron expression."
  (not (null (ogent-armory--cron-expression-fields value))))

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

(defun ogent-armory--org-timestamp (value)
  "Return VALUE as an active Org timestamp."
  (let ((text (string-trim (or value ""))))
    (cond
     ((string-match-p "\\`<[^>]+>\\'" text) text)
     ((string-blank-p text) "")
     (t (format-time-string "<%Y-%m-%d %a %H:%M>"
                            (date-to-time text))))))

(defun ogent-armory--time-expression-p (value)
  "Return non-nil when VALUE parses as an Emacs time expression."
  (condition-case nil
      (progn
        (date-to-time value)
        t)
    (error nil)))

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

(defun ogent-armory-global-agents-directory (directory)
  "Return the global agents directory visible from DIRECTORY."
  (file-name-as-directory
   (expand-file-name
    (or ogent-armory-global-agents-root
        (expand-file-name ".global-agents"
                          (ogent-armory--directory directory))))))

(defun ogent-armory-agent-directory (directory slug)
  "Return the directory for agent SLUG under DIRECTORY."
  (expand-file-name slug (ogent-armory-agents-directory directory)))

(defun ogent-armory-global-agent-directory (directory slug)
  "Return the global directory for agent SLUG under DIRECTORY."
  (expand-file-name slug (ogent-armory-global-agents-directory directory)))

(defun ogent-armory-agent-file (directory slug)
  "Return the persona file for agent SLUG under DIRECTORY."
  (expand-file-name "persona.org"
                    (ogent-armory-agent-directory directory slug)))

(defun ogent-armory-global-agent-file (directory slug)
  "Return the global persona file for agent SLUG under DIRECTORY."
  (expand-file-name "persona.org"
                    (ogent-armory-global-agent-directory directory slug)))

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

(defun ogent-armory--armory-kind (metadata)
  "Return the Armory kind from METADATA."
  (or (plist-get metadata :armory-kind)
      (plist-get metadata :kind)))

(defun ogent-armory-read-index (directory)
  "Read the armory index under DIRECTORY and return a plist."
  (let ((file (ogent-armory-index-file directory)))
    (unless (file-readable-p file)
      (user-error "Armory index not found: %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (ogent-armory--org-mode)
      (let ((name (ogent-armory--first-heading-title)))
        (list :id (or (org-entry-get nil "OGENT_ARMORY_ID") "armory")
              :name name
              :kind (or (org-entry-get nil "OGENT_ARMORY_KIND")
                        (org-entry-get nil "OGENT_KIND"))
              :armory-kind (or (org-entry-get nil "OGENT_ARMORY_KIND")
                                (org-entry-get nil "OGENT_KIND"))
              :parent (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_ARMORY_PARENT"))
              :description (org-entry-get nil "OGENT_DESCRIPTION")
              :entry (ogent-armory--blank-to-nil
                      (org-entry-get nil "OGENT_ARMORY_ENTRY"))
              :access (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_ARMORY_ACCESS"))
              :shared-context (ogent-armory--tags-from-string
                               (org-entry-get nil "OGENT_ARMORY_SHARED_CONTEXT"))
              :tags (ogent-armory--tags-from-string
                     (org-entry-get nil "OGENT_TAGS"))
              :body (ogent-armory--heading-body)
              :path file)))))

(defun ogent-armory--format-index (name kind description body tags)
  "Return an Org index document for armory NAME.
KIND, DESCRIPTION, BODY, and TAGS supply the root metadata."
  (let ((armory-id (format "%s-%s" (ogent-armory--slug name "armory") kind)))
    (concat
     (format "#+title: %s\n" name)
     (ogent-armory--todo-header)
     "\n"
     (format "* %s\n" name)
     (ogent-armory--format-properties
      `(("OGENT_ARMORY" . t)
        ("OGENT_ARMORY_ID" . ,armory-id)
        ("OGENT_KIND" . ,kind)
        ("OGENT_ARMORY_KIND" . ,kind)
        ("OGENT_ARMORY_PARENT" . "")
        ("OGENT_ARMORY_ENTRY" . "")
        ("OGENT_ARMORY_ACCESS" . "")
        ("OGENT_ARMORY_SHARED_CONTEXT" . "")
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
         (display-name (ogent-armory--agent-plist-value
                        agent :display-name nil))
         (icon (ogent-armory--agent-plist-value agent :icon nil))
         (color (ogent-armory--agent-plist-value agent :color nil))
         (avatar (ogent-armory--agent-plist-value agent :avatar nil))
         (role (ogent-armory--agent-plist-value agent :role "Agent"))
         (department (ogent-armory--agent-plist-value
                      agent :department nil))
         (type (ogent-armory--agent-plist-value agent :type nil))
         (scope (ogent-armory--agent-plist-value agent :scope "armory"))
         (can-dispatch (ogent-armory--agent-plist-value
                        agent :can-dispatch nil))
         (provider (ogent-armory--agent-plist-value
                    agent :provider ogent-armory-default-agent-provider))
         (adapter (ogent-armory--agent-plist-value agent :adapter nil))
         (adapter-config (ogent-armory--agent-plist-value
                          agent :adapter-config nil))
         (model (ogent-armory--agent-plist-value agent :model nil))
         (effort (ogent-armory--agent-plist-value agent :effort nil))
         (runtime-mode (ogent-armory--agent-plist-value
                        agent :runtime-mode nil))
         (permission-mode (ogent-armory--agent-plist-value
                           agent :permission-mode nil))
         (budget (ogent-armory--agent-plist-value agent :budget nil))
         (focus (ogent-armory--agent-plist-value agent :focus nil))
         (goals (ogent-armory--agent-plist-value agent :goals nil))
         (channels (ogent-armory--agent-plist-value agent :channels nil))
         (skills (ogent-armory--agent-plist-value agent :skills nil))
         (recommended-skills (ogent-armory--agent-plist-value
                              agent :recommended-skills nil))
         (setup-complete (ogent-armory--agent-plist-value
                          agent :setup-complete nil))
         (heartbeat (ogent-armory--agent-plist-value
                     agent :heartbeat ogent-armory-default-heartbeat))
         (last-heartbeat (ogent-armory--agent-plist-value
                          agent :last-heartbeat nil))
         (next-heartbeat (ogent-armory--agent-plist-value
                          agent :next-heartbeat nil))
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
        ("OGENT_AGENT_SCOPE" . ,scope)
        ("OGENT_DISPLAY_NAME" . ,display-name)
        ("OGENT_ICON" . ,icon)
        ("OGENT_COLOR" . ,color)
        ("OGENT_AVATAR" . ,avatar)
        ("OGENT_ROLE" . ,role)
        ("OGENT_DEPARTMENT" . ,department)
        ("OGENT_TYPE" . ,type)
        ("OGENT_CAN_DISPATCH" . ,can-dispatch)
        ("OGENT_PROVIDER" . ,provider)
        ("OGENT_ADAPTER" . ,adapter)
        ("OGENT_ADAPTER_CONFIG" . ,adapter-config)
        ("OGENT_MODEL" . ,model)
        ("OGENT_EFFORT" . ,effort)
        ("OGENT_RUNTIME_MODE" . ,runtime-mode)
        ("OGENT_PERMISSION_MODE" . ,permission-mode)
        ("OGENT_BUDGET" . ,budget)
        ("OGENT_FOCUS" . ,focus)
        ("OGENT_GOALS" . ,goals)
        ("OGENT_CHANNELS" . ,channels)
        ("OGENT_SKILLS" . ,skills)
        ("OGENT_RECOMMENDED_SKILLS" . ,recommended-skills)
        ("OGENT_SETUP_COMPLETE" . ,setup-complete)
        ("OGENT_HEARTBEAT" . ,heartbeat)
        ("OGENT_LAST_HEARTBEAT" . ,last-heartbeat)
        ("OGENT_NEXT_HEARTBEAT" . ,next-heartbeat)
        ("OGENT_ACTIVE" . ,active)
        ("OGENT_ARCHIVED" . ,archived)
        ("OGENT_WORKSPACE" . ,workspace)
        ("OGENT_TAGS" . ,tags)))
     "\n"
     (when body
       (concat (string-trim body) "\n")))))

(defun ogent-armory--write-agent-to (directory agent scope &optional body)
  "Write AGENT persona under DIRECTORY in SCOPE using BODY."
  (let* ((slug (ogent-armory--slug
                (ogent-armory--agent-plist-value agent :slug nil)
                "agent"))
         (agent (plist-put (copy-sequence agent)
                           :scope (symbol-name scope)))
         (agent-dir (if (eq scope 'global)
                        (ogent-armory-global-agent-directory directory slug)
                      (ogent-armory-agent-directory directory slug)))
         (file (if (eq scope 'global)
                   (ogent-armory-global-agent-file directory slug)
                 (ogent-armory-agent-file directory slug))))
    (make-directory agent-dir t)
    (ogent-armory--ensure-agent-support-files agent-dir)
    (ogent-armory--write-file file (ogent-armory--format-agent agent body))
    file))

(defun ogent-armory-write-agent (directory agent &optional body)
  "Write armory-local AGENT persona under DIRECTORY using BODY as instructions.
AGENT is a plist.  Required key: `:slug'.  Common keys include `:name',
`:role', `:provider', `:model', `:permission-mode', `:heartbeat',
`:active', `:workspace', and `:tags'."
  (ogent-armory--write-agent-to directory agent 'armory body))

(defun ogent-armory-write-global-agent (directory agent &optional body)
  "Write global AGENT persona visible from DIRECTORY using BODY."
  (ogent-armory--write-agent-to directory agent 'global body))

(defun ogent-armory--read-agent-file (file slug scope-fallback)
  "Read agent persona FILE for SLUG with SCOPE-FALLBACK."
  (unless (file-readable-p file)
    (user-error "Agent persona not found: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (ogent-armory--org-mode)
    (let ((name (ogent-armory--first-heading-title)))
      (list :slug (or (org-entry-get nil "OGENT_SLUG") slug)
            :name name
            :display-name (ogent-armory--blank-to-nil
                           (org-entry-get nil "OGENT_DISPLAY_NAME"))
            :icon (ogent-armory--blank-to-nil
                   (org-entry-get nil "OGENT_ICON"))
            :color (ogent-armory--blank-to-nil
                    (org-entry-get nil "OGENT_COLOR"))
            :avatar (ogent-armory--blank-to-nil
                     (org-entry-get nil "OGENT_AVATAR"))
            :role (org-entry-get nil "OGENT_ROLE")
            :department (ogent-armory--blank-to-nil
                         (org-entry-get nil "OGENT_DEPARTMENT"))
            :type (ogent-armory--blank-to-nil
                   (org-entry-get nil "OGENT_TYPE"))
            :scope (or (ogent-armory--blank-to-nil
                        (org-entry-get nil "OGENT_AGENT_SCOPE"))
                       scope-fallback)
            :can-dispatch (ogent-armory--truth-value
                           (org-entry-get nil "OGENT_CAN_DISPATCH"))
            :provider (org-entry-get nil "OGENT_PROVIDER")
            :adapter (ogent-armory--blank-to-nil
                      (org-entry-get nil "OGENT_ADAPTER"))
            :adapter-config (ogent-armory--blank-to-nil
                             (org-entry-get nil "OGENT_ADAPTER_CONFIG"))
            :model (ogent-armory--blank-to-nil
                    (org-entry-get nil "OGENT_MODEL"))
            :effort (ogent-armory--blank-to-nil
                     (org-entry-get nil "OGENT_EFFORT"))
            :runtime-mode (ogent-armory--blank-to-nil
                           (org-entry-get nil "OGENT_RUNTIME_MODE"))
            :permission-mode (ogent-armory--blank-to-nil
                              (org-entry-get nil "OGENT_PERMISSION_MODE"))
            :budget (ogent-armory--blank-to-nil
                     (org-entry-get nil "OGENT_BUDGET"))
            :focus (ogent-armory--tags-from-string
                    (org-entry-get nil "OGENT_FOCUS"))
            :goals (ogent-armory--tags-from-string
                    (org-entry-get nil "OGENT_GOALS"))
            :channels (ogent-armory--tags-from-string
                       (org-entry-get nil "OGENT_CHANNELS"))
            :skills (ogent-armory--tags-from-string
                     (org-entry-get nil "OGENT_SKILLS"))
            :recommended-skills (ogent-armory--tags-from-string
                                 (org-entry-get nil "OGENT_RECOMMENDED_SKILLS"))
            :setup-complete (ogent-armory--truth-value
                             (org-entry-get nil "OGENT_SETUP_COMPLETE"))
            :heartbeat (org-entry-get nil "OGENT_HEARTBEAT")
            :last-heartbeat (ogent-armory--blank-to-nil
                             (org-entry-get nil "OGENT_LAST_HEARTBEAT"))
            :next-heartbeat (ogent-armory--blank-to-nil
                             (org-entry-get nil "OGENT_NEXT_HEARTBEAT"))
            :active (ogent-armory--truth-value
                     (org-entry-get nil "OGENT_ACTIVE"))
            :archived (ogent-armory--truth-value
                       (org-entry-get nil "OGENT_ARCHIVED"))
            :workspace (org-entry-get nil "OGENT_WORKSPACE")
            :tags (ogent-armory--tags-from-string
                   (org-entry-get nil "OGENT_TAGS"))
            :body (ogent-armory--heading-body)
            :path file))))

(defun ogent-armory-read-agent (directory slug)
  "Read armory-local agent SLUG from DIRECTORY and return a plist."
  (let ((file (ogent-armory-agent-file directory slug)))
    (unless (file-readable-p file)
      (user-error "Agent persona not found: %s" file))
    (ogent-armory--read-agent-file file slug "armory")))

(defun ogent-armory-read-global-agent (directory slug)
  "Read global agent SLUG visible from DIRECTORY and return a plist."
  (let ((file (ogent-armory-global-agent-file directory slug)))
    (unless (file-readable-p file)
      (user-error "Global agent persona not found: %s" file))
    (ogent-armory--read-agent-file file slug "global")))

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

(defun ogent-armory-list-global-agents (directory)
  "Return global agent slugs visible from DIRECTORY."
  (let ((agents-dir (ogent-armory-global-agents-directory directory)))
    (when (file-directory-p agents-dir)
      (seq-sort
       #'string<
       (seq-filter
        (lambda (name)
          (and (not (string-prefix-p "." name))
               (file-exists-p
                (ogent-armory-global-agent-file directory name))))
        (directory-files agents-dir nil directory-files-no-dot-files-regexp))))))

(defun ogent-armory--agent-with-source (agent scope source-root path)
  "Return AGENT annotated with SCOPE, SOURCE-ROOT, and PATH."
  (let ((record (copy-sequence agent)))
    (setq record (plist-put record :scope scope))
    (setq record (plist-put record :source-root
                            (directory-file-name
                             (file-truename
                              (ogent-armory--directory source-root)))))
    (setq record (plist-put record :path path))
    record))

(defun ogent-armory-child-armories (directory)
  "Return immediate child Armory roots below DIRECTORY."
  (let* ((root (ogent-armory--directory directory))
         children)
    (dolist (entry (directory-files root t directory-files-no-dot-files-regexp))
      (when (and (file-directory-p entry)
                 (not (string-prefix-p "."
                                       (file-name-nondirectory entry)))
                 (ogent-armory-root-p entry))
        (push (directory-file-name (file-truename entry)) children)))
    (seq-sort #'string< children)))

(defun ogent-armory-visible-armories (directory)
  "Return Armory roots visible from DIRECTORY."
  (delete-dups
   (cons (directory-file-name
          (file-truename (ogent-armory--directory directory)))
         (ogent-armory-child-armories directory))))

(cl-defun ogent-armory-resolve-agent (directory slug &key include-visible)
  "Resolve agent SLUG from DIRECTORY.
Armory-local agents win first, followed by global agents.  When
INCLUDE-VISIBLE is non-nil, slug-unique agents in visible child Armories are
also candidates."
  (let* ((root (ogent-armory--directory directory))
         (local-file (ogent-armory-agent-file root slug))
         (global-file (ogent-armory-global-agent-file root slug)))
    (cond
     ((file-readable-p local-file)
      (ogent-armory--agent-with-source
       (ogent-armory-read-agent root slug)
       'armory
       root
       local-file))
     ((file-readable-p global-file)
      (ogent-armory--agent-with-source
       (ogent-armory-read-global-agent root slug)
       'global
       root
       global-file))
     (include-visible
      (let (matches)
        (dolist (visible-root (cdr (ogent-armory-visible-armories root)))
          (let ((file (ogent-armory-agent-file visible-root slug)))
            (when (file-readable-p file)
              (push (ogent-armory--agent-with-source
                     (ogent-armory-read-agent visible-root slug)
                     'visible
                     visible-root
                     file)
                    matches))))
        (pcase (length matches)
          (0 (user-error "Agent persona not found: %s" slug))
          (1 (car matches))
          (_ (user-error "Ambiguous visible Armory agent: %s" slug)))))
     (t (user-error "Agent persona not found: %s" slug)))))

(cl-defun ogent-armory-agent-records (directory &key include-visible)
  "Return agent records visible from DIRECTORY.
Local records are listed first, then non-shadowed global records.  When
INCLUDE-VISIBLE is non-nil, non-shadowed child Armory agents are appended."
  (let* ((root (ogent-armory--directory directory))
         (seen (make-hash-table :test 'equal))
         records)
    (dolist (slug (ogent-armory-list-agents root))
      (puthash slug t seen)
      (push (ogent-armory--agent-with-source
             (ogent-armory-read-agent root slug)
             'armory
             root
             (ogent-armory-agent-file root slug))
            records))
    (dolist (slug (ogent-armory-list-global-agents root))
      (unless (gethash slug seen)
        (puthash slug t seen)
        (push (ogent-armory--agent-with-source
               (ogent-armory-read-global-agent root slug)
               'global
               root
               (ogent-armory-global-agent-file root slug))
              records)))
    (when include-visible
      (dolist (visible-root (cdr (ogent-armory-visible-armories root)))
        (dolist (slug (ogent-armory-list-agents visible-root))
          (unless (gethash slug seen)
            (puthash slug t seen)
            (push (ogent-armory--agent-with-source
                   (ogent-armory-read-agent visible-root slug)
                   'visible
                   visible-root
                   (ogent-armory-agent-file visible-root slug))
                  records)))))
    (seq-sort-by (lambda (agent)
                   (or (plist-get agent :display-name)
                       (plist-get agent :name)
                       (plist-get agent :slug)))
                 #'string<
                 records)))

(cl-defun ogent-armory-list-visible-agents (directory &key include-visible)
  "Return visible agent slugs for DIRECTORY."
  (mapcar (lambda (agent) (plist-get agent :slug))
          (ogent-armory-agent-records
           directory
           :include-visible include-visible)))

(defun ogent-armory-agent-lead-p (agent)
  "Return non-nil when AGENT is a lead or can dispatch actions."
  (or (equal (plist-get agent :type) "lead")
      (plist-get agent :can-dispatch)))

(cl-defun ogent-armory-agents-by-department (directory &key include-visible)
  "Return visible agents under DIRECTORY grouped by department."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (agent (ogent-armory-agent-records
                    directory
                    :include-visible include-visible))
      (let* ((department (or (plist-get agent :department) "Unassigned"))
             (agents (gethash department groups)))
        (puthash department (cons agent agents) groups)))
    (seq-sort-by
     (lambda (group)
       (plist-get group :department))
     #'string<
     (let (records)
       (maphash
        (lambda (department agents)
          (let* ((ordered (seq-sort-by
                           (lambda (agent)
                             (or (plist-get agent :display-name)
                                 (plist-get agent :name)
                                 (plist-get agent :slug)))
                           #'string<
                           agents))
                 (lead (seq-find #'ogent-armory-agent-lead-p ordered)))
            (push (list :department department
                        :lead lead
                        :agents ordered)
                  records)))
        groups)
       records))))

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
         (adapter (or (plist-get job :adapter) ""))
         (adapter-config (or (plist-get job :adapter-config) ""))
         (provider (or (plist-get job :provider) ""))
         (model (or (plist-get job :model) ""))
         (effort (or (plist-get job :effort) ""))
         (runtime-mode (or (plist-get job :runtime-mode) ""))
         (workspace (or (plist-get job :workspace) ""))
         (timeout (or (plist-get job :timeout) ""))
         (on-complete (or (plist-get job :on-complete) ""))
         (on-failure (or (plist-get job :on-failure) ""))
         (armory-path (or (plist-get job :armory-path) ""))
         (created-at (or (plist-get job :created-at) ""))
         (updated-at (or (plist-get job :updated-at) ""))
         (run-after (or (plist-get job :run-after) ""))
         (owner-task (or (plist-get job :owner-task) ""))
         (one-shot-state (or (plist-get job :one-shot-state) ""))
         (last-run (or (plist-get job :last-run) ""))
         (next-run (or (plist-get job :next-run) ""))
         (tags (plist-get job :tags))
         (archived (plist-get job :archived))
         (enabled (if (plist-member job :enabled)
                      (plist-get job :enabled)
                    t))
         (scheduled (or (ogent-armory--blank-to-nil run-after)
                        (ogent-armory--blank-to-nil
                         (plist-get job :scheduled)))))
    (concat
     (format "#+title: %s\n\n" name)
     (format "* TODO %s\n" name)
     (when (ogent-armory--blank-to-nil scheduled)
       (format "SCHEDULED: %s\n"
               (ogent-armory--org-timestamp scheduled)))
     (ogent-armory--format-properties
      `(("OGENT_JOB" . t)
        ("OGENT_JOB_ID" . ,id)
        ("OGENT_AGENT" . ,agent-slug)
        ("OGENT_CRON" . ,cron)
        ("OGENT_HEARTBEAT" . ,heartbeat)
        ("OGENT_ENABLED" . ,enabled)
        ("OGENT_ADAPTER" . ,adapter)
        ("OGENT_ADAPTER_CONFIG" . ,adapter-config)
        ("OGENT_PROVIDER" . ,provider)
        ("OGENT_MODEL" . ,model)
        ("OGENT_EFFORT" . ,effort)
        ("OGENT_RUNTIME_MODE" . ,runtime-mode)
        ("OGENT_WORKSPACE" . ,workspace)
        ("OGENT_TIMEOUT" . ,timeout)
        ("OGENT_ON_COMPLETE" . ,on-complete)
        ("OGENT_ON_FAILURE" . ,on-failure)
        ("OGENT_ARMORY_PATH" . ,armory-path)
        ("OGENT_CREATED_AT" . ,created-at)
        ("OGENT_UPDATED_AT" . ,updated-at)
        ("OGENT_RUN_AFTER" . ,run-after)
        ("OGENT_OWNER_TASK" . ,owner-task)
        ("OGENT_ONE_SHOT_STATE" . ,one-shot-state)
        ("OGENT_LAST_RUN" . ,last-run)
        ("OGENT_NEXT_RUN" . ,next-run)
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
      (ogent-armory--org-mode)
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
              :adapter (ogent-armory--blank-to-nil
                        (org-entry-get nil "OGENT_ADAPTER"))
              :adapter-config (ogent-armory--blank-to-nil
                               (org-entry-get nil "OGENT_ADAPTER_CONFIG"))
              :provider (ogent-armory--blank-to-nil
                         (org-entry-get nil "OGENT_PROVIDER"))
              :model (ogent-armory--blank-to-nil
                      (org-entry-get nil "OGENT_MODEL"))
              :effort (ogent-armory--blank-to-nil
                       (org-entry-get nil "OGENT_EFFORT"))
              :runtime-mode (ogent-armory--blank-to-nil
                             (org-entry-get nil "OGENT_RUNTIME_MODE"))
              :workspace (ogent-armory--blank-to-nil
                          (org-entry-get nil "OGENT_WORKSPACE"))
              :timeout (ogent-armory--blank-to-nil
                        (org-entry-get nil "OGENT_TIMEOUT"))
              :on-complete (ogent-armory--blank-to-nil
                            (org-entry-get nil "OGENT_ON_COMPLETE"))
              :on-failure (ogent-armory--blank-to-nil
                           (org-entry-get nil "OGENT_ON_FAILURE"))
              :armory-path (ogent-armory--blank-to-nil
                             (org-entry-get nil "OGENT_ARMORY_PATH"))
              :created-at (ogent-armory--blank-to-nil
                           (org-entry-get nil "OGENT_CREATED_AT"))
              :updated-at (ogent-armory--blank-to-nil
                           (org-entry-get nil "OGENT_UPDATED_AT"))
              :run-after (ogent-armory--blank-to-nil
                          (org-entry-get nil "OGENT_RUN_AFTER"))
              :owner-task (ogent-armory--blank-to-nil
                           (org-entry-get nil "OGENT_OWNER_TASK"))
              :one-shot-state (ogent-armory--blank-to-nil
                               (org-entry-get nil "OGENT_ONE_SHOT_STATE"))
              :last-run (ogent-armory--blank-to-nil
                         (org-entry-get nil "OGENT_LAST_RUN"))
              :next-run (ogent-armory--blank-to-nil
                         (org-entry-get nil "OGENT_NEXT_RUN"))
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
    (when-let ((run-after (ogent-armory--blank-to-nil
                           (plist-get job :run-after))))
      (unless (ogent-armory--time-expression-p run-after)
        (push (format "OGENT_RUN_AFTER must be a parseable time: %s"
                      run-after)
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
      (ogent-armory--org-mode)
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
    (ogent-armory--org-mode)
    (let* ((name (ogent-armory--first-heading-title))
           (todo (or (nth 2 (org-heading-components))
                     (when (string-match "\\`\\(DONE\\|FAILED\\|TODO\\)\\_>" name)
                       (match-string 1 name))))
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

(defun ogent-armory--section-src-text (heading)
  "Return source block body under Org subsection HEADING."
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
        (forward-line 1)
        (skip-chars-forward " \t\n")
        (when (looking-at "^[ \t]*#\\+begin_src[^\n]*$")
          (goto-char (line-end-position))
          (let ((begin (line-beginning-position 2)))
            (when (re-search-forward "^[ \t]*#\\+end_src[ \t]*$" nil t)
              (string-trim
               (buffer-substring-no-properties
                begin
                (line-beginning-position))))))))))

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
      (ogent-armory--org-mode)
      (let* ((exit-status (plist-get record :exit-status))
             (successful (if exit-status
                             (zerop exit-status)
                           (equal (plist-get record :status) "DONE")))
             (error-text (ogent-armory--strip-src-wrapper
                          (or (ogent-armory--section-src-text "Error")
                              (ogent-armory--section-text "Error"))))
             (trace-text (or (ogent-armory--blank-to-nil
                              (or (ogent-armory--section-src-text
                                   "Runtime Trace")
                                  (ogent-armory--strip-src-wrapper
                                   (ogent-armory--section-text
                                    "Runtime Trace"))))
                             (when successful
                               (ogent-armory--blank-to-nil error-text)))))
        (append
         record
         (list :prompt (or (ogent-armory--section-src-text "Prompt")
                           (ogent-armory--strip-src-wrapper
                            (ogent-armory--section-text "Prompt")))
               :output (or (ogent-armory--section-src-text "Output")
                           (ogent-armory--strip-src-wrapper
                            (ogent-armory--section-text "Output")))
               :error (unless successful
                        error-text)
               :runtime-trace trace-text
               :tools (ogent-armory--tool-blocks)))))))

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
    (ogent-armory--org-mode)
    (condition-case nil
        (progn
          (let* ((heading (ogent-armory--first-heading-title))
                 (agent-property (ogent-armory--blank-to-nil
                                  (org-entry-get nil "OGENT_AGENT")))
                 (slug-property (ogent-armory--blank-to-nil
                                 (org-entry-get nil "OGENT_SLUG")))
                 (agent (if (and agent-property
                                 (not (member (downcase agent-property)
                                              '("t" "true" "yes"))))
                            agent-property
                          slug-property)))
            (list
             :kind (cond
                    ((org-entry-get nil "OGENT_ARMORY") 'armory)
                    ((org-entry-get nil "OGENT_CONVERSATION") 'conversation)
                    ((org-entry-get nil "OGENT_SESSION") 'session)
                    ((org-entry-get nil "OGENT_JOB") 'job)
                    ((org-entry-get nil "OGENT_AGENT") 'agent)
                    ((org-entry-get nil "OGENT_IMPORT") 'import)
                    ((org-entry-get nil "OGENT_ISSUE_ID") 'issue-link)
                    (t 'org))
             :heading heading
             :agent agent
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

(defun ogent-armory--conversation-org-files (root)
  "Return canonical conversation index files under ROOT.
These live below .agents/.conversations/, which
`ogent-armory-org-files' deliberately hides."
  (let ((store (expand-file-name ".agents/.conversations" root)))
    (when (file-directory-p store)
      (directory-files-recursively store "\\`index\\.org\\'"))))

(cl-defun ogent-armory-search-records
    (directory query &key kind agent status tag archived)
  "Return Armory search matches for QUERY under DIRECTORY.
Optional filters narrow by KIND, AGENT, STATUS, TAG, and ARCHIVED state."
  (let ((root (ogent-armory--directory directory))
        (case-fold-search t)
        (regexp (regexp-quote (or query "")))
        results)
    (unless (string-blank-p (or query ""))
      (dolist (file (append (ogent-armory-org-files root)
                            (ogent-armory--conversation-org-files root)))
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

(defun ogent-armory-overview (directory)
  "Return a Armory overview plist for DIRECTORY."
  (let* ((root (directory-file-name
                (file-truename (ogent-armory--directory directory))))
         (index (ogent-armory-read-index root))
         (agents (ogent-armory-agent-records root :include-visible t))
         (jobs nil))
    (dolist (agent agents)
      (when (eq (plist-get agent :scope) 'armory)
        (setq jobs
              (append jobs
                      (ogent-armory-list-jobs
                       root
                       (plist-get agent :slug))))))
    (list :root root
          :id (plist-get index :id)
          :name (plist-get index :name)
          :kind (ogent-armory--armory-kind index)
          :parent (plist-get index :parent)
          :description (plist-get index :description)
          :entry (plist-get index :entry)
          :access (plist-get index :access)
          :shared-context (plist-get index :shared-context)
          :children (ogent-armory-child-armories root)
          :visible-armories (ogent-armory-visible-armories root)
          :agents agents
          :global-agents (seq-filter (lambda (agent)
                                       (eq (plist-get agent :scope) 'global))
                                     agents)
          :jobs jobs)))

(defun ogent-armory--app-owner (root relative)
  "Return owner metadata for app RELATIVE under ROOT."
  (or
   (seq-find
    (lambda (session)
      (member relative (plist-get session :app-paths)))
    (ogent-armory-list-sessions root))
   (ogent-armory--canonical-app-owner root relative)
   (let ((parts (split-string relative "/" t)))
     (when (and (equal (car parts) ".agents") (cadr parts))
       (list :agent (cadr parts))))))

(defun ogent-armory--canonical-app-owner (root relative)
  "Return canonical conversation owner for app RELATIVE under ROOT."
  (let ((conversations-dir (expand-file-name ".agents/.conversations" root))
        owner)
    (when (file-directory-p conversations-dir)
      (dolist (conversation-id
               (directory-files conversations-dir nil
                                directory-files-no-dot-files-regexp))
        (let ((file (expand-file-name
                     "index.org"
                     (expand-file-name conversation-id conversations-dir))))
          (when (and (not owner) (file-readable-p file))
            (with-temp-buffer
              (insert-file-contents file)
              (ogent-armory--org-mode)
              (condition-case nil
                  (progn
                    (ogent-armory--first-heading-title)
                    (let ((artifacts
                           (ogent-armory--tags-from-string
                            (org-entry-get nil "OGENT_ARTIFACTS"))))
                      (when (seq-some
                             (lambda (artifact)
                               (or (equal artifact relative)
                                   (equal (directory-file-name artifact)
                                          relative)
                                   (equal (file-name-directory
                                           (directory-file-name artifact))
                                          (file-name-as-directory relative))))
                             artifacts)
                        (setq owner
                              (list :id conversation-id
                                    :conversation-id conversation-id
                                    :agent (ogent-armory--blank-to-nil
                                            (org-entry-get nil "OGENT_AGENT"))
                                    :job-id (ogent-armory--blank-to-nil
                                             (org-entry-get nil "OGENT_JOB_ID"))
                                    :path file)))))
                (error nil)))))))
    owner))

(defun ogent-armory-list-apps (directory)
  "Return Armory app artifacts under DIRECTORY.
An app artifact is a directory containing an index.html file."
  (let* ((root (ogent-armory--directory directory))
         (files (directory-files-recursively root "index\\.html\\'"))
         apps)
    (dolist (file files)
      (let* ((dir (file-name-directory file))
             (relative (directory-file-name
                        (file-relative-name dir root)))
             (owner (ogent-armory--app-owner root relative)))
        (unless (and (ogent-armory--hidden-path-p root file)
                     (not owner))
          (let ((attrs (file-attributes file)))
            (push (list :label (if (string-empty-p relative) "." relative)
                        :directory (directory-file-name dir)
                        :path file
                        :modified (format-time-string
                                   "%Y-%m-%d %H:%M"
                                   (file-attribute-modification-time attrs))
                        :agent (plist-get owner :agent)
                        :job-id (plist-get owner :job-id)
                        :conversation-id (plist-get owner :conversation-id)
                        :session-id (plist-get owner :id)
                        :session-path (plist-get owner :path))
                  apps)))))
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
