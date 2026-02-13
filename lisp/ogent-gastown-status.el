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
(require 'iso8601)
(require 'ogent-ops-style)

;; Soft dependency on magit-section
(defvar ogent-gastown--magit-section-available
  (require 'magit-section nil t)
  "Non-nil if magit-section is available.")

(defun ogent-gastown--magit-usable-p ()
  "Return non-nil when magit-section APIs are available for this session."
  (and ogent-gastown--magit-section-available
       (fboundp 'magit-section-mode)
       (fboundp 'magit-insert-section)
       (fboundp 'magit-insert-heading)))

(defun ogent-gastown--refresh-magit-availability ()
  "Refresh magit-section availability from current load-path."
  (setq ogent-gastown--magit-section-available
        (or ogent-gastown--magit-section-available
            (require 'magit-section nil t)))
  (when (and ogent-gastown--magit-section-available
             (not (featurep 'magit-section)))
    (require 'magit-section))
  (when (ogent-gastown--magit-usable-p)
    (ogent-gastown--define-magit-section-classes))
  (ogent-gastown--magit-usable-p))

;; Load transient help menu if available
(declare-function ogent-gastown-status-dispatch "ogent-gastown-status-transient" nil t)
(autoload 'ogent-gastown-status-dispatch "ogent-gastown-status-transient" nil t)

;; Load ogent-issues for rig → issues navigation
(autoload 'ogent-issues "ogent-issues" nil t)
(autoload 'ogent-issues-bd-get "ogent-issues-bd" nil nil)
(autoload 'ogent-issues-bd-list "ogent-issues-bd" nil nil)
(autoload 'ogent-issues-bd-create "ogent-issues-bd" nil nil)
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

(defcustom ogent-gastown-auto-refresh-interval 30
  "Interval in seconds between automatic refreshes.
Only effective when `ogent-gastown-auto-refresh-mode' is active."
  :type 'integer
  :group 'ogent-gastown)

(defcustom ogent-gastown-auto-refresh-highlight-duration 5
  "Duration in seconds for the change highlight overlay."
  :type 'number
  :group 'ogent-gastown)

(defcustom ogent-gastown-workspace-display-width 36
  "Maximum width for workspace path display in the status header."
  :type 'integer
  :group 'ogent-gastown)

(defcustom ogent-gastown-section-heading-face-overrides nil
  "Optional per-section heading face overrides.
When non-nil, this should be an alist of (SECTION . FACE), where SECTION is
one of `hook', `mail', `convoy', `workers', `stats', `deacon',
`witnesses', `crew', `polecats', `rigs', or `issues'. FACE must name an existing face.
Invalid face symbols are ignored and default faces are used."
  :type '(alist :key-type (choice (const hook)
                                  (const mail)
                                  (const convoy)
                                  (const workers)
                                  (const stats)
                                  (const deacon)
                                  (const witnesses)
                                  (const crew)
                                  (const polecats)
                                  (const rigs)
                                  (const issues))
                :value-type face)
  :group 'ogent-gastown)

;;; Faces

(defgroup ogent-gastown-faces nil
  "Faces for ogent-gastown."
  :group 'ogent-gastown
  :group 'faces)

(defface ogent-gastown-section-heading
  '((((class color) (background light))
     :foreground "#37474f" :background "#eceff1" :weight bold :extend t)
    (((class color) (background dark))
     :foreground "#eceff4" :background "#3b4252" :weight bold :extend t)
    (t :weight bold))
  "Base face for section headings."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-hook
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#4527a0" :background "#ede7f6")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#b48ead" :background "#3a2f4a")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Hook section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-mail
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#0d47a1" :background "#e3f2fd")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#88c0d0" :background "#2a3f5f")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Mail section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-convoy
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#6a1b9a" :background "#f3e5f5")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#b48ead" :background "#4a345a")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Convoys section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-workers
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#1b5e20" :background "#e8f5e9")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#a3be8c" :background "#2f4f3e")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Workers section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-stats
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#1e3a8a" :background "#dbeafe")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#88c0d0" :background "#243447")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Town Stats section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-deacon
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#1b5e20" :background "#e8f5e9")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#a3be8c" :background "#2f4f3e")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Deacon section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-witnesses
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#bf360c" :background "#fff3e0")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#d08770" :background "#4b3b2e")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Witnesses section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-crew
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#1a237e" :background "#e8f0fe")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#81a1c1" :background "#33415e")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Crew section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-polecats
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#bf360c" :background "#fbe9e7")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#d08770" :background "#5a3a34")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Polecats section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-rigs
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#37474f" :background "#f5f5f5")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#d8dee9" :background "#434c5e")
    (t :inherit ogent-gastown-section-heading))
  "Face for the Rigs section heading."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-section-heading-issues
  '((((class color) (background light))
     :inherit ogent-gastown-section-heading
     :foreground "#4e342e" :background "#efebe9")
    (((class color) (background dark))
     :inherit ogent-gastown-section-heading
     :foreground "#ebcb8b" :background "#4b3f33")
    (t :inherit ogent-gastown-section-heading))
  "Face for per-rig issues detail headings."
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

(defface ogent-gastown-fetch-error
  '((((class color) (background light)) :foreground "#c62828")
    (((class color) (background dark)) :foreground "#bf616a"))
  "Face for fetch error messages in sections."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-header-line-key
  '((((class color) (background light))
     :background "grey90" :foreground "#5e35b1" :weight bold)
    (((class color) (background dark))
     :background "#2e3440" :foreground "#b48ead" :weight bold))
  "Face for keybindings in header line."
  :group 'ogent-gastown-faces)

(defface ogent-gastown-changed
  '((((class color) (background light))
     :background "#fff8e1")
    (((class color) (background dark))
     :background "#4a3c00"))
  "Transient highlight for recently-changed items.
Applied as an overlay that fades after
`ogent-gastown-auto-refresh-highlight-duration' seconds."
  :group 'ogent-gastown-faces)

(defun ogent-gastown--section-heading-face (section)
  "Return heading face for SECTION."
  (let ((default-face
          (pcase section
            ('hook 'ogent-gastown-section-heading-hook)
            ('mail 'ogent-gastown-section-heading-mail)
            ('convoy 'ogent-gastown-section-heading-convoy)
            ('workers 'ogent-gastown-section-heading-workers)
            ('stats 'ogent-gastown-section-heading-stats)
            ('deacon 'ogent-gastown-section-heading-deacon)
            ('witnesses 'ogent-gastown-section-heading-witnesses)
            ('crew 'ogent-gastown-section-heading-crew)
            ('polecats 'ogent-gastown-section-heading-polecats)
            ('rigs 'ogent-gastown-section-heading-rigs)
            ('issues 'ogent-gastown-section-heading-issues)
            (_ 'ogent-gastown-section-heading))))
    (if-let ((override (alist-get section ogent-gastown-section-heading-face-overrides)))
        (if (facep override) override default-face)
      default-face)))

(defun ogent-gastown--section-heading (section label)
  "Return LABEL propertized for SECTION heading."
  (propertize label 'face (ogent-gastown--section-heading-face section)))

(defun ogent-gastown--plain-section-prefix (section)
  "Return plain-mode prefix symbol for SECTION."
  (pcase section
    ('hook "#")
    ('mail "@")
    ('convoy ">")
    ('workers "*")
    ('stats "#")
    ('deacon "D")
    ('witnesses "W")
    ('crew "C")
    ('polecats "P")
    ('rigs "R")
    ('issues "I")
    (_ "?")))

(defun ogent-gastown--compose-section-heading (section title &rest suffixes)
  "Compose a Magit section heading for SECTION using TITLE and SUFFIXES."
  (let* ((ogent-ops-use-unicode ogent-gastown-use-unicode)
         (heading-face (ogent-gastown--section-heading-face section))
         (heading
          (concat (ogent-ops-section-symbol section)
                  " "
                  (ogent-gastown--section-heading section title)
                  (apply #'concat (delq nil suffixes)))))
    ;; Keep one background treatment across the full heading line while
    ;; preserving any suffix-specific faces (e.g., dimmed counters).
    (add-face-text-property 0 (length heading) heading-face 'append heading)
    heading))

(defun ogent-gastown--compose-plain-section-heading (section title &optional suffix)
  "Compose a plain-mode heading line for SECTION and TITLE with SUFFIX."
  (concat (ogent-gastown--plain-section-prefix section)
          " "
          title
          (or suffix "")
          "\n"))

;;; Buffer-local State

(defvar-local ogent-gastown--hook-data nil
  "Cached hook status data.")

(defvar-local ogent-gastown--hook-loading nil
  "Non-nil while hook data is loading.")

(defvar-local ogent-gastown--mail-data nil
  "Cached mail inbox data.")

(defvar-local ogent-gastown--mail-loading nil
  "Non-nil while mail data is loading.")

(defvar-local ogent-gastown--convoy-data nil
  "Cached convoy list data (normalized).")

(defvar-local ogent-gastown--convoy-loading nil
  "Non-nil while convoy data is loading.")

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

;;; Crew / Polecat / Worker Normalization
;;
;; Real `gt` command output uses field names that differ from the
;; canonical keys assumed by the rendering code.  These helpers map
;; incoming payloads to the internal schema at the fetch boundary so
;; render functions never need to know about transport variants.

(defun ogent-gastown--normalize-crew-member (member)
  "Normalize crew MEMBER plist to canonical keys.
Accepts both real gt output (:has_session, :git_clean) and the
canonical internal keys (:session_running, :dirty).  Returns a plist
with canonical keys: :name, :rig, :branch, :session_running, :dirty,
:hooked_work, :unread_mail."
  (when member
    (let ((name (plist-get member :name))
          (rig (plist-get member :rig))
          (branch (plist-get member :branch))
          ;; session: accept :session_running or :has_session
          (running (if (plist-member member :session_running)
                       (plist-get member :session_running)
                     (plist-get member :has_session)))
          ;; dirty: accept :dirty or invert :git_clean
          (dirty (if (plist-member member :dirty)
                     (plist-get member :dirty)
                   (when (plist-member member :git_clean)
                     (not (plist-get member :git_clean)))))
          (hooked-work (plist-get member :hooked_work))
          (unread-mail (or (plist-get member :unread_mail) 0)))
      (list :name name
            :rig rig
            :branch branch
            :session_running running
            :dirty dirty
            :hooked_work hooked-work
            :unread_mail unread-mail))))

(defun ogent-gastown--normalize-crew-list (crew)
  "Normalize a list of CREW members to canonical shape."
  (delq nil (mapcar #'ogent-gastown--normalize-crew-member crew)))

(defun ogent-gastown--normalize-polecat (polecat)
  "Normalize POLECAT plist to canonical keys.
Accepts both real gt output (:running, :hook_bead, :has_work,
:work_title) and canonical keys (:session_running, :current_task,
:hooked_work).  Returns a plist with canonical keys: :name, :rig,
:state, :session_running, :current_task, :hooked_work,
:session_started."
  (when polecat
    (let ((name (plist-get polecat :name))
          (rig (plist-get polecat :rig))
          (state (plist-get polecat :state))
          ;; session: accept :session_running or :running
          (running (if (plist-member polecat :session_running)
                       (plist-get polecat :session_running)
                     (plist-get polecat :running)))
          ;; task: accept :current_task, :hooked_work, or :hook_bead
          (task (or (plist-get polecat :current_task)
                    (plist-get polecat :hooked_work)
                    (plist-get polecat :hook_bead)))
          (hooked-work (or (plist-get polecat :hooked_work)
                           (plist-get polecat :hook_bead)))
          (started (plist-get polecat :session_started)))
      (list :name name
            :rig rig
            :state state
            :session_running running
            :current_task task
            :hooked_work hooked-work
            :session_started started))))

(defun ogent-gastown--normalize-polecat-list (polecats)
  "Normalize a list of POLECATS to canonical shape."
  (delq nil (mapcar #'ogent-gastown--normalize-polecat polecats)))

(defun ogent-gastown--normalize-worker (worker)
  "Normalize WORKER plist to canonical keys.
Accepts both real gt output (:running) and canonical keys
\(:session_running).  Returns a plist with canonical keys:
:name, :rig, :state, :session_running."
  (when worker
    (let ((name (plist-get worker :name))
          (rig (plist-get worker :rig))
          (state (plist-get worker :state))
          ;; session: accept :session_running or :running
          (running (if (plist-member worker :session_running)
                       (plist-get worker :session_running)
                     (plist-get worker :running))))
      (list :name name
            :rig rig
            :state state
            :session_running running))))

(defun ogent-gastown--normalize-worker-list (workers)
  "Normalize a list of WORKERS to canonical shape."
  (delq nil (mapcar #'ogent-gastown--normalize-worker workers)))

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

(defvar-local ogent-gastown--issues-data nil
  "Cached issues list data, keyed by rig name.
An alist of (RIG-NAME . ISSUES-LIST) where each issue is a plist.")

(defvar-local ogent-gastown--selected-rig nil
  "Rig name currently selected for rig-scoped detail sections.")

(defvar-local ogent-gastown--fetch-errors (make-hash-table :test 'eq)
  "Hash table mapping section keys to error messages.
Keys are symbols like `hook', `mail', `convoy', `workers', `town-status',
`crew', `polecat'.  Values are error message strings, or absent if no error.")

(defvar-local ogent-gastown--loading nil
  "Non-nil when a gt command is in progress.")

(defvar-local ogent-gastown--loading-timer nil
  "Timer for animating the loading spinner.")

(defvar-local ogent-gastown--loading-frame 0
  "Current animation frame index.")

(defvar-local ogent-gastown--auto-refresh-timer nil
  "Timer for auto-refresh mode.")

(defvar-local ogent-gastown--auto-refresh-snapshot nil
  "Snapshot of key data taken before an auto-refresh.
Used to detect changes and highlight them.")

(defvar-local ogent-gastown--auto-refresh-first-load t
  "Non-nil on the first auto-refresh load.
Suppresses highlighting so the entire buffer doesn't light up.")

(defvar-local ogent-gastown--change-overlays nil
  "List of active change-highlight overlays managed by auto-refresh.")

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

(defun ogent-gastown--run-async-cached (args callback &optional error-callback raw-output)
  "Run gt with ARGS asynchronously and cache JSON responses.
CALLBACK receives the parsed result.  ERROR-CALLBACK is invoked on failure.
When RAW-OUTPUT is non-nil, skip caching and return raw output."
  (if raw-output
      (ogent-gastown-status--run-async args callback error-callback raw-output)
    (let ((cached (ogent-gastown--cache-get args)))
      (if cached
          (funcall callback cached)
        (ogent-gastown-status--run-async
         args
         (lambda (result)
           (ogent-gastown--cache-set args result)
           (funcall callback result))
         error-callback)))))

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

(defun ogent-gastown--define-magit-section-classes ()
  "Define EIEIO section classes used by magit-section rendering."
  (when (ogent-gastown--magit-usable-p)
    (unless (fboundp 'ogent-gastown-root-section)
      (defclass ogent-gastown-root-section (magit-section) ()
        "Root section for Gas Town status buffer."))
    (unless (fboundp 'ogent-gastown-hook-section)
      (defclass ogent-gastown-hook-section (magit-section) ()
        "Section for hook status."))
    (unless (fboundp 'ogent-gastown-mail-section)
      (defclass ogent-gastown-mail-section (magit-section) ()
        "Section for mail inbox."))
    (unless (fboundp 'ogent-gastown-mail-item-section)
      (defclass ogent-gastown-mail-item-section (magit-section) ()
        "Section for a single mail message."))
    (unless (fboundp 'ogent-gastown-convoy-section)
      (defclass ogent-gastown-convoy-section (magit-section) ()
        "Section for convoy status."))
    (unless (fboundp 'ogent-gastown-convoy-item-section)
      (defclass ogent-gastown-convoy-item-section (magit-section) ()
        "Section for a single convoy."))
    (unless (fboundp 'ogent-gastown-workers-section)
      (defclass ogent-gastown-workers-section (magit-section) ()
        "Section for workers overview."))
    (unless (fboundp 'ogent-gastown-worker-section)
      (defclass ogent-gastown-worker-section (magit-section) ()
        "Section for a single worker."))
    (unless (fboundp 'ogent-gastown-stats-section)
      (defclass ogent-gastown-stats-section (magit-section) ()
        "Section for town statistics."))
    (unless (fboundp 'ogent-gastown-deacon-section)
      (defclass ogent-gastown-deacon-section (magit-section) ()
        "Section for deacon status."))
    (unless (fboundp 'ogent-gastown-witness-section)
      (defclass ogent-gastown-witness-section (magit-section) ()
        "Section for witness status overview."))
    (unless (fboundp 'ogent-gastown-witness-item-section)
      (defclass ogent-gastown-witness-item-section (magit-section) ()
        "Section for a single rig witness."))
    (unless (fboundp 'ogent-gastown-crew-section)
      (defclass ogent-gastown-crew-section (magit-section) ()
        "Section for crew members."))
    (unless (fboundp 'ogent-gastown-crew-item-section)
      (defclass ogent-gastown-crew-item-section (magit-section) ()
        "Section for a single crew member."))
    (unless (fboundp 'ogent-gastown-polecat-section)
      (defclass ogent-gastown-polecat-section (magit-section) ()
        "Section for polecats."))
    (unless (fboundp 'ogent-gastown-polecat-item-section)
      (defclass ogent-gastown-polecat-item-section (magit-section) ()
        "Section for a single polecat."))
    (unless (fboundp 'ogent-gastown-rigs-section)
      (defclass ogent-gastown-rigs-section (magit-section) ()
        "Section for rigs overview."))
    (unless (fboundp 'ogent-gastown-rig-item-section)
      (defclass ogent-gastown-rig-item-section (magit-section) ()
        "Section for a single rig."))
    (unless (fboundp 'ogent-gastown-issue-item-section)
      (defclass ogent-gastown-issue-item-section (magit-section) ()
        "Section for a single issue within a rig."))))

(ogent-gastown--define-magit-section-classes)

;;; Keymap

(defvar ogent-gastown-status-mode-map
  (let ((map (make-sparse-keymap)))
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
    (define-key map "o" #'ogent-gastown-hook-show)
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

    ;; Dispatch (sling)
    (define-key map "S" #'ogent-gastown-sling)

    ;; Rig actions
    (define-key map "H" #'ogent-gastown-cycle-rig-prev)
    (define-key map "L" #'ogent-gastown-cycle-rig-next)
    (define-key map "r" #'ogent-gastown-rig-status)
    (define-key map "f" #'ogent-gastown-refinery-status)

    ;; Issues navigation
    (define-key map "i" #'ogent-gastown-rig-issues)
    (define-key map "+" #'ogent-gastown-bead-create)

    ;; Auto-refresh toggle
    (define-key map "A" #'ogent-gastown-auto-refresh-mode)

    ;; Issue triage (context-sensitive: only act on issue-item-section)
    (define-key map "x" #'ogent-gastown-issue-close)
    (define-key map "!" #'ogent-gastown-issue-prioritize)
    (define-key map "X" #'ogent-gastown-issue-claim)
    (define-key map "b" #'ogent-gastown-issue-block)

    ;; Quit
    (define-key map "q" #'quit-window)

    map)
  "Keymap for `ogent-gastown-status-mode'.")

;;; Mode Definition

(defconst ogent-gastown--status-mode-doc
  "Major mode for viewing Gas Town status.

Like `magit-status' but for your Gas Town multi-agent workspace.

\\<ogent-gastown-status-mode-map>
Navigation:
  \\[ogent-gastown-next-item]     Move to next item
  \\[ogent-gastown-prev-item]     Move to previous item
  \\[ogent-gastown-next-section]   Move to next section
  \\[ogent-gastown-prev-section]   Move to previous section
  \\[ogent-gastown-cycle-rig-prev]   Select previous rig
  \\[ogent-gastown-cycle-rig-next]   Select next rig
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

Dispatch:
  \\[ogent-gastown-sling]     Sling work to agent

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
  \\[ogent-gastown-auto-refresh-mode]     Toggle auto-refresh mode
  \\[ogent-gastown-status-dispatch]     Show command menu
  \\[quit-window]     Quit

\\{ogent-gastown-status-mode-map}"
  "Docstring for `ogent-gastown-status-mode'.")

(defun ogent-gastown--status-mode-parent ()
  "Return the parent mode for `ogent-gastown-status-mode'."
  (if (ogent-gastown--magit-usable-p)
      'magit-section-mode
    'special-mode))

(defun ogent-gastown--status-mode-setup ()
  "Initialize local state for `ogent-gastown-status-mode'."
  (setq-local revert-buffer-function #'ogent-gastown-refresh)
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq header-line-format '(:eval (ogent-gastown--header-line)))
  (if (and (ogent-gastown--magit-usable-p)
           (boundp 'magit-section-mode-map))
      (progn
        (set-keymap-parent ogent-gastown-status-mode-map magit-section-mode-map)
        (setq-local magit-section-visibility-indicator
                    (if ogent-gastown-use-unicode
                        '("…" . t)
                      '("..." . t))))
    (set-keymap-parent ogent-gastown-status-mode-map nil)))

(defun ogent-gastown--define-status-mode ()
  "Define `ogent-gastown-status-mode' using the current magit availability."
  (let ((parent (ogent-gastown--status-mode-parent)))
    (eval
     `(define-derived-mode ogent-gastown-status-mode ,parent "Gas Town"
        ,ogent-gastown--status-mode-doc
        :group 'ogent-gastown
        (ogent-gastown--status-mode-setup)))))

(defun ogent-gastown--ensure-status-mode-definition ()
  "Ensure `ogent-gastown-status-mode' parent matches current capabilities."
  (let ((expected-parent (ogent-gastown--status-mode-parent))
        (actual-parent (get 'ogent-gastown-status-mode 'derived-mode-parent)))
    (unless (eq expected-parent actual-parent)
      (ogent-gastown--define-status-mode))))

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

(defun ogent-gastown--rig-names ()
  "Return rig names from cached rig data."
  (delq nil (mapcar (lambda (rig) (plist-get rig :name))
                    ogent-gastown--rigs-data)))

(defun ogent-gastown--sync-selected-rig ()
  "Ensure `ogent-gastown--selected-rig' points to a valid rig.
When unavailable, clear it; when unset, pick the first known rig."
  (let ((rig-names (ogent-gastown--rig-names)))
    (cond
     ((null rig-names)
      (setq ogent-gastown--selected-rig nil))
     ((member ogent-gastown--selected-rig rig-names)
      ogent-gastown--selected-rig)
     (t
      (setq ogent-gastown--selected-rig (car rig-names))))))

(defun ogent-gastown--selected-rig-heading ()
  "Return a formatted selected-rig heading suffix."
  (if-let ((rig (ogent-gastown--sync-selected-rig)))
      (format " [%s]" rig)
    " [all rigs]"))

(defun ogent-gastown--header-rig-segment ()
  "Return selected rig segment for the header line, or nil."
  (when-let ((rig (ogent-gastown--sync-selected-rig)))
    (concat
     (propertize "  " 'face 'ogent-gastown-dimmed)
     (propertize "Rig:" 'face 'ogent-gastown-dimmed)
     (propertize rig 'face 'ogent-gastown-rig-name)
     (propertize " (H/L)" 'face 'ogent-gastown-dimmed))))

(defun ogent-gastown--filter-items-for-selected-rig (items)
  "Return ITEMS scoped to the selected rig when possible."
  (if-let ((rig (ogent-gastown--sync-selected-rig)))
      (seq-filter (lambda (item)
                    (equal (plist-get item :rig) rig))
                  items)
    items))

(defun ogent-gastown--crew-list-args (&optional rig-name)
  "Return `gt crew list' args scoped to RIG-NAME when provided."
  (if (and rig-name (not (string-empty-p rig-name)))
      (list "crew" "list" "--rig" rig-name "--json")
    '("crew" "list" "--all" "--json")))

(defun ogent-gastown--polecat-list-args (&optional rig-name)
  "Return `gt polecat list' args scoped to RIG-NAME when provided."
  (if (and rig-name (not (string-empty-p rig-name)))
      (list "polecat" "list" rig-name "--json")
    '("polecat" "list" "--all" "--json")))

;;; Header Line

(defun ogent-gastown--header-line ()
  "Generate header line for Gas Town buffer."
  (let ((loading-indicator (ogent-gastown--loading-indicator))
        (workspace-segment (ogent-gastown--header-workspace-segment))
        (rig-segment (ogent-gastown--header-rig-segment))
        (mail-count (length (seq-filter
                             (lambda (m) (not (plist-get m :read)))
                             ogent-gastown--mail-data)))
        (hook-loading ogent-gastown--hook-loading)
        (hook-active (and ogent-gastown--hook-data
                          (plist-get ogent-gastown--hook-data :has_work))))
    (concat
     (propertize " " 'face 'ogent-gastown-header-line)
     (propertize "Gas Town" 'face 'ogent-gastown-header-line)
     (or workspace-segment "")
     (or rig-segment "")
     (if loading-indicator
         (concat (propertize "  " 'face 'ogent-gastown-dimmed)
                 (propertize loading-indicator 'face 'ogent-gastown-hook-active)
                 (propertize " Loading..." 'face 'ogent-gastown-dimmed))
       (concat
        (propertize "  " 'face 'ogent-gastown-dimmed)
        (if hook-loading
            (propertize "Hook: loading" 'face 'ogent-gastown-dimmed)
          (if hook-active
              (propertize "Hook: active" 'face 'ogent-gastown-hook-active)
            (propertize "Hook: empty" 'face 'ogent-gastown-hook-empty)))
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

(defun ogent-gastown--fetch-all (callback &optional deferred-callback)
  "Fetch status data for the status buffer.
CALLBACK runs once core sections are ready.
DEFERRED-CALLBACK runs after each deferred section update."
  (let* ((core-pending 3)
         (results (make-hash-table :test 'eq))
         (errors (make-hash-table :test 'eq))
         (buf (current-buffer))
         (check-core-done
          (lambda ()
            (cl-decf core-pending)
            (when (zerop core-pending)
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (setq ogent-gastown--workers-data
                        (ogent-gastown--normalize-worker-list
                         (gethash 'workers results)))
                  (setq ogent-gastown--crew-data
                        (ogent-gastown--normalize-crew-list
                         (gethash 'crew results)))
                  (setq ogent-gastown--polecat-data
                        (ogent-gastown--normalize-polecat-list
                         (gethash 'polecat results)))
                  (let ((town-status (gethash 'town-status results)))
                    (setq ogent-gastown--stats-data
                          (plist-get town-status :summary))
                    (setq ogent-gastown--deacon-data
                          (ogent-gastown--extract-deacon town-status))
                    (setq ogent-gastown--witness-data
                          (ogent-gastown--extract-witnesses town-status))
                    (setq ogent-gastown--rigs-data
                          (plist-get town-status :rigs))
                    (ogent-gastown--sync-selected-rig))
                  ;; Keep the same hash table so deferred updates mutate in place.
                  (setq ogent-gastown--fetch-errors errors)
                  (funcall callback))))))
         (update-deferred
          (lambda (slot value &optional err)
            (when (buffer-live-p buf)
              (with-current-buffer buf
                (if err
                    (puthash slot err errors)
                  (remhash slot errors))
                (pcase slot
                  ('hook
                   (setq ogent-gastown--hook-loading nil)
                   (setq ogent-gastown--hook-data value))
                  ('mail
                   (setq ogent-gastown--mail-loading nil)
                   (setq ogent-gastown--mail-data value))
                  ('convoy
                   (setq ogent-gastown--convoy-loading nil)
                   (setq ogent-gastown--convoy-data
                         (ogent-gastown--normalize-convoy-list value)))
                  ('issues
                   (setq ogent-gastown--issues-data value)))
                (setq ogent-gastown--fetch-errors errors)
                (when deferred-callback
                  (funcall deferred-callback slot value err))))))
         (fetch-rig-scoped
          (lambda (rig-name)
            (ogent-gastown--run-async-cached
             (ogent-gastown--crew-list-args rig-name)
             (lambda (result)
               (puthash 'crew result results)
               (remhash 'crew errors)
               (funcall check-core-done))
             (lambda (err)
               (puthash 'crew nil results)
               (puthash 'crew err errors)
               (funcall check-core-done)))

            ;; Reuse polecat payload for workers and polecat sections.
            (ogent-gastown--run-async-cached
             (ogent-gastown--polecat-list-args rig-name)
             (lambda (result)
               (puthash 'workers result results)
               (puthash 'polecat result results)
               (remhash 'workers errors)
               (remhash 'polecat errors)
               (funcall check-core-done))
             (lambda (err)
               (puthash 'workers nil results)
               (puthash 'polecat nil results)
               (puthash 'workers err errors)
               (puthash 'polecat err errors)
               (funcall check-core-done))))))

    (setq ogent-gastown--hook-loading t
          ogent-gastown--mail-loading t
          ogent-gastown--convoy-loading t
          ogent-gastown--hook-data nil
          ogent-gastown--mail-data nil
          ogent-gastown--convoy-data nil
          ogent-gastown--fetch-errors errors)

    ;; Core: fast first paint.
    (ogent-gastown--run-async-cached
     '("status" "--json" "--fast")
     (lambda (result)
       (puthash 'town-status result results)
       (remhash 'town-status errors)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setq ogent-gastown--rigs-data (plist-get result :rigs))
           (ogent-gastown--sync-selected-rig)))
       (let ((selected-rig (and (buffer-live-p buf)
                                (with-current-buffer buf ogent-gastown--selected-rig))))
         (funcall fetch-rig-scoped selected-rig))
       (funcall check-core-done))
     (lambda (err)
       (puthash 'town-status nil results)
       (puthash 'town-status err errors)
       (let ((selected-rig (and (buffer-live-p buf)
                                (with-current-buffer buf
                                  (ogent-gastown--sync-selected-rig)
                                  ogent-gastown--selected-rig))))
         (funcall fetch-rig-scoped selected-rig))
       (funcall check-core-done)))

    ;; Deferred: load slower sections in the background.
    (ogent-gastown--run-async-cached
     '("hook" "--json")
     (lambda (result)
       (funcall update-deferred 'hook result nil))
     (lambda (err)
       (funcall update-deferred 'hook nil err)))

    (ogent-gastown--run-async-cached
     '("mail" "inbox" "--json")
     (lambda (result)
       (funcall update-deferred 'mail result nil))
     (lambda (err)
       (funcall update-deferred 'mail nil err)))

    (ogent-gastown--run-async-cached
     '("convoy" "list" "--json")
     (lambda (result)
       (funcall update-deferred 'convoy result nil))
     (lambda (err)
       (funcall update-deferred 'convoy nil err)))

    ;; Deferred: fetch open issues for inline display in rig sections.
    ;; Uses bd list via ogent-issues-bd-list with status filter.
    ;; Groups results by rig name, excluding agent/event types.
    (ogent-issues-bd-list
     (lambda (result)
       (when (buffer-live-p buf)
         (let ((grouped nil))
           ;; Group issues by rig (for now, all go under selected rig)
           (dolist (issue result)
             (let* ((issue-type (plist-get issue :issue_type))
                    ;; Skip agent/event beads — only show work items
                    (work-type-p (member issue-type '("task" "bug" "feature" "epic" "chore"))))
               (when work-type-p
                 (let* ((rig (or ogent-gastown--selected-rig "ogent"))
                        (entry (assoc rig grouped)))
                   (if entry
                       (setcdr entry (append (cdr entry) (list issue)))
                     (push (cons rig (list issue)) grouped))))))
           (funcall update-deferred 'issues grouped nil))))
     '(:status "open")
     (lambda (err)
       (funcall update-deferred 'issues nil err)))))

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

;;; Fetch Error Helpers

(defun ogent-gastown--section-fetch-error (key)
  "Return the fetch error string for section KEY, or nil."
  (gethash key ogent-gastown--fetch-errors))

(defun ogent-gastown--insert-fetch-error (key)
  "Insert a concise error line for section KEY if a fetch error exists.
Returns non-nil if an error was inserted."
  (when-let* ((err (ogent-gastown--section-fetch-error key)))
    (insert "  ")
    (insert (propertize (format "Fetch failed: %s" err)
                        'face 'ogent-gastown-fetch-error))
    (insert "\n")
    t))

;;; Buffer Rendering

(defun ogent-gastown--insert-buffer-contents ()
  "Insert all sections into the buffer."
  (if (ogent-gastown--magit-usable-p)
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
         (loading ogent-gastown--hook-loading)
         (has-work (plist-get data :has_work))
         (role (or (plist-get data :role) "unknown"))
         (target (or (plist-get data :target) "unknown"))
         (next-action (plist-get data :next_action)))
    (magit-insert-section (ogent-gastown-hook-section data)
      (magit-insert-heading
       (ogent-gastown--compose-section-heading
        'hook
        "Hook Status"
        (when loading
          (propertize " (loading...)" 'face 'ogent-gastown-dimmed))))
      (cond
       ((and loading (null data))
        (insert (propertize "  Loading hook...\n" 'face 'ogent-gastown-dimmed)))
       ((and (null data) (ogent-gastown--section-fetch-error 'hook))
        (ogent-gastown--insert-fetch-error 'hook))
       (t
        (insert "  ")
        (insert (propertize "Role: " 'face 'ogent-gastown-dimmed))
        (insert (propertize role 'face 'ogent-gastown-rig-name))
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
        (insert "\n"))))))

(defun ogent-gastown--insert-hook-section-plain ()
  "Insert hook status section (plain)."
  (let* ((data ogent-gastown--hook-data)
         (loading ogent-gastown--hook-loading)
         (has-work (plist-get data :has_work))
         (role (or (plist-get data :role) "unknown")))
    (insert (propertize (ogent-gastown--compose-plain-section-heading 'hook "Hook Status")
                        'face (ogent-gastown--section-heading-face 'hook)))
    (cond
     ((and loading (null data))
      (insert (propertize "  Loading hook...\n" 'face 'ogent-gastown-dimmed)))
     ((and (null data) (ogent-gastown--section-fetch-error 'hook))
      (ogent-gastown--insert-fetch-error 'hook))
     (t
      (insert "  Role: " role "\n")
      (insert "  ")
      (if has-work
          (insert (propertize "Work hooked" 'face 'ogent-gastown-hook-active))
        (insert (propertize "No work hooked" 'face 'ogent-gastown-hook-empty)))
      (insert "\n")))))

;;; Mail Section

(defun ogent-gastown--insert-mail-section ()
  "Insert mail inbox section with magit-section."
  (let* ((mail ogent-gastown--mail-data)
         (loading ogent-gastown--mail-loading)
         (unread-count (length (seq-filter (lambda (m) (not (plist-get m :read))) mail))))
    (magit-insert-section (ogent-gastown-mail-section mail nil)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'mail
         "Mail Inbox"
         (when loading
           (propertize " (loading...)" 'face 'ogent-gastown-dimmed))
         (when (> unread-count 0)
           (propertize (format " (%d unread)" unread-count)
                       'face 'ogent-gastown-mail-unread))))
      (cond
       ((and loading (null mail))
        (insert (propertize "  Loading mail...\n" 'face 'ogent-gastown-dimmed)))
       ((ogent-gastown--section-fetch-error 'mail)
        (ogent-gastown--insert-fetch-error 'mail))
       ((null mail)
        (insert (propertize "  No messages\n" 'face 'ogent-gastown-dimmed)))
       (t
        (dolist (msg mail)
          (ogent-gastown--insert-mail-item msg)))))))

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
  (let ((mail ogent-gastown--mail-data)
        (loading ogent-gastown--mail-loading))
    (insert (propertize (ogent-gastown--compose-plain-section-heading 'mail "Mail Inbox")
                        'face (ogent-gastown--section-heading-face 'mail)))
    (cond
     ((and loading (null mail))
      (insert (propertize "  Loading mail...\n" 'face 'ogent-gastown-dimmed)))
     ((ogent-gastown--section-fetch-error 'mail)
      (ogent-gastown--insert-fetch-error 'mail))
     ((null mail)
      (insert (propertize "  No messages\n" 'face 'ogent-gastown-dimmed)))
     (t
      (dolist (msg mail)
        (let* ((from (plist-get msg :from))
               (subject (plist-get msg :subject))
               (read (plist-get msg :read)))
          (insert "  ")
          (insert (if read "  " "* "))
          (insert (or from "unknown"))
          (insert " - ")
          (insert (or subject "(no subject)"))
          (insert "\n")))))))

;;; Convoy Section

(defun ogent-gastown--insert-convoy-section ()
  "Insert convoy status section with magit-section."
  (let ((convoys ogent-gastown--convoy-data)
        (loading ogent-gastown--convoy-loading))
    (magit-insert-section (ogent-gastown-convoy-section convoys nil)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'convoy
         "Convoys"
         (when loading
           (propertize " (loading...)" 'face 'ogent-gastown-dimmed))
         (when convoys
           (propertize (format " (%d)" (length convoys))
                       'face 'ogent-gastown-dimmed))))
      (cond
       ((and loading (null convoys))
        (insert (propertize "  Loading convoys...\n" 'face 'ogent-gastown-dimmed)))
       ((ogent-gastown--section-fetch-error 'convoy)
        (ogent-gastown--insert-fetch-error 'convoy))
       ((null convoys)
        (insert (propertize "  No active convoys\n" 'face 'ogent-gastown-dimmed)))
       (t
        (dolist (convoy convoys)
          (ogent-gastown--insert-convoy-item convoy)))))))

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
  (let ((convoys ogent-gastown--convoy-data)
        (loading ogent-gastown--convoy-loading))
    (insert (propertize (ogent-gastown--compose-plain-section-heading 'convoy "Convoys")
                        'face (ogent-gastown--section-heading-face 'convoy)))
    (cond
     ((and loading (null convoys))
      (insert (propertize "  Loading convoys...\n" 'face 'ogent-gastown-dimmed)))
     ((ogent-gastown--section-fetch-error 'convoy)
      (ogent-gastown--insert-fetch-error 'convoy))
     ((null convoys)
      (insert (propertize "  No active convoys\n" 'face 'ogent-gastown-dimmed)))
     (t
      (dolist (convoy convoys)
        (insert "  ")
        (insert (or (plist-get convoy :title) "(unnamed)"))
        (insert "\n"))))))

;;; Workers Section

(defun ogent-gastown--insert-workers-section ()
  "Insert workers overview section with magit-section."
  (let ((workers (ogent-gastown--filter-items-for-selected-rig
                  ogent-gastown--workers-data))
        (running-count 0))
    (dolist (w workers)
      (when (plist-get w :session_running)
        (cl-incf running-count)))
    (magit-insert-section (ogent-gastown-workers-section workers nil)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'workers
         "Workers"
         (propertize (ogent-gastown--selected-rig-heading)
                     'face 'ogent-gastown-rig-name)
         (propertize (format " (%d/%d running)"
                             running-count (length workers))
                     'face 'ogent-gastown-dimmed)))
      (cond
       ((ogent-gastown--section-fetch-error 'workers)
        (ogent-gastown--insert-fetch-error 'workers))
       ((null workers)
        (insert (propertize
                 (format "  No workers for %s\n"
                         (or (ogent-gastown--sync-selected-rig) "selected rig"))
                 'face 'ogent-gastown-dimmed)))
       (t
        (dolist (worker workers)
          (ogent-gastown--insert-worker-item worker)))))))

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
  (let ((workers (ogent-gastown--filter-items-for-selected-rig
                  ogent-gastown--workers-data)))
    (insert (propertize
             (ogent-gastown--compose-plain-section-heading
              'workers "Workers" (ogent-gastown--selected-rig-heading))
             'face (ogent-gastown--section-heading-face 'workers)))
    (cond
     ((ogent-gastown--section-fetch-error 'workers)
      (ogent-gastown--insert-fetch-error 'workers))
     ((null workers)
      (insert (propertize
               (format "  No workers for %s\n"
                       (or (ogent-gastown--sync-selected-rig) "selected rig"))
               'face 'ogent-gastown-dimmed)))
     (t
      (dolist (worker workers)
        (insert "  ")
        (insert (or (plist-get worker :rig) "???"))
        (insert "/")
        (insert (or (plist-get worker :name) "???"))
        (insert " [")
        (insert (or (plist-get worker :state) "unknown"))
        (insert "]\n"))))))

;;; Stats Section

(defun ogent-gastown--insert-stats-section ()
  "Insert town statistics section with magit-section."
  (let ((stats ogent-gastown--stats-data))
    (magit-insert-section (ogent-gastown-stats-section stats)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading 'stats "Town Stats"))
      (cond
       ((and (null stats) (ogent-gastown--section-fetch-error 'town-status))
        (ogent-gastown--insert-fetch-error 'town-status))
       ((null stats)
        (insert (propertize "  No stats available\n" 'face 'ogent-gastown-dimmed)))
       (t
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
        (insert "\n"))))))

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
    (insert (propertize (ogent-gastown--compose-plain-section-heading 'stats "Town Stats")
                        'face (ogent-gastown--section-heading-face 'stats)))
    (cond
     ((and (null stats) (ogent-gastown--section-fetch-error 'town-status))
      (ogent-gastown--insert-fetch-error 'town-status))
     ((null stats)
      (insert (propertize "  No stats available\n" 'face 'ogent-gastown-dimmed)))
     (t
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
                          (or (plist-get agg :in_progress) 0)))))))))

;;; Deacon Section

(defun ogent-gastown--insert-deacon-section ()
  "Insert deacon status section with magit-section."
  (let* ((data ogent-gastown--deacon-data)
         (running (plist-get data :running))
         (has-work (plist-get data :has_work))
         (address (plist-get data :address)))
    (magit-insert-section (ogent-gastown-deacon-section data)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'deacon
         "Deacon"
         " "
         (if running
             (propertize "[running]" 'face 'ogent-gastown-deacon-running)
           (propertize "[stopped]" 'face 'ogent-gastown-deacon-stopped))))
      (cond
       ((and (null data) (ogent-gastown--section-fetch-error 'town-status))
        (ogent-gastown--insert-fetch-error 'town-status))
       ((null data)
        (insert (propertize "  No deacon info available\n" 'face 'ogent-gastown-dimmed)))
       (t
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
        (insert "\n"))))))

(defun ogent-gastown--insert-deacon-section-plain ()
  "Insert deacon section (plain)."
  (let* ((data ogent-gastown--deacon-data)
         (running (plist-get data :running)))
    (insert (propertize (ogent-gastown--compose-plain-section-heading 'deacon "Deacon")
                        'face (ogent-gastown--section-heading-face 'deacon)))
    (cond
     ((and (null data) (ogent-gastown--section-fetch-error 'town-status))
      (ogent-gastown--insert-fetch-error 'town-status))
     (t
      (insert "  Status: ")
      (if running
          (insert (propertize "running\n" 'face 'ogent-gastown-deacon-running))
        (insert (propertize "stopped\n" 'face 'ogent-gastown-deacon-stopped)))))))

;;; Witness Section

(defun ogent-gastown--insert-witness-section ()
  "Insert witness status section with magit-section."
  (let* ((witnesses ogent-gastown--witness-data)
         (active-count (length (seq-filter
                                (lambda (w) (plist-get w :has_witness))
                                witnesses))))
    (magit-insert-section (ogent-gastown-witness-section witnesses nil)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'witnesses
         "Witnesses"
         (propertize (format " (%d/%d active)"
                             active-count (length witnesses))
                     'face 'ogent-gastown-dimmed)))
      (cond
       ((and (null witnesses) (ogent-gastown--section-fetch-error 'town-status))
        (ogent-gastown--insert-fetch-error 'town-status))
       ((null witnesses)
        (insert (propertize "  No rig data available\n" 'face 'ogent-gastown-dimmed)))
       (t
        (dolist (witness witnesses)
          (ogent-gastown--insert-witness-item witness)))))))

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
    (insert (propertize (ogent-gastown--compose-plain-section-heading 'witnesses "Witnesses")
                        'face (ogent-gastown--section-heading-face 'witnesses)))
    (cond
     ((and (null witnesses) (ogent-gastown--section-fetch-error 'town-status))
      (ogent-gastown--insert-fetch-error 'town-status))
     ((null witnesses)
      (insert (propertize "  No rig data available\n" 'face 'ogent-gastown-dimmed)))
     (t
      (dolist (witness witnesses)
        (let* ((rig (plist-get witness :rig))
               (has-witness (plist-get witness :has_witness)))
          (insert "  ")
          (insert (if has-witness "+" "-"))
          (insert " ")
          (insert rig)
          (insert "\n")))))))

;;; Crew Section

(defun ogent-gastown--insert-crew-section ()
  "Insert crew status section with magit-section."
  (let ((crew (ogent-gastown--filter-items-for-selected-rig
               ogent-gastown--crew-data))
        (active-count 0))
    (dolist (member crew)
      (when (plist-get member :session_running)
        (cl-incf active-count)))
    (magit-insert-section (ogent-gastown-crew-section crew nil)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'crew
         "Crew"
         (propertize (ogent-gastown--selected-rig-heading)
                     'face 'ogent-gastown-rig-name)
         (propertize (format " (%d/%d active)"
                             active-count (length crew))
                     'face 'ogent-gastown-dimmed)))
      (cond
       ((ogent-gastown--section-fetch-error 'crew)
        (ogent-gastown--insert-fetch-error 'crew))
       ((null crew)
        (insert (propertize
                 (format "  No crew members for %s\n"
                         (or (ogent-gastown--sync-selected-rig) "selected rig"))
                 'face 'ogent-gastown-dimmed)))
       (t
        (dolist (member crew)
          (ogent-gastown--insert-crew-item member)))))))

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
        (insert (propertize (format "%s%d" (ogent-ops-badge-symbol 'mail) mail-count) 'face 'ogent-gastown-mail-unread)))
      (insert "\n"))))

(defun ogent-gastown--insert-crew-section-plain ()
  "Insert crew section (plain)."
  (let ((crew (ogent-gastown--filter-items-for-selected-rig
               ogent-gastown--crew-data)))
    (insert (propertize
             (ogent-gastown--compose-plain-section-heading
              'crew "Crew" (ogent-gastown--selected-rig-heading))
             'face (ogent-gastown--section-heading-face 'crew)))
    (cond
     ((ogent-gastown--section-fetch-error 'crew)
      (ogent-gastown--insert-fetch-error 'crew))
     ((null crew)
      (insert (propertize
               (format "  No crew members for %s\n"
                       (or (ogent-gastown--sync-selected-rig) "selected rig"))
               'face 'ogent-gastown-dimmed)))
     (t
      (dolist (member crew)
        (insert "  ")
        (insert (or (plist-get member :rig) "???"))
        (insert "/")
        (insert (or (plist-get member :name) "???"))
        (when (plist-get member :session_running)
          (insert " [active]"))
        (insert "\n"))))))

;;; Polecat Section

(defun ogent-gastown--insert-polecat-section ()
  "Insert polecat status section with magit-section."
  (let ((polecats (ogent-gastown--filter-items-for-selected-rig
                   ogent-gastown--polecat-data))
        (running-count 0))
    (dolist (p polecats)
      (when (plist-get p :session_running)
        (cl-incf running-count)))
    (magit-insert-section (ogent-gastown-polecat-section polecats nil)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'polecats
         "Polecats"
         (propertize (ogent-gastown--selected-rig-heading)
                     'face 'ogent-gastown-rig-name)
         (propertize (format " (%d/%d running)"
                             running-count (length polecats))
                     'face 'ogent-gastown-dimmed)))
      (cond
       ((ogent-gastown--section-fetch-error 'polecat)
        (ogent-gastown--insert-fetch-error 'polecat))
       ((null polecats)
        (insert (propertize
                 (format "  No polecats for %s\n"
                         (or (ogent-gastown--sync-selected-rig) "selected rig"))
                 'face 'ogent-gastown-dimmed)))
       (t
        (dolist (polecat polecats)
          (ogent-gastown--insert-polecat-item polecat)))))))

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
  (let ((polecats (ogent-gastown--filter-items-for-selected-rig
                   ogent-gastown--polecat-data)))
    (insert (propertize
             (ogent-gastown--compose-plain-section-heading
              'polecats "Polecats" (ogent-gastown--selected-rig-heading))
             'face (ogent-gastown--section-heading-face 'polecats)))
    (cond
     ((ogent-gastown--section-fetch-error 'polecat)
      (ogent-gastown--insert-fetch-error 'polecat))
     ((null polecats)
      (insert (propertize
               (format "  No polecats for %s\n"
                       (or (ogent-gastown--sync-selected-rig) "selected rig"))
               'face 'ogent-gastown-dimmed)))
     (t
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
        (insert "\n"))))))

;;; Rigs Section

(defun ogent-gastown--insert-rigs-section ()
  "Insert rigs overview section with magit-section."
  (let ((rigs ogent-gastown--rigs-data))
    (magit-insert-section (ogent-gastown-rigs-section rigs nil)
      (magit-insert-heading
        (ogent-gastown--compose-section-heading
         'rigs
         "Rigs"
         (propertize (format " (%d)" (length rigs))
                     'face 'ogent-gastown-dimmed)))
      (cond
       ((and (null rigs) (ogent-gastown--section-fetch-error 'town-status))
        (ogent-gastown--insert-fetch-error 'town-status))
       ((null rigs)
        (insert (propertize "  No rigs configured\n" 'face 'ogent-gastown-dimmed)))
       (t
        (dolist (rig rigs)
          (ogent-gastown--insert-rig-item rig)))))))

(defun ogent-gastown--insert-rig-item (rig)
  "Insert a single RIG as a section."
  (let* ((name (plist-get rig :name))
         (polecat-count (or (plist-get rig :polecat_count) 0))
         (crew-count (or (plist-get rig :crew_count) 0))
         (has-witness (plist-get rig :has_witness))
         (has-refinery (plist-get rig :has_refinery))
         (agents (plist-get rig :agents))
         (any-running (seq-some (lambda (a) (plist-get a :running)) agents)))
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
      (ogent-gastown--insert-rig-beads-detail (plist-get rig :beads_stats))
      ;; Insert inline issue items if expanded
      (ogent-gastown--insert-rig-issues name))))

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
        (insert "    "
                (ogent-gastown--compose-section-heading 'issues "Issues:")
                "\n")
        (dolist (p pairs)
          (let ((label (nth 0 p))
                (value (nth 1 p))
                (face (nth 2 p)))
            (when (> value 0)
              (insert "      "
                      (propertize (format "%-12s" label) 'face 'ogent-gastown-dimmed)
                      (propertize (format "%d" value) 'face face)
                      "\n"))))))))

(defun ogent-gastown--insert-rig-issues (rig-name)
  "Insert inline issue items for RIG-NAME from cached issues data."
  (when-let* ((issues (cdr (assoc rig-name ogent-gastown--issues-data))))
    (let ((ogent-ops-use-unicode ogent-gastown-use-unicode)
          (shown 0)
          (max-issues 20))
      (dolist (issue issues)
        (when (< shown max-issues)
          (let* ((id (plist-get issue :id))
                 (title (or (plist-get issue :title) "(untitled)"))
                 (status (or (plist-get issue :status) "open"))
                 (priority (plist-get issue :priority))
                 (assignee (plist-get issue :assignee))
                 (issue-type (or (plist-get issue :issue_type) "task"))
                 (status-icon
                  (pcase status
                    ("in_progress" (propertize (ogent-ops-section-prefix "●" "*")
                                              'face 'ogent-gastown-beads-in-progress))
                    ("hooked"      (propertize (ogent-ops-section-prefix "●" "*")
                                              'face 'ogent-gastown-beads-in-progress))
                    ("blocked"     (propertize (ogent-ops-section-prefix "⊘" "x")
                                              'face 'warning))
                    (_             (propertize (ogent-ops-section-prefix "○" "o")
                                              'face 'ogent-gastown-dimmed))))
                 (pri-badge
                  (when priority
                    (propertize (format "[P%s]" priority)
                                'face (if (<= priority 1) 'warning 'ogent-gastown-dimmed))))
                 (type-badge
                  (unless (equal issue-type "task")
                    (propertize (format "[%s]" issue-type) 'face 'ogent-gastown-dimmed)))
                 (assignee-str
                  (when (and assignee (not (string-empty-p assignee)))
                    (propertize (format "@%s" (file-name-nondirectory assignee))
                                'face 'ogent-gastown-dimmed))))
            (magit-insert-section (ogent-gastown-issue-item-section issue)
              (insert "      "
                      status-icon " "
                      (or pri-badge "") (if pri-badge " " "")
                      (propertize (or id "?") 'face 'ogent-gastown-dimmed)
                      "  "
                      (propertize (truncate-string-to-width title 50 nil nil t)
                                  'face (if (member status '("in_progress" "hooked"))
                                            'bold 'default))
                      (if type-badge (concat " " type-badge) "")
                      (if assignee-str (concat "  " assignee-str) "")
                      "\n"))
            (cl-incf shown))))
      (when (> (length issues) max-issues)
        (insert "      "
                (propertize (format "... and %d more (press i for full list)"
                                    (- (length issues) max-issues))
                            'face 'ogent-gastown-dimmed)
                "\n")))))

(defun ogent-gastown--insert-rig-agent (agent)
  "Insert a single AGENT line within a rig section."
  (let* ((ogent-ops-use-unicode ogent-gastown-use-unicode)
         (name (plist-get agent :name))
         (role (plist-get agent :role))
         (running (plist-get agent :running))
         (has-work (plist-get agent :has_work))
         (unread (or (plist-get agent :unread_mail) 0))
         (role-icon (pcase role
                      ("witness" (ogent-ops-role-symbol 'witness))
                      ("refinery" (ogent-ops-role-symbol 'refinery))
                      ("polecat" (ogent-ops-role-symbol 'polecat))
                      ("crew" (ogent-ops-role-symbol 'crew))
                      (_ "?"))))
    (insert "    ")
    (insert role-icon)
    (insert " ")
    (insert (propertize (or name "???")
                        'face (if running 'ogent-gastown-worker-running 'ogent-gastown-dimmed)))
    (when has-work
      (insert " ")
      (insert (propertize (ogent-ops-badge-symbol 'hook) 'face 'ogent-gastown-hook-active)))
    (when (> unread 0)
      (insert " ")
      (insert (propertize (format "%s%d"
                                  (ogent-ops-badge-symbol 'mail)
                                  unread)
                          'face 'ogent-gastown-mail-unread)))
    (insert "\n")))

(defun ogent-gastown--insert-rigs-section-plain ()
  "Insert rigs section (plain)."
  (let ((rigs ogent-gastown--rigs-data))
    (insert (propertize (ogent-gastown--compose-plain-section-heading 'rigs "Rigs")
                        'face (ogent-gastown--section-heading-face 'rigs)))
    (cond
     ((and (null rigs) (ogent-gastown--section-fetch-error 'town-status))
      (ogent-gastown--insert-fetch-error 'town-status))
     ((null rigs)
      (insert (propertize "  No rigs configured\n" 'face 'ogent-gastown-dimmed)))
     (t
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
          (insert "\n")))))))

;;; Utilities

(defun ogent-gastown--format-time (iso-time)
  "Format ISO-TIME as relative time string."
  (if (and iso-time (stringp iso-time) (not (string-empty-p iso-time)))
      (condition-case nil
          (let* ((time (encode-time (iso8601-parse iso-time)))
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
  (if (ogent-gastown--magit-usable-p)
      (magit-section-forward)
    (forward-line)))

(defun ogent-gastown-prev-item ()
  "Move to the previous item."
  (interactive)
  (if (ogent-gastown--magit-usable-p)
      (magit-section-backward)
    (forward-line -1)))

(defun ogent-gastown-toggle-section ()
  "Toggle the current section."
  (interactive)
  (if (ogent-gastown--magit-usable-p)
      (if-let ((section (magit-current-section)))
          (magit-section-toggle section)
        (message "No section at point"))
    (message "Section toggling requires magit-section")))

(defun ogent-gastown-next-section ()
  "Move to the next sibling section."
  (interactive)
  (when (ogent-gastown--magit-usable-p)
    (magit-section-forward-sibling)))

(defun ogent-gastown-prev-section ()
  "Move to the previous sibling section."
  (interactive)
  (when (ogent-gastown--magit-usable-p)
    (magit-section-backward-sibling)))

(defun ogent-gastown--cycle-rig (delta)
  "Move selected rig by DELTA and refresh the status buffer."
  (let* ((rigs (ogent-gastown--rig-names))
         (count (length rigs)))
    (cond
     ((zerop count)
      (user-error "No rigs available"))
     ((= count 1)
      (setq ogent-gastown--selected-rig (car rigs))
      (message "Only one rig available: %s" ogent-gastown--selected-rig))
     (t
      (let* ((current (or (ogent-gastown--sync-selected-rig) (car rigs)))
             (idx (or (cl-position current rigs :test #'string=) 0))
             (next-idx (mod (+ idx delta) count)))
        (setq ogent-gastown--selected-rig (nth next-idx rigs))
        (message "Selected rig: %s (%d/%d)"
                 ogent-gastown--selected-rig
                 (1+ next-idx)
                 count))))
    (ogent-gastown-refresh)))

(defun ogent-gastown-cycle-rig-prev ()
  "Select the previous rig and refresh scoped sections."
  (interactive)
  (ogent-gastown--cycle-rig -1))

(defun ogent-gastown-cycle-rig-next ()
  "Select the next rig and refresh scoped sections."
  (interactive)
  (ogent-gastown--cycle-rig 1))

(defun ogent-gastown-up-section ()
  "Move to the parent section."
  (interactive)
  (when (ogent-gastown--magit-usable-p)
    (magit-section-up)))

(defun ogent-gastown-cycle-sections ()
  "Cycle visibility of all sections."
  (interactive)
  (if (ogent-gastown--magit-usable-p)
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-gastown-visit ()
  "Visit the item at point.
On convoy items, opens the convoy inspector.
On mail items, reads the message.
On other sections, toggles visibility."
  (interactive)
  (when (ogent-gastown--magit-usable-p)
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
       ((eq (eieio-object-class-name section) 'ogent-gastown-issue-item-section)
        (let* ((issue (oref section value))
               (id (plist-get issue :id)))
          (when id
            (ogent-issues-bd-get id
                                 (lambda (detail)
                                   (when detail
                                     (ogent-issues--show-detail detail)))
                                 (lambda (err)
                                   (message "Could not fetch issue %s: %s" id err))))))
       (t
        (magit-section-toggle section))))))

;;; Actions

(defun ogent-gastown-status-mail-read (&optional id)
  "Read mail message ID."
  (interactive)
  (let ((mail-id (or id
                     (when (ogent-gastown--magit-usable-p)
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
  (when (ogent-gastown--magit-usable-p)
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

;;; Issue Triage Actions

(defun ogent-gastown--issue-at-point ()
  "Return the issue plist at point if on an issue-item-section, else nil."
  (when (ogent-gastown--magit-usable-p)
    (let ((section (magit-current-section)))
      (when (and section
                 (eq (eieio-object-class-name section)
                     'ogent-gastown-issue-item-section))
        (oref section value)))))

(defun ogent-gastown-issue-close ()
  "Close the issue at point, prompting for a reason."
  (interactive)
  (let ((issue (ogent-gastown--issue-at-point)))
    (unless issue
      (user-error "No issue at point"))
    (let* ((id (plist-get issue :id))
           (title (or (plist-get issue :title) "(untitled)"))
           (reason (read-string (format "Close %s (%s) reason: " id title))))
      (when (and reason (not (string-empty-p reason)))
        (when (y-or-n-p (format "Close %s: %s? " id title))
          (ogent-issues-bd-close
           id reason
           (lambda ()
             (message "Closed %s: %s" id title)
             (ogent-gastown-cache-invalidate)
             (ogent-gastown-refresh))
           (lambda (err)
             (message "Failed to close %s: %s" id err))))))))

(defun ogent-gastown-issue-prioritize ()
  "Set priority on the issue at point."
  (interactive)
  (let ((issue (ogent-gastown--issue-at-point)))
    (unless issue
      (user-error "No issue at point"))
    (let* ((id (plist-get issue :id))
           (title (or (plist-get issue :title) "(untitled)"))
           (current (plist-get issue :priority))
           (choices '("P0" "P1" "P2" "P3"))
           (default (when current (format "P%s" current)))
           (choice (completing-read
                    (format "Priority for %s (%s)%s: "
                            id title
                            (if default (format " [%s]" default) ""))
                    choices nil t nil nil default))
           (priority (string-to-number (substring choice 1))))
      (ogent-issues-bd-update
       id
       (lambda ()
         (message "Set %s to %s" id choice)
         (ogent-gastown-cache-invalidate)
         (ogent-gastown-refresh))
       :priority priority
       :error-callback
       (lambda (err)
         (message "Failed to set priority on %s: %s" id err))))))

(defun ogent-gastown-issue-claim ()
  "Claim the issue at point (mark in-progress)."
  (interactive)
  (let ((issue (ogent-gastown--issue-at-point)))
    (unless issue
      (user-error "No issue at point"))
    (let* ((id (plist-get issue :id))
           (title (or (plist-get issue :title) "(untitled)")))
      (ogent-issues-bd-start
       id
       (lambda ()
         (message "Claimed %s: %s" id title)
         (ogent-gastown-cache-invalidate)
         (ogent-gastown-refresh))
       (lambda (err)
         (message "Failed to claim %s: %s" id err))))))

(defun ogent-gastown-issue-block ()
  "Add a blocking dependency to the issue at point.
Prompts for the blocker issue ID."
  (interactive)
  (let ((issue (ogent-gastown--issue-at-point)))
    (unless issue
      (user-error "No issue at point"))
    (let* ((id (plist-get issue :id))
           (title (or (plist-get issue :title) "(untitled)"))
           (blocker (read-string (format "Blocker ID for %s (%s): " id title))))
      (when (and blocker (not (string-empty-p blocker)))
        (ogent-issues-bd-dep-add
         id blocker
         (lambda ()
           (message "%s now blocked by %s" id blocker)
           (ogent-gastown-cache-invalidate)
           (ogent-gastown-refresh))
         (lambda (err)
           (message "Failed to add dependency: %s" err)))))))

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

;;; Sling (Work Dispatch)

(defun ogent-gastown--bead-id-at-point ()
  "Get bead ID from context at point, or nil.
Checks text properties first, then magit section values."
  (or
   ;; Text property (on clickable bead links)
   (get-text-property (point) 'ogent-bead-id)
   ;; Section value properties
   (when (ogent-gastown--magit-usable-p)
     (let ((section (magit-current-section)))
       (when (and section (slot-boundp section 'value))
         (let ((value (oref section value)))
           (when (listp value)
             (or (plist-get value :hooked_work)
                 (plist-get value :current_task)
                 (plist-get value :id)))))))))

(defun ogent-gastown--sling-target-at-point ()
  "Get sling target address from section at point, or nil.
Returns a rig/role/name address suitable for `gt sling'."
  (when (ogent-gastown--magit-usable-p)
    (let ((section (magit-current-section)))
      (when (and section (slot-boundp section 'value))
        (let ((class (eieio-object-class-name section))
              (value (oref section value)))
          (cond
           ;; Crew member → rig/crew/name
           ((eq class 'ogent-gastown-crew-item-section)
            (let ((rig (plist-get value :rig))
                  (name (plist-get value :name)))
              (when (and rig name)
                (format "%s/crew/%s" rig name))))
           ;; Polecat → rig/polecats/name
           ((eq class 'ogent-gastown-polecat-item-section)
            (let ((rig (plist-get value :rig))
                  (name (plist-get value :name)))
              (when (and rig name)
                (format "%s/polecats/%s" rig name))))
           ;; Rig → just the rig name (auto-spawns polecat)
           ((eq class 'ogent-gastown-rig-item-section)
            (plist-get value :name))
           ;; Witness → rig/witness/
           ((eq class 'ogent-gastown-witness-item-section)
            (let ((rig (plist-get value :rig)))
              (when rig
                (format "%s/witness/" rig))))
           (t nil)))))))

(defun ogent-gastown--get-sling-targets ()
  "Get list of sling targets for completion.
Builds from rigs, crew, and polecats."
  (let ((targets nil))
    ;; Add rig names (auto-spawn polecat)
    (dolist (rig ogent-gastown--rigs-data)
      (let ((name (plist-get rig :name)))
        (when name (push name targets))))
    ;; Add crew and polecats (reuse mail recipients logic)
    (dolist (member ogent-gastown--crew-data)
      (let ((rig (plist-get member :rig))
            (name (plist-get member :name)))
        (when (and rig name)
          (push (format "%s/crew/%s" rig name) targets))))
    (dolist (polecat ogent-gastown--polecat-data)
      (let ((rig (plist-get polecat :rig))
            (name (plist-get polecat :name)))
        (when (and rig name)
          (push (format "%s/polecats/%s" rig name) targets))))
    (sort (delete-dups targets) #'string<)))

(defun ogent-gastown-sling ()
  "Sling (dispatch) a bead to a target agent.
Context-sensitive:
- On a crew/polecat/rig item: pre-fills target, prompts for bead-id.
- On a bead link: pre-fills bead-id, prompts for target.
- Otherwise: prompts for both."
  (interactive)
  (let* ((ctx-bead (ogent-gastown--bead-id-at-point))
         (ctx-target (ogent-gastown--sling-target-at-point))
         (bead-id (or ctx-bead
                      (read-string "Bead ID to sling: ")))
         (target (or ctx-target
                     (completing-read "Sling to: "
                                      (ogent-gastown--get-sling-targets)
                                      nil nil))))
    (when (or (string-empty-p bead-id) (string-empty-p target))
      (user-error "Both bead ID and target are required"))
    (message "Slinging %s → %s ..." bead-id target)
    (ogent-gastown-status--run-async
     (list "sling" bead-id target)
     (lambda (_result)
       (message "Slung %s → %s" bead-id target)
       (ogent-gastown-cache-invalidate)
       (ogent-gastown-refresh))
     (lambda (err)
       (message "Sling failed: %s" err))
     t)))

(defun ogent-gastown-convoy-status ()
  "Inspect convoy at point, or prompt for a convoy ID.
Opens the dedicated convoy inspector buffer.  When point is on a
convoy item section, inspects that convoy directly.  Otherwise,
prompts with `completing-read' from the current convoy list."
  (interactive)
  (let ((convoy-id (when (ogent-gastown--magit-usable-p)
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
  (let ((rig (when (ogent-gastown--magit-usable-p)
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

(autoload 'ogent-agent-detail-inspect "ogent-agent-detail" nil t)

(defun ogent-gastown-crew-status (&optional raw)
  "Show crew member status.
With prefix arg RAW (\\[universal-argument]), show raw shell output."
  (interactive "P")
  (let ((crew-name (when (ogent-gastown--magit-usable-p)
                     (let ((section (magit-current-section)))
                       (when (eq (eieio-object-class-name section)
                                 'ogent-gastown-crew-item-section)
                         (plist-get (oref section value) :name)))))
        (rig-name (ogent-gastown--sync-selected-rig)))
    (cond
     ((and crew-name (not raw))
      (ogent-agent-detail-inspect crew-name 'crew rig-name))
     (crew-name
      (ogent-gastown-status--run-shell-command
       (list "crew" "status" crew-name)
       "*gt crew*"))
     (t
      (ogent-gastown-status--run-shell-command
       (if rig-name
           (list "crew" "list" "--rig" rig-name)
         '("crew" "list" "--all"))
       "*gt crew*")))))

(defun ogent-gastown-polecat-status (&optional raw)
  "Show polecat status.
With prefix arg RAW (\\[universal-argument]), show raw shell output."
  (interactive "P")
  (let ((polecat-name (when (ogent-gastown--magit-usable-p)
                        (let ((section (magit-current-section)))
                          (when (eq (eieio-object-class-name section)
                                    'ogent-gastown-polecat-item-section)
                            (plist-get (oref section value) :name)))))
        (rig-name (ogent-gastown--sync-selected-rig)))
    (cond
     ((and polecat-name (not raw))
      (ogent-agent-detail-inspect polecat-name 'polecat rig-name))
     (polecat-name
      (ogent-gastown-status--run-shell-command
       (list "polecat" "status" polecat-name)
       "*gt polecat*"))
     (t
      (ogent-gastown-status--run-shell-command
       (if rig-name
           (list "polecat" "list" rig-name)
         '("polecat" "list" "--all"))
       "*gt polecat*")))))

(defun ogent-gastown-rig-status ()
  "Show rig status."
  (interactive)
  (let ((rig-name (when (ogent-gastown--magit-usable-p)
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
  (let ((rig-name (when (ogent-gastown--magit-usable-p)
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
  (when (ogent-gastown--magit-usable-p)
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

;;; Bead Creation

(defun ogent-gastown-bead-create ()
  "Create a new bead from the status buffer.
Prompts for title, type, and priority.  If point is on an agent
section, offers to scope creation to that agent's rig."
  (interactive)
  (let* ((rig-name (or (ogent-gastown--rig-at-point)
                       (ogent-gastown--sync-selected-rig)
                       (completing-read
                        "Rig: "
                        (mapcar (lambda (r) (plist-get r :name))
                                ogent-gastown--rigs-data))))
         (rig-path (when rig-name
                     (expand-file-name rig-name ogent-gastown--town-root)))
         (title (read-string "Bead title: "))
         (type (completing-read "Type: " '("task" "bug" "feature" "epic" "chore")
                                nil t nil nil "task"))
         (priority-label (completing-read "Priority: "
                                          '("P0 (critical)" "P1 (high)"
                                            "P2 (normal)" "P3 (low)")
                                          nil t nil nil "P2 (normal)"))
         (priority (string-to-number (substring priority-label 1 2))))
    (when (string-empty-p (string-trim title))
      (user-error "Bead title cannot be empty"))
    (unless (and rig-path (file-directory-p rig-path))
      (user-error "Rig directory not found: %s" rig-name))
    (let ((default-directory rig-path))
      (ogent-issues-bd-create
       title
       (lambda (result)
         (let ((id (if (listp result)
                       (or (plist-get (if (plistp result) result (car result)) :id)
                           (plist-get (if (plistp result) result (car result)) :ID))
                     "?")))
           (message "Created bead %s: %s" id title))
         (ogent-gastown-cache-invalidate)
         (ogent-gastown-refresh))
       :type type
       :priority priority
       :error-callback
       (lambda (err)
         (message "Failed to create bead: %s" err))))))

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
      "g:refresh  m:mail  o:hook  S:sling  c:convoy  "
      "H/L:cycle-rig  "
      "r:rig  f:refinery  s:stats  d:deacon  w:witness  i:issues  ?:help  q:quit"
      "  Workspace:" workspace
      "  Reopen from a town directory or set GT_ROOT/GT_TOWN"))))

;;; Refresh

(defun ogent-gastown--ensure-magit-root-section ()
  "Ensure magit buffers have a root section before async refresh work.
Without this, `magit-section-post-command-hook' can run against a status
buffer that has no root section yet and signal type errors."
  (when (and (ogent-gastown--magit-usable-p)
             (derived-mode-p 'magit-section-mode)
             (boundp 'magit-root-section)
             (null magit-root-section))
    (let ((inhibit-read-only t)
          (pos (point)))
      (erase-buffer)
      (ogent-gastown--insert-buffer-contents)
      (goto-char (min pos (point-max))))))

(defun ogent-gastown--render-buffer ()
  "Render status sections while preserving point."
  (let ((inhibit-read-only t)
        (pos (point)))
    (erase-buffer)
    (ogent-gastown--insert-buffer-contents)
    (goto-char (min pos (point-max)))))

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
           (ogent-gastown--render-buffer))))
     (lambda (_slot _value _err)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           ;; Deferred updates repaint only after first paint has completed.
           (unless ogent-gastown--loading
             (ogent-gastown--render-buffer))))))))

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
  (ogent-gastown--refresh-magit-availability)
  (ogent-gastown--ensure-status-mode-definition)
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
        (unless (equal ogent-gastown--town-root workspace-dir)
          (setq-local ogent-gastown--selected-rig nil))
        (setq-local ogent-gastown--town-root workspace-dir)
        (setq-local default-directory workspace-dir)
        (ogent-gastown-refresh))
      (switch-to-buffer buf))))

;;; Auto-Refresh Mode

;; Forward-declare the minor-mode variable so the byte-compiler knows about
;; it before `define-minor-mode' creates it later in this section.
(defvar ogent-gastown-auto-refresh-mode)

(defun ogent-gastown--auto-refresh-snapshot-data ()
  "Capture a snapshot of current buffer data for change detection.
Returns an alist of (KEY . FINGERPRINT) pairs."
  (list
   (cons 'mail-count (length ogent-gastown--mail-data))
   (cons 'mail-ids (mapcar (lambda (m) (plist-get m :id)) ogent-gastown--mail-data))
   (cons 'convoy-progress
         (mapcar (lambda (c)
                   (cons (plist-get c :id)
                         (ogent-gastown--convoy-progress-string c)))
                 ogent-gastown--convoy-data))
   (cons 'worker-states
         (mapcar (lambda (w)
                   (cons (plist-get w :name)
                         (plist-get w :state)))
                 ogent-gastown--workers-data))
   (cons 'polecat-states
         (mapcar (lambda (p)
                   (cons (plist-get p :name)
                         (list (plist-get p :state)
                               (plist-get p :session_running)
                               (plist-get p :hooked_work))))
                 ogent-gastown--polecat-data))
   (cons 'crew-states
         (mapcar (lambda (c)
                   (cons (plist-get c :name)
                         (list (plist-get c :session_running)
                               (plist-get c :hooked_work))))
                 ogent-gastown--crew-data))
   (cons 'hook-data
         (when ogent-gastown--hook-data
           (plist-get ogent-gastown--hook-data :has_work)))))

(defun ogent-gastown--auto-refresh-diff (old-snap new-snap)
  "Compare OLD-SNAP and NEW-SNAP, return list of changed section keys."
  (let ((changed nil))
    (dolist (new-entry new-snap)
      (let* ((key (car new-entry))
             (new-val (cdr new-entry))
             (old-val (alist-get key old-snap)))
        (unless (equal old-val new-val)
          (push (pcase key
                  ((or 'mail-count 'mail-ids) 'mail)
                  ('convoy-progress 'convoy)
                  ('worker-states 'workers)
                  ('polecat-states 'polecats)
                  ('crew-states 'crew)
                  ('hook-data 'hook)
                  (_ key))
                changed))))
    (delete-dups changed)))

(defun ogent-gastown--highlight-section (section-key)
  "Apply a transient change highlight to lines belonging to SECTION-KEY."
  (save-excursion
    (goto-char (point-min))
    (let ((section-name (pcase section-key
                          ('mail "Mail")
                          ('convoy "Convoy")
                          ('workers "Workers")
                          ('polecats "Polecats")
                          ('crew "Crew")
                          ('hook "Hook")
                          (_ nil))))
      (when section-name
        (when (re-search-forward
               (concat "^[[:space:]]*[^ \t\n].*" (regexp-quote section-name))
               nil t)
          (let* ((section-start (line-beginning-position))
                 ;; Find the end: next section heading or end of buffer
                 (section-end (save-excursion
                                (forward-line 1)
                                (if (re-search-forward "^[^ \t\n]" nil t)
                                    (line-beginning-position)
                                  (point-max))))
                 (ov (make-overlay section-start section-end)))
            (overlay-put ov 'face 'ogent-gastown-changed)
            (overlay-put ov 'ogent-gastown-change t)
            (let ((timer (run-at-time ogent-gastown-auto-refresh-highlight-duration nil
                                      (lambda ()
                                        (when (overlay-buffer ov)
                                          (delete-overlay ov))))))
              (push (cons ov timer) ogent-gastown--change-overlays))))))))

(defun ogent-gastown--clear-change-overlays ()
  "Remove all change-highlight overlays and cancel their fade timers."
  (dolist (entry ogent-gastown--change-overlays)
    (let ((ov (car entry))
          (timer (cdr entry)))
      (when timer (cancel-timer timer))
      (when (overlay-buffer ov)
        (delete-overlay ov))))
  (setq ogent-gastown--change-overlays nil))

(defun ogent-gastown--auto-refresh-tick (buf)
  "Timer callback: refresh status buffer BUF if conditions are met."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and ogent-gastown-auto-refresh-mode
                 ;; Only refresh when buffer is visible
                 (get-buffer-window buf t)
                 ;; Don't refresh during minibuffer input
                 (not (minibufferp (window-buffer (selected-window)))))
        ;; Snapshot current state before refresh
        (let ((pre-snapshot (ogent-gastown--auto-refresh-snapshot-data)))
          (setq ogent-gastown--auto-refresh-snapshot pre-snapshot))
        ;; Invalidate cache so we get fresh data
        (ogent-gastown-cache-invalidate)
        ;; Run the actual refresh with a post-refresh hook for highlighting
        (let ((snapshot ogent-gastown--auto-refresh-snapshot)
              (first-load ogent-gastown--auto-refresh-first-load))
          (ogent-gastown--ensure-magit-root-section)
          (ogent-gastown--start-loading)
          (ogent-gastown--fetch-all
           (lambda ()
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (ogent-gastown--stop-loading)
                 (ogent-gastown--render-buffer)
                 ;; Highlight changes (skip first load)
                 (unless first-load
                   (let* ((post-snapshot (ogent-gastown--auto-refresh-snapshot-data))
                          (changed (ogent-gastown--auto-refresh-diff snapshot post-snapshot)))
                     (ogent-gastown--clear-change-overlays)
                     (dolist (section changed)
                       (ogent-gastown--highlight-section section))))
                 (setq ogent-gastown--auto-refresh-first-load nil))))
           (lambda (_slot _value _err)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (unless ogent-gastown--loading
                   (ogent-gastown--render-buffer)))))))))))

(defun ogent-gastown--auto-refresh-start ()
  "Start the auto-refresh timer for the current buffer."
  (ogent-gastown--auto-refresh-stop)
  (setq ogent-gastown--auto-refresh-first-load t)
  (setq ogent-gastown--auto-refresh-timer
        (run-at-time ogent-gastown-auto-refresh-interval
                     ogent-gastown-auto-refresh-interval
                     #'ogent-gastown--auto-refresh-tick
                     (current-buffer))))

(defun ogent-gastown--auto-refresh-stop ()
  "Stop the auto-refresh timer for the current buffer."
  (when ogent-gastown--auto-refresh-timer
    (cancel-timer ogent-gastown--auto-refresh-timer)
    (setq ogent-gastown--auto-refresh-timer nil))
  (ogent-gastown--clear-change-overlays)
  (setq ogent-gastown--auto-refresh-snapshot nil)
  (setq ogent-gastown--auto-refresh-first-load t))

;;;###autoload
(define-minor-mode ogent-gastown-auto-refresh-mode
  "Periodically auto-refresh the Gas Town status buffer.
When enabled, refreshes every `ogent-gastown-auto-refresh-interval'
seconds and highlights changed sections with a transient pulse.

Only refreshes when the buffer is visible and the minibuffer is not
active."
  :lighter " AutoRef"
  :group 'ogent-gastown
  (if ogent-gastown-auto-refresh-mode
      (ogent-gastown--auto-refresh-start)
    (ogent-gastown--auto-refresh-stop)))

;;; Cleanup

(defun ogent-gastown--cleanup-on-kill ()
  "Clean up timers when the buffer is killed."
  (ogent-gastown--stop-loading-timer)
  (ogent-gastown--auto-refresh-stop))

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
