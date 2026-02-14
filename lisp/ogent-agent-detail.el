;;; ogent-agent-detail.el --- Structured agent detail buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides dedicated magit-section based buffers for inspecting crew members
;; and polecats.  Replaces raw shell output with structured, navigable detail
;; views following the ogent-convoy.el inspector pattern.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'json)
(require 'ogent-ops-style)

;; Soft dependency on magit-section
(eval-and-compile
  (defvar ogent-agent-detail--magit-section-available
    (require 'magit-section nil t)
    "Non-nil if magit-section is available.")
  (when ogent-agent-detail--magit-section-available
    (require 'magit-section)))

;; Declare magit functions to avoid byte-compile warnings
(declare-function magit-insert-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-section-forward "ext:magit-section")
(declare-function magit-section-backward "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-current-section "ext:magit-section")

;; Autoloads for bead drill-down
(autoload 'ogent-issues-bd-get "ogent-issues-bd" nil nil)
(autoload 'ogent-issues--show-detail "ogent-issues" nil nil)

;;; Customization

(defgroup ogent-agent-detail nil
  "Agent detail inspector."
  :group 'ogent
  :prefix "ogent-agent-detail-")

(defcustom ogent-agent-detail-gt-executable "gt"
  "Path to the gt executable."
  :type 'string
  :group 'ogent-agent-detail)

(defcustom ogent-agent-detail-timeout 15
  "Timeout in seconds for gt commands."
  :type 'integer
  :group 'ogent-agent-detail)

;;; Faces

(defgroup ogent-agent-detail-faces nil
  "Faces for ogent-agent-detail."
  :group 'ogent-agent-detail
  :group 'faces)

(defface ogent-agent-detail-section-heading
  '((((class color) (background light)) :foreground "#4271ae" :weight bold)
    (((class color) (background dark)) :foreground "#81a1c1" :weight bold)
    (t :weight bold))
  "Face for section headings."
  :group 'ogent-agent-detail-faces)

(defface ogent-agent-detail-label
  '((((class color) (background light)) :foreground "#8e8e93")
    (((class color) (background dark)) :foreground "#6c7086")
    (t :inherit shadow))
  "Face for field labels."
  :group 'ogent-agent-detail-faces)

(defface ogent-agent-detail-value
  '((t :inherit default))
  "Face for field values."
  :group 'ogent-agent-detail-faces)

(defface ogent-agent-detail-active
  '((((class color) (background light)) :foreground "#718c00")
    (((class color) (background dark)) :foreground "#a3be8c"))
  "Face for active/running states."
  :group 'ogent-agent-detail-faces)

(defface ogent-agent-detail-inactive
  '((((class color) (background light)) :foreground "#c82829")
    (((class color) (background dark)) :foreground "#bf616a"))
  "Face for inactive/stopped states."
  :group 'ogent-agent-detail-faces)

(defface ogent-agent-detail-header-line
  '((((class color) (background light)) :foreground "#4271ae" :weight bold)
    (((class color) (background dark)) :foreground "#81a1c1" :weight bold)
    (t :weight bold))
  "Face for header line."
  :group 'ogent-agent-detail-faces)

(defface ogent-agent-detail-header-key
  '((((class color) (background light)) :foreground "#f5871f" :weight bold)
    (((class color) (background dark)) :foreground "#d08770" :weight bold)
    (t :weight bold))
  "Face for header line key hints."
  :group 'ogent-agent-detail-faces)

;;; Buffer-local state

(defvar-local ogent-agent-detail--name nil
  "The agent name being inspected.")

(defvar-local ogent-agent-detail--rig nil
  "The rig the agent belongs to.")

(defvar-local ogent-agent-detail--kind nil
  "Agent kind: `crew' or `polecat'.")

(defvar-local ogent-agent-detail--data nil
  "Cached agent data plist.")

(defvar-local ogent-agent-detail--processes nil
  "List of active async processes.")

;;; Section Classes

(eval-and-compile
  (when (bound-and-true-p ogent-agent-detail--magit-section-available)
    (defclass ogent-agent-detail-root-section (magit-section) ()
      "Root section for agent detail buffer.")
    (defclass ogent-agent-detail-info-section (magit-section) ()
      "Section for agent info fields.")
    (defclass ogent-agent-detail-git-section (magit-section) ()
      "Section for git state.")
    (defclass ogent-agent-detail-work-section (magit-section) ()
      "Section for hooked/current work.")))

;;; Async execution

(defun ogent-agent-detail--run-async (args callback &optional error-callback)
  "Run gt with ARGS asynchronously, call CALLBACK with parsed JSON.
ERROR-CALLBACK receives error message on failure."
  (let* ((default-directory (expand-file-name "~/gt"))
         (buffer (generate-new-buffer " *ogent-agent-detail-gt*"))
         (stderr-buffer (generate-new-buffer " *ogent-agent-detail-stderr*"))
         (proc nil)
         (timer nil))
    (setq timer
          (run-with-timer
           ogent-agent-detail-timeout nil
           (lambda ()
             (when (and proc (process-live-p proc))
               (kill-process proc)
               (when error-callback
                 (funcall error-callback "gt command timed out"))))))
    (setq proc
          (make-process
           :name "ogent-agent-detail-gt"
           :buffer buffer
           :stderr stderr-buffer
           :command (cons ogent-agent-detail-gt-executable args)
           :sentinel
           (lambda (process event)
             (when timer (cancel-timer timer))
             (setq ogent-agent-detail--processes
                   (delq process ogent-agent-detail--processes))
             (cond
              ((string= event "finished\n")
               (let ((output (with-current-buffer (process-buffer process)
                               (buffer-string))))
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))
                 (condition-case _err
                     (let ((json-object-type 'plist)
                           (json-array-type 'list)
                           (json-key-type 'keyword))
                       (funcall callback (json-read-from-string output)))
                   (error
                    (if error-callback
                        (funcall error-callback "Failed to parse JSON")
                      (message "ogent-agent-detail: JSON parse error"))))))
              (t
               (let ((stderr-content
                      (when (buffer-live-p stderr-buffer)
                        (string-trim
                         (with-current-buffer stderr-buffer
                           (buffer-string))))))
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))
                 (if error-callback
                     (funcall error-callback
                              (or stderr-content
                                  (format "gt command failed: %s" event)))
                   (message "ogent-agent-detail error: %s"
                            (or stderr-content event)))))))))
    (set-process-query-on-exit-flag proc nil)
    (when-let ((stderr-proc (get-buffer-process stderr-buffer)))
      (set-process-query-on-exit-flag stderr-proc nil))
    (push proc ogent-agent-detail--processes)
    proc))

;;; Keymap

(defvar ogent-agent-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (when (and ogent-agent-detail--magit-section-available
               (boundp 'magit-section-mode-map))
      (set-keymap-parent map magit-section-mode-map))
    (define-key map "g" #'ogent-agent-detail-refresh)
    (define-key map "n" #'ogent-agent-detail-next-item)
    (define-key map "p" #'ogent-agent-detail-prev-item)
    (define-key map (kbd "TAB") #'ogent-agent-detail-toggle-section)
    (define-key map (kbd "RET") #'ogent-agent-detail-visit)
    (define-key map "M" #'ogent-agent-detail-mail)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-agent-detail-mode'.")

;;; Mode Definition

(defmacro ogent-agent-detail--define-mode ()
  "Define `ogent-agent-detail-mode' with appropriate parent."
  (let ((parent (if (bound-and-true-p ogent-agent-detail--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ogent-agent-detail-mode ,parent "Agent"
       "Major mode for inspecting an agent.

\\<ogent-agent-detail-mode-map>
Navigation:
  \\[ogent-agent-detail-next-item]     Move to next item
  \\[ogent-agent-detail-prev-item]     Move to previous item
  \\[ogent-agent-detail-visit]         Visit item at point
  \\[ogent-agent-detail-toggle-section] Toggle section

Actions:
  \\[ogent-agent-detail-mail]     Compose mail to this agent

Other:
  \\[ogent-agent-detail-refresh]  Refresh
  \\[quit-window]                 Quit

\\{ogent-agent-detail-mode-map}"
       :group 'ogent-agent-detail
       (setq-local revert-buffer-function #'ogent-agent-detail-refresh)
       (setq-local truncate-lines t)
       (setq-local buffer-read-only t)
       (setq header-line-format '(:eval (ogent-agent-detail--header-line))))))

(ogent-agent-detail--define-mode)

;;; Header Line

(defun ogent-agent-detail--header-line ()
  "Generate header line for agent detail buffer."
  (let ((kind (or ogent-agent-detail--kind "agent"))
        (name (or ogent-agent-detail--name "?")))
    (concat
     (propertize " " 'face 'ogent-agent-detail-header-line)
     (propertize (format "%s: %s" (capitalize (symbol-name kind)) name)
                 'face 'ogent-agent-detail-header-line)
     (propertize "  " 'face 'ogent-agent-detail-label)
     (propertize "g" 'face 'ogent-agent-detail-header-key)
     (propertize ":refresh " 'face 'ogent-agent-detail-label)
     (propertize "M" 'face 'ogent-agent-detail-header-key)
     (propertize ":mail " 'face 'ogent-agent-detail-label)
     (propertize "q" 'face 'ogent-agent-detail-header-key)
     (propertize ":quit" 'face 'ogent-agent-detail-label))))

;;; Data Fetching

(defun ogent-agent-detail--fetch (callback)
  "Fetch agent data and call CALLBACK when done."
  (let ((buf (current-buffer))
        (kind ogent-agent-detail--kind)
        (name ogent-agent-detail--name)
        (rig ogent-agent-detail--rig))
    (let ((args (pcase kind
                  ('crew (list "crew" "status" name "--json"))
                  ('polecat (list "polecat" "list" (or rig "ogent") "--json")))))
      (ogent-agent-detail--run-async
       args
       (lambda (result)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             ;; crew status returns a list, polecat list returns a list
             ;; For crew, find matching entry; for polecat, find matching name
             (setq ogent-agent-detail--data
                   (if (listp result)
                       (seq-find (lambda (item)
                                   (equal (plist-get item :name) name))
                                 result)
                     result))
             (funcall callback))))
       (lambda (err)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq ogent-agent-detail--data nil)
             (funcall callback)
             (message "Failed to fetch %s %s: %s" kind name err))))))))

;;; Buffer Content Rendering

(defun ogent-agent-detail--insert-buffer-contents ()
  "Insert all sections into the agent detail buffer."
  (if ogent-agent-detail--magit-section-available
      (ogent-agent-detail--insert-with-magit)
    (ogent-agent-detail--insert-plain)))

(defun ogent-agent-detail--insert-field (label value &optional face)
  "Insert a labeled field: LABEL: VALUE with optional FACE on value."
  (insert "  ")
  (insert (propertize (format "%-12s" label) 'face 'ogent-agent-detail-label))
  (insert (propertize (or value "—")
                      'face (or face 'ogent-agent-detail-value)))
  (insert "\n"))

(defun ogent-agent-detail--insert-with-magit ()
  "Insert content using magit-section."
  (magit-insert-section (ogent-agent-detail-root-section)
    (ogent-agent-detail--insert-info-section)
    (insert "\n")
    (when (eq ogent-agent-detail--kind 'crew)
      (ogent-agent-detail--insert-git-section)
      (insert "\n"))
    (ogent-agent-detail--insert-work-section)))

(defun ogent-agent-detail--insert-info-section ()
  "Insert agent info section."
  (let ((data ogent-agent-detail--data))
    (if ogent-agent-detail--magit-section-available
        (magit-insert-section (ogent-agent-detail-info-section data nil)
          (magit-insert-heading
            (concat
             (ogent-ops-section-prefix "" ">")
             " "
             (propertize "Agent" 'face 'ogent-agent-detail-section-heading)))
          (ogent-agent-detail--insert-info-fields data))
      (progn
        (insert (propertize "> Agent\n" 'face 'ogent-agent-detail-section-heading))
        (ogent-agent-detail--insert-info-fields data)))))

(defun ogent-agent-detail--insert-info-fields (data)
  "Insert info fields from DATA plist."
  (if (null data)
      (insert (propertize "  Agent not found\n" 'face 'ogent-agent-detail-label))
    (let* ((name (plist-get data :name))
           (rig (plist-get data :rig))
           (has-session (plist-get data :has_session))
           (session-running (plist-get data :session_running))
           (state (plist-get data :state))
           (running (or has-session session-running)))
      (ogent-agent-detail--insert-field
       "Name:" name)
      (ogent-agent-detail--insert-field
       "Rig:" rig)
      (when (eq ogent-agent-detail--kind 'crew)
        (ogent-agent-detail--insert-field
         "Role:" "crew"))
      (when state
        (ogent-agent-detail--insert-field
         "State:" state
         (if (equal state "working")
             'ogent-agent-detail-active
           'ogent-agent-detail-label)))
      (ogent-agent-detail--insert-field
       "Session:"
       (if running "running" "stopped")
       (if running
           'ogent-agent-detail-active
         'ogent-agent-detail-inactive)))))

(defun ogent-agent-detail--insert-git-section ()
  "Insert git state section (crew only)."
  (let ((data ogent-agent-detail--data))
    (when data
      (let ((branch (plist-get data :branch))
            (clean (plist-get data :git_clean))
            (modified (plist-get data :git_modified)))
        (if ogent-agent-detail--magit-section-available
            (magit-insert-section (ogent-agent-detail-git-section data nil)
              (magit-insert-heading
                (concat
                 (ogent-ops-section-prefix "" "#")
                 " "
                 (propertize "Git" 'face 'ogent-agent-detail-section-heading)))
              (ogent-agent-detail--insert-git-fields branch clean modified))
          (progn
            (insert (propertize "# Git\n" 'face 'ogent-agent-detail-section-heading))
            (ogent-agent-detail--insert-git-fields branch clean modified)))))))

(defun ogent-agent-detail--insert-git-fields (branch clean modified)
  "Insert git fields: BRANCH, CLEAN status, MODIFIED files."
  (ogent-agent-detail--insert-field "Branch:" branch)
  (ogent-agent-detail--insert-field
   "Status:"
   (if clean "clean" (format "dirty (%d modified)" (length modified)))
   (if clean 'ogent-agent-detail-active 'ogent-agent-detail-inactive))
  (when (and modified (not clean))
    (dolist (file modified)
      (insert "    ")
      (insert (propertize file 'face 'ogent-agent-detail-label))
      (insert "\n"))))

(defun ogent-agent-detail--insert-work-section ()
  "Insert hooked/current work section."
  (let ((data ogent-agent-detail--data))
    (when data
      (let ((issue (plist-get data :issue))
            (mail-total (plist-get data :mail_total))
            (mail-unread (plist-get data :mail_unread)))
        (if ogent-agent-detail--magit-section-available
            (magit-insert-section (ogent-agent-detail-work-section data nil)
              (magit-insert-heading
                (concat
                 (ogent-ops-section-prefix "" "~")
                 " "
                 (propertize "Work" 'face 'ogent-agent-detail-section-heading)))
              (ogent-agent-detail--insert-work-fields issue mail-total mail-unread))
          (progn
            (insert (propertize "~ Work\n" 'face 'ogent-agent-detail-section-heading))
            (ogent-agent-detail--insert-work-fields issue mail-total mail-unread)))))))

(defun ogent-agent-detail--insert-work-fields (issue mail-total mail-unread)
  "Insert work fields: ISSUE, MAIL-TOTAL, MAIL-UNREAD."
  (ogent-agent-detail--insert-field
   "Hooked:"
   (if issue
       (propertize issue 'ogent-bead-id issue)
     "(none)")
   (when issue 'ogent-agent-detail-active))
  (when mail-total
    (ogent-agent-detail--insert-field
     "Mail:"
     (format "%s total, %s unread"
             (or mail-total 0)
             (or mail-unread 0))
     (if (and mail-unread (> mail-unread 0))
         'ogent-agent-detail-active
       'ogent-agent-detail-label))))

;;; Interactive Commands

(defun ogent-agent-detail-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the agent detail buffer."
  (interactive)
  (when (derived-mode-p 'ogent-agent-detail-mode)
    (ogent-agent-detail--fetch
     (lambda ()
       (let ((inhibit-read-only t)
             (pos (point)))
         (erase-buffer)
         (ogent-agent-detail--insert-buffer-contents)
         (goto-char (min pos (point-max))))))))

(defun ogent-agent-detail-next-item ()
  "Move to the next item."
  (interactive)
  (if ogent-agent-detail--magit-section-available
      (magit-section-forward)
    (forward-line)))

(defun ogent-agent-detail-prev-item ()
  "Move to the previous item."
  (interactive)
  (if ogent-agent-detail--magit-section-available
      (magit-section-backward)
    (forward-line -1)))

(defun ogent-agent-detail-toggle-section ()
  "Toggle visibility of current section."
  (interactive)
  (when ogent-agent-detail--magit-section-available
    (magit-section-toggle (magit-current-section))))

(defun ogent-agent-detail-visit ()
  "Visit item at point (e.g., hooked bead)."
  (interactive)
  (let ((bead-id (get-text-property (point) 'ogent-bead-id)))
    (if bead-id
        (ogent-issues-bd-get
         bead-id
         (lambda (detail)
           (when detail
             (ogent-issues--show-detail detail)))
         (lambda (err)
           (message "Could not fetch %s: %s" bead-id err)))
      (when ogent-agent-detail--magit-section-available
        (magit-section-toggle (magit-current-section))))))

(defun ogent-agent-detail-mail ()
  "Compose mail to this agent."
  (interactive)
  (let* ((rig (or ogent-agent-detail--rig "ogent"))
         (kind (or ogent-agent-detail--kind 'crew))
         (name ogent-agent-detail--name)
         (addr (format "%s/%s/%s"
                       rig
                       (pcase kind ('crew "crew") ('polecat "polecats") (_ "crew"))
                       name)))
    (if (fboundp 'ogent-gastown-mail-compose)
        (ogent-gastown-mail-compose addr)
      (message "Mail compose not available (ogent-gastown-mail-compose)"))))

;;; Plain-text fallback

(defun ogent-agent-detail--insert-plain ()
  "Insert all content without magit-section."
  (ogent-agent-detail--insert-info-section)
  (insert "\n")
  (when (eq ogent-agent-detail--kind 'crew)
    (ogent-agent-detail--insert-git-section)
    (insert "\n"))
  (ogent-agent-detail--insert-work-section))

;;; Entry Point

;;;###autoload
(defun ogent-agent-detail-inspect (name kind &optional rig)
  "Open the agent detail inspector for NAME of KIND (crew or polecat).
Optional RIG specifies the rig (defaults to \"ogent\")."
  (interactive
   (list (read-string "Agent name: ")
         (intern (completing-read "Kind: " '("crew" "polecat") nil t))))
  (unless (and name (not (string-empty-p name)))
    (user-error "No agent name specified"))
  (let ((buffer (get-buffer-create
                 (format "*%s: %s*" (capitalize (symbol-name kind)) name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ogent-agent-detail-mode)
        (ogent-agent-detail-mode))
      (setq ogent-agent-detail--name name
            ogent-agent-detail--kind kind
            ogent-agent-detail--rig (or rig "ogent"))
      (ogent-agent-detail-refresh))
    (pop-to-buffer-same-window buffer)))

(provide 'ogent-agent-detail)
;;; ogent-agent-detail.el ends here
