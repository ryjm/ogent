;;; ogent-ops-style.el --- Shared operational buffer style contract -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides shared status symbols, section heading helpers, and loading
;; animation frames for ogent's operational buffers (Gastown Status,
;; Issues, Refinery).  Each buffer wires into these helpers so the
;; visual language is consistent while remaining free to define its own
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

;;;; Section heading symbols

(defconst ogent-ops--section-symbols-unicode
  '((hook      . "⊙")
    (mail      . "▷")
    (convoy    . "▶")
    (workers   . "◆")
    (stats     . "≡")
    (deacon    . "◎")
    (witnesses . "◎")
    (crew      . "◇")
    (polecats  . "▸")
    (rigs      . "▣"))
  "Unicode section heading symbols for operational buffers.")

(defconst ogent-ops--section-symbols-ascii
  '((hook      . "#")
    (mail      . "@")
    (convoy    . ">")
    (workers   . "*")
    (stats     . "#")
    (deacon    . "D")
    (witnesses . "W")
    (crew      . "C")
    (polecats  . "P")
    (rigs      . "R"))
  "ASCII fallback section heading symbols.")

(defun ogent-ops-section-symbol (section)
  "Return the display symbol for SECTION.
SECTION is a symbol like `hook', `mail', `stats', `rigs', etc."
  (let ((table (if ogent-ops-use-unicode
                   ogent-ops--section-symbols-unicode
                 ogent-ops--section-symbols-ascii)))
    (or (alist-get section table) "?")))

;;;; Role symbols

(defconst ogent-ops--role-symbols-unicode
  '((witness  . "◎")
    (refinery . "▣")
    (polecat  . "▸")
    (crew     . "▪"))
  "Unicode role symbols for agent listings.")

(defconst ogent-ops--role-symbols-ascii
  '((witness  . "W")
    (refinery . "R")
    (polecat  . "P")
    (crew     . "C"))
  "ASCII fallback role symbols.")

(defun ogent-ops-role-symbol (role)
  "Return the display symbol for agent ROLE.
ROLE is a symbol like `witness', `refinery', `polecat', or `crew'."
  (let ((table (if ogent-ops-use-unicode
                   ogent-ops--role-symbols-unicode
                 ogent-ops--role-symbols-ascii)))
    (or (alist-get role table) "?")))

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

(defconst ogent-ops-loading-frames-unicode '("◐" "◑" "◒" "◓")
  "Unicode spinner frames for loading animation.")

(defconst ogent-ops-loading-frames-ascii '("|" "/" "-" "\\")
  "ASCII spinner frames for loading animation.")

(defun ogent-ops-loading-frames ()
  "Return the appropriate loading animation frame list.
Uses `display-graphic-p' to pick Unicode vs ASCII."
  (if (display-graphic-p)
      ogent-ops-loading-frames-unicode
    ogent-ops-loading-frames-ascii))

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
