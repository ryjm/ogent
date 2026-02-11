;;; ogent-gastown.el --- Gas Town (gt) integration for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Integrates Gas Town multi-agent workflow system with ogent.
;; Provides:
;; - Hook status display in header-line and mode-line
;; - Mail inbox/read/send commands via transient menu
;; - Convoy awareness for tracking work progress
;; - gt prime integration for session startup
;;
;; Gas Town is a multi-agent workspace manager with:
;; - Mayor: Global coordinator
;; - Witness: Worker lifecycle manager
;; - Refinery: Merge queue processor
;; - Polecats: Worker agents with dedicated worktrees
;;
;; Entry point: `ogent-gastown-dispatch' for the transient menu
;; Automatic: Hook status in header-line when ogent-gastown-mode is active

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'transient)

;; Load faces from gastown-status
(require 'ogent-gastown-status)
(declare-function ogent-gastown--find-town-root "ogent-gastown-status")

;;; Additional Faces (supplement ogent-gastown-status faces)

(defface ogent-gastown-id
  '((((class color) (background light)) :foreground "#546e7a")
    (((class color) (background dark)) :foreground "#81a1c1")
    (t :inherit font-lock-comment-face))
  "Face for IDs (mail IDs, issue IDs, etc.)."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-title
  '((((class color) (background light)) :foreground "#37474f")
    (((class color) (background dark)) :foreground "#d8dee9")
    (t :inherit default))
  "Face for titles and descriptions."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-priority
  '((((class color) (background light)) :foreground "#d84315" :weight bold)
    (((class color) (background dark)) :foreground "#d08770" :weight bold)
    (t :weight bold))
  "Face for priority indicators."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-type
  '((((class color) (background light))
     :foreground "#455a64" :box (:line-width -1 :color "#90a4ae"))
    (((class color) (background dark))
     :foreground "#81a1c1" :box (:line-width -1 :color "#4c566a"))
    (t :inherit font-lock-type-face))
  "Face for type badges."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-transient-title
  '((((class color) (background light)) :foreground "#5d4037" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold)
    (t :weight bold))
  "Face for transient menu titles."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-connected
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c")
    (t :inherit success))
  "Face for connected/active status indicators."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-disconnected
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a")
    (t :inherit shadow))
  "Face for disconnected/inactive status indicators."
  :group 'ogent-gastown-faces)

;; Autoload tmux integration
(autoload 'ogent-gastown-tmux-list-sessions "ogent-gastown-tmux" nil t)
(autoload 'ogent-gastown-tmux-dispatch "ogent-gastown-tmux" nil t)
(autoload 'ogent-gastown-tmux-attach "ogent-gastown-tmux" nil t)
(autoload 'ogent-gastown-tmux-send "ogent-gastown-tmux" nil t)
(autoload 'ogent-gastown-tmux-preview "ogent-gastown-tmux" nil t)

(defgroup ogent-gastown nil
  "Gas Town integration for ogent."
  :group 'ogent)

(defcustom ogent-gastown-gt-executable "gt"
  "Path to the gt executable.
Can be just \"gt\" if it's in PATH, or an absolute path."
  :type 'string
  :group 'ogent-gastown)

(defcustom ogent-gastown-bd-executable "bd"
  "Path to the bd (beads) executable.
Used for issue tracking integration."
  :type 'string
  :group 'ogent-gastown)

(defcustom ogent-gastown-timeout 30
  "Timeout in seconds for gt commands."
  :type 'integer
  :group 'ogent-gastown)

(defcustom ogent-gastown-poll-interval 60
  "Interval in seconds for polling hook and mail status.
Set to 0 to disable automatic polling."
  :type 'integer
  :group 'ogent-gastown)

(defcustom ogent-gastown-show-hook-in-modeline t
  "Whether to show hook status in the mode-line."
  :type 'boolean
  :group 'ogent-gastown)

(defcustom ogent-gastown-integration t
  "Whether to enable Gas Town integration in ogent buffers.
When non-nil and Gas Town is available (gt in PATH, inside a town
workspace), ogent features like issues and header-line can show
Gas Town context such as agent assignments and convoy status."
  :type 'boolean
  :group 'ogent-gastown)

;;; Internal State

(defvar ogent-gastown--hook-cache nil
  "Cached hook status: plist with :id :title :type :status or nil if no hook.")

(defvar ogent-gastown--mail-cache nil
  "Cached mail status: list of unread message plists.")

(defvar ogent-gastown--convoy-cache nil
  "Cached convoy status: list of active convoy plists.")

(defvar ogent-gastown--poll-timer nil
  "Timer for periodic status polling.")

(defvar ogent-gastown--processes nil
  "List of active gt processes for cleanup.")

(defvar ogent-gastown--town-root nil
  "Cached Gas Town root directory, or nil if not in a town.")

;;; Availability Checks

(defun ogent-gastown-available-p ()
  "Return non-nil if gt CLI is available in PATH or at configured location."
  (executable-find ogent-gastown-gt-executable))

(defun ogent-gastown-town-root ()
  "Find the Gas Town root directory.
Returns the town root path or nil if not in a Gas Town workspace.
Uses `ogent-gastown--find-town-root' so workspace rules stay in sync
with `ogent-gastown-status'."
  (or ogent-gastown--town-root
      (setq ogent-gastown--town-root (ogent-gastown--find-town-root))))

(defun ogent-gastown-in-town-p ()
  "Return non-nil if current directory is within a Gas Town workspace."
  (not (null (ogent-gastown-town-root))))

(defvar ogent-gastown--integration-cache nil
  "Cached result of `ogent-gastown-integration-active-p'.
A cons of (TIME . RESULT) where TIME is from `float-time'.
Invalidated by `ogent-gastown-integration-invalidate' or after 5 seconds.")

(defconst ogent-gastown--integration-cache-ttl 5.0
  "Seconds to cache `ogent-gastown-integration-active-p' result.")

;;;###autoload
(defun ogent-gastown-integration-active-p ()
  "Return non-nil when Gas Town integration is fully available.
Checks three conditions:
1. `ogent-gastown-integration' customization is non-nil
2. The gt executable is found in PATH
3. The current directory is inside a Gas Town workspace

The result is cached for `ogent-gastown--integration-cache-ttl'
seconds to avoid repeated `executable-find' calls during
header-line redisplay."
  (let ((now (float-time)))
    (if (and ogent-gastown--integration-cache
             (< (- now (car ogent-gastown--integration-cache))
                ogent-gastown--integration-cache-ttl))
        (cdr ogent-gastown--integration-cache)
      (let ((result (and ogent-gastown-integration
                         (ogent-gastown-available-p)
                         (ogent-gastown-in-town-p)
                         t)))
        (setq ogent-gastown--integration-cache (cons now result))
        result))))

(defun ogent-gastown-integration-invalidate ()
  "Invalidate the cached integration-active-p result.
Call this after changing `ogent-gastown-integration' or when the
environment changes (e.g., entering/leaving a Gas Town workspace)."
  (setq ogent-gastown--integration-cache nil))

;;; Core Async Execution

(defun ogent-gastown--run-async (command args callback &optional error-callback raw-output)
  "Run gt COMMAND with ARGS asynchronously, call CALLBACK with result.
COMMAND is the gt subcommand (e.g., \"hook\", \"mail\").
ARGS is a list of additional command-line arguments.
CALLBACK receives the parsed JSON result (as plist) on success.
ERROR-CALLBACK receives an error message string on failure.
If RAW-OUTPUT is non-nil, pass raw string output instead of parsing JSON.

Returns the process object, or nil if gt is not available."
  (unless (ogent-gastown-available-p)
    (when error-callback
      (funcall error-callback "gt CLI not found"))
    (cl-return-from ogent-gastown--run-async nil))

  (let* ((default-directory (or (ogent-gastown-town-root) default-directory))
         (buffer (generate-new-buffer " *ogent-gt*"))
         (stderr-buffer (generate-new-buffer " *ogent-gt-stderr*"))
         (proc nil)
         (timer nil)
         (full-args (cons command args)))

    ;; Set up timeout timer
    (setq timer
          (run-with-timer
           ogent-gastown-timeout nil
           (lambda ()
             (when (and proc (process-live-p proc))
               (kill-process proc)
               (when error-callback
                 (funcall error-callback
                          (format "gt command timed out after %ds"
                                  ogent-gastown-timeout)))))))

    ;; Start the process
    (let ((full-command (cons ogent-gastown-gt-executable full-args)))
      (setq proc
            (make-process
             :name "ogent-gt"
             :buffer buffer
             :stderr stderr-buffer
             :command full-command
             :sentinel
             (lambda (process event)
               ;; Cancel timeout timer
               (when timer (cancel-timer timer))

               ;; Clean up process list
               (setq ogent-gastown--processes
                     (delq process ogent-gastown--processes))

               (cond
                ;; Success
                ((string= event "finished\n")
                 (with-current-buffer (process-buffer process)
                   (goto-char (point-min))
                   (skip-chars-forward " \t\n\r")
                   (condition-case err
                       (let ((result (if raw-output
                                         (string-trim (buffer-string))
                                       (if (eobp)
                                           nil
                                         (json-parse-buffer
                                          :object-type 'plist
                                          :array-type 'list
                                          :null-object nil
                                          :false-object nil)))))
                         (funcall callback result))
                     (error
                      (if error-callback
                          (funcall error-callback
                                   (format "JSON parse error: %s"
                                           (error-message-string err)))
                        (message "ogent-gt: JSON parse error: %s"
                                 (error-message-string err))))))
                 ;; Clean up buffers
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                ;; Process exited with error
                ((string-match "exited abnormally" event)
                 (let ((stderr-content
                        (when (buffer-live-p stderr-buffer)
                          (with-current-buffer stderr-buffer
                            (string-trim (buffer-string))))))
                   (if error-callback
                       (funcall error-callback
                                (or stderr-content
                                    (format "gt command failed: %s" event)))
                     (message "ogent-gt error: %s" (or stderr-content event))))
                 ;; Clean up buffers
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                ;; Other events (killed, etc.)
                (t
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))))))))

    ;; Track process for cleanup
    (push proc ogent-gastown--processes)
    proc))

;;; Hook Status API

(defun ogent-gastown-hook-refresh (&optional callback)
  "Refresh hook status asynchronously.
If CALLBACK is provided, call it with the hook plist when done."
  (ogent-gastown--run-async
   "hook" '("--json")
   (lambda (result)
     (setq ogent-gastown--hook-cache result)
     (force-mode-line-update t)
     (when callback (funcall callback result)))
   (lambda (err)
     (setq ogent-gastown--hook-cache nil)
     (message "Failed to get hook status: %s" err))))

(defun ogent-gastown-hook-status ()
  "Return cached hook status or nil."
  ogent-gastown--hook-cache)

(defun ogent-gastown-hook-id ()
  "Return the hooked bead ID, or nil if no hook."
  (plist-get ogent-gastown--hook-cache :id))

(defun ogent-gastown-hook-title ()
  "Return the hooked bead title, or nil if no hook."
  (plist-get ogent-gastown--hook-cache :title))

;;; Mail API

(defun ogent-gastown-mail-refresh (&optional callback)
  "Refresh mail inbox status asynchronously.
If CALLBACK is provided, call it with the mail list when done."
  (ogent-gastown--run-async
   "mail" '("inbox" "--json")
   (lambda (result)
     (setq ogent-gastown--mail-cache result)
     (force-mode-line-update t)
     (when callback (funcall callback result)))
   (lambda (err)
     (setq ogent-gastown--mail-cache nil)
     (message "Failed to get mail: %s" err))))

(defun ogent-gastown-mail-unread-count ()
  "Return the number of unread messages."
  (length (seq-filter (lambda (m) (not (plist-get m :read)))
                      ogent-gastown--mail-cache)))

(defun ogent-gastown-mail-read (mail-id &optional callback)
  "Read mail with MAIL-ID, calling CALLBACK with the message content.
If CALLBACK is nil, display the mail in a buffer."
  (ogent-gastown--run-async
   "mail" (list "read" mail-id "--json")
   (or callback
       (lambda (msg)
         (let ((buf (get-buffer-create (format "*Mail: %s*" mail-id))))
           (with-current-buffer buf
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert (format "From: %s\n" (plist-get msg :from)))
               (insert (format "To: %s\n" (plist-get msg :to)))
               (insert (format "Subject: %s\n" (plist-get msg :subject)))
               (insert (format "Date: %s\n" (plist-get msg :date)))
               (insert "\n")
               (insert (or (plist-get msg :body) "(empty)"))
               (goto-char (point-min))
               (view-mode 1)))
           (display-buffer buf))))
   (lambda (err)
     (message "Failed to read mail %s: %s" mail-id err))))

(defun ogent-gastown-mail-send (recipient subject body callback)
  "Send mail to RECIPIENT with SUBJECT and BODY.
CALLBACK is called on success with the result."
  (ogent-gastown--run-async
   "mail" (list "send" recipient "-s" subject "-m" body)
   (lambda (_result)
     (message "Mail sent to %s" recipient)
     (when callback (funcall callback)))
   (lambda (err)
     (message "Failed to send mail: %s" err))
   t))

;;; Convoy API

(defun ogent-gastown-convoy-refresh (&optional callback)
  "Refresh convoy status asynchronously.
If CALLBACK is provided, call it with the convoy list when done."
  (ogent-gastown--run-async
   "convoy" '("list" "--json")
   (lambda (result)
     (setq ogent-gastown--convoy-cache result)
     (when callback (funcall callback result)))
   (lambda (err)
     (setq ogent-gastown--convoy-cache nil)
     (message "Failed to get convoy status: %s" err))))

(defun ogent-gastown-convoy-active ()
  "Return list of active convoys."
  ogent-gastown--convoy-cache)

;;; Session Integration

(defun ogent-gastown-prime ()
  "Run gt prime to initialize session context.
This loads the hooked work and prepares the session."
  (interactive)
  (if (ogent-gastown-in-town-p)
      (progn
        (message "Running gt prime...")
        (ogent-gastown--run-async
         "prime" nil
         (lambda (_result)
           (message "Gas Town session initialized")
           ;; Refresh hook and mail after prime
           (ogent-gastown-hook-refresh)
           (ogent-gastown-mail-refresh))
         (lambda (err)
           (message "gt prime failed: %s" err))
         t))
    (message "Not in a Gas Town workspace")))

(defun ogent-gastown-done ()
  "Signal work completion with gt done.
This syncs beads and submits to the merge queue."
  (interactive)
  (if (ogent-gastown-in-town-p)
      (progn
        (when (yes-or-no-p "Mark work as done and submit to merge queue? ")
          (message "Running gt done...")
          (ogent-gastown--run-async
           "done" nil
           (lambda (_result)
             (message "Work submitted to merge queue")
             (ogent-gastown-hook-refresh))
           (lambda (err)
             (message "gt done failed: %s" err))
           t)))
    (message "Not in a Gas Town workspace")))

;;; Mode-line Integration

(defvar ogent-gastown--mode-line-string ""
  "Mode-line string showing hook status.")

(defun ogent-gastown--update-mode-line ()
  "Update the mode-line string with hook status."
  (setq ogent-gastown--mode-line-string
        (if-let ((hook ogent-gastown--hook-cache))
            (let ((id (plist-get hook :id))
                  (title (plist-get hook :title)))
              (propertize
               (format " [⚓ %s]" (or id "hooked"))
               'face 'ogent-gastown-hook-active
               'help-echo (or title "Hooked work")))
          "")))

;;; Header-line Integration

(defun ogent-gastown--format-header-line ()
  "Format header-line string showing Gas Town status."
  (if-let ((hook ogent-gastown--hook-cache))
      (let* ((id (plist-get hook :id))
             (title (plist-get hook :title))
             (mail-count (ogent-gastown-mail-unread-count)))
        (concat
         (propertize "Gas Town" 'face 'ogent-gastown-section-heading)
         " | "
         (propertize "⚓ " 'face 'ogent-gastown-hook-active)
         (propertize (or id "hooked") 'face 'ogent-gastown-id)
         " "
         (when title
           (propertize (truncate-string-to-width title 30 nil nil "…")
                       'face 'ogent-gastown-title))
         (when (> mail-count 0)
           (concat " | "
                   (propertize (format "📬 %d" mail-count)
                               'face 'ogent-gastown-mail-unread)))))
    (concat
     (propertize "Gas Town" 'face 'ogent-gastown-section-heading)
     " | "
     (propertize "no hook" 'face 'ogent-gastown-hook-empty))))

;;; Polling Timer

(defun ogent-gastown--start-polling ()
  "Start the status polling timer."
  (ogent-gastown--stop-polling)
  (when (> ogent-gastown-poll-interval 0)
    (setq ogent-gastown--poll-timer
          (run-at-time ogent-gastown-poll-interval
                       ogent-gastown-poll-interval
                       #'ogent-gastown--poll))))

(defun ogent-gastown--stop-polling ()
  "Stop the status polling timer."
  (when ogent-gastown--poll-timer
    (cancel-timer ogent-gastown--poll-timer)
    (setq ogent-gastown--poll-timer nil)))

(defun ogent-gastown--poll ()
  "Poll for status updates."
  (when (ogent-gastown-in-town-p)
    (ogent-gastown-hook-refresh)
    (ogent-gastown-mail-refresh)))

;;; Interactive Commands

;;;###autoload
(defun ogent-gastown-show-hook ()
  "Show the current hooked work in a buffer."
  (interactive)
  (if-let ((hook (ogent-gastown-hook-status)))
      (let ((buf (get-buffer-create "*Gas Town Hook*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (propertize "Hooked Work\n" 'face 'ogent-gastown-section-heading))
            (insert (make-string 40 ?=) "\n\n")
            (insert (format "ID: %s\n" (plist-get hook :id)))
            (insert (format "Title: %s\n" (plist-get hook :title)))
            (insert (format "Status: %s\n" (plist-get hook :status)))
            (insert (format "Type: %s\n" (plist-get hook :type)))
            (when-let ((desc (plist-get hook :description)))
              (insert "\nDescription:\n")
              (insert desc))
            (goto-char (point-min))
            (view-mode 1)))
        (display-buffer buf))
    (message "No work hooked")))

;;;###autoload
(defun ogent-gastown-show-mail ()
  "Show mail inbox in a buffer."
  (interactive)
  (ogent-gastown-mail-refresh
   (lambda (mail)
     (let ((buf (get-buffer-create "*Gas Town Mail*")))
       (with-current-buffer buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (propertize "Mail Inbox\n" 'face 'ogent-gastown-section-heading))
           (insert (make-string 40 ?=) "\n\n")
           (if (null mail)
               (insert "No messages.\n")
             (dolist (m mail)
               (let ((id (plist-get m :id))
                     (from (plist-get m :from))
                     (subject (plist-get m :subject))
                     (read (plist-get m :read)))
                 (insert (if read "  " "● "))
                 (insert (propertize (or id "?") 'face 'ogent-gastown-id))
                 (insert " ")
                 (insert (propertize (or from "unknown") 'face 'ogent-gastown-mail-from))
                 (insert ": ")
                 (insert (or subject "(no subject)"))
                 (insert "\n"))))
           (goto-char (point-min))
           (ogent-gastown-mail-mode)))
       (display-buffer buf)))))

;;;###autoload
(defun ogent-gastown-send-mail ()
  "Compose and send mail."
  (interactive)
  (let* ((recipient (read-string "To: "))
         (subject (read-string "Subject: "))
         (body (read-string "Message: ")))
    (when (and (not (string-empty-p recipient))
               (not (string-empty-p subject)))
      (ogent-gastown-mail-send recipient subject body
                               #'ogent-gastown-mail-refresh))))

;;;###autoload
(defun ogent-gastown-show-convoy ()
  "Show convoy status in a buffer."
  (interactive)
  (ogent-gastown-convoy-refresh
   (lambda (convoys)
     (let ((buf (get-buffer-create "*Gas Town Convoys*")))
       (with-current-buffer buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (propertize "Active Convoys\n" 'face 'ogent-gastown-section-heading))
           (insert (make-string 40 ?=) "\n\n")
           (if (null convoys)
               (insert "No active convoys.\n")
             (dolist (c convoys)
               (let ((id (plist-get c :id))
                     (name (plist-get c :name))
                     (status (plist-get c :status))
                     (progress (plist-get c :progress)))
                 (insert (propertize (or id "?") 'face 'ogent-gastown-id))
                 (insert " ")
                 (insert (propertize (or name "unnamed") 'face 'ogent-gastown-convoy-active))
                 (insert " [")
                 (insert (or status "unknown"))
                 (insert "]")
                 (when progress
                   (insert (format " %d%%" progress)))
                 (insert "\n"))))
           (goto-char (point-min))
           (view-mode 1)))
       (display-buffer buf)))))

;;; Mail Mode

(defvar ogent-gastown-mail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-gastown-mail-read-at-point)
    (define-key map (kbd "r") #'ogent-gastown-mail-reply-at-point)
    (define-key map (kbd "c") #'ogent-gastown-send-mail)
    (define-key map (kbd "g") #'ogent-gastown-show-mail)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-gastown-mail-mode'.")

(define-derived-mode ogent-gastown-mail-mode special-mode "GT-Mail"
  "Mode for viewing Gas Town mail."
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (ogent-gastown-show-mail))))

(defun ogent-gastown-mail-read-at-point ()
  "Read the mail message at point."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^[● ] \\([^ ]+\\)")
      (let ((mail-id (match-string 1)))
        (ogent-gastown-mail-read
         mail-id
         (lambda (msg)
           (let ((buf (get-buffer-create (format "*Mail: %s*" mail-id))))
             (with-current-buffer buf
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (format "From: %s\n" (plist-get msg :from)))
                 (insert (format "To: %s\n" (plist-get msg :to)))
                 (insert (format "Subject: %s\n" (plist-get msg :subject)))
                 (insert (format "Date: %s\n" (plist-get msg :date)))
                 (insert "\n")
                 (insert (or (plist-get msg :body) "(empty)"))
                 (goto-char (point-min))
                 (view-mode 1)))
             (display-buffer buf))))))))

(defun ogent-gastown-mail-reply-at-point ()
  "Reply to the mail message at point."
  (interactive)
  (save-excursion
    (beginning-of-line)
    (when (looking-at "^[● ] \\([^ ]+\\) \\([^:]+\\):")
      (let* ((_mail-id (match-string 1))  ; Unused but extracted for future use
             (from (match-string 2))
             (subject (read-string "Subject: " (concat "Re: ")))
             (body (read-string "Message: ")))
        (ogent-gastown-mail-send from subject body
                                 #'ogent-gastown-show-mail)))))

;;; Beads (bd) Integration

(defvar ogent-gastown--bd-ready-cache nil
  "Cached ready issues: list of issue plists.")

(defvar ogent-gastown--bd-processes nil
  "List of active bd processes for cleanup.")

(defun ogent-gastown-bd-available-p ()
  "Return non-nil if bd CLI is available."
  (executable-find ogent-gastown-bd-executable))

(defun ogent-gastown-bd--run-async (args callback &optional error-callback raw-output)
  "Run bd with ARGS asynchronously, call CALLBACK with result.
ARGS is a list of command-line arguments.
CALLBACK receives the parsed JSON result (as plist) on success.
ERROR-CALLBACK receives an error message string on failure.
If RAW-OUTPUT is non-nil, pass raw string output instead of parsing JSON.

Returns the process object, or nil if bd is not available."
  (unless (ogent-gastown-bd-available-p)
    (when error-callback
      (funcall error-callback "bd CLI not found"))
    (cl-return-from ogent-gastown-bd--run-async nil))

  (let* ((buffer (generate-new-buffer " *ogent-bd*"))
         (stderr-buffer (generate-new-buffer " *ogent-bd-stderr*"))
         (proc nil)
         (timer nil))

    ;; Set up timeout timer
    (setq timer
          (run-with-timer
           ogent-gastown-timeout nil
           (lambda ()
             (when (and proc (process-live-p proc))
               (kill-process proc)
               (when error-callback
                 (funcall error-callback
                          (format "bd command timed out after %ds"
                                  ogent-gastown-timeout)))))))

    ;; Start the process
    (let ((full-command (cons ogent-gastown-bd-executable args)))
      (setq proc
            (make-process
             :name "ogent-bd"
             :buffer buffer
             :stderr stderr-buffer
             :command full-command
             :sentinel
             (lambda (process event)
               ;; Cancel timeout timer
               (when timer (cancel-timer timer))

               ;; Clean up process list
               (setq ogent-gastown--bd-processes
                     (delq process ogent-gastown--bd-processes))

               (cond
                ;; Success
                ((string= event "finished\n")
                 (with-current-buffer (process-buffer process)
                   (goto-char (point-min))
                   (skip-chars-forward " \t\n\r")
                   (condition-case err
                       (let ((result (if raw-output
                                         (string-trim (buffer-string))
                                       (if (eobp)
                                           nil
                                         (json-parse-buffer
                                          :object-type 'plist
                                          :array-type 'list
                                          :null-object nil
                                          :false-object nil)))))
                         (funcall callback result))
                     (error
                      (if error-callback
                          (funcall error-callback
                                   (format "JSON parse error: %s"
                                           (error-message-string err)))
                        (message "ogent-bd: JSON parse error: %s"
                                 (error-message-string err))))))
                 ;; Clean up buffers
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                ;; Process exited with error
                ((string-match "exited abnormally" event)
                 (let ((stderr-content
                        (when (buffer-live-p stderr-buffer)
                          (with-current-buffer stderr-buffer
                            (string-trim (buffer-string))))))
                   (if error-callback
                       (funcall error-callback
                                (or stderr-content
                                    (format "bd command failed: %s" event)))
                     (message "ogent-bd error: %s" (or stderr-content event))))
                 ;; Clean up buffers
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                ;; Other events
                (t
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))))))))

    ;; Track process for cleanup
    (push proc ogent-gastown--bd-processes)
    proc))

;;; Beads API

(defun ogent-gastown-bd-ready-refresh (&optional callback)
  "Refresh ready issues asynchronously.
If CALLBACK is provided, call it with the issues list when done."
  (ogent-gastown-bd--run-async
   '("ready" "--json")
   (lambda (result)
     (setq ogent-gastown--bd-ready-cache result)
     (when callback (funcall callback result)))
   (lambda (err)
     (setq ogent-gastown--bd-ready-cache nil)
     (message "Failed to get ready issues: %s" err))))

(defun ogent-gastown-bd-show (id callback &optional error-callback)
  "Get issue details for ID, calling CALLBACK with the result."
  (ogent-gastown-bd--run-async
   (list "show" id "--json")
   callback
   (or error-callback
       (lambda (err)
         (message "Failed to get issue %s: %s" id err)))))

(defun ogent-gastown-bd-update (id status callback &optional error-callback)
  "Update issue ID to STATUS, calling CALLBACK on success."
  (ogent-gastown-bd--run-async
   (list "update" id (format "--status=%s" status))
   (lambda (_result)
     (message "Updated %s to %s" id status)
     (ogent-gastown-bd-ready-refresh)
     (when callback (funcall callback)))
   (or error-callback
       (lambda (err)
         (message "Failed to update %s: %s" id err)))
   t))

(defun ogent-gastown-bd-close (id reason callback &optional error-callback)
  "Close issue ID with REASON, calling CALLBACK on success."
  (ogent-gastown-bd--run-async
   (list "close" id (format "--reason=%s" reason))
   (lambda (_result)
     (message "Closed %s" id)
     (ogent-gastown-bd-ready-refresh)
     (when callback (funcall callback)))
   (or error-callback
       (lambda (err)
         (message "Failed to close %s: %s" id err)))
   t))

;;; Beads Interactive Commands

;;;###autoload
(defun ogent-gastown-show-ready ()
  "Show ready issues in a buffer."
  (interactive)
  (ogent-gastown-bd-ready-refresh
   (lambda (issues)
     (let ((buf (get-buffer-create "*Beads Ready*")))
       (with-current-buffer buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (propertize "Ready Work\n" 'face 'ogent-gastown-section-heading))
           (insert (make-string 50 ?=) "\n\n")
           (if (null issues)
               (insert "No ready issues.\n")
             (dolist (issue issues)
               (let ((id (plist-get issue :id))
                     (title (plist-get issue :title))
                     (priority (plist-get issue :priority))
                     (type (plist-get issue :issue_type)))
                 (insert (propertize (format "[P%s]" (or priority "?"))
                                     'face 'ogent-gastown-priority))
                 (insert " ")
                 (insert (propertize (or id "?") 'face 'ogent-gastown-id))
                 (insert " ")
                 (when type
                   (insert (propertize (format "[%s]" type)
                                       'face 'ogent-gastown-type))
                   (insert " "))
                 (insert (or title "(no title)"))
                 (insert "\n"))))
           (goto-char (point-min))
           (ogent-gastown-bd-ready-mode)))
       (display-buffer buf)))))

;;;###autoload
(defun ogent-gastown-show-issue (id)
  "Show issue details for ID in a buffer."
  (interactive "sIssue ID: ")
  (ogent-gastown-bd-show
   id
   (lambda (issue)
     (let ((buf (get-buffer-create (format "*Beads: %s*" id))))
       (with-current-buffer buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert (propertize (format "%s\n" (or (plist-get issue :title) id))
                               'face 'ogent-gastown-section-heading))
           (insert (make-string 50 ?=) "\n\n")
           (insert (format "ID: %s\n" (plist-get issue :id)))
           (insert (format "Status: %s\n" (plist-get issue :status)))
           (insert (format "Priority: P%s\n" (or (plist-get issue :priority) "?")))
           (insert (format "Type: %s\n" (or (plist-get issue :issue_type) "?")))
           (when-let ((created (plist-get issue :created_at)))
             (insert (format "Created: %s\n" created)))
           (when-let ((desc (plist-get issue :description)))
             (insert "\nDescription:\n")
             (insert desc))
           (goto-char (point-min))
           (ogent-gastown-bd-issue-mode)
           (setq-local ogent-gastown-bd--current-issue-id id)))
       (display-buffer buf)))))

;;;###autoload
(defun ogent-gastown-claim-issue (id)
  "Claim issue ID by setting status to in_progress."
  (interactive "sIssue ID: ")
  (ogent-gastown-bd-update id "in_progress" nil))

;;;###autoload
(defun ogent-gastown-close-issue (id reason)
  "Close issue ID with REASON."
  (interactive "sIssue ID: \nsReason: ")
  (ogent-gastown-bd-close id reason nil))

;;; Beads Ready Mode

(defvar ogent-gastown-bd-ready-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-gastown-bd-ready-show-at-point)
    (define-key map (kbd "s") #'ogent-gastown-bd-ready-start-at-point)
    (define-key map (kbd "g") #'ogent-gastown-show-ready)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-gastown-bd-ready-mode'.")

(define-derived-mode ogent-gastown-bd-ready-mode special-mode "BD-Ready"
  "Mode for viewing ready issues."
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (ogent-gastown-show-ready))))

(defun ogent-gastown-bd-ready--id-at-point ()
  "Extract issue ID from current line."
  (save-excursion
    (beginning-of-line)
    (when (re-search-forward "\\[P[0-4?]\\] \\([^ ]+\\)" (line-end-position) t)
      (match-string 1))))

(defun ogent-gastown-bd-ready-show-at-point ()
  "Show details of issue at point."
  (interactive)
  (when-let ((id (ogent-gastown-bd-ready--id-at-point)))
    (ogent-gastown-show-issue id)))

(defun ogent-gastown-bd-ready-start-at-point ()
  "Start working on issue at point."
  (interactive)
  (when-let ((id (ogent-gastown-bd-ready--id-at-point)))
    (ogent-gastown-claim-issue id)))

;;; Beads Issue Mode

(defvar-local ogent-gastown-bd--current-issue-id nil
  "Current issue ID in this buffer.")

(defvar ogent-gastown-bd-issue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'ogent-gastown-bd-issue-start)
    (define-key map (kbd "c") #'ogent-gastown-bd-issue-close)
    (define-key map (kbd "g") #'ogent-gastown-bd-issue-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-gastown-bd-issue-mode'.")

(define-derived-mode ogent-gastown-bd-issue-mode special-mode "BD-Issue"
  "Mode for viewing issue details."
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (when ogent-gastown-bd--current-issue-id
                  (ogent-gastown-show-issue ogent-gastown-bd--current-issue-id)))))

(defun ogent-gastown-bd-issue-start ()
  "Start working on the current issue."
  (interactive)
  (when ogent-gastown-bd--current-issue-id
    (ogent-gastown-claim-issue ogent-gastown-bd--current-issue-id)))

(defun ogent-gastown-bd-issue-close ()
  "Close the current issue."
  (interactive)
  (when ogent-gastown-bd--current-issue-id
    (let ((reason (read-string "Close reason: ")))
      (ogent-gastown-close-issue ogent-gastown-bd--current-issue-id reason))))

(defun ogent-gastown-bd-issue-refresh ()
  "Refresh the current issue."
  (interactive)
  (when ogent-gastown-bd--current-issue-id
    (ogent-gastown-show-issue ogent-gastown-bd--current-issue-id)))

;;; Transient Menu

;;;###autoload (autoload 'ogent-gastown-dispatch "ogent-gastown" nil t)
(transient-define-prefix ogent-gastown-dispatch ()
  "Gas Town command dispatch menu."
  [:description
   (lambda ()
     (concat
      (propertize "Gas Town" 'face 'ogent-gastown-transient-title)
      (if (ogent-gastown-in-town-p)
          (concat " " (propertize "● connected" 'face 'ogent-gastown-connected))
        (concat " " (propertize "○ not in town" 'face 'ogent-gastown-disconnected)))))

   ["Hook"
    ("h" "Show hook" ogent-gastown-show-hook)
    ("H" "Refresh hook" ogent-gastown-hook-refresh)]

   ["Mail"
    ("m" "Inbox" ogent-gastown-show-mail)
    ("c" "Compose" ogent-gastown-send-mail)
    ("M" "Refresh mail" ogent-gastown-mail-refresh)]

   ["Convoy"
    ("v" "Show convoys" ogent-gastown-show-convoy)
    ("V" "Refresh convoys" ogent-gastown-convoy-refresh)]

   ["Beads"
    ("b" "Ready work" ogent-gastown-show-ready)
    ("i" "Show issue" ogent-gastown-show-issue)
    ("s" "Start issue" ogent-gastown-claim-issue)
    ("k" "Close issue" ogent-gastown-close-issue)]

   ["Tmux"
    ("t" "List sessions" ogent-gastown-tmux-list-sessions)
    ("T" "Tmux menu..." ogent-gastown-tmux-dispatch)]]

  [["Session"
    ("p" "Prime (init)" ogent-gastown-prime)
    ("d" "Done (submit)" ogent-gastown-done)]

   ["Quit"
    ("q" "Quit" transient-quit-one)]])

;;; Minor Mode

(defvar ogent-gastown--original-header-line nil
  "Original header-line-format before enabling gastown mode.")

;;;###autoload
(define-minor-mode ogent-gastown-mode
  "Minor mode showing Gas Town status in header-line.
Displays hook status, mail count, and provides quick access
to Gas Town commands."
  :lighter " GT"
  :global nil
  (if ogent-gastown-mode
      (progn
        ;; Save and set header-line
        (setq-local ogent-gastown--original-header-line header-line-format)
        (setq-local header-line-format
                    '(:eval (ogent-gastown--format-header-line)))
        ;; Initial refresh
        (when (ogent-gastown-in-town-p)
          (ogent-gastown-hook-refresh)
          (ogent-gastown-mail-refresh))
        ;; Start polling
        (ogent-gastown--start-polling)
        ;; Add to mode-line if configured
        (when ogent-gastown-show-hook-in-modeline
          (ogent-gastown--update-mode-line)
          (add-to-list 'mode-line-misc-info
                       '(:eval ogent-gastown--mode-line-string))))
    ;; Restore header-line
    (setq-local header-line-format ogent-gastown--original-header-line)
    (setq-local ogent-gastown--original-header-line nil)
    ;; Stop polling
    (ogent-gastown--stop-polling)
    ;; Remove from mode-line
    (setq mode-line-misc-info
          (delete '(:eval ogent-gastown--mode-line-string) mode-line-misc-info))))

;;;###autoload
(define-globalized-minor-mode ogent-gastown-global-mode
  ogent-gastown-mode
  (lambda ()
    (when (ogent-gastown-in-town-p)
      (ogent-gastown-mode 1)))
  :group 'ogent-gastown)

;;; Cleanup

(defun ogent-gastown-cleanup ()
  "Kill all active gt and bd processes and clear cache."
  (interactive)
  ;; Clean up gt processes
  (dolist (proc ogent-gastown--processes)
    (when (process-live-p proc)
      (kill-process proc)))
  (setq ogent-gastown--processes nil)
  ;; Clean up bd processes
  (dolist (proc ogent-gastown--bd-processes)
    (when (process-live-p proc)
      (kill-process proc)))
  (setq ogent-gastown--bd-processes nil)
  ;; Clear all caches
  (setq ogent-gastown--hook-cache nil)
  (setq ogent-gastown--mail-cache nil)
  (setq ogent-gastown--convoy-cache nil)
  (setq ogent-gastown--bd-ready-cache nil)
  (setq ogent-gastown--town-root nil)
  (ogent-gastown--stop-polling)
  (message "ogent-gastown: Cleaned up"))

;;; Agent Assignment Mapping (for issues integration)

(defvar ogent-gastown--agent-assignments-cache nil
  "Cached hash table mapping bead-id to list of (agent-name . agent-type) pairs.
Built from crew and polecat list data.")

(defvar ogent-gastown--agent-assignments-timestamp nil
  "Time when agent assignments were last fetched.")

(defun ogent-gastown-agent-assignments ()
  "Return the cached agent assignments hash table, or nil."
  ogent-gastown--agent-assignments-cache)

(defun ogent-gastown-agent-assignments-stale-p ()
  "Return non-nil if agent assignments cache is stale or missing."
  (or (null ogent-gastown--agent-assignments-cache)
      (null ogent-gastown--agent-assignments-timestamp)
      (> (- (float-time) ogent-gastown--agent-assignments-timestamp)
         ogent-gastown--integration-cache-ttl)))

(defun ogent-gastown-fetch-agent-assignments (callback)
  "Fetch crew and polecat lists, build agent→bead mapping, call CALLBACK.
CALLBACK receives the hash table mapping bead-id → list of
\(agent-name . agent-type) pairs."
  (unless (ogent-gastown-integration-active-p)
    (when callback (funcall callback nil))
    (cl-return-from ogent-gastown-fetch-agent-assignments nil))

  (let* ((pending 2)
         (results (make-hash-table :test #'equal))
         (assignments (make-hash-table :test #'equal))
         (finish
          (lambda ()
            (cl-decf pending)
            (when (zerop pending)
              ;; Build bead-id → agents mapping from crew data
              (dolist (member (gethash 'crew results))
                (let ((name (plist-get member :name))
                      (hooked (or (plist-get member :hooked_work)
                                  (plist-get member :issue))))
                  (when (and name hooked (not (string-empty-p hooked)))
                    (let ((existing (gethash hooked assignments)))
                      (puthash hooked
                               (cons (cons name "crew") existing)
                               assignments)))))
              ;; Build bead-id → agents mapping from polecat data
              (dolist (polecat (gethash 'polecat results))
                (let ((name (plist-get polecat :name))
                      (hooked (or (plist-get polecat :hooked_work)
                                  (plist-get polecat :issue)
                                  (plist-get polecat :current_task))))
                  (when (and name hooked (not (string-empty-p hooked)))
                    (let ((existing (gethash hooked assignments)))
                      (puthash hooked
                               (cons (cons name "polecat") existing)
                               assignments)))))
              ;; Update cache
              (setq ogent-gastown--agent-assignments-cache assignments)
              (setq ogent-gastown--agent-assignments-timestamp (float-time))
              (when callback (funcall callback assignments))))))

    ;; Fetch crew list
    (ogent-gastown--run-async
     "crew" '("list" "--json")
     (lambda (result)
       (puthash 'crew (if (listp result) result nil) results)
       (funcall finish))
     (lambda (_err)
       (puthash 'crew nil results)
       (funcall finish)))

    ;; Fetch polecat list
    (ogent-gastown--run-async
     "polecat" '("list" "--all" "--json")
     (lambda (result)
       (puthash 'polecat (if (listp result) result nil) results)
       (funcall finish))
     (lambda (_err)
       (puthash 'polecat nil results)
       (funcall finish)))))

(defun ogent-gastown-lookup-agent-assignment (bead-id)
  "Look up agent assignments for BEAD-ID in the cache.
Returns a list of (agent-name . agent-type) pairs, or nil."
  (when ogent-gastown--agent-assignments-cache
    (gethash bead-id ogent-gastown--agent-assignments-cache)))

(defun ogent-gastown-format-agent-assignment (bead-id)
  "Return a formatted string for agents assigned to BEAD-ID, or nil.
Format: \" → name\" for single agent, \" → name +N\" for multiple."
  (when-let ((agents (ogent-gastown-lookup-agent-assignment bead-id)))
    (let* ((first-name (car (car agents)))
           (count (length agents)))
      (if (= count 1)
          (format " → %s" first-name)
        (format " → %s +%d" first-name (1- count))))))

(provide 'ogent-gastown)

;;; ogent-gastown.el ends here
