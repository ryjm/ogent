;;; ogent-convoy.el --- Magit-style convoy inspector -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-section based buffer for viewing and inspecting convoy
;; status.  Displays convoy header metadata and tracked issue sections.
;; Designed to feel native to magit users with familiar keybindings,
;; mirroring ogent-issues and ogent-refinery interaction patterns.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'json)
(require 'ogent-ops-style)
(require 'ogent-gastown-status)

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

;;; Customization

(defgroup ogent-convoy nil
  "Convoy inspector."
  :group 'ogent
  :prefix "ogent-convoy-")

(defcustom ogent-convoy-buffer-name "*Convoy*"
  "Name of the Convoy inspector buffer."
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

(defcustom ogent-convoy-use-unicode t
  "Whether to use Unicode characters for icons."
  :type 'boolean
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

(defface ogent-convoy-active
  '((((class color) (background light)) :foreground "#1565c0" :weight bold)
    (((class color) (background dark)) :foreground "#88c0d0" :weight bold)
    (t :weight bold :inherit font-lock-function-name-face))
  "Face for active convoy title."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-complete
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c")
    (t :inherit success))
  "Face for completed convoy title."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-progress
  '((((class color) (background light)) :foreground "#ff8f00")
    (((class color) (background dark)) :foreground "#ebcb8b")
    (t :inherit font-lock-keyword-face))
  "Face for progress indicator."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-dimmed
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a")
    (t :inherit shadow))
  "Face for less important text."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-issue-id
  '((((class color) (background light)) :foreground "#6a1b9a")
    (((class color) (background dark)) :foreground "#b48ead")
    (t :inherit font-lock-type-face))
  "Face for tracked issue IDs."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-issue-title
  '((t :inherit default))
  "Face for tracked issue titles."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-header-line
  '((((class color) (background light))
     :background "grey90" :foreground "grey20"
     :weight bold :box (:line-width 2 :color "grey90"))
    (((class color) (background dark))
     :background "#2e3440" :foreground "#eceff4"
     :weight bold :box (:line-width 2 :color "#2e3440"))
    (t :weight bold :inherit mode-line))
  "Face for the header line."
  :group 'ogent-convoy-faces)

(defface ogent-convoy-header-line-key
  '((((class color) (background light))
     :background "grey90" :foreground "#5e35b1" :weight bold)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#b48ead" :weight bold)
    (t :weight bold :inherit mode-line))
  "Face for keybindings in header line."
  :group 'ogent-convoy-faces)

;;; Buffer-local State

(defvar-local ogent-convoy--data nil
  "Cached convoy data (normalized).")

(defvar-local ogent-convoy--loading nil
  "Non-nil when a gt command is in progress.")

(defvar-local ogent-convoy--loading-timer nil
  "Timer for animating the loading spinner.")

(defvar-local ogent-convoy--loading-frame 0
  "Current animation frame index.")

(defvar-local ogent-convoy--convoy-id nil
  "Convoy ID for this inspector buffer.")

;;; Cache

(defvar ogent-convoy--cache (make-hash-table :test 'equal)
  "Cache for gt command results.")

(defun ogent-convoy--cache-key (convoy-id args)
  "Generate cache key from CONVOY-ID and ARGS."
  (format "%s:%S" convoy-id args))

(defun ogent-convoy--cache-get (convoy-id args)
  "Get cached result for CONVOY-ID and ARGS if valid."
  (when (> ogent-convoy-cache-ttl 0)
    (let* ((key (ogent-convoy--cache-key convoy-id args))
           (entry (gethash key ogent-convoy--cache)))
      (when entry
        (let ((timestamp (car entry))
              (result (cdr entry)))
          (if (< (float-time (time-subtract (current-time) timestamp))
                 ogent-convoy-cache-ttl)
              result
            (remhash key ogent-convoy--cache)
            nil))))))

(defun ogent-convoy--cache-set (convoy-id args result)
  "Cache RESULT for CONVOY-ID and ARGS."
  (when (> ogent-convoy-cache-ttl 0)
    (let ((key (ogent-convoy--cache-key convoy-id args)))
      (puthash key (cons (current-time) result) ogent-convoy--cache))))

(defun ogent-convoy-cache-invalidate ()
  "Invalidate all cached results."
  (clrhash ogent-convoy--cache))

;;; Async Execution

(defvar ogent-convoy--processes nil
  "List of active gt processes.")

(defun ogent-convoy--run-async (args callback &optional error-callback)
  "Run gt with ARGS asynchronously, call CALLBACK with parsed JSON result.
ERROR-CALLBACK receives error message on failure."
  (let* ((default-directory (expand-file-name "~/gt"))
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

    (defclass ogent-convoy-issue-section (magit-section) ()
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
    (define-key map (kbd "RET") #'ogent-convoy-visit)

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
       "Major mode for inspecting convoy status.

\\<ogent-convoy-mode-map>
Navigation:
  \\[ogent-convoy-next-item]     Move to next item
  \\[ogent-convoy-prev-item]     Move to previous item
  \\[ogent-convoy-visit]   Visit tracked issue
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
  "Generate header line for Convoy inspector buffer."
  (let* ((loading-indicator (ogent-convoy--loading-indicator))
         (convoy ogent-convoy--data)
         (title (when convoy (plist-get convoy :title)))
         (progress (when convoy (ogent-gastown--convoy-progress-string convoy))))
    (concat
     (propertize " " 'face 'ogent-convoy-header-line)
     (propertize (format "Convoy: %s" (or title ogent-convoy--convoy-id "?"))
                 'face 'ogent-convoy-header-line)
     (if loading-indicator
         (concat (propertize "  " 'face 'ogent-convoy-dimmed)
                 (propertize loading-indicator 'face 'ogent-convoy-progress)
                 (propertize " Loading..." 'face 'ogent-convoy-dimmed))
       (concat
        (when progress
          (concat (propertize "  " 'face 'ogent-convoy-dimmed)
                  (propertize progress 'face 'ogent-convoy-progress)))
        (propertize "  " 'face 'ogent-convoy-dimmed)
        (propertize "g" 'face 'ogent-convoy-header-line-key)
        (propertize ":refresh " 'face 'ogent-convoy-dimmed)
        (propertize "q" 'face 'ogent-convoy-header-line-key)
        (propertize ":quit" 'face 'ogent-convoy-dimmed))))))

;;; Data Fetching

(defun ogent-convoy--fetch (callback)
  "Fetch convoy data, call CALLBACK when done."
  (let ((buf (current-buffer))
        (convoy-id ogent-convoy--convoy-id))
    (ogent-convoy--run-async
     (list "convoy" "status" convoy-id "--json")
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq ogent-convoy--data
                 (when result
                   (ogent-gastown--normalize-convoy result)))
           (funcall callback))))
     (lambda (_err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq ogent-convoy--data nil)
           (funcall callback)))))))

;;; Buffer Rendering

(defun ogent-convoy--insert-buffer-contents ()
  "Insert all sections into the buffer."
  (if ogent-convoy--magit-section-available
      (ogent-convoy--insert-with-magit-section)
    (ogent-convoy--insert-plain)))

(defun ogent-convoy--insert-with-magit-section ()
  "Insert content using magit-section."
  (magit-insert-section (ogent-convoy-root-section)
    (ogent-convoy--insert-header-section)
    (insert "\n")
    (ogent-convoy--insert-tracked-section)))

(defun ogent-convoy--insert-plain ()
  "Insert content without magit-section (fallback)."
  (ogent-convoy--insert-header-section-plain)
  (insert "\n")
  (ogent-convoy--insert-tracked-section-plain))

;;; Header Section

(defun ogent-convoy--insert-header-section ()
  "Insert convoy header metadata section with magit-section."
  (let ((convoy ogent-convoy--data))
    (magit-insert-section (ogent-convoy-header-section convoy)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "\u25B6" ">")
         " "
         (propertize "Convoy" 'face 'ogent-convoy-section-heading)))
      (if (null convoy)
          (insert (propertize "  No convoy data\n" 'face 'ogent-convoy-dimmed))
        (ogent-convoy--insert-header-fields convoy)))))

(defun ogent-convoy--insert-header-section-plain ()
  "Insert header section (plain)."
  (let ((convoy ogent-convoy--data))
    (insert (propertize "> Convoy\n" 'face 'ogent-convoy-section-heading))
    (if (null convoy)
        (insert (propertize "  No convoy data\n" 'face 'ogent-convoy-dimmed))
      (ogent-convoy--insert-header-fields convoy))))

(defun ogent-convoy--insert-header-fields (convoy)
  "Insert header metadata fields for CONVOY."
  (let* ((id (plist-get convoy :id))
         (title (plist-get convoy :title))
         (status (plist-get convoy :status))
         (progress (ogent-gastown--convoy-progress-string convoy))
         (title-face (if (equal status "complete")
                         'ogent-convoy-complete
                       'ogent-convoy-active)))
    (insert "  ")
    (insert (propertize "Title:    " 'face 'ogent-convoy-dimmed))
    (insert (propertize (or title "(unnamed)") 'face title-face))
    (insert "\n")
    (when id
      (insert "  ")
      (insert (propertize "ID:       " 'face 'ogent-convoy-dimmed))
      (insert (propertize id 'face 'ogent-convoy-dimmed))
      (insert "\n"))
    (when status
      (insert "  ")
      (insert (propertize "Status:   " 'face 'ogent-convoy-dimmed))
      (insert (propertize status 'face (if (equal status "complete")
                                           'ogent-convoy-complete
                                         'ogent-convoy-active)))
      (insert "\n"))
    (when progress
      (insert "  ")
      (insert (propertize "Progress: " 'face 'ogent-convoy-dimmed))
      (insert (propertize progress 'face 'ogent-convoy-progress))
      (insert "\n"))))

;;; Tracked Issues Section

(defun ogent-convoy--insert-tracked-section ()
  "Insert tracked issues section with magit-section."
  (let* ((convoy ogent-convoy--data)
         (tracked (when convoy (plist-get convoy :tracked))))
    (magit-insert-section (ogent-convoy-tracked-section tracked)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "\u2261" "#")
         " "
         (propertize "Tracked Issues" 'face 'ogent-convoy-section-heading)
         (when tracked
           (propertize (format " (%d)" (length tracked))
                       'face 'ogent-convoy-dimmed))))
      (if (null tracked)
          (insert (propertize "  No tracked issues\n" 'face 'ogent-convoy-dimmed))
        (dolist (issue tracked)
          (ogent-convoy--insert-issue-item issue))))))

(defun ogent-convoy--insert-tracked-section-plain ()
  "Insert tracked issues section (plain)."
  (let* ((convoy ogent-convoy--data)
         (tracked (when convoy (plist-get convoy :tracked))))
    (insert (propertize "# Tracked Issues\n" 'face 'ogent-convoy-section-heading))
    (if (null tracked)
        (insert (propertize "  No tracked issues\n" 'face 'ogent-convoy-dimmed))
      (dolist (issue tracked)
        (ogent-convoy--insert-issue-item-plain issue)))))

(defun ogent-convoy--insert-issue-item (issue)
  "Insert a single tracked ISSUE as a magit-section."
  (let* ((id (or (plist-get issue :id) "???"))
         (title (or (plist-get issue :title) "(untitled)"))
         (status (plist-get issue :status))
         (assignee (plist-get issue :assignee))
         (issue-type (plist-get issue :type))
         (status-sym (when status
                       (ogent-ops-status-symbol
                        (intern (replace-regexp-in-string "_" "-" status))))))
    (magit-insert-section (ogent-convoy-issue-section issue)
      (insert "  ")
      (when status-sym
        (insert (propertize status-sym 'face 'ogent-convoy-dimmed))
        (insert " "))
      (insert (propertize id 'face 'ogent-convoy-issue-id))
      (insert " ")
      (insert (propertize title 'face 'ogent-convoy-issue-title))
      (when issue-type
        (insert " ")
        (insert (propertize (format "[%s]" issue-type) 'face 'ogent-convoy-dimmed)))
      (when assignee
        (insert " ")
        (insert (propertize assignee 'face 'ogent-convoy-dimmed)))
      (insert "\n"))))

(defun ogent-convoy--insert-issue-item-plain (issue)
  "Insert a single tracked ISSUE as plain text."
  (let* ((id (or (plist-get issue :id) "???"))
         (title (or (plist-get issue :title) "(untitled)"))
         (status (plist-get issue :status)))
    (insert (format "  %s %s [%s]\n" id title (or status "?")))))

;;; Interactive Commands

(defun ogent-convoy-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the convoy inspector buffer."
  (interactive)
  (when (derived-mode-p 'ogent-convoy-mode)
    (ogent-convoy--start-loading)
    (ogent-convoy--fetch
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

(defun ogent-convoy--current-issue ()
  "Get the tracked issue at point."
  (when ogent-convoy--magit-section-available
    (when-let ((section (magit-current-section)))
      (when (eq (eieio-object-class-name section) 'ogent-convoy-issue-section)
        (oref section value)))))

(defun ogent-convoy-visit ()
  "Visit the tracked issue at point.
Opens the issue in the ogent-issues viewer if available."
  (interactive)
  (if-let ((issue (ogent-convoy--current-issue)))
      (let ((id (plist-get issue :id)))
        (when id
          (message "Viewing issue: %s" id)
          (shell-command (format "bd show %s" (shell-quote-argument id)))))
    (user-error "No tracked issue at point")))

;;; Entry Point

;;;###autoload
(defun ogent-convoy-inspect (convoy-id)
  "Open the convoy inspector for CONVOY-ID."
  (interactive "sConvoy ID: ")
  (unless (and convoy-id (not (string-empty-p convoy-id)))
    (user-error "No convoy ID specified"))
  (let ((buffer (get-buffer-create (format "*Convoy: %s*" convoy-id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ogent-convoy-mode)
        (ogent-convoy-mode))
      (setq ogent-convoy--convoy-id convoy-id)
      (ogent-convoy-refresh))
    (pop-to-buffer-same-window buffer)))

(provide 'ogent-convoy)
;;; ogent-convoy.el ends here
