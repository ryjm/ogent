;;; ogent-armory-actions.el --- Armory action proposals -*- lexical-binding: t; -*-

;;; Commentary:
;; Parse, validate, approve, and dispatch actions proposed by lead agents.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'ogent-armory)
(require 'ogent-armory-evil)
(require 'ogent-armory-conversations)
(require 'ogent-armory-runner)
(require 'ogent-armory-schedule)

(defgroup ogent-armory-actions nil
  "Approval gate for Armory agent action proposals."
  :group 'ogent-armory
  :prefix "ogent-armory-actions-")

(defvar ogent-armory-actions-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a" #'ogent-armory-actions-approve-at-point)
    (define-key map (kbd "C-c a") #'ogent-armory-actions-approve-at-point)
    (define-key map "r" #'ogent-armory-actions-reject-at-point)
    (define-key map (kbd "C-c r") #'ogent-armory-actions-reject-at-point)
    (define-key map "A" #'ogent-armory-actions-approve-buffer)
    (define-key map (kbd "C-c A") #'ogent-armory-actions-approve-buffer)
    (define-key map "R" #'ogent-armory-actions-reject-buffer)
    (define-key map (kbd "C-c R") #'ogent-armory-actions-reject-buffer)
    (define-key map "d" #'ogent-armory-actions-dispatch-buffer)
    (define-key map (kbd "C-c d") #'ogent-armory-actions-dispatch-buffer)
    (define-key map "g" #'ogent-armory-actions-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-actions-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-actions-mode'.")

(defvar-local ogent-armory-actions--root nil
  "Armory root for the current actions buffer.")

(defvar-local ogent-armory-actions--conversation-id nil
  "Conversation id for the current actions buffer.")

(define-derived-mode ogent-armory-actions-mode tabulated-list-mode
  "Armory-Actions"
  "Major mode for Armory action proposal approval."
  :group 'ogent-armory-actions
  (setq-local tabulated-list-format
              [("Status" 12 t)
               ("Type" 15 t)
               ("Agent" 14 t)
               ("Title" 28 t)
               ("Errors" 35 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-actions-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-actions-file (directory conversation-id)
  "Return the actions file for CONVERSATION-ID under DIRECTORY."
  (expand-file-name "actions.org"
                    (ogent-armory-conversation-directory
                     directory conversation-id)))

(defun ogent-armory-actions--iso-now ()
  "Return the current time as an ISO-like local timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun ogent-armory-actions--parts (text)
  "Return pipe-delimited TEXT parts."
  (mapcar #'string-trim (split-string text "[ \t]*|[ \t]*" t)))

(defun ogent-armory-actions--type (value)
  "Return canonical action type for VALUE."
  (let ((text (downcase
               (replace-regexp-in-string "_" "-"
                                         (format "%s" value)))))
    (pcase text
      ((or "launch-task" "launchtask") 'launch-task)
      ((or "schedule-job" "schedulejob") 'schedule-job)
      ((or "schedule-task" "scheduletask") 'schedule-task)
      (_ (intern text)))))

(defun ogent-armory-actions--value (record &rest keys)
  "Return the first value found in RECORD for KEYS."
  (catch 'value
    (dolist (key keys)
      (when (plist-member record key)
        (throw 'value (plist-get record key))))
    nil))

(defun ogent-armory-actions--string-value (record &rest keys)
  "Return a string value from RECORD for KEYS."
  (when-let ((value (apply #'ogent-armory-actions--value record keys)))
    (format "%s" value)))

(defun ogent-armory-actions--canonical (action)
  "Return ACTION with canonical keys."
  (let* ((type (ogent-armory-actions--type
                (ogent-armory-actions--value action :type 'type "type")))
         (target (ogent-armory-actions--string-value
                  action :target-agent :agent 'target-agent 'agent "agent"))
         (title (ogent-armory-actions--string-value
                 action :title :name 'title 'name "title" "name"))
         (prompt (ogent-armory-actions--string-value
                  action :prompt 'prompt "prompt"))
         (cron (ogent-armory-actions--string-value
                action :cron 'cron "cron"))
         (datetime (ogent-armory-actions--string-value
                    action :datetime :run-at 'datetime 'run-at
                    "datetime" "run_at")))
    (list :id (or (ogent-armory-actions--string-value
                   action :id 'id "id")
                  (secure-hash
                   'sha1
                   (format "%s|%s|%s|%s|%s|%s"
                           type target title prompt cron datetime)))
          :type type
          :target-agent target
          :title title
          :prompt prompt
          :cron cron
          :datetime datetime
          :status (or (ogent-armory-actions--string-value
                       action :status 'status "status")
                      "pending")
          :provider (ogent-armory-actions--string-value
                     action :provider 'provider "provider")
          :adapter (ogent-armory-actions--string-value
                    action :adapter :adapter-id 'adapter 'adapter-id
                    "adapter" "adapter_id")
          :model (ogent-armory-actions--string-value
                  action :model 'model "model")
          :effort (ogent-armory-actions--string-value
                   action :effort 'effort "effort")
          :runtime-mode (ogent-armory-actions--string-value
                         action :runtime-mode :runtime 'runtime-mode
                         'runtime "runtime_mode" "runtime"))))

(defun ogent-armory-actions--line-action (kind payload)
  "Return a proposal action for KIND and line PAYLOAD."
  (let ((parts (ogent-armory-actions--parts payload)))
    (pcase kind
      ("LAUNCH_TASK"
       (when (>= (length parts) 3)
         (ogent-armory-actions--canonical
          (list :type 'launch-task
                :target-agent (nth 0 parts)
                :title (nth 1 parts)
                :prompt (string-join (nthcdr 2 parts) " | ")))))
      ("SCHEDULE_JOB"
       (when (>= (length parts) 4)
         (ogent-armory-actions--canonical
          (list :type 'schedule-job
                :target-agent (nth 0 parts)
                :title (nth 1 parts)
                :cron (nth 2 parts)
                :prompt (string-join (nthcdr 3 parts) " | ")))))
      ("SCHEDULE_TASK"
       (when (>= (length parts) 4)
         (ogent-armory-actions--canonical
          (list :type 'schedule-task
                :target-agent (nth 0 parts)
                :datetime (nth 1 parts)
                :title (nth 2 parts)
                :prompt (string-join (nthcdr 3 parts) " | "))))))))

(defun ogent-armory-actions--json-actions (text)
  "Return proposal actions from JSON TEXT."
  (condition-case nil
      (let ((parsed (json-parse-string
                     text
                     :object-type 'plist
                     :array-type 'list
                     :null-object nil
                     :false-object nil)))
        (mapcar #'ogent-armory-actions--canonical
                (if (and (listp parsed)
                         (keywordp (car parsed)))
                    (list parsed)
                  parsed)))
    (error nil)))

(defun ogent-armory-actions--block-actions (text)
  "Return proposal actions from Armory JSON blocks in TEXT."
  (let (actions)
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      (let ((case-fold-search t))
        (while (re-search-forward
                "^#\\+begin_\\(?:armory-actions\\|src json.*armory-actions\\).*$"
                nil t)
          (let ((begin (line-beginning-position 2)))
            (when (re-search-forward
                   "^#\\+end_\\(?:armory-actions\\|src\\).*$" nil t)
              (setq actions
                    (append actions
                            (ogent-armory-actions--json-actions
                             (buffer-substring-no-properties
                              begin
                              (line-beginning-position))))))))))
    actions))

(defun ogent-armory-actions-dedupe (actions)
  "Return ACTIONS with duplicate proposals removed."
  (let ((seen (make-hash-table :test 'equal))
        deduped)
    (dolist (action actions)
      (let ((id (plist-get action :id)))
        (unless (gethash id seen)
          (puthash id t seen)
          (push action deduped))))
    (nreverse deduped)))

(defun ogent-armory-actions-parse (text)
  "Parse action proposals from TEXT."
  (let ((actions (ogent-armory-actions--block-actions text)))
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      (while (re-search-forward
              "^\\(LAUNCH_TASK\\|SCHEDULE_JOB\\|SCHEDULE_TASK\\):[ \t]*\\(.+\\)$"
              nil t)
        (when-let ((action (ogent-armory-actions--line-action
                            (match-string 1)
                            (match-string 2))))
          (push action actions))))
    (ogent-armory-actions-dedupe (nreverse actions))))

(defun ogent-armory-actions--inherit-runtime (action source-agent)
  "Return ACTION with runtime fields inherited from SOURCE-AGENT."
  (let ((record (copy-sequence action)))
    (dolist (pair '((:provider . :provider)
                    (:adapter . :adapter)
                    (:model . :model)
                    (:effort . :effort)
                    (:runtime-mode . :runtime-mode)))
      (unless (ogent-armory--blank-to-nil (plist-get record (car pair)))
        (setq record
              (plist-put record
                         (car pair)
                         (plist-get source-agent (cdr pair))))))
    record))

(cl-defun ogent-armory-actions-validate
    (directory actions &key triggering-agent)
  "Validate ACTIONS under DIRECTORY.
TRIGGERING-AGENT supplies runtime inheritance and self-launch checks."
  (let* ((root (ogent-armory--directory directory))
         (source-agent (when triggering-agent
                         (condition-case nil
                             (ogent-armory-resolve-agent
                              root triggering-agent :include-visible t)
                           (user-error nil)))))
    (mapcar
     (lambda (action)
       (let* ((record (if source-agent
                          (ogent-armory-actions--inherit-runtime
                           action source-agent)
                        (copy-sequence action)))
              (target (plist-get record :target-agent))
              errors
              warnings)
         (unless (ogent-armory--blank-to-nil target)
           (push "Target agent is required" errors))
         (when target
           (condition-case nil
               (plist-put record :target-agent-record
                          (ogent-armory-resolve-agent
                           root target :include-visible t))
             (user-error
              (push (format "Target agent not found: %s" target) errors))))
         (when (and triggering-agent target
                    (equal triggering-agent target))
           (push "Self-launch proposal" warnings))
         (unless (ogent-armory--blank-to-nil (plist-get record :title))
           (push "Title is required" errors))
         (unless (ogent-armory--blank-to-nil (plist-get record :prompt))
           (push "Prompt is required" errors))
         (when (eq (plist-get record :type) 'schedule-job)
           (unless (ogent-armory--cron-expression-p
                    (or (plist-get record :cron) ""))
             (push (format "Cron must have five fields: %s"
                           (or (plist-get record :cron) ""))
                   errors)))
         (when (eq (plist-get record :type) 'schedule-task)
           (unless (ogent-armory--blank-to-nil
                    (plist-get record :datetime))
             (push "Scheduled task datetime is required" errors)))
         (setq record (plist-put record :triggering-agent triggering-agent))
         (setq record (plist-put record :errors (nreverse errors)))
         (setq record (plist-put record :warnings (nreverse warnings)))
         (setq record (plist-put record :valid (null errors)))
         (unless (plist-get record :status)
           (setq record (plist-put record :status "pending")))
         record))
     (ogent-armory-actions-dedupe actions))))

(defun ogent-armory-actions--format-action (action)
  "Return ACTION as an Org heading."
  (concat
   (format "* %s %s\n"
           (upcase (or (plist-get action :status) "pending"))
           (or (plist-get action :title) (plist-get action :id)))
   (ogent-armory--format-properties
    `(("OGENT_ACTION" . t)
      ("OGENT_ACTION_ID" . ,(plist-get action :id))
      ("OGENT_ACTION_TYPE" . ,(plist-get action :type))
      ("OGENT_ACTION_STATUS" . ,(plist-get action :status))
      ("OGENT_TARGET_AGENT" . ,(plist-get action :target-agent))
      ("OGENT_TRIGGERING_AGENT" . ,(plist-get action :triggering-agent))
      ("OGENT_TITLE" . ,(plist-get action :title))
      ("OGENT_CRON" . ,(plist-get action :cron))
      ("OGENT_DATETIME" . ,(plist-get action :datetime))
      ("OGENT_PROVIDER" . ,(plist-get action :provider))
      ("OGENT_ADAPTER" . ,(plist-get action :adapter))
      ("OGENT_MODEL" . ,(plist-get action :model))
      ("OGENT_EFFORT" . ,(plist-get action :effort))
      ("OGENT_RUNTIME_MODE" . ,(plist-get action :runtime-mode))
      ("OGENT_VALID" . ,(plist-get action :valid))
      ("OGENT_ERRORS" . ,(plist-get action :errors))
      ("OGENT_WARNINGS" . ,(plist-get action :warnings))
      ("OGENT_DISPATCHED_ID" . ,(plist-get action :dispatched-id))))
   "\n"
   (string-trim (or (plist-get action :prompt) ""))
   "\n\n"))

(defun ogent-armory-actions-store (directory conversation-id actions)
  "Store ACTIONS under CONVERSATION-ID in DIRECTORY."
  (let ((file (ogent-armory-actions-file directory conversation-id)))
    (ogent-armory--write-file
     file
     (concat
      (format "#+title: Actions for %s\n\n" conversation-id)
      (mapconcat #'ogent-armory-actions--format-action actions "")))
    (ogent-armory-conversation-update-properties
     directory conversation-id
     `(("OGENT_ACTIONS_PROPOSED_AT" .
        ,(ogent-armory-actions--iso-now))))
    file))

(defun ogent-armory-actions-read (directory conversation-id)
  "Read action proposals under CONVERSATION-ID in DIRECTORY."
  (let ((file (ogent-armory-actions-file directory conversation-id))
        actions)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ogent-armory--org-mode)
        (org-map-entries
         (lambda ()
           (when (org-entry-get nil "OGENT_ACTION")
             (push
              (list :id (org-entry-get nil "OGENT_ACTION_ID")
                    :type (ogent-armory-actions--type
                           (org-entry-get nil "OGENT_ACTION_TYPE"))
                    :status (or (org-entry-get nil "OGENT_ACTION_STATUS")
                                "pending")
                    :target-agent (org-entry-get nil "OGENT_TARGET_AGENT")
                    :triggering-agent (org-entry-get nil "OGENT_TRIGGERING_AGENT")
                    :title (org-entry-get nil "OGENT_TITLE")
                    :cron (ogent-armory--blank-to-nil
                           (org-entry-get nil "OGENT_CRON"))
                    :datetime (ogent-armory--blank-to-nil
                               (org-entry-get nil "OGENT_DATETIME"))
                    :provider (ogent-armory--blank-to-nil
                               (org-entry-get nil "OGENT_PROVIDER"))
                    :adapter (ogent-armory--blank-to-nil
                              (org-entry-get nil "OGENT_ADAPTER"))
                    :model (ogent-armory--blank-to-nil
                            (org-entry-get nil "OGENT_MODEL"))
                    :effort (ogent-armory--blank-to-nil
                             (org-entry-get nil "OGENT_EFFORT"))
                    :runtime-mode (ogent-armory--blank-to-nil
                                   (org-entry-get nil "OGENT_RUNTIME_MODE"))
                    :valid (ogent-armory--truth-value
                            (org-entry-get nil "OGENT_VALID"))
                    :errors (ogent-armory--tags-from-string
                             (org-entry-get nil "OGENT_ERRORS"))
                    :warnings (ogent-armory--tags-from-string
                               (org-entry-get nil "OGENT_WARNINGS"))
                    :dispatched-id (ogent-armory--blank-to-nil
                                    (org-entry-get nil "OGENT_DISPATCHED_ID"))
                    :prompt (ogent-armory--heading-body))
              actions))))
        (nreverse actions)))))

(defun ogent-armory-actions--set-status (actions status)
  "Return ACTIONS with STATUS."
  (mapcar (lambda (action)
            (plist-put (copy-sequence action) :status status))
          actions))

(defun ogent-armory-actions-approve-all (actions)
  "Return ACTIONS marked approved."
  (ogent-armory-actions--set-status actions "approved"))

(defun ogent-armory-actions-reject-all (actions)
  "Return ACTIONS marked rejected."
  (ogent-armory-actions--set-status actions "rejected"))

(defun ogent-armory-actions--runtime-symbol (value)
  "Return VALUE as a runtime symbol."
  (when (ogent-armory--blank-to-nil value)
    (intern (format "%s" value))))

(defun ogent-armory-actions--launch (root conversation-id action triggering-agent)
  "Dispatch launch ACTION under ROOT from CONVERSATION-ID."
  (let* ((runtime-mode (ogent-armory-actions--runtime-symbol
                        (plist-get action :runtime-mode)))
         (plan (ogent-armory-runner-plan
                root
                (plist-get action :target-agent)
                :instruction (plist-get action :prompt)
                :turn-content (plist-get action :prompt)
                :conversation-title (plist-get action :title)
                :trigger "agent"
                :provider (plist-get action :provider)
                :adapter-id (plist-get action :adapter)
                :model (plist-get action :model)
                :effort (plist-get action :effort)
                :runtime-mode runtime-mode
                :parent-task conversation-id
                :triggering-agent triggering-agent
                :spawn-depth 1)))
    (ogent-armory-runner-start plan)
    (plist-put (copy-sequence action)
               :dispatched-id
               (plist-get plan :conversation-id))))

(defun ogent-armory-actions--job-id (title)
  "Return a job id for TITLE."
  (ogent-armory--slug title "job"))

(defun ogent-armory-actions--schedule-job (root conversation-id action)
  "Create a job from ACTION under ROOT and CONVERSATION-ID."
  (let* ((agent (plist-get action :target-agent))
         (job-id (ogent-armory-actions--job-id
                  (or (plist-get action :title) "job")))
         (_file (ogent-armory-write-job
                 root agent
                 (list :id job-id
                       :name (plist-get action :title)
                       :cron (plist-get action :cron)
                       :enabled t
                       :provider (plist-get action :provider)
                       :model (plist-get action :model)
                       :owner-task conversation-id)
                 (plist-get action :prompt))))
    (plist-put (copy-sequence action) :dispatched-id job-id)))

(defun ogent-armory-actions--schedule-task (root conversation-id action triggering-agent)
  "Create a scheduled conversation from ACTION under ROOT."
  (let* ((id (format "%s-%s"
                     (format-time-string "%Y%m%dT%H%M%S")
                     (substring (plist-get action :id) 0 8)))
         (target (plist-get action :target-agent))
         (datetime (plist-get action :datetime))
         (schedule-key (ogent-armory-schedule-key
                        target
                        'task
                        (plist-get action :id)
                        (ogent-armory-schedule-parse-time datetime)))
         (_file (ogent-armory-conversation-create
                 root
                 (list :id id
                       :agent target
                       :title (plist-get action :title)
                       :trigger "agent"
                       :status "idle"
                       :scheduled-at datetime
                       :scheduled-key schedule-key
                       :provider (plist-get action :provider)
                       :model (plist-get action :model)
                       :effort (plist-get action :effort)
                       :parent-task conversation-id
                       :triggering-agent triggering-agent
                       :spawn-depth 1))))
    (ogent-armory-conversation-append-turn
     root id "user" (plist-get action :prompt)
     :ts (ogent-armory-actions--iso-now))
    (plist-put (copy-sequence action) :dispatched-id id)))

(cl-defun ogent-armory-actions-dispatch
    (directory conversation-id actions &key triggering-agent)
  "Dispatch approved ACTIONS under DIRECTORY for CONVERSATION-ID."
  (let* ((root (ogent-armory--directory directory))
         (conversation (ogent-armory-conversation-read root conversation-id))
         (triggering-agent (or triggering-agent
                               (plist-get conversation :agent)))
         dispatched)
    (dolist (action actions)
      (if (and (plist-get action :valid)
               (equal (plist-get action :status) "approved"))
          (let ((updated
                 (pcase (plist-get action :type)
                   ('launch-task
                    (ogent-armory-actions--launch
                     root conversation-id action triggering-agent))
                   ('schedule-job
                    (ogent-armory-actions--schedule-job
                     root conversation-id action))
                   ('schedule-task
                    (ogent-armory-actions--schedule-task
                     root conversation-id action triggering-agent))
                   (_ action))))
            (push (plist-put updated :status "dispatched") dispatched))
        (push action dispatched)))
    (setq dispatched (nreverse dispatched))
    (ogent-armory-actions-store root conversation-id dispatched)
    dispatched))

(defun ogent-armory-actions--entries ()
  "Return tabulated action entries for the current buffer."
  (mapcar
   (lambda (action)
     (list (plist-get action :id)
           (vector
            (or (plist-get action :status) "")
            (symbol-name (plist-get action :type))
            (or (plist-get action :target-agent) "")
            (or (plist-get action :title) "")
            (string-join (or (plist-get action :errors) nil) ", "))))
   (ogent-armory-actions-read
    ogent-armory-actions--root
    ogent-armory-actions--conversation-id)))

;;;###autoload
(defun ogent-armory-actions (&optional directory conversation-id)
  "Open action approvals for CONVERSATION-ID under DIRECTORY."
  (interactive
   (let* ((root (or (ogent-armory-find-root)
                    (read-directory-name "Armory root: ")))
          (conversation (completing-read
                         "Conversation: "
                         (mapcar (lambda (record)
                                   (plist-get record :id))
                                 (ogent-armory-conversation-list root))
                         nil t)))
     (list root conversation)))
  (let* ((root (ogent-armory--directory directory))
         (buffer (get-buffer-create
                  (format "*ogent-armory-actions:%s*" conversation-id))))
    (with-current-buffer buffer
      (ogent-armory-actions-mode)
      (setq ogent-armory-actions--root root)
      (setq ogent-armory-actions--conversation-id conversation-id)
      (setq tabulated-list-entries #'ogent-armory-actions--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-actions-refresh (&rest _)
  "Refresh the current actions buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-actions--update-buffer-status (status)
  "Set the current buffer action at point to STATUS."
  (let* ((id (or (tabulated-list-get-id)
                 (user-error "No Armory action at point")))
         (actions (ogent-armory-actions-read
                   ogent-armory-actions--root
                   ogent-armory-actions--conversation-id))
         (updated (mapcar
                   (lambda (action)
                     (if (equal (plist-get action :id) id)
                         (plist-put (copy-sequence action) :status status)
                       action))
                   actions)))
    (ogent-armory-actions-store
     ogent-armory-actions--root
     ogent-armory-actions--conversation-id
     updated)
    (ogent-armory-actions-refresh)))

(defun ogent-armory-actions-approve-at-point ()
  "Approve the Armory action at point."
  (interactive)
  (ogent-armory-actions--update-buffer-status "approved"))

(defun ogent-armory-actions-reject-at-point ()
  "Reject the Armory action at point."
  (interactive)
  (ogent-armory-actions--update-buffer-status "rejected"))

(defun ogent-armory-actions-approve-buffer ()
  "Approve all Armory actions in this buffer."
  (interactive)
  (ogent-armory-actions-store
   ogent-armory-actions--root
   ogent-armory-actions--conversation-id
   (ogent-armory-actions-approve-all
    (ogent-armory-actions-read
     ogent-armory-actions--root
     ogent-armory-actions--conversation-id)))
  (ogent-armory-actions-refresh))

(defun ogent-armory-actions-reject-buffer ()
  "Reject all Armory actions in this buffer."
  (interactive)
  (ogent-armory-actions-store
   ogent-armory-actions--root
   ogent-armory-actions--conversation-id
   (ogent-armory-actions-reject-all
    (ogent-armory-actions-read
     ogent-armory-actions--root
     ogent-armory-actions--conversation-id)))
  (ogent-armory-actions-refresh))

(defun ogent-armory-actions-dispatch-buffer ()
  "Dispatch approved actions in this buffer."
  (interactive)
  (ogent-armory-actions-dispatch
   ogent-armory-actions--root
   ogent-armory-actions--conversation-id
   (ogent-armory-actions-read
    ogent-armory-actions--root
    ogent-armory-actions--conversation-id))
  (ogent-armory-actions-refresh))

(defun ogent-armory-actions--evil-local-keys ()
  "Install local Evil keys for Armory actions."
  (ogent-armory-evil-install-local-bindings ogent-armory-actions-mode-map))

(defun ogent-armory-actions--setup-evil ()
  "Set up Evil integration for Armory actions."
  (ogent-armory-evil-setup-mode
   'ogent-armory-actions-mode
   ogent-armory-actions-mode-map
   'ogent-armory-actions-mode-hook
   #'ogent-armory-actions--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-actions--setup-evil))

(provide 'ogent-armory-actions)

;;; ogent-armory-actions.el ends here
