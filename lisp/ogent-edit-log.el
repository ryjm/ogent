;;; ogent-edit-log.el --- Companion buffer logging for edits -*- lexical-binding: t; -*-

;;; Commentary:
;; Logs edit operations to the companion Org buffer for audit trail.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)
(require 'ogent-companion)

;;; Logging Functions

(defun ogent-edit-log-proposal (edit)
  "Log EDIT proposal to companion buffer.
Creates an Org heading with properties and diff block."
  (let* ((source-buf (ogent-edit-source-buffer edit))
         (companion (when source-buf
                      (ogent-companion--get-linked-buffer source-buf))))
    (when companion
      (with-current-buffer companion
        (goto-char (point-max))
        (insert (ogent-edit--format-log-entry edit))
        ;; Store marker for later updates
        (ogent-edit--store-log-marker edit (point-marker))))))

(defun ogent-edit--format-log-entry (edit)
  "Format EDIT as an Org log entry."
  (let ((id (ogent-edit-id edit))
        (file (or (ogent-edit-source-file edit) "(unsaved)"))
        (timestamp (format-time-string "%Y-%m-%d %a %H:%M"
                                       (ogent-edit-timestamp edit)))
        (status (symbol-name (ogent-edit-status edit)))
        (old-text (ogent-edit-old-text edit))
        (new-text (ogent-edit-new-text edit)))
    (format "\n** Edit: %s [%s]
:PROPERTIES:
:OGENT_EDIT_ID: %s
:SOURCE_FILE: %s
:STATUS: %s
:END:

*** Proposed Change
%s
"
            id timestamp id file status
            (ogent-edit--format-diff old-text new-text))))

(defun ogent-edit--format-diff (old-text new-text)
  "Format OLD-TEXT and NEW-TEXT as a diff block."
  (concat "#+begin_src diff\n"
          (ogent-edit--generate-diff-lines old-text new-text)
          "#+end_src\n"))

(defun ogent-edit--generate-diff-lines (old-text new-text)
  "Generate diff-style output for OLD-TEXT vs NEW-TEXT."
  (let ((old-lines (split-string old-text "\n"))
        (new-lines (split-string new-text "\n")))
    ;; Simple diff: show all old as removed, all new as added
    ;; Use mapconcat for efficiency (see elisp-handbook.org)
    (concat
     (mapconcat (lambda (line) (concat "- " line)) old-lines "\n")
     (when old-lines "\n")
     (mapconcat (lambda (line) (concat "+ " line)) new-lines "\n")
     (when new-lines "\n"))))

;;; Log Marker Management

(defvar-local ogent-edit--log-markers nil
  "Alist of (edit-id . marker) for log entries in companion buffer.")

(defun ogent-edit--store-log-marker (edit marker)
  "Store MARKER for EDIT's log entry.
Also stores the marker in the edit struct for navigation."
  (let ((id (ogent-edit-id edit))
        (companion (ogent-companion--get-linked-buffer
                    (ogent-edit-source-buffer edit))))
    (when companion
      (with-current-buffer companion
        (push (cons id marker) ogent-edit--log-markers)))
    ;; Store in edit struct for navigation
    (setf (ogent-edit-companion-marker edit) marker)))

(defun ogent-edit--find-log-marker (edit)
  "Find the log marker for EDIT."
  (let ((companion (ogent-companion--get-linked-buffer
                    (ogent-edit-source-buffer edit))))
    (when companion
      (with-current-buffer companion
        (cdr (assoc (ogent-edit-id edit) ogent-edit--log-markers))))))

;;; Resolution Logging

(defun ogent-edit-log-resolution (edit new-status)
  "Log that EDIT was resolved with NEW-STATUS.
Updates the STATUS property and adds a resolution timestamp."
  (let ((marker (ogent-edit--find-log-marker edit)))
    (when (and marker (marker-buffer marker))
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char marker)
          ;; Find the heading for this edit
          (when (re-search-backward
                 (format ":OGENT_EDIT_ID: %s" (ogent-edit-id edit))
                 nil t)
            (org-back-to-heading t)
            ;; Update STATUS property
            (org-set-property "STATUS" (symbol-name new-status))
            ;; Add resolution subheading
            (org-end-of-subtree)
            (insert (format "\n*** Resolution [%s]\nStatus: %s\n"
                            (format-time-string "%Y-%m-%d %a %H:%M")
                            new-status))))))))

;;; Batch Logging

(defun ogent-edit-log-all-proposals (edits)
  "Log all EDITS to companion buffer."
  (dolist (edit edits)
    (ogent-edit-log-proposal edit)))

(defun ogent-edit-log-errors (edits)
  "Log error messages for failed EDITS."
  (let ((errors (ogent-edit-filter-errors edits)))
    (when errors
      (let* ((first-edit (car errors))
             (source-buf (ogent-edit-source-buffer first-edit))
             (companion (when source-buf
                          (ogent-companion--get-linked-buffer source-buf))))
        (when companion
          (with-current-buffer companion
            (goto-char (point-max))
            (insert "\n** Edit Errors\n")
            (dolist (edit errors)
              (insert (format "- %s: %s\n"
                              (ogent-edit-id edit)
                              (ogent-edit-error-message edit))))))))))

;;; Hook Integration

(defun ogent-edit--log-resolved (edit)
  "Hook function to log when EDIT is resolved."
  (ogent-edit-log-resolution edit (ogent-edit-status edit)))

;; Register the logging hook
(add-hook 'ogent-edit-resolved-hook #'ogent-edit--log-resolved)

(provide 'ogent-edit-log)

;;; ogent-edit-log.el ends here
