;;; ogent-gastown-status.el --- Magit-style Gas Town status buffer -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-section based buffer for viewing Gas Town status.
;; Displays hook status, mail inbox, convoy progress, and workers overview.
;; Designed to feel native to magit users with familiar keybindings.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'json)

;; Soft dependency on magit-section
(eval-and-compile
  (defvar ogent-gastown--magit-section-available
    (require 'magit-section nil t)
    "Non-nil if magit-section is available.")
  (when ogent-gastown--magit-section-available
    (require 'magit-section)))

;; Declare magit functions to avoid byte-compile warnings
(declare-function magit-insert-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-section-forward "ext:magit-section")
(declare-function magit-section-backward "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-current-section "ext:magit-section")

;;; Customization

(defgroup ogent-gastown nil
  "Gas Town status viewer."
  :group 'ogent
  :prefix "ogent-gastown-")

(defcustom ogent-gastown-buffer-name "*Gas Town*"
  "Name of the Gas Town status buffer."
  :type 'string
  :group 'ogent-gastown)

(defcustom ogent-gastown-gt-executable "gt"
  "Path to the gt executable."
  :type 'string
  :group 'ogent-gastown)

(defcustom ogent-gastown-timeout 30
  "Timeout in seconds for gt commands."
  :type 'integer
  :group 'ogent-gastown)

(defcustom ogent-gastown-cache-ttl 5
  "Cache time-to-live in seconds."
  :type 'integer
  :group 'ogent-gastown)

(defcustom ogent-gastown-use-unicode t
  "Whether to use Unicode characters for icons."
  :type 'boolean
  :group 'ogent-gastown)

;;; Faces

(defgroup ogent-gastown-faces nil
  "Faces for ogent-gastown."
  :group 'ogent-gastown
  :group 'faces)

(defface ogent-gastown-section-heading
  '((((class color) (background light)) :foreground "#5d4037" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold))
  "Face for section headings."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-hook-active
  '((((class color) (background light)) :foreground "#2e7d32" :weight bold)
    (((class color) (background dark)) :foreground "#a3be8c" :weight bold))
  "Face for active hook indicator."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-hook-empty
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for empty hook state."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-mail-unread
  '((((class color) (background light)) :foreground "#1565c0" :weight bold)
    (((class color) (background dark)) :foreground "#88c0d0" :weight bold))
  "Face for unread mail."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-mail-read
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for read mail."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-mail-from
  '((((class color) (background light)) :foreground "#6a1b9a")
    (((class color) (background dark)) :foreground "#b48ead"))
  "Face for mail sender."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-convoy-active
  '((((class color) (background light)) :foreground "#6a1b9a" :weight bold)
    (((class color) (background dark)) :foreground "#b48ead" :weight bold))
  "Face for active convoy."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-convoy-complete
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c"))
  "Face for completed convoy."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-worker-running
  '((((class color) (background light)) :foreground "#2e7d32" :weight bold)
    (((class color) (background dark)) :foreground "#a3be8c" :weight bold))
  "Face for running worker."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-worker-done
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for done worker."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-worker-working
  '((((class color) (background light)) :foreground "#ff8f00" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold))
  "Face for working worker."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-dimmed
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for less important text."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-header-line
  '((((class color) (background light))
     :background "grey90" :foreground "grey20"
     :weight bold :box (:line-width 2 :color "grey90"))
    (((class color) (background dark))
     :background "#2e3440" :foreground "#eceff4"
     :weight bold :box (:line-width 2 :color "#2e3440")))
  "Face for the header line."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-header-line-key
  '((((class color) (background light))
     :background "grey90" :foreground "#5e35b1" :weight bold)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#b48ead" :weight bold))
  "Face for keybindings in header line."
  :group 'ogent-gastown-faces)

;;; Buffer-local State

(defvar-local ogent-gastown--hook-data nil
  "Cached hook status data.")

(defvar-local ogent-gastown--mail-data nil
  "Cached mail inbox data.")

(defvar-local ogent-gastown--convoy-data nil
  "Cached convoy list data.")

(defvar-local ogent-gastown--workers-data nil
  "Cached workers list data.")

(defvar-local ogent-gastown--rigs-data nil
  "Cached rig overview data from gt status.")

(defvar-local ogent-gastown--refinery-data nil
  "Cached refinery/merge-queue data per rig.")

(defvar-local ogent-gastown--loading nil
  "Non-nil when a gt command is in progress.")

(defvar-local ogent-gastown--loading-timer nil
  "Timer for animating the loading spinner.")

(defvar-local ogent-gastown--loading-frame 0
  "Current animation frame index.")

(defvar-local ogent-gastown--town-root nil
  "Gas Town root directory.")

;;; Cache

(defvar ogent-gastown--cache (make-hash-table :test 'equal)
  "Cache for gt command results.")

(defun ogent-gastown--cache-key (args)
  "Generate cache key from ARGS."
  (format "%S" args))

(defun ogent-gastown--cache-get (args)
  "Get cached result for ARGS if valid."
  (when (> ogent-gastown-cache-ttl 0)
    (let* ((key (ogent-gastown--cache-key args))
           (entry (gethash key ogent-gastown--cache)))
      (when entry
        (let ((timestamp (car entry))
              (result (cdr entry)))
          (if (< (float-time (time-subtract (current-time) timestamp))
                 ogent-gastown-cache-ttl)
              result
            (remhash key ogent-gastown--cache)
            nil))))))

(defun ogent-gastown--cache-set (args result)
  "Cache RESULT for ARGS."
  (when (> ogent-gastown-cache-ttl 0)
    (let ((key (ogent-gastown--cache-key args)))
      (puthash key (cons (current-time) result) ogent-gastown--cache))))

(defun ogent-gastown-cache-invalidate ()
  "Invalidate all cached results."
  (clrhash ogent-gastown--cache))

;;; Async Execution

(defvar ogent-gastown--processes nil
  "List of active gt processes.")

(defun ogent-gastown--run-async (args callback &optional error-callback raw-output)
  "Run gt with ARGS asynchronously, call CALLBACK with result.
ERROR-CALLBACK receives error message on failure.
If RAW-OUTPUT is non-nil, pass raw string instead of parsed JSON."
  (let* ((default-directory (or ogent-gastown--town-root
                                (ogent-gastown--find-town-root)
                                default-directory))
         (buffer (generate-new-buffer " *ogent-gt*"))
         (stderr-buffer (generate-new-buffer " *ogent-gt-stderr*"))
         (proc nil)
         (timer nil))

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

    (let ((full-command (cons ogent-gastown-gt-executable args)))
      (setq proc
            (make-process
             :name "ogent-gt"
             :buffer buffer
             :stderr stderr-buffer
             :command full-command
             :sentinel
             (lambda (process event)
               (when timer (cancel-timer timer))
               (setq ogent-gastown--processes
                     (delq process ogent-gastown--processes))

               (cond
                ((string= event "finished\n")
                 (with-current-buffer (process-buffer process)
                   (goto-char (point-min))
                   (skip-chars-forward " \t\n\r")
                   (condition-case err
                       (let ((result (if raw-output
                                         (buffer-string)
                                       (if (eobp)
                                           '()
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
                     (message "ogent-gt error: %s" (or stderr-content event))))
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer)))

                (t
                 (when (buffer-live-p (process-buffer process))
                   (kill-buffer (process-buffer process)))
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))))))))

    (push proc ogent-gastown--processes)
    proc))

;;; Town Detection

(defun ogent-gastown--find-town-root ()
  "Find the Gas Town root directory."
  (or (getenv "GT_ROOT")
      (expand-file-name "~/gt")))

(defun ogent-gastown--in-town-p ()
  "Return non-nil if gt is available."
  (executable-find ogent-gastown-gt-executable))

;;; Section Classes (when magit-section available)

(eval-and-compile
  (when (bound-and-true-p ogent-gastown--magit-section-available)
    (defclass ogent-gastown-root-section (magit-section) ()
      "Root section for Gas Town status buffer.")

    (defclass ogent-gastown-hook-section (magit-section) ()
      "Section for hook status.")

    (defclass ogent-gastown-mail-section (magit-section) ()
      "Section for mail inbox.")

    (defclass ogent-gastown-mail-item-section (magit-section) ()
      "Section for a single mail message.")

    (defclass ogent-gastown-convoy-section (magit-section) ()
      "Section for convoy status.")

    (defclass ogent-gastown-convoy-item-section (magit-section) ()
      "Section for a single convoy.")

    (defclass ogent-gastown-workers-section (magit-section) ()
      "Section for workers overview.")

    (defclass ogent-gastown-worker-section (magit-section) ()
      "Section for a single worker.")

    (defclass ogent-gastown-rigs-section (magit-section) ()
      "Section for rig overview.")

    (defclass ogent-gastown-rig-item-section (magit-section) ()
      "Section for a single rig.")

    (defclass ogent-gastown-refinery-section (magit-section) ()
      "Section for refinery/merge-queue status.")

    (defclass ogent-gastown-refinery-item-section (magit-section) ()
      "Section for a single refinery status.")))

;;; Keymap

(defvar ogent-gastown-mode-map
  (let ((map (make-sparse-keymap)))
    (when (and ogent-gastown--magit-section-available
               (boundp 'magit-section-mode-map))
      (set-keymap-parent map magit-section-mode-map))

    ;; Refresh
    (define-key map "g" #'ogent-gastown-refresh)
    (define-key map "G" #'ogent-gastown-refresh-force)

    ;; Navigation
    (define-key map "n" #'ogent-gastown-next-item)
    (define-key map "p" #'ogent-gastown-prev-item)
    (define-key map (kbd "TAB") #'ogent-gastown-toggle-section)
    (define-key map (kbd "RET") #'ogent-gastown-visit)

    ;; Mail actions
    (define-key map "m" #'ogent-gastown-mail-read)
    (define-key map "M" #'ogent-gastown-mail-compose)

    ;; Hook actions
    (define-key map "h" #'ogent-gastown-hook-show)
    (define-key map "H" #'ogent-gastown-hook-attach)

    ;; Convoy actions
    (define-key map "c" #'ogent-gastown-convoy-status)
    (define-key map "C" #'ogent-gastown-convoy-create)

    ;; Rig actions
    (define-key map "r" #'ogent-gastown-rig-status)
    (define-key map "R" #'ogent-gastown-rig-boot)

    ;; Refinery/MQ actions
    (define-key map "f" #'ogent-gastown-refinery-status)

    ;; Quit
    (define-key map "q" #'quit-window)

    map)
  "Keymap for `ogent-gastown-mode'.")

;;; Mode Definition

(defmacro ogent-gastown--define-mode ()
  "Define `ogent-gastown-mode' with appropriate parent mode."
  (let ((parent (if (bound-and-true-p ogent-gastown--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ogent-gastown-mode ,parent "Gas Town"
       "Major mode for viewing Gas Town status.

\\<ogent-gastown-mode-map>
Navigation:
  \\[ogent-gastown-next-item]     Move to next item
  \\[ogent-gastown-prev-item]     Move to previous item
  \\[ogent-gastown-visit]   Visit item details
  \\[ogent-gastown-toggle-section]   Toggle section visibility

Mail:
  \\[ogent-gastown-mail-read]     Read selected mail
  \\[ogent-gastown-mail-compose]     Compose new mail

Hook:
  \\[ogent-gastown-hook-show]     Show hook details
  \\[ogent-gastown-hook-attach]     Attach work to hook

Convoy:
  \\[ogent-gastown-convoy-status]     Show convoy status
  \\[ogent-gastown-convoy-create]     Create new convoy

Other:
  \\[ogent-gastown-refresh]     Refresh
  \\[quit-window]     Quit

\\{ogent-gastown-mode-map}"
       :group 'ogent-gastown
       (setq-local revert-buffer-function #'ogent-gastown-refresh)
       (setq-local truncate-lines t)
       (setq-local buffer-read-only t)
       (setq header-line-format '(:eval (ogent-gastown--header-line)))
       (when (bound-and-true-p ogent-gastown--magit-section-available)
         (setq-local magit-section-visibility-indicator
                     (if ogent-gastown-use-unicode '("..." . t) '("..." . t)))))))

(ogent-gastown--define-mode)

;;; Loading Animation

(defconst ogent-gastown--loading-frames
  (if (display-graphic-p)
      '("" "" "" "")
    '("|" "/" "-" "\\"))
  "Animation frames for loading spinner.")

(defun ogent-gastown--start-loading ()
  "Start the loading animation."
  (setq ogent-gastown--loading t
        ogent-gastown--loading-frame 0)
  (ogent-gastown--stop-loading-timer)
  (setq ogent-gastown--loading-timer
        (run-at-time 0.25 0.25 #'ogent-gastown--animate-loading (current-buffer)))
  (force-mode-line-update))

(defun ogent-gastown--stop-loading ()
  "Stop the loading animation."
  (ogent-gastown--stop-loading-timer)
  (setq ogent-gastown--loading nil)
  (force-mode-line-update))

(defun ogent-gastown--stop-loading-timer ()
  "Cancel the loading timer if active."
  (when ogent-gastown--loading-timer
    (cancel-timer ogent-gastown--loading-timer)
    (setq ogent-gastown--loading-timer nil)))

(defun ogent-gastown--animate-loading (buffer)
  "Advance the loading animation frame in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ogent-gastown--loading-frame
            (mod (1+ ogent-gastown--loading-frame) 4))
      (force-mode-line-update))))

(defun ogent-gastown--loading-indicator ()
  "Return the current loading spinner character."
  (when ogent-gastown--loading
    (nth ogent-gastown--loading-frame ogent-gastown--loading-frames)))

;;; Header Line

(defun ogent-gastown--header-line ()
  "Generate header line for Gas Town buffer."
  (let ((loading-indicator (ogent-gastown--loading-indicator))
        (mail-count (length (seq-filter
                             (lambda (m) (not (plist-get m :read)))
                             ogent-gastown--mail-data)))
        (hook-active (and ogent-gastown--hook-data
                          (plist-get ogent-gastown--hook-data :has_work))))
    (concat
     (propertize " " 'face 'ogent-gastown-header-line)
     (propertize "Gas Town" 'face 'ogent-gastown-header-line)
     (if loading-indicator
         (concat (propertize "  " 'face 'ogent-gastown-dimmed)
                 (propertize loading-indicator 'face 'ogent-gastown-hook-active)
                 (propertize " Loading..." 'face 'ogent-gastown-dimmed))
       (concat
        (propertize "  " 'face 'ogent-gastown-dimmed)
        (if hook-active
            (propertize "Hook: active" 'face 'ogent-gastown-hook-active)
          (propertize "Hook: empty" 'face 'ogent-gastown-hook-empty))
        (when (> mail-count 0)
          (concat (propertize "  " 'face 'ogent-gastown-dimmed)
                  (propertize (format "%d unread" mail-count)
                              'face 'ogent-gastown-mail-unread)))
        (propertize "  " 'face 'ogent-gastown-dimmed)
        (propertize "g" 'face 'ogent-gastown-header-line-key)
        (propertize ":refresh " 'face 'ogent-gastown-dimmed)
        (propertize "q" 'face 'ogent-gastown-header-line-key)
        (propertize ":quit" 'face 'ogent-gastown-dimmed))))))

;;; Data Fetching

(defun ogent-gastown--fetch-all (callback)
  "Fetch all data for the status buffer, call CALLBACK when done."
  (let ((pending 5)
        (results (make-hash-table))
        (buf (current-buffer)))
    (cl-flet ((check-done ()
                (cl-decf pending)
                (when (zerop pending)
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (setq ogent-gastown--hook-data (gethash 'hook results))
                      (setq ogent-gastown--mail-data (gethash 'mail results))
                      (setq ogent-gastown--convoy-data (gethash 'convoy results))
                      (setq ogent-gastown--workers-data (gethash 'workers results))
                      (setq ogent-gastown--rigs-data (gethash 'rigs results))
                      (funcall callback))))))

      ;; Fetch hook status
      (ogent-gastown--run-async
       '("hook" "--json")
       (lambda (result)
         (puthash 'hook result results)
         (check-done))
       (lambda (_err)
         (puthash 'hook nil results)
         (check-done)))

      ;; Fetch mail
      (ogent-gastown--run-async
       '("mail" "inbox" "--json")
       (lambda (result)
         (puthash 'mail result results)
         (check-done))
       (lambda (_err)
         (puthash 'mail nil results)
         (check-done)))

      ;; Fetch convoys
      (ogent-gastown--run-async
       '("convoy" "list" "--json")
       (lambda (result)
         (puthash 'convoy result results)
         (check-done))
       (lambda (_err)
         (puthash 'convoy nil results)
         (check-done)))

      ;; Fetch workers
      (ogent-gastown--run-async
       '("polecat" "list" "--all" "--json")
       (lambda (result)
         (puthash 'workers result results)
         (check-done))
       (lambda (_err)
         (puthash 'workers nil results)
         (check-done)))

      ;; Fetch rigs overview (includes refinery info)
      (ogent-gastown--run-async
       '("status" "--json" "--fast")
       (lambda (result)
         (puthash 'rigs (plist-get result :rigs) results)
         (check-done))
       (lambda (_err)
         (puthash 'rigs nil results)
         (check-done))))))

;;; Buffer Rendering

(defun ogent-gastown--insert-buffer-contents ()
  "Insert all sections into the buffer."
  (if ogent-gastown--magit-section-available
      (ogent-gastown--insert-with-magit-section)
    (ogent-gastown--insert-plain)))

(defun ogent-gastown--insert-with-magit-section ()
  "Insert content using magit-section."
  (magit-insert-section (ogent-gastown-root-section)
    (ogent-gastown--insert-hook-section)
    (insert "\n")
    (ogent-gastown--insert-mail-section)
    (insert "\n")
    (ogent-gastown--insert-rigs-section)
    (insert "\n")
    (ogent-gastown--insert-convoy-section)
    (insert "\n")
    (ogent-gastown--insert-workers-section)))

(defun ogent-gastown--insert-plain ()
  "Insert content without magit-section (fallback)."
  (ogent-gastown--insert-hook-section-plain)
  (insert "\n")
  (ogent-gastown--insert-mail-section-plain)
  (insert "\n")
  (ogent-gastown--insert-rigs-section-plain)
  (insert "\n")
  (ogent-gastown--insert-convoy-section-plain)
  (insert "\n")
  (ogent-gastown--insert-workers-section-plain))

;;; Hook Section

(defun ogent-gastown--insert-hook-section ()
  "Insert hook status section with magit-section."
  (let* ((data ogent-gastown--hook-data)
         (has-work (plist-get data :has_work))
         (role (or (plist-get data :role) "unknown"))
         (target (or (plist-get data :target) "unknown"))
         (next-action (plist-get data :next_action)))
    (magit-insert-section (ogent-gastown-hook-section data)
      (magit-insert-heading
        (concat
         (if ogent-gastown-use-unicode "" "#")
         " "
         (propertize "Hook Status" 'face 'ogent-gastown-section-heading)))
      (insert "  ")
      (insert (propertize "Role: " 'face 'ogent-gastown-dimmed))
      (insert (propertize role 'face 'ogent-gastown-section-heading))
      (insert "  ")
      (insert (propertize "Target: " 'face 'ogent-gastown-dimmed))
      (insert target)
      (insert "\n")
      (insert "  ")
      (if has-work
          (insert (propertize "Work hooked - ready to execute"
                              'face 'ogent-gastown-hook-active))
        (progn
          (insert (propertize "No work hooked" 'face 'ogent-gastown-hook-empty))
          (when next-action
            (insert "\n  ")
            (insert (propertize next-action 'face 'ogent-gastown-dimmed)))))
      (insert "\n"))))

(defun ogent-gastown--insert-hook-section-plain ()
  "Insert hook status section (plain)."
  (let* ((data ogent-gastown--hook-data)
         (has-work (plist-get data :has_work))
         (role (or (plist-get data :role) "unknown")))
    (insert (propertize "# Hook Status\n" 'face 'ogent-gastown-section-heading))
    (insert "  Role: " role "\n")
    (insert "  ")
    (if has-work
        (insert (propertize "Work hooked" 'face 'ogent-gastown-hook-active))
      (insert (propertize "No work hooked" 'face 'ogent-gastown-hook-empty)))
    (insert "\n")))

;;; Mail Section

(defun ogent-gastown--insert-mail-section ()
  "Insert mail inbox section with magit-section."
  (let* ((mail ogent-gastown--mail-data)
         (unread-count (length (seq-filter (lambda (m) (not (plist-get m :read))) mail))))
    (magit-insert-section (ogent-gastown-mail-section mail nil)
      (magit-insert-heading
        (concat
         (if ogent-gastown-use-unicode "" "@")
         " "
         (propertize "Mail Inbox" 'face 'ogent-gastown-section-heading)
         (when (> unread-count 0)
           (propertize (format " (%d unread)" unread-count)
                       'face 'ogent-gastown-mail-unread))))
      (if (null mail)
          (insert (propertize "  No messages\n" 'face 'ogent-gastown-dimmed))
        (dolist (msg mail)
          (ogent-gastown--insert-mail-item msg))))))

(defun ogent-gastown--insert-mail-item (msg)
  "Insert a single mail MSG as a section."
  (let* ((id (plist-get msg :id))
         (from (plist-get msg :from))
         (subject (plist-get msg :subject))
         (read (plist-get msg :read))
         (timestamp (plist-get msg :timestamp))
         (time-str (ogent-gastown--format-time timestamp)))
    (magit-insert-section (ogent-gastown-mail-item-section msg)
      (insert "  ")
      (insert (if read
                  (propertize "" 'face 'ogent-gastown-mail-read)
                (propertize "" 'face 'ogent-gastown-mail-unread)))
      (insert " ")
      (insert (propertize id 'face 'ogent-gastown-dimmed))
      (insert " ")
      (insert (propertize (truncate-string-to-width (or from "") 20 nil nil "...")
                          'face 'ogent-gastown-mail-from))
      (insert " ")
      (insert (propertize (truncate-string-to-width (or subject "") 40 nil nil "...")
                          'face (if read 'ogent-gastown-mail-read nil)))
      (insert " ")
      (insert (propertize time-str 'face 'ogent-gastown-dimmed))
      (insert "\n"))))

(defun ogent-gastown--insert-mail-section-plain ()
  "Insert mail section (plain)."
  (let ((mail ogent-gastown--mail-data))
    (insert (propertize "@ Mail Inbox\n" 'face 'ogent-gastown-section-heading))
    (if (null mail)
        (insert (propertize "  No messages\n" 'face 'ogent-gastown-dimmed))
      (dolist (msg mail)
        (let* ((from (plist-get msg :from))
               (subject (plist-get msg :subject))
               (read (plist-get msg :read)))
          (insert "  ")
          (insert (if read "  " "* "))
          (insert (or from "unknown"))
          (insert " - ")
          (insert (or subject "(no subject)"))
          (insert "\n"))))))

;;; Convoy Section

(defun ogent-gastown--insert-convoy-section ()
  "Insert convoy status section with magit-section."
  (let ((convoys ogent-gastown--convoy-data))
    (magit-insert-section (ogent-gastown-convoy-section convoys nil)
      (magit-insert-heading
        (concat
         (if ogent-gastown-use-unicode "" ">")
         " "
         (propertize "Convoys" 'face 'ogent-gastown-section-heading)
         (when convoys
           (propertize (format " (%d)" (length convoys))
                       'face 'ogent-gastown-dimmed))))
      (if (null convoys)
          (insert (propertize "  No active convoys\n" 'face 'ogent-gastown-dimmed))
        (dolist (convoy convoys)
          (ogent-gastown--insert-convoy-item convoy))))))

(defun ogent-gastown--insert-convoy-item (convoy)
  "Insert a single CONVOY as a section."
  (let* ((id (plist-get convoy :id))
         (name (plist-get convoy :name))
         (status (plist-get convoy :status))
         (progress (plist-get convoy :progress)))
    (magit-insert-section (ogent-gastown-convoy-item-section convoy)
      (insert "  ")
      (insert (propertize (or id "???") 'face 'ogent-gastown-dimmed))
      (insert " ")
      (insert (propertize (or name "(unnamed)")
                          'face (if (string= status "complete")
                                    'ogent-gastown-convoy-complete
                                  'ogent-gastown-convoy-active)))
      (when progress
        (insert " ")
        (insert (propertize progress 'face 'ogent-gastown-dimmed)))
      (insert "\n"))))

(defun ogent-gastown--insert-convoy-section-plain ()
  "Insert convoy section (plain)."
  (let ((convoys ogent-gastown--convoy-data))
    (insert (propertize "> Convoys\n" 'face 'ogent-gastown-section-heading))
    (if (null convoys)
        (insert (propertize "  No active convoys\n" 'face 'ogent-gastown-dimmed))
      (dolist (convoy convoys)
        (insert "  ")
        (insert (or (plist-get convoy :name) "(unnamed)"))
        (insert "\n")))))

;;; Rigs Section

(defface ogent-gastown-rig-name
  '((((class color) (background light)) :foreground "#5d4037" :weight bold)
    (((class color) (background dark)) :foreground "#ebcb8b" :weight bold))
  "Face for rig names."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-rig-running
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c"))
  "Face for running rig indicator."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-rig-stopped
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for stopped rig indicator."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-refinery-active
  '((((class color) (background light)) :foreground "#6a1b9a" :weight bold)
    (((class color) (background dark)) :foreground "#b48ead" :weight bold))
  "Face for active refinery."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-refinery-idle
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for idle refinery."
  :group 'ogent-gastown-faces)

(defun ogent-gastown--insert-rigs-section ()
  "Insert rigs overview section with magit-section."
  (let ((rigs ogent-gastown--rigs-data))
    (magit-insert-section (ogent-gastown-rigs-section rigs nil)
      (magit-insert-heading
        (concat
         (if ogent-gastown-use-unicode "🏗" "#")
         " "
         (propertize "Rigs" 'face 'ogent-gastown-section-heading)
         (propertize (format " (%d)" (length rigs))
                     'face 'ogent-gastown-dimmed)))
      (if (null rigs)
          (insert (propertize "  No rigs configured\n" 'face 'ogent-gastown-dimmed))
        (dolist (rig rigs)
          (ogent-gastown--insert-rig-item rig))))))

(defun ogent-gastown--insert-rig-item (rig)
  "Insert a single RIG as a collapsible section."
  (let* ((name (plist-get rig :name))
         (polecat-count (or (plist-get rig :polecat_count) 0))
         (crew-count (or (plist-get rig :crew_count) 0))
         (has-witness (plist-get rig :has_witness))
         (has-refinery (plist-get rig :has_refinery))
         (agents (plist-get rig :agents))
         (running-count (length (seq-filter
                                 (lambda (a) (plist-get a :running))
                                 agents))))
    (magit-insert-section (ogent-gastown-rig-item-section rig t)
      (magit-insert-heading
        (concat
         "  "
         (propertize name 'face 'ogent-gastown-rig-name)
         " "
         (propertize (format "P:%d C:%d" polecat-count crew-count)
                     'face 'ogent-gastown-dimmed)
         " "
         (if (> running-count 0)
             (propertize (format "[%d running]" running-count)
                         'face 'ogent-gastown-rig-running)
           (propertize "[stopped]" 'face 'ogent-gastown-rig-stopped))
         (when has-witness
           (concat " " (propertize "W" 'face 'ogent-gastown-dimmed)))
         (when has-refinery
           (concat " " (propertize "R" 'face 'ogent-gastown-dimmed)))))
      ;; Show agents when expanded
      (when agents
        (dolist (agent agents)
          (ogent-gastown--insert-rig-agent agent))))))

(defun ogent-gastown--insert-rig-agent (agent)
  "Insert a single AGENT line within a rig section."
  (let* ((name (plist-get agent :name))
         (role (plist-get agent :role))
         (running (plist-get agent :running))
         (has-work (plist-get agent :has_work))
         (unread (or (plist-get agent :unread_mail) 0))
         (role-icon (pcase role
                      ("witness" (if ogent-gastown-use-unicode "👁" "W"))
                      ("refinery" (if ogent-gastown-use-unicode "⚙" "R"))
                      ("polecat" (if ogent-gastown-use-unicode "🐱" "P"))
                      ("crew" (if ogent-gastown-use-unicode "👤" "C"))
                      (_ "?"))))
    (insert "    ")
    (insert (propertize role-icon 'face 'ogent-gastown-dimmed))
    (insert " ")
    (insert (propertize name
                        'face (if running
                                  'ogent-gastown-worker-running
                                'ogent-gastown-worker-done)))
    (when has-work
      (insert " ")
      (insert (propertize "⚓" 'face 'ogent-gastown-hook-active)))
    (when (> unread 0)
      (insert " ")
      (insert (propertize (format "📬%d" unread) 'face 'ogent-gastown-mail-unread)))
    (insert "\n")))

(defun ogent-gastown--insert-rigs-section-plain ()
  "Insert rigs section (plain)."
  (let ((rigs ogent-gastown--rigs-data))
    (insert (propertize "# Rigs\n" 'face 'ogent-gastown-section-heading))
    (if (null rigs)
        (insert (propertize "  No rigs configured\n" 'face 'ogent-gastown-dimmed))
      (dolist (rig rigs)
        (let* ((name (plist-get rig :name))
               (polecat-count (or (plist-get rig :polecat_count) 0))
               (crew-count (or (plist-get rig :crew_count) 0)))
          (insert "  ")
          (insert name)
          (insert (format " (P:%d C:%d)" polecat-count crew-count))
          (insert "\n"))))))

;;; Workers Section

(defun ogent-gastown--insert-workers-section ()
  "Insert workers overview section with magit-section."
  (let ((workers ogent-gastown--workers-data)
        (running-count 0))
    (dolist (w workers)
      (when (plist-get w :session_running)
        (cl-incf running-count)))
    (magit-insert-section (ogent-gastown-workers-section workers nil)
      (magit-insert-heading
        (concat
         (if ogent-gastown-use-unicode "" "*")
         " "
         (propertize "Workers" 'face 'ogent-gastown-section-heading)
         (propertize (format " (%d/%d running)"
                             running-count (length workers))
                     'face 'ogent-gastown-dimmed)))
      (if (null workers)
          (insert (propertize "  No workers\n" 'face 'ogent-gastown-dimmed))
        ;; Group by rig
        (let ((by-rig (seq-group-by (lambda (w) (plist-get w :rig)) workers)))
          (dolist (rig-group by-rig)
            (let ((rig (car rig-group))
                  (rig-workers (cdr rig-group)))
              (insert "  ")
              (insert (propertize rig 'face 'ogent-gastown-section-heading))
              (insert ":\n")
              (dolist (worker rig-workers)
                (ogent-gastown--insert-worker-item worker)))))))))

(defun ogent-gastown--insert-worker-item (worker)
  "Insert a single WORKER as a line."
  (let* ((name (plist-get worker :name))
         (state (plist-get worker :state))
         (running (plist-get worker :session_running))
         (state-face (cond
                      (running 'ogent-gastown-worker-running)
                      ((string= state "working") 'ogent-gastown-worker-working)
                      (t 'ogent-gastown-worker-done)))
         (icon (cond
                (running (if ogent-gastown-use-unicode "" ">"))
                ((string= state "working") (if ogent-gastown-use-unicode "" "*"))
                (t (if ogent-gastown-use-unicode "" "-")))))
    (insert "    ")
    (insert (propertize icon 'face state-face))
    (insert " ")
    (insert (propertize name 'face state-face))
    (insert " ")
    (insert (propertize (format "[%s]" state) 'face 'ogent-gastown-dimmed))
    (when running
      (insert " ")
      (insert (propertize "running" 'face 'ogent-gastown-worker-running)))
    (insert "\n")))

(defun ogent-gastown--insert-workers-section-plain ()
  "Insert workers section (plain)."
  (let ((workers ogent-gastown--workers-data))
    (insert (propertize "* Workers\n" 'face 'ogent-gastown-section-heading))
    (if (null workers)
        (insert (propertize "  No workers\n" 'face 'ogent-gastown-dimmed))
      (dolist (worker workers)
        (insert "  ")
        (insert (plist-get worker :rig))
        (insert "/")
        (insert (plist-get worker :name))
        (insert " [")
        (insert (plist-get worker :state))
        (insert "]\n")))))

;;; Utilities

(defun ogent-gastown--format-time (iso-time)
  "Format ISO-TIME as relative time string."
  (if (and iso-time (stringp iso-time) (not (string-empty-p iso-time)))
      (condition-case nil
          (let* ((time (parse-iso8601-time-string iso-time))
                 (diff (float-time (time-subtract (current-time) time))))
            (cond
             ((< diff 60) "just now")
             ((< diff 3600) (format "%dm ago" (/ (truncate diff) 60)))
             ((< diff 86400) (format "%dh ago" (/ (truncate diff) 3600)))
             (t (format-time-string "%b %d" time))))
        (error "???"))
    "???"))

;;; Navigation

(defun ogent-gastown-next-item ()
  "Move to the next item."
  (interactive)
  (if ogent-gastown--magit-section-available
      (magit-section-forward)
    (forward-line)))

(defun ogent-gastown-prev-item ()
  "Move to the previous item."
  (interactive)
  (if ogent-gastown--magit-section-available
      (magit-section-backward)
    (forward-line -1)))

(defun ogent-gastown-toggle-section ()
  "Toggle the current section."
  (interactive)
  (if ogent-gastown--magit-section-available
      (magit-section-toggle (magit-current-section))
    (message "Section toggling requires magit-section")))

(defun ogent-gastown-visit ()
  "Visit the item at point."
  (interactive)
  (when ogent-gastown--magit-section-available
    (let ((section (magit-current-section)))
      (cond
       ((eq (eieio-object-class-name section) 'ogent-gastown-mail-item-section)
        (let* ((msg (oref section value))
               (id (plist-get msg :id)))
          (ogent-gastown-mail-read id)))
       (t
        (magit-section-toggle section))))))

;;; Actions

(defun ogent-gastown-mail-read (&optional id)
  "Read mail message ID."
  (interactive)
  (let ((mail-id (or id
                     (when ogent-gastown--magit-section-available
                       (let ((section (magit-current-section)))
                         (when (eq (eieio-object-class-name section)
                                   'ogent-gastown-mail-item-section)
                           (plist-get (oref section value) :id))))
                     (completing-read "Mail ID: "
                                      (mapcar (lambda (m) (plist-get m :id))
                                              ogent-gastown--mail-data)))))
    (when mail-id
      (let ((cmd (format "%s mail read %s" ogent-gastown-gt-executable mail-id)))
        (async-shell-command cmd "*gt mail*")))))

(defun ogent-gastown-mail-compose ()
  "Compose a new mail message."
  (interactive)
  (let* ((to (read-string "To: "))
         (subject (read-string "Subject: "))
         (body (read-string "Message: ")))
    (ogent-gastown--run-async
     (list "mail" "send" to "-s" subject "-m" body)
     (lambda (_result)
       (message "Mail sent to %s" to)
       (ogent-gastown-cache-invalidate)
       (ogent-gastown-refresh))
     (lambda (err)
       (message "Failed to send mail: %s" err))
     t)))

(defun ogent-gastown-hook-show ()
  "Show hook details."
  (interactive)
  (async-shell-command (format "%s hook" ogent-gastown-gt-executable) "*gt hook*"))

(defun ogent-gastown-hook-attach ()
  "Attach work to hook."
  (interactive)
  (let ((bead-id (read-string "Bead ID to hook: ")))
    (ogent-gastown--run-async
     (list "hook" bead-id)
     (lambda (_result)
       (message "Hooked: %s" bead-id)
       (ogent-gastown-cache-invalidate)
       (ogent-gastown-refresh))
     (lambda (err)
       (message "Failed to hook: %s" err))
     t)))

(defun ogent-gastown-convoy-status ()
  "Show convoy status."
  (interactive)
  (let ((convoy-id (when ogent-gastown--magit-section-available
                     (let ((section (magit-current-section)))
                       (when (eq (eieio-object-class-name section)
                                 'ogent-gastown-convoy-item-section)
                         (plist-get (oref section value) :id))))))
    (if convoy-id
        (async-shell-command
         (format "%s convoy status %s" ogent-gastown-gt-executable convoy-id)
         "*gt convoy*")
      (async-shell-command
       (format "%s convoy list" ogent-gastown-gt-executable)
       "*gt convoy*"))))

(defun ogent-gastown-convoy-create ()
  "Create a new convoy."
  (interactive)
  (let* ((name (read-string "Convoy name: "))
         (issues (read-string "Issue IDs (space-separated): ")))
    (ogent-gastown--run-async
     (append (list "convoy" "create" name) (split-string issues))
     (lambda (_result)
       (message "Created convoy: %s" name)
       (ogent-gastown-cache-invalidate)
       (ogent-gastown-refresh))
     (lambda (err)
       (message "Failed to create convoy: %s" err))
     t)))

(defun ogent-gastown-rig-status ()
  "Show status for rig at point or prompt for rig name."
  (interactive)
  (let ((rig-name (when ogent-gastown--magit-section-available
                    (let ((section (magit-current-section)))
                      (when (eq (eieio-object-class-name section)
                                'ogent-gastown-rig-item-section)
                        (plist-get (oref section value) :name))))))
    (unless rig-name
      (setq rig-name (completing-read
                      "Rig: "
                      (mapcar (lambda (r) (plist-get r :name))
                              ogent-gastown--rigs-data))))
    (when rig-name
      (async-shell-command
       (format "%s rig status %s" ogent-gastown-gt-executable rig-name)
       "*gt rig*"))))

(defun ogent-gastown-rig-boot ()
  "Boot (start) rig at point or prompt for rig name."
  (interactive)
  (let ((rig-name (when ogent-gastown--magit-section-available
                    (let ((section (magit-current-section)))
                      (when (eq (eieio-object-class-name section)
                                'ogent-gastown-rig-item-section)
                        (plist-get (oref section value) :name))))))
    (unless rig-name
      (setq rig-name (completing-read
                      "Rig to boot: "
                      (mapcar (lambda (r) (plist-get r :name))
                              ogent-gastown--rigs-data))))
    (when rig-name
      (message "Booting rig %s..." rig-name)
      (ogent-gastown--run-async
       (list "rig" "boot" rig-name)
       (lambda (_result)
         (message "Rig %s booted" rig-name)
         (ogent-gastown-cache-invalidate)
         (ogent-gastown-refresh))
       (lambda (err)
         (message "Failed to boot rig %s: %s" rig-name err))
       t))))

(defun ogent-gastown-refinery-status ()
  "Show refinery/merge-queue status for rig at point or prompt."
  (interactive)
  (let ((rig-name (when ogent-gastown--magit-section-available
                    (let ((section (magit-current-section)))
                      (cond
                       ((eq (eieio-object-class-name section)
                            'ogent-gastown-rig-item-section)
                        (plist-get (oref section value) :name))
                       ((eq (eieio-object-class-name section)
                            'ogent-gastown-refinery-item-section)
                        (plist-get (oref section value) :rig)))))))
    (unless rig-name
      (setq rig-name (completing-read
                      "Rig: "
                      (seq-filter
                       (lambda (name)
                         (let ((rig (seq-find
                                     (lambda (r) (equal (plist-get r :name) name))
                                     ogent-gastown--rigs-data)))
                           (plist-get rig :has_refinery)))
                       (mapcar (lambda (r) (plist-get r :name))
                               ogent-gastown--rigs-data)))))
    (when rig-name
      (async-shell-command
       (format "%s refinery status %s" ogent-gastown-gt-executable rig-name)
       "*gt refinery*"))))

;;; Refresh

(defun ogent-gastown-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the Gas Town status buffer."
  (interactive)
  (let ((buf (current-buffer)))
    (ogent-gastown--start-loading)
    (ogent-gastown--fetch-all
     (lambda ()
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-gastown--stop-loading)
           (let ((inhibit-read-only t)
                 (pos (point)))
             (erase-buffer)
             (ogent-gastown--insert-buffer-contents)
             (goto-char (min pos (point-max))))))))))

(defun ogent-gastown-refresh-force ()
  "Force refresh, clearing cache."
  (interactive)
  (ogent-gastown-cache-invalidate)
  (ogent-gastown-refresh))

;;; Entry Point

;;;###autoload
(defun ogent-gastown-status ()
  "Open the Gas Town status buffer."
  (interactive)
  (unless (ogent-gastown--in-town-p)
    (user-error "Gas Town CLI (gt) not found in PATH"))
  (let ((buf (get-buffer-create ogent-gastown-buffer-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'ogent-gastown-mode)
        (ogent-gastown-mode))
      (setq ogent-gastown--town-root (ogent-gastown--find-town-root))
      (ogent-gastown-refresh))
    (switch-to-buffer buf)))

;;; Cleanup

(defun ogent-gastown--cleanup-on-kill ()
  "Clean up timers when the buffer is killed."
  (ogent-gastown--stop-loading-timer))

(add-hook 'ogent-gastown-mode-hook
          (lambda ()
            (add-hook 'kill-buffer-hook #'ogent-gastown--cleanup-on-kill nil t)))

(provide 'ogent-gastown-status)

;;; ogent-gastown-status.el ends here
