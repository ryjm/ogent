;;; ogent-cabinet-conversations.el --- Org Cabinet conversations -*- lexical-binding: t; -*-

;;; Commentary:
;; Canonical Org-backed conversation records for Cabinet-style task runs.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'seq)
(require 'subr-x)
(require 'ogent-cabinet)

(defgroup ogent-cabinet-conversations nil
  "Org-native Cabinet conversation records."
  :group 'ogent-cabinet)

(defconst ogent-cabinet-conversations--index-file "index.org"
  "File name for a canonical conversation index.")

(defconst ogent-cabinet-conversations--events-file "events.org"
  "File name for a canonical conversation event log.")

(defconst ogent-cabinet-conversations--session-file "session.org"
  "File name for a canonical conversation session handle.")

(defun ogent-cabinet-conversations-directory (directory)
  "Return the canonical conversations directory under DIRECTORY."
  (expand-file-name ".agents/.conversations"
                    (ogent-cabinet--directory directory)))

(defun ogent-cabinet-conversation-directory (directory conversation-id)
  "Return the directory for CONVERSATION-ID under DIRECTORY."
  (expand-file-name conversation-id
                    (ogent-cabinet-conversations-directory directory)))

(defun ogent-cabinet-conversation-file (directory conversation-id)
  "Return the index Org file for CONVERSATION-ID under DIRECTORY."
  (expand-file-name ogent-cabinet-conversations--index-file
                    (ogent-cabinet-conversation-directory
                     directory conversation-id)))

(defun ogent-cabinet-conversation-turns-directory (directory conversation-id)
  "Return the turns directory for CONVERSATION-ID under DIRECTORY."
  (expand-file-name "turns"
                    (ogent-cabinet-conversation-directory
                     directory conversation-id)))

(defun ogent-cabinet-conversation-attachments-directory
    (directory conversation-id)
  "Return the attachments directory for CONVERSATION-ID under DIRECTORY."
  (expand-file-name "attachments"
                    (ogent-cabinet-conversation-directory
                     directory conversation-id)))

(defun ogent-cabinet-conversation-pending-directory (directory pending-id)
  "Return pending conversation directory PENDING-ID under DIRECTORY."
  (expand-file-name pending-id
                    (expand-file-name
                     "_pending"
                     (ogent-cabinet-conversations-directory directory))))

(defun ogent-cabinet-conversation-pending-attachments-directory
    (directory pending-id)
  "Return pending attachments directory PENDING-ID under DIRECTORY."
  (expand-file-name "attachments"
                    (ogent-cabinet-conversation-pending-directory
                     directory pending-id)))

(defun ogent-cabinet-conversation-artifacts-file (directory conversation-id)
  "Return the artifacts Org file for CONVERSATION-ID under DIRECTORY."
  (expand-file-name "artifacts.org"
                    (ogent-cabinet-conversation-directory
                     directory conversation-id)))

(defun ogent-cabinet-conversation-events-file (directory conversation-id)
  "Return the events Org file for CONVERSATION-ID under DIRECTORY."
  (expand-file-name ogent-cabinet-conversations--events-file
                    (ogent-cabinet-conversation-directory
                     directory conversation-id)))

(defun ogent-cabinet-conversation-session-file (directory conversation-id)
  "Return the session Org file for CONVERSATION-ID under DIRECTORY."
  (expand-file-name ogent-cabinet-conversations--session-file
                    (ogent-cabinet-conversation-directory
                     directory conversation-id)))

(defun ogent-cabinet-conversations--new-id ()
  "Return a filesystem-safe generated conversation id."
  (format "%s-%06x"
          (format-time-string "%Y%m%dT%H%M%S")
          (random #x1000000)))

(defun ogent-cabinet-conversations--copy-name (file seen)
  "Return a unique attachment name for FILE using SEEN hash table."
  (let* ((base (file-name-nondirectory file))
         (name base)
         (index 2))
    (while (gethash name seen)
      (setq name (if-let ((extension (file-name-extension base)))
                     (format "%s-%d.%s"
                             (file-name-sans-extension base)
                             index
                             extension)
                   (format "%s-%d" base index)))
      (setq index (1+ index)))
    (puthash name t seen)
    name))

(defun ogent-cabinet-conversation-stage-attachments (directory files)
  "Copy FILES into a pending attachment folder under DIRECTORY."
  (let* ((pending-id (ogent-cabinet-conversations--new-id))
         (target-dir (ogent-cabinet-conversation-pending-attachments-directory
                      directory pending-id))
         (seen (make-hash-table :test 'equal))
         staged)
    (make-directory target-dir t)
    (dolist (file files)
      (unless (file-readable-p file)
        (user-error "Attachment not readable: %s" file))
      (let* ((name (ogent-cabinet-conversations--copy-name file seen))
             (target (expand-file-name name target-dir)))
        (copy-file file target t)
        (push target staged)))
    (list :pending-id pending-id
          :attachment-paths (nreverse staged))))

(defun ogent-cabinet-conversation-finalize-attachments
    (directory pending-id conversation-id)
  "Move PENDING-ID attachments into CONVERSATION-ID under DIRECTORY."
  (let ((source-dir (ogent-cabinet-conversation-pending-attachments-directory
                    directory pending-id))
        (target-dir (ogent-cabinet-conversation-attachments-directory
                     directory conversation-id))
        attachments)
    (when (file-directory-p source-dir)
      (make-directory target-dir t)
      (dolist (file (directory-files source-dir t directory-files-no-dot-files-regexp))
        (when (file-regular-p file)
          (let ((target (expand-file-name (file-name-nondirectory file)
                                          target-dir)))
            (rename-file file target t)
            (push (file-relative-name target directory) attachments))))
      (let ((pending-root (ogent-cabinet-conversation-pending-directory
                           directory pending-id)))
        (when (file-directory-p pending-root)
          (delete-directory pending-root t))))
    (nreverse attachments)))

(defun ogent-cabinet-conversations--plist-value (plist key fallback)
  "Return PLIST KEY or FALLBACK."
  (if (plist-member plist key)
      (plist-get plist key)
    fallback))

(defun ogent-cabinet-conversations--list-property (value)
  "Return VALUE as a list suitable for a multivalue property."
  (cond
   ((null value) nil)
   ((listp value) value)
   ((stringp value) (ogent-cabinet--tags-from-string value))
   (t (list (format "%s" value)))))

(defun ogent-cabinet-conversations--number-property (value)
  "Return VALUE as a number, or nil when blank."
  (when-let ((text (ogent-cabinet--blank-to-nil value)))
    (string-to-number text)))

(defun ogent-cabinet-conversations--status (value)
  "Return VALUE normalized for canonical conversation status."
  (let ((status (downcase (or value ""))))
    (pcase status
      ((or "done" "completed" "success" "succeeded") "done")
      ((or "failed" "error") "failed")
      ((or "awaiting-input" "awaiting_input" "needs-reply") "awaiting-input")
      ((or "archive" "archived") "archived")
      ((or "cancelled" "canceled") "cancelled")
      ((or "running" "idle") status)
      (_ (if (string-empty-p status) "idle" status)))))

(defun ogent-cabinet-conversations--legacy-status (status)
  "Return canonical status from legacy session STATUS."
  (pcase (upcase (or status ""))
    ("DONE" "done")
    ("FAILED" "failed")
    ("TODO" "idle")
    (_ (ogent-cabinet-conversations--status status))))

(defun ogent-cabinet-conversations--turn-file-name (turn role)
  "Return file name for TURN and ROLE."
  (format "%03d-%s.org" turn role))

(defun ogent-cabinet-conversations--turn-file
    (directory conversation-id turn role)
  "Return the turn file for CONVERSATION-ID TURN and ROLE."
  (expand-file-name
   (ogent-cabinet-conversations--turn-file-name turn role)
   (ogent-cabinet-conversation-turns-directory directory conversation-id)))

(defun ogent-cabinet-conversations--parse-turn-file-name (name)
  "Return plist metadata parsed from turn file NAME."
  (when (string-match "\\`\\([0-9][0-9][0-9]\\)-\\(user\\|agent\\)\\.org\\'" name)
    (list :turn (string-to-number (match-string 1 name))
          :role (match-string 2 name))))

(defun ogent-cabinet-conversations--role-sort-value (role)
  "Return sort value for ROLE."
  (if (equal role "user") 0 1))

(defun ogent-cabinet-conversations--format-index (conversation)
  "Return CONVERSATION formatted as an Org index record."
  (let* ((id (or (plist-get conversation :id)
                 (ogent-cabinet-conversations--new-id)))
         (title (or (plist-get conversation :title) id))
         (status (ogent-cabinet-conversations--status
                  (or (plist-get conversation :status) "idle"))))
    (concat
     (format "#+title: %s\n\n" title)
     (format "* %s\n" title)
     (ogent-cabinet--format-properties
      `(("OGENT_CONVERSATION" . t)
        ("OGENT_CONVERSATION_ID" . ,id)
        ("OGENT_AGENT" . ,(plist-get conversation :agent))
        ("OGENT_CABINET_PATH" . ,(plist-get conversation :cabinet-path))
        ("OGENT_TITLE" . ,title)
        ("OGENT_TRIGGER" . ,(or (plist-get conversation :trigger) "manual"))
        ("OGENT_STATUS" . ,status)
        ("OGENT_STARTED_AT" . ,(plist-get conversation :started))
        ("OGENT_COMPLETED_AT" . ,(plist-get conversation :completed))
        ("OGENT_LAST_ACTIVITY_AT" . ,(plist-get conversation :last-activity))
        ("OGENT_EXIT_CODE" . ,(plist-get conversation :exit-code))
        ("OGENT_JOB_ID" . ,(plist-get conversation :job-id))
        ("OGENT_JOB_NAME" . ,(plist-get conversation :job-name))
        ("OGENT_SCHEDULED_AT" . ,(plist-get conversation :scheduled-at))
        ("OGENT_SCHEDULED_KEY" . ,(plist-get conversation :scheduled-key))
        ("OGENT_PROVIDER" . ,(plist-get conversation :provider))
        ("OGENT_ADAPTER" . ,(plist-get conversation :adapter))
        ("OGENT_MODEL" . ,(plist-get conversation :model))
        ("OGENT_EFFORT" . ,(plist-get conversation :effort))
        ("OGENT_RUNTIME_MODE" . ,(plist-get conversation :runtime-mode))
        ("OGENT_CONTEXT_WINDOW" . ,(plist-get conversation :context-window))
        ("OGENT_TOKENS_INPUT" . ,(plist-get conversation :tokens-input))
        ("OGENT_TOKENS_OUTPUT" . ,(plist-get conversation :tokens-output))
        ("OGENT_TOKENS_CACHE" . ,(plist-get conversation :tokens-cache))
        ("OGENT_TOKENS_TOTAL" . ,(plist-get conversation :tokens-total))
        ("OGENT_MENTIONS" . ,(plist-get conversation :mentioned-paths))
        ("OGENT_SKILLS" . ,(plist-get conversation :skills))
        ("OGENT_ATTACHMENTS" . ,(plist-get conversation :attachment-paths))
        ("OGENT_ARTIFACTS" . ,(plist-get conversation :artifact-paths))
        ("OGENT_DURATION" . ,(plist-get conversation :duration))
        ("OGENT_SUMMARY" . ,(plist-get conversation :summary))
        ("OGENT_CONTEXT_SUMMARY" . ,(plist-get conversation :context-summary))
        ("OGENT_AWAITING_INPUT" . ,(plist-get conversation :awaiting-input))
        ("OGENT_ARCHIVED" . ,(plist-get conversation :archived))
        ("OGENT_TITLE_PINNED" . ,(plist-get conversation :title-pinned))
        ("OGENT_BOARD_ORDER" . ,(plist-get conversation :board-order))
        ("OGENT_MUTED" . ,(plist-get conversation :muted))
        ("OGENT_ERROR_KIND" . ,(plist-get conversation :error-kind))
        ("OGENT_ERROR_HINT" . ,(plist-get conversation :error-hint))
        ("OGENT_ERROR_RETRY_AFTER" . ,(plist-get conversation :error-retry-after))
        ("OGENT_LAST_RESUME_RESULT" . ,(plist-get conversation :last-resume-result))
        ("OGENT_PARENT_TASK" . ,(plist-get conversation :parent-task))
        ("OGENT_TRIGGERING_AGENT" . ,(plist-get conversation :triggering-agent))
        ("OGENT_SPAWN_DEPTH" . ,(plist-get conversation :spawn-depth))
        ("OGENT_ACTIONS_PROPOSED_AT" . ,(plist-get conversation :actions-proposed-at))))
     "\n")))

(defun ogent-cabinet-conversation-create (directory conversation)
  "Create CONVERSATION under DIRECTORY and return its index path.
CONVERSATION is a plist.  When `:id' is absent, generate one."
  (let* ((id (or (plist-get conversation :id)
                 (ogent-cabinet-conversations--new-id)))
         (conversation (plist-put (copy-sequence conversation) :id id))
         (conversation-dir (ogent-cabinet-conversation-directory directory id))
         (file (ogent-cabinet-conversation-file directory id)))
    (make-directory (ogent-cabinet-conversation-turns-directory directory id) t)
    (make-directory (ogent-cabinet-conversation-attachments-directory
                     directory id)
                    t)
    (ogent-cabinet--write-file-if-missing
     (ogent-cabinet-conversation-artifacts-file directory id)
     "#+title: Artifacts\n\n* Artifacts\n")
    (ogent-cabinet--write-file-if-missing
     (ogent-cabinet-conversation-events-file directory id)
     "#+title: Events\n\n* Events\n")
    (ogent-cabinet--write-file-if-missing
     (ogent-cabinet-conversation-session-file directory id)
     "#+title: Session\n\n* Session\n")
    (make-directory conversation-dir t)
    (ogent-cabinet--write-file
     file
     (ogent-cabinet-conversations--format-index conversation))
    file))

(defun ogent-cabinet-conversations--read-index-file (file &optional id)
  "Read conversation index FILE and return a plist.
ID is the fallback conversation id."
  (unless (file-readable-p file)
    (user-error "Cabinet conversation not found: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let ((title (ogent-cabinet--first-heading-title)))
      (list
       :id (or (ogent-cabinet--blank-to-nil
                (org-entry-get nil "OGENT_CONVERSATION_ID"))
               id)
       :agent (ogent-cabinet--blank-to-nil
               (org-entry-get nil "OGENT_AGENT"))
       :cabinet-path (ogent-cabinet--blank-to-nil
                      (org-entry-get nil "OGENT_CABINET_PATH"))
       :title (or (ogent-cabinet--blank-to-nil
                   (org-entry-get nil "OGENT_TITLE"))
                  title)
       :trigger (or (ogent-cabinet--blank-to-nil
                     (org-entry-get nil "OGENT_TRIGGER"))
                    "manual")
       :status (ogent-cabinet-conversations--status
                (org-entry-get nil "OGENT_STATUS"))
       :started (ogent-cabinet--blank-to-nil
                 (org-entry-get nil "OGENT_STARTED_AT"))
       :completed (ogent-cabinet--blank-to-nil
                   (org-entry-get nil "OGENT_COMPLETED_AT"))
       :last-activity (ogent-cabinet--blank-to-nil
                       (org-entry-get nil "OGENT_LAST_ACTIVITY_AT"))
       :exit-code (ogent-cabinet-conversations--number-property
                   (org-entry-get nil "OGENT_EXIT_CODE"))
       :job-id (ogent-cabinet--blank-to-nil
                (org-entry-get nil "OGENT_JOB_ID"))
       :job-name (ogent-cabinet--blank-to-nil
                  (org-entry-get nil "OGENT_JOB_NAME"))
       :scheduled-at (ogent-cabinet--blank-to-nil
                      (org-entry-get nil "OGENT_SCHEDULED_AT"))
       :scheduled-key (ogent-cabinet--blank-to-nil
                       (org-entry-get nil "OGENT_SCHEDULED_KEY"))
       :provider (ogent-cabinet--blank-to-nil
                  (org-entry-get nil "OGENT_PROVIDER"))
       :adapter (ogent-cabinet--blank-to-nil
                 (org-entry-get nil "OGENT_ADAPTER"))
       :model (ogent-cabinet--blank-to-nil
               (org-entry-get nil "OGENT_MODEL"))
       :effort (ogent-cabinet--blank-to-nil
                (org-entry-get nil "OGENT_EFFORT"))
       :runtime-mode (ogent-cabinet--blank-to-nil
                      (org-entry-get nil "OGENT_RUNTIME_MODE"))
       :context-window (ogent-cabinet-conversations--number-property
                        (org-entry-get nil "OGENT_CONTEXT_WINDOW"))
       :tokens-input (ogent-cabinet-conversations--number-property
                      (org-entry-get nil "OGENT_TOKENS_INPUT"))
       :tokens-output (ogent-cabinet-conversations--number-property
                       (org-entry-get nil "OGENT_TOKENS_OUTPUT"))
       :tokens-cache (ogent-cabinet-conversations--number-property
                      (org-entry-get nil "OGENT_TOKENS_CACHE"))
       :tokens-total (ogent-cabinet-conversations--number-property
                      (org-entry-get nil "OGENT_TOKENS_TOTAL"))
       :mentioned-paths (ogent-cabinet-conversations--list-property
                         (org-entry-get nil "OGENT_MENTIONS"))
       :skills (ogent-cabinet-conversations--list-property
                (org-entry-get nil "OGENT_SKILLS"))
       :attachment-paths (ogent-cabinet-conversations--list-property
                          (org-entry-get nil "OGENT_ATTACHMENTS"))
       :artifact-paths (ogent-cabinet-conversations--list-property
                        (org-entry-get nil "OGENT_ARTIFACTS"))
       :duration (ogent-cabinet--blank-to-nil
                  (org-entry-get nil "OGENT_DURATION"))
       :summary (ogent-cabinet--blank-to-nil
                 (org-entry-get nil "OGENT_SUMMARY"))
       :context-summary (ogent-cabinet--blank-to-nil
                         (org-entry-get nil "OGENT_CONTEXT_SUMMARY"))
       :awaiting-input (ogent-cabinet--truth-value
                        (org-entry-get nil "OGENT_AWAITING_INPUT"))
       :archived (or (equal (ogent-cabinet-conversations--status
                             (org-entry-get nil "OGENT_STATUS"))
                            "archived")
                     (ogent-cabinet--truth-value
                      (org-entry-get nil "OGENT_ARCHIVED")))
       :title-pinned (ogent-cabinet--truth-value
                      (org-entry-get nil "OGENT_TITLE_PINNED"))
       :board-order (ogent-cabinet-conversations--number-property
                     (org-entry-get nil "OGENT_BOARD_ORDER"))
       :muted (ogent-cabinet--truth-value
               (org-entry-get nil "OGENT_MUTED"))
       :error-kind (ogent-cabinet--blank-to-nil
                    (org-entry-get nil "OGENT_ERROR_KIND"))
       :error-hint (ogent-cabinet--blank-to-nil
                    (org-entry-get nil "OGENT_ERROR_HINT"))
       :error-retry-after (ogent-cabinet-conversations--number-property
                           (org-entry-get nil "OGENT_ERROR_RETRY_AFTER"))
       :last-resume-result (ogent-cabinet--blank-to-nil
                            (org-entry-get nil "OGENT_LAST_RESUME_RESULT"))
       :parent-task (ogent-cabinet--blank-to-nil
                     (org-entry-get nil "OGENT_PARENT_TASK"))
       :triggering-agent (ogent-cabinet--blank-to-nil
                          (org-entry-get nil "OGENT_TRIGGERING_AGENT"))
       :spawn-depth (ogent-cabinet-conversations--number-property
                     (org-entry-get nil "OGENT_SPAWN_DEPTH"))
       :actions-proposed-at (ogent-cabinet--blank-to-nil
                             (org-entry-get nil "OGENT_ACTIONS_PROPOSED_AT"))
       :path file
       :body (ogent-cabinet--heading-body)))))

(defun ogent-cabinet-conversation-read (directory conversation-id)
  "Read CONVERSATION-ID from DIRECTORY and return a plist."
  (ogent-cabinet-conversations--read-index-file
   (ogent-cabinet-conversation-file directory conversation-id)
   conversation-id))

(cl-defun ogent-cabinet-conversation-list
    (directory &key agent status trigger)
  "Return canonical conversations under DIRECTORY.
Optional filters narrow by AGENT, STATUS, and TRIGGER."
  (let ((conversations-dir (ogent-cabinet-conversations-directory directory))
        conversations)
    (when (file-directory-p conversations-dir)
      (dolist (entry (directory-files conversations-dir nil
                                      directory-files-no-dot-files-regexp))
        (let ((file (ogent-cabinet-conversation-file directory entry)))
          (when (file-regular-p file)
            (let ((conversation
                   (ogent-cabinet-conversations--read-index-file file entry)))
              (when (and (or (null agent)
                             (equal (plist-get conversation :agent) agent))
                         (or (null status)
                             (equal (plist-get conversation :status) status))
                         (or (null trigger)
                             (equal (plist-get conversation :trigger) trigger)))
                (push conversation conversations)))))))
    (seq-sort
     (lambda (left right)
       (string> (or (plist-get left :last-activity)
                    (plist-get left :completed)
                    (plist-get left :started)
                    "")
                (or (plist-get right :last-activity)
                    (plist-get right :completed)
                    (plist-get right :started)
                    "")))
     conversations)))

(defun ogent-cabinet-conversations--session-status (status)
  "Return legacy display status for canonical STATUS."
  (pcase (ogent-cabinet-conversations--status status)
    ("done" "DONE")
    ("failed" "FAILED")
    ("running" "RUNNING")
    ("awaiting-input" "AWAITING-INPUT")
    ("archived" "ARCHIVED")
    ("cancelled" "CANCELLED")
    (_ "TODO")))

(defun ogent-cabinet-conversations--as-session (conversation)
  "Return CONVERSATION as a session-shaped plist for legacy UI surfaces."
  (list :id (plist-get conversation :id)
        :conversation-id (plist-get conversation :id)
        :record-kind 'conversation
        :name (plist-get conversation :title)
        :agent (plist-get conversation :agent)
        :provider (plist-get conversation :provider)
        :model (plist-get conversation :model)
        :job-id (plist-get conversation :job-id)
        :exit-status (plist-get conversation :exit-code)
        :status (ogent-cabinet-conversations--session-status
                 (plist-get conversation :status))
        :workspace nil
        :duration (plist-get conversation :duration)
        :finished (or (plist-get conversation :completed)
                      (plist-get conversation :last-activity)
                      (plist-get conversation :started))
        :tags nil
        :app-paths (plist-get conversation :artifact-paths)
        :archived (plist-get conversation :archived)
        :muted (plist-get conversation :muted)
        :board-order (plist-get conversation :board-order)
        :last-activity (plist-get conversation :last-activity)
        :scheduled-at (plist-get conversation :scheduled-at)
        :scheduled-key (plist-get conversation :scheduled-key)
        :body (plist-get conversation :body)
        :path (plist-get conversation :path)))

(cl-defun ogent-cabinet-conversation-list-sessions
    (directory &key agent status trigger)
  "Return canonical conversations as session-shaped plists under DIRECTORY."
  (mapcar
   #'ogent-cabinet-conversations--as-session
   (ogent-cabinet-conversation-list
    directory
    :agent agent
    :status status
    :trigger trigger)))

(defun ogent-cabinet-conversations--update-index-properties
    (directory conversation-id properties)
  "Update CONVERSATION-ID PROPERTIES under DIRECTORY."
  (let ((file (ogent-cabinet-conversation-file directory conversation-id)))
    (when (file-exists-p file)
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (org-mode)
          (goto-char (point-min))
          (unless (re-search-forward org-heading-regexp nil t)
            (user-error "No Org heading found in %s" file))
          (org-back-to-heading t)
          (dolist (property properties)
            (org-entry-put nil
                           (car property)
                           (ogent-cabinet--property-value (cdr property))))
          (save-buffer))))))

(defun ogent-cabinet-conversation-update-properties
    (directory conversation-id properties)
  "Update CONVERSATION-ID PROPERTIES under DIRECTORY.
PROPERTIES is an alist of Org property names to values."
  (ogent-cabinet-conversations--update-index-properties
   directory conversation-id properties))

(defun ogent-cabinet-conversations--next-turn-number
    (directory conversation-id role)
  "Return the next turn number for CONVERSATION-ID and ROLE."
  (let* ((turns (ogent-cabinet-conversation-read-turns
                 directory conversation-id))
         (max-turn (if turns
                       (apply #'max (mapcar (lambda (turn)
                                              (plist-get turn :turn))
                                            turns))
                     0)))
    (if (and (equal role "agent")
             (seq-find (lambda (turn)
                         (and (= (plist-get turn :turn) max-turn)
                              (equal (plist-get turn :role) "user")))
                       turns)
             (not (seq-find (lambda (turn)
                              (and (= (plist-get turn :turn) max-turn)
                                   (equal (plist-get turn :role) "agent")))
                            turns)))
        max-turn
      (1+ max-turn))))

(cl-defun ogent-cabinet-conversation-append-turn
    (directory conversation-id role content
               &key turn id ts session-id tokens awaiting-input pending
               exit-code error mentioned-paths attachment-paths artifacts skills)
  "Append a ROLE turn with CONTENT to CONVERSATION-ID under DIRECTORY."
  (let* ((role (downcase role))
         (turn (or turn
                   (ogent-cabinet-conversations--next-turn-number
                    directory conversation-id role)))
         (id (or id (format "%s-%03d-%s" conversation-id turn role)))
         (ts (or ts (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
         (file (ogent-cabinet-conversations--turn-file
                directory conversation-id turn role)))
    (ogent-cabinet--write-file
     file
     (concat
      (format "#+title: %s turn %d\n\n" (capitalize role) turn)
      (format "* %s turn %d\n" (capitalize role) turn)
      (ogent-cabinet--format-properties
       `(("OGENT_TURN" . t)
         ("OGENT_CONVERSATION_ID" . ,conversation-id)
         ("OGENT_TURN_ID" . ,id)
         ("OGENT_TURN_NUMBER" . ,turn)
         ("OGENT_ROLE" . ,role)
         ("OGENT_TS" . ,ts)
         ("OGENT_SESSION_ID" . ,session-id)
         ("OGENT_TOKENS_INPUT" . ,(plist-get tokens :input))
         ("OGENT_TOKENS_OUTPUT" . ,(plist-get tokens :output))
         ("OGENT_TOKENS_CACHE" . ,(plist-get tokens :cache))
         ("OGENT_AWAITING_INPUT" . ,awaiting-input)
         ("OGENT_PENDING" . ,pending)
         ("OGENT_EXIT_CODE" . ,exit-code)
         ("OGENT_ERROR" . ,error)
         ("OGENT_MENTIONED_PATHS" . ,mentioned-paths)
         ("OGENT_ATTACHMENTS" . ,attachment-paths)
         ("OGENT_SKILLS" . ,skills)
         ("OGENT_ARTIFACTS" . ,artifacts)))
      "\n"
      (string-trim-right (or content ""))
      "\n"))
    (ogent-cabinet-conversations--update-index-properties
     directory conversation-id
     `(("OGENT_LAST_ACTIVITY_AT" . ,ts)
       ("OGENT_AWAITING_INPUT" . ,awaiting-input)))
    file))

(defun ogent-cabinet-conversations--read-turn-file (file fallback)
  "Read turn FILE using FALLBACK metadata."
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let ((fallback-turn (plist-get fallback :turn))
          (fallback-role (plist-get fallback :role)))
      (ogent-cabinet--first-heading-title)
      (list
       :id (or (ogent-cabinet--blank-to-nil
                (org-entry-get nil "OGENT_TURN_ID"))
               (format "%s-%s" fallback-turn fallback-role))
       :conversation-id (ogent-cabinet--blank-to-nil
                         (org-entry-get nil "OGENT_CONVERSATION_ID"))
       :turn (or (ogent-cabinet-conversations--number-property
                  (org-entry-get nil "OGENT_TURN_NUMBER"))
                 fallback-turn)
       :role (or (ogent-cabinet--blank-to-nil
                  (org-entry-get nil "OGENT_ROLE"))
                 fallback-role)
       :ts (ogent-cabinet--blank-to-nil
            (org-entry-get nil "OGENT_TS"))
       :session-id (ogent-cabinet--blank-to-nil
                    (org-entry-get nil "OGENT_SESSION_ID"))
       :tokens (let ((input (ogent-cabinet-conversations--number-property
                             (org-entry-get nil "OGENT_TOKENS_INPUT")))
                     (output (ogent-cabinet-conversations--number-property
                              (org-entry-get nil "OGENT_TOKENS_OUTPUT")))
                     (cache (ogent-cabinet-conversations--number-property
                             (org-entry-get nil "OGENT_TOKENS_CACHE"))))
                 (when (or input output cache)
                   (list :input input :output output :cache cache)))
       :awaiting-input (ogent-cabinet--truth-value
                        (org-entry-get nil "OGENT_AWAITING_INPUT"))
       :pending (ogent-cabinet--truth-value
                 (org-entry-get nil "OGENT_PENDING"))
       :exit-code (ogent-cabinet-conversations--number-property
                   (org-entry-get nil "OGENT_EXIT_CODE"))
       :error (ogent-cabinet--blank-to-nil
               (org-entry-get nil "OGENT_ERROR"))
       :mentioned-paths (ogent-cabinet-conversations--list-property
                         (org-entry-get nil "OGENT_MENTIONED_PATHS"))
       :attachment-paths (ogent-cabinet-conversations--list-property
                          (org-entry-get nil "OGENT_ATTACHMENTS"))
       :skills (ogent-cabinet-conversations--list-property
                (org-entry-get nil "OGENT_SKILLS"))
       :artifacts (ogent-cabinet-conversations--list-property
                   (org-entry-get nil "OGENT_ARTIFACTS"))
       :content (ogent-cabinet--heading-body)
       :path file))))

(defun ogent-cabinet-conversation-read-turns (directory conversation-id)
  "Return turns for CONVERSATION-ID under DIRECTORY."
  (let ((turns-dir (ogent-cabinet-conversation-turns-directory
                    directory conversation-id))
        turns)
    (when (file-directory-p turns-dir)
      (dolist (file (directory-files turns-dir t "\\.org\\'"))
        (when-let ((fallback (ogent-cabinet-conversations--parse-turn-file-name
                              (file-name-nondirectory file))))
          (push (ogent-cabinet-conversations--read-turn-file file fallback)
                turns))))
    (seq-sort
     (lambda (left right)
       (let ((left-turn (plist-get left :turn))
             (right-turn (plist-get right :turn)))
         (if (= left-turn right-turn)
             (< (ogent-cabinet-conversations--role-sort-value
                 (plist-get left :role))
                (ogent-cabinet-conversations--role-sort-value
                 (plist-get right :role)))
           (< left-turn right-turn))))
     turns)))

(cl-defun ogent-cabinet-conversation-append-event
    (directory conversation-id type &key seq ts payload)
  "Append event TYPE to CONVERSATION-ID under DIRECTORY."
  (let* ((events-file (ogent-cabinet-conversation-events-file
                       directory conversation-id))
         (events (ogent-cabinet-conversation-read-events
                  directory conversation-id))
         (seq (or seq
                  (1+ (if events
                          (apply #'max (mapcar (lambda (event)
                                                 (or (plist-get event :seq) 0))
                                               events))
                        0))))
         (ts (or ts (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))))
    (unless (file-exists-p events-file)
      (ogent-cabinet--write-file
       events-file
       "#+title: Events\n\n* Events\n"))
    (with-temp-buffer
      (insert-file-contents events-file)
      (goto-char (point-max))
      (unless (bolp)
        (insert "\n"))
      (insert
       (format "** %06d %s\n" seq type)
       (ogent-cabinet--format-properties
        `(("OGENT_EVENT" . t)
          ("OGENT_EVENT_SEQ" . ,seq)
          ("OGENT_EVENT_TYPE" . ,type)
          ("OGENT_EVENT_TIME" . ,ts)
          ("OGENT_EVENT_TASK" . ,conversation-id)))
       "\n")
      (when payload
        (insert (string-trim-right payload) "\n"))
      (write-region (point-min) (point-max) events-file nil 'silent))
    events-file))

(defun ogent-cabinet-conversation-read-events (directory conversation-id)
  "Return event records for CONVERSATION-ID under DIRECTORY."
  (let ((events-file (ogent-cabinet-conversation-events-file
                      directory conversation-id))
        events)
    (when (file-readable-p events-file)
      (with-temp-buffer
        (insert-file-contents events-file)
        (org-mode)
        (goto-char (point-min))
        (while (re-search-forward org-heading-regexp nil t)
          (org-back-to-heading t)
          (when (org-entry-get nil "OGENT_EVENT")
            (push
             (list
              :seq (ogent-cabinet-conversations--number-property
                    (org-entry-get nil "OGENT_EVENT_SEQ"))
              :type (ogent-cabinet--blank-to-nil
                     (org-entry-get nil "OGENT_EVENT_TYPE"))
              :ts (ogent-cabinet--blank-to-nil
                   (org-entry-get nil "OGENT_EVENT_TIME"))
              :task (ogent-cabinet--blank-to-nil
                     (org-entry-get nil "OGENT_EVENT_TASK"))
              :payload (ogent-cabinet--heading-body)
              :path events-file)
             events))
          (outline-next-heading))))
    (seq-sort-by (lambda (event)
                   (or (plist-get event :seq) 0))
                 #'<
                 events)))

(defun ogent-cabinet-conversations--cabinet-block-body (text)
  "Return the final Cabinet metadata block from TEXT."
  (let ((case-fold-search t)
        found)
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      (while (re-search-forward
              "\\(?:^```cabinet[ \t]*\n\\|^#\\+begin_cabinet[ \t]*\n\\)"
              nil t)
        (let ((begin (point)))
          (when (re-search-forward
                 "\\(?:^```[ \t]*$\\|^#\\+end_cabinet[ \t]*$\\)"
                 nil t)
            (setq found (string-trim
                         (buffer-substring-no-properties
                          begin
                          (match-beginning 0))))))))
    found))

(defun ogent-cabinet-conversations--artifact-value-valid-p (value)
  "Return non-nil when VALUE names a real artifact path."
  (let ((trimmed (string-trim (or value ""))))
    (and (not (string-empty-p trimmed))
         (not (member (downcase trimmed)
                      '("none" "nil" "n/a" "na")))
         (not (string-match-p "relative/path/to" trimmed)))))

(defun ogent-cabinet-conversations--ask-user (text)
  "Return the first ask-user marker body in TEXT."
  (when (string-match
         "<ask_user>\\(?:.\\|\n\\)*?</ask_user>"
         (or text ""))
    (let ((match (match-string 0 text)))
      (string-trim
       (replace-regexp-in-string
        "\\`<ask_user>\\|</ask_user>\\'" "" match)))))

(defun ogent-cabinet-conversation-parse-output (text)
  "Parse Cabinet metadata and ask-user markers from TEXT."
  (let ((ask-user (ogent-cabinet-conversations--ask-user text))
        (block (ogent-cabinet-conversations--cabinet-block-body text))
        summary
        context-summary
        artifacts)
    (when block
      (dolist (line (split-string block "\n" t))
        (when (string-match "\\`\\([[:upper:]_]+\\):[ \t]*\\(.*\\)\\'" line)
          (let ((key (match-string 1 line))
                (value (string-trim (match-string 2 line))))
            (pcase key
              ("SUMMARY" (setq summary value))
              ("CONTEXT" (setq context-summary value))
              ("ARTIFACT"
               (when (ogent-cabinet-conversations--artifact-value-valid-p
                      value)
                 (push value artifacts))))))))
    (list :summary summary
          :context-summary context-summary
          :artifact-paths (nreverse artifacts)
          :awaiting-input (not (null ask-user))
          :ask-user ask-user)))

(defun ogent-cabinet-conversation-detail (directory conversation-id)
  "Return CONVERSATION-ID with turns and events."
  (let ((conversation (ogent-cabinet-conversation-read
                       directory conversation-id)))
    (append conversation
            (list :turns (ogent-cabinet-conversation-read-turns
                          directory conversation-id)
                  :events (ogent-cabinet-conversation-read-events
                           directory conversation-id)))))

(defun ogent-cabinet-conversations--turn-label (turn)
  "Return a compact label for TURN."
  (format "%03d %s %s"
          (or (plist-get turn :turn) 0)
          (upcase (or (plist-get turn :role) "turn"))
          (or (plist-get turn :ts) "")))

(defun ogent-cabinet-conversation-replay-prompt
    (directory conversation-id instruction)
  "Return a replay prompt for continuing CONVERSATION-ID with INSTRUCTION."
  (let* ((detail (ogent-cabinet-conversation-detail directory conversation-id))
         (turns (plist-get detail :turns)))
    (string-join
     (delq
      nil
      (list
       "Continue this existing Org Cabinet conversation."
       (format "Conversation: %s"
               (or (plist-get detail :title) conversation-id))
       (format "Status: %s" (or (plist-get detail :status) "idle"))
       (when-let ((summary (ogent-cabinet--blank-to-nil
                            (plist-get detail :context-summary))))
         (format "Context summary:\n%s" summary))
       (when turns
         (concat
          "Prior turns:\n"
          (string-join
           (mapcar
            (lambda (turn)
              (format "[%s]\n%s"
                      (ogent-cabinet-conversations--turn-label turn)
                      (string-trim (or (plist-get turn :content) ""))))
            turns)
           "\n\n")))
       (format "New user instruction:\n%s" instruction)))
     "\n\n")))

(defun ogent-cabinet-conversations--compact-summary (detail)
  "Return a deterministic compact summary for DETAIL."
  (let* ((turns (last (plist-get detail :turns) 6))
         (turn-summary
          (string-join
           (mapcar
            (lambda (turn)
              (let ((content (string-trim
                              (or (plist-get turn :content) ""))))
                (format "- %s: %s"
                        (ogent-cabinet-conversations--turn-label turn)
                        (truncate-string-to-width content 240 nil nil t))))
            turns)
           "\n")))
    (string-join
     (delq
      nil
      (list
       (format "Conversation %s is %s."
               (or (plist-get detail :title) (plist-get detail :id))
               (or (plist-get detail :status) "idle"))
       (when-let ((summary (ogent-cabinet--blank-to-nil
                            (plist-get detail :summary))))
         (format "Latest summary: %s" summary))
       (when (ogent-cabinet--blank-to-nil turn-summary)
         (format "Recent turns:\n%s" turn-summary))))
     "\n\n")))

(defun ogent-cabinet-conversation-compact-record
    (directory conversation-id &optional summary)
  "Store a compact digest for CONVERSATION-ID under DIRECTORY."
  (let* ((detail (ogent-cabinet-conversation-detail directory conversation-id))
         (digest (or (ogent-cabinet--blank-to-nil summary)
                     (ogent-cabinet-conversations--compact-summary detail)))
         (ts (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
    (ogent-cabinet-conversation-append-turn
     directory conversation-id "system"
     (concat "Context digest:\n\n" digest)
     :ts ts
     :awaiting-input (plist-get detail :awaiting-input))
    (ogent-cabinet-conversation-update-properties
     directory conversation-id
     `(("OGENT_CONTEXT_SUMMARY" . ,digest)
       ("OGENT_LAST_ACTIVITY_AT" . ,ts)))
    (ogent-cabinet-conversation-append-event
     directory conversation-id "conversation.compacted"
     :ts ts
     :payload "context digest refreshed")
    digest))

(defun ogent-cabinet-conversation-migrate-session
    (directory session-file &optional agent-slug)
  "Migrate legacy SESSION-FILE under DIRECTORY into canonical conversations."
  (let* ((detail (ogent-cabinet-session-detail session-file agent-slug))
         (id (plist-get detail :id))
         (finished (plist-get detail :finished))
         (status (ogent-cabinet-conversations--legacy-status
                  (plist-get detail :status)))
         (file (ogent-cabinet-conversation-create
                directory
                (list
                 :id id
                 :agent (plist-get detail :agent)
                 :title (plist-get detail :name)
                 :trigger (if (plist-get detail :job-id) "job" "manual")
                 :status status
                 :started finished
                 :completed finished
                 :last-activity finished
                 :provider (plist-get detail :provider)
                 :model (plist-get detail :model)
                 :job-id (plist-get detail :job-id)
                 :exit-code (plist-get detail :exit-status)
                 :artifact-paths (plist-get detail :app-paths)))))
    (when-let ((prompt (ogent-cabinet--blank-to-nil
                        (plist-get detail :prompt))))
      (ogent-cabinet-conversation-append-turn
       directory id "user" prompt
       :ts finished))
    (when-let ((output (ogent-cabinet--blank-to-nil
                        (plist-get detail :output))))
      (ogent-cabinet-conversation-append-turn
       directory id "agent" output
       :ts finished
       :exit-code (plist-get detail :exit-status)
       :error (plist-get detail :error)
       :artifacts (plist-get detail :app-paths)))
    (ogent-cabinet-conversation-append-event
     directory id "legacy.migrated"
     :ts (or finished (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
     :payload (file-relative-name session-file directory))
    file))

(provide 'ogent-cabinet-conversations)

;;; ogent-cabinet-conversations.el ends here
