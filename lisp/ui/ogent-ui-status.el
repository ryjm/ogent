;;; ogent-ui-status.el --- Header-line status indicator for requests -*- lexical-binding: t; -*-

;;; Commentary:
;; Displays active request status in the header-line showing:
;; - Model name
;; - Status icon (⏳ wait, ✍ type, ✓ done, ✗ error, ⊘ abort)
;; - Elapsed time (updated in real-time during active requests)
;;
;; Integration with ogent-ui.el:
;;   Call `ogent-status-set-request' when a request starts.
;;   Call `ogent-status-clear-request' when a request completes.
;;
;; The minor mode `ogent-status-mode' sets up the header-line-format
;; and manages the update timer.

;;; Code:

(require 'cl-lib)

;; Forward declarations for request struct accessors
(declare-function ogent-ui-request-model "ogent-ui")
(declare-function ogent-ui-request-status "ogent-ui")
(declare-function ogent-ui-request-start-time "ogent-ui")
(declare-function ogent-ui-request-end-time "ogent-ui")

;;; Status Icons

(defconst ogent-status--icons
  '((wait . "⏳")
    (type . "✍")
    (done . "✓")
    (error . "✗")
    (aborted . "⊘"))
  "Alist mapping status symbols to display icons.")

;;; Buffer-local State

(defvar-local ogent-status--current-request nil
  "The currently active request in this buffer, or nil.")

(defvar-local ogent-status--elapsed-timer nil
  "Timer for updating elapsed time during active requests.")

;;; Formatting

(defun ogent-status--format-elapsed (start-time)
  "Format elapsed seconds since START-TIME.
Returns a string like \"3.2s\"."
  (if start-time
      (format "%.1fs" (float-time (time-since start-time)))
    "0.0s"))

(defun ogent-status--format-header-line ()
  "Format the header-line string for the current request.
Shows model name, status icon, and elapsed time.
Returns \"ogent: ready\" when no active request."
  (if ogent-status--current-request
      (let* ((model (ogent-ui-request-model ogent-status--current-request))
             (model-id (plist-get model :id))
             (status (ogent-ui-request-status ogent-status--current-request))
             (icon (or (cdr (assoc status ogent-status--icons)) "?"))
             (start-time (ogent-ui-request-start-time ogent-status--current-request))
             (elapsed (ogent-status--format-elapsed start-time)))
        (format "ogent: %s %s %s" model-id icon elapsed))
    "ogent: ready"))

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

;;; Public API

(defun ogent-status-set-request (request)
  "Set REQUEST as the active request and start timer.
REQUEST should be an `ogent-ui-request' struct."
  (setq ogent-status--current-request request)
  (ogent-status--start-timer)
  (force-mode-line-update))

(defun ogent-status-clear-request ()
  "Clear the active request and stop timer."
  (setq ogent-status--current-request nil)
  (ogent-status--stop-timer)
  (force-mode-line-update))

;;; Minor Mode

(defvar ogent-status--original-header-line nil
  "Stores the original header-line-format when mode is enabled.")

;;;###autoload
(define-minor-mode ogent-status-mode
  "Minor mode that displays request status in the header-line.
Shows model name, status icon, and elapsed time for active requests."
  :lighter nil
  (if ogent-status-mode
      (progn
        ;; Save original header-line
        (setq ogent-status--original-header-line header-line-format)
        ;; Set our custom header-line
        (setq header-line-format
              '(:eval (ogent-status--format-header-line))))
    ;; Restore original header-line
    (setq header-line-format ogent-status--original-header-line)
    (setq ogent-status--original-header-line nil)
    ;; Clean up
    (ogent-status--stop-timer)
    (setq ogent-status--current-request nil)))

(provide 'ogent-ui-status)

;;; ogent-ui-status.el ends here
