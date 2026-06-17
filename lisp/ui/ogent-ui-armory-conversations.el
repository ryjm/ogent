;;; ogent-ui-armory-conversations.el --- Armory conversation list and reader -*- lexical-binding: t; -*-

;;; Commentary:
;; Conversation list and the single-conversation reader buffer.

;;; Code:

(require 'ogent-ui-armory-core)

(declare-function magit-current-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-insert-section--create "ext:magit-section")
(declare-function magit-insert-section--finish "ext:magit-section")
(declare-function magit-section-backward-sibling "ext:magit-section")
(declare-function magit-section-cycle-global "ext:magit-section")
(declare-function magit-section-forward-sibling "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-section-up "ext:magit-section")
(defvar magit-section-mode-map)
(defvar magit-section-visibility-indicator)
(defvar magit-insert-section--current)
(defvar magit-insert-section--oldroot)
(defvar magit-insert-section--parent)
(defvar magit-root-section)

(declare-function ogent-armory-search "ogent-ui-armory-search")

(defvar ogent-armory-conversations-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-armory-conversations-open))
    (define-key map "R" #'ogent-armory-conversations-retry)
    (define-key map (kbd "C-c r") #'ogent-armory-conversations-retry)
    (define-key map "A" #'ogent-armory-conversations-archive)
    (define-key map (kbd "C-c a") #'ogent-armory-conversations-archive)
    (define-key map "U" #'ogent-armory-conversations-unarchive)
    (define-key map (kbd "C-c u") #'ogent-armory-conversations-unarchive)
    (define-key map "v" #'ogent-armory-conversations-visit-source)
    (define-key map (kbd "C-c v") #'ogent-armory-conversations-visit-source)
    (define-key map "s" #'ogent-armory-conversations-search)
    (define-key map (kbd "C-c s") #'ogent-armory-conversations-search)
    (define-key map "f" #'ogent-armory-conversations-filter)
    (define-key map (kbd "C-c f") #'ogent-armory-conversations-filter)
    (define-key map "g" #'ogent-armory-conversations-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-conversations-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-conversations-mode'.")

(define-derived-mode ogent-armory-conversations-mode tabulated-list-mode
  "Armory-Conversations"
  "Major mode for Armory conversation lists."
  :group 'ogent-ui-armory
  (setq-local tabulated-list-format
              [("Status" 10 t)
               ("Agent" 14 t)
               ("Job" 18 t)
               ("Conversation" 28 t)
               ("Provider" 10 t)
               ("Model" 12 t)
               ("Duration" 10 t)
               ("Finished" 22 t)
               ("Archived" 8 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key '("Finished" . t))
  (setq-local revert-buffer-function #'ogent-armory-conversations-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-conversations--matches-p (session)
  "Return non-nil when SESSION matches current filters."
  (let ((filters ogent-armory-conversations--filters))
    (and (or (null (plist-get filters :agent))
             (equal (plist-get session :agent) (plist-get filters :agent)))
         (or (null (plist-get filters :job-id))
             (equal (plist-get session :job-id) (plist-get filters :job-id)))
         (or (null (plist-get filters :status))
             (equal (plist-get session :status) (plist-get filters :status)))
         (or (null (plist-get filters :provider))
             (equal (plist-get session :provider) (plist-get filters :provider)))
         (or (null (plist-get filters :model))
             (equal (plist-get session :model) (plist-get filters :model)))
         (or (null (plist-get filters :tag))
             (member (plist-get filters :tag) (plist-get session :tags)))
         (or (null (plist-get filters :archived))
             (eq (plist-get session :archived)
                 (ogent-armory--truth-value (plist-get filters :archived)))))))

(defun ogent-armory-conversations--entry (session)
  "Return tabulated entry for SESSION."
  (list
   (append (list :type 'session) session)
   (vector
    (or (plist-get session :status) "")
    (or (plist-get session :agent) "")
    (or (plist-get session :job-id) "")
    (or (plist-get session :name) (plist-get session :id))
    (or (plist-get session :provider) "")
    (or (plist-get session :model) "")
    (or (plist-get session :duration) "")
    (or (plist-get session :finished) "")
    (if (plist-get session :archived) "yes" "no"))))

(defun ogent-armory-conversations--entries ()
  "Return conversation entries for the current buffer."
  (let* ((sessions (ogent-armory-ui--all-sessions
                    ogent-armory-conversations--root))
         (matches (seq-filter #'ogent-armory-conversations--matches-p
                              sessions)))
    (if matches
        (mapcar #'ogent-armory-conversations--entry matches)
      (list
       (list nil
             (vector "" "" ""
                     (if sessions
                         "No conversations match filters"
                       "No conversations yet")
                     "" "" "" "" ""))))))

(defun ogent-armory-conversations (&optional directory filters)
  "Open Armory conversations for DIRECTORY with optional FILTERS."
  (interactive
   (list (or (ogent-armory-find-root)
             (read-directory-name "Armory root: "))
         nil))
  (let* ((root (ogent-armory-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-conversations-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-armory-conversations-mode)
      (setq ogent-armory-conversations--root root)
      (setq ogent-armory-conversations--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-armory-conversations--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-conversations-refresh (&rest _)
  "Refresh the Armory conversations buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-armory-conversations--item ()
  "Return the conversation at point."
  (or (tabulated-list-get-id)
      (user-error "No Armory conversation at point")))

(defun ogent-armory-conversations-open ()
  "Open the conversation at point."
  (interactive)
  (ogent-armory-conversation
   ogent-armory-conversations--root
   (plist-get (ogent-armory-conversations--item) :path)))

(defun ogent-armory-conversations-visit-source ()
  "Visit the Org source file for the conversation at point."
  (interactive)
  (ogent-armory-ui--visit-path
   (plist-get (ogent-armory-conversations--item) :path)))

(defun ogent-armory-conversations-retry ()
  "Retry the conversation at point when it links to a job."
  (interactive)
  (let ((item (ogent-armory-conversations--item)))
    (if-let ((job-id (plist-get item :job-id)))
        (ogent-armory-run-job ogent-armory-conversations--root
                               (plist-get item :agent)
                               job-id)
      (ogent-armory-run-agent ogent-armory-conversations--root
                               (plist-get item :agent)
                               (read-string "Instruction: ")))))

(defun ogent-armory-conversations-archive ()
  "Archive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-armory-conversations--item) :path)))
    (ogent-armory-ui--conversation-update-properties
     ogent-armory-conversations--root path
     '(("OGENT_ARCHIVED" . "t")
       ("OGENT_STATUS" . "archived"))
     "conversation.archived"))
  (ogent-armory-conversations-refresh))

(defun ogent-armory-conversations-unarchive ()
  "Unarchive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-armory-conversations--item) :path)))
    (ogent-armory-ui--conversation-update-properties
     ogent-armory-conversations--root path
     '(("OGENT_ARCHIVED" . "nil")
       ("OGENT_STATUS" . "done"))
     "conversation.unarchived"))
  (ogent-armory-conversations-refresh))

(defun ogent-armory-conversations-filter ()
  "Set simple conversation filters."
  (interactive)
  (setq ogent-armory-conversations--filters
        (list :agent (ogent-armory--blank-to-nil
                      (ogent-armory-ui--read-optional-choice
                       "Agent filter: "
                       (ogent-armory-ui--agent-slugs
                        ogent-armory-conversations--root)))
              :status (ogent-armory--blank-to-nil
                       (ogent-armory-ui--read-optional-choice
                        "Status filter: "
                        (ogent-armory-ui--conversation-status-candidates
                         ogent-armory-conversations--root)))
              :tag (ogent-armory--blank-to-nil
                    (ogent-armory-ui--read-optional-choice
                     "Tag filter: "
                     (ogent-armory-ui--conversation-tag-candidates
                      ogent-armory-conversations--root)))))
  (ogent-armory-conversations-refresh))

(defun ogent-armory-conversations-search ()
  "Search within Armory conversations."
  (interactive)
  (ogent-armory-search ogent-armory-conversations--root
                        (read-string "Search conversations: ")
                        (list :kind 'session)))

(defvar ogent-armory-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>" "v"))
      (define-key map (kbd key) #'ogent-armory-conversation-visit-source))
    (define-key map (kbd "C-c v") #'ogent-armory-conversation-visit-source)
    (define-key map "c" #'ogent-armory-conversation-continue)
    (define-key map (kbd "C-c c") #'ogent-armory-conversation-continue)
    (define-key map "k" #'ogent-armory-conversation-stop)
    (define-key map (kbd "C-c k") #'ogent-armory-conversation-stop)
    (define-key map "R" #'ogent-armory-conversation-retry)
    (define-key map (kbd "C-c r") #'ogent-armory-conversation-retry)
    (define-key map "d" #'ogent-armory-conversation-mark-done)
    (define-key map (kbd "C-c d") #'ogent-armory-conversation-mark-done)
    (define-key map "A" #'ogent-armory-conversation-archive)
    (define-key map (kbd "C-c a") #'ogent-armory-conversation-archive)
    (define-key map "U" #'ogent-armory-conversation-unarchive)
    (define-key map (kbd "C-c u") #'ogent-armory-conversation-unarchive)
    (define-key map "m" #'ogent-armory-conversation-mute)
    (define-key map (kbd "C-c m") #'ogent-armory-conversation-mute)
    (define-key map "M" #'ogent-armory-conversation-unmute)
    (define-key map (kbd "C-c M") #'ogent-armory-conversation-unmute)
    (define-key map "C" #'ogent-armory-conversation-compact)
    (define-key map (kbd "C-c C") #'ogent-armory-conversation-compact)
    (define-key map "D" #'ogent-armory-conversation-delete)
    (define-key map (kbd "C-c D") #'ogent-armory-conversation-delete)
    (define-key map "y" #'ogent-armory-conversation-copy-link)
    (define-key map (kbd "C-c y") #'ogent-armory-conversation-copy-link)
    (define-key map "o" #'ogent-armory-conversation-open-artifacts)
    (define-key map (kbd "C-c o") #'ogent-armory-conversation-open-artifacts)
    (define-key map "l" #'ogent-armory-conversation-open-logs)
    (define-key map (kbd "C-c l") #'ogent-armory-conversation-open-logs)
    (define-key map "g" #'ogent-armory-conversation-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-conversation-refresh)
    (define-key map (kbd "TAB") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-armory-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-armory-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-armory-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-armory-ui-previous-section)
    (define-key map (kbd "^") #'ogent-armory-ui-up-section)
    (define-key map (kbd "C-c U") #'ogent-armory-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-conversation-mode'.")

(ogent-armory-ui--define-section-mode ogent-armory-conversation-mode
    "Armory-Conversation"
    "Major mode for a single Armory conversation."
  (setq-local revert-buffer-function #'ogent-armory-conversation-refresh)
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only t)
  (ogent-armory-ui--configure-section-buffer)
  (setq header-line-format
        "RET source  C-c g refresh  C-c r retry  C-c c continue  C-c o artifacts  C-c l logs  TAB fold"))

(defun ogent-armory-conversation (&optional directory file)
  "Open Armory conversation FILE under DIRECTORY."
  (interactive
   (let* ((root (ogent-armory-ui--root
                 (or (ogent-armory-find-root)
                     (read-directory-name "Armory root: "))))
          (session (completing-read
                    "Conversation: "
                    (mapcar (lambda (item)
                              (plist-get item :path))
                            (ogent-armory-ui--all-sessions root))
                    nil t)))
     (list root session)))
  (let* ((root (ogent-armory-ui--root directory))
         (raw-path (or file (plist-get (ogent-armory-conversations--item) :path)))
         (path (if (and raw-path (file-exists-p raw-path))
                   (file-truename raw-path)
                 raw-path))
         (buffer (get-buffer-create
                  (ogent-armory-ui--buffer-name
                   ogent-armory-conversation-buffer-name-format
                   root
                   (file-name-base path)))))
    (with-current-buffer buffer
      (ogent-armory-conversation-mode)
      (setq ogent-armory-conversation--root root)
      (setq ogent-armory-conversation--file path)
      (setq default-directory (file-name-as-directory root))
      (ogent-armory-conversation-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-conversation-refresh (&rest _)
  "Refresh this conversation detail buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-armory-conversation--insert-buffer)
    (goto-char (point-min))))

(defun ogent-armory-conversation--insert-buffer ()
  "Insert the current conversation detail."
  (ogent-armory-ui--with-root-section (ogent-armory-conversation-root)
    (ogent-armory-conversation--insert-buffer-content)))

(defun ogent-armory-conversation--insert-overview (detail)
  "Insert compact run overview for DETAIL."
  (let ((parts (delq nil
                     (list
                      (plist-get detail :status)
                      (plist-get detail :agent)
                      (plist-get detail :job-id)
                      (plist-get detail :provider)
                      (plist-get detail :model)
                      (plist-get detail :duration)
                      (plist-get detail :finished)))))
    (when parts
      (insert (propertize (string-join parts "  ")
                          'face 'ogent-armory-ui-dim)
              "\n"))))

(defun ogent-armory-conversation--insert-details (detail)
  "Insert detailed metadata for DETAIL."
  (ogent-armory-ui--with-section (ogent-armory-conversation-metadata)
      (ogent-armory-ui--heading-text "Details")
    (ogent-armory-ui--insert-kv "Status" (plist-get detail :status))
    (ogent-armory-ui--insert-kv "Agent" (plist-get detail :agent))
    (ogent-armory-ui--insert-kv "Job" (plist-get detail :job-id))
    (ogent-armory-ui--insert-kv "Trigger" (plist-get detail :trigger))
    (ogent-armory-ui--insert-kv "Provider" (plist-get detail :provider))
    (ogent-armory-ui--insert-kv "Model" (plist-get detail :model))
    (ogent-armory-ui--insert-kv
     "Exit status"
     (when (plist-get detail :exit-status)
       (number-to-string
        (plist-get detail :exit-status))))
    (ogent-armory-ui--insert-kv "Duration" (plist-get detail :duration))
    (ogent-armory-ui--insert-kv "Started" (plist-get detail :started))
    (ogent-armory-ui--insert-kv "Finished" (plist-get detail :finished))
    (ogent-armory-ui--insert-kv "Last activity"
                                 (plist-get detail :last-activity))
    (ogent-armory-ui--insert-kv "Archived"
                                 (if (plist-get detail :archived) "yes" "no"))
    (ogent-armory-ui--insert-kv "Muted"
                                 (if (plist-get detail :muted) "yes" "no"))))

(defun ogent-armory-conversation--insert-turns (turns)
  "Insert each conversation turn.
TURNS is the list of turn plists to insert."
  (ogent-armory-ui--with-section (ogent-armory-conversation-turns)
      (ogent-armory-ui--heading-text "Turns")
    (if turns
        (dolist (turn turns)
          (insert
           (propertize
            (format "  %03d %s %s\n"
                    (or (plist-get turn :turn) 0)
                    (upcase (or (plist-get turn :role) "turn"))
                    (or (plist-get turn :ts) ""))
            'face 'ogent-armory-ui-dim))
          (when-let ((tokens (plist-get turn :tokens)))
            (insert
             (format "  tokens input=%s output=%s cache=%s\n"
                     (or (plist-get tokens :input) "")
                     (or (plist-get tokens :output) "")
                     (or (plist-get tokens :cache) ""))))
          (insert (string-trim-right (or (plist-get turn :content) "")) "\n\n"))
      (insert (propertize "  No turn files recorded\n"
                          'face 'ogent-armory-ui-dim)))))

(defun ogent-armory-conversation--insert-artifacts (root detail)
  "Insert artifacts listed by DETAIL under ROOT."
  (let ((artifacts (ogent-armory-ui--conversation-artifacts detail)))
    (ogent-armory-ui--with-section (ogent-armory-conversation-artifacts)
        (ogent-armory-ui--heading-text "Artifacts")
      (if artifacts
          (dolist (artifact artifacts)
            (let ((path (ogent-armory-ui--artifact-path root artifact)))
              (ogent-armory-ui--insert-item-line
               (list :type 'artifact :path path)
               (format "  %s" artifact))))
        (insert (propertize "  No artifacts recorded\n"
                            'face 'ogent-armory-ui-dim))))))

(defun ogent-armory-conversation--insert-events (events)
  "Insert conversation EVENTS."
  (ogent-armory-ui--with-section (ogent-armory-conversation-events)
      (ogent-armory-ui--heading-text "Events")
    (if events
        (dolist (event events)
          (insert
           (format "  %06d %-24s %s\n"
                   (or (plist-get event :seq) 0)
                   (or (plist-get event :type) "")
                   (or (plist-get event :ts) "")))
          (when-let ((payload (ogent-armory--blank-to-nil
                               (plist-get event :payload))))
            (insert "  " (string-trim payload) "\n")))
      (insert (propertize "  No events recorded\n"
                          'face 'ogent-armory-ui-dim)))))

(defun ogent-armory-conversation--insert-runtime (detail)
  "Insert runtime metadata for DETAIL."
  (ogent-armory-ui--with-section (ogent-armory-conversation-runtime)
      (ogent-armory-ui--heading-text "Runtime")
    (ogent-armory-ui--insert-kv "Adapter" (plist-get detail :adapter))
    (ogent-armory-ui--insert-kv "Runtime" (plist-get detail :runtime-mode))
    (ogent-armory-ui--insert-kv "Effort" (plist-get detail :effort))
    (ogent-armory-ui--insert-kv "Context" (plist-get detail :context-window))
    (ogent-armory-ui--insert-kv "Resume" (plist-get detail :last-resume-result))
    (when (or (plist-get detail :tokens-input)
              (plist-get detail :tokens-output)
              (plist-get detail :tokens-cache)
              (plist-get detail :tokens-total))
      (ogent-armory-ui--insert-kv
       "Tokens"
       (format "input=%s output=%s cache=%s total=%s"
               (or (plist-get detail :tokens-input) "")
               (or (plist-get detail :tokens-output) "")
               (or (plist-get detail :tokens-cache) "")
               (or (plist-get detail :tokens-total) ""))))))

(defun ogent-armory-conversation--runtime-present-p (detail)
  "Return non-nil when DETAIL has runtime fields worth showing."
  (seq-some
   (lambda (key)
     (plist-get detail key))
   '(:adapter
     :runtime-mode
     :effort
     :context-window
     :last-resume-result
     :tokens-input
     :tokens-output
     :tokens-cache
     :tokens-total)))

(defun ogent-armory-conversation--insert-runtime-trace (trace)
  "Insert runtime TRACE as a preview."
  (when (ogent-armory--blank-to-nil trace)
    (let* ((preview (ogent-armory-ui--preview-lines
                     trace
                     ogent-armory-conversation-runtime-trace-preview-lines))
           (hidden (plist-get preview :hidden)))
      (ogent-armory-ui--with-section (ogent-armory-conversation-runtime-trace)
          (ogent-armory-ui--heading-text "Runtime Trace")
        (ogent-armory-ui--insert-readable-text
         (plist-get preview :text)
         "  No runtime trace recorded\n")
        (when (> hidden 0)
          (insert
           (propertize
            (format "  %d more lines. Press l for logs or v for source Org.\n"
                    hidden)
            'face 'ogent-armory-ui-dim)))))))

(defun ogent-armory-conversation--insert-buffer-content ()
  "Insert the current conversation detail sections."
  (let ((detail (ogent-armory-ui--conversation-detail
                 ogent-armory-conversation--root
                 ogent-armory-conversation--file)))
    (insert (propertize (or (plist-get detail :name)
                            (plist-get detail :id))
                        'face 'ogent-armory-ui-heading)
            "\n")
    (ogent-armory-conversation--insert-overview detail)
    (when (plist-get detail :awaiting-input)
      (insert (propertize "Awaiting user input\n"
                          'face 'ogent-armory-ui-warning)))
    (insert "\n")
    (when (or (plist-get detail :summary)
              (plist-get detail :context-summary))
      (ogent-armory-ui--with-section (ogent-armory-conversation-summary)
          (ogent-armory-ui--heading-text "Summary")
        (when-let ((summary (plist-get detail :summary)))
          (insert summary "\n"))
        (when-let ((context (plist-get detail :context-summary)))
          (insert "\nContext\n" context "\n")))
      (insert "\n"))
    (when (plist-get detail :turns)
      (ogent-armory-conversation--insert-turns (plist-get detail :turns))
      (insert "\n"))
    (ogent-armory-ui--with-section (ogent-armory-conversation-output)
        (ogent-armory-ui--heading-text "Output")
      (ogent-armory-ui--insert-readable-text
       (plist-get detail :output)
       "  No output recorded\n"))
    (insert "\n")
    (ogent-armory-conversation--insert-artifacts
     ogent-armory-conversation--root detail)
    (insert "\n")
    (ogent-armory-conversation--insert-details detail)
    (insert "\n")
    (when (ogent-armory-conversation--runtime-present-p detail)
      (ogent-armory-conversation--insert-runtime detail)
      (insert "\n"))
    (ogent-armory-ui--with-section (ogent-armory-conversation-prompt)
        (ogent-armory-ui--heading-text "Prompt")
      (ogent-armory-ui--insert-readable-text
       (plist-get detail :prompt)
       "  No prompt recorded\n"))
    (insert "\n")
    (when (plist-get detail :tools)
      (ogent-armory-ui--with-section (ogent-armory-conversation-tools)
          (ogent-armory-ui--heading-text "Tool Blocks")
        (dolist (tool (plist-get detail :tools))
          (insert (format "  %s\n%s\n" (plist-get tool :header)
                          (plist-get tool :body)))))
      (insert "\n"))
    (when (ogent-armory--blank-to-nil (plist-get detail :error))
      (ogent-armory-ui--with-section (ogent-armory-conversation-error)
          (ogent-armory-ui--heading-text "Error")
        (ogent-armory-ui--insert-readable-text
         (plist-get detail :error)
         "  No error recorded\n"))
      (insert "\n"))
    (ogent-armory-conversation--insert-runtime-trace
     (plist-get detail :runtime-trace))
    (when (ogent-armory--blank-to-nil (plist-get detail :runtime-trace))
      (insert "\n"))
    (ogent-armory-conversation--insert-events (plist-get detail :events))
    (insert "\n")
    (ogent-armory-ui--with-section (ogent-armory-conversation-source)
        (ogent-armory-ui--heading-text "Source Org")
      (ogent-armory-ui--insert-item-line
       (list :type 'file :path (plist-get detail :path))
       (format "  %s" (plist-get detail :path))))))

(defun ogent-armory-conversation-visit-source ()
  "Visit the Org source for this conversation."
  (interactive)
  (ogent-armory-ui--visit-path ogent-armory-conversation--file))

(defun ogent-armory-conversation--detail ()
  "Return detail for the current conversation buffer."
  (ogent-armory-ui--conversation-detail
   ogent-armory-conversation--root
   ogent-armory-conversation--file))

(defun ogent-armory-conversation--canonical-id ()
  "Return current canonical conversation id or nil."
  (when (ogent-armory-ui--canonical-conversation-path-p
         ogent-armory-conversation--file)
    (ogent-armory-ui--canonical-conversation-id
     ogent-armory-conversation--file)))

(defun ogent-armory-conversation-continue (instruction)
  "Continue this conversation with INSTRUCTION."
  (interactive (list (read-string "Continue: ")))
  (let* ((detail (ogent-armory-conversation--detail))
         (agent (plist-get detail :agent))
         (job-id (plist-get detail :job-id))
         (conversation-id (ogent-armory-conversation--canonical-id)))
    (unless agent
      (user-error "Conversation has no agent"))
    (if conversation-id
        (let* ((replay
                (ogent-armory-conversation-replay-prompt
                 ogent-armory-conversation--root conversation-id instruction))
               (keywords
                (append
                 (when job-id (list :job-id job-id))
                 (list :instruction replay
                       :conversation-id conversation-id
                       :conversation-title (plist-get detail :name)
                       :turn-content instruction
                       :trigger "manual"
                       :last-resume-result "replay")))
               (plan (apply #'ogent-armory-runner-plan
                            ogent-armory-conversation--root
                            agent
                            keywords)))
          (when (ogent-armory-runner--confirm plan)
            (ogent-armory-runner-start plan)
            (ogent-armory-conversation-refresh)))
      (ogent-armory-run-agent
       ogent-armory-conversation--root agent instruction))))

(defun ogent-armory-conversation-stop ()
  "Stop this conversation when it has a live process."
  (interactive)
  (let ((conversation-id (ogent-armory-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be stopped"))
    (unless (ogent-armory-runner-stop-conversation
             ogent-armory-conversation--root conversation-id)
      (user-error "No live process for conversation %s" conversation-id)))
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-retry ()
  "Retry this conversation."
  (interactive)
  (let ((detail (ogent-armory-conversation--detail)))
    (if-let ((job-id (plist-get detail :job-id)))
        (ogent-armory-run-job ogent-armory-conversation--root
                               (plist-get detail :agent)
                               job-id)
      (ogent-armory-run-agent ogent-armory-conversation--root
                               (plist-get detail :agent)
                               (read-string "Instruction: ")))))

(defun ogent-armory-conversation-mark-done ()
  "Mark this conversation done."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   `(("OGENT_STATUS" . "done")
     ("OGENT_AWAITING_INPUT" . "nil")
     ("OGENT_EXIT_CODE" . "0")
     ("OGENT_COMPLETED_AT" . ,(ogent-armory-ui--iso-now)))
   "conversation.marked_done")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-archive ()
  "Archive this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_ARCHIVED" . "t")
     ("OGENT_STATUS" . "archived"))
   "conversation.archived")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-unarchive ()
  "Unarchive this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_ARCHIVED" . "nil")
     ("OGENT_STATUS" . "done"))
   "conversation.unarchived")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-mute ()
  "Mute this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_MUTED" . "t"))
   "conversation.muted")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-unmute ()
  "Unmute this conversation."
  (interactive)
  (ogent-armory-ui--conversation-update-properties
   ogent-armory-conversation--root
   ogent-armory-conversation--file
   '(("OGENT_MUTED" . "nil"))
   "conversation.unmuted")
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-compact (&optional summary)
  "Compact this canonical conversation with optional SUMMARY."
  (interactive)
  (let ((conversation-id (ogent-armory-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be compacted"))
    (ogent-armory-conversation-compact-record
     ogent-armory-conversation--root
     conversation-id
     summary))
  (ogent-armory-conversation-refresh))

(defun ogent-armory-conversation-delete (&optional force)
  "Delete this conversation.
With FORCE, skip confirmation."
  (interactive "P")
  (let ((path ogent-armory-conversation--file)
        (buffer (current-buffer)))
    (when (or force
              (yes-or-no-p
               (format "Delete Armory conversation %s? "
                       (abbreviate-file-name path))))
      (if (ogent-armory-ui--canonical-conversation-path-p path)
          (delete-directory (file-name-directory path) t)
        (delete-file path))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-armory-conversation-copy-link ()
  "Copy a stable link to this conversation."
  (interactive)
  (let ((link (if-let ((conversation-id
                        (ogent-armory-conversation--canonical-id)))
                  (format "ogent-armory:%s" conversation-id)
                ogent-armory-conversation--file)))
    (kill-new link)
    (message "Copied %s" link)))

(defun ogent-armory-conversation-open-artifacts ()
  "Open the first artifact declared by this conversation."
  (interactive)
  (let* ((detail (ogent-armory-conversation--detail))
         (artifact (car (ogent-armory-ui--conversation-artifacts detail)))
         (path (ogent-armory-ui--artifact-path
                ogent-armory-conversation--root artifact)))
    (unless (and path (file-exists-p path))
      (user-error "No artifact path recorded for this conversation"))
    (cond
     ((and (file-directory-p path)
           (file-exists-p (expand-file-name "index.html" path)))
      (browse-url-of-file (expand-file-name "index.html" path)))
     ((string-suffix-p ".html" path t)
      (browse-url-of-file path))
     (t
      (find-file path)))))

(defun ogent-armory-conversation-open-logs ()
  "Open the event log for this conversation."
  (interactive)
  (if-let ((conversation-id (ogent-armory-conversation--canonical-id)))
      (find-file
       (ogent-armory-conversation-events-file
        ogent-armory-conversation--root conversation-id))
    (ogent-armory-conversation-visit-source)))

(provide 'ogent-ui-armory-conversations)
;;; ogent-ui-armory-conversations.el ends here
