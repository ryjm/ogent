;;; ogent-edit-display.el --- smerge-based edit display -*- lexical-binding: t; -*-

;;; Commentary:
;; Displays proposed edits as smerge conflict markers for accept/reject workflow.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)
(require 'smerge-mode)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)

;;; Edit Display

(defun ogent-edit-apply-as-smerge (edit)
  "Insert EDIT as smerge conflict markers in source buffer.
The original code is marked as mine (upper) and the new code
as other (lower), matching smerge conventions."
  (unless (eq (ogent-edit-status edit) 'pending)
    (user-error "Edit %s is not pending" (ogent-edit-id edit)))
  (unless (ogent-edit-start-pos edit)
    (user-error "Edit %s has not been validated" (ogent-edit-id edit)))
  (let ((buf (ogent-edit-source-buffer edit))
        (start (ogent-edit-start-pos edit))
        (old-text (ogent-edit-old-text edit))
        (new-text (ogent-edit-new-text edit)))
    (with-current-buffer buf
      (save-excursion
        (goto-char start)
        (delete-region start (ogent-edit-end-pos edit))
        (insert (ogent-edit--format-conflict old-text new-text)))
      ;; Enable smerge-mode if not already active
      (unless (bound-and-true-p smerge-mode)
        (smerge-mode 1))
      ;; Update edit status
      (setf (ogent-edit-status edit) 'applied)
      ;; Move to the conflict
      (goto-char start)
      (smerge-next))))

(defun ogent-edit--format-conflict (old-text new-text)
  "Format OLD-TEXT and NEW-TEXT as smerge conflict markers."
  (concat "<<<<<<< original\n"
          old-text
          (unless (string-suffix-p "\n" old-text) "\n")
          "=======\n"
          new-text
          (unless (string-suffix-p "\n" new-text) "\n")
          ">>>>>>> ogent\n"))

(defun ogent-edit-apply-all-as-smerge (edits)
  "Apply all valid EDITS as smerge conflicts.
Edits are applied in reverse position order to preserve positions.
Returns list of successfully applied edits."
  (let* ((valid-edits (ogent-edit-filter-valid edits))
         ;; Sort by position descending to apply from end to start
         (sorted (sort (copy-sequence valid-edits)
                       (lambda (a b)
                         (> (ogent-edit-start-pos a)
                            (ogent-edit-start-pos b)))))
         (applied nil))
    (dolist (edit sorted)
      (condition-case err
          (progn
            (ogent-edit-apply-as-smerge edit)
            (push edit applied))
        (error
         (setf (ogent-edit-status edit) 'error
               (ogent-edit-error-message edit)
               (error-message-string err)))))
    (nreverse applied)))

;;; Accept/Reject Tracking

(defvar-local ogent-edit--pending-edits nil
  "List of pending `ogent-edit' structs in this buffer.")

(defun ogent-edit--track-edits (edits)
  "Add EDITS to the tracking list for current buffer."
  (setq ogent-edit--pending-edits
        (append ogent-edit--pending-edits edits)))

(defun ogent-edit--find-edit-at-point ()
  "Find the edit struct for the smerge conflict at point."
  (when (and ogent-edit--pending-edits
             (bound-and-true-p smerge-mode))
    (let ((pos (point)))
      (cl-find-if
       (lambda (edit)
         (and (ogent-edit-start-pos edit)
              (<= (ogent-edit-start-pos edit) pos)
              ;; Approximate end based on conflict size
              (<= pos (+ (ogent-edit-start-pos edit)
                         (length (ogent-edit-old-text edit))
                         (length (ogent-edit-new-text edit))
                         50)))) ; slack for markers
       ogent-edit--pending-edits))))

;;; Resolution Hooks

(defun ogent-edit--smerge-resolved-hook ()
  "Called when a smerge conflict is resolved.
Updates the edit status based on which version was kept."
  (let ((edit (ogent-edit--find-edit-at-point)))
    (when edit
      ;; We can't easily detect which was kept from smerge,
      ;; so we mark as resolved and let logging handle details
      (setf (ogent-edit-status edit) 'resolved)
      (run-hook-with-args 'ogent-edit-resolved-hook edit))))

(defvar ogent-edit-resolved-hook nil
  "Hook run when an edit is resolved (accepted or rejected).
Each function receives the `ogent-edit' struct.")

;;; Navigation

(defun ogent-edit-goto-first ()
  "Go to the first smerge conflict in current buffer."
  (interactive)
  (goto-char (point-min))
  (smerge-next))

(defun ogent-edit-count-pending ()
  "Return count of pending smerge conflicts in current buffer."
  (when (bound-and-true-p smerge-mode)
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (ignore-errors (smerge-next) t)
          (cl-incf count))
        count))))

;;; Convenience Commands

(defun ogent-edit-accept-current ()
  "Accept the AI-proposed change at point (keep lower/new)."
  (interactive)
  (let ((edit (ogent-edit--find-edit-at-point)))
    (smerge-keep-lower)
    (when edit
      (setf (ogent-edit-status edit) 'accepted)
      (setq ogent-edit--pending-edits
            (delq edit ogent-edit--pending-edits))
      (run-hook-with-args 'ogent-edit-resolved-hook edit))))

(defun ogent-edit-reject-current ()
  "Reject the AI-proposed change at point (keep upper/original)."
  (interactive)
  (let ((edit (ogent-edit--find-edit-at-point)))
    (smerge-keep-upper)
    (when edit
      (setf (ogent-edit-status edit) 'rejected)
      (setq ogent-edit--pending-edits
            (delq edit ogent-edit--pending-edits))
      (run-hook-with-args 'ogent-edit-resolved-hook edit))))

(defun ogent-edit-accept-all ()
  "Accept all AI-proposed changes in current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (ignore-errors (smerge-next) t)
      (ogent-edit-accept-current))))

(defun ogent-edit-reject-all ()
  "Reject all AI-proposed changes in current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (ignore-errors (smerge-next) t)
      (ogent-edit-reject-current))))

(provide 'ogent-edit-display)

;;; ogent-edit-display.el ends here
