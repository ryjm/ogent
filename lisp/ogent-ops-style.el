;;; ogent-ops-style.el --- Shared operational buffer style contract -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides shared status symbols, section heading helpers, and loading
;; animation frames for ogent's operational buffers (Issues, Cabinet
;; status).  Each buffer wires into these helpers so the visual
;; language is consistent while remaining free to define its own
;; domain-specific rendering.

;;; Code:

(require 'cl-lib)

;;;; Customization

(defgroup ogent-ops-style nil
  "Shared visual style for operational buffers."
  :group 'ogent
  :prefix "ogent-ops-")

(defcustom ogent-ops-use-unicode t
  "When non-nil, use Unicode symbols in operational buffers.
When nil, fall back to ASCII equivalents."
  :type 'boolean
  :group 'ogent-ops-style)

(defconst ogent-ops--loading-spinner-presets
  '((braille
     :frames ("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
     :interval 0.08)
    (braillewave
     :frames ("⠁⠂⠄⡀" "⠂⠄⡀⢀" "⠄⡀⢀⠠" "⡀⢀⠠⠐"
              "⢀⠠⠐⠈" "⠠⠐⠈⠁" "⠐⠈⠁⠂" "⠈⠁⠂⠄")
     :interval 0.1)
    (dna
     :frames ("⠋⠉⠙⠚" "⠉⠙⠚⠒" "⠙⠚⠒⠂" "⠚⠒⠂⠂"
              "⠒⠂⠂⠒" "⠂⠂⠒⠲" "⠂⠒⠲⠴" "⠒⠲⠴⠤"
              "⠲⠴⠤⠄" "⠴⠤⠄⠋" "⠤⠄⠋⠉" "⠄⠋⠉⠙")
     :interval 0.08)
    (scan
     :frames ("⠀⠀⠀⠀" "⡇⠀⠀⠀" "⣿⠀⠀⠀" "⢸⡇⠀⠀" "⠀⣿⠀⠀"
              "⠀⢸⡇⠀" "⠀⠀⣿⠀" "⠀⠀⢸⡇" "⠀⠀⠀⣿" "⠀⠀⠀⢸")
     :interval 0.07)
    (rain
     :frames ("⢁⠂⠔⠈" "⠂⠌⡠⠐" "⠄⡐⢀⠡" "⡈⠠⠀⢂" "⠐⢀⠁⠄" "⠠⠁⠊⡀"
              "⢁⠂⠔⠈" "⠂⠌⡠⠐" "⠄⡐⢀⠡" "⡈⠠⠀⢂" "⠐⢀⠁⠄" "⠠⠁⠊⡀")
     :interval 0.1)
    (scanline
     :frames ("⠉⠉⠉" "⠓⠓⠓" "⠦⠦⠦" "⣄⣄⣄" "⠦⠦⠦" "⠓⠓⠓")
     :interval 0.12)
    (pulse
     :frames ("⠀⠶⠀" "⠰⣿⠆" "⢾⣉⡷" "⣏⠀⣹" "⡁⠀⢈")
     :interval 0.18)
    (snake
     :frames ("⣁⡀" "⣉⠀" "⡉⠁" "⠉⠉" "⠈⠙" "⠀⠛" "⠐⠚" "⠒⠒"
              "⠖⠂" "⠶⠀" "⠦⠄" "⠤⠤" "⠠⢤" "⠀⣤" "⢀⣠" "⣀⣀")
     :interval 0.08)
    (sparkle
     :frames ("⡡⠊⢔⠡" "⠊⡰⡡⡘" "⢔⢅⠈⢢" "⡁⢂⠆⡍" "⢔⠨⢑⢐" "⠨⡑⡠⠊")
     :interval 0.15)
    (cascade
     :frames ("⠀⠀⠀⠀" "⠀⠀⠀⠀" "⠁⠀⠀⠀" "⠋⠀⠀⠀" "⠞⠁⠀⠀" "⡴⠋⠀⠀" "⣠⠞⠁⠀"
              "⢀⡴⠋⠀" "⠀⣠⠞⠁" "⠀⢀⡴⠋" "⠀⠀⣠⠞" "⠀⠀⢀⡴" "⠀⠀⠀⣠" "⠀⠀⠀⢀")
     :interval 0.06)
    (columns
     :frames ("⡀⠀⠀" "⡄⠀⠀" "⡆⠀⠀" "⡇⠀⠀" "⣇⠀⠀" "⣧⠀⠀" "⣷⠀⠀" "⣿⠀⠀"
              "⣿⡀⠀" "⣿⡄⠀" "⣿⡆⠀" "⣿⡇⠀" "⣿⣇⠀" "⣿⣧⠀" "⣿⣷⠀" "⣿⣿⠀"
              "⣿⣿⡀" "⣿⣿⡄" "⣿⣿⡆" "⣿⣿⡇" "⣿⣿⣇" "⣿⣿⣧" "⣿⣿⣷" "⣿⣿⣿"
              "⣿⣿⣿" "⠀⠀⠀")
     :interval 0.06)
    (orbit
     :frames ("⠃" "⠉" "⠘" "⠰" "⢠" "⣀" "⡄" "⠆")
     :interval 0.1)
    (breathe
     :frames ("⠀" "⠂" "⠌" "⡑" "⢕" "⢝" "⣫" "⣟" "⣿" "⣟" "⣫" "⢝" "⢕" "⡑" "⠌" "⠂" "⠀")
     :interval 0.1)
    (waverows
     :frames ("⠖⠉⠉⠑" "⡠⠖⠉⠉" "⣠⡠⠖⠉" "⣄⣠⡠⠖" "⠢⣄⣠⡠" "⠙⠢⣄⣠" "⠉⠙⠢⣄" "⠊⠉⠙⠢"
              "⠜⠊⠉⠙" "⡤⠜⠊⠉" "⣀⡤⠜⠊" "⢤⣀⡤⠜" "⠣⢤⣀⡤" "⠑⠣⢤⣀" "⠉⠑⠣⢤" "⠋⠉⠑⠣")
     :interval 0.09)
    (checkerboard
     :frames ("⢕⢕⢕" "⡪⡪⡪" "⢊⠔⡡" "⡡⢊⠔")
     :interval 0.25)
    (helix
     :frames ("⢌⣉⢎⣉" "⣉⡱⣉⡱" "⣉⢎⣉⢎" "⡱⣉⡱⣉"
              "⢎⣉⢎⣉" "⣉⡱⣉⡱" "⣉⢎⣉⢎" "⡱⣉⡱⣉"
              "⢎⣉⢎⣉" "⣉⡱⣉⡱" "⣉⢎⣉⢎" "⡱⣉⡱⣉"
              "⢎⣉⢎⣉" "⣉⡱⣉⡱" "⣉⢎⣉⢎" "⡱⣉⡱⣉")
     :interval 0.08)
    (fillsweep
     :frames ("⣀⣀" "⣤⣤" "⣶⣶" "⣿⣿" "⣿⣿" "⣿⣿" "⣶⣶" "⣤⣤" "⣀⣀" "⠀⠀" "⠀⠀")
     :interval 0.1)
    (diagswipe
     :frames ("⠁⠀" "⠋⠀" "⠟⠁" "⡿⠋" "⣿⠟" "⣿⡿" "⣿⣿" "⣿⣿"
              "⣾⣿" "⣴⣿" "⣠⣾" "⢀⣴" "⠀⣠" "⠀⢀" "⠀⠀" "⠀⠀")
     :interval 0.06))
  "Unicode loading spinner presets derived from unicode-animations.")

(defcustom ogent-ops-loading-spinner 'braille
  "Unicode spinner preset for loading and streaming indicators."
  :type '(choice (const :tag "braille" braille)
                 (const :tag "braillewave" braillewave)
                 (const :tag "dna" dna)
                 (const :tag "scan" scan)
                 (const :tag "rain" rain)
                 (const :tag "scanline" scanline)
                 (const :tag "pulse" pulse)
                 (const :tag "snake" snake)
                 (const :tag "sparkle" sparkle)
                 (const :tag "cascade" cascade)
                 (const :tag "columns" columns)
                 (const :tag "orbit" orbit)
                 (const :tag "breathe" breathe)
                 (const :tag "waverows" waverows)
                 (const :tag "checkerboard" checkerboard)
                 (const :tag "helix" helix)
                 (const :tag "fillsweep" fillsweep)
                 (const :tag "diagswipe" diagswipe))
  :group 'ogent-ops-style)

(defcustom ogent-ops-loading-frames-ascii '("|" "/" "-" "\\")
  "ASCII fallback spinner frames for loading and streaming indicators."
  :type '(repeat string)
  :group 'ogent-ops-style)

(defcustom ogent-ops-loading-interval-ascii 0.25
  "ASCII fallback frame interval in seconds."
  :type 'number
  :group 'ogent-ops-style)

;;;; Status symbols

(defconst ogent-ops--status-symbols-unicode
  '((open        . "○")
    (in-progress . "◐")
    (blocked     . "✗")
    (closed      . "●")
    (ready       . "»")
    (waiting     . "○")
    (processing  . "⚙")
    (failed      . "✗")
    (merged      . "✓"))
  "Unicode status symbols for operational buffers.")

(defconst ogent-ops--status-symbols-ascii
  '((open        . "o")
    (in-progress . ">")
    (blocked     . "x")
    (closed      . "*")
    (ready       . "!")
    (waiting     . "o")
    (processing  . "*")
    (failed      . "x")
    (merged      . "+"))
  "ASCII fallback status symbols for operational buffers.")

(defun ogent-ops-status-symbol (status)
  "Return the display symbol for STATUS.
STATUS is a symbol like `open', `in-progress', `blocked', `closed',
`ready', `waiting', `processing', `failed', or `merged'.
Falls back to \"?\" for unknown status values."
  (let ((table (if ogent-ops-use-unicode
                   ogent-ops--status-symbols-unicode
                 ogent-ops--status-symbols-ascii)))
    (or (alist-get status table) "?")))

;;;; Priority symbols

(defconst ogent-ops--priority-symbols-unicode
  '((0 . "●")
    (1 . "◐")
    (2 . "○")
    (3 . "◌"))
  "Unicode priority symbols (0=critical, 3=low).")

(defun ogent-ops-priority-symbol (priority)
  "Return the display symbol for PRIORITY (integer 0-3+).
In ASCII mode, returns \"P<n>\" instead."
  (let ((p (or priority 2)))
    (if ogent-ops-use-unicode
        (or (alist-get p ogent-ops--priority-symbols-unicode) "◌")
      (format "P%d" p))))

;;;; Activity indicators

(defconst ogent-ops--activity-symbols-unicode
  '((active  . "●")
    (working . "◐")
    (idle    . "○"))
  "Unicode activity indicators for workers/agents.")

(defconst ogent-ops--activity-symbols-ascii
  '((active  . ">")
    (working . "*")
    (idle    . "-"))
  "ASCII activity indicators for workers/agents.")

(defun ogent-ops-activity-symbol (state)
  "Return the display symbol for activity STATE.
STATE is one of `active', `working', or `idle'."
  (let ((table (if ogent-ops-use-unicode
                   ogent-ops--activity-symbols-unicode
                 ogent-ops--activity-symbols-ascii)))
    (or (alist-get state table) "?")))

;;;; Badge symbols

(defconst ogent-ops--badge-symbols-unicode
  '((mail . "▷")
    (hook . "⊙"))
  "Unicode badge symbols for inline indicators.")

(defconst ogent-ops--badge-symbols-ascii
  '((mail . "M:")
    (hook . "H"))
  "ASCII fallback badge symbols.")

(defun ogent-ops-badge-symbol (badge)
  "Return the display symbol for BADGE.
BADGE is a symbol like `mail' or `hook'."
  (let ((table (if ogent-ops-use-unicode
                   ogent-ops--badge-symbols-unicode
                 ogent-ops--badge-symbols-ascii)))
    (or (alist-get badge table) "?")))

;;;; Section heading helpers

(defun ogent-ops-section-prefix (unicode-icon ascii-icon)
  "Return UNICODE-ICON or ASCII-ICON based on `ogent-ops-use-unicode'."
  (if ogent-ops-use-unicode unicode-icon ascii-icon))

(defun ogent-ops-section-heading (icon label &optional count count-face)
  "Format a section heading string.
ICON is the prefix symbol (already resolved via `ogent-ops-section-prefix').
LABEL is the heading text, propertized by the caller.
COUNT, when non-nil, is appended as \" (N)\" with COUNT-FACE (or `shadow')."
  (concat
   icon " " label
   (when count
     (propertize (format " (%d)" count)
                 'face (or count-face 'shadow)))))

;;;; Loading animation

(defun ogent-ops--loading-spinner-spec ()
  "Return the configured Unicode spinner preset spec."
  (or (alist-get ogent-ops-loading-spinner ogent-ops--loading-spinner-presets)
      (alist-get 'braille ogent-ops--loading-spinner-presets)))

(defun ogent-ops-loading-frames ()
  "Return the loading animation frame list for the current environment."
  (if ogent-ops-use-unicode
      (plist-get (ogent-ops--loading-spinner-spec) :frames)
    ogent-ops-loading-frames-ascii))

(defun ogent-ops-loading-interval ()
  "Return loading animation interval in seconds for the current environment."
  (if ogent-ops-use-unicode
      (plist-get (ogent-ops--loading-spinner-spec) :interval)
    ogent-ops-loading-interval-ascii))

(defun ogent-ops-streaming-frames ()
  "Return animation frame list for streaming indicators."
  (ogent-ops-loading-frames))

(defun ogent-ops-streaming-interval ()
  "Return animation interval in seconds for streaming indicators."
  (ogent-ops-loading-interval))

;;;; Font-lock protection

(defun ogent-ops-protect-face-properties ()
  "Configure buffer-local settings to prevent font-lock from stripping faces.
Call this from mode initialization functions.  Operational buffers apply
faces via `propertize' with the `face' property; this function ensures
`font-lock-mode' does not clobber them."
  (setq-local font-lock-defaults '(nil t))
  (setq-local font-lock-unfontify-region-function
              (lambda (beg end)
                (remove-text-properties beg end '(font-lock-face nil
                                                  font-lock-multiline nil)))))

(provide 'ogent-ops-style)
;;; ogent-ops-style.el ends here
