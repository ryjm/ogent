;;; ogent-ui-section.el --- Shared magit-section machinery for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; ONE magit-section wrapper for every sectioned ogent buffer (Armory
;; surfaces, the zen review dashboard).  Provides:
;;
;; - Availability probing that degrades to `special-mode' when
;;   magit-section is not installed (e.g. the CI lint sandbox, which
;;   installs only Package-Requires).
;; - Section insertion macros (`ogent-section-with',
;;   `ogent-section-with-root') and a mode-defining macro
;;   (`ogent-section-define-mode').
;; - Section navigation commands (toggle/cycle/next/prev/up).
;; - Item-line plumbing parameterized over the text property that
;;   carries the item payload.
;; - `ogent-section-preserve-point' - the Magit "stay where you were"
;;   behavior for erase/reinsert refreshes.
;; - `ogent-section-header-line' - the one header-line convention.
;;
;; Division of labor across the ogent style stack:
;; - `ogent-ops-style'   - plain symbol/spinner tables.
;; - `ogent-ui-theme'    - faces, icons, and visual feedback.
;; - `ogent-ui-section'  - magit-section buffer machinery (this file).

;;; Code:

(require 'ogent-ops-style)
(require 'ogent-ui-theme)

(eval-and-compile
  (defvar ogent-section--magit-available
    (require 'magit-section nil t)
    "Non-nil when `magit-section' is available for ogent section buffers.")
  (when ogent-section--magit-available
    (require 'magit-section)))

;; Forward declarations for magit-section functions.  Without
;; magit-section (e.g. the CI lint sandbox) these keep the
;; byte-compiler from flagging call sites as undefined; the magit
;; render paths are unreachable then anyway
;; (`ogent-section-usable-p' is nil).
(declare-function magit-section-mode "ext:magit-section")
(declare-function magit-current-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-insert-section--create "ext:magit-section")
(declare-function magit-insert-section--finish "ext:magit-section")
(declare-function magit-section-backward-sibling "ext:magit-section")
(declare-function magit-section-cycle-global "ext:magit-section")
(declare-function magit-section-forward-sibling "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-section-up "ext:magit-section")
(defvar magit-section-visibility-indicator)
(defvar magit-section-visibility-indicators)
(defvar magit-insert-section--current)
(defvar magit-insert-section--oldroot)
(defvar magit-insert-section--parent)
(defvar magit-root-section)

;;; Availability

(defun ogent-section-available-p ()
  "Refresh and return `magit-section' availability."
  (setq ogent-section--magit-available
        (or ogent-section--magit-available
            (require 'magit-section nil t)))
  (when (and ogent-section--magit-available
             (not (featurep 'magit-section)))
    (require 'magit-section))
  ogent-section--magit-available)

(defun ogent-section-usable-p ()
  "Return non-nil when Magit section APIs are usable."
  (and (ogent-section-available-p)
       (fboundp 'magit-current-section)
       (fboundp 'magit-insert-heading)
       (fboundp 'magit-section-toggle)
       (fboundp 'magit-section-forward-sibling)
       (fboundp 'magit-section-backward-sibling)))

;;; Base mode

(if (ogent-section-available-p)
    (define-derived-mode ogent-section-mode magit-section-mode "Ogent Section"
      "Base mode for sectioned ogent buffers.")
  (define-derived-mode ogent-section-mode special-mode "Ogent Section"
    "Fallback base mode for sectioned ogent buffers."))

;;; Section macros

(defmacro ogent-section-with (section heading &rest body)
  "Insert collapsible SECTION with HEADING around BODY when Magit is present."
  (declare (indent 2) (debug t))
  (let ((type (car section)))
    `(if (ogent-section-usable-p)
         (let* ((section (magit-insert-section--create ',type nil nil))
                (magit-insert-section--current section)
                (magit-insert-section--oldroot
                 (or magit-insert-section--oldroot
                     (and (not magit-insert-section--parent)
                          (prog1 magit-root-section
                            (setq magit-root-section section)))))
                (magit-insert-section--parent section))
           (ignore magit-insert-section--current
                   magit-insert-section--oldroot
                   magit-insert-section--parent)
           (catch 'cancel-section
             (magit-insert-heading ,heading)
             ,@body
             (magit-insert-section--finish section))
           section)
       (insert ,heading "\n")
       ,@body)))

(defmacro ogent-section-with-root (section &rest body)
  "Insert root SECTION around BODY when Magit is present."
  (declare (indent 1) (debug t))
  (let ((type (car section)))
    `(if (ogent-section-usable-p)
         (let* ((section (magit-insert-section--create ',type nil nil))
                (magit-insert-section--current section)
                (magit-insert-section--oldroot
                 (or magit-insert-section--oldroot
                     (and (not magit-insert-section--parent)
                          (prog1 magit-root-section
                            (setq magit-root-section section)))))
                (magit-insert-section--parent section))
           (ignore magit-insert-section--current
                   magit-insert-section--oldroot
                   magit-insert-section--parent)
           (catch 'cancel-section
             ,@body
             (magit-insert-section--finish section))
           section)
       ,@body)))

(defmacro ogent-section-define-mode (mode name docstring &rest body)
  "Define section-capable MODE with NAME, DOCSTRING, and BODY.
Every generated mode derives from `ogent-section-mode', whose parent
is selected at load time from the user's runtime `magit-section'
availability."
  (declare (indent 3) (debug t))
  `(define-derived-mode ,mode ogent-section-mode ,name ,docstring
     ,@body))

;;; Navigation commands

(defun ogent-section-toggle ()
  "Toggle the section at point."
  (interactive)
  (if (ogent-section-usable-p)
      (if-let ((section (magit-current-section)))
          (condition-case err
              (magit-section-toggle section)
            (user-error (message "%s" (error-message-string err))))
        (message "No section at point"))
    (message "Section toggling requires magit-section")))

(defun ogent-section-cycle ()
  "Cycle visibility for all sections."
  (interactive)
  (if (and (ogent-section-usable-p)
           (fboundp 'magit-section-cycle-global))
      (magit-section-cycle-global)
    (message "Section cycling requires magit-section")))

(defun ogent-section-next ()
  "Move to the next sibling section."
  (interactive)
  (when (ogent-section-usable-p)
    (magit-section-forward-sibling)))

(defun ogent-section-prev ()
  "Move to the previous sibling section."
  (interactive)
  (when (ogent-section-usable-p)
    (magit-section-backward-sibling)))

(defun ogent-section-up ()
  "Move to the parent section."
  (interactive)
  (when (and (ogent-section-usable-p)
             (fboundp 'magit-section-up))
    (magit-section-up)))

;;; Buffer configuration

(defun ogent-section-configure-buffer ()
  "Configure local Magit section affordances for the current buffer."
  (when (ogent-section-usable-p)
    (let ((indicator (if ogent-ops-use-unicode
                         (cons "…" t)
                       (cons "..." t))))
      (if (boundp 'magit-section-visibility-indicators)
          (setq-local magit-section-visibility-indicators
                      (list indicator indicator))
        (with-suppressed-warnings ((obsolete magit-section-visibility-indicator))
          (setq-local magit-section-visibility-indicator indicator))))))

;;; Item-line plumbing
;;
;; Parameterized over PROP, the text property carrying the item
;; payload, so armory buffers keep `ogent-armory-item' /
;; `ogent-armory-node' and the zen review dashboard passes
;; `ogent-review-marker'.

(defun ogent-section-insert-item-line (text prop item &optional help-echo)
  "Insert TEXT as one line carrying ITEM under text-property PROP.
HELP-ECHO overrides the default mouse help string."
  (insert (propertize (concat text "\n")
                      prop item
                      'mouse-face 'highlight
                      'help-echo (or help-echo "RET visits this item"))))

(defun ogent-section-item-at-point (prop)
  "Return the PROP item on the current line, or nil."
  (get-text-property (line-beginning-position) prop))

(defun ogent-section-visible-item-position (prop direction)
  "Return the next visible position carrying PROP in DIRECTION.
DIRECTION is either `next' or `previous'."
  (let ((limit (if (eq direction 'next) (point-max) (point-min)))
        (pos (point))
        found)
    (while (and (not found)
                (if (eq direction 'next)
                    (< pos limit)
                  (> pos limit)))
      (setq pos
            (if (eq direction 'next)
                (next-single-property-change pos prop nil limit)
              (previous-single-property-change pos prop nil limit)))
      (when pos
        (when (eq direction 'previous)
          (setq pos (max (point-min) (1- pos))))
        (if (and (get-text-property pos prop)
                 (not (invisible-p pos)))
            (setq found pos)
          (setq pos (if (eq direction 'next)
                        (min (point-max) (1+ pos))
                      (max (point-min) (1- pos)))))))
    found))

;;; Point preservation

(defmacro ogent-section-preserve-point (spec &rest body)
  "Preserve point across a re-render performed by BODY.
SPEC is (ID-FN): ID-FN is called with no arguments to produce a
comparable key for the item at point (may return nil).  Before BODY
runs, the key and current line number are captured.  After BODY, the
buffer is scanned for the first line whose ID-FN value `equal's the
captured key and point moves there; when no line matches, point moves
to the captured line number clamped to the end of the buffer."
  (declare (indent 1) (debug ((form) body)))
  (let ((id-fn (car spec))
        (key (make-symbol "key"))
        (line (make-symbol "line")))
    `(let ((,key (funcall ,id-fn))
           (,line (line-number-at-pos)))
       ,@body
       (ogent-section--restore-point ,id-fn ,key ,line))))

(defun ogent-section--restore-point (id-fn key line)
  "Move point to the line whose ID-FN value equals KEY.
Fall back to LINE (clamped to the buffer) when KEY is nil or no line
matches."
  (let ((target nil))
    (when key
      (save-excursion
        (goto-char (point-min))
        (while (and (not target) (not (eobp)))
          (when (equal key (funcall id-fn))
            (setq target (line-beginning-position)))
          (forward-line 1))))
    (if target
        (goto-char target)
      (goto-char (point-min))
      (forward-line (1- (max 1 line)))
      (when (eobp)
        (goto-char (point-max))
        (forward-line 0)))))

;;; Header line

(defun ogent-section-header-line (view-label context &rest key-hints)
  "Return the standard ogent section header line.
VIEW-LABEL names the surface, CONTEXT is a short summary string (may
be nil), KEY-HINTS are (KEY . DESCRIPTION) pairs rendered with
`ogent-theme-keys'."
  (concat
   (propertize (concat " " (ogent-theme-icon 'folder) " " view-label)
               'face 'ogent-theme-header-line)
   (when (and context (not (string-empty-p context)))
     (concat (propertize " · " 'face 'ogent-theme-muted)
             (propertize context 'face 'ogent-theme-muted)))
   (when key-hints
     (concat "   "
             (apply #'ogent-theme-keys
                    (mapcar (lambda (hint)
                              ;; Accept both ("k" . "desc") and ("k" "desc").
                              (if (and (consp (cdr hint)) (stringp (cadr hint)))
                                  (cons (car hint) (cadr hint))
                                hint))
                            key-hints))))))

(provide 'ogent-ui-section)
;;; ogent-ui-section.el ends here
