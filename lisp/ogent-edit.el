;;; ogent-edit.el --- Inline code editing for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Main module for inline code editing.  Coordinates parsing, display,
;; and logging of LLM-proposed code changes.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)
(require 'transient)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)
(require 'ogent-edit-display)
(require 'ogent-edit-log)
(require 'ogent-companion)

;;; Customization

(defcustom ogent-edit-auto-display t
  "When non-nil, automatically display edits as smerge conflicts."
  :type 'boolean
  :group 'ogent-edit)

(defcustom ogent-edit-log-to-companion t
  "When non-nil, log edit operations to companion buffer."
  :type 'boolean
  :group 'ogent-edit)

(defvar ogent-edit--pending-request nil
  "Plist storing context for the current edit request.")

;;; Request Flow

;;;###autoload
(defun ogent-request-edit (&optional prompt)
  "Request code edits for current buffer or region.
PROMPT is the edit instruction.  If region is active, only that
region is sent for context."
  (interactive)
  (unless (buffer-file-name)
    (user-error "Buffer must be visiting a file for edit requests"))
  (let* ((source-buffer (current-buffer))
         (region-active (use-region-p))
         (region-start (when region-active (region-beginning)))
         (region-end (when region-active (region-end)))
         (content (if region-active
                      (buffer-substring-no-properties region-start region-end)
                    (buffer-substring-no-properties (point-min) (point-max))))
         (user-prompt (or prompt (read-string "Edit instruction: ")))
         (filename (file-name-nondirectory (buffer-file-name)))
         (mode (symbol-name major-mode))
         (full-prompt (ogent-edit-wrap-prompt user-prompt filename mode content)))
    ;; Store context for callback
    (setq ogent-edit--pending-request
          (list :source-buffer source-buffer
                :region-start region-start
                :region-end region-end
                :prompt user-prompt))
    ;; Return the full prompt and system instructions for caller to send
    (list :prompt full-prompt
          :system ogent-edit-system-prompt
          :callback #'ogent-edit--process-response)))

;;; Response Processing

(defun ogent-edit--process-response (response)
  "Process LLM RESPONSE and apply edits to source buffer."
  (let* ((request ogent-edit--pending-request)
         (source-buffer (plist-get request :source-buffer))
         (edits (ogent-edit-parse-response response source-buffer)))
    ;; Validate all edits
    (setq edits (ogent-edit-validate-all edits))
    ;; Log proposals to companion
    (when ogent-edit-log-to-companion
      (ogent-edit-log-all-proposals edits)
      (ogent-edit-log-errors edits))
    ;; Report errors
    (let ((errors (ogent-edit-filter-errors edits)))
      (when errors
        (message "Edit errors: %d of %d edits failed validation"
                 (length errors) (length edits))))
    ;; Display valid edits
    (when ogent-edit-auto-display
      (let ((valid (ogent-edit-filter-valid edits)))
        (when valid
          (ogent-edit-apply-all-as-smerge valid)
          (ogent-edit--track-edits valid)
          ;; Switch to source buffer and go to first conflict
          (pop-to-buffer source-buffer)
          (ogent-edit-goto-first))))
    ;; Return edits for further processing
    edits))

;;; Integration with ogent-ui

(defun ogent-edit-send-request (request-plist)
  "Send edit REQUEST-PLIST via gptel.
REQUEST-PLIST should contain :prompt, :system, and :callback."
  ;; This will be integrated with ogent-ui's gptel sending
  ;; For now, return the request for manual integration
  request-plist)

;;; Transient Menu

;;;###autoload (autoload 'ogent-edit-menu "ogent-edit" nil t)
(transient-define-prefix ogent-edit-menu ()
  "Commands for managing ogent edits."
  [:description
   (lambda ()
     (let ((pending (or (ogent-edit-count-pending) 0)))
       (if (> pending 0)
           (format "Pending edits: %d" pending)
         "No pending edits")))
   ["Current Edit"
    ("a" "Accept" ogent-edit-accept-current)
    ("r" "Reject" ogent-edit-reject-current)
    ("n" "Next" smerge-next :transient t)
    ("p" "Previous" smerge-prev :transient t)]
   ["All Edits"
    ("A" "Accept all" ogent-edit-accept-all)
    ("R" "Reject all" ogent-edit-reject-all)]]
  [["Request"
    ("e" "Request edit" ogent-request-edit)
    ("q" "Quit" transient-quit-one)]])

(provide 'ogent-edit)

;;; ogent-edit.el ends here
