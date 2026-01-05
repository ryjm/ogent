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
(require 'ogent-edit-diff)
(require 'ogent-companion)

;; gptel integration
(declare-function gptel-request "ext:gptel" (prompt &rest args))
(declare-function gptel-backend-name "ext:gptel")
(declare-function gptel--model-name "ext:gptel")
(defvar gptel-backend)
(defvar gptel-model)

;;; Customization

(defcustom ogent-edit-auto-display t
  "When non-nil, automatically display edits using configured method.
See `ogent-edit-display-method' for display options."
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
              (message "Edit: displaying %d edits using %s method"
                       (length valid) ogent-edit-display-method)
              (ogent-edit-display-all valid)
              (ogent-edit--track-edits valid)
              ;; Switch to source buffer and go to first edit
              (pop-to-buffer source-buffer)
              (pcase ogent-edit-display-method
                ('overlay (when ogent-edit--overlay-list
                            (goto-char (overlay-start (car ogent-edit--overlay-list)))))
                (_ (ogent-edit-goto-first))))
          (message "Edit: no valid edits to apply"))))
    ;; Return edits for further processing
    edits))

;;; Transient Menu

(defun ogent-edit--pending-count ()
  "Return count of pending edits based on display method."
  (pcase ogent-edit-display-method
    ('overlay (length ogent-edit--overlay-list))
    (_ (or (ogent-edit-count-pending) 0))))

(defun ogent-edit--accept-current-dispatch ()
  "Accept current edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-accept))
    (_ (ogent-edit-accept-current))))

(defun ogent-edit--reject-current-dispatch ()
  "Reject current edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-reject))
    (_ (ogent-edit-reject-current))))

(defun ogent-edit--next-dispatch ()
  "Go to next edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-next))
    (_ (smerge-next))))

(defun ogent-edit--prev-dispatch ()
  "Go to previous edit using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-previous))
    (_ (smerge-prev))))

(defun ogent-edit--accept-all-dispatch ()
  "Accept all edits using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-accept-all))
    (_ (ogent-edit-accept-all))))

(defun ogent-edit--reject-all-dispatch ()
  "Reject all edits using appropriate method."
  (interactive)
  (pcase ogent-edit-display-method
    ('overlay (ogent-edit-overlay-reject-all))
    (_ (ogent-edit-reject-all))))

;;;###autoload
(defun ogent-edit-show-diff-buffer ()
  "Show pending edits in a magit-style diff buffer.
Provides stage/unstage semantics, collapsible sections, and batch operations."
  (interactive)
  (let ((edits ogent-edit--pending-edits))
    (if edits
        (ogent-edit-diff-show edits)
      (user-error "No pending edits"))))

;;;###autoload (autoload 'ogent-edit-menu "ogent-edit" nil t)
(transient-define-prefix ogent-edit-menu ()
			 "Commands for managing ogent edits."
			 [:description
			  (lambda ()
			    (let ((pending (ogent-edit--pending-count)))
			      (format "Pending edits: %d (%s mode)"
				      pending ogent-edit-display-method)))
			  ["Current Edit"
			   ("a" "Accept" ogent-edit--accept-current-dispatch)
			   ("r" "Reject" ogent-edit--reject-current-dispatch)
			   ("n" "Next" ogent-edit--next-dispatch :transient t)
			   ("p" "Previous" ogent-edit--prev-dispatch :transient t)]
			  ["All Edits"
			   ("A" "Accept all" ogent-edit--accept-all-dispatch)
			   ("R" "Reject all" ogent-edit--reject-all-dispatch)]]
			 [["Request"
			   ("e" "Request edit" ogent-request-edit)
			   ("D" "Diff buffer (magit-style)" ogent-edit-show-diff-buffer)
			   ("q" "Quit" transient-quit-one)]
			  ["Overlay Actions" :if (lambda () (eq ogent-edit-display-method 'overlay))
			   ("d" "Diff" ogent-edit-overlay-diff)
			   ("E" "Ediff" ogent-edit-overlay-ediff)
			   ("m" "Merge (smerge)" ogent-edit-overlay-merge)]])

(provide 'ogent-edit)

;;; ogent-edit.el ends here
