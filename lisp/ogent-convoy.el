;;; ogent-convoy.el --- Magit-style convoy inspector mode -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a dedicated magit-section based buffer for inspecting a single
;; convoy. Displays convoy header metadata and tracked-issue sections with
;; keyboard-driven drilldown (g, TAB, RET, q).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'json)
(require 'ogent-ops-style)

;; Soft dependency on magit-section
(eval-and-compile
  (defvar ogent-convoy--magit-section-available
    (require 'magit-section nil t)
    "Non-nil if magit-section is available.")
  (when ogent-convoy--magit-section-available
    (require 'magit-section)))

;; Declare magit functions to avoid byte-compile warnings
(declare-function magit-insert-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-section-forward "ext:magit-section")
(declare-function magit-section-backward "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-current-section "ext:magit-section")

;; Autoload the normalizer from gastown-status
(autoload 'ogent-gastown--normalize-convoy "ogent-gastown-status" nil nil)
(autoload 'ogent-gastown--convoy-progress-string "ogent-gastown-status" nil nil)

;; Autoload ogent-issues for tracked issue navigation
(autoload 'ogent-issues-bd-get "ogent-issues-bd" nil nil)
(autoload 'ogent-issues--show-detail "ogent-issues" nil nil)

;;; Customization

(defgroup ogent-convoy nil
  "Convoy inspector."
  :group 'ogent
  :prefix "ogent-convoy-")

(defcustom ogent-convoy-buffer-name-format "*Convoy: %s*"
  "Format string for convoy inspector buffer names.
%s is replaced with the convoy ID."
  :type 'string
  :group 'ogent-convoy)

(defcustom ogent-convoy-gt-executable "gt"
  "Path to the gt executable."
  :type 'string
  :group 'ogent-convoy)

(defcustom ogent-convoy-timeout 30
  "Timeout in seconds for gt commands."
  :type 'integer
  :group 'ogent-convoy)

(defcustom ogent-convoy-cache-ttl 5
  "Cache time-to-live in seconds."
  :type 'integer
  :group 'ogent-convoy)

;;; Faces

(defgroup ogent-convoy-faces nil
  "Faces for ogent-convoy."
  :group 'ogent-convoy
  :group 'faces)

(defface ogent-convoy-section-heading
  '((((class color) (background light)) :foreground "#5d4037" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold)
    (t :weight bold))
  "Face for section headings."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-header-line
  '((((class color) (background light)) :foreground "#37474f" :weight bold)
    (((class color) (background dark)) :foreground "#d8dee9" :weight bold)
    (t :weight bold))
  "Face for the header line."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-id
  '((((class color) (background light)) :foreground "#5d4037")
    (((class color) (background dark)) :foreground "#d08770"))
  "Face for convoy ID."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-title
  '((((class color) (background light)) :foreground "#1b5e20" :weight bold)
    (((class color) (background dark)) :foreground "#a3be8c" :weight bold)
    (t :weight bold))
  "Face for convoy title."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-status-active
  '((((class color) (background light)) :foreground "#ff8f00" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold)
    (t :weight bold))
  "Face for active convoy status."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-status-complete
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c"))
  "Face for completed convoy status."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-dimmed
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for dimmed/secondary text."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-tracked-issue
  '((((class color) (background light)) :foreground "#37474f")
    (((class color) (background dark)) :foreground "#d8dee9"))
  "Face for tracked issue IDs."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-header-line-key
  '((((class color) (background light)) :foreground "#d32f2f" :weight bold)
    (((class color) (background dark)) :foreground "#bf616a" :weight bold)
    (t :weight bold))
  "Face for header line key hints."
  :group 'ogent-convoy-faces)

;;; Buffer-local state

(defvar-local ogent-convoy--id nil
  "The convoy ID being inspected.")

(defvar-local ogent-convoy--data nil
  "Cached convoy data plist (normalized).")

(defvar-local ogent-convoy--loading nil
  "Non-nil when a fetch is in progress.")

(defvar-local ogent-convoy--loading-frame 0
  "Current frame index for the loading animation.")

(defvar-local ogent-convoy--loading-timer nil
  "Timer for the loading animation.")

(defvar-local ogent-convoy--processes nil
  "List of active async processes.")

(defvar-local ogent-convoy--workspace-root nil
  "Workspace root for gt commands.")

;;; Cache

(defvar ogent-convoy--cache (make-hash-table :test 'equal)
  "Cache for convoy fetch results.")

(defun ogent-convoy--cache-key (convoy-id)
  "Generate cache key from CONVOY-ID."
  (format "convoy:%s" convoy-id))

(defun ogent-convoy--cache-get (convoy-id)
  "Get cached result for CONVOY-ID if valid."
  (when (> ogent-convoy-cache-ttl 0)
    (let* ((key (ogent-convoy--cache-key convoy-id))
           (entry (gethash key ogent-convoy--cache)))
      (when entry
        (let ((timestamp (car entry))
              (result (cdr entry)))
          (if (< (float-time (time-subtract (current-time) timestamp))
                 ogent-convoy-cache-ttl)
              result
            (remhash key ogent-convoy--cache)
            nil))))))

(defun ogent-convoy--cache-set (convoy-id result)
  "Cache RESULT for CONVOY-ID."
  (when (> ogent-convoy-cache-ttl 0)
    (puthash (ogent-convoy--cache-key convoy-id)
             (cons (current-time) result)
             ogent-convoy--cache)))

(defun ogent-convoy-cache-invalidate ()
  "Invalidate all cached results."
  (clrhash ogent-convoy--cache))

;;; Async execution

(defun ogent-convoy--run-async (args callback &optional error-callback)
  "Run gt with ARGS asynchronously, call CALLBACK with parsed JSON result.
ERROR-CALLBACK receives error message on failure."
  (let* ((default-directory (or ogent-convoy--workspace-root
                                (expand-file-name "~/gt")))
         (buffer (generate-new-buffer " *ogent-convoy-gt*"))
         (stderr-buffer (generate-new-buffer " *ogent-convoy-gt-stderr*"))
         (proc nil)
         (timer nil))

    (setq timer
          (run-with-timer
           ogent-convoy-timeout nil
           (lambda ()
             (when (and proc (process-live-p proc))
               (kill-process proc)
               (when error-callback
                 (funcall error-callback
                          (format "gt command timed out after %ds"
                                  ogent-convoy-timeout)))))))

    (let ((full-command (cons ogent-convoy-gt-executable args)))
      (setq proc
            (make-process
             :name "ogent-convoy-gt"
             :buffer buffer
             :stderr stderr-buffer
             :command full-command
             :sentinel
             (lambda (process event)
               (when timer (cancel-timer timer))
               (setq ogent-convoy--processes
                     (delq process ogent-convoy--processes))

               (cond
                ((string= event "finished\n")
                 (with-current-buffer (process-buffer process)
                   (goto-char (point-min))
                   (skip-chars-forward " \t\n\r")
                   (condition-case err
                       (let ((result (if (eobp)
                                         nil
                                       (json-parse-buffer
                                        :object-type 'plist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil))))
                         (funcall callback result))
                     (error
                      (if error-callback
                          (funcall error-callback
                                   (format "JSON parse error: %s"
                                           (error-message-string err)))
                        (message "ogent-convoy: JSON parse error: %s"
                                 (error-message-string err))))))
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                ((string-match "exited abnormally" event)
                 (let ((stderr-content
                        (when (buffer-live-p stderr-buffer)
                          (with-current-buffer stderr-buffer
                            (string-trim (buffer-string))))))
                   (if error-callback
                       (funcall error-callback
                                (or stderr-content
                                    (format "gt command failed: %s" event)))
                     (message "ogent-convoy error: %s" (or stderr-content event))))
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                (t
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))))))))

    (push proc ogent-convoy--processes)
    proc))

;;; Section Classes (when magit-section available)

(eval-and-compile
  (when (bound-and-true-p ogent-convoy--magit-section-available)
    (defclass ogent-convoy-root-section (magit-section) ()
      "Root section for convoy inspector buffer.")

    (defclass ogent-convoy-header-section (magit-section) ()
      "Section for convoy header metadata.")

    (defclass ogent-convoy-tracked-section (magit-section) ()
      "Section for tracked issues list.")

    (defclass ogent-convoy-tracked-item-section (magit-section) ()
      "Section for a single tracked issue.")))

;;; Keymap

(defvar ogent-convoy-mode-map
  (let ((map (make-sparse-keymap)))
    (when (and ogent-convoy--magit-section-available
               (boundp 'magit-section-mode-map))
      (set-keymap-parent map magit-section-mode-map))

    ;; Refresh
    (define-key map "g" #'ogent-convoy-refresh)
    (define-key map "G" #'ogent-convoy-refresh-force)

    ;; Navigation
    (define-key map "n" #'ogent-convoy-next-item)
    (define-key map "p" #'ogent-convoy-prev-item)
    (define-key map (kbd "TAB") #'ogent-convoy-toggle-section)
    (define-key map (kbd "RET") #'ogent-convoy-visit-tracked)

    ;; Quit
    (define-key map "q" #'quit-window)

    map)
  "Keymap for `ogent-convoy-mode'.")

;;; Mode Definition

(defmacro ogent-convoy--define-mode ()
  "Define `ogent-convoy-mode' with appropriate parent mode."
  (let ((parent (if (bound-and-true-p ogent-convoy--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ogent-convoy-mode ,parent "Convoy"
       "Major mode for inspecting a convoy.

\\<ogent-convoy-mode-map>
Navigation:
  \\[ogent-convoy-next-item]     Move to next item
  \\[ogent-convoy-prev-item]     Move to previous item
  \\[ogent-convoy-visit-tracked]   Visit tracked issue at point
  \\[ogent-convoy-toggle-section]   Toggle section visibility

Other:
  \\[ogent-convoy-refresh]     Refresh
  \\[ogent-convoy-refresh-force]     Force refresh (clear cache)
  \\[quit-window]     Quit

\\{ogent-convoy-mode-map}"
       :group 'ogent-convoy
       (setq-local revert-buffer-function #'ogent-convoy-refresh)
       (setq-local truncate-lines t)
       (setq-local buffer-read-only t)
       (setq header-line-format '(:eval (ogent-convoy--header-line))))))

(ogent-convoy--define-mode)

;;; Loading Animation

(defconst ogent-convoy--loading-frames (ogent-ops-loading-frames)
  "Animation frames for loading spinner.")

(defun ogent-convoy--start-loading ()
  "Start the loading animation."
  (setq ogent-convoy--loading t
        ogent-convoy--loading-frame 0)
  (ogent-convoy--stop-loading-timer)
  (setq ogent-convoy--loading-timer
        (run-at-time 0.25 0.25 #'ogent-convoy--animate-loading (current-buffer)))
  (force-mode-line-update))

(defun ogent-convoy--stop-loading ()
  "Stop the loading animation."
  (ogent-convoy--stop-loading-timer)
  (setq ogent-convoy--loading nil)
  (force-mode-line-update))

(defun ogent-convoy--stop-loading-timer ()
  "Cancel the loading timer if active."
  (when ogent-convoy--loading-timer
    (cancel-timer ogent-convoy--loading-timer)
    (setq ogent-convoy--loading-timer nil)))

(defun ogent-convoy--animate-loading (buffer)
  "Advance the loading animation frame in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ogent-convoy--loading-frame
            (mod (1+ ogent-convoy--loading-frame) 4))
      (force-mode-line-update))))

(defun ogent-convoy--loading-indicator ()
  "Return the current loading spinner character."
  (when ogent-convoy--loading
    (nth ogent-convoy--loading-frame ogent-convoy--loading-frames)))

;;; Header Line

(defun ogent-convoy--header-line ()
  "Generate header line for convoy inspector buffer."
  (let ((loading-indicator (ogent-convoy--loading-indicator))
        (id (or ogent-convoy--id "?")))
    (concat
     (propertize " " 'face 'ogent-convoy-header-line)
     (propertize (format "Convoy: %s" id)
                 'face 'ogent-convoy-header-line)
     (if loading-indicator
         (concat (propertize "  " 'face 'ogent-convoy-dimmed)
                 (propertize loading-indicator 'face 'ogent-convoy-status-active)
                 (propertize " Loading..." 'face 'ogent-convoy-dimmed))
       (concat
        (propertize "  " 'face 'ogent-convoy-dimmed)
        (propertize "g" 'face 'ogent-convoy-header-line-key)
        (propertize ":refresh " 'face 'ogent-convoy-dimmed)
        (propertize "q" 'face 'ogent-convoy-header-line-key)
        (propertize ":quit" 'face 'ogent-convoy-dimmed))))))

;;; Data Fetching

(defun ogent-convoy--fetch (convoy-id callback)
  "Fetch convoy data for CONVOY-ID, call CALLBACK when done."
  (let ((cached (ogent-convoy--cache-get convoy-id))
        (buf (current-buffer)))
    (if cached
        (progn
          (setq ogent-convoy--data cached)
          (funcall callback))
      (ogent-convoy--run-async
       (list "convoy" "status" convoy-id "--json")
       (lambda (result)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (let ((normalized (if result
                                   (ogent-gastown--normalize-convoy result)
                                 nil)))
               (setq ogent-convoy--data normalized)
               (ogent-convoy--cache-set convoy-id normalized)
               (funcall callback)))))
       (lambda (err)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq ogent-convoy--data nil)
             (funcall callback)
             (message "Failed to fetch convoy %s: %s" convoy-id err))))))))

;;; Buffer Content Rendering

(defun ogent-convoy--insert-buffer-contents ()
  "Insert all sections into the convoy inspector buffer."
  (if ogent-convoy--magit-section-available
      (ogent-convoy--insert-with-magit-section)
    (ogent-convoy--insert-plain)))

(defun ogent-convoy--insert-with-magit-section ()
  "Insert content using magit-section."
  (magit-insert-section (ogent-convoy-root-section)
    (ogent-convoy--insert-header-section)
    (insert "\n")
    (ogent-convoy--insert-tracked-section)))

(defun ogent-convoy--insert-header-section ()
  "Insert convoy header metadata section."
  (let ((data ogent-convoy--data))
    (magit-insert-section (ogent-convoy-header-section data nil)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "" ">")
         " "
         (propertize "Convoy" 'face 'ogent-convoy-section-heading)))
      (if (null data)
          (insert (propertize "  Convoy not found\n" 'face 'ogent-convoy-dimmed))
        (let ((id (plist-get data :id))
              (title (plist-get data :title))
              (status (plist-get data :status))
              (progress (ogent-gastown--convoy-progress-string data)))
          (insert "  ")
          (insert (propertize "ID:     " 'face 'ogent-convoy-dimmed))
          (insert (propertize (or id "?") 'face 'ogent-convoy-id))
          (insert "\n")
          (insert "  ")
          (insert (propertize "Title:  " 'face 'ogent-convoy-dimmed))
          (insert (propertize (or title "(unnamed)") 'face 'ogent-convoy-title))
          (insert "\n")
          (insert "  ")
          (insert (propertize "Status: " 'face 'ogent-convoy-dimmed))
          (insert (propertize (or status "unknown")
                              'face (if (equal status "complete")
                                        'ogent-convoy-status-complete
                                      'ogent-convoy-status-active)))
          (insert "\n")
          (when progress
            (insert "  ")
            (insert (propertize "Progress: " 'face 'ogent-convoy-dimmed))
            (insert (propertize progress 'face 'ogent-convoy-dimmed))
            (insert "\n")))))))

(defun ogent-convoy--insert-tracked-section ()
  "Insert tracked issues section."
  (let* ((data ogent-convoy--data)
         (tracked (when data (plist-get data :tracked))))
    (magit-insert-section (ogent-convoy-tracked-section tracked nil)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "" "#")
         " "
         (propertize "Tracked Issues" 'face 'ogent-convoy-section-heading)
         (when tracked
           (propertize (format " (%d)" (length tracked))
                       'face 'ogent-convoy-dimmed))))
      (if (or (null data) (null tracked))
          (insert (propertize "  No tracked issues\n" 'face 'ogent-convoy-dimmed))
        (dolist (issue-id tracked)
          (ogent-convoy--insert-tracked-item issue-id))))))

(defun ogent-convoy--insert-tracked-item (issue-id)
  "Insert a single tracked ISSUE-ID as a section."
  (magit-insert-section (ogent-convoy-tracked-item-section issue-id)
    (insert "  ")
    (insert (propertize (ogent-ops-status-symbol 'open) 'face 'ogent-convoy-dimmed))
    (insert " ")
    (insert (propertize (if (stringp issue-id) issue-id (format "%s" issue-id))
                        'face 'ogent-convoy-tracked-issue))
    (insert "\n")))

;;; Plain-text fallback rendering

(defun ogent-convoy--insert-plain ()
  "Insert convoy content without magit-section."
  (ogent-convoy--insert-header-plain)
  (insert "\n")
  (ogent-convoy--insert-tracked-plain))

(defun ogent-convoy--insert-header-plain ()
  "Insert convoy header (plain)."
  (let ((data ogent-convoy--data))
    (insert (propertize "> Convoy\n" 'face 'ogent-convoy-section-heading))
    (if (null data)
        (insert (propertize "  Convoy not found\n" 'face 'ogent-convoy-dimmed))
      (let ((id (plist-get data :id))
            (title (plist-get data :title))
            (status (plist-get data :status))
            (progress (ogent-gastown--convoy-progress-string data)))
        (insert (format "  ID:     %s\n" (or id "?")))
        (insert (format "  Title:  %s\n" (or title "(unnamed)")))
        (insert (format "  Status: %s\n" (or status "unknown")))
        (when progress
          (insert (format "  Progress: %s\n" progress)))))))

(defun ogent-convoy--insert-tracked-plain ()
  "Insert tracked issues section (plain)."
  (let* ((data ogent-convoy--data)
         (tracked (when data (plist-get data :tracked))))
    (insert (propertize "# Tracked Issues\n" 'face 'ogent-convoy-section-heading))
    (if (or (null data) (null tracked))
        (insert (propertize "  No tracked issues\n" 'face 'ogent-convoy-dimmed))
      (dolist (issue-id tracked)
        (insert (format "  %s %s\n"
                        (ogent-ops-status-symbol 'open)
                        (if (stringp issue-id) issue-id (format "%s" issue-id))))))))

;;; Interactive Commands

(defun ogent-convoy-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the convoy inspector buffer."
  (interactive)
  (when (derived-mode-p 'ogent-convoy-mode)
    (ogent-convoy--start-loading)
    (ogent-convoy--fetch
     ogent-convoy--id
     (lambda ()
       (ogent-convoy--stop-loading)
       (let ((inhibit-read-only t)
             (pos (point)))
         (erase-buffer)
         (ogent-convoy--insert-buffer-contents)
         (goto-char (min pos (point-max))))))))

(defun ogent-convoy-refresh-force ()
  "Force refresh, clearing cache."
  (interactive)
  (ogent-convoy-cache-invalidate)
  (ogent-convoy-refresh))

(defun ogent-convoy-next-item ()
  "Move to the next item."
  (interactive)
  (if ogent-convoy--magit-section-available
      (magit-section-forward)
    (forward-line)))

(defun ogent-convoy-prev-item ()
  "Move to the previous item."
  (interactive)
  (if ogent-convoy--magit-section-available
      (magit-section-backward)
    (forward-line -1)))

(defun ogent-convoy-toggle-section ()
  "Toggle visibility of current section."
  (interactive)
  (when ogent-convoy--magit-section-available
    (magit-section-toggle (magit-current-section))))

(defun ogent-convoy-visit-tracked ()
  "Visit the tracked issue at point."
  (interactive)
  (if ogent-convoy--magit-section-available
      (let ((section (magit-current-section)))
        (if (eq (eieio-object-class-name section)
                'ogent-convoy-tracked-item-section)
            (let ((issue-id (oref section value)))
              (message "Visiting issue: %s" issue-id))
          (magit-section-toggle section)))
    (user-error "No tracked issue at point")))

;;; Entry Point

;;;###autoload
(defun ogent-convoy-inspect (convoy-id &optional workspace-root)
  "Open the convoy inspector for CONVOY-ID.
WORKSPACE-ROOT is the Gas Town workspace root for gt commands.
If nil, defaults to ~/gt."
  (interactive
   (list (read-string "Convoy ID: ")))
  (unless (and convoy-id (not (string-empty-p convoy-id)))
    (user-error "No convoy ID specified"))
  (let ((buffer (get-buffer-create
                 (format ogent-convoy-buffer-name-format convoy-id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ogent-convoy-mode)
        (ogent-convoy-mode))
      (setq ogent-convoy--id convoy-id)
      (setq ogent-convoy--workspace-root
            (or workspace-root (expand-file-name "~/gt")))
      (ogent-convoy-refresh))
    (pop-to-buffer-same-window buffer)))

(provide 'ogent-convoy)
;;; ogent-convoy.el ends here
