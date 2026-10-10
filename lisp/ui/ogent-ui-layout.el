;;; ogent-ui-layout.el --- Native window-aware presentation -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep owned reader buffers readable without imposing a global theme,
;; font, completion system, or window configuration.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
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

(defun ogent-ui-layout--location (property position)
  "Capture PROPERTY identity and relative offset at POSITION."
  (let ((value (get-text-property position property)))
    (list value
          (when value
            (- position (or (previous-single-property-change
                             (1+ position) property nil (point-min))
                            (point-min))))
          position)))

(defun ogent-ui-layout--position (property location)
  "Resolve PROPERTY LOCATION after a reader has been rendered again."
  (let ((position (point-min)) found)
    (when (car location)
      (while (and (< position (point-max)) (not found))
        (if (equal (get-text-property position property) (car location))
            (setq found (min (+ position (cadr location))
                             (1- (next-single-property-change
                                  position property nil (point-max)))))
          (setq position (next-single-property-change
                          position property nil (point-max))))))
    (or found (min (nth 2 location) (point-max)))))

(defmacro ogent-ui-layout-preserve-location (property &rest body)
  "Run BODY preserving PROPERTY item, offset and visible viewports.
PROPERTY must identify a stable item throughout its rendered text."
  (declare (indent 1) (debug (form body)))
  (let ((prop (make-symbol "property"))
        (location (make-symbol "location"))
        (windows (make-symbol "windows")))
    `(let* ((,prop ,property)
            (,location (ogent-ui-layout--location ,prop (point)))
            (,windows (mapcar (lambda (window)
                                (list window
                                      (ogent-ui-layout--location ,prop (window-start window))))
                              (get-buffer-window-list (current-buffer) nil t))))
       ,@body
       (goto-char (ogent-ui-layout--position ,prop ,location))
       (dolist (entry ,windows)
         (when (window-live-p (car entry))
           (set-window-start (car entry)
                             (ogent-ui-layout--position ,prop (cadr entry)) t))))))

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
