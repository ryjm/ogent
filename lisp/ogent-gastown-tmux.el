;;; ogent-gastown-tmux.el --- Tmux session integration for Gas Town -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides tmux session management for Gas Town agent workflows.
;; Features:
;; - Session picker with completing-read (consult/marginalia compatible)
;; - Attach to session (vterm, term, or external terminal)
;; - Send commands to sessions
;; - Session preview via tmux capture-pane

;;; Code:

(require 'cl-lib)
(require 'seq)

;; Soft dependencies
(declare-function vterm "ext:vterm")
(declare-function vterm-send-string "ext:vterm")

;;; Customization

(defgroup ogent-gastown-tmux nil
  "Tmux session integration for Gas Town."
  :group 'ogent-gastown
  :prefix "ogent-gastown-tmux-")

(defcustom ogent-gastown-tmux-executable "tmux"
  "Path to the tmux executable."
  :type 'string
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-attach-method 'vterm
  "Method for attaching to tmux sessions.
`vterm' - Open in vterm buffer (requires vterm package)
`term' - Open in built-in term buffer
`external' - Launch external terminal"
  :type '(choice (const :tag "vterm buffer" vterm)
                 (const :tag "term buffer" term)
                 (const :tag "External terminal" external))
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-external-terminal "kitty"
  "External terminal to use when attach-method is `external'.
Common options: \"kitty\", \"alacritty\", \"Terminal.app\"."
  :type 'string
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-preview-lines 50
  "Number of lines to capture for session preview."
  :type 'integer
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-quick-commands
  '(("Check mail" . "gt mail inbox")
    ("Show hook" . "gt hook")
    ("Nudge" . "# nudge - type your message")
    ("Sync beads" . "bd sync"))
  "Quick commands available for sending to sessions.
Each entry is (LABEL . COMMAND)."
  :type '(alist :key-type string :value-type string)
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-session-prefix "gt-"
  "Prefix for Gas Town tmux sessions.
Used to filter sessions in the picker."
  :type 'string
  :group 'ogent-gastown-tmux)

;;; Internal State

(defvar ogent-gastown-tmux--sessions-cache nil
  "Cached list of tmux sessions.")

(defvar ogent-gastown-tmux--cache-time nil
  "Time when session cache was last updated.")

(defconst ogent-gastown-tmux--cache-ttl 5
  "Cache TTL in seconds.")

;;; Core Utilities

(defun ogent-gastown-tmux-available-p ()
  "Return non-nil if tmux is available."
  (executable-find ogent-gastown-tmux-executable))

(defun ogent-gastown-tmux--run-command (args)
  "Run tmux with ARGS synchronously, return output as string."
  (with-temp-buffer
    (let ((exit-code (apply #'call-process
                            ogent-gastown-tmux-executable
                            nil t nil args)))
      (if (zerop exit-code)
          (string-trim (buffer-string))
        nil))))

(defun ogent-gastown-tmux--run-command-async (args callback &optional error-callback)
  "Run tmux with ARGS asynchronously, call CALLBACK with output.
ERROR-CALLBACK is called with error message on failure."
  (let* ((buffer (generate-new-buffer " *ogent-tmux*"))
         (proc nil))
    (setq proc
          (make-process
           :name "ogent-tmux"
           :buffer buffer
           :command (cons ogent-gastown-tmux-executable args)
           :sentinel
           (lambda (process event)
             (cond
              ((string= event "finished\n")
               (with-current-buffer (process-buffer process)
                 (funcall callback (string-trim (buffer-string))))
               (kill-buffer (process-buffer process)))
              ((string-match "exited abnormally" event)
               (when error-callback
                 (funcall error-callback
                          (format "tmux command failed: %s" event)))
               (kill-buffer (process-buffer process)))
              (t
               (kill-buffer (process-buffer process)))))))
    proc))

;;; Session Discovery

(defun ogent-gastown-tmux--parse-session-line (line)
  "Parse a tmux list-sessions LINE into a plist."
  (when (string-match "^\\([^:]+\\):\\s-*\\([0-9]+\\)\\s-*windows" line)
    (let ((name (match-string 1 line))
          (windows (string-to-number (match-string 2 line)))
          (attached (string-match-p "(attached)" line)))
      (list :name name
            :windows windows
            :attached (not (null attached))
            :gastown (string-prefix-p ogent-gastown-tmux-session-prefix name)))))

(defun ogent-gastown-tmux--list-sessions ()
  "Get list of tmux sessions as plists.
Returns cached value if still valid."
  (when (and ogent-gastown-tmux--sessions-cache
             ogent-gastown-tmux--cache-time
             (< (float-time (time-subtract (current-time)
                                           ogent-gastown-tmux--cache-time))
                ogent-gastown-tmux--cache-ttl))
    (cl-return-from ogent-gastown-tmux--list-sessions
      ogent-gastown-tmux--sessions-cache))

  (let ((output (ogent-gastown-tmux--run-command '("list-sessions"))))
    (when output
      (let ((sessions (delq nil
                            (mapcar #'ogent-gastown-tmux--parse-session-line
                                    (split-string output "\n" t)))))
        (setq ogent-gastown-tmux--sessions-cache sessions)
        (setq ogent-gastown-tmux--cache-time (current-time))
        sessions))))

(defun ogent-gastown-tmux-refresh-sessions ()
  "Force refresh of session cache."
  (interactive)
  (setq ogent-gastown-tmux--sessions-cache nil)
  (setq ogent-gastown-tmux--cache-time nil)
  (ogent-gastown-tmux--list-sessions))

;;; Session Picker

(defun ogent-gastown-tmux--format-session (session)
  "Format SESSION plist for display in completing-read."
  (let ((name (plist-get session :name))
        (windows (plist-get session :windows))
        (attached (plist-get session :attached))
        (gastown (plist-get session :gastown)))
    (format "%s%s (%d windows)%s"
            (if gastown "[GT] " "")
            name
            windows
            (if attached " [attached]" ""))))

(defun ogent-gastown-tmux--annotation-function (candidate)
  "Provide annotation for session CANDIDATE."
  (let* ((sessions (ogent-gastown-tmux--list-sessions))
         (session (seq-find (lambda (s)
                              (string-match-p (regexp-quote (plist-get s :name))
                                              candidate))
                            sessions)))
    (when session
      (let ((attached (plist-get session :attached))
            (windows (plist-get session :windows)))
        (concat (propertize " " 'display '(space :align-to 40))
                (if attached
                    (propertize "attached" 'face 'success)
                  (propertize "detached" 'face 'shadow))
                " "
                (propertize (format "%d win" windows) 'face 'font-lock-comment-face))))))

(defun ogent-gastown-tmux--read-session (&optional prompt)
  "Read a session name with completion.
PROMPT defaults to \"Session: \"."
  (unless (ogent-gastown-tmux-available-p)
    (user-error "tmux not found in PATH"))
  (let* ((sessions (ogent-gastown-tmux--list-sessions))
         (candidates (mapcar (lambda (s) (plist-get s :name)) sessions))
         (completion-extra-properties
          '(:annotation-function ogent-gastown-tmux--annotation-function)))
    (unless sessions
      (user-error "No tmux sessions found"))
    (completing-read (or prompt "Session: ") candidates nil t)))

;;; Attach to Session

(defun ogent-gastown-tmux--attach-vterm (session-name)
  "Attach to SESSION-NAME using vterm."
  (unless (require 'vterm nil t)
    (user-error "vterm package not installed"))
  (let ((buffer-name (format "*tmux:%s*" session-name)))
    (if (get-buffer buffer-name)
        (switch-to-buffer buffer-name)
      (let ((vterm-shell (format "%s attach -t %s"
                                 ogent-gastown-tmux-executable
                                 (shell-quote-argument session-name))))
        (vterm buffer-name)))))

(defun ogent-gastown-tmux--attach-term (session-name)
  "Attach to SESSION-NAME using built-in term."
  (let ((buffer-name (format "*tmux:%s*" session-name)))
    (if (get-buffer buffer-name)
        (switch-to-buffer buffer-name)
      (ansi-term ogent-gastown-tmux-executable buffer-name)
      (with-current-buffer buffer-name
        (term-send-raw-string (format "attach -t %s\n"
                                      (shell-quote-argument session-name)))))))

(defun ogent-gastown-tmux--attach-external (session-name)
  "Attach to SESSION-NAME using external terminal."
  (let ((cmd (format "%s attach -t %s"
                     ogent-gastown-tmux-executable
                     (shell-quote-argument session-name))))
    (pcase ogent-gastown-tmux-external-terminal
      ("kitty"
       (start-process "tmux-attach" nil
                      "kitty" "--" "sh" "-c" cmd))
      ("alacritty"
       (start-process "tmux-attach" nil
                      "alacritty" "-e" "sh" "-c" cmd))
      ("Terminal.app"
       (start-process "tmux-attach" nil
                      "open" "-a" "Terminal.app"
                      (expand-file-name "~")))  ; macOS quirk
      (_
       (start-process "tmux-attach" nil
                      ogent-gastown-tmux-external-terminal
                      "-e" cmd)))))

;;;###autoload
(defun ogent-gastown-tmux-attach (&optional session-name method)
  "Attach to a tmux SESSION-NAME using METHOD.
If SESSION-NAME is nil, prompt for one.
METHOD defaults to `ogent-gastown-tmux-attach-method'."
  (interactive)
  (let ((session (or session-name (ogent-gastown-tmux--read-session "Attach to: ")))
        (attach-method (or method ogent-gastown-tmux-attach-method)))
    (pcase attach-method
      ('vterm (ogent-gastown-tmux--attach-vterm session))
      ('term (ogent-gastown-tmux--attach-term session))
      ('external (ogent-gastown-tmux--attach-external session))
      (_ (user-error "Unknown attach method: %s" attach-method)))))

;;; Send Commands

(defun ogent-gastown-tmux--send-keys (session-name keys)
  "Send KEYS to SESSION-NAME."
  (ogent-gastown-tmux--run-command
   (list "send-keys" "-t" session-name keys "Enter")))

;;;###autoload
(defun ogent-gastown-tmux-send (session-name command)
  "Send COMMAND to SESSION-NAME.
If called interactively, prompt for both."
  (interactive
   (let ((session (ogent-gastown-tmux--read-session "Send to: ")))
     (list session
           (read-string (format "Command for %s: " session)))))
  (if (ogent-gastown-tmux--send-keys session-name command)
      (message "Sent to %s: %s" session-name command)
    (message "Failed to send command to %s" session-name)))

;;;###autoload
(defun ogent-gastown-tmux-send-quick ()
  "Send a quick command from `ogent-gastown-tmux-quick-commands'."
  (interactive)
  (let* ((session (ogent-gastown-tmux--read-session "Send to: "))
         (choice (completing-read "Command: "
                                  (mapcar #'car ogent-gastown-tmux-quick-commands)
                                  nil t))
         (command (cdr (assoc choice ogent-gastown-tmux-quick-commands))))
    (ogent-gastown-tmux-send session command)))

;;; Session Preview

(defun ogent-gastown-tmux--capture-pane (session-name &optional lines)
  "Capture pane content from SESSION-NAME.
LINES defaults to `ogent-gastown-tmux-preview-lines'."
  (let ((line-count (or lines ogent-gastown-tmux-preview-lines)))
    (ogent-gastown-tmux--run-command
     (list "capture-pane" "-t" session-name "-p"
           "-S" (format "-%d" line-count)))))

;;;###autoload
(defun ogent-gastown-tmux-preview (&optional session-name)
  "Show preview of SESSION-NAME in a popup buffer.
If SESSION-NAME is nil, prompt for one."
  (interactive)
  (let* ((session (or session-name (ogent-gastown-tmux--read-session "Preview: ")))
         (content (ogent-gastown-tmux--capture-pane session))
         (buf (get-buffer-create (format "*tmux-preview:%s*" session))))
    (if content
        (progn
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (propertize (format "=== %s ===\n\n" session)
                                  'face 'bold))
              (insert content)
              (goto-char (point-max))
              (ansi-color-apply-on-region (point-min) (point-max))
              (view-mode 1)
              (setq-local revert-buffer-function
                          (lambda (_ignore-auto _noconfirm)
                            (ogent-gastown-tmux-preview session)))))
          (display-buffer buf))
      (message "Failed to capture pane from %s" session))))

;;; Session List Buffer

(defvar ogent-gastown-tmux-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-gastown-tmux-list-attach)
    (define-key map (kbd "a") #'ogent-gastown-tmux-list-attach)
    (define-key map (kbd "s") #'ogent-gastown-tmux-list-send)
    (define-key map (kbd "p") #'ogent-gastown-tmux-list-preview)
    (define-key map (kbd "g") #'ogent-gastown-tmux-list-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-gastown-tmux-list-mode'.")

(define-derived-mode ogent-gastown-tmux-list-mode special-mode "GT-Tmux"
  "Mode for viewing tmux sessions."
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (ogent-gastown-tmux-sessions))))

(defun ogent-gastown-tmux-list--session-at-point ()
  "Get session name at point."
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^\\(?:\\[GT\\] \\)?\\([^ ]+\\)")
      (match-string 1))))

(defun ogent-gastown-tmux-list-attach ()
  "Attach to session at point."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (ogent-gastown-tmux-attach session)))

(defun ogent-gastown-tmux-list-send ()
  "Send command to session at point."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (let ((command (read-string (format "Command for %s: " session))))
      (ogent-gastown-tmux-send session command))))

(defun ogent-gastown-tmux-list-preview ()
  "Preview session at point."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (ogent-gastown-tmux-preview session)))

(defun ogent-gastown-tmux-list-refresh ()
  "Refresh session list."
  (interactive)
  (ogent-gastown-tmux-refresh-sessions)
  (ogent-gastown-tmux-sessions))

;;;###autoload
(defun ogent-gastown-tmux-sessions ()
  "Show list of tmux sessions in a buffer."
  (interactive)
  (unless (ogent-gastown-tmux-available-p)
    (user-error "tmux not found in PATH"))
  (let* ((sessions (ogent-gastown-tmux-refresh-sessions))
         (buf (get-buffer-create "*Gas Town Tmux*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Tmux Sessions\n" 'face 'bold))
        (insert (make-string 40 ?=) "\n\n")
        (insert (propertize "RET" 'face 'help-key-binding)
                ":attach  "
                (propertize "s" 'face 'help-key-binding)
                ":send  "
                (propertize "p" 'face 'help-key-binding)
                ":preview  "
                (propertize "g" 'face 'help-key-binding)
                ":refresh\n\n")
        (if (null sessions)
            (insert (propertize "No tmux sessions found.\n" 'face 'shadow))
          ;; Group by gastown status
          (let ((gt-sessions (seq-filter (lambda (s) (plist-get s :gastown)) sessions))
                (other-sessions (seq-filter (lambda (s) (not (plist-get s :gastown))) sessions)))
            (when gt-sessions
              (insert (propertize "Gas Town Sessions:\n" 'face 'font-lock-keyword-face))
              (dolist (session gt-sessions)
                (ogent-gastown-tmux--insert-session-line session))
              (insert "\n"))
            (when other-sessions
              (insert (propertize "Other Sessions:\n" 'face 'font-lock-comment-face))
              (dolist (session other-sessions)
                (ogent-gastown-tmux--insert-session-line session)))))
        (goto-char (point-min))
        (ogent-gastown-tmux-list-mode)))
    (display-buffer buf)))

(defun ogent-gastown-tmux--insert-session-line (session)
  "Insert a line for SESSION in the list buffer."
  (let ((name (plist-get session :name))
        (windows (plist-get session :windows))
        (attached (plist-get session :attached))
        (gastown (plist-get session :gastown)))
    (insert "  ")
    (when gastown
      (insert (propertize "[GT] " 'face 'success)))
    (insert (propertize name 'face (if attached 'bold 'default)))
    (insert (propertize (format " (%d windows)" windows)
                        'face 'font-lock-comment-face))
    (when attached
      (insert " " (propertize "[attached]" 'face 'success)))
    (insert "\n")))

;;; Integration Helpers (for ogent-gastown-status.el)

(defun ogent-gastown-tmux-get-sessions-for-status ()
  "Get sessions formatted for status buffer integration.
Returns list of plists with :name :windows :attached :gastown keys."
  (when (ogent-gastown-tmux-available-p)
    (ogent-gastown-tmux--list-sessions)))

(provide 'ogent-gastown-tmux)

;;; ogent-gastown-tmux.el ends here
