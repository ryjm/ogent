;;; ogent-edit-parse.el --- Parser for edit blocks -*- lexical-binding: t; -*-

;;; Commentary:
;; Parses LLM responses to extract SEARCH/REPLACE edit blocks.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)
(require 'ogent-edit-format)

;;; Parsing

(defun ogent-edit-parse-response (response source-buffer)
  "Parse RESPONSE text for SEARCH/REPLACE blocks.
SOURCE-BUFFER is the buffer containing the source code.
Returns list of `ogent-edit' structs."
  (let ((edits nil)
        ;; Capture source-file before entering temp buffer
        ;; to avoid calling buffer-file-name on potentially dead buffer
        (source-file (when (and source-buffer (buffer-live-p source-buffer))
                       (buffer-file-name source-buffer))))
    (ogent-edit--reset-counter)
    (with-temp-buffer
      (insert response)
      (goto-char (point-min))
      (while (re-search-forward ogent-edit-search-regex nil t)
        (let* ((search-start (point))
               (separator-match (save-excursion
                                  (re-search-forward ogent-edit-separator-regex nil t)))
               (replace-end-match (save-excursion
                                    (re-search-forward ogent-edit-replace-regex nil t)))
               (old-text (when (and separator-match replace-end-match)
                           (buffer-substring-no-properties
                            search-start
                            (- separator-match (length "=======\n")))))
               (new-text (when (and separator-match replace-end-match)
                           (buffer-substring-no-properties
                            separator-match
                            (save-excursion
                              (goto-char replace-end-match)
                              (beginning-of-line)
                              (point))))))
          (when (and old-text new-text)
            (push (make-ogent-edit
                   :id (ogent-edit--generate-id)
                   :old-text (ogent-edit--normalize-text old-text)
                   :new-text (ogent-edit--normalize-text new-text)
                   :source-buffer source-buffer
                   :source-file source-file
                   :status 'pending
                   :timestamp (current-time))
                  edits))
          (goto-char (or replace-end-match (point-max))))))
    (nreverse edits)))

(defun ogent-edit--normalize-text (text)
  "Normalize TEXT by removing trailing newline if present.
Preserves internal newlines but removes single trailing one."
  (if (and text (string-suffix-p "\n" text))
      (substring text 0 -1)
    text))

;;; Validation

(defun ogent-edit-validate (edit)
  "Validate EDIT against its source buffer.
Sets start-pos/end-pos on success, or status='error on failure.
Returns the modified EDIT struct."
  (let* ((buf (ogent-edit-source-buffer edit))
         (old-text (ogent-edit-old-text edit))
         (matches nil))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-min))
          (while (search-forward old-text nil t)
            (push (cons (match-beginning 0) (match-end 0)) matches)))))
    (pcase (length matches)
      (0
       (setf (ogent-edit-status edit) 'error
             (ogent-edit-error-message edit) "SEARCH text not found in source"))
      (1
       (setf (ogent-edit-start-pos edit) (caar matches)
             (ogent-edit-end-pos edit) (cdar matches)))
      (_
       (setf (ogent-edit-status edit) 'error
             (ogent-edit-error-message edit)
             (format "SEARCH text matches %d locations (must be unique)"
                     (length matches)))))
    edit))

(defun ogent-edit-validate-all (edits)
  "Validate all EDITS against their source buffers.
Returns the list of edits with updated status/positions."
  (mapcar #'ogent-edit-validate edits))

;;; Utility Functions

(defun ogent-edit-pending-p (edit)
  "Return non-nil if EDIT is pending (not yet applied or rejected)."
  (eq (ogent-edit-status edit) 'pending))

(defun ogent-edit-error-p (edit)
  "Return non-nil if EDIT has an error."
  (eq (ogent-edit-status edit) 'error))

(defun ogent-edit-valid-p (edit)
  "Return non-nil if EDIT is valid (has positions set, no error)."
  (and (ogent-edit-start-pos edit)
       (ogent-edit-end-pos edit)
       (not (ogent-edit-error-p edit))))

(defun ogent-edit-filter-valid (edits)
  "Return only valid edits from EDITS list."
  (cl-remove-if-not #'ogent-edit-valid-p edits))

(defun ogent-edit-filter-errors (edits)
  "Return only error edits from EDITS list."
  (cl-remove-if-not #'ogent-edit-error-p edits))

(provide 'ogent-edit-parse)

;;; ogent-edit-parse.el ends here
