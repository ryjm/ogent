;;; ogent-ui-theme.el --- Unified design system for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A native design system for ogent that inherits the user's theme.
;; Provides:
;;
;; - Semantic color palette with light/dark theme support
;; - Icon system with nerd-icons fallback to Unicode/ASCII
;; - Consistent face hierarchy for all ogent components
;; - Visual feedback utilities (flash, pulse, notifications)
;; - Progress indicators and badges
;;
;; Design Principles:
;; 1. Consistency - Same colors/icons mean same things everywhere
;; 2. Hierarchy - Visual weight guides attention
;; 3. Feedback - Every action has visible response
;; 4. Accessibility - Works in terminal, respects user themes
;;
;; Division of labor across the ogent style stack:
;; - `ogent-ops-style'   - plain symbol/spinner tables (status, priority,
;;                         activity glyph lookups) with no face knowledge.
;; - `ogent-ui-theme'    - faces, icons, and visual feedback (this file).
;; - `ogent-ui-section'  - magit-section buffer machinery (sections,
;;                         navigation, point-preserving refresh).
;;
;; Usage:
;;   (require 'ogent-ui-theme)
;;   (ogent-theme-icon 'send)        ; Get icon for action
;;   (ogent-theme-face 'success)     ; Get semantic face
;;   (ogent-theme-flash 'success)    ; Flash mode-line green

;;; Code:

(require 'cl-lib)
(require 'face-remap)
(require 'ogent-ops-style)

;;; Customization Group

(defgroup ogent-theme nil
  "Visual theme and design system for ogent."
  :group 'ogent
  :prefix "ogent-theme-")

(defcustom ogent-theme-use-icons t
  "Whether to use icons in the UI.
When non-nil and nerd-icons is available, uses nerd-icons.
Otherwise falls back to Unicode symbols.
Set to nil for pure ASCII."
  :type 'boolean
  :group 'ogent-theme)

(defcustom ogent-theme-use-unicode t
  "Whether to use Unicode symbols when icons unavailable.
Set to nil for ASCII-only terminals."
  :type 'boolean
  :group 'ogent-theme)

(defcustom ogent-theme-flash-duration 0.3
  "Duration in seconds for visual flash effects."
  :type 'number
  :group 'ogent-theme)

(defcustom ogent-theme-animation-speed 'normal
  "Speed of UI animations.
Options: `fast', `normal', `slow', or `none'."
  :type '(choice (const :tag "Fast (0.15s)" fast)
                 (const :tag "Normal (0.25s)" normal)
                 (const :tag "Slow (0.4s)" slow)
                 (const :tag "Disabled" none))
  :group 'ogent-theme)

;;; Semantic faces
;; Inherit the user's palette so Modus, Doom and terminal themes retain
;; their own contrast and color-deficiency choices.

(defface ogent-theme-primary
  '((t :inherit link :weight bold))
  "Primary actions and focus."
  :group 'ogent-theme)

(defface ogent-theme-secondary
  '((t :inherit font-lock-type-face))
  "Supporting semantic information."
  :group 'ogent-theme)

(defface ogent-theme-success
  '((t :inherit success :weight bold))
  "Completed and confirmed states."
  :group 'ogent-theme)

(defface ogent-theme-success-bg
  '((t :inherit success :inverse-video t))
  "Completion feedback."
  :group 'ogent-theme)

(defface ogent-theme-warning
  '((t :inherit warning :weight bold))
  "States requiring attention."
  :group 'ogent-theme)

(defface ogent-theme-warning-bg
  '((t :inherit warning :inverse-video t))
  "Attention feedback."
  :group 'ogent-theme)

(defface ogent-theme-error
  '((t :inherit error :weight bold))
  "Failed and destructive states."
  :group 'ogent-theme)

(defface ogent-theme-error-bg
  '((t :inherit error :inverse-video t))
  "Failure feedback."
  :group 'ogent-theme)

(defface ogent-theme-info
  '((t :inherit font-lock-doc-face))
  "Neutral supporting information."
  :group 'ogent-theme)

(defface ogent-theme-muted
  '((t :inherit shadow))
  "Secondary context."
  :group 'ogent-theme)

(defface ogent-theme-highlight
  '((t :inherit font-lock-constant-face :weight bold))
  "Selected and special values."
  :group 'ogent-theme)

(defface ogent-theme-key
  '((t :inherit help-key-binding :weight bold))
  "Discoverable keyboard actions."
  :group 'ogent-theme)

(defface ogent-theme-badge
  '((t :inherit font-lock-constant-face))
  "Small labels and counts."
  :group 'ogent-theme)

(defface ogent-theme-section-heading
  '((t :inherit bold))
  "Section structure."
  :group 'ogent-theme)

(defface ogent-theme-header-line
  '((t :inherit header-line :weight bold))
  "Current surface identity."
  :group 'ogent-theme)

(defface ogent-theme-title
  '((t :inherit bold :height 1.25))
  "Primary surface title."
  :group 'ogent-theme)

;;; Icon System
;;
;; Hierarchical icon lookup: nerd-icons -> Unicode -> ASCII

(defvar ogent-theme--nerd-icons-available
  (and (require 'nerd-icons nil t)
       (fboundp 'nerd-icons-mdicon))
  "Non-nil if nerd-icons is available.")

(declare-function nerd-icons-mdicon "ext:nerd-icons" t t)

(defconst ogent-theme-icons
  '(;; Actions
    (send        . (:nerd "nf-md-send"           :unicode "➤"  :ascii ">"))
    (cancel      . (:nerd "nf-md-close"          :unicode "✕"  :ascii "x"))
    (refresh     . (:nerd "nf-md-refresh"        :unicode "↻"  :ascii "R"))
    (settings    . (:nerd "nf-md-cog"            :unicode "⚙"  :ascii "*"))
    (help        . (:nerd "nf-md-help_circle"    :unicode "?"  :ascii "?"))
    (edit        . (:nerd "nf-md-pencil"         :unicode "✎"  :ascii "E"))
    (save        . (:nerd "nf-md-content_save"   :unicode "⇓"  :ascii "S"))
    (pin         . (:nerd "nf-md-pin"            :unicode "☰"  :ascii "P"))
    (unpin       . (:nerd "nf-md-pin_off"        :unicode "📍" :ascii "U"))
    
    ;; Status
    (success     . (:nerd "nf-md-check_circle"   :unicode "✓"  :ascii "+"))
    (error       . (:nerd "nf-md-close_circle"   :unicode "✗"  :ascii "!"))
    (warning     . (:nerd "nf-md-alert"          :unicode "⚠"  :ascii "!"))
    (info        . (:nerd "nf-md-information"    :unicode "ℹ"  :ascii "i"))
    (pending     . (:nerd "nf-md-clock_outline"  :unicode "○"  :ascii "o"))
    (running     . (:nerd "nf-md-loading"        :unicode "◐"  :ascii "*"))
    (done        . (:nerd "nf-md-check"          :unicode "✓"  :ascii "+"))
    (blocked     . (:nerd "nf-md-block_helper"   :unicode "⊘"  :ascii "X"))
    
    ;; Objects
    (file        . (:nerd "nf-md-file"           :unicode "≡"  :ascii "F"))
    (folder      . (:nerd "nf-md-folder"         :unicode "▸"  :ascii "D"))
    (code        . (:nerd "nf-md-code_tags"      :unicode "⟨⟩" :ascii "<>"))
    (terminal    . (:nerd "nf-md-console"        :unicode "⌨"  :ascii "$"))
    (model       . (:nerd "nf-md-robot"          :unicode "◈"  :ascii "@"))
    (context     . (:nerd "nf-md-text_box"       :unicode "📋" :ascii "C"))
    (session     . (:nerd "nf-md-history"        :unicode "📜" :ascii "H"))
    (issue       . (:nerd "nf-md-checkbox_marked":unicode "☑"  :ascii "[x]"))
    (bug         . (:nerd "nf-md-bug"            :unicode "⚑"  :ascii "B"))
    (feature     . (:nerd "nf-md-star"           :unicode "★"  :ascii "*"))
    (task        . (:nerd "nf-md-checkbox_blank" :unicode "☐"  :ascii "[ ]"))
    (epic        . (:nerd "nf-md-flag"           :unicode "🚩" :ascii "E"))
    
    ;; Navigation
    (expand      . (:nerd "nf-md-chevron_down"   :unicode "▼"  :ascii "v"))
    (collapse    . (:nerd "nf-md-chevron_right"  :unicode "▶"  :ascii ">"))
    (next        . (:nerd "nf-md-arrow_down"     :unicode "↓"  :ascii "v"))
    (prev        . (:nerd "nf-md-arrow_up"       :unicode "↑"  :ascii "^"))
    (link        . (:nerd "nf-md-link"           :unicode "🔗" :ascii "->"))
    
    ;; Priority
    (priority-0  . (:nerd "nf-md-fire"           :unicode "🔥" :ascii "!!!"))
    (priority-1  . (:nerd "nf-md-alert_circle"   :unicode "●"  :ascii "!!"))
    (priority-2  . (:nerd "nf-md-circle_outline" :unicode "◐"  :ascii "!"))
    (priority-3  . (:nerd "nf-md-circle_outline" :unicode "○"  :ascii "."))
    
    ;; Tools
    (tool        . (:nerd "nf-md-wrench"         :unicode "🔧" :ascii "T"))
    (bash        . (:nerd "nf-md-console"        :unicode "$"  :ascii "$"))
    (read        . (:nerd "nf-md-eye"            :unicode "👁"  :ascii "R"))
    (write       . (:nerd "nf-md-pencil"         :unicode "✏"  :ascii "W"))
    (search      . (:nerd "nf-md-magnify"        :unicode "🔍" :ascii "?"))
    
    ;; Streaming animation frames
    (stream-0    . (:nerd "nf-md-loading"        :unicode "◐"  :ascii "|"))
    (stream-1    . (:nerd "nf-md-loading"        :unicode "◑"  :ascii "/"))
    (stream-2    . (:nerd "nf-md-loading"        :unicode "◒"  :ascii "-"))
    (stream-3    . (:nerd "nf-md-loading"        :unicode "◓"  :ascii "\\")))
  "Icon definitions with nerd-icons, Unicode, and ASCII fallbacks.")

(defun ogent-theme-icon (name &optional face)
  "Return the icon string for NAME, optionally with FACE.
Looks up in `ogent-theme-icons' and returns appropriate variant
based on `ogent-theme-use-icons' and `ogent-theme-use-unicode'."
  (let* ((entry (alist-get name ogent-theme-icons))
         (icon (cond
                ;; Try nerd-icons first
                ((and ogent-theme-use-icons
                      ogent-theme--nerd-icons-available
                      (plist-get entry :nerd))
                 (condition-case nil
                     (nerd-icons-mdicon (plist-get entry :nerd))
                   (error (plist-get entry :unicode))))
                ;; Fall back to Unicode
                ((and ogent-theme-use-unicode
                      (plist-get entry :unicode))
                 (plist-get entry :unicode))
                ;; ASCII fallback
                (t (or (plist-get entry :ascii) "?")))))
    (if face
        (propertize icon 'face face)
      icon)))

(defun ogent-theme-icon-with-text (name text &optional face separator)
  "Return icon for NAME followed by TEXT with optional FACE.
SEPARATOR defaults to a single space."
  (concat (ogent-theme-icon name face)
          (or separator " ")
          (if face (propertize text 'face face) text)))

;;; Semantic Face Lookup

(defun ogent-theme-face (semantic-name)
  "Return the face symbol for SEMANTIC-NAME.
SEMANTIC-NAME is one of: primary, secondary, success, warning,
error, info, muted, highlight, key, badge, heading, header."
  (intern (format "ogent-theme-%s" semantic-name)))

;;; Visual Feedback System

(defvar ogent-theme--flash-overlay nil
  "Overlay used for flash effects.")

(defvar ogent-theme--flash-timer nil
  "Timer for clearing flash effects.")

(defvar ogent-theme--flash-cookie nil
  "Face remapping cookie for mode-line flash.")

(cl-defun ogent-theme-flash (type &optional message)
  "Flash the mode-line with TYPE color and optional MESSAGE.
TYPE is one of: `success', `warning', `error', `info'.
The flash lasts for `ogent-theme-flash-duration' seconds."
  (when (eq ogent-theme-animation-speed 'none)
    (when message (message "%s" message))
    (cl-return-from ogent-theme-flash))
  (let ((face (pcase type
                ('success 'ogent-theme-success-bg)
                ('warning 'ogent-theme-warning-bg)
                ('error 'ogent-theme-error-bg)
                (_ 'ogent-theme-info))))
    ;; Cancel any existing flash
    (ogent-theme--clear-flash)
    ;; Apply face remapping to mode-line
    (setq ogent-theme--flash-cookie
          (face-remap-add-relative 'mode-line face))
    ;; Show message if provided
    (when message
      (message "%s %s"
               (ogent-theme-icon (pcase type
                                   ('success 'success)
                                   ('warning 'warning)
                                   ('error 'error)
                                   (_ 'info))
                                 face)
               message))
    ;; Force redisplay
    (force-mode-line-update t)
    ;; Set timer to clear
    (setq ogent-theme--flash-timer
          (run-with-timer ogent-theme-flash-duration nil
                          #'ogent-theme--clear-flash))))

(defun ogent-theme--clear-flash ()
  "Clear any active flash effect."
  (when ogent-theme--flash-timer
    (cancel-timer ogent-theme--flash-timer)
    (setq ogent-theme--flash-timer nil))
  (when ogent-theme--flash-cookie
    (face-remap-remove-relative ogent-theme--flash-cookie)
    (setq ogent-theme--flash-cookie nil)
    (force-mode-line-update t)))

(cl-defun ogent-theme-pulse-line (&optional face)
  "Briefly highlight the current line with FACE.
Defaults to `ogent-theme-highlight'."
  (when (eq ogent-theme-animation-speed 'none)
    (cl-return-from ogent-theme-pulse-line))
  (let* ((ov (make-overlay (line-beginning-position) (1+ (line-end-position))))
         (face (or face 'ogent-theme-highlight))
         (duration (pcase ogent-theme-animation-speed
                     ('fast 0.15)
                     ('slow 0.4)
                     (_ 0.25))))
    (overlay-put ov 'face face)
    (overlay-put ov 'priority 100)
    (run-with-timer duration nil #'delete-overlay ov)))

;;; Progress Indicators

(defconst ogent-theme-progress-chars
  '(:filled "█" :partial "▓" :empty "░" :ascii-filled "#" :ascii-empty "-")
  "Characters for progress bar rendering.")

(defun ogent-theme-progress-bar (percent &optional width face)
  "Return a progress bar string for PERCENT (0-100).
WIDTH defaults to 10 characters.  FACE colors the filled portion."
  (let* ((width (or width 10))
         (filled-width (round (* width (/ (min 100 (max 0 percent)) 100.0))))
         (empty-width (- width filled-width))
         (filled-char (if ogent-theme-use-unicode
                          (plist-get ogent-theme-progress-chars :filled)
                        (plist-get ogent-theme-progress-chars :ascii-filled)))
         (empty-char (if ogent-theme-use-unicode
                         (plist-get ogent-theme-progress-chars :empty)
                       (plist-get ogent-theme-progress-chars :ascii-empty)))
         (filled-str (make-string filled-width (string-to-char filled-char)))
         (empty-str (make-string empty-width (string-to-char empty-char))))
    (concat
     (if face (propertize filled-str 'face face) filled-str)
     (propertize empty-str 'face 'ogent-theme-muted))))

(defun ogent-theme-progress-face (percent)
  "Return appropriate face for PERCENT completion.
Green for <70%, yellow for 70-90%, red for >90%."
  (cond
   ((< percent 70) 'ogent-theme-success)
   ((< percent 90) 'ogent-theme-warning)
   (t 'ogent-theme-error)))

;;; Badges and Tags

(defun ogent-theme-badge (text &optional face)
  "Return TEXT formatted as a badge with optional FACE.
Use the active theme's semantic label styling."
  (propertize (format " %s " text)
              'face (or face 'ogent-theme-badge)))

(defun ogent-theme-count-badge (count &optional face)
  "Return COUNT as a small badge, hidden if zero.
FACE defaults to `ogent-theme-muted'."
  (if (and count (> count 0))
      (propertize (format "(%d)" count)
                  'face (or face 'ogent-theme-muted))
    ""))

;;; Separators and Spacing

(defun ogent-theme-separator (&optional char width)
  "Return a separator line of WIDTH using CHAR.
Defaults to thin horizontal line."
  (let ((char (or char (if ogent-theme-use-unicode "─" "-")))
        (width (or width (- (window-width) 2))))
    (propertize (make-string width (string-to-char char))
                'face 'ogent-theme-muted)))

(defconst ogent-theme-bullet
  '(:unicode "•" :ascii "-")
  "Bullet point characters.")

(defun ogent-theme-bullet ()
  "Return appropriate bullet character."
  (if ogent-theme-use-unicode
      (plist-get ogent-theme-bullet :unicode)
    (plist-get ogent-theme-bullet :ascii)))

;;; Keybinding Formatting

(defun ogent-theme-key (key &optional description)
  "Format KEY with optional DESCRIPTION for display.
KEY is highlighted, description is muted."
  (concat
   (propertize key 'face 'ogent-theme-key 'font-lock-face 'ogent-theme-key)
   (when description
     (concat (propertize ":" 'face 'ogent-theme-muted
                         'font-lock-face 'ogent-theme-muted)
             (propertize description 'face 'ogent-theme-muted
                         'font-lock-face 'ogent-theme-muted)))))

(defun ogent-theme-keys (&rest key-desc-pairs)
  "Format multiple KEY-DESC-PAIRS for display.
Each pair is (KEY . DESCRIPTION).  Return space-separated string."
  (mapconcat (lambda (pair)
               (ogent-theme-key (car pair) (cdr pair)))
             key-desc-pairs
             "  "))

;;; Animation Utilities

(defun ogent-theme-animation-interval ()
  "Return animation interval in seconds based on `ogent-theme-animation-speed'."
  (pcase ogent-theme-animation-speed
    ('fast 0.15)
    ('slow 0.4)
    ('none nil)
    (_ 0.25)))

(defun ogent-theme-stream-icon (frame)
  "Return streaming animation icon for FRAME."
  (let* ((ogent-ops-use-unicode ogent-theme-use-unicode)
         (frames (ogent-ops-streaming-frames))
         (frame-count (max 1 (length frames)))
         (icon (or (nth (mod frame frame-count) frames) "?")))
    (propertize icon 'face 'ogent-theme-warning)))

;;; Mode-line Segment Helpers

(defun ogent-theme-mode-line-segment (icon text &optional face)
  "Create a mode-line segment with ICON and TEXT.
Optional FACE applies to both."
  (let ((content (concat (ogent-theme-icon icon) " " text)))
    (if face
        (propertize content 'face face)
      content)))

;;; Initialization

(defun ogent-theme-setup ()
  "Initialize the ogent theme system.
Call this after loading ogent to ensure consistent styling."
  (interactive)
  ;; Check for nerd-icons availability
  (setq ogent-theme--nerd-icons-available
        (and (require 'nerd-icons nil t)
             (fboundp 'nerd-icons-mdicon)))
  (message "ogent-theme: icons=%s unicode=%s nerd-icons=%s"
           ogent-theme-use-icons
           ogent-theme-use-unicode
           (if ogent-theme--nerd-icons-available "available" "not found")))

(provide 'ogent-ui-theme)

;;; ogent-ui-theme.el ends here
