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

;; gptel integration
(declare-function gptel-request "ext:gptel" (prompt &rest args))
(declare-function gptel-backend-name "ext:gptel")
(declare-function gptel--model-name "ext:gptel")
(defvar gptel-backend)
(defvar gptel-model)

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

(defvar ogent-edit--streaming-response ""
  "Accumulated response text during streaming.")

;;; Request Flow

(defun ogent-edit--ensure-gptel ()
  "Signal a user error if gptel is unavailable."
  (unless (require 'gptel nil 'noerror)
    (user-error "gptel is required for ogent edit requests. Install gptel first")))

(defun ogent-edit--make-callback ()
  "Return a gptel callback that accumulates response and processes on completion."
  (lambda (text info)
    ;; Accumulate string content
    (when (stringp text)
      (setq ogent-edit--streaming-response
            (concat ogent-edit--streaming-response text))
      (message "Receiving edit response... (%d chars)"
               (length ogent-edit--streaming-response)))
    ;; Check for completion or error
    (cond
     ;; Error case
     ((and (listp info) (plist-get info :error))
      (message "Edit request failed: %s" (plist-get info :error))
      (setq ogent-edit--streaming-response ""))
     ;; Done - info contains :status "success" or similar completion markers
     ((or (and (listp info)
               (or (plist-get info :done)
                   (plist-get info :final)
                   (equal (plist-get info :status) "success")))
          ;; Non-streaming: text is final response, info is nil
          (and (null info) (stringp text) (> (length text) 0))
          ;; Streaming complete: text is nil/t, info indicates done
          (and (not (stringp text)) (listp info) info))
      (when (> (length ogent-edit--streaming-response) 0)
        (message "Processing %d chars of edit response..."
                 (length ogent-edit--streaming-response))
        (condition-case err
            (ogent-edit--process-response ogent-edit--streaming-response)
          (error (message "Edit processing error: %s" (error-message-string err))))
        (setq ogent-edit--streaming-response ""))))))

;;;###autoload
(defun ogent-request-edit (&optional prompt)
  "Request code edits for current buffer or region.
PROMPT is the edit instruction.  If region is active, only that
region is sent for context.  Sends request via gptel and applies
edits as smerge conflicts when response arrives."
  (interactive)
  (ogent-edit--ensure-gptel)
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
    ;; Reset streaming accumulator
    (setq ogent-edit--streaming-response "")
    ;; Send the request via gptel
    (message "Sending edit request to %s..."
             (if (and (boundp 'gptel-model) gptel-model)
                 (if (fboundp 'gptel--model-name)
                     (gptel--model-name gptel-model)
                   gptel-model)
               "LLM"))
    (gptel-request full-prompt
                   :system ogent-edit-system-prompt
                   :stream t
                   :callback (ogent-edit--make-callback))))

;;; Response Processing

(defun ogent-edit--process-response (response)
  "Process LLM RESPONSE and apply edits to source buffer."
  (let* ((request ogent-edit--pending-request)
         (source-buffer (plist-get request :source-buffer))
         (edits (ogent-edit-parse-response response source-buffer)))
    (message "Edit: parsed %d edit blocks from response" (length edits))
    ;; Validate all edits
    (setq edits (ogent-edit-validate-all edits))
    ;; Log proposals to companion
    (when ogent-edit-log-to-companion
      (ogent-edit-log-all-proposals edits)
      (ogent-edit-log-errors edits))
    ;; Report errors
    (let ((errors (ogent-edit-filter-errors edits))
          (valid (ogent-edit-filter-valid edits)))
      (message "Edit: %d valid, %d errors" (length valid) (length errors))
      (when errors
        (dolist (e errors)
          (message "Edit error: %s" (ogent-edit-error-message e)))))
    ;; Display valid edits
    (when ogent-edit-auto-display
      (let ((valid (ogent-edit-filter-valid edits)))
        (if valid
            (progn
              (message "Edit: applying %d edits as smerge conflicts" (length valid))
              (ogent-edit-apply-all-as-smerge valid)
              (ogent-edit--track-edits valid)
              ;; Switch to source buffer and go to first conflict
              (pop-to-buffer source-buffer)
              (ogent-edit-goto-first))
          (message "Edit: no valid edits to apply"))))
    ;; Return edits for further processing
    edits))

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
