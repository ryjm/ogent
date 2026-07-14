;;; ogent-edit-parse.el --- Parser for edit blocks -*- lexical-binding: t; -*-

;;; Commentary:
;; Parses LLM responses to extract SEARCH/REPLACE edit blocks.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)
(require 'json)
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

;;; Structured Output (JSON schema)

(define-error 'ogent-edit-structured-invalid
              "Invalid structured edit payload")

(defconst ogent-edit-structured-schema
  '(:type "array"
          :items (:type "object"
                        :properties
                        (:file (:type "string"
                                      :description "Name of the file the edit applies to.")
                               :search (:type "string"
                                              :description "Exact original code to find.  Must match the source verbatim, whitespace included.")
                               :replace (:type "string"
                                               :description "Full replacement for the matched code.")
                               :rationale (:type "string"
                                                 :description "Optional short explanation of the change."))
                        :required ["file" "search" "replace"]))
  "JSON schema describing a structured edit response.
The response is an array of edit objects, each carrying the file
name, the exact text to search for, its replacement, and an
optional rationale.")

(defun ogent-edit--json-parse (string)
  "Parse STRING as JSON with plist objects and list arrays.
Signal `ogent-edit-structured-invalid' when STRING is not valid JSON."
  (condition-case nil
      (if (fboundp 'json-parse-string)
          (json-parse-string string
                             :object-type 'plist
                             :array-type 'list
                             :null-object nil
                             :false-object nil)
        (let ((json-object-type 'plist)
              (json-array-type 'list)
              (json-false nil)
              (json-null nil))
          (json-read-from-string string)))
    (error (signal 'ogent-edit-structured-invalid
                   (list "Response is not valid JSON")))))

(defun ogent-edit--structured-entries (payload)
  "Return the list of edit entries described by PAYLOAD.
PAYLOAD is a parsed JSON value: either a list of edit objects, or
an object whose \"items\" key holds that list (gptel wraps
top-level arrays this way for providers that require an object
root).  Signal `ogent-edit-structured-invalid' when PAYLOAD has
neither shape."
  (cond
   ;; Object payload: require an "items" array.
   ((and (consp payload) (keywordp (car payload)))
    (let ((items (plist-get payload :items)))
      (unless (and (plist-member payload :items) (listp items))
        (signal 'ogent-edit-structured-invalid
                (list "Object payload lacks an \"items\" array" payload)))
      items))
   ;; Array payload (nil is the empty array).
   ((listp payload) payload)
   (t (signal 'ogent-edit-structured-invalid
              (list "Payload is not an array of edits" payload)))))

(defun ogent-edit--structured-entry-to-edit (entry source-buffer source-file)
  "Convert structured edit ENTRY into an `ogent-edit' struct.
ENTRY is a plist with string :search and :replace fields; :file
and :rationale are accepted but not stored.  SOURCE-BUFFER and
SOURCE-FILE seed the struct's origin slots.  Signal
`ogent-edit-structured-invalid' when ENTRY is malformed."
  (unless (and (listp entry)
               (stringp (plist-get entry :search))
               (stringp (plist-get entry :replace)))
    (signal 'ogent-edit-structured-invalid
            (list "Edit entry needs string \"search\" and \"replace\" fields"
                  entry)))
  (make-ogent-edit
   :id (ogent-edit--generate-id)
   :old-text (ogent-edit--normalize-text (plist-get entry :search))
   :new-text (ogent-edit--normalize-text (plist-get entry :replace))
   :source-buffer source-buffer
   :source-file source-file
   :status 'pending
   :timestamp (current-time)))

(defun ogent-edit-structured-to-edits (payload source-buffer)
  "Convert parsed structured PAYLOAD into a list of `ogent-edit' structs.
PAYLOAD is a parsed JSON value (see `ogent-edit--structured-entries').
SOURCE-BUFFER is the buffer the edits target.  Signal
`ogent-edit-structured-invalid' when PAYLOAD does not describe a
list of well-formed edits."
  (let ((entries (ogent-edit--structured-entries payload))
        (source-file (when (and source-buffer (buffer-live-p source-buffer))
                       (buffer-file-name source-buffer))))
    (ogent-edit--reset-counter)
    (mapcar (lambda (entry)
              (ogent-edit--structured-entry-to-edit
               entry source-buffer source-file))
            entries)))

(defun ogent-edit-parse-structured-response (response source-buffer)
  "Parse RESPONSE as a structured JSON edit payload.
Return a list of `ogent-edit' structs targeting SOURCE-BUFFER,
equivalent to what `ogent-edit-parse-response' produces for the
same edits in SEARCH/REPLACE form.  Signal
`ogent-edit-structured-invalid' when RESPONSE is not a valid
structured payload; callers should fall back to the text parser
in that case."
  (unless (stringp response)
    (signal 'ogent-edit-structured-invalid
            (list "Response is not a string")))
  (ogent-edit-structured-to-edits (ogent-edit--json-parse response)
                                  source-buffer))

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
