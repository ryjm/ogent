;;; ogent-gastown-tmux.el --- Tmux session integration for Gas Town -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides tmux session management for Gas Town workers from within Emacs.
;; Features:
;; - Session picker with completing-read (consult/marginalia compatible)
;; - Attach to sessions via vterm, term, or external terminal
;; - Send commands to sessions (emamux-style targeting)
;; - Session preview via capture-pane
;;
;; Integration:
;; - Adds tmux commands to ogent-gastown-dispatch transient menu
;; - Workers section in ogent-gastown-status becomes actionable
;;
;; Dependencies:
;; - tmux (CLI)
;; - vterm (optional, for embedded terminal attach)

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup ogent-gastown-tmux nil
  "Tmux integration for Gas Town."
  :group 'ogent-gastown
  :prefix "ogent-gastown-tmux-")

;;; Customization

(defcustom ogent-gastown-tmux-executable "tmux"
  "Path to the tmux executable."
  :type 'string
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-attach-method 'vterm
  "Method for attaching to tmux sessions.
- `vterm': Open in a vterm buffer (requires vterm package)
- `term': Open in an Emacs term buffer
- `external': Launch external terminal application"
  :type '(choice (const :tag "VTerm buffer" vterm)
                 (const :tag "Term buffer" term)
                 (const :tag "External terminal" external))
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-external-terminal
  (cond
   ((eq system-type 'darwin) "Terminal.app")
   ((executable-find "kitty") "kitty")
   ((executable-find "alacritty") "alacritty")
   ((executable-find "gnome-terminal") "gnome-terminal")
   (t "xterm"))
  "External terminal application for tmux attach.
Used when `ogent-gastown-tmux-attach-method' is `external'."
  :type 'string
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-preview-lines 50
  "Number of lines to capture for session preview."
  :type 'integer
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-quick-commands
  '(("Check mail" . "gt mail inbox")
    ("Sync beads" . "bd sync")
    ("Show hook" . "gt hook")
    ("Prime session" . "gt prime")
    ("Nudge" . "# Nudge sent"))
  "Quick commands for tmux sessions.
Alist of (LABEL . COMMAND) pairs."
  :type '(alist :key-type string :value-type string)
  :group 'ogent-gastown-tmux)

(defcustom ogent-gastown-tmux-session-prefix "gt-"
  "Prefix for Gas Town tmux sessions.
Sessions matching this prefix are shown in the picker."
  :type 'string
  :group 'ogent-gastown-tmux)

;;; Internal State

(defvar ogent-gastown-tmux--session-cache nil
  "Cached list of tmux sessions.")

(defvar ogent-gastown-tmux--cache-time nil
  "Time when session cache was last updated.")

(defconst ogent-gastown-tmux--cache-ttl 5
  "Cache TTL in seconds.")

;;; Availability

(defun ogent-gastown-tmux-available-p ()
  "Return non-nil if tmux is available."
  (executable-find ogent-gastown-tmux-executable))

;;; Session Data

(defun ogent-gastown-tmux--parse-session-line (line)
  "Parse a tmux session LINE into a plist.
Format: name:windows:attached:activity:created"
  (let ((parts (split-string line ":")))
    (when (>= (length parts) 5)
      (list :name (nth 0 parts)
            :windows (string-to-number (nth 1 parts))
            :attached (not (string= (nth 2 parts) "0"))
            :activity (string-to-number (nth 3 parts))
            :created (string-to-number (nth 4 parts))))))

(defun ogent-gastown-tmux--list-sessions-sync ()
  "List all tmux sessions synchronously.
Returns a list of plists with session info."
  (when (ogent-gastown-tmux-available-p)
    (let ((output (shell-command-to-string
                   (format "%s list-sessions -F '#{session_name}:#{session_windows}:#{session_attached}:#{session_activity}:#{session_created}' 2>/dev/null"
                           ogent-gastown-tmux-executable))))
      (when (and output (not (string-empty-p output)))
        (delq nil
              (mapcar #'ogent-gastown-tmux--parse-session-line
                      (split-string (string-trim output) "\n" t)))))))

(defun ogent-gastown-tmux--get-sessions (&optional force-refresh)
  "Return list of Gas Town tmux sessions.
Uses cache unless FORCE-REFRESH is non-nil or cache is stale.
Sessions are filtered to only show those with `ogent-gastown-tmux-session-prefix'."
  (when (or force-refresh
            (null ogent-gastown-tmux--session-cache)
            (null ogent-gastown-tmux--cache-time)
            (> (float-time (time-subtract (current-time)
                                           ogent-gastown-tmux--cache-time))
               ogent-gastown-tmux--cache-ttl))
    (setq ogent-gastown-tmux--session-cache (ogent-gastown-tmux--list-sessions-sync))
    (setq ogent-gastown-tmux--cache-time (current-time)))
  ;; Filter to Gas Town sessions only
  (seq-filter (lambda (s)
                (string-prefix-p ogent-gastown-tmux-session-prefix
                                 (plist-get s :name)))
              ogent-gastown-tmux--session-cache))

(defun ogent-gastown-tmux-refresh-sessions ()
  "Force refresh session cache and return sessions."
  (ogent-gastown-tmux--get-sessions t))

;;; Session Metadata

(defun ogent-gastown-tmux--parse-session-name (name)
  "Parse a Gas Town session NAME into components.
Returns plist with :rig :role :type or nil if not a GT session."
  (when (string-prefix-p ogent-gastown-tmux-session-prefix name)
    (let* ((stripped (substring name (length ogent-gastown-tmux-session-prefix)))
           (parts (split-string stripped "-")))
      (cond
       ;; gt-<rig>-refinery
       ((and (>= (length parts) 2)
             (string= (car (last parts)) "refinery"))
        (list :rig (string-join (butlast parts) "-")
              :role "refinery"
              :type 'refinery))
       ;; gt-<rig>-witness
       ((and (>= (length parts) 2)
             (string= (car (last parts)) "witness"))
        (list :rig (string-join (butlast parts) "-")
              :role "witness"
              :type 'witness))
       ;; gt-<rig>-<polecat-name>
       ((>= (length parts) 2)
        (list :rig (car parts)
              :role (string-join (cdr parts) "-")
              :type 'polecat))
       ;; gt-<something>
       ((= (length parts) 1)
        (list :rig (car parts)
              :role nil
              :type 'other))
       (t nil)))))

(defun ogent-gastown-tmux--format-session (session)
  "Format SESSION for display in completing-read.
Returns a propertized string with annotations."
  (let* ((name (plist-get session :name))
         (attached (plist-get session :attached))
         (windows (plist-get session :windows))
         (parsed (ogent-gastown-tmux--parse-session-name name))
         (role-type (plist-get parsed :type))
         (role-icon (pcase role-type
                      ('refinery "")
                      ('witness "")
                      ('polecat "")
                      (_ ""))))
    (format "%s %s%s [%d win%s]"
            role-icon
            name
            (if attached " (attached)" "")
            windows
            (if (= windows 1) "" "s"))))

;;; Completing Read

(defun ogent-gastown-tmux--read-session (&optional prompt)
  "Read a tmux session name with completion.
PROMPT is the prompt string, defaults to \"Tmux session: \"."
  (let* ((sessions (ogent-gastown-tmux--get-sessions))
         (candidates (mapcar (lambda (s)
                               (cons (ogent-gastown-tmux--format-session s)
                                     (plist-get s :name)))
                             sessions)))
    (unless candidates
      (user-error "No Gas Town tmux sessions found"))
    (let ((choice (completing-read (or prompt "Tmux session: ")
                                   candidates nil t)))
      (cdr (assoc choice candidates)))))

;;;###autoload
(defun ogent-gastown-tmux-sessions ()
  "Show a list of Gas Town tmux sessions and select one to attach."
  (interactive)
  (let ((session (ogent-gastown-tmux--read-session "Attach to session: ")))
    (ogent-gastown-tmux-attach session)))

;;; Attach to Session

(declare-function vterm "ext:vterm")
(defvar vterm-shell)

(defun ogent-gastown-tmux--attach-vterm (session)
  "Attach to SESSION using vterm."
  (unless (require 'vterm nil t)
    (user-error "vterm package not available; install it or use a different attach method"))
  (let ((buf-name (format "*tmux: %s*" session)))
    (if-let ((existing-buf (get-buffer buf-name)))
        (switch-to-buffer existing-buf)
      (let ((vterm-shell (format "%s attach-session -t %s"
                                 ogent-gastown-tmux-executable
                                 (shell-quote-argument session))))
        (vterm buf-name)))))

(defun ogent-gastown-tmux--attach-term (session)
  "Attach to SESSION using term."
  (let ((buf-name (format "*tmux: %s*" session)))
    (if-let ((existing-buf (get-buffer buf-name)))
        (switch-to-buffer existing-buf)
      (term (format "%s attach-session -t %s"
                    ogent-gastown-tmux-executable
                    (shell-quote-argument session))))))

(defun ogent-gastown-tmux--attach-external (session)
  "Attach to SESSION using external terminal."
  (let ((cmd (pcase ogent-gastown-tmux-external-terminal
               ("Terminal.app"
                (format "open -a Terminal.app %s -new-window '%s attach-session -t %s'"
                        ""
                        ogent-gastown-tmux-executable
                        (shell-quote-argument session)))
               ("kitty"
                (format "kitty --single-instance %s attach-session -t %s &"
                        ogent-gastown-tmux-executable
                        (shell-quote-argument session)))
               ("alacritty"
                (format "alacritty -e %s attach-session -t %s &"
                        ogent-gastown-tmux-executable
                        (shell-quote-argument session)))
               ("gnome-terminal"
                (format "gnome-terminal -- %s attach-session -t %s &"
                        ogent-gastown-tmux-executable
                        (shell-quote-argument session)))
               (_
                (format "%s -e '%s attach-session -t %s' &"
                        ogent-gastown-tmux-external-terminal
                        ogent-gastown-tmux-executable
                        (shell-quote-argument session))))))
    (shell-command cmd)))

;;;###autoload
(defun ogent-gastown-tmux-attach (session)
  "Attach to tmux SESSION using configured method."
  (interactive (list (ogent-gastown-tmux--read-session "Attach to: ")))
  (pcase ogent-gastown-tmux-attach-method
    ('vterm (ogent-gastown-tmux--attach-vterm session))
    ('term (ogent-gastown-tmux--attach-term session))
    ('external (ogent-gastown-tmux--attach-external session))
    (_ (ogent-gastown-tmux--attach-vterm session))))

;;;###autoload
(defun ogent-gastown-tmux-attach-vterm (session)
  "Attach to tmux SESSION using vterm."
  (interactive (list (ogent-gastown-tmux--read-session "Attach via vterm: ")))
  (ogent-gastown-tmux--attach-vterm session))

;;;###autoload
(defun ogent-gastown-tmux-attach-external (session)
  "Attach to tmux SESSION using external terminal."
  (interactive (list (ogent-gastown-tmux--read-session "Attach externally: ")))
  (ogent-gastown-tmux--attach-external session))

;;; Send Command

(defun ogent-gastown-tmux--send-keys (session keys)
  "Send KEYS to tmux SESSION."
  (let ((cmd (format "%s send-keys -t %s %s Enter"
                     ogent-gastown-tmux-executable
                     (shell-quote-argument session)
                     (shell-quote-argument keys))))
    (shell-command cmd)))

;;;###autoload
(defun ogent-gastown-tmux-send (session command)
  "Send COMMAND to tmux SESSION."
  (interactive
   (let* ((session (ogent-gastown-tmux--read-session "Send to session: "))
          (command (read-string "Command: ")))
     (list session command)))
  (ogent-gastown-tmux--send-keys session command)
  (message "Sent to %s: %s" session command))

;;;###autoload
(defun ogent-gastown-tmux-send-quick (session)
  "Send a quick command to SESSION, selected from predefined list."
  (interactive (list (ogent-gastown-tmux--read-session "Send quick command to: ")))
  (let* ((choices ogent-gastown-tmux-quick-commands)
         (choice (completing-read "Quick command: " choices nil t))
         (command (cdr (assoc choice choices))))
    (ogent-gastown-tmux--send-keys session command)
    (message "Sent to %s: %s" session choice)))

;;;###autoload
(defun ogent-gastown-tmux-nudge (session)
  "Send a nudge to SESSION (just press Enter to wake it up)."
  (interactive (list (ogent-gastown-tmux--read-session "Nudge session: ")))
  (let ((cmd (format "%s send-keys -t %s Enter"
                     ogent-gastown-tmux-executable
                     (shell-quote-argument session))))
    (shell-command cmd)
    (message "Nudged: %s" session)))

;;; Session Preview

(defun ogent-gastown-tmux--capture-pane (session &optional lines)
  "Capture recent output from SESSION pane.
LINES defaults to `ogent-gastown-tmux-preview-lines'."
  (let* ((num-lines (or lines ogent-gastown-tmux-preview-lines))
         (cmd (format "%s capture-pane -t %s -p -S -%d 2>/dev/null"
                      ogent-gastown-tmux-executable
                      (shell-quote-argument session)
                      num-lines)))
    (shell-command-to-string cmd)))

;;;###autoload
(defun ogent-gastown-tmux-preview (session)
  "Show a preview of SESSION's pane output in a popup buffer."
  (interactive (list (ogent-gastown-tmux--read-session "Preview session: ")))
  (let* ((content (ogent-gastown-tmux--capture-pane session))
         (buf (get-buffer-create (format "*Tmux Preview: %s*" session))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Session: %s\n" session) 'face 'bold))
        (insert (propertize (format "Captured: %s\n" (format-time-string "%H:%M:%S"))
                            'face 'shadow))
        (insert (make-string 50 ?-) "\n\n")
        (insert (or content "(empty)"))
        (goto-char (point-max))
        (special-mode)))
    (display-buffer buf '((display-buffer-at-bottom)
                          (window-height . 15)))))

;;;###autoload
(defun ogent-gastown-tmux-preview-refresh ()
  "Refresh the current tmux preview buffer."
  (interactive)
  (when (string-prefix-p "*Tmux Preview: " (buffer-name))
    (let ((session (substring (buffer-name) 15 -1)))
      (ogent-gastown-tmux-preview session))))

;;; Session Buffer Mode

(defvar ogent-gastown-tmux-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-gastown-tmux-list-attach)
    (define-key map (kbd "a") #'ogent-gastown-tmux-list-attach)
    (define-key map (kbd "A") #'ogent-gastown-tmux-list-attach-external)
    (define-key map (kbd "s") #'ogent-gastown-tmux-list-send)
    (define-key map (kbd "p") #'ogent-gastown-tmux-list-preview)
    (define-key map (kbd "n") #'ogent-gastown-tmux-list-nudge)
    (define-key map (kbd "g") #'ogent-gastown-tmux-list-sessions)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `ogent-gastown-tmux-list-mode'.")

(define-derived-mode ogent-gastown-tmux-list-mode special-mode "GT-Tmux"
  "Mode for viewing Gas Town tmux sessions."
  :group 'ogent-gastown-tmux
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm)
                (ogent-gastown-tmux-list-sessions))))

(defun ogent-gastown-tmux-list--session-at-point ()
  "Get the session name at point."
  (get-text-property (line-beginning-position) 'ogent-gastown-tmux-session))

(defun ogent-gastown-tmux-list-attach ()
  "Attach to session at point."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (ogent-gastown-tmux-attach session)))

(defun ogent-gastown-tmux-list-attach-external ()
  "Attach to session at point via external terminal."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (ogent-gastown-tmux-attach-external session)))

(defun ogent-gastown-tmux-list-send ()
  "Send command to session at point."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (let ((command (read-string (format "Send to %s: " session))))
      (ogent-gastown-tmux-send session command))))

(defun ogent-gastown-tmux-list-preview ()
  "Preview session at point."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (ogent-gastown-tmux-preview session)))

(defun ogent-gastown-tmux-list-nudge ()
  "Nudge session at point."
  (interactive)
  (when-let ((session (ogent-gastown-tmux-list--session-at-point)))
    (ogent-gastown-tmux-nudge session)))

;;;###autoload
(defun ogent-gastown-tmux-list-sessions ()
  "Display a buffer with Gas Town tmux sessions."
  (interactive)
  (let ((buf (get-buffer-create "*Gas Town Tmux*"))
        (sessions (ogent-gastown-tmux-refresh-sessions)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Gas Town Tmux Sessions\n" 'face 'bold))
        (insert (propertize (format "Last refresh: %s\n" (format-time-string "%H:%M:%S"))
                            'face 'shadow))
        (insert (make-string 60 ?=) "\n\n")
        (insert (propertize "Keybindings: " 'face 'bold))
        (insert "RET:attach  s:send  p:preview  n:nudge  g:refresh  q:quit\n\n")
        (if (null sessions)
            (insert (propertize "No Gas Town sessions found.\n" 'face 'shadow))
          ;; Group by rig
          (let ((by-rig (seq-group-by
                         (lambda (s)
                           (or (plist-get (ogent-gastown-tmux--parse-session-name
                                           (plist-get s :name))
                                          :rig)
                               "other"))
                         sessions)))
            (dolist (rig-group (sort by-rig (lambda (a b) (string< (car a) (car b)))))
              (let ((rig (car rig-group))
                    (rig-sessions (cdr rig-group)))
                (insert (propertize (format "# %s\n" rig) 'face 'bold))
                (dolist (session rig-sessions)
                  (let* ((name (plist-get session :name))
                         (attached (plist-get session :attached))
                         (windows (plist-get session :windows))
                         (parsed (ogent-gastown-tmux--parse-session-name name))
                         (role (plist-get parsed :role))
                         (role-type (plist-get parsed :type))
                         (role-icon (pcase role-type
                                      ('refinery "")
                                      ('witness "")
                                      ('polecat "")
                                      (_ "")))
                         (face (cond
                                (attached 'success)
                                ((eq role-type 'polecat) 'font-lock-function-name-face)
                                ((eq role-type 'refinery) 'font-lock-type-face)
                                ((eq role-type 'witness) 'font-lock-keyword-face)
                                (t nil))))
                    (insert (propertize
                             (format "  %s %-30s %s [%d win%s]\n"
                                     role-icon
                                     (or role name)
                                     (if attached "(attached)" "")
                                     windows
                                     (if (= windows 1) "" "s"))
                             'face face
                             'ogent-gastown-tmux-session name))))
                (insert "\n"))))))
      (goto-char (point-min))
      (ogent-gastown-tmux-list-mode))
    (switch-to-buffer buf)))

;;; Transient Integration

(declare-function transient-define-prefix "ext:transient")
(declare-function transient-define-suffix "ext:transient")

(with-eval-after-load 'transient
  (transient-define-prefix ogent-gastown-tmux-dispatch ()
    "Tmux session management."
    [:description
     (lambda ()
       (let ((count (length (ogent-gastown-tmux--get-sessions))))
         (format "Tmux Sessions (%d active)" count)))
     ["Sessions"
      ("t" "List sessions" ogent-gastown-tmux-list-sessions)
      ("a" "Attach to session" ogent-gastown-tmux-sessions)
      ("A" "Attach (external)" ogent-gastown-tmux-attach-external)]
     ["Actions"
      ("s" "Send command" ogent-gastown-tmux-send)
      ("q" "Quick command" ogent-gastown-tmux-send-quick)
      ("n" "Nudge session" ogent-gastown-tmux-nudge)
      ("p" "Preview pane" ogent-gastown-tmux-preview)]]))

(provide 'ogent-gastown-tmux)

;;; ogent-gastown-tmux.el ends here
