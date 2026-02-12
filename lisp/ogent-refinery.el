;;; ogent-refinery.el --- Magit-style merge queue buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-section based buffer for viewing and managing the
;; refinery merge queue. Displays queue status, current processing,
;; recent merges, and failed/blocked branches.
;; Designed to feel native to magit users with familiar keybindings.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'json)
(require 'ogent-ops-style)

;; Soft dependency on magit-section
(eval-and-compile
  (defvar ogent-refinery--magit-section-available
    (require 'magit-section nil t)
    "Non-nil if magit-section is available.")
  (when ogent-refinery--magit-section-available
    (require 'magit-section)))

;; Declare magit functions to avoid byte-compile warnings
(declare-function magit-insert-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-section-forward "ext:magit-section")
(declare-function magit-section-backward "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-current-section "ext:magit-section")

;;; Customization

(defgroup ogent-refinery nil
  "Merge queue viewer."
  :group 'ogent
  :prefix "ogent-refinery-")

(defcustom ogent-refinery-buffer-name "*Refinery*"
  "Name of the Refinery status buffer."
  :type 'string
  :group 'ogent-refinery)

(defcustom ogent-refinery-gt-executable "gt"
  "Path to the gt executable."
  :type 'string
  :group 'ogent-refinery)

(defcustom ogent-refinery-timeout 30
  "Timeout in seconds for gt commands."
  :type 'integer
  :group 'ogent-refinery)

(defcustom ogent-refinery-cache-ttl 5
  "Cache time-to-live in seconds."
  :type 'integer
  :group 'ogent-refinery)

(defcustom ogent-refinery-use-unicode t
  "Whether to use Unicode characters for icons."
  :type 'boolean
  :group 'ogent-refinery)

(defcustom ogent-refinery-recent-merges-limit 10
  "Maximum number of recent merges to display."
  :type 'integer
  :group 'ogent-refinery)

;;; Faces

(defgroup ogent-refinery-faces nil
  "Faces for ogent-refinery."
  :group 'ogent-refinery
  :group 'faces)

(defface ogent-refinery-section-heading
  '((((class color) (background light))
     :foreground "#37474f" :background "#eceff1" :weight bold :extend t)
    (((class color) (background dark))
     :foreground "#eceff4" :background "#3b4252" :weight bold :extend t)
    (t :weight bold))
  "Face for section headings."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-section-heading-processing
  '((((class color) (background light))
     :inherit ogent-refinery-section-heading
     :foreground "#6f4e37" :background "#fff3e0")
    (((class color) (background dark))
     :inherit ogent-refinery-section-heading
     :foreground "#f4d9b3" :background "#4b3d2f")
    (t :inherit ogent-refinery-section-heading))
  "Face for the processing section heading."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-section-heading-queue
  '((((class color) (background light))
     :inherit ogent-refinery-section-heading
     :foreground "#0d47a1" :background "#e3f2fd")
    (((class color) (background dark))
     :inherit ogent-refinery-section-heading
     :foreground "#9ed0ff" :background "#2f435f")
    (t :inherit ogent-refinery-section-heading))
  "Face for the queue section heading."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-section-heading-failed
  '((((class color) (background light))
     :inherit ogent-refinery-section-heading
     :foreground "#b71c1c" :background "#ffebee")
    (((class color) (background dark))
     :inherit ogent-refinery-section-heading
     :foreground "#ff9aa2" :background "#5a3338")
    (t :inherit ogent-refinery-section-heading))
  "Face for the failed section heading."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-section-heading-history
  '((((class color) (background light))
     :inherit ogent-refinery-section-heading
     :foreground "#1b5e20" :background "#e8f5e9")
    (((class color) (background dark))
     :inherit ogent-refinery-section-heading
     :foreground "#b7e3a1" :background "#304a38")
    (t :inherit ogent-refinery-section-heading))
  "Face for the history section heading."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-queue-ready
  '((((class color) (background light)) :foreground "#2e7d32" :weight bold)
    (((class color) (background dark)) :foreground "#a3be8c" :weight bold)
    (t :weight bold :inherit success))
  "Face for ready queue items."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-queue-processing
  '((((class color) (background light)) :foreground "#ff8f00" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold)
    (t :weight bold :inherit font-lock-keyword-face))
  "Face for items currently processing."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-queue-blocked
  '((((class color) (background light)) :foreground "#c62828" :weight bold)
    (((class color) (background dark)) :foreground "#bf616a" :weight bold)
    (t :weight bold :slant italic))
  "Face for blocked items."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-queue-failed
  '((((class color) (background light)) :foreground "#c62828")
    (((class color) (background dark)) :foreground "#bf616a")
    (t :inherit font-lock-warning-face))
  "Face for failed items."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-merged
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c")
    (t :inherit success))
  "Face for successfully merged items."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-branch
  '((((class color) (background light)) :foreground "#1565c0")
    (((class color) (background dark)) :foreground "#88c0d0")
    (t :inherit font-lock-function-name-face))
  "Face for branch names."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-worker
  '((((class color) (background light)) :foreground "#6a1b9a")
    (((class color) (background dark)) :foreground "#b48ead")
    (t :inherit font-lock-type-face))
  "Face for worker names."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-priority-p0
  '((((class color) (background light)) :foreground "#c62828" :weight bold)
    (((class color) (background dark)) :foreground "#bf616a" :weight bold)
    (t :weight bold :inverse-video t))
  "Face for P0 (critical) priority."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-priority-p1
  '((((class color) (background light)) :foreground "#ff8f00" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold)
    (t :weight bold :underline t))
  "Face for P1 (high) priority."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-priority-p2
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c")
    (t :inherit default))
  "Face for P2 (medium) priority."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-dimmed
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a")
    (t :inherit shadow))
  "Face for less important text."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-header-line
  '((((class color) (background light))
     :background "grey90" :foreground "grey20"
     :weight bold :box (:line-width 2 :color "grey90"))
    (((class color) (background dark))
     :background "#2e3440" :foreground "#eceff4"
     :weight bold :box (:line-width 2 :color "#2e3440"))
    (t :weight bold :inherit mode-line))
  "Face for the header line."
  :group 'ogent-refinery-faces)

(defface ogent-refinery-header-line-key
  '((((class color) (background light))
     :background "grey90" :foreground "#5e35b1" :weight bold)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#b48ead" :weight bold)
    (t :weight bold :inherit mode-line))
  "Face for keybindings in header line."
  :group 'ogent-refinery-faces)

;;; Buffer-local State

(defvar-local ogent-refinery--queue-data nil
  "Cached queue data from `gt mq list'.")

(defvar-local ogent-refinery--history-data nil
  "Cached merge history data.")

(defvar-local ogent-refinery--loading nil
  "Non-nil when a gt command is in progress.")

(defvar-local ogent-refinery--loading-timer nil
  "Timer for animating the loading spinner.")

(defvar-local ogent-refinery--loading-frame 0
  "Current animation frame index.")

(defvar-local ogent-refinery--rig nil
  "Current rig name for this buffer.")

;;; Cache

(defvar ogent-refinery--cache (make-hash-table :test 'equal)
  "Cache for gt command results.")

(defun ogent-refinery--cache-key (rig args)
  "Generate cache key from RIG and ARGS."
  (format "%s:%S" rig args))

(defun ogent-refinery--cache-get (rig args)
  "Get cached result for RIG and ARGS if valid."
  (when (> ogent-refinery-cache-ttl 0)
    (let* ((key (ogent-refinery--cache-key rig args))
           (entry (gethash key ogent-refinery--cache)))
      (when entry
        (let ((timestamp (car entry))
              (result (cdr entry)))
          (if (< (float-time (time-subtract (current-time) timestamp))
                 ogent-refinery-cache-ttl)
              result
            (remhash key ogent-refinery--cache)
            nil))))))

(defun ogent-refinery--cache-set (rig args result)
  "Cache RESULT for RIG and ARGS."
  (when (> ogent-refinery-cache-ttl 0)
    (let ((key (ogent-refinery--cache-key rig args)))
      (puthash key (cons (current-time) result) ogent-refinery--cache))))

(defun ogent-refinery-cache-invalidate ()
  "Invalidate all cached results."
  (clrhash ogent-refinery--cache))

;;; Async Execution

(defvar ogent-refinery--processes nil
  "List of active gt processes.")

(defun ogent-refinery--run-async (args callback &optional error-callback)
  "Run gt with ARGS asynchronously, call CALLBACK with parsed JSON result.
ERROR-CALLBACK receives error message on failure."
  (let* ((default-directory (expand-file-name "~/gt"))
         (buffer (generate-new-buffer " *ogent-refinery-gt*"))
         (stderr-buffer (generate-new-buffer " *ogent-refinery-gt-stderr*"))
         (proc nil)
         (timer nil))

    (setq timer
          (run-with-timer
           ogent-refinery-timeout nil
           (lambda ()
             (when (and proc (process-live-p proc))
               (kill-process proc)
               (when error-callback
                 (funcall error-callback
                          (format "gt command timed out after %ds"
                                  ogent-refinery-timeout)))))))

    (let ((full-command (cons ogent-refinery-gt-executable args)))
      (setq proc
            (make-process
             :name "ogent-refinery-gt"
             :buffer buffer
             :stderr stderr-buffer
             :command full-command
             :sentinel
             (lambda (process event)
               (when timer (cancel-timer timer))
               (setq ogent-refinery--processes
                     (delq process ogent-refinery--processes))

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
                        (message "ogent-refinery: JSON parse error: %s"
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
                     (message "ogent-refinery error: %s" (or stderr-content event))))
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                (t
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))))))))

    (push proc ogent-refinery--processes)
    proc))

;;; Rig Detection

(defun ogent-refinery--detect-rig ()
  "Detect the current rig from the working directory."
  (let ((dir default-directory)
        (gt-root (expand-file-name "~/gt")))
    (when (string-prefix-p gt-root dir)
      (let ((relative (substring dir (1+ (length gt-root)))))
        (car (split-string relative "/"))))))

;;; Section Classes (when magit-section available)

(eval-and-compile
  (when (bound-and-true-p ogent-refinery--magit-section-available)
    (defclass ogent-refinery-root-section (magit-section) ()
      "Root section for refinery status buffer.")

    (defclass ogent-refinery-queue-section (magit-section) ()
      "Section for queue status.")

    (defclass ogent-refinery-mr-section (magit-section) ()
      "Section for a single merge request.")

    (defclass ogent-refinery-processing-section (magit-section) ()
      "Section for currently processing MR.")

    (defclass ogent-refinery-history-section (magit-section) ()
      "Section for merge history.")

    (defclass ogent-refinery-failed-section (magit-section) ()
      "Section for failed/blocked items.")))

;;; Keymap

(defvar ogent-refinery-mode-map
  (let ((map (make-sparse-keymap)))
    (when (and ogent-refinery--magit-section-available
               (boundp 'magit-section-mode-map))
      (set-keymap-parent map magit-section-mode-map))

    ;; Refresh
    (define-key map "g" #'ogent-refinery-refresh)
    (define-key map "G" #'ogent-refinery-refresh-force)

    ;; Navigation
    (define-key map "n" #'ogent-refinery-next-item)
    (define-key map "p" #'ogent-refinery-prev-item)
    (define-key map (kbd "TAB") #'ogent-refinery-toggle-section)
    (define-key map (kbd "RET") #'ogent-refinery-visit)

    ;; Actions
    (define-key map "m" #'ogent-refinery-merge)
    (define-key map "r" #'ogent-refinery-retry)
    (define-key map "d" #'ogent-refinery-drop)
    (define-key map "l" #'ogent-refinery-log)

    ;; Quit
    (define-key map "q" #'quit-window)

    map)
  "Keymap for `ogent-refinery-mode'.")

;;; Mode Definition

(defmacro ogent-refinery--define-mode ()
  "Define `ogent-refinery-mode' with appropriate parent mode."
  (let ((parent (if (bound-and-true-p ogent-refinery--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ogent-refinery-mode ,parent "Refinery"
       "Major mode for viewing refinery merge queue.

\\<ogent-refinery-mode-map>
Navigation:
  \\[ogent-refinery-next-item]     Move to next item
  \\[ogent-refinery-prev-item]     Move to previous item
  \\[ogent-refinery-visit]   View item details
  \\[ogent-refinery-toggle-section]   Toggle section visibility

Actions:
  \\[ogent-refinery-merge]     Merge selected (priority bump)
  \\[ogent-refinery-retry]     Retry failed merge request
  \\[ogent-refinery-drop]     Drop from queue
  \\[ogent-refinery-log]     View merge log

Other:
  \\[ogent-refinery-refresh]     Refresh
  \\[quit-window]     Quit

\\{ogent-refinery-mode-map}"
       :group 'ogent-refinery
       (setq-local revert-buffer-function #'ogent-refinery-refresh)
       (setq-local truncate-lines t)
       (setq-local buffer-read-only t)
       (setq header-line-format '(:eval (ogent-refinery--header-line))))))

(ogent-refinery--define-mode)

;;; Loading Animation

(defconst ogent-refinery--loading-frames (ogent-ops-loading-frames)
  "Animation frames for loading spinner.")

(defun ogent-refinery--start-loading ()
  "Start the loading animation."
  (setq ogent-refinery--loading t
        ogent-refinery--loading-frame 0)
  (ogent-refinery--stop-loading-timer)
  (setq ogent-refinery--loading-timer
        (run-at-time 0.25 0.25 #'ogent-refinery--animate-loading (current-buffer)))
  (force-mode-line-update))

(defun ogent-refinery--stop-loading ()
  "Stop the loading animation."
  (ogent-refinery--stop-loading-timer)
  (setq ogent-refinery--loading nil)
  (force-mode-line-update))

(defun ogent-refinery--stop-loading-timer ()
  "Cancel the loading timer if active."
  (when ogent-refinery--loading-timer
    (cancel-timer ogent-refinery--loading-timer)
    (setq ogent-refinery--loading-timer nil)))

(defun ogent-refinery--animate-loading (buffer)
  "Advance the loading animation frame in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ogent-refinery--loading-frame
            (mod (1+ ogent-refinery--loading-frame) 4))
      (force-mode-line-update))))

(defun ogent-refinery--loading-indicator ()
  "Return the current loading spinner character."
  (when ogent-refinery--loading
    (nth ogent-refinery--loading-frame ogent-refinery--loading-frames)))

;;; Header Line

(defun ogent-refinery--header-line ()
  "Generate header line for Refinery buffer."
  (let ((loading-indicator (ogent-refinery--loading-indicator))
        (queue-count (length (ogent-refinery--filter-queue-status 'waiting)))
        (processing-count (length (ogent-refinery--filter-queue-status 'processing)))
        (failed-count (length (ogent-refinery--filter-queue-status 'failed))))
    (concat
     (propertize " " 'face 'ogent-refinery-header-line)
     (propertize (format "Refinery: %s" (or ogent-refinery--rig "?"))
                 'face 'ogent-refinery-header-line)
     (if loading-indicator
         (concat (propertize "  " 'face 'ogent-refinery-dimmed)
                 (propertize loading-indicator 'face 'ogent-refinery-queue-processing)
                 (propertize " Loading..." 'face 'ogent-refinery-dimmed))
       (concat
        (propertize "  " 'face 'ogent-refinery-dimmed)
        (when (> queue-count 0)
          (concat
           (propertize (format "%d queued" queue-count)
                       'face 'ogent-refinery-queue-ready)
           (propertize "  " 'face 'ogent-refinery-dimmed)))
        (when (> processing-count 0)
          (concat
           (propertize (format "%d processing" processing-count)
                       'face 'ogent-refinery-queue-processing)
           (propertize "  " 'face 'ogent-refinery-dimmed)))
        (when (> failed-count 0)
          (concat
           (propertize (format "%d failed" failed-count)
                       'face 'ogent-refinery-queue-failed)
           (propertize "  " 'face 'ogent-refinery-dimmed)))
        (propertize "g" 'face 'ogent-refinery-header-line-key)
        (propertize ":refresh " 'face 'ogent-refinery-dimmed)
        (propertize "q" 'face 'ogent-refinery-header-line-key)
        (propertize ":quit" 'face 'ogent-refinery-dimmed))))))

;;; Data Filtering

(defun ogent-refinery--filter-queue-status (status)
  "Filter queue data by STATUS.
STATUS can be `waiting', `processing', `failed', or `blocked'."
  (when ogent-refinery--queue-data
    (seq-filter
     (lambda (mr)
       (let ((mr-status (plist-get mr :status)))
         (pcase status
           ('waiting (member mr-status '("ready" "pending" "queued")))
           ('processing (member mr-status '("in_progress" "processing" "testing" "rebasing")))
           ('failed (member mr-status '("failed" "error")))
           ('blocked (member mr-status '("blocked"))))))
     ogent-refinery--queue-data)))

;;; Data Fetching

(defun ogent-refinery--fetch-all (callback)
  "Fetch all data for the status buffer, call CALLBACK when done."
  (let ((pending 1)
        (results (make-hash-table))
        (buf (current-buffer))
        (rig ogent-refinery--rig))
    (cl-flet ((check-done ()
                (cl-decf pending)
                (when (zerop pending)
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (setq ogent-refinery--queue-data (gethash 'queue results))
                      (funcall callback))))))

      ;; Fetch queue
      (ogent-refinery--run-async
       (list "mq" "list" rig "--json")
       (lambda (result)
         (puthash 'queue (if (listp result) result nil) results)
         (check-done))
       (lambda (_err)
         (puthash 'queue nil results)
         (check-done))))))

;;; Buffer Rendering

(defun ogent-refinery--insert-buffer-contents ()
  "Insert all sections into the buffer."
  (if ogent-refinery--magit-section-available
      (ogent-refinery--insert-with-magit-section)
    (ogent-refinery--insert-plain)))

(defun ogent-refinery--insert-with-magit-section ()
  "Insert content using magit-section."
  (magit-insert-section (ogent-refinery-root-section)
    (ogent-refinery--insert-processing-section)
    (insert "\n")
    (ogent-refinery--insert-queue-section)
    (insert "\n")
    (ogent-refinery--insert-failed-section)
    (insert "\n")
    (ogent-refinery--insert-history-section)))

(defun ogent-refinery--insert-plain ()
  "Insert content without magit-section (fallback)."
  (ogent-refinery--insert-processing-section-plain)
  (insert "\n")
  (ogent-refinery--insert-queue-section-plain)
  (insert "\n")
  (ogent-refinery--insert-failed-section-plain)
  (insert "\n")
  (ogent-refinery--insert-history-section-plain))

;;; Processing Section

(defun ogent-refinery--insert-processing-section ()
  "Insert currently processing section with magit-section."
  (let ((processing (ogent-refinery--filter-queue-status 'processing)))
    (magit-insert-section (ogent-refinery-processing-section processing)
      (magit-insert-heading
       (ogent-refinery--compose-section-heading
        'processing
        (ogent-ops-section-prefix "⚙" "*")
        "Processing"
        (when processing
          (propertize (format " (%d)" (length processing))
                      'face 'ogent-refinery-dimmed))))
      (if (null processing)
          (insert (propertize "  No active processing\n" 'face 'ogent-refinery-dimmed))
        (dolist (mr processing)
          (ogent-refinery--insert-mr-item mr 'processing))))))

(defun ogent-refinery--insert-processing-section-plain ()
  "Insert processing section (plain)."
  (let ((processing (ogent-refinery--filter-queue-status 'processing)))
    (insert (propertize "* Processing\n"
                        'face (ogent-refinery--section-heading-face 'processing)))
    (if (null processing)
        (insert (propertize "  No active processing\n" 'face 'ogent-refinery-dimmed))
      (dolist (mr processing)
        (ogent-refinery--insert-mr-item-plain mr)))))

;;; Queue Section

(defun ogent-refinery--insert-queue-section ()
  "Insert queue status section with magit-section."
  (let ((waiting (ogent-refinery--filter-queue-status 'waiting))
        (blocked (ogent-refinery--filter-queue-status 'blocked)))
    (magit-insert-section (ogent-refinery-queue-section waiting nil)
      (magit-insert-heading
       (ogent-refinery--compose-section-heading
        'queue
        (ogent-ops-section-prefix "⏳" "#")
        "Queue"
        (when waiting
          (propertize (format " (%d waiting)" (length waiting))
                      'face 'ogent-refinery-queue-ready))
        (when blocked
          (propertize (format " (%d blocked)" (length blocked))
                      'face 'ogent-refinery-queue-blocked))))
      (if (and (null waiting) (null blocked))
          (insert (propertize "  Queue is empty\n" 'face 'ogent-refinery-dimmed))
        (progn
          (dolist (mr waiting)
            (ogent-refinery--insert-mr-item mr 'waiting))
          (dolist (mr blocked)
            (ogent-refinery--insert-mr-item mr 'blocked)))))))

(defun ogent-refinery--insert-queue-section-plain ()
  "Insert queue section (plain)."
  (let ((waiting (ogent-refinery--filter-queue-status 'waiting)))
    (insert (propertize "# Queue\n"
                        'face (ogent-refinery--section-heading-face 'queue)))
    (if (null waiting)
        (insert (propertize "  Queue is empty\n" 'face 'ogent-refinery-dimmed))
      (dolist (mr waiting)
        (ogent-refinery--insert-mr-item-plain mr)))))

;;; Failed Section

(defun ogent-refinery--insert-failed-section ()
  "Insert failed/blocked section with magit-section."
  (let ((failed (ogent-refinery--filter-queue-status 'failed)))
    (magit-insert-section (ogent-refinery-failed-section failed nil)
      (magit-insert-heading
       (ogent-refinery--compose-section-heading
        'failed
        (ogent-ops-section-prefix "✗" "!")
        "Failed"
        (when failed
          (propertize (format " (%d)" (length failed))
                      'face 'ogent-refinery-queue-failed))))
      (if (null failed)
          (insert (propertize "  No failures\n" 'face 'ogent-refinery-dimmed))
        (dolist (mr failed)
          (ogent-refinery--insert-mr-item mr 'failed))))))

(defun ogent-refinery--insert-failed-section-plain ()
  "Insert failed section (plain)."
  (let ((failed (ogent-refinery--filter-queue-status 'failed)))
    (insert (propertize "! Failed\n"
                        'face (ogent-refinery--section-heading-face 'failed)))
    (if (null failed)
        (insert (propertize "  No failures\n" 'face 'ogent-refinery-dimmed))
      (dolist (mr failed)
        (ogent-refinery--insert-mr-item-plain mr)))))

;;; History Section

(defun ogent-refinery--insert-history-section ()
  "Insert merge history section with magit-section."
  (let ((history ogent-refinery--history-data))
    (magit-insert-section (ogent-refinery-history-section history nil)
      (magit-insert-heading
       (ogent-refinery--compose-section-heading
        'history
        (ogent-ops-section-prefix "✓" "+")
        "Recent Merges"
        (when history
          (propertize (format " (%d)" (length history))
                      'face 'ogent-refinery-dimmed))))
      (if (null history)
          (insert (propertize "  No recent merges\n" 'face 'ogent-refinery-dimmed))
        (dolist (mr history)
          (ogent-refinery--insert-mr-item mr 'merged))))))

(defun ogent-refinery--insert-history-section-plain ()
  "Insert history section (plain)."
  (let ((history ogent-refinery--history-data))
    (insert (propertize "+ Recent Merges\n"
                        'face (ogent-refinery--section-heading-face 'history)))
    (if (null history)
        (insert (propertize "  No recent merges\n" 'face 'ogent-refinery-dimmed))
      (dolist (mr history)
        (ogent-refinery--insert-mr-item-plain mr)))))

;;; MR Item Rendering

(defun ogent-refinery--priority-face (priority)
  "Return face for PRIORITY."
  (pcase priority
    ((or "P0" "critical") 'ogent-refinery-priority-p0)
    ((or "P1" "high") 'ogent-refinery-priority-p1)
    (_ 'ogent-refinery-priority-p2)))

(defun ogent-refinery--status-icon (status-type)
  "Return icon for STATUS-TYPE."
  (let ((ogent-ops-use-unicode ogent-refinery-use-unicode))
    (ogent-ops-status-symbol status-type)))

(defun ogent-refinery--section-heading-face (section)
  "Return heading face for SECTION."
  (pcase section
    ('processing 'ogent-refinery-section-heading-processing)
    ('queue 'ogent-refinery-section-heading-queue)
    ('failed 'ogent-refinery-section-heading-failed)
    ('history 'ogent-refinery-section-heading-history)
    (_ 'ogent-refinery-section-heading)))

(defun ogent-refinery--section-heading (section label)
  "Return LABEL propertized for SECTION heading."
  (propertize label 'face (ogent-refinery--section-heading-face section)))

(defun ogent-refinery--compose-section-heading (section prefix title &rest suffixes)
  "Compose a section heading for SECTION using PREFIX, TITLE, and SUFFIXES."
  (let* ((heading-face (ogent-refinery--section-heading-face section))
         (heading
          (concat prefix
                  " "
                  (ogent-refinery--section-heading section title)
                  (apply #'concat (delq nil suffixes)))))
    (add-face-text-property 0 (length heading) heading-face 'append heading)
    heading))

(defun ogent-refinery--format-age (timestamp)
  "Format TIMESTAMP as relative age string."
  (if timestamp
      (let* ((now (float-time))
             (then (if (stringp timestamp)
                       (float-time (date-to-time timestamp))
                     timestamp))
             (diff (- now then)))
        (cond
         ((< diff 60) "now")
         ((< diff 3600) (format "%dm" (/ diff 60)))
         ((< diff 86400) (format "%dh" (/ diff 3600)))
         (t (format "%dd" (/ diff 86400)))))
    "?"))

(defun ogent-refinery--insert-mr-item (mr status-type)
  "Insert a single MR as a magit-section.
MR is the merge request plist, STATUS-TYPE is the display context."
  (let* ((id (or (plist-get mr :id) "???"))
         (branch (or (plist-get mr :branch) (plist-get mr :name) "(unknown)"))
         (worker (or (plist-get mr :worker) (plist-get mr :polecat) ""))
         (priority (or (plist-get mr :priority) "P2"))
         (age (ogent-refinery--format-age (plist-get mr :created_at)))
         (status-face (pcase status-type
                        ('processing 'ogent-refinery-queue-processing)
                        ('waiting 'ogent-refinery-queue-ready)
                        ('blocked 'ogent-refinery-queue-blocked)
                        ('failed 'ogent-refinery-queue-failed)
                        ('merged 'ogent-refinery-merged)
                        (_ nil)))
         (icon (ogent-refinery--status-icon status-type)))
    (magit-insert-section (ogent-refinery-mr-section mr)
      (insert "  ")
      (insert (propertize icon 'face status-face))
      (insert " ")
      (insert (propertize id 'face 'ogent-refinery-dimmed))
      (insert " ")
      (insert (propertize priority 'face (ogent-refinery--priority-face priority)))
      (insert " ")
      (insert (propertize (truncate-string-to-width branch 40 nil nil "...")
                          'face 'ogent-refinery-branch))
      (when (and worker (not (string-empty-p worker)))
        (insert " ")
        (insert (propertize worker 'face 'ogent-refinery-worker)))
      (insert " ")
      (insert (propertize age 'face 'ogent-refinery-dimmed))
      ;; Show blocker info if blocked
      (when (eq status-type 'blocked)
        (let ((blocker (plist-get mr :blocked_by)))
          (when blocker
            (insert "\n      ")
            (insert (propertize (format "blocked by: %s" blocker)
                                'face 'ogent-refinery-dimmed)))))
      ;; Show error if failed
      (when (eq status-type 'failed)
        (let ((error-msg (or (plist-get mr :error) (plist-get mr :reason))))
          (when error-msg
            (insert "\n      ")
            (insert (propertize (truncate-string-to-width error-msg 60 nil nil "...")
                                'face 'ogent-refinery-queue-failed)))))
      (insert "\n"))))

(defun ogent-refinery--insert-mr-item-plain (mr)
  "Insert a single MR as plain text."
  (let* ((id (or (plist-get mr :id) "???"))
         (branch (or (plist-get mr :branch) "(unknown)"))
         (status (or (plist-get mr :status) "?")))
    (insert (format "  %s %s [%s]\n" id branch status))))

;;; Interactive Commands

(defun ogent-refinery-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the refinery buffer."
  (interactive)
  (when (derived-mode-p 'ogent-refinery-mode)
    (ogent-refinery--start-loading)
    (ogent-refinery--fetch-all
     (lambda ()
       (ogent-refinery--stop-loading)
       (let ((inhibit-read-only t)
             (pos (point)))
         (erase-buffer)
         (ogent-refinery--insert-buffer-contents)
         (goto-char (min pos (point-max))))))))

(defun ogent-refinery-refresh-force ()
  "Force refresh, clearing cache."
  (interactive)
  (ogent-refinery-cache-invalidate)
  (ogent-refinery-refresh))

(defun ogent-refinery-next-item ()
  "Move to the next MR item."
  (interactive)
  (if ogent-refinery--magit-section-available
      (magit-section-forward)
    (forward-line)))

(defun ogent-refinery-prev-item ()
  "Move to the previous MR item."
  (interactive)
  (if ogent-refinery--magit-section-available
      (magit-section-backward)
    (forward-line -1)))

(defun ogent-refinery-toggle-section ()
  "Toggle visibility of current section."
  (interactive)
  (when ogent-refinery--magit-section-available
    (magit-section-toggle (magit-current-section))))

(defun ogent-refinery--current-mr ()
  "Get the MR at point."
  (when ogent-refinery--magit-section-available
    (when-let ((section (magit-current-section)))
      ;; Use eq on class name to avoid cl-typep compile-time type resolution
      (when (eq (eieio-object-class-name section) 'ogent-refinery-mr-section)
        (oref section value)))))

(defun ogent-refinery-visit ()
  "View details of the MR at point."
  (interactive)
  (if-let ((mr (ogent-refinery--current-mr)))
      (let ((id (plist-get mr :id)))
        (when id
          (message "Viewing MR: %s" id)
          (shell-command (format "gt mq status %s" id))))
    (user-error "No merge request at point")))

(defun ogent-refinery-merge ()
  "Merge the MR at point.
Sends the merge request to the refinery for immediate processing
via `gt mq merge'."
  (interactive)
  (if-let ((mr (ogent-refinery--current-mr)))
      (let ((id (plist-get mr :id))
            (branch (or (plist-get mr :branch) (plist-get mr :name) "")))
        (when (yes-or-no-p (format "Merge %s (%s)? " id branch))
          (message "Merging: %s..." id)
          (ogent-refinery--run-async
           (list "mq" "merge" id)
           (lambda (_)
             (message "Merge initiated for %s" id)
             (ogent-refinery-cache-invalidate)
             (ogent-refinery-refresh))
           (lambda (err)
             (message "Merge failed: %s" err)))))
    (user-error "No merge request at point")))

(defun ogent-refinery-retry ()
  "Retry the failed MR at point."
  (interactive)
  (if-let ((mr (ogent-refinery--current-mr)))
      (let ((id (plist-get mr :id)))
        (when (yes-or-no-p (format "Retry failed merge request %s? " id))
          (message "Retrying: %s" id)
          (ogent-refinery--run-async
           (list "mq" "retry" id)
           (lambda (_)
             (message "Retry initiated for %s" id)
             (ogent-refinery-refresh))
           (lambda (err)
             (message "Retry failed: %s" err)))))
    (user-error "No merge request at point")))

(defun ogent-refinery-drop ()
  "Drop the MR at point from the queue."
  (interactive)
  (if-let ((mr (ogent-refinery--current-mr)))
      (let ((id (plist-get mr :id)))
        (when (yes-or-no-p (format "Drop %s from merge queue? " id))
          (message "Dropping: %s" id)
          (ogent-refinery--run-async
           (list "mq" "reject" id)
           (lambda (_)
             (message "Dropped %s from queue" id)
             (ogent-refinery-refresh))
           (lambda (err)
             (message "Drop failed: %s" err)))))
    (user-error "No merge request at point")))

(defun ogent-refinery-log ()
  "View merge log for the MR at point."
  (interactive)
  (if-let ((mr (ogent-refinery--current-mr)))
      (let ((branch (plist-get mr :branch)))
        (when branch
          (message "Showing log for: %s" branch)
          (shell-command (format "git log --oneline -20 %s" branch))))
    (user-error "No merge request at point")))

;;; Entry Point

;;;###autoload
(defun ogent-refinery-status (&optional rig)
  "Open the refinery merge queue buffer for RIG.
If RIG is nil, detect from current directory or prompt."
  (interactive
   (list (or (ogent-refinery--detect-rig)
             (read-string "Rig: "))))
  (unless rig
    (user-error "No rig specified"))
  (let ((buffer (get-buffer-create (format "*Refinery: %s*" rig))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ogent-refinery-mode)
        (ogent-refinery-mode))
      (setq ogent-refinery--rig rig)
      (ogent-refinery-refresh))
    (pop-to-buffer-same-window buffer)))

(provide 'ogent-refinery)
;;; ogent-refinery.el ends here
