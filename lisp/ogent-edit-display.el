;;; ogent-edit-display.el --- smerge-based edit display -*- lexical-binding: t; -*-

;;; Commentary:
;; Displays proposed edits as smerge conflict markers for accept/reject workflow.
;; Also provides Magit-style diff preview for edits before applying.
;; See specs/inline-edits.org for full specification.

;;; Code:

(require 'cl-lib)
(require 'smerge-mode)
(require 'diff-mode)
(require 'ogent-edit-format)
(require 'ogent-edit-parse)

;; Forward declaration for customization from ogent-edit.el
(defvar ogent-edit-auto-display)

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

;;; Diff Preview

(defvar-local ogent-edit-preview--current-edit nil
  "The `ogent-edit' struct being previewed in this diff buffer.")

(defvar-local ogent-edit-preview--source-buffer nil
  "The source buffer where the edit will be applied.")

(defcustom ogent-edit-preview-window-height 0.3
  "Height of diff preview window as fraction of frame height."
  :type 'float
  :group 'ogent-edit)

(defvar ogent-edit-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'ogent-edit-preview-accept)
    (define-key map (kbd "r") #'ogent-edit-preview-reject)
    (define-key map (kbd "q") #'ogent-edit-preview-reject)
    (define-key map (kbd "RET") #'ogent-edit-preview-accept)
    (define-key map (kbd "n") #'diff-hunk-next)
    (define-key map (kbd "p") #'diff-hunk-prev)
    map)
  "Keymap for `ogent-edit-preview-mode'.")

(define-minor-mode ogent-edit-preview-mode
  "Minor mode for previewing ogent edits as unified diffs.
\\{ogent-edit-preview-mode-map}"
  :lighter " OgentPreview"
  :keymap ogent-edit-preview-mode-map
  (when ogent-edit-preview-mode
    (setq buffer-read-only t)))

;;;###autoload
(defun ogent-edit-preview-diff (edit)
  "Show unified diff preview for EDIT in a popup buffer.
Returns the preview buffer."
  (let* ((file-path (or (ogent-edit-source-file edit) "buffer"))
         (old-text (ogent-edit-old-text edit))
         (new-text (ogent-edit-new-text edit))
         (source-buf (ogent-edit-source-buffer edit))
         (buf-name "*ogent-diff*")
         (diff-content (ogent-edit--generate-unified-diff 
                        file-path old-text new-text)))
    ;; Create or reuse diff buffer
    (with-current-buffer (get-buffer-create buf-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert diff-content)
        (goto-char (point-min))
        ;; Enable diff-mode for syntax highlighting
        (diff-mode)
        ;; Enable our preview mode for keybindings
        (ogent-edit-preview-mode 1)
        ;; Store edit context
        (setq ogent-edit-preview--current-edit edit
              ogent-edit-preview--source-buffer source-buf))
      ;; Display the buffer
      (let ((win (display-buffer 
                  (current-buffer)
                  `((display-buffer-at-bottom)
                    (window-height . ,ogent-edit-preview-window-height)))))
        (when win
          (select-window win)))
      (current-buffer))))

(defun ogent-edit--generate-unified-diff (file-path old-text new-text)
  "Generate unified diff format showing OLD-TEXT vs NEW-TEXT for FILE-PATH.
Returns a string in unified diff format."
  (let* ((old-lines (split-string old-text "\n" nil))
         (new-lines (split-string new-text "\n" nil))
         (header (format "--- a/%s\n+++ b/%s\n" file-path file-path)))
    (with-temp-buffer
      (insert header)
      ;; Generate hunk header
      ;; For simplicity, treat entire change as one hunk
      (let ((old-start 1)
            (old-count (length old-lines))
            (new-start 1)
            (new-count (length new-lines)))
        (insert (format "@@ -%d,%d +%d,%d @@\n"
                        old-start old-count
                        new-start new-count)))
      ;; Insert old lines with - prefix
      (dolist (line old-lines)
        (insert (format "-%s\n" line)))
      ;; Insert new lines with + prefix
      (dolist (line new-lines)
        (insert (format "+%s\n" line)))
      (buffer-string))))

(defun ogent-edit-preview-accept ()
  "Accept the edit being previewed and apply it to source buffer."
  (interactive)
  (unless ogent-edit-preview--current-edit
    (user-error "No edit to accept"))
  (let ((edit ogent-edit-preview--current-edit)
        (source-buf ogent-edit-preview--source-buffer))
    ;; Apply the edit as smerge conflict
    (with-current-buffer source-buf
      (ogent-edit-apply-as-smerge edit))
    ;; Close preview
    (quit-window t)
    ;; Switch to source buffer
    (pop-to-buffer source-buf)
    (message "Edit applied as smerge conflict. Use smerge commands to resolve.")))

(defun ogent-edit-preview-reject ()
  "Reject the edit being previewed and close preview buffer."
  (interactive)
  (unless ogent-edit-preview--current-edit
    (user-error "No edit to reject"))
  (let ((edit ogent-edit-preview--current-edit))
    (setf (ogent-edit-status edit) 'rejected)
    (message "Edit rejected"))
  (quit-window t))

(defun ogent-edit-preview-or-apply (edit)
  "Preview EDIT as diff, or apply directly based on customization.
If `ogent-edit-auto-display' is non-nil, shows preview first.
Otherwise applies as smerge immediately."
  (if ogent-edit-auto-display
      (ogent-edit-preview-diff edit)
    (ogent-edit-apply-as-smerge edit)))

(provide 'ogent-edit-display)

;;; ogent-edit-display.el ends here
