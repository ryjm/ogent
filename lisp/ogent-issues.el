;;; ogent-issues.el --- Magit-style beads issue viewer -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-section based buffer for viewing and managing beads issues.
;; Designed to feel native to magit users with familiar keybindings and visual style.

;;; Code:

;; Persist the source directory so sibling files (ogent-issues-bd,
;; ogent-issues-graph, etc.) can always be found, even if load-path
;; is modified after initial load (e.g., by package manager rebuilds)
(defvar ogent-issues--source-directory
  (when-let ((file (or load-file-name buffer-file-name)))
    (file-name-directory file))
  "Directory containing ogent-issues and sibling .el files.
Captured at load time so sibling requires remain robust.")

(when (and ogent-issues--source-directory
           (not (member ogent-issues--source-directory load-path)))
  (add-to-list 'load-path ogent-issues--source-directory))

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'ogent-ops-style)

;; Soft dependency on magit-section - check at both compile and load time
;; to ensure classes are properly defined for macro expansion
(eval-and-compile
  (defvar ogent-issues--magit-section-available
    (require 'magit-section nil t)
    "Non-nil if magit-section is available.")
  (when ogent-issues--magit-section-available
    (require 'magit-section)))

(require 'ogent-issues-bd)

;; Load transient menu if available
(declare-function ogent-issues-dispatch "ogent-issues-transient" nil t)
(autoload 'ogent-issues-dispatch "ogent-issues-transient" nil t)
(autoload 'ogent-issues-create-dispatch "ogent-issues-transient" nil t)
(autoload 'ogent-issues-filter-dispatch "ogent-issues-transient" nil t)

;; Load graph visualization if available
(declare-function ogent-issues-graph-view "ogent-issues-graph" (&optional issue-id) t)
(autoload 'ogent-issues-graph-view "ogent-issues-graph" nil t)

;; Gas Town integration (soft dependency)
(declare-function ogent-gastown-integration-active-p "ogent-gastown" () t)
(declare-function ogent-gastown-status "ogent-gastown-status" () t)
(declare-function ogent-gastown-mail-compose "ogent-gastown-status"
  (&optional initial-recipient initial-subject initial-body) t)
(declare-function ogent-gastown--run-async "ogent-gastown" (command args callback &optional error-callback raw-output))
(declare-function ogent-gastown-fetch-agent-assignments "ogent-gastown" (callback))
(declare-function ogent-gastown-format-agent-assignment "ogent-gastown" (bead-id))
(autoload 'ogent-gastown-integration-active-p "ogent-gastown" nil nil)
(autoload 'ogent-gastown-status "ogent-gastown-status" nil t)
(autoload 'ogent-gastown-mail-compose "ogent-gastown-status" nil t)
(autoload 'ogent-gastown--run-async "ogent-gastown" nil nil)
(autoload 'ogent-gastown-fetch-agent-assignments "ogent-gastown" nil nil)
(autoload 'ogent-gastown-format-agent-assignment "ogent-gastown" nil nil)

;;; Customization

(defgroup ogent-issues nil
  "Magit-style beads issue viewer."
  :group 'ogent
  :prefix "ogent-issues-")

(defcustom ogent-issues-buffer-name "*ogent-issues*"
  "Name of the ogent-issues buffer.
When `ogent-issues-per-project-buffers' is nil (the default), this
is used as the buffer name.  When per-project buffers are enabled,
the project name is appended."
  :type 'string
  :group 'ogent-issues)

(defcustom ogent-issues-per-project-buffers t
  "When non-nil, create separate buffer for each project.
Buffer names will be `*ogent-issues: <project>*'.
When nil, use single shared buffer (not recommended).
Default is t, matching magit's behavior of per-repo buffers."
  :type 'boolean
  :group 'ogent-issues)

(defcustom ogent-issues-default-view 'list
  "Default view when opening ogent-issues.
Options: `list', `ready', `kanban'."
  :type '(choice (const :tag "List view" list)
                 (const :tag "Ready work" ready)
                 (const :tag "Kanban board" kanban))
  :group 'ogent-issues)

(defcustom ogent-issues-collapsed-statuses '("closed")
  "List of statuses that should be collapsed by default."
  :type '(repeat string)
  :group 'ogent-issues)

(defcustom ogent-issues-use-unicode t
  "Whether to use Unicode characters for icons.
Set to nil for ASCII-only terminals."
  :type 'boolean
  :group 'ogent-issues)

(defcustom ogent-issues-show-counts t
  "Whether to show issue counts in section headings."
  :type 'boolean
  :group 'ogent-issues)

(defcustom ogent-issues-display-buffer-action 'same-window
  "How to display the issues buffer when calling `ogent-issues'.
Options:
  `same-window' - Take over current window (like `magit-status')
  `other-window' - Display in another window (horizontal split)"
  :type '(choice (const :tag "Same window (magit-style)" same-window)
                 (const :tag "Other window" other-window))
  :group 'ogent-issues)

(defcustom ogent-issues-detail-display-action 'below
  "How to display the issue detail buffer.
Options:
  `below' - Vertical split below issues buffer (like `magit-show-commit')
  `other-window' - Display in another window"
  :type '(choice (const :tag "Below (magit-style)" below)
                 (const :tag "Other window" other-window))
  :group 'ogent-issues)

(defcustom ogent-issues-detail-auto-refresh t
  "Whether to automatically refresh issue details in background.
When non-nil, after rendering the detail view with cached data,
a background fetch will update the view with fresh data (comments, etc.).
Set to nil for fastest possible display with no background activity."
  :type 'boolean
  :group 'ogent-issues)

;;; Faces - Following magit conventions

(defgroup ogent-issues-faces nil
  "Faces for ogent-issues."
  :group 'ogent-issues
  :group 'faces)

;; Section headings - like magit-section-heading
(defface ogent-issues-section-heading
  '((((class color) (background light))
     :foreground "#37474f" :background "#eceff1" :weight bold :extend t)
    (((class color) (background dark))
     :foreground "#eceff4" :background "#3b4252" :weight bold :extend t)
    (t :weight bold))
  "Face for section headings."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading-view
  '((((class color) (background light))
     :inherit ogent-issues-section-heading
     :foreground "#4e342e" :background "#efebe9")
    (((class color) (background dark))
     :inherit ogent-issues-section-heading
     :foreground "#e5c07b" :background "#4a4037")
    (t :inherit ogent-issues-section-heading))
  "Face for primary Issues view headings."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading-in-progress
  '((((class color) (background light))
     :inherit ogent-issues-section-heading
     :foreground "#4a148c" :background "#ede7f6")
    (((class color) (background dark))
     :inherit ogent-issues-section-heading
     :foreground "#caa1ff" :background "#3f3158")
    (t :inherit ogent-issues-section-heading))
  "Face for the in-progress status section heading."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading-open
  '((((class color) (background light))
     :inherit ogent-issues-section-heading
     :foreground "#0d47a1" :background "#e3f2fd")
    (((class color) (background dark))
     :inherit ogent-issues-section-heading
     :foreground "#8cc7ff" :background "#2f435e")
    (t :inherit ogent-issues-section-heading))
  "Face for the open status section heading."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading-blocked
  '((((class color) (background light))
     :inherit ogent-issues-section-heading
     :foreground "#b71c1c" :background "#ffebee")
    (((class color) (background dark))
     :inherit ogent-issues-section-heading
     :foreground "#ff9aa2" :background "#5a3338")
    (t :inherit ogent-issues-section-heading))
  "Face for the blocked status section heading."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading-closed
  '((((class color) (background light))
     :inherit ogent-issues-section-heading
     :foreground "#37474f" :background "#eceff1")
    (((class color) (background dark))
     :inherit ogent-issues-section-heading
     :foreground "#c0c5ce" :background "#323b4a")
    (t :inherit ogent-issues-section-heading))
  "Face for the closed status section heading."
  :group 'ogent-issues-faces)

(defface ogent-issues-section-heading-selection
  '((((class color) (background light))
     :inherit ogent-issues-section-heading
     :foreground "#bf360c" :background "#ffe0b2" :weight bold)
    (((class color) (background dark))
     :inherit ogent-issues-section-heading
     :foreground "#d08770" :background "#5a3f33" :weight bold)
    (t :weight bold :underline t))
  "Face for selected section headings."
  :group 'ogent-issues-faces)

;; Issue ID - like magit-hash
(defface ogent-issues-id
  '((((class color) (background light)) :foreground "#546e7a")
    (((class color) (background dark)) :foreground "#81a1c1")
    (t :inherit font-lock-comment-face))
  "Face for issue IDs."
  :group 'ogent-issues-faces)

;; Priority faces - refined color scale
(defface ogent-issues-priority-critical
  '((((class color) (background light)) :foreground "#c62828" :weight bold)
    (((class color) (background dark)) :foreground "#bf616a" :weight bold)
    (t :weight bold :inverse-video t))
  "Face for P0 (critical) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-high
  '((((class color) (background light)) :foreground "#d84315" :weight bold)
    (((class color) (background dark)) :foreground "#d08770" :weight bold)
    (t :weight bold :underline t))
  "Face for P1 (high) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-medium
  '((((class color) (background light)) :foreground "#5d4037")
    (((class color) (background dark)) :foreground "#ebcb8b")
    (t :inherit default))
  "Face for P2 (medium) issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-priority-low
  '((((class color) (background light)) :foreground "#558b2f")
    (((class color) (background dark)) :foreground "#a3be8c")
    (t :inherit font-lock-comment-face))
  "Face for P3 (low) issues."
  :group 'ogent-issues-faces)

;; Status faces
(defface ogent-issues-status-open
  '((((class color) (background light)) :foreground "#1565c0")
    (((class color) (background dark)) :foreground "#88c0d0")
    (t :inherit font-lock-function-name-face))
  "Face for open issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-in-progress
  '((((class color) (background light)) :foreground "#6a1b9a" :weight bold)
    (((class color) (background dark)) :foreground "#b48ead" :weight bold)
    (t :weight bold :inherit font-lock-keyword-face))
  "Face for in-progress issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-blocked
  '((((class color) (background light)) :foreground "#c62828" :slant italic)
    (((class color) (background dark)) :foreground "#bf616a" :slant italic)
    (t :slant italic :inherit font-lock-warning-face))
  "Face for blocked issues."
  :group 'ogent-issues-faces)

(defface ogent-issues-status-closed
  '((((class color) (background light)) :foreground "grey55")
    (((class color) (background dark)) :foreground "#4c566a")
    (t :inherit shadow))
  "Face for closed issues."
  :group 'ogent-issues-faces)

;; Ready indicator
(defface ogent-issues-ready
  '((((class color) (background light)) :foreground "#2e7d32" :weight bold)
    (((class color) (background dark)) :foreground "#a3be8c" :weight bold)
    (t :weight bold :inherit success))
  "Face for ready issue indicator."
  :group 'ogent-issues-faces)

;; Dimmed text - like magit-dimmed
(defface ogent-issues-dimmed
  '((((class color) (background light)) :foreground "#78909c")
    (((class color) (background dark)) :foreground "#4c566a")
    (t :inherit shadow))
  "Face for less important text."
  :group 'ogent-issues-faces)

;; Type badge
(defface ogent-issues-type
  '((((class color) (background light))
     :foreground "#455a64" :box (:line-width -1 :color "#90a4ae"))
    (((class color) (background dark))
     :foreground "#81a1c1" :box (:line-width -1 :color "#4c566a"))
    (t :inherit font-lock-type-face))
  "Face for issue type badges."
  :group 'ogent-issues-faces)

;; Header line - magit-style with background
(defface ogent-issues-header-line
  '((((class color) (background light))
     :background "grey90" :foreground "grey20"
     :weight bold :box (:line-width 2 :color "grey90"))
    (((class color) (background dark))
     :background "#2e3440" :foreground "#eceff4"
     :weight bold :box (:line-width 2 :color "#2e3440"))
    (t :weight bold :inherit mode-line))
  "Face for the header line title."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line-project
  '((((class color) (background light))
     :background "grey90" :foreground "#5e81ac" :weight bold)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#88c0d0" :weight bold)
    (t :weight bold :inherit mode-line))
  "Face for the project name in header line."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line-view
  '((((class color) (background light))
     :background "grey90" :foreground "#4c566a")
    (((class color) (background dark))
     :background "#2e3440" :foreground "#81a1c1")
    (t :inherit mode-line))
  "Face for the view indicator in header line."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line-stat
  '((((class color) (background light))
     :background "grey90" :foreground "grey40")
    (((class color) (background dark))
     :background "#2e3440" :foreground "#7b88a1")
    (t :inherit mode-line))
  "Face for stats in header line."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line-ready
  '((((class color) (background light))
     :background "grey90" :foreground "#2e7d32" :weight bold)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#a3be8c" :weight bold)
    (t :weight bold :inherit mode-line))
  "Face for ready count in header line."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line-blocked
  '((((class color) (background light))
     :background "grey90" :foreground "#bf360c" :slant italic)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#bf616a" :slant italic)
    (t :slant italic :inherit mode-line))
  "Face for blocked count in header line."
  :group 'ogent-issues-faces)

(defface ogent-issues-header-line-key
  '((((class color) (background light))
     :background "grey90" :foreground "#5e35b1" :weight bold)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#b48ead" :weight bold)
    (t :weight bold :inherit mode-line))
  "Face for keybindings in header line."
  :group 'ogent-issues-faces)

;;; Type Icons

(defcustom ogent-issues-type-icons
  '(("bug" . ("[bug]" . "B"))
    ("feature" . ("[feat]" . "F"))
    ("task" . ("[task]" . "T"))
    ("epic" . ("[epic]" . "E"))
    ("chore" . ("[chore]" . "C")))
  "Icons for issue types.
Each entry is (TYPE . (UNICODE . ASCII))."
  :type '(alist :key-type string
                :value-type (cons string string))
  :group 'ogent-issues)

;;; Buffer-local State

(defvar-local ogent-issues--current-view 'list
  "Current view mode: `list', `ready', or `kanban'.")

(defvar-local ogent-issues--filters nil
  "Current active filters as plist (:status :type :priority :assignee).")

(defvar-local ogent-issues--issues nil
  "Cached list of issues for the current buffer.")

(defvar-local ogent-issues--last-position nil
  "Last cursor position for restoration after refresh.")

(defvar-local ogent-issues--project-root nil
  "Project root for the issues displayed in this buffer.
Used to detect project switches and clear stale state.")

;;; Loading State

(defvar-local ogent-issues--loading nil
  "Non-nil when a bd command is in progress.")

(defvar-local ogent-issues--loading-timer nil
  "Timer for animating the loading spinner.")

(defvar-local ogent-issues--loading-frame 0
  "Current animation frame index (0-3).")

(defvar-local ogent-issues--agent-assignments nil
  "Hash table mapping bead-id to agent assignment info.
Populated from Gas Town crew/polecat data when integration is active.")

(defvar ogent-issues--loading-frames nil
  "Animation frames for loading spinner.
Uses Unicode in GUI, ASCII in terminal.
Initialized lazily to avoid issues during byte-compilation.")

(defun ogent-issues--get-loading-frames ()
  "Return loading frames, initializing if needed."
  (or ogent-issues--loading-frames
      (setq ogent-issues--loading-frames (ogent-ops-loading-frames))))

;;; Section Classes (when magit-section available)
;; Use eval-and-compile to ensure classes exist at macro-expansion time
;; (needed for magit-insert-section macro)

(eval-and-compile
  (when (bound-and-true-p ogent-issues--magit-section-available)
    (defclass ogent-issues-root-section (magit-section) ()
	      "Root section for ogent-issues buffer.")

    (defclass ogent-issues-status-section (magit-section) ()
	      "Section for a status group (open, in_progress, etc.).
The inherited `value' slot holds the status string.")

    (defclass ogent-issues-issue-section (magit-section) ()
	      "Section for a single issue.
The inherited `value' slot holds the issue plist.")))

;;; Keymap - Following magit conventions

(defvar ogent-issues-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Inherit from magit-section if available
    (when (and ogent-issues--magit-section-available
               (boundp 'magit-section-mode-map))
      (set-keymap-parent map magit-section-mode-map))
    
    ;; Navigation - n/p for issue navigation
    ;; j/k are intentionally NOT bound here so evil users get normal line movement
    (define-key map "n" #'ogent-issues-next-issue)
    (define-key map "p" #'ogent-issues-prev-issue)
    (define-key map "N" #'ogent-issues-next-ready)  ; Jump to next ready issue
    (define-key map (kbd "M-n") #'ogent-issues-next-section)
    (define-key map (kbd "M-p") #'ogent-issues-prev-section)
    (define-key map (kbd "RET") #'ogent-issues-visit)
    (define-key map (kbd "TAB") #'ogent-issues-toggle-section)
    (define-key map (kbd "<backtab>") #'ogent-issues-cycle-sections)
    (define-key map (kbd "^") #'ogent-issues-up-section)
    
    ;; Refresh (magit-style: g)
    (define-key map "g" #'ogent-issues-refresh)
    (define-key map "G" #'ogent-issues-refresh-force)
    
    ;; Actions - single keys for common ops
    (define-key map "c" #'ogent-issues-create)
    (define-key map "s" #'ogent-issues-start)
    (define-key map "K" #'ogent-issues-close)
    (define-key map "x" #'ogent-issues-close)
    (define-key map "r" #'ogent-issues-reopen)
    (define-key map "C" #'ogent-issues-comment)
    
    ;; Help/dispatch (magit-style: ?)
    (define-key map "?" #'ogent-issues-dispatch)
    (define-key map "h" #'ogent-issues-dispatch)
    
    ;; Filters (f prefix like magit fetch)
    (define-key map "f" nil)  ; prefix
    (define-key map "fs" #'ogent-issues-filter-status)
    (define-key map "ft" #'ogent-issues-filter-type)
    (define-key map "fp" #'ogent-issues-filter-priority)
    (define-key map "ff" #'ogent-issues-filter-dispatch)
    (define-key map "fc" #'ogent-issues-clear-filters)
    
    ;; Views (v prefix)
    (define-key map "v" nil)  ; prefix
    (define-key map "vl" #'ogent-issues-view-list)
    (define-key map "vr" #'ogent-issues-view-ready)
    (define-key map "vk" #'ogent-issues-view-kanban)
    (define-key map "vd" #'ogent-issues-view-deps)

    ;; Dependencies (d for current issue's graph)
    (define-key map "d" #'ogent-issues-view-deps-current)
    
    ;; Kanban-specific (work in all views, but most useful in Kanban)
    (define-key map "H" #'ogent-issues-kanban-move-left)
    (define-key map "L" #'ogent-issues-kanban-move-right)
    
    ;; Sync (like magit push/pull)
    (define-key map "S" #'ogent-issues-sync)
    
    ;; Quit
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-issues-mode'.")



;;; Mode Definition
;; Derive from magit-section-mode when available for proper section support,
;; otherwise fall back to special-mode. We use a macro to determine the parent
;; at compile/load time since define-derived-mode needs a literal symbol.

(defmacro ogent-issues--define-mode ()
  "Define `ogent-issues-mode' with appropriate parent mode."
  (let ((parent (if (bound-and-true-p ogent-issues--magit-section-available)
                    'magit-section-mode
                  'special-mode)))
    `(define-derived-mode ogent-issues-mode ,parent "Issues"
       "Major mode for viewing and managing beads issues.

Like magit-status but for your issue tracker.

\\<ogent-issues-mode-map>
Navigation:
  \\[ogent-issues-next-issue]     Move to next issue
  \\[ogent-issues-prev-issue]     Move to previous issue
  \\[ogent-issues-visit]   Visit issue details
  \\[ogent-issues-toggle-section]   Toggle section visibility

Actions:
  \\[ogent-issues-create]     Create new issue
  \\[ogent-issues-start]     Start working on issue
  \\[ogent-issues-close]     Close issue
  \\[ogent-issues-comment]     Add comment

Filters:
  \\[ogent-issues-filter-status]    Filter by status
  \\[ogent-issues-filter-type]    Filter by type
  \\[ogent-issues-filter-priority]    Filter by priority
  \\[ogent-issues-clear-filters]    Clear all filters

Views:
  \\[ogent-issues-view-list]    List view
  \\[ogent-issues-view-ready]    Ready work
  \\[ogent-issues-view-kanban]    Kanban board

Other:
  \\[ogent-issues-refresh]     Refresh
  \\[ogent-issues-sync]     Sync to git
  \\[ogent-issues-dispatch]     Show all commands

\\{ogent-issues-mode-map}"
       :group 'ogent-issues
       (setq-local revert-buffer-function #'ogent-issues-refresh)
       (setq-local truncate-lines t)
       (setq-local buffer-read-only t)
       (setq header-line-format '(:eval (ogent-issues--header-line)))
       (ogent-ops-protect-face-properties)
       ;; Configure magit-section if we're derived from it
       (when (bound-and-true-p ogent-issues--magit-section-available)
         (setq-local magit-section-visibility-indicator
                     (if ogent-issues-use-unicode '("…" . t) '("..." . t)))))))

(ogent-issues--define-mode)

;;; Loading Animation

(defun ogent-issues--start-loading ()
  "Start the loading animation."
  ;; Guard: only run in ogent-issues-mode buffers where buffer-local vars exist
  (when (and (eq major-mode 'ogent-issues-mode)
             (boundp 'ogent-issues--loading))
    (setq ogent-issues--loading t
          ogent-issues--loading-frame 0)
    (ogent-issues--stop-loading-timer)
    (setq ogent-issues--loading-timer
          (run-at-time 0.25 0.25 #'ogent-issues--animate-loading (current-buffer)))
    (force-mode-line-update)))

(defun ogent-issues--stop-loading ()
  "Stop the loading animation."
  (ogent-issues--stop-loading-timer)
  (setq ogent-issues--loading nil)
  (force-mode-line-update))

(defun ogent-issues--stop-loading-timer ()
  "Cancel the loading timer if active."
  (when (and (boundp 'ogent-issues--loading-timer)
             ogent-issues--loading-timer)
    (cancel-timer ogent-issues--loading-timer)
    (setq ogent-issues--loading-timer nil)))

(defun ogent-issues--animate-loading (buffer)
  "Advance the loading animation frame in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ogent-issues--loading-frame
            (mod (1+ ogent-issues--loading-frame) 4))
      (force-mode-line-update))))

(defun ogent-issues--loading-indicator ()
  "Return the current loading spinner character, or nil if not loading."
  (when ogent-issues--loading
    (nth ogent-issues--loading-frame (ogent-issues--get-loading-frames))))

(defun ogent-issues--cleanup-on-kill ()
  "Clean up timers when the buffer is killed."
  (ogent-issues--stop-loading-timer))

(add-hook 'ogent-issues-mode-hook
          (lambda ()
            (add-hook 'kill-buffer-hook #'ogent-issues--cleanup-on-kill nil t)))

;;; Entry Point

(defun ogent-issues--buffer-name ()
  "Return buffer name for current project.
When `ogent-issues-per-project-buffers' is non-nil, returns a
project-specific name like `*ogent-issues: <project>*'.
Otherwise returns `ogent-issues-buffer-name'."
  (if ogent-issues-per-project-buffers
      (let ((project (ogent-issues-bd-project-name)))
        (format "*ogent-issues: %s*" (or project "unknown")))
    ogent-issues-buffer-name))

;;;###autoload
(defun ogent-issues ()
  "Open the ogent-issues buffer for the current project.
Like `magit-status', this always shows issues for the project containing
the current buffer's file. By default, takes over the current window.
Customize `ogent-issues-display-buffer-action' to change display behavior."
  (interactive)
  (let ((current-project (ogent-issues-bd-project-root)))
    ;; Error if not in a beads project
    (unless current-project
      (user-error "Not in a beads project (no .beads directory found). Run `bd init' to initialize"))
    ;; Bind default-directory to project root so buffer inherits it
    ;; This ensures subsequent calls from the issues buffer detect the correct project
    (let* ((default-directory current-project)
           (buf (get-buffer-create (ogent-issues--buffer-name))))
      (with-current-buffer buf
        ;; Set default-directory in the buffer itself
        (setq default-directory current-project)
        (unless (eq major-mode 'ogent-issues-mode)
          (ogent-issues-mode))
        ;; Detect project change and clear stale state
        (when (and ogent-issues--project-root
                   (not (equal ogent-issues--project-root current-project)))
          (setq ogent-issues--issues nil)
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert "Loading issues...\n")))
        (setq ogent-issues--project-root current-project)
        (ogent-issues-refresh))
      ;; Display based on customization (default to 'same-window if not set)
      (pcase (if (boundp 'ogent-issues-display-buffer-action)
                 ogent-issues-display-buffer-action
               'same-window)
        ('same-window (switch-to-buffer buf))
        ('other-window (switch-to-buffer-other-window buf))
        (_ (switch-to-buffer buf))))))

;;; Header Line

(defun ogent-issues--header-line ()
  "Generate header line for ogent-issues buffer."
  (let* ((project (or (ogent-issues-bd-project-name) "unknown"))
         (view (symbol-name ogent-issues--current-view))
         (issues ogent-issues--issues)
         (count (length issues))
         ;; Calculate ready and blocked counts
         (ready-count (cl-count-if #'ogent-issues--issue-ready-p issues))
         (blocked-count (cl-count-if (lambda (i) (string= (plist-get i :status) "blocked")) issues))
         (filters (ogent-issues--format-filters))
         (loading-indicator (ogent-issues--loading-indicator)))
    (concat
     (propertize " " 'face 'ogent-issues-header-line)
     (propertize "Issues" 'face 'ogent-issues-header-line)
     ;; Show loading spinner if loading
     (if loading-indicator
         (concat (propertize "  " 'face 'ogent-issues-header-line-stat)
                 (propertize loading-indicator 'face 'ogent-issues-header-line-ready)
                 (propertize " Loading..." 'face 'ogent-issues-header-line-stat))
       ;; Normal display when not loading
       (concat
        (propertize "  " 'face 'ogent-issues-header-line-stat)
        (propertize project 'face 'ogent-issues-header-line-project)
        (propertize "  " 'face 'ogent-issues-header-line-stat)
        (propertize (format "[%s]" (capitalize view)) 'face 'ogent-issues-header-line-view)
        (propertize "  " 'face 'ogent-issues-header-line-stat)
        ;; Show ready count with emphasis when > 0
        (if (> ready-count 0)
            (propertize (format "%d ready" ready-count) 'face 'ogent-issues-header-line-ready)
          (propertize "0 ready" 'face 'ogent-issues-header-line-stat))
        ;; Show blocked count only if > 0
        (if (> blocked-count 0)
            (concat (propertize "  " 'face 'ogent-issues-header-line-stat)
                    (propertize (format "%d blocked" blocked-count) 'face 'ogent-issues-header-line-blocked))
          "")
        (propertize (format "  %d total" count) 'face 'ogent-issues-header-line-stat)
        (if filters
            (concat (propertize "  filtered: " 'face 'ogent-issues-header-line-stat)
                    (ogent-issues--format-filters-for-header))
          "")
        (propertize "  " 'face 'ogent-issues-header-line-stat)
        (propertize "?" 'face 'ogent-issues-header-line-key)
        (propertize ":help " 'face 'ogent-issues-header-line-stat))))))

(defun ogent-issues--format-filters-for-header ()
  "Format current filters for header line with proper faces."
  (let ((parts nil))
    (when-let ((status (plist-get ogent-issues--filters :status)))
      (push (propertize status 'face 'ogent-issues-header-line-view) parts))
    (when-let ((type (plist-get ogent-issues--filters :type)))
      (push (propertize type 'face 'ogent-issues-header-line-view) parts))
    (when-let ((priority (plist-get ogent-issues--filters :priority)))
      (push (propertize (format "P%d" priority) 'face 'ogent-issues-header-line-view) parts))
    (if parts
        (mapconcat #'identity (nreverse parts) (propertize " " 'face 'ogent-issues-header-line-stat))
      "")))

(defun ogent-issues--format-filters ()
  "Format current filters for display."
  (let ((parts nil))
    (when-let ((status (plist-get ogent-issues--filters :status)))
      (push (propertize status 'face 'font-lock-keyword-face) parts))
    (when-let ((type (plist-get ogent-issues--filters :type)))
      (push (propertize type 'face 'font-lock-type-face) parts))
    (when-let ((priority (plist-get ogent-issues--filters :priority)))
      (push (propertize (format "P%d" priority) 'face (ogent-issues--priority-face priority)) parts))
    (when parts
      (string-join (nreverse parts) " "))))

;;; Formatting Utilities

(defun ogent-issues--type-icon (type)
  "Return icon for issue TYPE with proper face applied."
  (let ((entry (cdr (assoc type ogent-issues-type-icons))))
    (propertize
     (if ogent-issues-use-unicode
         (or (car entry) "•")
       (or (cdr entry) "?"))
     'face 'ogent-issues-type)))

(defun ogent-issues--priority-face (priority)
  "Return face for PRIORITY level."
  (pcase (or priority 2)
    (0 'ogent-issues-priority-critical)
    (1 'ogent-issues-priority-high)
    (2 'ogent-issues-priority-medium)
    (_ 'ogent-issues-priority-low)))

(defun ogent-issues--priority-indicator (priority)
  "Return formatted priority indicator for PRIORITY."
  (let ((p (or priority 2))
        (ogent-ops-use-unicode ogent-issues-use-unicode))
    (propertize (ogent-ops-priority-symbol p)
                'face (ogent-issues--priority-face p))))

(defun ogent-issues--status-face (status)
  "Return face for STATUS."
  (pcase status
    ("open" 'ogent-issues-status-open)
    ("in_progress" 'ogent-issues-status-in-progress)
    ("blocked" 'ogent-issues-status-blocked)
    ("closed" 'ogent-issues-status-closed)
    (_ 'default)))

(defun ogent-issues--status-label (status)
  "Return human-readable label for STATUS."
  (pcase status
    ("open" "Open")
    ("in_progress" "In Progress")
    ("blocked" "Blocked")
    ("closed" "Closed")
    (_ (capitalize (or status "unknown")))))

(defun ogent-issues--status-icon (status)
  "Return icon for STATUS."
  (let ((ogent-ops-use-unicode ogent-issues-use-unicode))
    (ogent-ops-status-symbol
     (pcase status
       ("open" 'open)
       ("in_progress" 'in-progress)
       ("blocked" 'blocked)
       ("closed" 'closed)
       (_ nil)))))

(defun ogent-issues--section-heading-face (section)
  "Return heading face for SECTION."
  (pcase section
    ('view 'ogent-issues-section-heading-view)
    ("in_progress" 'ogent-issues-section-heading-in-progress)
    ("open" 'ogent-issues-section-heading-open)
    ("blocked" 'ogent-issues-section-heading-blocked)
    ("closed" 'ogent-issues-section-heading-closed)
    (_ 'ogent-issues-section-heading)))

(defun ogent-issues--compose-view-heading (title)
  "Compose top-level heading TITLE for the current Issues view."
  (let* ((face (ogent-issues--section-heading-face 'view))
         (heading (propertize title 'face face)))
    (add-face-text-property 0 (length heading) face 'append heading)
    heading))

(defun ogent-issues--compose-status-heading (status count)
  "Compose a status heading for STATUS with COUNT items."
  (let* ((icon (ogent-issues--status-icon status))
         (label (ogent-issues--status-label status))
         (count-suffix (when ogent-issues-show-counts
                         (format " (%d)" (or count 0))))
         (heading-face (ogent-issues--section-heading-face status))
         (heading (concat icon " " label (or count-suffix "")))
         (count-start (+ (length icon) 1 (length label))))
    (add-face-text-property 0 (length heading) heading-face 'append heading)
    (add-face-text-property 0 (length icon)
                            (ogent-issues--status-face status)
                            'append
                            heading)
    (when count-suffix
      (add-face-text-property count-start (length heading) 'ogent-issues-dimmed 'append heading))
    heading))

(defun ogent-issues--ready-indicator ()
  "Return the ready indicator string."
  (let ((ogent-ops-use-unicode ogent-issues-use-unicode))
    (propertize (ogent-ops-status-symbol 'ready)
                'face 'ogent-issues-ready)))

(defun ogent-issues--issue-ready-p (issue)
  "Return non-nil if ISSUE is ready (unblocked and actionable).
An issue is ready if it's open, not blocked, and has no blockers."
  (let ((status (plist-get issue :status))
        (blocked-by (plist-get issue :blocked_by)))
    (and (string= status "open")
         (or (null blocked-by)
             (= (length blocked-by) 0)))))

(defun ogent-issues--format-agent-indicator (bead-id)
  "Return a propertized agent assignment string for BEAD-ID, or nil."
  (when-let ((agents (and ogent-issues--agent-assignments
                          (gethash bead-id ogent-issues--agent-assignments))))
    (let* ((first-name (car (car agents)))
           (count (length agents)))
      (propertize (if (= count 1)
                      (format " → %s" first-name)
                    (format " → %s +%d" first-name (1- count)))
                  'face 'ogent-issues-dimmed))))

(defun ogent-issues--format-issue-line (issue)
  "Format ISSUE as a single line for the list view."
  (let* ((id (plist-get issue :id))
         (title (plist-get issue :title))
         (priority (plist-get issue :priority))
         (type (plist-get issue :issue_type))
         (status (plist-get issue :status))
         (deps (or (plist-get issue :dependency_count) 0))
         (ready (ogent-issues--issue-ready-p issue))
         ;; Calculate available width for title
         (id-width 12)
         (meta-width 15)
         (available-width (max 20 (- (window-width) id-width meta-width 10)))
         (truncated-title (truncate-string-to-width (or title "") available-width nil nil "…")))
    (concat
     ;; Ready indicator or space
     (if ready (ogent-issues--ready-indicator) " ")
     " "
     ;; Issue ID (fixed width, dimmed)
     (propertize (truncate-string-to-width (or id "???") id-width nil ?\s)
                 'face 'ogent-issues-id)
     " "
     ;; Priority indicator
     (ogent-issues--priority-indicator priority)
     " "
     ;; Type icon
     (ogent-issues--type-icon type)
     " "
     ;; Title with status-based face
     (propertize truncated-title 'face (ogent-issues--status-face status))
     ;; Dependencies count (if any)
     (when (and deps (> deps 0))
       (propertize (format " (%d)" deps) 'face 'ogent-issues-dimmed))
     ;; Agent assignment (from Gas Town integration)
     (when-let ((agent-str (and ogent-issues--agent-assignments
                                id
                                (ogent-issues--format-agent-indicator id))))
       agent-str))))

;;; Section Insertion

(defun ogent-issues--insert-buffer-contents (issues)
  "Insert ISSUES into the current buffer."
  (if (null issues)
      (ogent-issues--insert-empty-state)
    (if ogent-issues--magit-section-available
        (ogent-issues--insert-with-magit-section issues)
      (ogent-issues--insert-plain issues))))

(defun ogent-issues--insert-empty-state ()
  "Insert empty state message when no issues match.
Wraps content in a magit-section root when available to prevent
errors in `magit-section-post-command-hook'."
  (if ogent-issues--magit-section-available
      ;; Wrap in root section to prevent nil section errors
      (magit-insert-section (ogent-issues-root-section)
        (ogent-issues--insert-empty-state-content))
    (ogent-issues--insert-empty-state-content)))

(defun ogent-issues--insert-empty-state-content ()
  "Insert the actual empty state content."
  (insert "\n")
  (if ogent-issues--filters
      (progn
        (insert (propertize "  No issues match current filters\n\n"
                            'face 'font-lock-warning-face))
        (insert "  Active filters: " (or (ogent-issues--format-filters) "none") "\n\n")
        (insert (propertize "  fc " 'face 'ogent-issues-header-line-key))
        (insert (propertize "clear filters  " 'face 'ogent-issues-dimmed))
        (insert (propertize "ff " 'face 'ogent-issues-header-line-key))
        (insert (propertize "change filters\n" 'face 'ogent-issues-dimmed)))
    (insert (propertize "  No issues found\n\n" 'face 'ogent-issues-dimmed))
    (insert (propertize "  c " 'face 'ogent-issues-header-line-key))
    (insert (propertize "create new issue\n" 'face 'ogent-issues-dimmed))))

(defun ogent-issues--insert-with-magit-section (issues)
  "Insert ISSUES using magit-section."
  (magit-insert-section (ogent-issues-root-section)
			(ogent-issues--insert-header-section)
			(insert "\n")
			(let ((grouped (ogent-issues--group-by-status issues)))
			  (dolist (status '("in_progress" "open" "blocked" "closed"))
			    (when-let ((group (alist-get status grouped nil nil #'string=)))
			      (ogent-issues--insert-status-section status group))))))

(defun ogent-issues--insert-plain (issues)
  "Insert ISSUES without magit-section (fallback)."
  (ogent-issues--insert-header-section)
  (insert "\n")
  (let ((grouped (ogent-issues--group-by-status issues)))
    (dolist (status '("in_progress" "open" "blocked" "closed"))
      (when-let ((group (alist-get status grouped nil nil #'string=)))
        (insert (ogent-issues--compose-status-heading status (length group)))
        (insert "\n")
        (dolist (issue group)
          (insert (ogent-issues--format-issue-line issue) "\n")
          (put-text-property (line-beginning-position 0)
                             (line-end-position 0)
                             'ogent-issue issue))
        (insert "\n")))))

(defun ogent-issues--insert-header-section ()
  "Insert buffer header with quick help."
  (let ((view-name (pcase ogent-issues--current-view
                     ('list "Issues")
                     ('ready "Ready Work")
                     ('kanban "Kanban")
                     (_ "Issues"))))
    (insert (ogent-issues--compose-view-heading view-name))
    (insert "\n")))

(defun ogent-issues--insert-status-section (status issues)
  "Insert a section for STATUS containing ISSUES."
  (let ((collapsed (member status ogent-issues-collapsed-statuses))
        (count (length issues)))
    (magit-insert-section (ogent-issues-status-section status collapsed)
			  (magit-insert-heading
                           (ogent-issues--compose-status-heading status count))
			  (dolist (issue issues)
			    (ogent-issues--insert-issue issue))
			  (insert "\n"))))

(defun ogent-issues--insert-issue (issue)
  "Insert a single ISSUE as a section."
  (if ogent-issues--magit-section-available
      (magit-insert-section (ogent-issues-issue-section issue)
			    (insert (ogent-issues--format-issue-line issue) "\n"))
    (insert (ogent-issues--format-issue-line issue) "\n")
    (put-text-property (line-beginning-position 0)
                       (line-end-position 0)
                       'ogent-issue issue)))

(defun ogent-issues--group-by-status (issues)
  "Group ISSUES by status, returning an alist."
  (seq-group-by (lambda (i) (plist-get i :status)) issues))

;;; Navigation

(defun ogent-issues--current-issue ()
  "Return the issue at point, or nil."
  (if ogent-issues--magit-section-available
      (when-let ((section (magit-current-section)))
        ;; Use eq on class name to avoid cl-typep compile-time type resolution
        (when (eq (eieio-object-class-name section) 'ogent-issues-issue-section)
          (oref section value)))
    (get-text-property (point) 'ogent-issue)))

(defun ogent-issues--current-issue-id ()
  "Return the ID of the issue at point, or nil."
  (when-let ((issue (ogent-issues--current-issue)))
    (plist-get issue :id)))

(defun ogent-issues-next-issue ()
  "Move to the next issue."
  (interactive)
  (if ogent-issues--magit-section-available
      (let ((prev-pos nil))
        (magit-section-forward)
        ;; Skip non-issue sections, tracking position to prevent infinite loop
        (while (let ((cur-pos (point)))
                 (and (not (eobp))
                      (not (eq cur-pos prev-pos))
                      (not (ogent-issues--current-issue))
                      (setq prev-pos cur-pos)))
          (magit-section-forward)))
    ;; Fallback: search for next issue property
    (let ((pos (next-single-property-change (point) 'ogent-issue)))
      (when pos
        (goto-char pos)))))

(defun ogent-issues-prev-issue ()
  "Move to the previous issue."
  (interactive)
  (if ogent-issues--magit-section-available
      (let ((prev-pos nil))
        (magit-section-backward)
        ;; Skip non-issue sections, tracking position to prevent infinite loop
        (while (let ((cur-pos (point)))
                 (and (not (bobp))
                      (not (eq cur-pos prev-pos))
                      (not (ogent-issues--current-issue))
                      (setq prev-pos cur-pos)))
          (magit-section-backward)))
    ;; Fallback: search for previous issue property
    (let ((pos (previous-single-property-change (point) 'ogent-issue)))
      (when pos
        (goto-char pos)))))

(defun ogent-issues-next-ready ()
  "Move to the next ready (unblocked, actionable) issue."
  (interactive)
  (let ((start-pos (point))
        (found nil)
        (prev-pos nil))
    ;; Move forward until we find a ready issue or reach end
    (while (let ((cur-pos (point)))
             (and (not found)
                  (not (eobp))
                  (not (eq cur-pos prev-pos))
                  (setq prev-pos cur-pos)))
      (ogent-issues-next-issue)
      (when-let ((issue (ogent-issues--current-issue)))
        (when (ogent-issues--issue-ready-p issue)
          (setq found t))))
    (if found
        (message "Ready: %s" (plist-get (ogent-issues--current-issue) :id))
      ;; Wrap around from beginning
      (goto-char (point-min))
      (setq prev-pos nil)
      (while (let ((cur-pos (point)))
               (and (not found)
                    (< (point) start-pos)
                    (not (eobp))
                    (not (eq cur-pos prev-pos))
                    (setq prev-pos cur-pos)))
        (ogent-issues-next-issue)
        (when-let ((issue (ogent-issues--current-issue)))
          (when (ogent-issues--issue-ready-p issue)
            (setq found t))))
      (unless found
        (goto-char start-pos)
        (message "No ready issues found")))))

(defun ogent-issues-next-section ()
  "Move to the next status section."
  (interactive)
  (when ogent-issues--magit-section-available
    (magit-section-forward-sibling)))

(defun ogent-issues-prev-section ()
  "Move to the previous status section."
  (interactive)
  (when ogent-issues--magit-section-available
    (magit-section-backward-sibling)))

(defun ogent-issues-up-section ()
  "Move to the parent section."
  (interactive)
  (when ogent-issues--magit-section-available
    (magit-section-up)))

(defun ogent-issues-toggle-section ()
  "Toggle the current section."
  (interactive)
  (if ogent-issues--magit-section-available
      (if-let ((section (magit-current-section)))
          (magit-section-toggle section)
        (message "No section at point"))
    (message "Section toggling requires magit-section")))

(defun ogent-issues-cycle-sections ()
  "Cycle visibility of all sections."
  (interactive)
  (if ogent-issues--magit-section-available
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-issues-visit ()
  "Visit the issue at point (show details)."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (ogent-issues--show-detail issue)
    (user-error "No issue at point")))

;;; Detail View

(defvar ogent-issues-detail-buffer-name "*ogent-issue*"
  "Base name of the issue detail buffer.
Actual buffer name includes project: `*ogent-issue: <project>*'.")

(defun ogent-issues--detail-buffer-name ()
  "Return the detail buffer name for the current project."
  (let ((project (ogent-issues-bd-project-name)))
    (format "*ogent-issue: %s*" (or project "unknown"))))

(defvar ogent-issues-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" #'quit-window)
    (define-key map "g" #'ogent-issues-detail-refresh)
    (define-key map "K" #'ogent-issues-detail-close)
    ;; k is NOT bound here so evil users get normal up movement
    (define-key map "R" #'ogent-issues-detail-reopen)
    (define-key map "r" #'ogent-issues-detail-reopen)
    (define-key map "s" #'ogent-issues-detail-start)
    (define-key map "C" #'ogent-issues-detail-comment)
    (define-key map (kbd "RET") #'ogent-issues-detail-follow-link)
    (define-key map "?" #'ogent-issues-detail-help)
    map)
  "Keymap for `ogent-issues-detail-mode'.")

(define-derived-mode ogent-issues-detail-mode special-mode "Issue"
  "Major mode for viewing issue details."
  :group 'ogent-issues
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (ogent-ops-protect-face-properties))

(defvar-local ogent-issues-detail--issue nil
  "The issue being displayed in this detail buffer.")

(defvar-local ogent-issues-detail--gastown-agents nil
  "List of agents working on the current detail issue.
Each element is a plist with :name, :type (\"crew\" or \"polecat\"),
:rig, and :state.")

(defun ogent-issues--show-detail (issue)
  "Show detailed view for ISSUE in a dedicated buffer.
Renders immediately with available data for instant feedback.
Optionally refreshes in background if
`ogent-issues-detail-auto-refresh' is non-nil."
  ;; Capture project root from current buffer (the issues buffer)
  ;; so detail buffer and callbacks use the correct project
  (let ((project-root (ogent-issues-bd-project-root))
        (detail-buf-name (ogent-issues--detail-buffer-name)))
    ;; Render immediately with the data we have (no waiting for bd show)
    (ogent-issues--render-detail issue project-root detail-buf-name)
    ;; Background refresh to get fresh data (comments, full description, etc.)
    (when (and (boundp 'ogent-issues-detail-auto-refresh)
               ogent-issues-detail-auto-refresh)
      (let ((id (plist-get issue :id))
            (buf (get-buffer detail-buf-name)))
        ;; Run bd from the correct project directory
        (let ((default-directory project-root))
          (ogent-issues-bd-get id
                               (lambda (fresh-issue)
                                 (when (and (buffer-live-p buf)
                                            fresh-issue
                                            ;; Only re-render if still viewing same issue
                                            (with-current-buffer buf
                                              (equal (plist-get ogent-issues-detail--issue :id)
                                                     (plist-get fresh-issue :id))))
                                   (ogent-issues--render-detail fresh-issue project-root detail-buf-name)))
                               nil))))))

(defun ogent-issues--render-detail (issue &optional project-root buffer-name)
  "Render ISSUE in the detail buffer.
PROJECT-ROOT is the beads project directory (for setting default-directory).
BUFFER-NAME is the detail buffer name (defaults to project-specific name).
By default, displays in a vertical split below the issues buffer,
similar to how `magit-show-commit' displays commit details.
Customize `ogent-issues-detail-display-action' to change this behavior."
  (let* ((proj-root (or project-root (ogent-issues-bd-project-root)))
         (buf-name (or buffer-name (ogent-issues--detail-buffer-name)))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-issues-detail-mode)
        ;; Set default-directory so bd commands run in correct project
        (setq default-directory proj-root)
        (setq ogent-issues-detail--issue issue)
        (ogent-issues--insert-detail-header issue)
        (ogent-issues--insert-detail-description issue)
        (ogent-issues--insert-detail-subtasks issue)
        (ogent-issues--insert-detail-metadata issue)
        (ogent-issues--insert-detail-gastown issue)
        (ogent-issues--insert-detail-dependencies issue)
        (ogent-issues--insert-detail-comments issue)
        (goto-char (point-min))
        ;; Kick off async gastown agent fetch (will re-render when done)
        (ogent-issues--fetch-gastown-agents (plist-get issue :id) buf)
        (setq header-line-format
              (concat
               " "
               (propertize (plist-get issue :id) 'face 'ogent-issues-id)
               "  "
               (propertize "q" 'face 'ogent-issues-header-line-key)
               (propertize ":quit " 'face 'ogent-issues-dimmed)
               (propertize "g" 'face 'ogent-issues-header-line-key)
               (propertize ":refresh " 'face 'ogent-issues-dimmed)
               (propertize "s" 'face 'ogent-issues-header-line-key)
               (propertize ":start " 'face 'ogent-issues-dimmed)
               (propertize "K" 'face 'ogent-issues-header-line-key)
               (propertize ":close" 'face 'ogent-issues-dimmed)))))
    ;; Display based on customization (default to 'below if not set)
    (pcase (if (boundp 'ogent-issues-detail-display-action)
               ogent-issues-detail-display-action
             'below)
      ('below
       ;; Vertical split below, like magit-show-commit
       (let ((window (display-buffer buf
                                     '((display-buffer-below-selected)
                                       (window-height . 0.4)
                                       (preserve-size . (nil . t))))))
         (when window
           (select-window window))))
      ('other-window
       (pop-to-buffer buf))
      (_
       ;; Default to below
       (let ((window (display-buffer buf
                                     '((display-buffer-below-selected)
                                       (window-height . 0.4)
                                       (preserve-size . (nil . t))))))
         (when window
           (select-window window)))))))

(defun ogent-issues--insert-detail-header (issue)
  "Insert header section for ISSUE."
  (let* ((title (plist-get issue :title))
         (status (plist-get issue :status))
         (priority (plist-get issue :priority))
         (type (plist-get issue :issue_type))
         (ready (ogent-issues--issue-ready-p issue)))
    ;; Title line
    (insert (propertize (or title "Untitled") 'face '(:weight bold :height 1.1)))
    (insert "\n\n")
    ;; Status line with badges
    (insert (ogent-issues--priority-indicator priority))
    (insert " ")
    (insert (propertize (format "[%s]" (upcase (or type "task")))
                        'face 'ogent-issues-type))
    (insert " ")
    (insert (propertize (ogent-issues--status-label status)
                        'face (ogent-issues--status-face status)))
    (when ready
      (insert " ")
      (insert (ogent-issues--ready-indicator))
      (insert (propertize " ready" 'face 'ogent-issues-ready)))
    (insert "\n\n")))

(defun ogent-issues--insert-detail-description (issue)
  "Insert description section for ISSUE."
  (let ((desc (plist-get issue :description)))
    (insert (propertize "Description" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (if (and desc (not (string-empty-p desc)))
        (insert (ogent-issues--render-markdown desc))
      (insert (propertize "(No description)" 'face 'ogent-issues-dimmed)))
    (insert "\n\n")))

(defun ogent-issues--insert-detail-metadata (issue)
  "Insert metadata section for ISSUE."
  (let ((created (plist-get issue :created_at))
        (updated (plist-get issue :updated_at))
        (parent (plist-get issue :parent_id))
        (labels (plist-get issue :labels)))
    (insert (propertize "Metadata" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (propertize "Created  " 'face 'ogent-issues-dimmed))
    (insert (ogent-issues--format-time created))
    (insert "\n")
    (insert (propertize "Updated  " 'face 'ogent-issues-dimmed))
    (insert (ogent-issues--format-time updated))
    (insert "\n")
    (when parent
      (insert (propertize "Parent   " 'face 'ogent-issues-dimmed))
      (insert (ogent-issues--format-dep-link parent))
      (insert "\n"))
    (when labels
      (insert (propertize "Labels   " 'face 'ogent-issues-dimmed))
      (insert (if (listp labels)
                  (string-join labels ", ")
                labels))
      (insert "\n"))
    (insert "\n")))

(defun ogent-issues--insert-detail-gastown (issue)
  "Insert Gas Town agent assignment section for ISSUE.
Shows which agents (crew/polecats) have this bead hooked.
Only displayed when `ogent-gastown-integration-active-p' returns non-nil."
  (when (and (fboundp 'ogent-gastown-integration-active-p)
             (ogent-gastown-integration-active-p))
    (let ((agents ogent-issues-detail--gastown-agents))
      (insert (propertize "Gas Town" 'face 'ogent-issues-section-heading))
      (insert "\n")
      (cond
       ;; Agents found for this bead
       (agents
        (dolist (agent agents)
          (let* ((name (plist-get agent :name))
                 (agent-type (plist-get agent :type))
                 (rig (plist-get agent :rig))
                 (state (plist-get agent :state))
                 (running (plist-get agent :running))
                 (icon (if running "●" "○"))
                 (face (if running 'ogent-issues-status-in-progress
                         'ogent-issues-dimmed)))
            (insert (propertize "Assigned " 'face 'ogent-issues-dimmed))
            (insert (propertize icon 'face face))
            (insert " ")
            (insert (propertize (or name "???") 'face face))
            (when rig
              (insert (propertize (format " (%s/%s)" agent-type rig)
                                  'face 'ogent-issues-dimmed)))
            (when (and state (not running))
              (insert (propertize (format " [%s]" state)
                                  'face 'ogent-issues-dimmed)))
            (insert "\n"))))
       ;; No agents - show minimal message
       (t
        (insert (propertize "         " 'face 'ogent-issues-dimmed))
        (insert (propertize "No agent currently working on this issue"
                            'face 'ogent-issues-dimmed))
        (insert "\n")))
      (insert "\n"))))

(defun ogent-issues--fetch-gastown-agents (issue-id buffer)
  "Fetch Gas Town agent data and update BUFFER with agents for ISSUE-ID.
Fetches both crew and polecat lists, finds agents with this bead hooked,
and re-renders the detail view."
  (when (and (fboundp 'ogent-gastown--run-async)
             (fboundp 'ogent-gastown-integration-active-p)
             (ogent-gastown-integration-active-p))
    (let* ((pending 2)
           (crew-agents nil)
           (polecat-agents nil)
           (check-done
            (lambda ()
              (cl-decf pending)
              (when (zerop pending)
                (let ((all-agents (append crew-agents polecat-agents)))
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (when (and ogent-issues-detail--issue
                                 (equal (plist-get ogent-issues-detail--issue :id)
                                        issue-id))
                        ;; Only re-render if agent data changed
                        (unless (equal ogent-issues-detail--gastown-agents all-agents)
                          (setq ogent-issues-detail--gastown-agents all-agents)
                          (let ((inhibit-read-only t)
                                (pos (point)))
                            (erase-buffer)
                            (ogent-issues--insert-detail-header ogent-issues-detail--issue)
                            (ogent-issues--insert-detail-description ogent-issues-detail--issue)
                            (ogent-issues--insert-detail-subtasks ogent-issues-detail--issue)
                            (ogent-issues--insert-detail-metadata ogent-issues-detail--issue)
                            (ogent-issues--insert-detail-gastown ogent-issues-detail--issue)
                            (ogent-issues--insert-detail-dependencies ogent-issues-detail--issue)
                            (ogent-issues--insert-detail-comments ogent-issues-detail--issue)
                            (goto-char (min pos (point-max)))))))))))))
      ;; Fetch crew members
      (ogent-gastown--run-async
       "crew" '("list" "--json")
       (lambda (result)
         (when (listp result)
           (dolist (member result)
             (let ((hooked (plist-get member :hooked_work)))
               (when (and hooked (stringp hooked)
                          (string= hooked issue-id))
                 (push (list :name (plist-get member :name)
                             :type "crew"
                             :rig (plist-get member :rig)
                             :state nil
                             :running (plist-get member :session_running))
                       crew-agents)))))
         (funcall check-done))
       (lambda (_err) (funcall check-done)))
      ;; Fetch polecats
      (ogent-gastown--run-async
       "polecat" '("list" "--all" "--json")
       (lambda (result)
         (when (listp result)
           (dolist (polecat result)
             (let ((hooked (or (plist-get polecat :issue)
                               (plist-get polecat :hooked_work)
                               (plist-get polecat :current_task))))
               (when (and hooked (stringp hooked)
                          (string= hooked issue-id))
                 (push (list :name (plist-get polecat :name)
                             :type "polecat"
                             :rig (plist-get polecat :rig)
                             :state (plist-get polecat :state)
                             :running (plist-get polecat :session_running))
                       polecat-agents)))))
         (funcall check-done))
       (lambda (_err) (funcall check-done))))))

(defun ogent-issues--insert-detail-subtasks (issue)
  "Insert subtasks section for ISSUE (child issues)."
  (let* ((dependents (plist-get issue :dependents))
         (subtasks (seq-filter
                    (lambda (dep)
                      (string= (plist-get dep :dependency_type) "parent-child"))
                    dependents)))
    (when (and subtasks (> (length subtasks) 0))
      (insert (propertize (format "Subtasks (%d)" (length subtasks))
                          'face 'ogent-issues-section-heading))
      (insert "\n")
      (dolist (subtask subtasks)
        (ogent-issues--insert-subtask-line subtask))
      (insert "\n"))))

(defun ogent-issues--insert-subtask-line (subtask)
  "Insert a single SUBTASK as a line in the detail view."
  (let* ((id (plist-get subtask :id))
         (title (plist-get subtask :title))
         (status (plist-get subtask :status))
         (priority (or (plist-get subtask :priority) 2))
         (type (or (plist-get subtask :issue_type) "task"))
         (closed-p (string= status "closed"))
         (status-indicator (if closed-p
                               (propertize "✓" 'face 'ogent-issues-status-closed)
                             (propertize "○" 'face 'ogent-issues-status-open))))
    (insert "  ")
    (insert status-indicator)
    (insert " ")
    (insert (ogent-issues--format-dep-link id))
    (insert " ")
    (insert (ogent-issues--priority-indicator priority))
    (insert " ")
    (insert (propertize (format "[%s]" type) 'face 'ogent-issues-type))
    (insert " ")
    (insert (propertize (truncate-string-to-width (or title "") 50 nil nil "…")
                        'face (if closed-p 'ogent-issues-status-closed nil)))
    (insert "\n")))

(defun ogent-issues--insert-detail-dependencies (issue)
  "Insert dependencies section for ISSUE."
  (let* ((dependents (plist-get issue :dependents))
         ;; Filter out parent-child relationships (those are shown in Subtasks)
         (other-deps (seq-filter
                      (lambda (dep)
                        (not (string= (plist-get dep :dependency_type) "parent-child")))
                      dependents))
         (blocks (plist-get issue :blocks))
         (blocked-by (plist-get issue :blocked_by)))
    (insert (propertize "Dependencies" 'face 'ogent-issues-section-heading))
    (insert "\n")
    (insert (propertize "Blocks     " 'face 'ogent-issues-dimmed))
    (if (and blocks (> (length blocks) 0))
        (insert (mapconcat #'ogent-issues--format-dep-link blocks ", "))
      (insert (propertize "none" 'face 'ogent-issues-dimmed)))
    (insert "\n")
    (insert (propertize "Blocked by " 'face 'ogent-issues-dimmed))
    (if (and blocked-by (> (length blocked-by) 0))
        (insert (mapconcat #'ogent-issues--format-dep-link blocked-by ", "))
      (insert (propertize "none" 'face 'ogent-issues-dimmed)))
    (insert "\n")
    ;; Show other dependents (not parent-child) if any
    (when (and other-deps (> (length other-deps) 0))
      (insert (propertize "Dependents " 'face 'ogent-issues-dimmed))
      (insert (mapconcat (lambda (dep) (ogent-issues--format-dep-link (plist-get dep :id)))
                         other-deps ", "))
      (insert "\n"))
    (insert "\n")))

(defun ogent-issues--insert-detail-comments (issue)
  "Insert comments section for ISSUE."
  (let ((comments (plist-get issue :comments)))
    (insert (propertize (format "Comments (%d)" (length (or comments '())))
                        'face 'ogent-issues-section-heading))
    (insert "\n")
    (if (and comments (> (length comments) 0))
        (dolist (comment comments)
          (ogent-issues--insert-comment comment))
      (insert (propertize "(No comments)" 'face 'ogent-issues-dimmed)))
    (insert "\n")))

(defun ogent-issues--insert-comment (comment)
  "Insert a single COMMENT."
  (let ((author (or (plist-get comment :author) "unknown"))
        (time (plist-get comment :created_at))
        (text (or (plist-get comment :text)
                  (plist-get comment :body)
                  "")))
    (insert "\n")
    (insert (propertize (format "@%s" author) 'face 'font-lock-keyword-face))
    (insert " ")
    (insert (propertize (ogent-issues--format-time time) 'face 'ogent-issues-dimmed))
    (insert "\n")
    (insert (ogent-issues--indent-text text 2))
    (insert "\n")))

;;; Detail View Utilities

(defun ogent-issues--format-time (iso-time)
  "Format ISO-TIME as human-readable string."
  (if (and iso-time
           (stringp iso-time)
           (not (string-empty-p iso-time)))
      (condition-case nil
          (let ((time (parse-iso8601-time-string iso-time)))
            (format-time-string "%Y-%m-%d %H:%M" time))
        (error iso-time))
    "unknown"))

(defun ogent-issues--render-markdown (text)
  "Render TEXT with basic markdown formatting."
  (if (null text)
      ""
    (with-temp-buffer
      (insert text)
      ;; Bold: **text** or __text__
      (goto-char (point-min))
      (while (re-search-forward "\\*\\*\\(.+?\\)\\*\\*" nil t)
        (replace-match (propertize (match-string 1) 'face 'bold) t t))
      (goto-char (point-min))
      (while (re-search-forward "__\\(.+?\\)__" nil t)
        (replace-match (propertize (match-string 1) 'face 'bold) t t))
      ;; Code: `text`
      (goto-char (point-min))
      (while (re-search-forward "`\\([^`\n]+?\\)`" nil t)
        (replace-match (propertize (match-string 1) 'face 'font-lock-constant-face) t t))
      ;; Headers: ## text
      (goto-char (point-min))
      (while (re-search-forward "^##+ \\(.+\\)$" nil t)
        (replace-match (propertize (match-string 1) 'face 'ogent-issues-section-heading) t t))
      ;; List items: - or *
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)[-*] " nil t)
        (replace-match (concat (match-string 1) (if ogent-issues-use-unicode "• " "- "))))
      ;; Checkbox: - [ ] or - [x]
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)• \\[ \\]" nil t)
        (replace-match (concat (match-string 1) (if ogent-issues-use-unicode "☐ " "[ ] "))))
      (goto-char (point-min))
      (while (re-search-forward "^\\([ \t]*\\)• \\[x\\]" nil t)
        (replace-match (concat (match-string 1) (if ogent-issues-use-unicode "☑ " "[x] "))))
      (buffer-string))))

(defun ogent-issues--indent-text (text indent)
  "Indent TEXT by INDENT spaces."
  (if (null text)
      ""
    (let ((prefix (make-string indent ?\s)))
      (mapconcat (lambda (line) (concat prefix line))
                 (split-string text "\n")
                 "\n"))))

(defvar ogent-issues-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-issues-detail-follow-link)
    (define-key map [mouse-1] #'ogent-issues-detail-follow-link)
    map)
  "Keymap for issue links.")

(defun ogent-issues--format-dep-link (id)
  "Format ID as a clickable link."
  (propertize id
              'face 'link
              'mouse-face 'highlight
              'help-echo (format "Visit issue %s" id)
              'ogent-issue-id id
              'keymap ogent-issues-link-map))

;;; Detail View Actions

(defun ogent-issues-detail-refresh ()
  "Refresh the current detail view."
  (interactive)
  (when ogent-issues-detail--issue
    (ogent-issues--show-detail ogent-issues-detail--issue)))

(defun ogent-issues-detail-close ()
  "Close the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let* ((id (plist-get issue :id))
           (reason (read-string (format "Close %s with reason: " id))))
      (when (yes-or-no-p (format "Close issue %s? " id))
        (ogent-issues-bd-close id reason
                               (lambda ()
                                 (message "Closed: %s" id)
                                 (ogent-issues-detail-refresh))
                               (lambda (err)
                                 (message "Failed to close: %s" err)))))))

(defun ogent-issues-detail-reopen ()
  "Reopen the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let ((id (plist-get issue :id)))
      (ogent-issues-bd-reopen id
                              (lambda ()
                                (message "Reopened: %s" id)
                                (ogent-issues-detail-refresh))
                              (lambda (err)
                                (message "Failed to reopen: %s" err))))))

(defun ogent-issues-detail-start ()
  "Start working on the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let ((id (plist-get issue :id)))
      (ogent-issues-bd-start id
                             (lambda ()
                               (message "Started: %s" id)
                               (ogent-issues-detail-refresh))
                             (lambda (err)
                               (message "Failed to start: %s" err))))))

(defun ogent-issues-detail-comment ()
  "Add a comment to the issue being viewed."
  (interactive)
  (when-let ((issue ogent-issues-detail--issue))
    (let* ((id (plist-get issue :id))
           (text (read-string (format "Comment on %s: " id))))
      (when (string-empty-p text)
        (user-error "Comment cannot be empty"))
      (ogent-issues-bd-comment id text
                               (lambda ()
                                 (message "Comment added to %s" id)
                                 (ogent-issues-detail-refresh))
                               (lambda (err)
                                 (message "Failed to comment: %s" err))))))

(defun ogent-issues-detail-follow-link ()
  "Follow the issue link at point."
  (interactive)
  (if-let ((id (get-text-property (point) 'ogent-issue-id)))
      (ogent-issues-bd-get id
                           #'ogent-issues--render-detail
                           (lambda (err)
                             (message "Could not fetch issue %s: %s" id err)))
    (user-error "No issue link at point")))

(defun ogent-issues-detail-help ()
  "Show help for detail view."
  (interactive)
  (message "q:quit g:refresh s:start K:close r:reopen C:comment RET:follow-link"))

;;; Refresh

(defun ogent-issues--render-buffer (buf)
  "Re-render the issues buffer BUF from cached data."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (condition-case err
            (progn
              (ogent-issues--insert-buffer-contents ogent-issues--issues)
              (ogent-issues--restore-position))
          (error
           (insert (propertize
                    (format "\n  Error rendering issues: %s\n\n"
                            (error-message-string err))
                    'face 'error))
           (insert "  Press 'g' to retry refresh.\n")))))))

(defun ogent-issues-refresh (&optional _ignore-auto _noconfirm)
  "Refresh the issues buffer."
  (interactive)
  ;; Save position
  (setq ogent-issues--last-position
        (when-let ((issue (ogent-issues--current-issue)))
          (plist-get issue :id)))
  ;; Capture buffer for async callback
  (let ((buf (current-buffer)))
    ;; Start loading animation
    (ogent-issues--start-loading)
    ;; Fire gastown agent assignment fetch in parallel (if integration active)
    (when (and (fboundp 'ogent-gastown-integration-active-p)
               (ogent-gastown-integration-active-p))
      (ogent-gastown-fetch-agent-assignments
       (lambda (assignments)
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (setq ogent-issues--agent-assignments assignments)
             ;; Re-render if issues are already loaded
             (when ogent-issues--issues
               (ogent-issues--render-buffer buf)))))))
    ;; Fetch and render issues
    (ogent-issues-bd-list
     (lambda (issues)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           ;; Stop loading animation
           (ogent-issues--stop-loading)
           (setq ogent-issues--issues (ogent-issues--apply-filters issues))
           (ogent-issues--render-buffer buf))))
     ogent-issues--filters
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-issues--stop-loading)))
       (message "Failed to refresh: %s" err)))))

(defun ogent-issues-refresh-force ()
  "Force refresh, clearing cache."
  (interactive)
  (ogent-issues-bd-cache-invalidate)
  (ogent-issues-refresh))

(defun ogent-issues--restore-position ()
  "Restore cursor to last known position."
  (goto-char (point-min))
  (when ogent-issues--last-position
    (let ((found nil)
          (prev-pos nil))
      (while (let ((cur-pos (point)))
               (and (not found)
                    (not (eobp))
                    (not (eq cur-pos prev-pos))
                    (setq prev-pos cur-pos)))
        (if (equal (ogent-issues--current-issue-id) ogent-issues--last-position)
            (setq found t)
          (condition-case nil
              (ogent-issues-next-issue)
            (user-error nil))))
      (unless found
        (goto-char (point-min))
        (condition-case nil
            (ogent-issues-next-issue)
          (user-error nil))))))

;;; Filtering

(defun ogent-issues--apply-filters (issues)
  "Apply current filters to ISSUES."
  (if (null ogent-issues--filters)
      issues
    (seq-filter
     (lambda (issue)
       (and (or (null (plist-get ogent-issues--filters :status))
                (string= (plist-get issue :status)
                         (plist-get ogent-issues--filters :status)))
            (or (null (plist-get ogent-issues--filters :type))
                (string= (plist-get issue :issue_type)
                         (plist-get ogent-issues--filters :type)))
            (or (null (plist-get ogent-issues--filters :priority))
                (= (or (plist-get issue :priority) 2)
                   (plist-get ogent-issues--filters :priority)))))
     issues)))

(defun ogent-issues-filter-status (status)
  "Filter issues by STATUS."
  (interactive
   (list (completing-read "Status: "
                          '("open" "in_progress" "blocked" "closed")
                          nil t)))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :status status))
  (ogent-issues-refresh))

(defun ogent-issues-filter-type (type)
  "Filter issues by TYPE."
  (interactive
   (list (completing-read "Type: "
                          '("bug" "feature" "task" "epic" "chore")
                          nil t)))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :type type))
  (ogent-issues-refresh))

(defun ogent-issues-filter-priority (priority)
  "Filter issues by PRIORITY."
  (interactive
   (list (string-to-number
          (completing-read "Priority: " '("0" "1" "2" "3") nil t))))
  (setq ogent-issues--filters
        (plist-put ogent-issues--filters :priority priority))
  (ogent-issues-refresh))

(defun ogent-issues-clear-filters ()
  "Clear all filters."
  (interactive)
  (setq ogent-issues--filters nil)
  (ogent-issues-refresh))

;; ogent-issues-filter-dispatch is autoloaded from ogent-issues-transient.el

;;; Actions

(defun ogent-issues-create ()
  "Create a new issue."
  (interactive)
  (if (fboundp 'ogent-issues-create-dispatch)
      (call-interactively 'ogent-issues-create-dispatch)
    (let* ((title (read-string "Issue title: "))
           (type (completing-read "Type: " '("task" "bug" "feature" "chore" "epic") nil t "task"))
           (priority (string-to-number (completing-read "Priority: " '("0" "1" "2" "3") nil t "2"))))
      (when (string-empty-p title)
        (user-error "Title cannot be empty"))
      (ogent-issues-bd-create title
                              (lambda (result)
                                (message "Created: %s" (plist-get result :id))
                                (ogent-issues-refresh))
                              :type type
                              :priority priority))))

(defun ogent-issues-close ()
  "Close the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let* ((id (plist-get issue :id))
             (reason (read-string (format "Close %s with reason: " id))))
        (when (yes-or-no-p (format "Close issue %s? " id))
          (ogent-issues-bd-close id reason
                                 (lambda ()
                                   (message "Closed: %s" id)
                                   (ogent-issues-refresh))
                                 (lambda (err)
                                   (message "Failed to close: %s" err)))))
    (user-error "No issue at point")))

(defun ogent-issues-reopen ()
  "Reopen the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let ((id (plist-get issue :id)))
        (ogent-issues-bd-reopen id
                                (lambda ()
                                  (message "Reopened: %s" id)
                                  (ogent-issues-refresh))
                                (lambda (err)
                                  (message "Failed to reopen: %s" err))))
    (user-error "No issue at point")))

(defun ogent-issues-start ()
  "Start working on the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let ((id (plist-get issue :id)))
        (ogent-issues-bd-start id
                               (lambda ()
                                 (message "Started: %s" id)
                                 (ogent-issues-refresh))
                               (lambda (err)
                                 (message "Failed to start: %s" err))))
    (user-error "No issue at point")))

(defun ogent-issues-comment ()
  "Add a comment to the issue at point."
  (interactive)
  (if-let ((issue (ogent-issues--current-issue)))
      (let* ((id (plist-get issue :id))
             (text (read-string (format "Comment on %s: " id))))
        (when (string-empty-p text)
          (user-error "Comment cannot be empty"))
        (ogent-issues-bd-comment id text
                                 (lambda ()
                                   (message "Comment added to %s" id)
                                   (ogent-issues-refresh))
                                 (lambda (err)
                                   (message "Failed to comment: %s" err))))
    (user-error "No issue at point")))

(defun ogent-issues-sync ()
  "Sync issues to git."
  (interactive)
  (ogent-issues-bd-sync
   (lambda ()
     (message "Synced to git")
     (ogent-issues-refresh))
   (lambda (err)
     (message "Failed to sync: %s" err))))

;;; Views

(defun ogent-issues-view-list ()
  "Switch to list view."
  (interactive)
  (setq ogent-issues--current-view 'list)
  (ogent-issues-refresh))

(defun ogent-issues-view-ready ()
  "Switch to ready work view."
  (interactive)
  (setq ogent-issues--current-view 'ready)
  (let ((buf (current-buffer)))
    (ogent-issues--start-loading)
    (ogent-issues-bd-ready
     (lambda (issues)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-issues--stop-loading)
           (setq ogent-issues--issues issues)
           (let ((inhibit-read-only t))
             (erase-buffer)
             (if issues
                 (progn
                   (insert (propertize "Ready Work" 'face 'ogent-issues-section-heading))
                   (insert "\n")
                   (insert (propertize "Issues with no blockers, sorted by priority\n\n"
                                       'face 'ogent-issues-dimmed))
                   (if ogent-issues--magit-section-available
                       (magit-insert-section (ogent-issues-root-section)
					     (dolist (issue (seq-sort-by (lambda (i) (or (plist-get i :priority) 2)) #'< issues))
					       (ogent-issues--insert-issue issue)))
                     (dolist (issue (seq-sort-by (lambda (i) (or (plist-get i :priority) 2)) #'< issues))
                       (insert (ogent-issues--format-issue-line issue) "\n"))))
               (insert (propertize "Ready Work" 'face 'ogent-issues-section-heading))
               (insert "\n\n")
               (insert (propertize "  No ready work!\n\n" 'face 'ogent-issues-dimmed))
               (insert (propertize "  All issues are either blocked, closed, or in progress.\n"
                                   'face 'ogent-issues-dimmed)))
             (goto-char (point-min))))))
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-issues--stop-loading)))
       (message "Failed to fetch ready work: %s" err)))))

;;; Kanban View

(defconst ogent-issues-kanban-columns
  '(("in_progress" . "In Progress")
    ("open" . "Open")
    ("blocked" . "Blocked")
    ("closed" . "Closed"))
  "Kanban column definitions in display order.")

(defvar-local ogent-issues-kanban--column-width 20
  "Width of each Kanban column.")

(defun ogent-issues-view-kanban ()
  "Switch to Kanban board view."
  (interactive)
  (setq ogent-issues--current-view 'kanban)
  (let ((buf (current-buffer)))
    (ogent-issues--start-loading)
    (ogent-issues-bd-list
     (lambda (issues)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-issues--stop-loading)
           (setq ogent-issues--issues issues)
           (let ((inhibit-read-only t))
             (erase-buffer)
             (ogent-issues--insert-kanban-board issues)
             (goto-char (point-min))))))
     nil  ; no filters
     (lambda (err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (ogent-issues--stop-loading)))
       (message "Failed to fetch issues for Kanban: %s" err)))))

(defun ogent-issues--kanban-column-width ()
  "Calculate column width based on window width."
  (let* ((num-cols (length ogent-issues-kanban-columns))
         (separators (1+ num-cols))  ; │ between and at edges
         (available (- (window-width) separators)))
    (max 15 (/ available num-cols))))

(defun ogent-issues--insert-kanban-board (issues)
  "Insert Kanban board with ISSUES."
  (let* ((col-width (ogent-issues--kanban-column-width))
         (grouped (ogent-issues--group-by-status issues))
         (max-rows (ogent-issues--kanban-max-rows grouped)))
    (setq-local ogent-issues-kanban--column-width col-width)
    ;; Header
    (insert (propertize "Kanban Board" 'face 'ogent-issues-section-heading))
    (insert "  ")
    (insert (propertize "h/l: move issue left/right  q: quit" 'face 'ogent-issues-dimmed))
    (insert "\n\n")
    ;; Column headers
    (ogent-issues--insert-kanban-headers col-width grouped)
    ;; Separator
    (ogent-issues--insert-kanban-separator col-width)
    ;; Issue rows
    (if (zerop max-rows)
        (progn
          (insert "│")
          (dolist (_col ogent-issues-kanban-columns)
            (insert (ogent-issues--kanban-pad "No issues" col-width))
            (insert "│"))
          (insert "\n"))
      (dotimes (row max-rows)
        (insert "│")
        (dolist (col-def ogent-issues-kanban-columns)
          (let* ((status (car col-def))
                 (issues-in-col (cdr (assoc status grouped))))
            (if (< row (length issues-in-col))
                (ogent-issues--insert-kanban-card (nth row issues-in-col) col-width)
              (insert (make-string col-width ?\s)))
            (insert "│")))
        (insert "\n")))
    ;; Bottom border
    (ogent-issues--insert-kanban-separator col-width)))

(defun ogent-issues--insert-kanban-headers (col-width grouped)
  "Insert Kanban column headers with COL-WIDTH and issue counts from GROUPED."
  (insert "┌")
  (dotimes (i (length ogent-issues-kanban-columns))
    (insert (make-string col-width ?─))
    (if (< i (1- (length ogent-issues-kanban-columns)))
        (insert "┬")
      (insert "┐")))
  (insert "\n│")
  (dolist (col-def ogent-issues-kanban-columns)
    (let* ((status (car col-def))
           (label (cdr col-def))
           (count (length (cdr (assoc status grouped))))
           (header (format "%s (%d)" label count))
           (padded (ogent-issues--kanban-pad header col-width)))
      (insert (propertize padded 'face 'ogent-issues-section-heading))
      (insert "│")))
  (insert "\n"))

(defun ogent-issues--insert-kanban-separator (col-width)
  "Insert horizontal separator for Kanban board."
  (insert "├")
  (dotimes (i (length ogent-issues-kanban-columns))
    (insert (make-string col-width ?─))
    (if (< i (1- (length ogent-issues-kanban-columns)))
        (insert "┼")
      (insert "┤")))
  (insert "\n"))

(defun ogent-issues--insert-kanban-card (issue col-width)
  "Insert ISSUE as a Kanban card with COL-WIDTH."
  (let* ((id (plist-get issue :id))
         (title (plist-get issue :title))
         (priority (or (plist-get issue :priority) 2))
         (status (plist-get issue :status))
         (priority-str (if ogent-issues-use-unicode
                           (pcase priority
                             (0 "●")
                             (1 "◐")
                             (2 "○")
                             (_ "◌"))
                         (format "P%d" priority)))
         ;; Reserve space for: priority + space + id + space + title
         (available (- col-width (length priority-str) 1 (length id) 1))
         (truncated-title (truncate-string-to-width (or title "") (max 1 available) nil nil "…"))
         (card-text (concat priority-str " " id " " truncated-title))
         (padded (ogent-issues--kanban-pad card-text col-width)))
    (insert (propertize padded
                        'ogent-issue-id id
                        'ogent-issue issue
                        'face (ogent-issues--status-face status)))))

(defun ogent-issues--kanban-pad (str width)
  "Pad STR to WIDTH, centering if shorter."
  (let ((len (length str)))
    (if (>= len width)
        (truncate-string-to-width str width nil nil "…")
      (let* ((padding (- width len))
             (left-pad (/ padding 2))
             (right-pad (- padding left-pad)))
        (concat (make-string left-pad ?\s) str (make-string right-pad ?\s))))))

(defun ogent-issues--kanban-max-rows (grouped)
  "Return max number of issues in any column from GROUPED."
  (let ((max-count 0))
    (dolist (col-def ogent-issues-kanban-columns)
      (let ((count (length (cdr (assoc (car col-def) grouped)))))
        (when (> count max-count)
          (setq max-count count))))
    max-count))

(defun ogent-issues-kanban-move-left ()
  "Move issue at point to previous status column."
  (interactive)
  (ogent-issues--kanban-move-issue -1))

(defun ogent-issues-kanban-move-right ()
  "Move issue at point to next status column."
  (interactive)
  (ogent-issues--kanban-move-issue 1))

(defun ogent-issues--kanban-move-issue (direction)
  "Move current issue by DIRECTION (-1 or 1) in status."
  (let* ((issue (ogent-issues--current-issue))
         (id (when issue (plist-get issue :id)))
         (current-status (when issue (plist-get issue :status)))
         (statuses (mapcar #'car ogent-issues-kanban-columns))
         (current-idx (when current-status
                        (cl-position current-status statuses :test #'string=)))
         (new-idx (when current-idx (+ current-idx direction)))
         (new-status (when (and new-idx (>= new-idx 0) (< new-idx (length statuses)))
                       (nth new-idx statuses))))
    (cond
     ((not issue)
      (message "No issue at point"))
     ((not new-status)
      (message "Cannot move %s further %s" id (if (< direction 0) "left" "right")))
     ((string= current-status new-status)
      (message "Issue already in %s" new-status))
     (t
      ;; Use bd CLI to update status
      (ogent-issues-bd-update id
			      (lambda ()
				(message "Moved %s to %s" id new-status)
				(ogent-issues-refresh))
			      :status new-status)))))

(defun ogent-issues--ensure-sibling-loadpath ()
  "Ensure the directory containing ogent-issues sibling files is in `load-path'.
This guards against load-path modifications after initial load."
  (when (and ogent-issues--source-directory
             (not (member ogent-issues--source-directory load-path)))
    (add-to-list 'load-path ogent-issues--source-directory)))

(defun ogent-issues-view-deps ()
  "Switch to dependency graph view."
  (interactive)
  (ogent-issues--ensure-sibling-loadpath)
  (require 'ogent-issues-graph)
  (if-let ((id (ogent-issues--current-issue-id)))
      (ogent-issues-graph-view id)
    (ogent-issues-graph-view)))

(defun ogent-issues-view-deps-current ()
  "View dependency graph centered on current issue."
  (interactive)
  (ogent-issues--ensure-sibling-loadpath)
  (require 'ogent-issues-graph)
  (if-let ((id (ogent-issues--current-issue-id)))
      (ogent-issues-graph-view id)
    (user-error "No issue at point")))

;;; Evil Integration
;; When evil is loaded, set up proper evil keybindings.
;; j/k are NOT bound in the mode map so evil users get normal line movement.
;; Use n/p for issue-to-issue navigation, gj/gk for section navigation.
;; This section must be at the end of the file, after all keymaps are defined.

;; Declare evil functions to avoid byte-compile warnings
(declare-function evil-set-initial-state "ext:evil-core")
(declare-function evil-make-overriding-map "ext:evil-core")
(declare-function evil-normalize-keymaps "ext:evil-core")

(defun ogent-issues--setup-evil ()
  "Set up evil keybindings for ogent-issues modes.
Called after evil is loaded."
  (when (fboundp 'evil-set-initial-state)
    ;; Set initial state to normal for ogent-issues modes
    (evil-set-initial-state 'ogent-issues-mode 'normal)
    (evil-set-initial-state 'ogent-issues-detail-mode 'normal)
    
    ;; Make our keymaps override evil's state maps for non-movement keys.
    ;; j/k are intentionally NOT in the mode map so evil handles them.
    (evil-make-overriding-map ogent-issues-mode-map 'all)
    (evil-make-overriding-map ogent-issues-detail-mode-map 'all)
    
    ;; Add evil-specific navigation using define-key on evil's state maps
    ;; This avoids the evil-define-key macro which causes load-order issues
    (when (boundp 'evil-normal-state-local-map)
      (add-hook 'ogent-issues-mode-hook
                (lambda ()
                  (evil-local-set-key 'normal "gg" #'evil-goto-first-line)
                  (evil-local-set-key 'normal "G" #'evil-goto-line)
                  (evil-local-set-key 'normal "gr" #'ogent-issues-refresh)
                  (evil-local-set-key 'normal "gR" #'ogent-issues-refresh-force)
                  (evil-local-set-key 'normal "gj" #'ogent-issues-next-section)
                  (evil-local-set-key 'normal "gk" #'ogent-issues-prev-section)
                  (evil-local-set-key 'normal "ZZ" #'quit-window)
                  (evil-local-set-key 'normal "ZQ" #'quit-window)))
      (add-hook 'ogent-issues-detail-mode-hook
                (lambda ()
                  (evil-local-set-key 'normal "gg" #'evil-goto-first-line)
                  (evil-local-set-key 'normal "G" #'evil-goto-line)
                  (evil-local-set-key 'normal "gr" #'ogent-issues-detail-refresh)
                  (evil-local-set-key 'normal "ZZ" #'quit-window)
                  (evil-local-set-key 'normal "ZQ" #'quit-window))))
    
    ;; Normalize keymaps when entering these modes
    (add-hook 'ogent-issues-mode-hook #'evil-normalize-keymaps)
    (add-hook 'ogent-issues-detail-mode-hook #'evil-normalize-keymaps)))

(with-eval-after-load 'evil
  (ogent-issues--setup-evil))

(provide 'ogent-issues)

;;; ogent-issues.el ends here
