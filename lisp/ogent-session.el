;;; ogent-session.el --- Session save and restore for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides session persistence for ogent conversation buffers.
;; Sessions are saved as Org files with metadata stored in file-level keywords.
;;
;; Key functions:
;; - `ogent-session-save' - Save current session buffer to a file
;; - `ogent-session-load' - Load a saved session file
;; - `ogent-session-list' - List available saved sessions with metadata

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'format-spec)

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
Returns a plist with :id, :models, :start-time, :title."
  (let ((id (or ogent-persist--id (ogent-persist--generate-id)))
        (models (or ogent-persist--models '()))
        (start-time (or ogent-persist--start-time (current-time)))
        (title (save-excursion
                 (goto-char (point-min))
                 (if (re-search-forward "^#\\+title:\\s-*\\(.+\\)$" nil t)
                     (match-string-no-properties 1)
                   (buffer-name)))))
    (list :id id
          :models models
          :start-time start-time
          :title title)))

(defun ogent-persist--format-metadata-header (metadata)
  "Format METADATA plist as Org file-level keywords.
Returns a string with #+OGENT-SESSION-ID:, etc."
  (let ((id (plist-get metadata :id))
        (models (plist-get metadata :models))
        (start-time (plist-get metadata :start-time))
        (title (plist-get metadata :title)))
    (concat
     (format "#+title: %s\n" title)
     (format "#+OGENT-SESSION-ID: %s\n" id)
     (format "#+OGENT-SESSION-START: %s\n"
             (format-time-string "%Y-%m-%d %H:%M:%S" start-time))
     (when models
       (format "#+OGENT-SESSION-MODELS: %s\n"
               (string-join models ", ")))
     "\n")))

(defun ogent-persist--parse-metadata-from-buffer ()
  "Parse session metadata from current buffer's Org keywords.
Returns a plist with :id, :models, :start-time, :title, or nil if not found."
  (save-excursion
    (goto-char (point-min))
    (let ((id nil)
          (models nil)
          (start-time nil)
          (title nil))
      ;; Extract ID
      (when (re-search-forward "^#\\+OGENT-SESSION-ID:\\s-*\\(.+\\)$" nil t)
        (setq id (match-string-no-properties 1)))
      ;; Extract start time
      (goto-char (point-min))
      (when (re-search-forward "^#\\+OGENT-SESSION-START:\\s-*\\(.+\\)$" nil t)
        (condition-case nil
            (setq start-time (date-to-time (match-string-no-properties 1)))
          (error nil)))
      ;; Extract models
      (goto-char (point-min))
      (when (re-search-forward "^#\\+OGENT-SESSION-MODELS:\\s-*\\(.+\\)$" nil t)
        (setq models (split-string (match-string-no-properties 1) ",\\s-*" t)))
      ;; Extract title
      (goto-char (point-min))
      (when (re-search-forward "^#\\+title:\\s-*\\(.+\\)$" nil t)
        (setq title (match-string-no-properties 1)))
      ;; Return metadata if we found at least an ID
      (when id
        (list :id id
              :models models
              :start-time start-time
              :title title)))))

(defun ogent-persist--apply-metadata (metadata)
  "Apply METADATA plist to buffer-local session variables."
  (setq-local ogent-persist--id (plist-get metadata :id))
  (setq-local ogent-persist--models (plist-get metadata :models))
  (setq-local ogent-persist--start-time (plist-get metadata :start-time)))

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
      (goto-char (point-min))
      ;; Remove old metadata lines (title and ogent-session keywords)
      (while (re-search-forward "^#\\+\\(OGENT-SESSION-\\|title:\\)" nil t)
        (goto-char (line-beginning-position))
        (let ((line-start (point)))
          (forward-line 1)
          (delete-region line-start (point))))
      
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

(provide 'ogent-session)

;;; ogent-session.el ends here
