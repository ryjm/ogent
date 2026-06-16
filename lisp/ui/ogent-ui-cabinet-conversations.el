;;; ogent-ui-cabinet-conversations.el --- Cabinet conversation list and reader -*- lexical-binding: t; -*-

;;; Commentary:
;; Conversation list and the single-conversation reader buffer.

;;; Code:

(require 'ogent-ui-cabinet-core)

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

(declare-function ogent-cabinet-search "ogent-ui-cabinet-search")

(defvar ogent-cabinet-conversations-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>"))
      (define-key map (kbd key) #'ogent-cabinet-conversations-open))
    (define-key map "R" #'ogent-cabinet-conversations-retry)
    (define-key map (kbd "C-c r") #'ogent-cabinet-conversations-retry)
    (define-key map "A" #'ogent-cabinet-conversations-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-conversations-archive)
    (define-key map "U" #'ogent-cabinet-conversations-unarchive)
    (define-key map (kbd "C-c u") #'ogent-cabinet-conversations-unarchive)
    (define-key map "v" #'ogent-cabinet-conversations-visit-source)
    (define-key map (kbd "C-c v") #'ogent-cabinet-conversations-visit-source)
    (define-key map "s" #'ogent-cabinet-conversations-search)
    (define-key map (kbd "C-c s") #'ogent-cabinet-conversations-search)
    (define-key map "f" #'ogent-cabinet-conversations-filter)
    (define-key map (kbd "C-c f") #'ogent-cabinet-conversations-filter)
    (define-key map "g" #'ogent-cabinet-conversations-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-conversations-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-conversations-mode'.")

(define-derived-mode ogent-cabinet-conversations-mode tabulated-list-mode
  "Cabinet-Conversations"
  "Major mode for Cabinet conversation lists."
  :group 'ogent-ui-cabinet
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
  (setq-local revert-buffer-function #'ogent-cabinet-conversations-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-conversations--matches-p (session)
  "Return non-nil when SESSION matches current filters."
  (let ((filters ogent-cabinet-conversations--filters))
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
                 (ogent-cabinet--truth-value (plist-get filters :archived)))))))

(defun ogent-cabinet-conversations--entry (session)
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

(defun ogent-cabinet-conversations--entries ()
  "Return conversation entries for the current buffer."
  (let* ((sessions (ogent-cabinet-ui--all-sessions
                    ogent-cabinet-conversations--root))
         (matches (seq-filter #'ogent-cabinet-conversations--matches-p
                              sessions)))
    (if matches
        (mapcar #'ogent-cabinet-conversations--entry matches)
      (list
       (list nil
             (vector "" "" ""
                     (if sessions
                         "No conversations match filters"
                       "No conversations yet")
                     "" "" "" "" ""))))))

(defun ogent-cabinet-conversations (&optional directory filters)
  "Open Cabinet conversations for DIRECTORY with optional FILTERS."
  (interactive
   (list (or (ogent-cabinet-find-root)
             (read-directory-name "Cabinet root: "))
         nil))
  (let* ((root (ogent-cabinet-ui--root directory))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-conversations-buffer-name-format root))))
    (with-current-buffer buffer
      (ogent-cabinet-conversations-mode)
      (setq ogent-cabinet-conversations--root root)
      (setq ogent-cabinet-conversations--filters filters)
      (setq default-directory (file-name-as-directory root))
      (setq tabulated-list-entries #'ogent-cabinet-conversations--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-conversations-refresh (&rest _)
  "Refresh the Cabinet conversations buffer."
  (interactive)
  (tabulated-list-print t))

(defun ogent-cabinet-conversations--item ()
  "Return the conversation at point."
  (or (tabulated-list-get-id)
      (user-error "No Cabinet conversation at point")))

(defun ogent-cabinet-conversations-open ()
  "Open the conversation at point."
  (interactive)
  (ogent-cabinet-conversation
   ogent-cabinet-conversations--root
   (plist-get (ogent-cabinet-conversations--item) :path)))

(defun ogent-cabinet-conversations-visit-source ()
  "Visit the Org source file for the conversation at point."
  (interactive)
  (ogent-cabinet-ui--visit-path
   (plist-get (ogent-cabinet-conversations--item) :path)))

(defun ogent-cabinet-conversations-retry ()
  "Retry the conversation at point when it links to a job."
  (interactive)
  (let ((item (ogent-cabinet-conversations--item)))
    (if-let ((job-id (plist-get item :job-id)))
        (ogent-cabinet-run-job ogent-cabinet-conversations--root
                               (plist-get item :agent)
                               job-id)
      (ogent-cabinet-run-agent ogent-cabinet-conversations--root
                               (plist-get item :agent)
                               (read-string "Instruction: ")))))

(defun ogent-cabinet-conversations-archive ()
  "Archive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-cabinet-conversations--item) :path)))
    (ogent-cabinet-ui--conversation-update-properties
     ogent-cabinet-conversations--root path
     '(("OGENT_ARCHIVED" . "t")
       ("OGENT_STATUS" . "archived"))
     "conversation.archived"))
  (ogent-cabinet-conversations-refresh))

(defun ogent-cabinet-conversations-unarchive ()
  "Unarchive the conversation at point."
  (interactive)
  (let ((path (plist-get (ogent-cabinet-conversations--item) :path)))
    (ogent-cabinet-ui--conversation-update-properties
     ogent-cabinet-conversations--root path
     '(("OGENT_ARCHIVED" . "nil")
       ("OGENT_STATUS" . "done"))
     "conversation.unarchived"))
  (ogent-cabinet-conversations-refresh))

(defun ogent-cabinet-conversations-filter ()
  "Set simple conversation filters."
  (interactive)
  (setq ogent-cabinet-conversations--filters
        (list :agent (ogent-cabinet--blank-to-nil
                      (ogent-cabinet-ui--read-optional-choice
                       "Agent filter: "
                       (ogent-cabinet-ui--agent-slugs
                        ogent-cabinet-conversations--root)))
              :status (ogent-cabinet--blank-to-nil
                       (ogent-cabinet-ui--read-optional-choice
                        "Status filter: "
                        (ogent-cabinet-ui--conversation-status-candidates
                         ogent-cabinet-conversations--root)))
              :tag (ogent-cabinet--blank-to-nil
                    (ogent-cabinet-ui--read-optional-choice
                     "Tag filter: "
                     (ogent-cabinet-ui--conversation-tag-candidates
                      ogent-cabinet-conversations--root)))))
  (ogent-cabinet-conversations-refresh))

(defun ogent-cabinet-conversations-search ()
  "Search within Cabinet conversations."
  (interactive)
  (ogent-cabinet-search ogent-cabinet-conversations--root
                        (read-string "Search conversations: ")
                        (list :kind 'session)))

(defvar ogent-cabinet-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "<return>" "<kp-enter>" "v"))
      (define-key map (kbd key) #'ogent-cabinet-conversation-visit-source))
    (define-key map (kbd "C-c v") #'ogent-cabinet-conversation-visit-source)
    (define-key map "c" #'ogent-cabinet-conversation-continue)
    (define-key map (kbd "C-c c") #'ogent-cabinet-conversation-continue)
    (define-key map "k" #'ogent-cabinet-conversation-stop)
    (define-key map (kbd "C-c k") #'ogent-cabinet-conversation-stop)
    (define-key map "R" #'ogent-cabinet-conversation-retry)
    (define-key map (kbd "C-c r") #'ogent-cabinet-conversation-retry)
    (define-key map "d" #'ogent-cabinet-conversation-mark-done)
    (define-key map (kbd "C-c d") #'ogent-cabinet-conversation-mark-done)
    (define-key map "A" #'ogent-cabinet-conversation-archive)
    (define-key map (kbd "C-c a") #'ogent-cabinet-conversation-archive)
    (define-key map "U" #'ogent-cabinet-conversation-unarchive)
    (define-key map (kbd "C-c u") #'ogent-cabinet-conversation-unarchive)
    (define-key map "m" #'ogent-cabinet-conversation-mute)
    (define-key map (kbd "C-c m") #'ogent-cabinet-conversation-mute)
    (define-key map "M" #'ogent-cabinet-conversation-unmute)
    (define-key map (kbd "C-c M") #'ogent-cabinet-conversation-unmute)
    (define-key map "C" #'ogent-cabinet-conversation-compact)
    (define-key map (kbd "C-c C") #'ogent-cabinet-conversation-compact)
    (define-key map "D" #'ogent-cabinet-conversation-delete)
    (define-key map (kbd "C-c D") #'ogent-cabinet-conversation-delete)
    (define-key map "y" #'ogent-cabinet-conversation-copy-link)
    (define-key map (kbd "C-c y") #'ogent-cabinet-conversation-copy-link)
    (define-key map "o" #'ogent-cabinet-conversation-open-artifacts)
    (define-key map (kbd "C-c o") #'ogent-cabinet-conversation-open-artifacts)
    (define-key map "l" #'ogent-cabinet-conversation-open-logs)
    (define-key map (kbd "C-c l") #'ogent-cabinet-conversation-open-logs)
    (define-key map "g" #'ogent-cabinet-conversation-refresh)
    (define-key map (kbd "C-c g") #'ogent-cabinet-conversation-refresh)
    (define-key map (kbd "TAB") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<tab>") #'ogent-cabinet-ui-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-cabinet-ui-cycle-sections)
    (define-key map (kbd "M-n") #'ogent-cabinet-ui-next-section)
    (define-key map (kbd "M-p") #'ogent-cabinet-ui-previous-section)
    (define-key map (kbd "^") #'ogent-cabinet-ui-up-section)
    (define-key map (kbd "C-c U") #'ogent-cabinet-ui-up-section)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-conversation-mode'.")

(ogent-cabinet-ui--define-section-mode ogent-cabinet-conversation-mode
                                       "Cabinet-Conversation"
                                       "Major mode for a single Cabinet conversation."
                                       (setq-local revert-buffer-function #'ogent-cabinet-conversation-refresh)
                                       (setq-local truncate-lines nil)
                                       (setq-local buffer-read-only t)
                                       (ogent-cabinet-ui--configure-section-buffer)
                                       (setq header-line-format
                                             "RET source  C-c g refresh  C-c r retry  C-c c continue  C-c o artifacts  C-c l logs  TAB fold"))

(defun ogent-cabinet-conversation (&optional directory file)
  "Open Cabinet conversation FILE under DIRECTORY."
  (interactive
   (let* ((root (ogent-cabinet-ui--root
                 (or (ogent-cabinet-find-root)
                     (read-directory-name "Cabinet root: "))))
          (session (completing-read
                    "Conversation: "
                    (mapcar (lambda (item)
                              (plist-get item :path))
                            (ogent-cabinet-ui--all-sessions root))
                    nil t)))
     (list root session)))
  (let* ((root (ogent-cabinet-ui--root directory))
         (raw-path (or file (plist-get (ogent-cabinet-conversations--item) :path)))
         (path (if (and raw-path (file-exists-p raw-path))
                   (file-truename raw-path)
                 raw-path))
         (buffer (get-buffer-create
                  (ogent-cabinet-ui--buffer-name
                   ogent-cabinet-conversation-buffer-name-format
                   root
                   (file-name-base path)))))
    (with-current-buffer buffer
      (ogent-cabinet-conversation-mode)
      (setq ogent-cabinet-conversation--root root)
      (setq ogent-cabinet-conversation--file path)
      (setq default-directory (file-name-as-directory root))
      (ogent-cabinet-conversation-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-conversation-refresh (&rest _)
  "Refresh this conversation detail buffer."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (ogent-cabinet-conversation--insert-buffer)
    (goto-char (point-min))))

(defun ogent-cabinet-conversation--insert-buffer ()
  "Insert the current conversation detail."
  (ogent-cabinet-ui--with-root-section (ogent-cabinet-conversation-root)
                                       (ogent-cabinet-conversation--insert-buffer-content)))

(defun ogent-cabinet-conversation--insert-overview (detail)
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
                          'face 'ogent-cabinet-ui-dim)
              "\n"))))

(defun ogent-cabinet-conversation--insert-details (detail)
  "Insert detailed metadata for DETAIL."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-metadata)
                                  (ogent-cabinet-ui--heading-text "Details")
                                  (ogent-cabinet-ui--insert-kv "Status" (plist-get detail :status))
                                  (ogent-cabinet-ui--insert-kv "Agent" (plist-get detail :agent))
                                  (ogent-cabinet-ui--insert-kv "Job" (plist-get detail :job-id))
                                  (ogent-cabinet-ui--insert-kv "Trigger" (plist-get detail :trigger))
                                  (ogent-cabinet-ui--insert-kv "Provider" (plist-get detail :provider))
                                  (ogent-cabinet-ui--insert-kv "Model" (plist-get detail :model))
                                  (ogent-cabinet-ui--insert-kv
                                   "Exit status"
                                   (when (plist-get detail :exit-status)
                                     (number-to-string
                                      (plist-get detail :exit-status))))
                                  (ogent-cabinet-ui--insert-kv "Duration" (plist-get detail :duration))
                                  (ogent-cabinet-ui--insert-kv "Started" (plist-get detail :started))
                                  (ogent-cabinet-ui--insert-kv "Finished" (plist-get detail :finished))
                                  (ogent-cabinet-ui--insert-kv "Last activity"
                                                               (plist-get detail :last-activity))
                                  (ogent-cabinet-ui--insert-kv "Archived"
                                                               (if (plist-get detail :archived) "yes" "no"))
                                  (ogent-cabinet-ui--insert-kv "Muted"
                                                               (if (plist-get detail :muted) "yes" "no"))))

(defun ogent-cabinet-conversation--insert-turns (turns)
  "Insert each conversation turn.
TURNS is the list of turn plists to insert."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-turns)
                                  (ogent-cabinet-ui--heading-text "Turns")
                                  (if turns
                                      (dolist (turn turns)
                                        (insert
                                         (propertize
                                          (format "  %03d %s %s\n"
                                                  (or (plist-get turn :turn) 0)
                                                  (upcase (or (plist-get turn :role) "turn"))
                                                  (or (plist-get turn :ts) ""))
                                          'face 'ogent-cabinet-ui-dim))
                                        (when-let ((tokens (plist-get turn :tokens)))
                                          (insert
                                           (format "  tokens input=%s output=%s cache=%s\n"
                                                   (or (plist-get tokens :input) "")
                                                   (or (plist-get tokens :output) "")
                                                   (or (plist-get tokens :cache) ""))))
                                        (insert (string-trim-right (or (plist-get turn :content) "")) "\n\n"))
                                    (insert (propertize "  No turn files recorded\n"
                                                        'face 'ogent-cabinet-ui-dim)))))

(defun ogent-cabinet-conversation--insert-artifacts (root detail)
  "Insert artifacts listed by DETAIL under ROOT."
  (let ((artifacts (ogent-cabinet-ui--conversation-artifacts detail)))
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-artifacts)
                                    (ogent-cabinet-ui--heading-text "Artifacts")
                                    (if artifacts
                                        (dolist (artifact artifacts)
                                          (let ((path (ogent-cabinet-ui--artifact-path root artifact)))
                                            (ogent-cabinet-ui--insert-item-line
                                             (list :type 'artifact :path path)
                                             (format "  %s" artifact))))
                                      (insert (propertize "  No artifacts recorded\n"
                                                          'face 'ogent-cabinet-ui-dim))))))

(defun ogent-cabinet-conversation--insert-events (events)
  "Insert conversation EVENTS."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-events)
                                  (ogent-cabinet-ui--heading-text "Events")
                                  (if events
                                      (dolist (event events)
                                        (insert
                                         (format "  %06d %-24s %s\n"
                                                 (or (plist-get event :seq) 0)
                                                 (or (plist-get event :type) "")
                                                 (or (plist-get event :ts) "")))
                                        (when-let ((payload (ogent-cabinet--blank-to-nil
                                                             (plist-get event :payload))))
                                          (insert "  " (string-trim payload) "\n")))
                                    (insert (propertize "  No events recorded\n"
                                                        'face 'ogent-cabinet-ui-dim)))))

(defun ogent-cabinet-conversation--insert-runtime (detail)
  "Insert runtime metadata for DETAIL."
  (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-runtime)
                                  (ogent-cabinet-ui--heading-text "Runtime")
                                  (ogent-cabinet-ui--insert-kv "Adapter" (plist-get detail :adapter))
                                  (ogent-cabinet-ui--insert-kv "Runtime" (plist-get detail :runtime-mode))
                                  (ogent-cabinet-ui--insert-kv "Effort" (plist-get detail :effort))
                                  (ogent-cabinet-ui--insert-kv "Context" (plist-get detail :context-window))
                                  (ogent-cabinet-ui--insert-kv "Resume" (plist-get detail :last-resume-result))
                                  (when (or (plist-get detail :tokens-input)
                                            (plist-get detail :tokens-output)
                                            (plist-get detail :tokens-cache)
                                            (plist-get detail :tokens-total))
                                    (ogent-cabinet-ui--insert-kv
                                     "Tokens"
                                     (format "input=%s output=%s cache=%s total=%s"
                                             (or (plist-get detail :tokens-input) "")
                                             (or (plist-get detail :tokens-output) "")
                                             (or (plist-get detail :tokens-cache) "")
                                             (or (plist-get detail :tokens-total) ""))))))

(defun ogent-cabinet-conversation--runtime-present-p (detail)
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

(defun ogent-cabinet-conversation--insert-runtime-trace (trace)
  "Insert runtime TRACE as a preview."
  (when (ogent-cabinet--blank-to-nil trace)
    (let* ((preview (ogent-cabinet-ui--preview-lines
                     trace
                     ogent-cabinet-conversation-runtime-trace-preview-lines))
           (hidden (plist-get preview :hidden)))
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-runtime-trace)
                                      (ogent-cabinet-ui--heading-text "Runtime Trace")
                                      (ogent-cabinet-ui--insert-readable-text
                                       (plist-get preview :text)
                                       "  No runtime trace recorded\n")
                                      (when (> hidden 0)
                                        (insert
                                         (propertize
                                          (format "  %d more lines. Press l for logs or v for source Org.\n"
                                                  hidden)
                                          'face 'ogent-cabinet-ui-dim)))))))

(defun ogent-cabinet-conversation--insert-buffer-content ()
  "Insert the current conversation detail sections."
  (let ((detail (ogent-cabinet-ui--conversation-detail
                 ogent-cabinet-conversation--root
                 ogent-cabinet-conversation--file)))
    (insert (propertize (or (plist-get detail :name)
                            (plist-get detail :id))
                        'face 'ogent-cabinet-ui-heading)
            "\n")
    (ogent-cabinet-conversation--insert-overview detail)
    (when (plist-get detail :awaiting-input)
      (insert (propertize "Awaiting user input\n"
                          'face 'ogent-cabinet-ui-warning)))
    (insert "\n")
    (when (or (plist-get detail :summary)
              (plist-get detail :context-summary))
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-summary)
                                      (ogent-cabinet-ui--heading-text "Summary")
                                      (when-let ((summary (plist-get detail :summary)))
                                        (insert summary "\n"))
                                      (when-let ((context (plist-get detail :context-summary)))
                                        (insert "\nContext\n" context "\n")))
      (insert "\n"))
    (when (plist-get detail :turns)
      (ogent-cabinet-conversation--insert-turns (plist-get detail :turns))
      (insert "\n"))
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-output)
                                    (ogent-cabinet-ui--heading-text "Output")
                                    (ogent-cabinet-ui--insert-readable-text
                                     (plist-get detail :output)
                                     "  No output recorded\n"))
    (insert "\n")
    (ogent-cabinet-conversation--insert-artifacts
     ogent-cabinet-conversation--root detail)
    (insert "\n")
    (ogent-cabinet-conversation--insert-details detail)
    (insert "\n")
    (when (ogent-cabinet-conversation--runtime-present-p detail)
      (ogent-cabinet-conversation--insert-runtime detail)
      (insert "\n"))
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-prompt)
                                    (ogent-cabinet-ui--heading-text "Prompt")
                                    (ogent-cabinet-ui--insert-readable-text
                                     (plist-get detail :prompt)
                                     "  No prompt recorded\n"))
    (insert "\n")
    (when (plist-get detail :tools)
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-tools)
                                      (ogent-cabinet-ui--heading-text "Tool Blocks")
                                      (dolist (tool (plist-get detail :tools))
                                        (insert (format "  %s\n%s\n" (plist-get tool :header)
                                                        (plist-get tool :body)))))
      (insert "\n"))
    (when (ogent-cabinet--blank-to-nil (plist-get detail :error))
      (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-error)
                                      (ogent-cabinet-ui--heading-text "Error")
                                      (ogent-cabinet-ui--insert-readable-text
                                       (plist-get detail :error)
                                       "  No error recorded\n"))
      (insert "\n"))
    (ogent-cabinet-conversation--insert-runtime-trace
     (plist-get detail :runtime-trace))
    (when (ogent-cabinet--blank-to-nil (plist-get detail :runtime-trace))
      (insert "\n"))
    (ogent-cabinet-conversation--insert-events (plist-get detail :events))
    (insert "\n")
    (ogent-cabinet-ui--with-section (ogent-cabinet-conversation-source)
                                    (ogent-cabinet-ui--heading-text "Source Org")
                                    (ogent-cabinet-ui--insert-item-line
                                     (list :type 'file :path (plist-get detail :path))
                                     (format "  %s" (plist-get detail :path))))))

(defun ogent-cabinet-conversation-visit-source ()
  "Visit the Org source for this conversation."
  (interactive)
  (ogent-cabinet-ui--visit-path ogent-cabinet-conversation--file))

(defun ogent-cabinet-conversation--detail ()
  "Return detail for the current conversation buffer."
  (ogent-cabinet-ui--conversation-detail
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file))

(defun ogent-cabinet-conversation--canonical-id ()
  "Return current canonical conversation id or nil."
  (when (ogent-cabinet-ui--canonical-conversation-path-p
         ogent-cabinet-conversation--file)
    (ogent-cabinet-ui--canonical-conversation-id
     ogent-cabinet-conversation--file)))

(defun ogent-cabinet-conversation-continue (instruction)
  "Continue this conversation with INSTRUCTION."
  (interactive (list (read-string "Continue: ")))
  (let* ((detail (ogent-cabinet-conversation--detail))
         (agent (plist-get detail :agent))
         (job-id (plist-get detail :job-id))
         (conversation-id (ogent-cabinet-conversation--canonical-id)))
    (unless agent
      (user-error "Conversation has no agent"))
    (if conversation-id
        (let* ((replay
                (ogent-cabinet-conversation-replay-prompt
                 ogent-cabinet-conversation--root conversation-id instruction))
               (keywords
                (append
                 (when job-id (list :job-id job-id))
                 (list :instruction replay
                       :conversation-id conversation-id
                       :conversation-title (plist-get detail :name)
                       :turn-content instruction
                       :trigger "manual"
                       :last-resume-result "replay")))
               (plan (apply #'ogent-cabinet-runner-plan
                            ogent-cabinet-conversation--root
                            agent
                            keywords)))
          (when (ogent-cabinet-runner--confirm plan)
            (ogent-cabinet-runner-start plan)
            (ogent-cabinet-conversation-refresh)))
      (ogent-cabinet-run-agent
       ogent-cabinet-conversation--root agent instruction))))

(defun ogent-cabinet-conversation-stop ()
  "Stop this conversation when it has a live process."
  (interactive)
  (let ((conversation-id (ogent-cabinet-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be stopped"))
    (unless (ogent-cabinet-runner-stop-conversation
             ogent-cabinet-conversation--root conversation-id)
      (user-error "No live process for conversation %s" conversation-id)))
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-retry ()
  "Retry this conversation."
  (interactive)
  (let ((detail (ogent-cabinet-conversation--detail)))
    (if-let ((job-id (plist-get detail :job-id)))
        (ogent-cabinet-run-job ogent-cabinet-conversation--root
                               (plist-get detail :agent)
                               job-id)
      (ogent-cabinet-run-agent ogent-cabinet-conversation--root
                               (plist-get detail :agent)
                               (read-string "Instruction: ")))))

(defun ogent-cabinet-conversation-mark-done ()
  "Mark this conversation done."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   `(("OGENT_STATUS" . "done")
     ("OGENT_AWAITING_INPUT" . "nil")
     ("OGENT_EXIT_CODE" . "0")
     ("OGENT_COMPLETED_AT" . ,(ogent-cabinet-ui--iso-now)))
   "conversation.marked_done")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-archive ()
  "Archive this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_ARCHIVED" . "t")
     ("OGENT_STATUS" . "archived"))
   "conversation.archived")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-unarchive ()
  "Unarchive this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_ARCHIVED" . "nil")
     ("OGENT_STATUS" . "done"))
   "conversation.unarchived")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-mute ()
  "Mute this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_MUTED" . "t"))
   "conversation.muted")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-unmute ()
  "Unmute this conversation."
  (interactive)
  (ogent-cabinet-ui--conversation-update-properties
   ogent-cabinet-conversation--root
   ogent-cabinet-conversation--file
   '(("OGENT_MUTED" . "nil"))
   "conversation.unmuted")
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-compact (&optional summary)
  "Compact this canonical conversation with optional SUMMARY."
  (interactive)
  (let ((conversation-id (ogent-cabinet-conversation--canonical-id)))
    (unless conversation-id
      (user-error "Only canonical conversations can be compacted"))
    (ogent-cabinet-conversation-compact-record
     ogent-cabinet-conversation--root
     conversation-id
     summary))
  (ogent-cabinet-conversation-refresh))

(defun ogent-cabinet-conversation-delete (&optional force)
  "Delete this conversation.
With FORCE, skip confirmation."
  (interactive "P")
  (let ((path ogent-cabinet-conversation--file)
        (buffer (current-buffer)))
    (when (or force
              (yes-or-no-p
               (format "Delete Cabinet conversation %s? "
                       (abbreviate-file-name path))))
      (if (ogent-cabinet-ui--canonical-conversation-path-p path)
          (delete-directory (file-name-directory path) t)
        (delete-file path))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ogent-cabinet-conversation-copy-link ()
  "Copy a stable link to this conversation."
  (interactive)
  (let ((link (if-let ((conversation-id
                        (ogent-cabinet-conversation--canonical-id)))
                  (format "ogent-cabinet:%s" conversation-id)
                ogent-cabinet-conversation--file)))
    (kill-new link)
    (message "Copied %s" link)))

(defun ogent-cabinet-conversation-open-artifacts ()
  "Open the first artifact declared by this conversation."
  (interactive)
  (let* ((detail (ogent-cabinet-conversation--detail))
         (artifact (car (ogent-cabinet-ui--conversation-artifacts detail)))
         (path (ogent-cabinet-ui--artifact-path
                ogent-cabinet-conversation--root artifact)))
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

(defun ogent-cabinet-conversation-open-logs ()
  "Open the event log for this conversation."
  (interactive)
  (if-let ((conversation-id (ogent-cabinet-conversation--canonical-id)))
      (find-file
       (ogent-cabinet-conversation-events-file
        ogent-cabinet-conversation--root conversation-id))
    (ogent-cabinet-conversation-visit-source)))

(provide 'ogent-ui-cabinet-conversations)
;;; ogent-ui-cabinet-conversations.el ends here
