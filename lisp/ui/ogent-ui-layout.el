;;; ogent-ui-layout.el --- Native window-aware presentation -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep owned reader buffers readable without imposing a global theme,
;; font, completion system, or window configuration.

;;; Code:

(require 'subr-x)
(require 'hl-line)
(require 'ogent-ui-theme)

(defgroup ogent-ui-layout nil
  "Native layout for ogent reader buffers."
  :group 'ogent)

(defcustom ogent-ui-layout-line-spacing 0.12
  "Extra line spacing in owned ogent reader buffers."
  :type '(choice (const :tag "Use inherited spacing" nil) number)
  :group 'ogent-ui-layout)

(defun ogent-ui-layout-width ()
  "Return the width of the window displaying the current buffer."
  (if-let ((windows (get-buffer-window-list (current-buffer) nil t)))
      (apply #'min (mapcar #'window-body-width windows))
    (window-body-width (selected-window))))

(defun ogent-ui-layout-configure ()
  "Configure local reader spacing and preserve long text by wrapping."
  (when ogent-ui-layout-line-spacing
    (setq-local line-spacing ogent-ui-layout-line-spacing))
  (setq-local truncate-lines nil)
  (setq-local truncate-partial-width-windows nil)
  (setq-local word-wrap t)
  (when (derived-mode-p 'tabulated-list-mode)
    (hl-line-mode 1)))

(defun ogent-ui-layout-insert-text (text &optional indent)
  "Insert TEXT wrapped to the current window with optional INDENT.
Preserve text properties and avoid introducing hard line breaks in
stored records; this helper only inserts into presentation buffers."
  (let ((start (point))
        (fill-column (max 20 (- (ogent-ui-layout-width) 4)))
        (fill-prefix (or indent "  ")))
    (insert fill-prefix text "\n")
    (fill-region start (point))))

(defun ogent-ui-layout-header (title context hints)
  "Return a width-aware header with TITLE, CONTEXT and HINTS.
Keep the first hint accessible and shorten context before dropping
secondary hints.  HINTS is a list of (KEY . DESCRIPTION) pairs."
  (let* ((width (max 1 (1- (ogent-ui-layout-width))))
         (label (propertize (concat " " title) 'face 'ogent-theme-header-line))
         (keys (apply #'ogent-theme-keys hints)))
    (while (and (cdr hints)
                (> (+ (string-width label) 3 (string-width keys)) width))
      (setq hints (butlast hints)
            keys (apply #'ogent-theme-keys hints)))
    (let* ((room (- width (string-width label) (string-width keys) 6))
           (detail (when (and context (not (string-empty-p context)) (> room 3))
                     (concat (if ogent-theme-use-unicode " · " " / ")
                             (truncate-string-to-width context room nil nil
                                                       (if ogent-theme-use-unicode "…" "~"))))))
      (truncate-string-to-width
       (concat label
               (when detail (propertize detail 'face 'ogent-theme-muted))
               (when hints (concat "   " keys)))
       width))))

(provide 'ogent-ui-layout)
;;; ogent-ui-layout.el ends here
