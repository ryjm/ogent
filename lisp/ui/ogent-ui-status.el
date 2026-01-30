;;; ogent-ui-status.el --- Status indicators for requests (header-line + margin) -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides two status indicator systems:
;;
;; 1. Header-line status (existing):
;;    - Model name, status icon, elapsed time
;;    - Updated in real-time during active requests
;;
;; 2. Margin/fringe indicators (NEW):
;;    - Visual icons in the left margin of "* Request:" headlines
;;    - Status icons: ○ wait, ◐◑◒◓ streaming (animated), ✓ done, ✗ error
;;    - Visible even when headline is folded
;;    - Updated via overlays as request status changes
;;
;; Integration with ogent-ui.el:
;;   Call `ogent-status-set-request' when a request starts.
;;   Call `ogent-status-update-indicator' when status changes.
;;   Call `ogent-status-clear-request' when a request completes.
;;
;; The minor mode `ogent-status-mode' sets up the header-line-format
;; and manages the update timer.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ogent-ui-theme)

;; Forward declarations for request struct accessors
(declare-function ogent-ui-request-model "ogent-ui")
(declare-function ogent-ui-request-status "ogent-ui")
(declare-function ogent-ui-request-start-time "ogent-ui")
(declare-function ogent-ui-request-end-time "ogent-ui")
(declare-function ogent-ui-request-buffer "ogent-ui")
(declare-function ogent-ui-request-id "ogent-ui")
(declare-function ogent-ui-request-marker "ogent-ui")

;;; Status Icons - Now using ogent-ui-theme for consistency

(defun ogent-status--get-icon (status)
  "Get icon for STATUS using the theme system."
  (pcase status
    ('wait (ogent-theme-icon 'pending))
    ('type (ogent-theme-icon 'running))
    ('done (ogent-theme-icon 'done))
    ('error (ogent-theme-icon 'error))
    ('aborted (ogent-theme-icon 'blocked))
    (_ "?")))

(defun ogent-status--get-face (status)
  "Get face for STATUS using the theme system."
  (pcase status
    ('wait 'ogent-theme-muted)
    ('type 'ogent-theme-warning)
    ('done 'ogent-theme-success)
    ('error 'ogent-theme-error)
    ('aborted 'ogent-theme-error)
    (_ 'default)))

;; Legacy alists kept for compatibility but prefer theme functions
(defconst ogent-status--icons
  '((wait . "⏳")
    (type . "✍")
    (done . "✓")
    (error . "✗")
    (aborted . "⊘"))
  "Alist mapping status symbols to display icons.")

(defconst ogent-status--margin-icons
  '((waiting . "○")
    (streaming . ("◐" "◑" "◒" "◓"))  ; Animated sequence
    (done . "✓")
    (error . "✗"))
  "Alist mapping status symbols to margin/fringe icons.
For streaming status, value is a list of frames for animation.")

;;; Buffer-local State

(defvar-local ogent-status--current-request nil
  "The currently active request in this buffer, or nil.")

(defvar-local ogent-status--elapsed-timer nil
  "Timer for updating elapsed time during active requests.")

(defvar-local ogent-status--margin-overlays nil
  "Hash table mapping request-id to margin indicator overlays.
Keys are request IDs (strings), values are plists with:
  :overlay - the overlay object
  :animation-frame - current animation frame index (for streaming)
  :animation-timer - timer for animating streaming indicator")

(defvar-local ogent-status--animation-frame 0
  "Current frame index for streaming animation (0-3).")

;;; Formatting

(defun ogent-status--format-elapsed (start-time)
  "Format elapsed seconds since START-TIME.
Returns a string like \"3.2s\"."
  (if start-time
      (format "%.1fs" (float-time (time-since start-time)))
    "0.0s"))

(defun ogent-status--format-header-line ()
  "Format the header-line string for the current request.
Shows model name, status icon, and elapsed time with proper theming.
Returns \"ogent: ready\" when no active request."
  (if ogent-status--current-request
      (let* ((model (ogent-ui-request-model ogent-status--current-request))
             (model-id (plist-get model :id))
             (status (ogent-ui-request-status ogent-status--current-request))
             (icon (ogent-status--get-icon status))
             (face (ogent-status--get-face status))
             (start-time (ogent-ui-request-start-time ogent-status--current-request))
             (elapsed (ogent-status--format-elapsed start-time)))
        (concat
         (propertize "ogent" 'face 'ogent-theme-primary)
         (propertize ": " 'face 'ogent-theme-muted)
         (propertize model-id 'face 'ogent-theme-secondary)
         " "
         (propertize icon 'face face)
         " "
         (propertize elapsed 'face 'ogent-theme-muted)))
    (concat
     (propertize "ogent" 'face 'ogent-theme-primary)
     (propertize ": " 'face 'ogent-theme-muted)
     (ogent-theme-icon 'success 'ogent-theme-success)
     " "
     (propertize "ready" 'face 'ogent-theme-success))))

;;; Timer Management

(defun ogent-status--start-timer ()
  "Start the elapsed-time update timer.
Updates header-line every 0.5 seconds."
  (ogent-status--stop-timer)
  (setq ogent-status--elapsed-timer
        (run-at-time 0.5 0.5 #'ogent-status--update (current-buffer))))

(defun ogent-status--stop-timer ()
  "Stop the elapsed-time update timer."
  (when ogent-status--elapsed-timer
    (cancel-timer ogent-status--elapsed-timer)
    (setq ogent-status--elapsed-timer nil)))

(defun ogent-status--update (buffer)
  "Update header-line in BUFFER.
Called by timer to refresh elapsed time."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (force-mode-line-update))))

;;; Margin/Fringe Indicator Management

(defun ogent-status--find-request-headline (marker)
  "Find the \"* Request:\" headline position for request at MARKER.
MARKER should point to the beginning of the response section.
Searches backward for the enclosing headline."
  (when (and marker (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (when (re-search-backward "^\\*+ Request:" nil t)
          (point))))))

(defun ogent-status--get-margin-icon (status &optional animation-frame)
  "Return the margin icon string for STATUS.
For streaming status, ANIMATION-FRAME determines which frame to show."
  (let ((icon-spec (cdr (assoc status ogent-status--margin-icons))))
    (if (listp icon-spec)
        ;; Animated icon sequence
        (nth (mod (or animation-frame 0) (length icon-spec)) icon-spec)
      ;; Static icon
      icon-spec)))

(defun ogent-status--create-margin-overlay (request)
  "Create a margin indicator overlay for REQUEST at its headline position.
Returns a plist with :overlay, :animation-frame, :animation-timer."
  (when-let* ((marker (ogent-ui-request-marker request))
              (headline-pos (ogent-status--find-request-headline marker))
              (buffer (ogent-ui-request-buffer request)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
	(let ((ov (make-overlay headline-pos (1+ headline-pos) buffer t nil)))
          ;; Initialize with waiting icon
          (let ((icon (ogent-status--get-margin-icon 'waiting)))
            (overlay-put ov 'before-string
			 (propertize " " 'display
                                     (list '(margin left-margin)
                                           (propertize icon 'face 'warning)))))
          (overlay-put ov 'ogent-status-indicator t)
          (list :overlay ov :animation-frame 0 :animation-timer nil))))))

(defun ogent-status--update-margin-overlay (overlay-info status)
  "Update OVERLAY-INFO to show STATUS.
OVERLAY-INFO is a plist with :overlay, :animation-frame, :animation-timer.
Uses theme faces for consistent styling."
  (when-let ((ov (plist-get overlay-info :overlay)))
    (when (overlay-buffer ov)
      (let* ((frame (plist-get overlay-info :animation-frame))
             (icon (pcase status
                     ('wait (ogent-theme-icon 'pending))
                     ('type (ogent-theme-stream-icon (or frame 0)))
                     ('done (ogent-theme-icon 'done))
                     ('error (ogent-theme-icon 'error))
                     ('aborted (ogent-theme-icon 'blocked))
                     ('paused "⏸")
                     (_ (ogent-theme-icon 'pending))))
             (face (ogent-status--get-face status)))
        (overlay-put ov 'before-string
                     (propertize " " 'display
                                 (list '(margin left-margin)
                                       (propertize icon 'face face))))))))

(defun ogent-status--start-animation (overlay-info)
  "Start animation timer for OVERLAY-INFO (for streaming status).
Uses theme animation interval for consistent timing."
  ;; Stop existing timer if any
  (ogent-status--stop-animation overlay-info)
  (let* ((interval (or (ogent-theme-animation-interval) 0.25))
         (timer (run-at-time interval interval
                             (lambda (info)
                               (when-let ((ov (plist-get info :overlay)))
                                 (when (overlay-buffer ov)
                                   (let ((frame (mod (1+ (or (plist-get info :animation-frame) 0)) 4)))
                                     (plist-put info :animation-frame frame)
                                     (ogent-status--update-margin-overlay info 'type)))))
                             overlay-info)))
    (plist-put overlay-info :animation-timer timer)))

(defun ogent-status--stop-animation (overlay-info)
  "Stop animation timer for OVERLAY-INFO."
  (when-let ((timer (plist-get overlay-info :animation-timer)))
    (cancel-timer timer)
    (plist-put overlay-info :animation-timer nil)))

(defun ogent-status--remove-margin-overlay (overlay-info)
  "Remove the margin overlay from OVERLAY-INFO."
  (ogent-status--stop-animation overlay-info)
  (when-let ((ov (plist-get overlay-info :overlay)))
    (delete-overlay ov)))

;;; Public API

(defun ogent-status-set-request (request)
  "Set REQUEST as the active request and start timer.
REQUEST should be an `ogent-ui-request' struct."
  (setq ogent-status--current-request request)
  (ogent-status--start-timer)
  (force-mode-line-update)
  ;; Create margin indicator
  (when-let ((buf (and request (ogent-ui-request-buffer request))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
	(unless ogent-status--margin-overlays
          (setq ogent-status--margin-overlays (make-hash-table :test 'equal)))
	(when-let* ((request-id (ogent-ui-request-id request))
                    (overlay-info (ogent-status--create-margin-overlay request)))
          (puthash request-id overlay-info ogent-status--margin-overlays)
          ;; Set initial status
          (ogent-status--update-margin-overlay overlay-info 'wait))))))

(defun ogent-status-update-indicator (request new-status)
  "Update margin indicator for REQUEST to show NEW-STATUS.
NEW-STATUS should be one of: wait, type, done, error, aborted, paused."
  (when-let ((buf (and request (ogent-ui-request-buffer request))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
	(when ogent-status--margin-overlays
          (when-let* ((request-id (ogent-ui-request-id request))
                      (overlay-info (gethash request-id ogent-status--margin-overlays)))
            (cond
             ;; Start animation for streaming
             ((eq new-status 'type)
              (ogent-status--start-animation overlay-info))
             ;; Stop animation for terminal/paused states
             ((memq new-status '(done error aborted paused))
              (ogent-status--stop-animation overlay-info)))
            ;; Update icon
            (ogent-status--update-margin-overlay overlay-info new-status)))))))

(defun ogent-status-clear-request (&optional request)
  "Clear the active request and stop timer.
If REQUEST is provided, remove its margin indicator specifically."
  (setq ogent-status--current-request nil)
  (ogent-status--stop-timer)
  (force-mode-line-update)
  ;; Remove margin indicator for specific request or all
  (when request
    (when (and (ogent-ui-request-buffer request)
               (buffer-live-p (ogent-ui-request-buffer request)))
      (with-current-buffer (ogent-ui-request-buffer request)
        (when ogent-status--margin-overlays
          (when-let* ((request-id (ogent-ui-request-id request))
                      (overlay-info (gethash request-id ogent-status--margin-overlays)))
            (ogent-status--remove-margin-overlay overlay-info)
            (remhash request-id ogent-status--margin-overlays)))))))

;;; Minor Mode

(defvar ogent-status--original-header-line nil
  "Stores the original header-line-format when mode is enabled.")

;;;###autoload
(define-minor-mode ogent-status-mode
  "Minor mode that displays request status in the header-line and margin.
Shows model name, status icon, and elapsed time for active requests.
Also displays visual indicators in the left margin of \"* Request:\" headlines."
  :lighter nil
  (if ogent-status-mode
      (progn
        ;; Save original header-line
        (setq ogent-status--original-header-line header-line-format)
        ;; Set our custom header-line
        (setq header-line-format
              '(:eval (ogent-status--format-header-line)))
        ;; Ensure left-margin is wide enough for icons
        (when (derived-mode-p 'org-mode)
          (setq left-margin-width 2)))
    ;; Restore original header-line
    (setq header-line-format ogent-status--original-header-line)
    (setq ogent-status--original-header-line nil)
    ;; Clean up
    (ogent-status--stop-timer)
    (setq ogent-status--current-request nil)
    ;; Clean up all margin overlays
    (when ogent-status--margin-overlays
      (maphash (lambda (_id overlay-info)
                 (ogent-status--remove-margin-overlay overlay-info))
               ogent-status--margin-overlays)
      (setq ogent-status--margin-overlays nil))))

(provide 'ogent-ui-status)

;;; ogent-ui-status.el ends here
