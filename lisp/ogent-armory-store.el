;;; ogent-armory-store.el --- Armory storage kernel -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides the storage kernel shared by every Armory module: value
;; and validation primitives, Org path resolution, root discovery,
;; and record metadata classification.  `ogent-armory' requires this
;; file, so its requirers see every symbol unchanged.

;;; Code:

(require 'org)
(require 'seq)
(require 'subr-x)
(require 'ogent-armory-cache)

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
  "Return non-nil when VALUE is a heartbeat or cron expression."
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

(defun ogent-armory--invalidate-cache-for-file (file)
  "Invalidate cached Armory data for FILE's root, when FILE is inside one."
  (when-let ((root (ignore-errors
                     (ogent-armory-find-root (file-name-directory file)))))
    (ogent-armory-cache-invalidate
     (file-truename (ogent-armory--directory root)))))

(defun ogent-armory--write-file (file content)
  "Write CONTENT to FILE, creating parent directories first."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert content))
  (ogent-armory--invalidate-cache-for-file file))

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
  "Return non-nil when VALUE is readable as an Emacs time expression."
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
             :issue-parent (ogent-armory--blank-to-nil
                            (org-entry-get nil "OGENT_ISSUE_PARENT"))
             :assigned-worker (ogent-armory--blank-to-nil
                               (org-entry-get nil "OGENT_ASSIGNED_WORKER")))))
      (error (list :kind 'org :heading nil :tags nil)))))

(defun ogent-armory-record-kind (file)
  "Return the Armory record kind represented by FILE."
  (plist-get (ogent-armory-record-metadata file) :kind))

(provide 'ogent-armory-store)

;;; ogent-armory-store.el ends here
