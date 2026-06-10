;;; ogent-session.el --- Session save and restore for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides session persistence for ogent conversation buffers.
;; Sessions are saved as Org files with metadata stored in file-level keywords.
;;
;; Key functions:
;; - `ogent-session-save' - Save current session buffer to a file
;; - `ogent-session-load' - Load a saved session file
;; - `ogent-session-list' - List available saved sessions with metadata
;; - `ogent-history' - Interactive history browser with search
;;
;; Features:
;; - Full-text search across saved sessions
;; - Project context tracking
;; - Optional org-roam integration for knowledge capture

;;; Code:

(require 'org)

(defgroup ogent-session nil
  "Session persistence for ogent."
  :group 'ogent)

(defcustom ogent-session-directory
  (expand-file-name "ogent-sessions/" user-emacs-directory)
  "Directory for storing saved ogent sessions.
Defaults to ~/.emacs.d/ogent-sessions/"
  :type 'directory
  :group 'ogent-session)

(defcustom ogent-session-name-format "%Y%m%d-%H%M%S"
  "Format string for generating session filenames.
Uses `format-time-string' format specifiers.
Example: \"%Y%m%d-%H%M%S\" produces \"20240115-143022\""
  :type 'string
  :group 'ogent-session)

(defcustom ogent-session-auto-save nil
  "Whether to automatically save sessions on buffer kill.
nil - No automatic saving (default)
t - Save without prompting
`prompt' - Ask before saving"
  :type '(choice (const :tag "No automatic saving" nil)
                 (const :tag "Save automatically" t)
                 (const :tag "Prompt before saving" prompt))
  :group 'ogent-session)

(defcustom ogent-session-track-project t
  "Whether to track project context in session metadata.
When non-nil, the project root directory is saved with the session."
  :type 'boolean
  :group 'ogent-session)

(defcustom ogent-session-roam-integration nil
  "Whether to enable org-roam integration.
When non-nil, sessions can be linked to org-roam nodes."
  :type 'boolean
  :group 'ogent-session)

(defvar-local ogent-persist--id nil
  "Unique identifier for the current session.
Generated on first save and preserved across loads.")

(defvar-local ogent-persist--models nil
  "List of model names used in this session.
Tracked automatically when requests are made.")

(defvar-local ogent-persist--start-time nil
  "Timestamp when this session was created or loaded.")

(defvar-local ogent-persist--file-path nil
  "File path of the loaded session, if any.")

(defvar-local ogent-persist--project nil
  "Project root directory for this session.")

(defvar-local ogent-persist--roam-id nil
  "Org-roam node ID linked to this session, if any.")

(defun ogent-persist--ensure-directory ()
  "Ensure the session directory exists, creating it if necessary."
  (unless (file-exists-p ogent-session-directory)
    (make-directory ogent-session-directory t)))

(defun ogent-persist--generate-id ()
  "Generate a unique session identifier.
Returns a string in the format: ogent-YYYYMMDD-HHMMSS-RANDOM"
  (format "ogent-%s-%04x"
          (format-time-string "%Y%m%d-%H%M%S")
          (random 65536)))

(defun ogent-persist--extract-metadata ()
  "Extract session metadata from the current buffer.
Returns a plist with :id, :models, :start-time, :title, :project."
  (let ((id (or ogent-persist--id (ogent-persist--generate-id)))
        (models (or ogent-persist--models '()))
        (start-time (or ogent-persist--start-time (current-time)))
        (project (or ogent-persist--project
                     (when ogent-session-track-project
                       (ogent-persist--detect-project))))
        (roam-id ogent-persist--roam-id)
        (title (or (ogent-persist--preamble-value "title")
                   (buffer-name))))
    (list :id id
          :models models
          :start-time start-time
          :title title
          :project project
          :roam-id roam-id)))

(defun ogent-persist--detect-project ()
  "Detect the project root directory.
Uses `project-root' if available, or vc-root-dir as fallback."
  (or (when (fboundp 'project-root)
        (when-let ((proj (project-current)))
          (project-root proj)))
      (vc-root-dir)
      default-directory))

(defun ogent-persist--preamble-keywords ()
  "Return Org file keywords from the initial metadata preamble.
The result is an alist mapping upper-case keyword names to values."
  (save-excursion
    (goto-char (point-min))
    (let ((keywords nil)
          (done nil)
          (case-fold-search t))
      (while (and (not done) (not (eobp)))
        (cond
         ((looking-at "^#\\+\\([^: \t]+\\):[ \t]*\\(.*\\)$")
          (push (cons (upcase (match-string-no-properties 1))
                      (match-string-no-properties 2))
                keywords)
          (forward-line 1))
         ((looking-at "^[ \t]*$")
          (forward-line 1))
         (t
          (setq done t))))
      (nreverse keywords))))

(defun ogent-persist--preamble-value (key)
  "Return the preamble keyword value for KEY."
  (cdr (assoc (upcase key) (ogent-persist--preamble-keywords))))

(defun ogent-persist--metadata-line-p ()
  "Return non-nil when point is on an ogent-managed metadata line."
  (let ((case-fold-search t))
    (looking-at-p "^#\\+\\(?:title:\\|OGENT-SESSION-\\)")))

(defun ogent-persist--strip-metadata-preamble ()
  "Remove ogent-managed metadata lines from the initial Org preamble."
  (goto-char (point-min))
  (let ((done nil))
    (while (and (not done) (not (eobp)))
      (cond
       ((ogent-persist--metadata-line-p)
        (delete-region (line-beginning-position)
                       (min (point-max) (1+ (line-end-position)))))
       ((or (looking-at-p "^#\\+")
            (looking-at-p "^[ \t]*$"))
        (forward-line 1))
       (t
        (setq done t))))))

(defun ogent-persist--format-metadata-header (metadata)
  "Format METADATA plist as Org file-level keywords."
  (let ((id (plist-get metadata :id))
        (models (plist-get metadata :models))
        (start-time (plist-get metadata :start-time))
        (title (plist-get metadata :title))
        (project (plist-get metadata :project))
        (roam-id (plist-get metadata :roam-id)))
    (concat
     (format "#+title: %s\n" title)
     (format "#+OGENT-SESSION-ID: %s\n" id)
     (format "#+OGENT-SESSION-START: %s\n"
             (format-time-string "%Y-%m-%d %H:%M:%S" start-time))
     (when models
       (format "#+OGENT-SESSION-MODELS: %s\n"
               (string-join models ", ")))
     (when project
       (format "#+OGENT-SESSION-PROJECT: %s\n" project))
     (when roam-id
       (format "#+OGENT-SESSION-ROAM: %s\n" roam-id))
     "\n")))

(defun ogent-persist--parse-metadata-from-buffer ()
  "Parse session metadata from current buffer's Org keywords."
  (let* ((keywords (ogent-persist--preamble-keywords))
         (id (cdr (assoc "OGENT-SESSION-ID" keywords)))
         (models-value (cdr (assoc "OGENT-SESSION-MODELS" keywords)))
         (start-value (cdr (assoc "OGENT-SESSION-START" keywords)))
         (title (cdr (assoc "TITLE" keywords)))
         (project (cdr (assoc "OGENT-SESSION-PROJECT" keywords)))
         (roam-id (cdr (assoc "OGENT-SESSION-ROAM" keywords)))
         (models (when models-value
                   (split-string models-value ",\\s-*" t)))
         (start-time (when start-value
                       (condition-case nil
                           (date-to-time start-value)
                         (error nil)))))
    (when id
      (list :id id :models models :start-time start-time
            :title title :project project :roam-id roam-id))))

(defun ogent-persist--apply-metadata (metadata)
  "Apply METADATA plist to buffer-local session variables."
  (setq-local ogent-persist--id (plist-get metadata :id))
  (setq-local ogent-persist--models (plist-get metadata :models))
  (setq-local ogent-persist--start-time (plist-get metadata :start-time))
  (setq-local ogent-persist--project (plist-get metadata :project))
  (setq-local ogent-persist--roam-id (plist-get metadata :roam-id)))

(defun ogent-persist--generate-filename (&optional custom-name)
  "Generate a session filename.
If CUSTOM-NAME is provided, use it; otherwise generate from current time."
  (let ((name (or custom-name
                  (format-time-string ogent-session-name-format))))
    (expand-file-name (concat name ".org") ogent-session-directory)))

;;;###autoload
(defun ogent-session-save (&optional filename)
  "Save the current session buffer to a file.
If FILENAME is provided, use it; otherwise generate a timestamped name.
The session is saved with metadata as Org file-level keywords.
Returns the path to the saved file."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Current buffer is not in org-mode"))
  (ogent-persist--ensure-directory)
  
  (let* ((metadata (ogent-persist--extract-metadata))
         (file (or filename
                   (when ogent-persist--file-path
                     (expand-file-name ogent-persist--file-path))
                   (ogent-persist--generate-filename)))
         (content (buffer-substring-no-properties (point-min) (point-max))))
    
    ;; Update buffer-local metadata
    (ogent-persist--apply-metadata metadata)
    (setq-local ogent-persist--file-path file)
    
    ;; Write to file with metadata header
    (with-temp-buffer
      ;; First, insert content and strip old metadata
      (insert content)
      (ogent-persist--strip-metadata-preamble)
      
      ;; Now insert fresh metadata at the beginning
      (goto-char (point-min))
      (insert (ogent-persist--format-metadata-header metadata))
      
      ;; Write to file
      (write-region (point-min) (point-max) file nil 'silent))
    
    (message "Session saved to %s" file)
    file))

;;;###autoload
(defun ogent-session-load (filename)
  "Load a saved session from FILENAME.
Creates a new Org buffer with the session content and restores metadata.
Returns the newly created buffer."
  (interactive
   (list (read-file-name "Load session: "
                         ogent-session-directory
                         nil
                         t
                         nil
                         (lambda (name)
                           (string-suffix-p ".org" name)))))
  (unless (file-exists-p filename)
    (user-error "Session file does not exist: %s" filename))
  
  (let* ((content (with-temp-buffer
                    (insert-file-contents filename)
                    (buffer-string)))
         (buffer-name (format "*ogent-session: %s*"
                              (file-name-base filename)))
         (buffer (get-buffer-create buffer-name)))
    
    (with-current-buffer buffer
      (org-mode)
      (erase-buffer)
      (insert content)
      (goto-char (point-min))
      
      ;; Parse and apply metadata
      (when-let ((metadata (ogent-persist--parse-metadata-from-buffer)))
        (ogent-persist--apply-metadata metadata))
      (setq-local ogent-persist--file-path filename)
      
      ;; Move point to end of buffer (typical for conversation)
      (goto-char (point-max)))
    
    (switch-to-buffer buffer)
    (message "Session loaded: %s" (file-name-nondirectory filename))
    buffer))

;;;###autoload
(defun ogent-session-list ()
  "List all saved sessions in a dedicated buffer.
Shows session name, date, and models used."
  (interactive)
  (ogent-persist--ensure-directory)
  
  (let* ((session-files (directory-files ogent-session-directory
                                         t
                                         "\\.org$"
                                         nil))
         (sessions (mapcar #'ogent-persist--parse-file-metadata session-files))
         (buffer-name "*Ogent Sessions*")
         (buffer (get-buffer-create buffer-name)))
    
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Ogent Sessions\n")
        (insert (make-string 70 ?=) "\n\n")
        
        (if (null sessions)
            (insert "No saved sessions found.\n")
          (dolist (session sessions)
            (let ((file (plist-get session :file))
                  (title (plist-get session :title))
                  (start-time (plist-get session :start-time))
                  (models (plist-get session :models)))
              (insert (format "• %s\n" (or title (file-name-base file))))
              (when start-time
                (insert (format "  Date: %s\n"
                                (format-time-string "%Y-%m-%d %H:%M:%S" start-time))))
              (when models
                (insert (format "  Models: %s\n" (string-join models ", "))))
              (insert (format "  File: %s\n" (file-name-nondirectory file)))
              (insert "\n"))))
        
        (goto-char (point-min))
        (view-mode 1)))
    
    (switch-to-buffer buffer)))

(defun ogent-persist--parse-file-metadata (filename)
  "Parse metadata from session file FILENAME.
Returns a plist with :file, :id, :models, :start-time, :title."
  (with-temp-buffer
    (insert-file-contents filename nil 0 2048) ; Read first 2K
    (let ((metadata (ogent-persist--parse-metadata-from-buffer)))
      (if metadata
          (plist-put metadata :file filename)
        (list :file filename
              :title (file-name-base filename))))))

;;;###autoload
(defun ogent-session-track-model (model-name)
  "Track MODEL-NAME as used in the current session.
Adds to `ogent-persist--models' if not already present."
  (unless (member model-name ogent-persist--models)
    (push model-name ogent-persist--models)))

(defun ogent-persist--maybe-auto-save ()
  "Auto-save session if configured to do so."
  (when (and (derived-mode-p 'org-mode)
             ogent-persist--id
             ogent-session-auto-save)
    (cond
     ((eq ogent-session-auto-save t)
      (ogent-session-save))
     ((eq ogent-session-auto-save 'prompt)
      (when (y-or-n-p "Save ogent session? ")
        (ogent-session-save))))))

;; Hook into buffer kill to support auto-save
(add-hook 'kill-buffer-hook #'ogent-persist--maybe-auto-save)

;;; History Browser

(defvar ogent-history-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-history-load)
    (define-key map (kbd "o") #'ogent-history-load-other-window)
    (define-key map (kbd "d") #'ogent-history-delete)
    (define-key map (kbd "s") #'ogent-history-search)
    (define-key map (kbd "/") #'ogent-history-search)
    (define-key map (kbd "g") #'ogent-history-refresh)
    (define-key map (kbd "r") #'ogent-history-link-roam)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-history-mode'.")

(define-derived-mode ogent-history-mode special-mode "Ogent-History"
  "Major mode for browsing ogent session history.

\\{ogent-history-mode-map}"
  :group 'ogent-session
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (ogent-history-refresh)))
  (setq-local truncate-lines t))

(defvar-local ogent-history--sessions nil
  "List of session metadata plists in the current history buffer.")

(defun ogent-history--session-at-point ()
  "Get the session metadata at point."
  (get-text-property (line-beginning-position) 'ogent-history-session))

(defun ogent-history--format-entry (session)
  "Format a SESSION plist as a display line."
  (let* ((title (or (plist-get session :title) "(untitled)"))
         (start-time (plist-get session :start-time))
         (models (plist-get session :models))
         (project (plist-get session :project))
         (date-str (if start-time
                       (format-time-string "%Y-%m-%d %H:%M" start-time)
                     "???"))
         (model-str (if models
                        (string-join (seq-take models 2) ",")
                      ""))
         (project-str (if project
                          (abbreviate-file-name project)
                        "")))
    (format "%-18s  %-35s  %-20s  %s"
            (propertize date-str 'face 'font-lock-comment-face)
            (propertize (truncate-string-to-width title 35 nil nil "...")
                        'face 'font-lock-keyword-face)
            (propertize (truncate-string-to-width model-str 20 nil nil "...")
                        'face 'font-lock-type-face)
            (propertize (truncate-string-to-width project-str 30 nil nil "...")
                        'face 'font-lock-string-face))))

;;;###autoload
(defun ogent-history ()
  "Open the ogent session history browser."
  (interactive)
  (ogent-persist--ensure-directory)
  (let* ((session-files (directory-files ogent-session-directory t "\\.org$" nil))
         (sessions (sort (mapcar #'ogent-persist--parse-file-metadata session-files)
                         (lambda (a b)
                           (time-less-p (or (plist-get b :start-time) 0)
                                        (or (plist-get a :start-time) 0)))))
         (buffer (get-buffer-create "*Ogent History*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq-local ogent-history--sessions sessions)
        (insert (propertize "Ogent Session History\n" 'face 'bold))
        (insert (propertize "Keybindings: " 'face 'shadow))
        (insert "RET:load  o:other-window  d:delete  s:search  r:link-roam  g:refresh  q:quit\n\n")
        (insert (propertize (format "%-18s  %-35s  %-20s  %s\n"
                                    "Date" "Title" "Model" "Project")
                            'face '(:weight bold :underline t)))
        (if (null sessions)
            (insert (propertize "\nNo saved sessions found.\n" 'face 'shadow))
          (dolist (session sessions)
            (let ((start (point)))
              (insert (ogent-history--format-entry session) "\n")
              (put-text-property start (point) 'ogent-history-session session)))))
      (goto-char (point-min))
      (forward-line 4)
      (ogent-history-mode))
    (switch-to-buffer buffer)))

(defun ogent-history-refresh ()
  "Refresh the history buffer."
  (interactive)
  (ogent-history))

(defun ogent-history-load ()
  "Load the session at point."
  (interactive)
  (when-let* ((session (ogent-history--session-at-point))
              (file (plist-get session :file)))
    (ogent-session-load file)))

(defun ogent-history-load-other-window ()
  "Load the session at point in another window."
  (interactive)
  (when-let* ((session (ogent-history--session-at-point))
              (file (plist-get session :file)))
    (let ((buf (ogent-session-load file)))
      (switch-to-buffer-other-window buf))))

(defun ogent-history-delete ()
  "Delete the session at point after confirmation."
  (interactive)
  (when-let* ((session (ogent-history--session-at-point))
              (file (plist-get session :file))
              (title (or (plist-get session :title) file)))
    (when (yes-or-no-p (format "Delete session \"%s\"? " title))
      (delete-file file)
      (message "Deleted: %s" (file-name-nondirectory file))
      (ogent-history-refresh))))

;;; Full-text Search

;;;###autoload
(defun ogent-history-search (query)
  "Search across all saved sessions for QUERY.
Uses grep for fast full-text search."
  (interactive "sSearch sessions: ")
  (ogent-persist--ensure-directory)
  (let ((default-directory ogent-session-directory))
    (grep (format "grep -n -i -r --include=\"*.org\" %s ."
                  (shell-quote-argument query)))))

;;;###autoload
(defun ogent-session-search (query)
  "Search across saved sessions for QUERY and display results in a buffer."
  (interactive "sSearch sessions: ")
  (ogent-persist--ensure-directory)
  (let* ((files (directory-files ogent-session-directory t "\\.org$"))
         (results '()))
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((metadata (ogent-persist--parse-metadata-from-buffer))
              (matches '()))
          (while (search-forward query nil t)
            (let* ((line-num (line-number-at-pos))
                   (line-start (line-beginning-position))
                   (line-end (line-end-position))
                   (context (buffer-substring-no-properties line-start line-end)))
              (push (list :line line-num :context context) matches)))
          (when matches
            (push (list :file file
                        :metadata metadata
                        :matches (nreverse matches))
                  results)))))
    (ogent-history--display-search-results query (nreverse results))))

(defun ogent-history--display-search-results (query results)
  "Display search RESULTS for QUERY in a buffer."
  (let ((buf (get-buffer-create "*Ogent Search*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Search: %s\n" query) 'face 'bold))
        (insert (format "%d session(s) matched\n\n" (length results)))
        (if (null results)
            (insert (propertize "No matches found.\n" 'face 'shadow))
          (dolist (result results)
            (let* ((file (plist-get result :file))
                   (metadata (plist-get result :metadata))
                   (title (or (plist-get metadata :title)
                              (file-name-base file)))
                   (matches (plist-get result :matches)))
              (insert (propertize (format "▸ %s\n" title) 'face 'font-lock-function-name-face))
              (insert (propertize (format "  %s\n" file) 'face 'font-lock-comment-face))
              (dolist (match matches)
                (insert (format "  L%d: %s\n"
                                (plist-get match :line)
                                (truncate-string-to-width
                                 (string-trim (plist-get match :context))
                                 70 nil nil "..."))))
              (insert "\n")))))
      (goto-char (point-min))
      (special-mode))
    (display-buffer buf)))

;;; Org-roam Integration

(declare-function org-roam-node-read "ext:org-roam")
(declare-function org-roam-node-id "ext:org-roam")
(declare-function org-roam-node-find "ext:org-roam")

(defun ogent-history-link-roam ()
  "Link the session at point to an org-roam node."
  (interactive)
  (unless ogent-session-roam-integration
    (user-error "Org-roam integration is not enabled"))
  (unless (require 'org-roam nil t)
    (user-error "org-roam package not available"))
  (when-let* ((session (ogent-history--session-at-point))
              (file (plist-get session :file))
              (node (org-roam-node-read)))
    (let ((roam-id (org-roam-node-id node)))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        ;; Update or add roam ID
        (if (re-search-forward "^#\\+OGENT-SESSION-ROAM:.*$" nil t)
            (replace-match (format "#+OGENT-SESSION-ROAM: %s" roam-id))
          ;; Insert after other metadata
          (when (re-search-forward "^#\\+OGENT-SESSION-" nil t)
            (end-of-line)
            (insert (format "\n#+OGENT-SESSION-ROAM: %s" roam-id))))
        (write-region (point-min) (point-max) file nil 'silent))
      (message "Linked to org-roam node: %s" roam-id)
      (ogent-history-refresh))))

;;;###autoload
(defun ogent-session-create-roam-note ()
  "Create an org-roam note from the current ogent session."
  (interactive)
  (unless ogent-session-roam-integration
    (user-error "Org-roam integration is not enabled"))
  (unless (require 'org-roam nil t)
    (user-error "org-roam package not available"))
  (let* ((metadata (ogent-persist--extract-metadata))
         (title (plist-get metadata :title)))
    (org-roam-node-find nil (format "ogent: %s" title))))

;; Canonical Evil integration so the history buffer's single-key
;; affordances (RET load, d delete, s/ search, g refresh, q quit)
;; fire under Doom/Evil.
(with-eval-after-load 'evil
  (when (fboundp 'ogent-evil-display-mode-setup)
    (ogent-evil-display-mode-setup
     'ogent-history-mode ogent-history-mode-map
     'ogent-history-mode-hook #'ogent-history-refresh)))

(provide 'ogent-session)

;;; ogent-session.el ends here
