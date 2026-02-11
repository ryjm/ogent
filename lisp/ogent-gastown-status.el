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
(require 'ogent-ops-style)

;; Soft dependency on magit-section
(eval-and-compile
  (defvar ogent-gastown--magit-section-available
    (require 'magit-section nil t)
    "Non-nil if magit-section is available.")
  (when ogent-gastown--magit-section-available
    (require 'magit-section)))

;; Load transient help menu if available
(declare-function ogent-gastown-status-dispatch "ogent-gastown-status-transient" nil t)
(autoload 'ogent-gastown-status-dispatch "ogent-gastown-status-transient" nil t)

;; Load ogent-issues for rig → issues navigation
(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-issues-bd-get "ogent-issues-bd" nil nil)
(autoload 'ogent-issues--show-detail "ogent-issues" nil nil)

;; Load ogent-convoy for convoy inspector navigation
(autoload 'ogent-convoy-inspect "ogent-convoy" nil t)

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

(defcustom ogent-gastown-default-town-root "~/gt"
  "Default Gas Town root used when workspace detection cannot infer one."
  :type 'directory
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

(defcustom ogent-gastown-workspace-display-width 36
  "Maximum width for workspace path display in the status header."
  :type 'integer
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

(defface ogent-gastown-stats-label
  '((((class color) (background light)) :foreground "#37474f")
    (((class color) (background dark)) :foreground "#d8dee9"))
  "Face for stats labels."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-stats-value
  '((((class color) (background light)) :foreground "#1565c0" :weight bold)
    (((class color) (background dark)) :foreground "#88c0d0" :weight bold))
  "Face for stats values."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-deacon-running
  '((((class color) (background light)) :foreground "#2e7d32" :weight bold)
    (((class color) (background dark)) :foreground "#a3be8c" :weight bold))
  "Face for running deacon."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-deacon-stopped
  '((((class color) (background light)) :foreground "#c62828")
    (((class color) (background dark)) :foreground "#bf616a"))
  "Face for stopped deacon."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-witness-healthy
  '((((class color) (background light)) :foreground "#2e7d32")
    (((class color) (background dark)) :foreground "#a3be8c"))
  "Face for healthy witness."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-witness-unhealthy
  '((((class color) (background light)) :foreground "#c62828")
    (((class color) (background dark)) :foreground "#bf616a"))
  "Face for unhealthy witness."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-crew-active
  '((((class color) (background light)) :foreground "#1565c0" :weight bold)
    (((class color) (background dark)) :foreground "#5e81ac" :weight bold))
  "Face for active crew member."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-crew-idle
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for idle crew member."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-polecat-active
  '((((class color) (background light)) :foreground "#6a1b9a" :weight bold)
    (((class color) (background dark)) :foreground "#b48ead" :weight bold))
  "Face for active polecat."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-polecat-idle
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a"))
  "Face for idle polecat."
  :group 'ogent-gastown-faces)

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

(defface ogent-gastown-beads-in-progress
  '((((class color) (background light)) :foreground "#ff8f00" :weight bold)
    (((class color) (background dark)) :foreground "#e5c07b" :weight bold))
  "Face for in-progress beads count on rig lines."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-beads-ready
  '((((class color) (background light)) :foreground "#2e7d32" :weight bold)
    (((class color) (background dark)) :foreground "#98c379" :weight bold))
  "Face for ready beads count on rig lines."
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
  "Cached convoy list data (normalized).")

(defun ogent-gastown--normalize-convoy (convoy)
  "Normalize CONVOY plist to canonical keys.
Accepts both modern payload shape (:title, :completed, :total, :tracked)
and legacy shape (:name, :progress).  Returns a plist with canonical keys:
:id, :title, :status, :completed, :total, :tracked."
  (let* ((id (plist-get convoy :id))
         (title (or (plist-get convoy :title)
                    (plist-get convoy :name)))
         (status (plist-get convoy :status))
         (completed (plist-get convoy :completed))
         (total (plist-get convoy :total))
         (tracked (plist-get convoy :tracked))
         (progress (plist-get convoy :progress)))
    ;; Parse legacy :progress "N/M" when :completed/:total absent
    (when (and progress (not completed) (not total)
               (stringp progress)
               (string-match "\\`\\([0-9]+\\)/\\([0-9]+\\)\\'" progress))
      (setq completed (string-to-number (match-string 1 progress)))
      (setq total (string-to-number (match-string 2 progress))))
    (list :id id
          :title title
          :status status
          :completed completed
          :total total
          :tracked tracked)))

(defun ogent-gastown--normalize-convoy-list (convoys)
  "Normalize a list of CONVOYS to canonical shape."
  (mapcar #'ogent-gastown--normalize-convoy convoys))

(defun ogent-gastown--convoy-progress-string (convoy)
  "Format progress string from normalized CONVOY.
Returns \"COMPLETED/TOTAL\" or nil if data is missing."
  (let ((completed (plist-get convoy :completed))
        (total (plist-get convoy :total)))
    (when (and completed total)
      (format "%s/%s" completed total))))

(defvar-local ogent-gastown--workers-data nil
  "Cached workers list data.")

(defvar-local ogent-gastown--stats-data nil
  "Cached town statistics data.")

(defvar-local ogent-gastown--deacon-data nil
  "Cached deacon status data.")

(defvar-local ogent-gastown--witness-data nil
  "Cached witness status data (list of rig witness statuses).")

(defvar-local ogent-gastown--crew-data nil
  "Cached crew list data.")

(defvar-local ogent-gastown--polecat-data nil
  "Cached polecat list data.")

(defvar-local ogent-gastown--rigs-data nil
  "Cached rigs list data.")

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

(defun ogent-gastown--normalize-dir (dir)
  "Return DIR as an absolute directory path, or nil."
  (when (and dir (not (string-empty-p dir)) (file-directory-p dir))
    (file-name-as-directory (expand-file-name dir))))

(defun ogent-gastown--workspace-root-from-dir (dir)
  "Resolve a Gas Town workspace root from DIR, or nil."
  (let* ((expanded (and dir (expand-file-name dir)))
         (marker-root (and expanded (locate-dominating-file expanded ".gastown")))
         (default-root
          (file-name-as-directory
           (expand-file-name ogent-gastown-default-town-root))))
    (or (ogent-gastown--normalize-dir marker-root)
        (when (and expanded (string-prefix-p default-root (file-name-as-directory expanded)))
          default-root))))

(defun ogent-gastown--active-workspace-root ()
  "Return the active workspace root for status commands, or nil."
  (or (ogent-gastown--normalize-dir ogent-gastown--town-root)
      (ogent-gastown--find-town-root)))

(defun ogent-gastown-status--run-async (args callback &optional error-callback raw-output)
  "Run gt with ARGS asynchronously, call CALLBACK with result.
ERROR-CALLBACK receives error message on failure.
If RAW-OUTPUT is non-nil, pass raw string instead of parsed JSON."
  (let* ((workspace-root (ogent-gastown--active-workspace-root)))
    (unless workspace-root
      (if error-callback
          (funcall error-callback "Not in a Gas Town workspace")
        (message "ogent-gt error: Not in a Gas Town workspace"))
      (cl-return-from ogent-gastown-status--run-async nil))

    (let* ((default-directory workspace-root)
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
    proc)))

(defun ogent-gastown-status--run-shell-command (args output-buffer)
  "Run `gt` command ARGS in OUTPUT-BUFFER from the active workspace root."
  (let ((workspace-root (ogent-gastown--active-workspace-root)))
    (unless workspace-root
      (user-error "Not in a Gas Town workspace"))
    (let ((default-directory workspace-root))
      (async-shell-command
       (string-join
        (mapcar #'shell-quote-argument
                (cons ogent-gastown-gt-executable args))
        " ")
       output-buffer))))

;;; Town Detection

(defun ogent-gastown--find-town-root ()
  "Find the current Gas Town workspace root, or nil.
Resolution order:
1) `GT_ROOT' environment variable
2) `GT_TOWN' environment variable
3) `.gastown' marker from `default-directory' upward
4) parent `ogent-gastown-default-town-root' when current directory is under it
5) `ogent-gastown-default-town-root' fallback."
  (let ((env-root (or (ogent-gastown--normalize-dir (getenv "GT_ROOT"))
                      (ogent-gastown--normalize-dir (getenv "GT_TOWN")))))
    (or env-root
        (ogent-gastown--workspace-root-from-dir default-directory)
        (ogent-gastown--normalize-dir ogent-gastown-default-town-root))))

(defun ogent-gastown--in-town-p ()
  "Return non-nil if gt is available and workspace root is resolvable."
  (and (executable-find ogent-gastown-gt-executable)
       (ogent-gastown--find-town-root)))

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

    (defclass ogent-gastown-stats-section (magit-section) ()
      "Section for town statistics.")

    (defclass ogent-gastown-deacon-section (magit-section) ()
      "Section for deacon status.")

    (defclass ogent-gastown-witness-section (magit-section) ()
      "Section for witness status overview.")

    (defclass ogent-gastown-witness-item-section (magit-section) ()
      "Section for a single rig witness.")

    (defclass ogent-gastown-crew-section (magit-section) ()
      "Section for crew members.")

    (defclass ogent-gastown-crew-item-section (magit-section) ()
      "Section for a single crew member.")

    (defclass ogent-gastown-polecat-section (magit-section) ()
      "Section for polecats.")

    (defclass ogent-gastown-polecat-item-section (magit-section) ()
      "Section for a single polecat.")

    (defclass ogent-gastown-rigs-section (magit-section) ()
      "Section for rigs overview.")

    (defclass ogent-gastown-rig-item-section (magit-section) ()
      "Section for a single rig.")))

;;; Keymap

(defvar ogent-gastown-status-mode-map
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
    (define-key map (kbd "M-n") #'ogent-gastown-next-section)
    (define-key map (kbd "M-p") #'ogent-gastown-prev-section)
    (define-key map (kbd "TAB") #'ogent-gastown-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-gastown-cycle-sections)
    (define-key map (kbd "RET") #'ogent-gastown-visit)
    (define-key map (kbd "^") #'ogent-gastown-up-section)

    ;; Help/dispatch (magit-style: ?/h)
    (define-key map "?" #'ogent-gastown-status-dispatch)
    (define-key map "h" #'ogent-gastown-status-dispatch)

    ;; Mail actions
    (define-key map "m" #'ogent-gastown-status-mail-read)
    (define-key map "M" #'ogent-gastown-mail-compose)

    ;; Hook actions
    (define-key map "H" #'ogent-gastown-hook-show)
    (define-key map "a" #'ogent-gastown-hook-attach)

    ;; Convoy actions
    (define-key map "c" #'ogent-gastown-convoy-status)
    (define-key map "C" #'ogent-gastown-convoy-create)

    ;; Stats/Deacon/Witness actions
    (define-key map "s" #'ogent-gastown-stats-show)
    (define-key map "d" #'ogent-gastown-deacon-show)
    (define-key map "w" #'ogent-gastown-witness-show)

    ;; Crew actions
    (define-key map "R" #'ogent-gastown-crew-status)

    ;; Polecat actions
    (define-key map "P" #'ogent-gastown-polecat-status)

    ;; Rig actions
    (define-key map "r" #'ogent-gastown-rig-status)
    (define-key map "f" #'ogent-gastown-refinery-status)

    ;; Issues navigation
    (define-key map "i" #'ogent-gastown-rig-issues)

    ;; Quit
    (define-key map "q" #'quit-window)

    map)
  "Keymap for `ogent-gastown-status-mode'.")

;;; Mode Definition

(defmacro ogent-gastown--define-status-mode ()
  "Define `ogent-gastown-status-mode' with appropriate parent mode."
  (let ((parent (if (bound-and-true-p ogent-gastown--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ogent-gastown-status-mode ,parent "Gas Town"
       "Major mode for viewing Gas Town status.

Like `magit-status' but for your Gas Town multi-agent workspace.

\\<ogent-gastown-status-mode-map>
Navigation:
  \\[ogent-gastown-next-item]     Move to next item
  \\[ogent-gastown-prev-item]     Move to previous item
  \\[ogent-gastown-next-section]   Move to next section
  \\[ogent-gastown-prev-section]   Move to previous section
  \\[ogent-gastown-visit]   Visit item details
  \\[ogent-gastown-toggle-section]   Toggle section visibility
  \\[ogent-gastown-cycle-sections]   Cycle all section visibility
  \\[ogent-gastown-up-section]     Move to parent section

Mail:
  \\[ogent-gastown-status-mail-read]     Read selected mail
  \\[ogent-gastown-mail-compose]     Compose new mail

Hook:
  \\[ogent-gastown-hook-show]     Show hook details
  \\[ogent-gastown-hook-attach]     Attach work to hook

Convoy:
  \\[ogent-gastown-convoy-status]     Inspect convoy
  \\[ogent-gastown-convoy-create]     Create new convoy

Status:
  \\[ogent-gastown-stats-show]     Show town stats
  \\[ogent-gastown-deacon-show]     Show deacon status
  \\[ogent-gastown-witness-show]     Show witness status

Crew/Polecat:
  \\[ogent-gastown-crew-status]     Show crew status
  \\[ogent-gastown-polecat-status]     Show polecat status

Other:
  \\[ogent-gastown-refresh]     Refresh
  \\[ogent-gastown-status-dispatch]     Show command menu
  \\[quit-window]     Quit

\\{ogent-gastown-status-mode-map}"
       :group 'ogent-gastown
       (setq-local revert-buffer-function #'ogent-gastown-refresh)
       (setq-local truncate-lines t)
       (setq-local buffer-read-only t)
       (setq header-line-format '(:eval (ogent-gastown--header-line)))
       (when (bound-and-true-p ogent-gastown--magit-section-available)
         (setq-local magit-section-visibility-indicator
                     (if ogent-gastown-use-unicode '("…" . t) '("..." . t)))))))

(ogent-gastown--define-status-mode)

;; Backward compatibility alias
(defalias 'ogent-gastown-mode 'ogent-gastown-status-mode)

;;; Loading Animation

(defconst ogent-gastown--loading-frames (ogent-ops-loading-frames)
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

(defun ogent-gastown--workspace-root-for-display ()
  "Return workspace root for UI display, preferring buffer-local binding."
  (or (and (stringp ogent-gastown--town-root)
           (not (string-empty-p ogent-gastown--town-root))
           ogent-gastown--town-root)
      (ogent-gastown--find-town-root)))

(defun ogent-gastown--workspace-root-display (&optional root)
  "Return abbreviated workspace ROOT for compact UI display."
  (let* ((workspace-root (or root (ogent-gastown--workspace-root-for-display)))
         (trimmed (and workspace-root
                       (let ((p (directory-file-name (file-name-as-directory workspace-root))))
                         (if (string-empty-p p) "/" p))))
         (display (and trimmed (abbreviate-file-name trimmed)))
         (max-width (max 8 ogent-gastown-workspace-display-width)))
    (when display
      (if (> (length display) max-width)
          (concat "…" (substring display (- (length display) (1- max-width))))
        display))))

(defun ogent-gastown--header-workspace-segment ()
  "Return formatted workspace segment for the status header, or nil."
  (when-let ((workspace (ogent-gastown--workspace-root-display)))
    (concat
     (propertize "  " 'face 'ogent-gastown-dimmed)
     (propertize "WS:" 'face 'ogent-gastown-dimmed)
     (propertize workspace 'face 'ogent-gastown-rig-name))))

;;; Header Line

(defun ogent-gastown--header-line ()
  "Generate header line for Gas Town buffer."
  (let ((loading-indicator (ogent-gastown--loading-indicator))
        (workspace-segment (ogent-gastown--header-workspace-segment))
        (mail-count (length (seq-filter
                             (lambda (m) (not (plist-get m :read)))
                             ogent-gastown--mail-data)))
        (hook-active (and ogent-gastown--hook-data
                          (plist-get ogent-gastown--hook-data :has_work))))
    (concat
     (propertize " " 'face 'ogent-gastown-header-line)
     (propertize "Gas Town" 'face 'ogent-gastown-header-line)
     (or workspace-segment "")
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
        (propertize "?" 'face 'ogent-gastown-header-line-key)
        (propertize ":help " 'face 'ogent-gastown-dimmed)
        (propertize "q" 'face 'ogent-gastown-header-line-key)
        (propertize ":quit" 'face 'ogent-gastown-dimmed))))))

;;; Data Fetching

(defun ogent-gastown--fetch-all (callback)
  "Fetch all data for the status buffer, call CALLBACK when done."
  (let* ((pending 6)
         (results (make-hash-table))
         (buf (current-buffer))
         ;; Use let-bound lambda instead of cl-flet to avoid bytecode issues
         ;; with async callbacks in certain Emacs versions
         (check-done
          (lambda ()
            (cl-decf pending)
            (when (zerop pending)
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (setq ogent-gastown--hook-data (gethash 'hook results))
                  (setq ogent-gastown--mail-data (gethash 'mail results))
                  (setq ogent-gastown--convoy-data
                          (ogent-gastown--normalize-convoy-list
                           (gethash 'convoy results)))
                  (setq ogent-gastown--workers-data (gethash 'workers results))
                  (setq ogent-gastown--crew-data (gethash 'crew results))
                  (setq ogent-gastown--polecat-data (gethash 'workers results))
                  ;; Extract stats, deacon, witnesses, and rigs from town status
                  (let ((town-status (gethash 'town-status results)))
                    (setq ogent-gastown--stats-data
                          (plist-get town-status :summary))
                    (setq ogent-gastown--deacon-data
                          (ogent-gastown--extract-deacon town-status))
                    (setq ogent-gastown--witness-data
                          (ogent-gastown--extract-witnesses town-status))
                    (setq ogent-gastown--rigs-data
                          (plist-get town-status :rigs)))
                  (funcall callback)))))))

    ;; Fetch hook status
    (ogent-gastown-status--run-async
     '("hook" "--json")
     (lambda (result)
       (puthash 'hook result results)
       (funcall check-done))
     (lambda (_err)
       (puthash 'hook nil results)
       (funcall check-done)))

    ;; Fetch mail
    (ogent-gastown-status--run-async
     '("mail" "inbox" "--json")
     (lambda (result)
       (puthash 'mail result results)
       (funcall check-done))
     (lambda (_err)
       (puthash 'mail nil results)
       (funcall check-done)))

    ;; Fetch convoys
    (ogent-gastown-status--run-async
     '("convoy" "list" "--json")
     (lambda (result)
       (puthash 'convoy result results)
       (funcall check-done))
     (lambda (_err)
       (puthash 'convoy nil results)
       (funcall check-done)))

    ;; Fetch workers
    (ogent-gastown-status--run-async
     '("polecat" "list" "--all" "--json")
     (lambda (result)
       (puthash 'workers result results)
       (funcall check-done))
     (lambda (_err)
       (puthash 'workers nil results)
       (funcall check-done)))

    ;; Fetch town status (for stats, deacon, witnesses)
    (ogent-gastown-status--run-async
     '("status" "--json" "--fast")
     (lambda (result)
       (puthash 'town-status result results)
       (funcall check-done))
     (lambda (_err)
       (puthash 'town-status nil results)
       (funcall check-done)))

    ;; Fetch crew members
    (ogent-gastown-status--run-async
     '("crew" "list" "--json")
     (lambda (result)
       (puthash 'crew result results)
       (funcall check-done))
     (lambda (_err)
       (puthash 'crew nil results)
       (funcall check-done)))

    ))

(defun ogent-gastown--extract-deacon (town-status)
  "Extract deacon info from TOWN-STATUS."
  (when town-status
    (let ((agents (plist-get town-status :agents)))
      (seq-find (lambda (agent)
                  (string= (plist-get agent :name) "deacon"))
                agents))))

(defun ogent-gastown--extract-witnesses (town-status)
  "Extract witness info from TOWN-STATUS."
  (when town-status
    (let ((rigs (plist-get town-status :rigs)))
      (mapcar (lambda (rig)
                (list :rig (plist-get rig :name)
                      :has_witness (plist-get rig :has_witness)
                      :polecat_count (or (plist-get rig :polecat_count) 0)
                      :crew_count (or (plist-get rig :crew_count) 0)))
              rigs))))

;;; Bead Link Keymap (defined early for use in section rendering)

(declare-function ogent-gastown-visit-bead "ogent-gastown-status")

(defvar ogent-gastown-bead-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-gastown-visit-bead)
    (define-key map [mouse-1] #'ogent-gastown-visit-bead)
    map)
  "Keymap for clickable bead IDs in Gas Town buffer.")

;;; Buffer Rendering

(defun ogent-gastown--insert-buffer-contents ()
  "Insert all sections into the buffer."
  (if ogent-gastown--magit-section-available
      (ogent-gastown--insert-with-magit-section)
    (ogent-gastown--insert-plain)))

(defun ogent-gastown--insert-with-magit-section ()
  "Insert content using magit-section."
  (magit-insert-section (ogent-gastown-root-section)
    (ogent-gastown--insert-stats-section)
    (insert "\n")
    (ogent-gastown--insert-deacon-section)
    (insert "\n")
    (ogent-gastown--insert-witness-section)
    (insert "\n")
    (ogent-gastown--insert-hook-section)
    (insert "\n")
    (ogent-gastown--insert-mail-section)
    (insert "\n")
    (ogent-gastown--insert-convoy-section)
    (insert "\n")
    (ogent-gastown--insert-rigs-section)
    (insert "\n")
    (ogent-gastown--insert-crew-section)
    (insert "\n")
    (ogent-gastown--insert-polecat-section)
    (insert "\n")
    (ogent-gastown--insert-workers-section)))

(defun ogent-gastown--insert-plain ()
  "Insert content without magit-section (fallback)."
  (ogent-gastown--insert-stats-section-plain)
  (insert "\n")
  (ogent-gastown--insert-deacon-section-plain)
  (insert "\n")
  (ogent-gastown--insert-witness-section-plain)
  (insert "\n")
  (ogent-gastown--insert-hook-section-plain)
  (insert "\n")
  (ogent-gastown--insert-mail-section-plain)
  (insert "\n")
  (ogent-gastown--insert-convoy-section-plain)
  (insert "\n")
  (ogent-gastown--insert-rigs-section-plain)
  (insert "\n")
  (ogent-gastown--insert-crew-section-plain)
  (insert "\n")
  (ogent-gastown--insert-polecat-section-plain)
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
        (ogent-ops-section-heading
         (ogent-ops-section-prefix "" "#")
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
         (ogent-ops-section-prefix "" "@")
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
         (ogent-ops-section-prefix "" ">")
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
  "Insert a single CONVOY as a section.
CONVOY should be a normalized plist with canonical keys."
  (let* ((id (plist-get convoy :id))
         (title (plist-get convoy :title))
         (status (plist-get convoy :status))
         (progress (ogent-gastown--convoy-progress-string convoy)))
    (magit-insert-section (ogent-gastown-convoy-item-section convoy)
      (insert "  ")
      (insert (propertize (or id "???") 'face 'ogent-gastown-dimmed))
      (insert " ")
      (insert (propertize (or title "(unnamed)")
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
        (insert (or (plist-get convoy :title) "(unnamed)"))
        (insert "\n")))))

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
         (ogent-ops-section-prefix "" "*")
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
         (icon (let ((ogent-ops-use-unicode ogent-gastown-use-unicode))
                 (cond
                  (running (ogent-ops-activity-symbol 'active))
                  ((string= state "working") (ogent-ops-activity-symbol 'working))
                  (t (ogent-ops-activity-symbol 'idle))))))
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

;;; Stats Section

(defun ogent-gastown--insert-stats-section ()
  "Insert town statistics section with magit-section."
  (let ((stats ogent-gastown--stats-data))
    (magit-insert-section (ogent-gastown-stats-section stats)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "📊" "#")
         " "
         (propertize "Town Stats" 'face 'ogent-gastown-section-heading)))
      (if (null stats)
          (insert (propertize "  No stats available\n" 'face 'ogent-gastown-dimmed))
        (insert "  ")
        (ogent-gastown--insert-stat-item "Rigs" (plist-get stats :rig_count))
        (insert "  ")
        (ogent-gastown--insert-stat-item "Polecats" (plist-get stats :polecat_count))
        (insert "  ")
        (ogent-gastown--insert-stat-item "Crew" (plist-get stats :crew_count))
        (insert "\n  ")
        (ogent-gastown--insert-stat-item "Witnesses" (plist-get stats :witness_count))
        (insert "  ")
        (ogent-gastown--insert-stat-item "Refineries" (plist-get stats :refinery_count))
        (insert "  ")
        (ogent-gastown--insert-stat-item "Hooks" (plist-get stats :active_hooks))
        ;; Aggregate beads stats from per-rig data
        (let ((agg (ogent-gastown--aggregate-beads-stats)))
          (when agg
            (insert "\n  ")
            (ogent-gastown--insert-stat-item
             (concat (ogent-ops-section-prefix "◆" "+") "Ready")
             (plist-get agg :ready))
            (insert "  ")
            (ogent-gastown--insert-stat-item
             (concat (ogent-ops-section-prefix "●" "*") "Active")
             (plist-get agg :in_progress))))
        (insert "\n")))))

(defun ogent-gastown--aggregate-beads-stats ()
  "Compute aggregate beads stats from per-rig data.
Returns a plist with :ready, :in_progress, :open, or nil if no data."
  (let ((rigs ogent-gastown--rigs-data)
        (ready 0) (in-prog 0) (open 0))
    (when rigs
      (dolist (rig rigs)
        (when-let* ((bs (plist-get rig :beads_stats)))
          (setq ready (+ ready (or (plist-get bs :ready) 0)))
          (setq in-prog (+ in-prog (or (plist-get bs :in_progress) 0)))
          (setq open (+ open (or (plist-get bs :open) 0)))))
      (when (> (+ ready in-prog open) 0)
        (list :ready ready :in_progress in-prog :open open)))))

(defun ogent-gastown--insert-stat-item (label value)
  "Insert a stat LABEL: VALUE pair."
  (insert (propertize label 'face 'ogent-gastown-stats-label))
  (insert ": ")
  (insert (propertize (format "%s" (or value 0)) 'face 'ogent-gastown-stats-value)))

(defun ogent-gastown--insert-stats-section-plain ()
  "Insert stats section (plain)."
  (let ((stats ogent-gastown--stats-data))
    (insert (propertize "# Town Stats\n" 'face 'ogent-gastown-section-heading))
    (if (null stats)
        (insert (propertize "  No stats available\n" 'face 'ogent-gastown-dimmed))
      (insert (format "  Rigs: %d  Polecats: %d  Crew: %d\n"
                      (or (plist-get stats :rig_count) 0)
                      (or (plist-get stats :polecat_count) 0)
                      (or (plist-get stats :crew_count) 0)))
      (insert (format "  Witnesses: %d  Refineries: %d  Hooks: %d\n"
                      (or (plist-get stats :witness_count) 0)
                      (or (plist-get stats :refinery_count) 0)
                      (or (plist-get stats :active_hooks) 0)))
      (let ((agg (ogent-gastown--aggregate-beads-stats)))
        (when agg
          (insert (format "  +Ready: %d  *Active: %d\n"
                          (or (plist-get agg :ready) 0)
                          (or (plist-get agg :in_progress) 0))))))))

;;; Deacon Section

(defun ogent-gastown--insert-deacon-section ()
  "Insert deacon status section with magit-section."
  (let* ((data ogent-gastown--deacon-data)
         (running (plist-get data :running))
         (has-work (plist-get data :has_work))
         (address (plist-get data :address)))
    (magit-insert-section (ogent-gastown-deacon-section data)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "👁" "D")
         " "
         (propertize "Deacon" 'face 'ogent-gastown-section-heading)
         " "
         (if running
             (propertize "[running]" 'face 'ogent-gastown-deacon-running)
           (propertize "[stopped]" 'face 'ogent-gastown-deacon-stopped))))
      (if (null data)
          (insert (propertize "  No deacon info available\n" 'face 'ogent-gastown-dimmed))
        (insert "  ")
        (insert (propertize "Address: " 'face 'ogent-gastown-dimmed))
        (insert (or address "deacon/"))
        (insert "\n")
        (insert "  ")
        (if running
            (if has-work
                (insert (propertize "Has work on hook" 'face 'ogent-gastown-hook-active))
              (insert (propertize "Patrolling (no hooked work)" 'face 'ogent-gastown-deacon-running)))
          (insert (propertize "Not running - start with: gt deacon start" 'face 'ogent-gastown-dimmed)))
        (insert "\n")))))

(defun ogent-gastown--insert-deacon-section-plain ()
  "Insert deacon section (plain)."
  (let* ((data ogent-gastown--deacon-data)
         (running (plist-get data :running)))
    (insert (propertize "D Deacon\n" 'face 'ogent-gastown-section-heading))
    (insert "  Status: ")
    (if running
        (insert (propertize "running\n" 'face 'ogent-gastown-deacon-running))
      (insert (propertize "stopped\n" 'face 'ogent-gastown-deacon-stopped)))))

;;; Witness Section

(defun ogent-gastown--insert-witness-section ()
  "Insert witness status section with magit-section."
  (let* ((witnesses ogent-gastown--witness-data)
         (active-count (length (seq-filter
                                (lambda (w) (plist-get w :has_witness))
                                witnesses))))
    (magit-insert-section (ogent-gastown-witness-section witnesses nil)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "🔭" "W")
         " "
         (propertize "Witnesses" 'face 'ogent-gastown-section-heading)
         (propertize (format " (%d/%d active)"
                             active-count (length witnesses))
                     'face 'ogent-gastown-dimmed)))
      (if (null witnesses)
          (insert (propertize "  No rig data available\n" 'face 'ogent-gastown-dimmed))
        (dolist (witness witnesses)
          (ogent-gastown--insert-witness-item witness))))))

(defun ogent-gastown--insert-witness-item (witness)
  "Insert a single rig WITNESS status as a line."
  (let* ((rig (plist-get witness :rig))
         (has-witness (plist-get witness :has_witness))
         (polecat-count (or (plist-get witness :polecat_count) 0))
         (crew-count (or (plist-get witness :crew_count) 0))
         (icon (let ((ogent-ops-use-unicode ogent-gastown-use-unicode))
                 (if has-witness
                     (ogent-ops-activity-symbol 'active)
                   (ogent-ops-activity-symbol 'idle))))
         (face (if has-witness
                   'ogent-gastown-witness-healthy
                 'ogent-gastown-witness-unhealthy)))
    (magit-insert-section (ogent-gastown-witness-item-section witness)
      (insert "  ")
      (insert (propertize icon 'face face))
      (insert " ")
      (insert (propertize rig 'face face))
      (insert " ")
      (insert (propertize (format "[%d polecats, %d crew]"
                                  polecat-count crew-count)
                          'face 'ogent-gastown-dimmed))
      (insert "\n"))))

(defun ogent-gastown--insert-witness-section-plain ()
  "Insert witness section (plain)."
  (let ((witnesses ogent-gastown--witness-data))
    (insert (propertize "W Witnesses\n" 'face 'ogent-gastown-section-heading))
    (if (null witnesses)
        (insert (propertize "  No rig data available\n" 'face 'ogent-gastown-dimmed))
      (dolist (witness witnesses)
        (let* ((rig (plist-get witness :rig))
               (has-witness (plist-get witness :has_witness)))
          (insert "  ")
          (insert (if has-witness "+" "-"))
          (insert " ")
          (insert rig)
          (insert "\n"))))))

;;; Crew Section

(defun ogent-gastown--insert-crew-section ()
  "Insert crew status section with magit-section."
  (let ((crew ogent-gastown--crew-data)
        (active-count 0))
    (dolist (member crew)
      (when (plist-get member :session_running)
        (cl-incf active-count)))
    (magit-insert-section (ogent-gastown-crew-section crew nil)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "👤" "C")
         " "
         (propertize "Crew" 'face 'ogent-gastown-section-heading)
         (propertize (format " (%d/%d active)"
                             active-count (length crew))
                     'face 'ogent-gastown-dimmed)))
      (if (null crew)
          (insert (propertize "  No crew members\n" 'face 'ogent-gastown-dimmed))
        ;; Group by rig
        (let ((by-rig (seq-group-by (lambda (m) (plist-get m :rig)) crew)))
          (dolist (rig-group by-rig)
            (let ((rig (car rig-group))
                  (rig-crew (cdr rig-group)))
              (insert "  ")
              (insert (propertize (or rig "unknown") 'face 'ogent-gastown-section-heading))
              (insert ":\n")
              (dolist (member rig-crew)
                (ogent-gastown--insert-crew-item member)))))))))

(defun ogent-gastown--insert-crew-item (member)
  "Insert a single crew MEMBER as a line."
  (let* ((name (plist-get member :name))
         (hooked-work (plist-get member :hooked_work))
         (branch (plist-get member :branch))
         (dirty (plist-get member :dirty))
         (running (plist-get member :session_running))
         (mail-count (plist-get member :unread_mail))
         (state-face (if running 'ogent-gastown-crew-active 'ogent-gastown-crew-idle))
         (icon (let ((ogent-ops-use-unicode ogent-gastown-use-unicode))
                 (if running
                     (ogent-ops-activity-symbol 'active)
                   (ogent-ops-activity-symbol 'idle)))))
    (magit-insert-section (ogent-gastown-crew-item-section member)
      (insert "    ")
      (insert (propertize icon 'face state-face))
      (insert " ")
      (insert (propertize (or name "???") 'face state-face))
      ;; Git branch info
      (when branch
        (insert " ")
        (insert (propertize (format "[%s%s]"
                                    branch
                                    (if dirty "*" ""))
                            'face 'ogent-gastown-dimmed)))
      ;; Hooked work (clickable bead link)
      (when hooked-work
        (insert " ")
        (insert (propertize (format "→ %s" hooked-work)
                            'face 'ogent-gastown-hook-active
                            'ogent-bead-id hooked-work
                            'ogent-rig-path (ogent-gastown--crew-rig-path member)
                            'keymap ogent-gastown-bead-link-map
                            'mouse-face 'highlight
                            'help-echo (format "RET to view bead %s" hooked-work))))
      ;; Mail count
      (when (and mail-count (> mail-count 0))
        (insert " ")
        (insert (propertize (format "📬%d" mail-count) 'face 'ogent-gastown-mail-unread)))
      (insert "\n"))))

(defun ogent-gastown--insert-crew-section-plain ()
  "Insert crew section (plain)."
  (let ((crew ogent-gastown--crew-data))
    (insert (propertize "C Crew\n" 'face 'ogent-gastown-section-heading))
    (if (null crew)
        (insert (propertize "  No crew members\n" 'face 'ogent-gastown-dimmed))
      (dolist (member crew)
        (insert "  ")
        (insert (or (plist-get member :rig) "???"))
        (insert "/")
        (insert (or (plist-get member :name) "???"))
        (when (plist-get member :session_running)
          (insert " [active]"))
        (insert "\n")))))

;;; Polecat Section

(defun ogent-gastown--insert-polecat-section ()
  "Insert polecat status section with magit-section."
  (let ((polecats ogent-gastown--polecat-data)
        (running-count 0))
    (dolist (p polecats)
      (when (plist-get p :session_running)
        (cl-incf running-count)))
    (magit-insert-section (ogent-gastown-polecat-section polecats nil)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "🔧" "P")
         " "
         (propertize "Polecats" 'face 'ogent-gastown-section-heading)
         (propertize (format " (%d/%d running)"
                             running-count (length polecats))
                     'face 'ogent-gastown-dimmed)))
      (if (null polecats)
          (insert (propertize "  No polecats\n" 'face 'ogent-gastown-dimmed))
        ;; Group by rig
        (let ((by-rig (seq-group-by (lambda (p) (plist-get p :rig)) polecats)))
          (dolist (rig-group by-rig)
            (let ((rig (car rig-group))
                  (rig-polecats (cdr rig-group)))
              (insert "  ")
              (insert (propertize (or rig "unknown") 'face 'ogent-gastown-section-heading))
              (insert ":\n")
              (dolist (polecat rig-polecats)
                (ogent-gastown--insert-polecat-item polecat)))))))))

(defun ogent-gastown--insert-polecat-item (polecat)
  "Insert a single POLECAT as a line."
  (let* ((name (plist-get polecat :name))
         (state (plist-get polecat :state))
         (running (plist-get polecat :session_running))
         (task (or (plist-get polecat :current_task)
                   (plist-get polecat :hooked_work)))
         (started (plist-get polecat :session_started))
         (state-face (cond
                      (running 'ogent-gastown-polecat-active)
                      ((string= state "working") 'ogent-gastown-worker-working)
                      (t 'ogent-gastown-polecat-idle)))
         (icon (let ((ogent-ops-use-unicode ogent-gastown-use-unicode))
                 (cond
                  (running (ogent-ops-activity-symbol 'active))
                  ((string= state "working") (ogent-ops-activity-symbol 'working))
                  (t (ogent-ops-activity-symbol 'idle))))))
    (magit-insert-section (ogent-gastown-polecat-item-section polecat)
      (insert "    ")
      (insert (propertize icon 'face state-face))
      (insert " ")
      (insert (propertize (or name "???") 'face state-face))
      ;; State
      (insert " ")
      (insert (propertize (format "[%s]" (or state "unknown")) 'face 'ogent-gastown-dimmed))
      ;; Current task/bead (clickable)
      (when task
        (let ((rig-path (let ((rig (plist-get polecat :rig)))
                          (when rig
                            (expand-file-name rig ogent-gastown--town-root)))))
          (insert " ")
          (insert (propertize (format "→ %s" task)
                              'face 'ogent-gastown-hook-active
                              'ogent-bead-id task
                              'ogent-rig-path rig-path
                              'keymap ogent-gastown-bead-link-map
                              'mouse-face 'highlight
                              'help-echo (format "RET to view bead %s" task)))))
      ;; Time active
      (when (and running started)
        (let ((time-str (ogent-gastown--format-time started)))
          (insert " ")
          (insert (propertize (format "(since %s)" time-str) 'face 'ogent-gastown-dimmed))))
      (insert "\n"))))

(defun ogent-gastown--insert-polecat-section-plain ()
  "Insert polecat section (plain)."
  (let ((polecats ogent-gastown--polecat-data))
    (insert (propertize "P Polecats\n" 'face 'ogent-gastown-section-heading))
    (if (null polecats)
        (insert (propertize "  No polecats\n" 'face 'ogent-gastown-dimmed))
      (dolist (polecat polecats)
        (insert "  ")
        (insert (or (plist-get polecat :rig) "???"))
        (insert "/")
        (insert (or (plist-get polecat :name) "???"))
        (insert " [")
        (insert (or (plist-get polecat :state) "unknown"))
        (insert "]")
        (when (plist-get polecat :session_running)
          (insert " running"))
        (insert "\n")))))

;;; Rigs Section

(defun ogent-gastown--insert-rigs-section ()
  "Insert rigs overview section with magit-section."
  (let ((rigs ogent-gastown--rigs-data))
    (magit-insert-section (ogent-gastown-rigs-section rigs nil)
      (magit-insert-heading
        (concat
         (ogent-ops-section-prefix "🏭" "R")
         " "
         (propertize "Rigs" 'face 'ogent-gastown-section-heading)
         (propertize (format " (%d)" (length rigs))
                     'face 'ogent-gastown-dimmed)))
      (if (null rigs)
          (insert (propertize "  No rigs configured\n" 'face 'ogent-gastown-dimmed))
        (dolist (rig rigs)
          (ogent-gastown--insert-rig-item rig))))))

(defun ogent-gastown--insert-rig-item (rig)
  "Insert a single RIG as a section."
  (let* ((name (plist-get rig :name))
         (polecat-count (or (plist-get rig :polecat_count) 0))
         (crew-count (or (plist-get rig :crew_count) 0))
         (has-witness (plist-get rig :has_witness))
         (has-refinery (plist-get rig :has_refinery))
         (agents (plist-get rig :agents))
         (any-running (seq-some (lambda (a) (plist-get a :running)) agents))
         (beads-stats (plist-get rig :beads_stats)))
    (magit-insert-section (ogent-gastown-rig-item-section rig t)
      (insert "  ")
      (insert (propertize name 'face 'ogent-gastown-rig-name))
      (insert " ")
      (insert (propertize (format "P:%d C:%d" polecat-count crew-count)
                          'face 'ogent-gastown-dimmed))
      (insert " ")
      (if any-running
          (insert (propertize "[running]" 'face 'ogent-gastown-rig-running))
        (insert (propertize "[stopped]" 'face 'ogent-gastown-rig-stopped)))
      (when has-witness
        (insert (propertize " W" 'face 'ogent-gastown-witness-healthy)))
      (when has-refinery
        (insert (propertize " R" 'face 'ogent-gastown-convoy-active)))
      (when-let* ((bs (plist-get rig :beads_stats)))
        (let ((ready (or (plist-get bs :ready) 0))
              (in-prog (or (plist-get bs :in_progress) 0))
              (open (or (plist-get bs :open) 0)))
          (when (> (+ in-prog ready open) 0)
            (insert "  ")
            (when (> in-prog 0)
              (insert (propertize (format "%s%d"
                                         (ogent-ops-section-prefix "●" "*")
                                         in-prog)
                                  'face 'ogent-gastown-beads-in-progress)))
            (when (> ready 0)
              (when (> in-prog 0) (insert " "))
              (insert (propertize (format "%s%d"
                                         (ogent-ops-section-prefix "◆" "+")
                                         ready)
                                  'face 'ogent-gastown-beads-ready)))
            (when (> open 0)
              (when (> (+ in-prog ready) 0) (insert " "))
              (insert (propertize (format "%s%d"
                                         (ogent-ops-section-prefix "○" "o")
                                         open)
                                  'face 'ogent-gastown-dimmed))))))
      (insert "\n")
      ;; Insert agents if expanded
      (when agents
        (dolist (agent agents)
          (ogent-gastown--insert-rig-agent agent)))
      ;; Insert beads stats detail if expanded
      (ogent-gastown--insert-rig-beads-detail (plist-get rig :beads_stats)))))

(defun ogent-gastown--insert-rig-beads-detail (beads-stats)
  "Insert beads stats detail lines for an expanded rig section.
BEADS-STATS is a plist with :ready, :in_progress, :blocked, :open, :closed, :total."
  (when beads-stats
    (let ((pairs `(("Ready"       ,(or (plist-get beads-stats :ready) 0)       ogent-gastown-beads-ready)
                   ("In Progress" ,(or (plist-get beads-stats :in_progress) 0) ogent-gastown-beads-in-progress)
                   ("Blocked"     ,(or (plist-get beads-stats :blocked) 0)     warning)
                   ("Open"        ,(or (plist-get beads-stats :open) 0)        ogent-gastown-dimmed)
                   ("Closed"      ,(or (plist-get beads-stats :closed) 0)      ogent-gastown-dimmed)
                   ("Total"       ,(or (plist-get beads-stats :total) 0)       default))))
      ;; Only show if there are any issues at all
      (when (> (or (plist-get beads-stats :total)
                   (+ (or (plist-get beads-stats :open) 0)
                      (or (plist-get beads-stats :in_progress) 0)
                      (or (plist-get beads-stats :closed) 0)))
               0)
        (insert "    " (propertize "Beads:" 'face 'ogent-gastown-section-heading) "\n")
        (dolist (p pairs)
          (let ((label (nth 0 p))
                (value (nth 1 p))
                (face (nth 2 p)))
            (when (> value 0)
              (insert "      "
                      (propertize (format "%-12s" label) 'face 'ogent-gastown-dimmed)
                      (propertize (format "%d" value) 'face face)
                      "\n"))))))))

(defun ogent-gastown--insert-rig-agent (agent)
  "Insert a single AGENT line within a rig section."
  (let* ((ogent-ops-use-unicode ogent-gastown-use-unicode)
         (name (plist-get agent :name))
         (role (plist-get agent :role))
         (running (plist-get agent :running))
         (has-work (plist-get agent :has_work))
         (unread (or (plist-get agent :unread_mail) 0))
         (role-icon (pcase role
                      ("witness" (ogent-ops-section-prefix "👁" "W"))
                      ("refinery" (ogent-ops-section-prefix "⚙" "R"))
                      ("polecat" (ogent-ops-section-prefix "🐱" "P"))
                      ("crew" (ogent-ops-section-prefix "👤" "C"))
                      (_ "?"))))
    (insert "    ")
    (insert role-icon)
    (insert " ")
    (insert (propertize (or name "???")
                        'face (if running 'ogent-gastown-worker-running 'ogent-gastown-dimmed)))
    (when has-work
      (insert " ")
      (insert (propertize (ogent-ops-section-prefix "⚓" "H") 'face 'ogent-gastown-hook-active)))
    (when (> unread 0)
      (insert " ")
      (insert (propertize (format "%s%d"
                                  (ogent-ops-section-prefix "📬" "M:")
                                  unread)
                          'face 'ogent-gastown-mail-unread)))
    (insert "\n")))

(defun ogent-gastown--insert-rigs-section-plain ()
  "Insert rigs section (plain)."
  (let ((rigs ogent-gastown--rigs-data))
    (insert (propertize "R Rigs\n" 'face 'ogent-gastown-section-heading))
    (if (null rigs)
        (insert (propertize "  No rigs configured\n" 'face 'ogent-gastown-dimmed))
      (dolist (rig rigs)
        (let* ((name (plist-get rig :name))
               (polecat-count (or (plist-get rig :polecat_count) 0))
               (crew-count (or (plist-get rig :crew_count) 0))
               (bs (plist-get rig :beads_stats)))
          (insert "  ")
          (insert (or name "???"))
          (insert " ")
          (insert (format "P:%d C:%d" polecat-count crew-count))
          (when bs
            (let ((ready (or (plist-get bs :ready) 0))
                  (in-prog (or (plist-get bs :in_progress) 0))
                  (open (or (plist-get bs :open) 0)))
              (when (> (+ in-prog ready open) 0)
                (insert (format "  *%d +%d o%d" in-prog ready open)))))
          (insert "\n"))))))

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
      (if-let ((section (magit-current-section)))
          (magit-section-toggle section)
        (message "No section at point"))
    (message "Section toggling requires magit-section")))

(defun ogent-gastown-next-section ()
  "Move to the next sibling section."
  (interactive)
  (when ogent-gastown--magit-section-available
    (magit-section-forward-sibling)))

(defun ogent-gastown-prev-section ()
  "Move to the previous sibling section."
  (interactive)
  (when ogent-gastown--magit-section-available
    (magit-section-backward-sibling)))

(defun ogent-gastown-up-section ()
  "Move to the parent section."
  (interactive)
  (when ogent-gastown--magit-section-available
    (magit-section-up)))

(defun ogent-gastown-cycle-sections ()
  "Cycle visibility of all sections."
  (interactive)
  (if ogent-gastown--magit-section-available
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-gastown-visit ()
  "Visit the item at point.
On convoy items, opens the convoy inspector.
On mail items, reads the message.
On other sections, toggles visibility."
  (interactive)
  (when ogent-gastown--magit-section-available
    (let ((section (magit-current-section)))
      (cond
       ((eq (eieio-object-class-name section) 'ogent-gastown-convoy-item-section)
        (let* ((convoy (oref section value))
               (id (plist-get convoy :id)))
          (if id
              (ogent-convoy-inspect id (ogent-gastown--active-workspace-root))
            (user-error "No convoy ID at point"))))
       ((eq (eieio-object-class-name section) 'ogent-gastown-mail-item-section)
        (let* ((msg (oref section value))
               (id (plist-get msg :id)))
          (ogent-gastown-status-mail-read id)))
       (t
        (magit-section-toggle section))))))

;;; Actions

(defun ogent-gastown-status-mail-read (&optional id)
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
      (ogent-gastown-status--run-shell-command
       (list "mail" "read" mail-id)
       "*gt mail*"))))

(defun ogent-gastown--get-mail-recipients ()
  "Get list of available mail recipients for completion.
Builds list from:
- Fixed addresses: mayor/, deacon/
- Crew members (rig/crew/name format)
- Polecats (rig/polecats/name format)
- Witnesses (rig/witness/)
- Refineries (rig/refinery/)"
  (let ((recipients (list "mayor/" "deacon/")))
    ;; Add crew members
    (dolist (member ogent-gastown--crew-data)
      (let ((rig (plist-get member :rig))
            (name (plist-get member :name)))
        (when (and rig name)
          (push (format "%s/crew/%s" rig name) recipients))))
    ;; Add polecats
    (dolist (polecat ogent-gastown--polecat-data)
      (let ((rig (plist-get polecat :rig))
            (name (plist-get polecat :name)))
        (when (and rig name)
          (push (format "%s/polecats/%s" rig name) recipients))))
    ;; Add witnesses and refineries from witness data (has rig info)
    (dolist (witness ogent-gastown--witness-data)
      (let ((rig (plist-get witness :rig)))
        (when rig
          (when (plist-get witness :has_witness)
            (push (format "%s/witness/" rig) recipients))
          ;; Add refinery for each rig (assume exists if rig exists)
          (push (format "%s/refinery/" rig) recipients))))
    ;; Remove duplicates and sort
    (sort (delete-dups recipients) #'string<)))

(defun ogent-gastown--recipient-at-point ()
  "Get mail recipient address for item at point, or nil."
  (when ogent-gastown--magit-section-available
    (let ((section (magit-current-section)))
      (when section
        (let ((class (eieio-object-class-name section))
              (value (and (slot-boundp section 'value)
                          (oref section value))))
          (cond
           ;; Crew member
           ((eq class 'ogent-gastown-crew-item-section)
            (let ((rig (plist-get value :rig))
                  (name (plist-get value :name)))
              (when (and rig name)
                (format "%s/crew/%s" rig name))))
           ;; Polecat
           ((eq class 'ogent-gastown-polecat-item-section)
            (let ((rig (plist-get value :rig))
                  (name (plist-get value :name)))
              (when (and rig name)
                (format "%s/polecats/%s" rig name))))
           ;; Witness item
           ((eq class 'ogent-gastown-witness-item-section)
            (let ((rig (plist-get value :rig)))
              (when rig
                (format "%s/witness/" rig))))
           (t nil)))))))

(defun ogent-gastown-mail-compose (&optional initial-recipient
                                            initial-subject initial-body)
  "Compose a new mail message.
With INITIAL-RECIPIENT, pre-fill the To field.
With INITIAL-SUBJECT, pre-fill the Subject prompt.
With INITIAL-BODY, pre-fill the Message prompt.
When called interactively with point on a crew/polecat item,
pre-fills that recipient."
  (interactive (list (ogent-gastown--recipient-at-point)))
  (let* ((recipients (ogent-gastown--get-mail-recipients))
         (to (completing-read "To: " recipients nil nil initial-recipient))
         (subject (read-string "Subject: " initial-subject))
         (body (read-string "Message: " initial-body)))
    (when (and to (not (string-empty-p to)))
      (ogent-gastown-status--run-async
       (list "mail" "send" to "-s" subject "-m" body)
       (lambda (_result)
         (message "Mail sent to %s" to)
         (ogent-gastown-cache-invalidate)
         (ogent-gastown-refresh))
       (lambda (err)
         (message "Failed to send mail: %s" err))
       t))))

(defun ogent-gastown-mail-to-mayor ()
  "Quick send mail to mayor."
  (interactive)
  (ogent-gastown-mail-compose "mayor/"))

(defun ogent-gastown-mail-to-deacon ()
  "Quick send mail to deacon."
  (interactive)
  (ogent-gastown-mail-compose "deacon/"))

(defun ogent-gastown-hook-show ()
  "Show hook details."
  (interactive)
  (ogent-gastown-status--run-shell-command '("hook") "*gt hook*"))

(defun ogent-gastown-hook-attach ()
  "Attach work to hook."
  (interactive)
  (let ((bead-id (read-string "Bead ID to hook: ")))
    (ogent-gastown-status--run-async
     (list "hook" bead-id)
     (lambda (_result)
       (message "Hooked: %s" bead-id)
       (ogent-gastown-cache-invalidate)
       (ogent-gastown-refresh))
     (lambda (err)
       (message "Failed to hook: %s" err))
     t)))

(defun ogent-gastown-convoy-status ()
  "Inspect convoy at point, or prompt for a convoy ID.
Opens the dedicated convoy inspector buffer.  When point is on a
convoy item section, inspects that convoy directly.  Otherwise,
prompts with `completing-read' from the current convoy list."
  (interactive)
  (let ((convoy-id (when ogent-gastown--magit-section-available
                     (let ((section (magit-current-section)))
                       (when (eq (eieio-object-class-name section)
                                 'ogent-gastown-convoy-item-section)
                         (plist-get (oref section value) :id))))))
    (unless convoy-id
      (let ((candidates (mapcar (lambda (c)
                                  (let ((id (plist-get c :id))
                                        (title (plist-get c :title)))
                                    (cons (format "%s  %s" (or id "?") (or title ""))
                                          id)))
                                ogent-gastown--convoy-data)))
        (if candidates
            (let ((choice (completing-read "Inspect convoy: " candidates nil t)))
              (setq convoy-id (cdr (assoc choice candidates))))
          (setq convoy-id (read-string "Convoy ID: ")))))
    (if (and convoy-id (not (string-empty-p convoy-id)))
        (ogent-convoy-inspect convoy-id (ogent-gastown--active-workspace-root))
      (user-error "No convoy specified"))))

(defun ogent-gastown-convoy-create ()
  "Create a new convoy."
  (interactive)
  (let* ((name (read-string "Convoy name: "))
         (issues (read-string "Issue IDs (space-separated): ")))
    (ogent-gastown-status--run-async
     (append (list "convoy" "create" name) (split-string issues))
     (lambda (_result)
       (message "Created convoy: %s" name)
       (ogent-gastown-cache-invalidate)
       (ogent-gastown-refresh))
     (lambda (err)
       (message "Failed to create convoy: %s" err))
     t)))

(defun ogent-gastown-stats-show ()
  "Show detailed town statistics."
  (interactive)
  (ogent-gastown-status--run-shell-command '("status") "*gt status*"))

(defun ogent-gastown-deacon-show ()
  "Show deacon status and controls."
  (interactive)
  (ogent-gastown-status--run-shell-command '("deacon" "status") "*gt deacon*"))

(defun ogent-gastown-witness-show ()
  "Show witness status for the selected rig."
  (interactive)
  (let ((rig (when ogent-gastown--magit-section-available
               (let ((section (magit-current-section)))
                 (when (eq (eieio-object-class-name section)
                           'ogent-gastown-witness-item-section)
                         (plist-get (oref section value) :rig))))))
    (if rig
        (ogent-gastown-status--run-shell-command
         (list "witness" "status" rig)
         "*gt witness*")
      ;; No rig selected, prompt
      (let ((rig-name (completing-read
                       "Rig: "
                       (mapcar (lambda (w) (plist-get w :rig))
                               ogent-gastown--witness-data))))
        (ogent-gastown-status--run-shell-command
         (list "witness" "status" rig-name)
         "*gt witness*")))))

(defun ogent-gastown-crew-status ()
  "Show crew member status."
  (interactive)
  (let ((crew-name (when ogent-gastown--magit-section-available
                     (let ((section (magit-current-section)))
                       (when (eq (eieio-object-class-name section)
                                 'ogent-gastown-crew-item-section)
                         (plist-get (oref section value) :name))))))
    (if crew-name
        (ogent-gastown-status--run-shell-command
         (list "crew" "status" crew-name)
         "*gt crew*")
      (ogent-gastown-status--run-shell-command
       '("crew" "list")
       "*gt crew*"))))

(defun ogent-gastown-polecat-status ()
  "Show polecat status."
  (interactive)
  (let ((polecat-name (when ogent-gastown--magit-section-available
                        (let ((section (magit-current-section)))
                          (when (eq (eieio-object-class-name section)
                                    'ogent-gastown-polecat-item-section)
                            (plist-get (oref section value) :name))))))
    (if polecat-name
        (ogent-gastown-status--run-shell-command
         (list "polecat" "status" polecat-name)
         "*gt polecat*")
      (ogent-gastown-status--run-shell-command
       '("polecat" "list")
       "*gt polecat*"))))

(defun ogent-gastown-rig-status ()
  "Show rig status."
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
      (ogent-gastown-status--run-shell-command
       (list "rig" "status" rig-name)
       "*gt rig*"))))

(defun ogent-gastown-refinery-status ()
  "Show refinery/merge-queue status."
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
      (ogent-gastown-status--run-shell-command
       (list "refinery" "status" rig-name)
       "*gt refinery*"))))

;;; Rig → Issues Navigation

(defun ogent-gastown--rig-at-point ()
  "Return rig name from section at point.
Works on rig sections, crew sections, and polecat sections."
  (when ogent-gastown--magit-section-available
    (let ((section (magit-current-section)))
      (when section
        (pcase (eieio-object-class-name section)
          ('ogent-gastown-rig-item-section
           (plist-get (oref section value) :name))
          ((or 'ogent-gastown-crew-item-section
               'ogent-gastown-polecat-item-section)
           (plist-get (oref section value) :rig))
          ('ogent-gastown-witness-item-section
           (plist-get (oref section value) :rig))
          (_ nil))))))

(defun ogent-gastown--crew-rig-path (member)
  "Get rig path for crew MEMBER."
  (let ((rig (plist-get member :rig)))
    (when rig
      (expand-file-name rig ogent-gastown--town-root))))

(defun ogent-gastown-rig-issues ()
  "Open issues buffer for the rig at point.
Works when point is on a rig, crew member, or polecat."
  (interactive)
  (let* ((rig-name (or (ogent-gastown--rig-at-point)
                       (completing-read
                        "Rig: "
                        (mapcar (lambda (r) (plist-get r :name))
                                ogent-gastown--rigs-data))))
         (rig-path (when rig-name
                     (expand-file-name rig-name ogent-gastown--town-root))))
    (if (and rig-path (file-directory-p rig-path))
        (let ((default-directory rig-path))
          (ogent-issues))
      (user-error "No rig at point or rig directory not found: %s" rig-name))))

;;; Bead Link Navigation

(defun ogent-gastown-visit-bead ()
  "Visit the bead at point."
  (interactive)
  (let ((bead-id (get-text-property (point) 'ogent-bead-id))
        (rig-path (get-text-property (point) 'ogent-rig-path)))
    (cond
     ((and bead-id rig-path (file-directory-p rig-path))
      (let ((default-directory rig-path))
        (ogent-issues-bd-get bead-id
                             (lambda (issue)
                               (when issue
                                 (ogent-issues--show-detail issue)))
                             (lambda (err)
                               (message "Could not fetch bead %s: %s" bead-id err)))))
     (bead-id
      (message "Rig path not found for bead %s" bead-id))
     (t
      (message "No bead at point")))))

(defun ogent-gastown-status-help ()
  "Show help for Gas Town status buffer.
Displays available keybindings and actions."
  (interactive)
  (let ((workspace (or (ogent-gastown--workspace-root-display)
                       "unresolved")))
    (message
     (concat
      "n/p:item  M-n/M-p:section  TAB:toggle  "
      "g:refresh  m:mail  h:hook  c:convoy  "
      "r:rig  f:refinery  s:stats  d:deacon  w:witness  i:issues  ?:help  q:quit"
      "  Workspace:" workspace
      "  Reopen from a town directory or set GT_ROOT/GT_TOWN"))))

;;; Refresh

(defun ogent-gastown--ensure-magit-root-section ()
  "Ensure magit buffers have a root section before async refresh work.
Without this, `magit-section-post-command-hook' can run against a status
buffer that has no root section yet and signal type errors."
  (when (and ogent-gastown--magit-section-available
             (derived-mode-p 'magit-section-mode)
             (boundp 'magit-root-section)
             (null magit-root-section))
    (let ((inhibit-read-only t)
          (pos (point)))
      (erase-buffer)
      (ogent-gastown--insert-buffer-contents)
      (goto-char (min pos (point-max))))))

(defun ogent-gastown-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the Gas Town status buffer."
  (interactive)
  (let ((buf (current-buffer)))
    (ogent-gastown--ensure-magit-root-section)
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
  "Open the Gas Town status buffer.
Like `magit-status', this shows a comprehensive view of your
Gas Town multi-agent workspace including hook status, mail,
convoys, crew members, and polecats."
  (interactive)
  (let ((workspace-root (ogent-gastown--find-town-root)))
    (unless (executable-find ogent-gastown-gt-executable)
      (user-error "Gas Town CLI (gt) not found in PATH"))
    (unless workspace-root
      (user-error
       "No Gas Town workspace found (set GT_ROOT/GT_TOWN, open from a town directory, or set ogent-gastown-default-town-root)"))
    (let ((buf (get-buffer-create ogent-gastown-buffer-name))
          (workspace-dir (file-name-as-directory (expand-file-name workspace-root))))
      (with-current-buffer buf
        (unless (eq major-mode 'ogent-gastown-status-mode)
          (ogent-gastown-status-mode))
        (setq-local ogent-gastown--town-root workspace-dir)
        (setq-local default-directory workspace-dir)
        (ogent-gastown-refresh))
      (switch-to-buffer buf))))

;;; Cleanup

(defun ogent-gastown--cleanup-on-kill ()
  "Clean up timers when the buffer is killed."
  (ogent-gastown--stop-loading-timer))

(add-hook 'ogent-gastown-status-mode-hook
          (lambda ()
            (add-hook 'kill-buffer-hook #'ogent-gastown--cleanup-on-kill nil t)))

;;; Evil Integration
;; When evil is loaded, set up proper evil keybindings.
;; j/k are NOT bound in the mode map so evil users get normal line movement.
;; Use n/p for item navigation, gj/gk for section navigation.

(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-make-overriding-map "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function evil-local-set-key "ext:evil-core")

(defun ogent-gastown--setup-evil ()
  "Set up evil keybindings for `ogent-gastown-status-mode'.
Called after evil is loaded."
  (when (fboundp 'evil-set-initial-state)
    ;; Set initial state to normal so buffer is read-only and navigable
    (evil-set-initial-state 'ogent-gastown-status-mode 'normal)

    ;; Make our keymap override evil's state maps for non-movement keys
    ;; j/k are intentionally NOT in the mode map so evil handles them
    (evil-make-overriding-map ogent-gastown-status-mode-map 'normal)

    ;; Add evil-specific navigation using evil-local-set-key in mode hook
    (add-hook 'ogent-gastown-status-mode-hook
              (lambda ()
                ;; Standard evil navigation
                (evil-local-set-key 'normal "gg" #'evil-goto-first-line)
                (evil-local-set-key 'normal "G" #'evil-goto-line)
                ;; Refresh with g-prefix (standard evil pattern)
                (evil-local-set-key 'normal "gr" #'ogent-gastown-refresh)
                (evil-local-set-key 'normal "gR" #'ogent-gastown-refresh-force)
                ;; Section navigation
                (evil-local-set-key 'normal "gj" #'ogent-gastown-next-section)
                (evil-local-set-key 'normal "gk" #'ogent-gastown-prev-section)
                ;; Section toggle
                (evil-local-set-key 'normal (kbd "TAB") #'ogent-gastown-toggle-section)
                (evil-local-set-key 'normal (kbd "<tab>") #'ogent-gastown-toggle-section)
                ;; Quit
                (evil-local-set-key 'normal "ZZ" #'quit-window)
                (evil-local-set-key 'normal "ZQ" #'quit-window)))

    ;; Normalize keymaps when entering the mode
    (add-hook 'ogent-gastown-status-mode-hook #'evil-normalize-keymaps)))

(with-eval-after-load 'evil
  (ogent-gastown--setup-evil))

(provide 'ogent-gastown-status)

;;; ogent-gastown-status.el ends here
