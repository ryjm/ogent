;;; ogent-edit-display.el --- Edit display methods -*- lexical-binding: t; -*-

;;; Commentary:
;; Displays proposed edits using configurable methods:
;; - smerge: Traditional conflict markers (built-in)
;; - overlay: gptel-rewrite style overlays with dispatch menu
;; - inline-diff: Word-level inline highlighting (requires inline-diff.el)
;;
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

(declare-function ediff-buffers "ediff" (buffer-a buffer-b &optional startup-hooks job-name))
(declare-function ediff-setup-windows-plain "ediff-wind")
(defvar ediff-window-setup-function)
(defvar ediff-split-window-function)

;; Optional: inline-diff for word-level change highlighting
(declare-function inline-diff-mode "inline-diff" (&optional arg))
(declare-function inline-diff-words-region "inline-diff" (beg end old-text))

;; Org-mode functions (loaded at runtime)
(declare-function org-back-to-heading "org" (&optional invisible-ok))
;; Obsolete alias kept for older Org (fileonly: alias, not a defun)
(declare-function org-show-subtree "org" nil t)
(declare-function org-fold-show-subtree "org-fold" ())
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))

;;; Customization

(defcustom ogent-edit-display-method 'smerge
  "Method for displaying proposed edits.
Options:
- `smerge': Traditional conflict markers (built-in, always available)
- `overlay': gptel-rewrite style overlays with inline preview and dispatch menu
- `inline-diff': Word-level inline highlighting (requires inline-diff.el)"
  :type '(choice (const :tag "Smerge conflict markers" smerge)
                 (const :tag "Overlay with inline preview" overlay)
                 (const :tag "Inline-diff word highlighting" inline-diff))
  :group 'ogent-edit)

(defcustom ogent-edit-overlay-default-action nil
  "Default action when an overlay edit is ready.
If nil, wait for explicit user action.
Otherwise, automatically perform the specified action."
  :type '(choice (const :tag "Wait for user" nil)
                 (const :tag "Accept immediately" accept)
                 (const :tag "Show merge conflict" merge)
                 (const :tag "Show diff" diff)
                 (const :tag "Show ediff" ediff)
                 (const :tag "Show dispatch menu" dispatch))
  :group 'ogent-edit)

;;; Edit Display

(defun ogent-edit--re-anchor (edit)
  "Ensure EDIT's cached positions still cover its original text.
Call with EDIT's source buffer current.  When the cached region no
longer matches the old text, re-anchor EDIT to the unique occurrence
of that text, updating start-pos and end-pos.  When the text is
missing or ambiguous, set status to `error' with an explanatory
error-message and signal `user-error' without modifying the buffer.
Return EDIT."
  (let ((start (ogent-edit-start-pos edit))
        (end (ogent-edit-end-pos edit))
        (old-text (ogent-edit-old-text edit)))
    (unless (and (integerp start) (integerp end)
                 (>= start (point-min))
                 (<= end (point-max))
                 (string= (buffer-substring-no-properties start end)
                          old-text))
      ;; Cached positions are stale; rescan for the original text.
      (let ((matches nil))
        (save-excursion
          (goto-char (point-min))
          (while (search-forward old-text nil t)
            (push (cons (match-beginning 0) (match-end 0)) matches)))
        (pcase (length matches)
          (1
           (setf (ogent-edit-start-pos edit) (caar matches)
                 (ogent-edit-end-pos edit) (cdar matches))
           (message "ogent: edit %s re-anchored after buffer changed"
                    (ogent-edit-id edit)))
          (0
           (let ((msg "stale edit: original text not found"))
             (setf (ogent-edit-status edit) 'error
                   (ogent-edit-error-message edit) msg)
             (user-error "%s" msg)))
          (n
           (let ((msg (format "ambiguous after buffer changed: %d matches" n)))
             (setf (ogent-edit-status edit) 'error
                   (ogent-edit-error-message edit) msg)
             (user-error "%s" msg)))))))
  edit)

(defun ogent-edit-apply-as-smerge (edit)
  "Insert EDIT as smerge conflict markers in source buffer.
The original code is marked as mine (upper) and the new code
as other (lower), matching smerge conventions.
If the buffer changed since validation, re-anchor EDIT via
`ogent-edit--re-anchor'; a stale or ambiguous edit signals
`user-error' and leaves the buffer untouched."
  (unless (eq (ogent-edit-status edit) 'pending)
    (user-error "Edit %s is not pending" (ogent-edit-id edit)))
  (unless (ogent-edit-start-pos edit)
    (user-error "Edit %s has not been validated" (ogent-edit-id edit)))
  (let ((buf (ogent-edit-source-buffer edit))
        (old-text (ogent-edit-old-text edit))
        (new-text (ogent-edit-new-text edit)))
    (unless (buffer-live-p buf)
      (user-error "Source buffer for edit %s is no longer available"
                  (ogent-edit-id edit)))
    (with-current-buffer buf
      (ogent-edit--re-anchor edit)
      (let ((start (ogent-edit-start-pos edit)))
        (save-excursion
          (goto-char start)
          (delete-region start (ogent-edit-end-pos edit))
          (insert (ogent-edit--format-conflict old-text new-text))
          ;; Store source marker for navigation
          (setf (ogent-edit-source-marker edit) (copy-marker start)))
        ;; Enable smerge-mode if not already active
        (unless (bound-and-true-p smerge-mode)
          (smerge-mode 1))
        ;; Update edit status
        (setf (ogent-edit-status edit) 'applied)
        ;; Move to the conflict
        (goto-char start)
        (smerge-next)))))

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
      (let ((count 0)
            (prev-pos nil))
        (while (let ((cur-pos (point)))
                 (and (not (eq cur-pos prev-pos))
                      (ignore-errors (smerge-next) t)
                      (setq prev-pos cur-pos)))
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
    (let ((prev-pos nil))
      (while (let ((cur-pos (point)))
               (and (not (eq cur-pos prev-pos))
                    (ignore-errors (smerge-next) t)
                    (setq prev-pos cur-pos)))
        (ogent-edit-accept-current)))))

(defun ogent-edit-reject-all ()
  "Reject all AI-proposed changes in current buffer."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let ((prev-pos nil))
      (while (let ((cur-pos (point)))
               (and (not (eq cur-pos prev-pos))
                    (ignore-errors (smerge-next) t)
                    (setq prev-pos cur-pos)))
        (ogent-edit-reject-current)))))

;;; Marker Navigation

(defun ogent-edit-goto-source ()
  "Jump from companion buffer to corresponding source location.
When in a companion buffer, find the edit at point and jump to
its location in the source buffer."
  (interactive)
  (let ((edit (ogent-edit--find-edit-in-companion)))
    (if edit
        (let ((marker (ogent-edit-source-marker edit)))
          (if (and marker (marker-buffer marker))
              (progn
                (pop-to-buffer (marker-buffer marker))
                (goto-char marker)
                (message "Jumped to edit %s in source" (ogent-edit-id edit)))
            (user-error "Source marker not available for edit %s"
                        (ogent-edit-id edit))))
      (user-error "No edit found at point"))))

(defun ogent-edit-goto-companion ()
  "Jump from source buffer to corresponding companion log entry.
When in a source buffer with pending edits, find the edit at point
and jump to its log entry in the companion buffer."
  (interactive)
  (let ((edit (ogent-edit--find-edit-at-point)))
    (if edit
        (let ((marker (ogent-edit-companion-marker edit)))
          (if (and marker (marker-buffer marker))
              (progn
                (pop-to-buffer (marker-buffer marker))
                (goto-char marker)
                (org-back-to-heading t)
                (if (fboundp 'org-fold-show-subtree)
                    (org-fold-show-subtree)
                  ;; Fallback for older Org versions; use funcall to avoid
                  ;; byte-compile warning about obsolete function
                  (funcall 'org-show-subtree))
                (message "Jumped to edit %s in companion" (ogent-edit-id edit)))
            (user-error "Companion marker not available for edit %s"
                        (ogent-edit-id edit))))
      (user-error "No edit found at point"))))

(defun ogent-edit--find-edit-in-companion ()
  "Find the edit struct for the log entry at point in companion buffer.
Returns the edit struct or nil if not found."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (org-back-to-heading t)
      (let ((edit-id (org-entry-get nil "OGENT_EDIT_ID")))
        (when edit-id
          ;; Search through all tracked edits to find matching ID
          (ogent-edit--find-edit-by-id edit-id))))))

(defun ogent-edit--find-edit-by-id (id)
  "Find an edit struct by its ID across all buffers."
  (catch 'found
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (bound-and-true-p ogent-edit--pending-edits)
          (dolist (edit ogent-edit--pending-edits)
            (when (equal (ogent-edit-id edit) id)
              (throw 'found edit))))))
    nil))

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
    (define-key map (kbd "t") #'ogent-edit-toggle-display-method)
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
  "Accept the edit being previewed and apply it to source buffer.
The applied edit is tracked in the source buffer's
`ogent-edit--pending-edits' so resolving its smerge conflict is
logged like any other edit.  If the source buffer changed and the
edit is stale or ambiguous, the `user-error' signaled by
`ogent-edit-apply-as-smerge' propagates so the preview stays open
and the reason is visible."
  (interactive)
  (unless ogent-edit-preview--current-edit
    (user-error "No edit to accept"))
  (let ((edit ogent-edit-preview--current-edit)
        (source-buf ogent-edit-preview--source-buffer))
    (unless (buffer-live-p source-buf)
      (user-error "Source buffer is no longer available"))
    ;; Apply the edit as smerge conflict and track it for resolution
    ;; logging.  The edit was already logged as a proposal upstream,
    ;; so only tracking happens here.
    (with-current-buffer source-buf
      (ogent-edit-apply-as-smerge edit)
      (ogent-edit--track-edits (list edit)))
    ;; Close preview
    (quit-window t)
    ;; Switch to source buffer
    (pop-to-buffer source-buf)
    (message "Edit applied as smerge conflict. Use smerge commands to resolve.")))

(defun ogent-edit-preview-reject ()
  "Reject the edit being previewed and close preview buffer.
Untracks the edit from its source buffer and runs
`ogent-edit-resolved-hook' so the rejection is logged."
  (interactive)
  (unless ogent-edit-preview--current-edit
    (user-error "No edit to reject"))
  (let ((edit ogent-edit-preview--current-edit))
    (setf (ogent-edit-status edit) 'rejected)
    (let ((source-buf (ogent-edit-source-buffer edit)))
      (when (buffer-live-p source-buf)
        (with-current-buffer source-buf
          (setq ogent-edit--pending-edits
                (delq edit ogent-edit--pending-edits)))))
    (run-hook-with-args 'ogent-edit-resolved-hook edit)
    (message "Edit rejected"))
  (quit-window t))


;;; Overlay-based Display (gptel-rewrite style)

(defface ogent-edit-overlay-face
  '((((class color) (min-colors 88) (background dark))
     :background "#041714" :extend t)
    (((class color) (min-colors 88) (background light))
     :background "light goldenrod yellow" :extend t)
    (t :inherit secondary-selection))
  "Face for highlighting regions with pending edits."
  :group 'ogent-edit)

(defface ogent-edit-overlay-new-face
  '((((class color) (min-colors 88) (background dark))
     :background "#1a3a1a" :extend t)
    (((class color) (min-colors 88) (background light))
     :background "#e6ffe6" :extend t)
    (t :inherit diff-added))
  "Face for showing new text in overlay display."
  :group 'ogent-edit)

(defvar-local ogent-edit--overlay-list nil
  "List of active edit overlays in the buffer.")

(defvar ogent-edit-overlay-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ogent-edit-overlay-dispatch)
    (define-key map (kbd "a") #'ogent-edit-overlay-accept)
    (define-key map (kbd "r") #'ogent-edit-overlay-reject)
    (define-key map (kbd "k") #'ogent-edit-overlay-reject)
    (define-key map (kbd "d") #'ogent-edit-overlay-diff)
    (define-key map (kbd "e") #'ogent-edit-overlay-ediff)
    (define-key map (kbd "m") #'ogent-edit-overlay-merge)
    (define-key map (kbd "n") #'ogent-edit-overlay-next)
    (define-key map (kbd "p") #'ogent-edit-overlay-previous)
    (define-key map (kbd "t") #'ogent-edit-toggle-display-method)
    (define-key map [mouse-1] #'ogent-edit-overlay-dispatch)
    map)
  "Keymap for ogent edit overlays.")

(defun ogent-edit-apply-as-overlay (edit)
  "Display EDIT as an overlay with inline preview.
The original text is highlighted and the new text shown as a display overlay.
User can accept, reject, diff, ediff, or merge."
  (unless (eq (ogent-edit-status edit) 'pending)
    (user-error "Edit %s is not pending" (ogent-edit-id edit)))
  (unless (ogent-edit-start-pos edit)
    (user-error "Edit %s has not been validated" (ogent-edit-id edit)))
  (let* ((buf (ogent-edit-source-buffer edit))
         (start (ogent-edit-start-pos edit))
         (end (ogent-edit-end-pos edit))
         (new-text (ogent-edit-new-text edit)))
    (unless (buffer-live-p buf)
      (user-error "Source buffer for edit %s is no longer available"
                  (ogent-edit-id edit)))
    (with-current-buffer buf
      (let* ((ov (make-overlay start end nil t nil)))
        ;; Store edit in overlay
        (overlay-put ov 'ogent-edit edit)
        (overlay-put ov 'ogent-new-text new-text)
        ;; Visual styling
        (overlay-put ov 'face 'ogent-edit-overlay-face)
        (overlay-put ov 'priority 2000)
        ;; Show new text as display property (replaces original visually)
        (overlay-put ov 'display
                     (propertize new-text 'face 'ogent-edit-overlay-new-face))
        ;; Add before-string with action hint
        (overlay-put ov 'before-string
                     (propertize
                      (concat "\n" (ogent-edit--overlay-hint-string) "\n")
                      'face 'font-lock-comment-face))
        ;; Keymap for actions
        (overlay-put ov 'keymap ogent-edit-overlay-map)
        (overlay-put ov 'mouse-face 'highlight)
        (overlay-put ov 'help-echo
                     "ogent edit: RET=dispatch, a=accept, r=reject, d=diff, e=ediff, m=merge, t=toggle method")
        ;; Track overlay
        (push ov ogent-edit--overlay-list)
        ;; Store marker for navigation
        (setf (ogent-edit-source-marker edit) (copy-marker start))
        ;; Update status
        (setf (ogent-edit-status edit) 'applied)
        ;; Move to overlay
        (goto-char start)
        ;; Handle default action
        (when ogent-edit-overlay-default-action
          (ogent-edit--overlay-do-action ov ogent-edit-overlay-default-action))))))

(defun ogent-edit--overlay-hint-string ()
  "Return hint string for overlay actions."
  (concat
   (propertize "EDIT READY: " 'face 'success)
   (propertize "a" 'face 'help-key-binding) "ccept, "
   (propertize "r" 'face 'help-key-binding) "eject, "
   (propertize "d" 'face 'help-key-binding) "iff, "
   (propertize "e" 'face 'help-key-binding) "diff, "
   (propertize "m" 'face 'help-key-binding) "erge, "
   (propertize "t" 'face 'help-key-binding) "oggle"))

(defun ogent-edit--overlay-at (&optional pt)
  "Return the ogent edit overlay at PT (or point).
Signals error if no overlay found."
  (let ((pt (or pt (point))))
    (or (cl-find-if (lambda (ov)
                      (and (overlay-get ov 'ogent-edit)
                           (<= (overlay-start ov) pt)
                           (<= pt (overlay-end ov))))
                    ogent-edit--overlay-list)
        (user-error "No ogent edit overlay at point"))))

(defun ogent-edit--overlay-do-action (ov action)
  "Perform ACTION on overlay OV."
  (pcase action
    ('accept (ogent-edit-overlay-accept ov))
    ('reject (ogent-edit-overlay-reject ov))
    ('diff (ogent-edit-overlay-diff ov))
    ('ediff (ogent-edit-overlay-ediff ov))
    ('merge (ogent-edit-overlay-merge ov))
    ('dispatch (ogent-edit-overlay-dispatch ov))))

(defun ogent-edit-overlay-dispatch (&optional ov)
  "Show dispatch menu for edit overlay OV or at point."
  (interactive)
  (let* ((ov (or ov (ogent-edit--overlay-at)))
         (choice (read-multiple-choice
                  "Action: "
                  '((?a "accept" "Replace original with new text")
                    (?r "reject" "Keep original, discard new")
                    (?d "diff" "Show unified diff")
                    (?e "ediff" "Interactive ediff session")
                    (?m "merge" "Create smerge conflict markers")))))
    (pcase (car choice)
      (?a (ogent-edit-overlay-accept ov))
      (?r (ogent-edit-overlay-reject ov))
      (?d (ogent-edit-overlay-diff ov))
      (?e (ogent-edit-overlay-ediff ov))
      (?m (ogent-edit-overlay-merge ov)))))

(defun ogent-edit-overlay-accept (&optional ov)
  "Accept the edit in overlay OV, replacing original with new text."
  (interactive)
  (let* ((ov (or ov (ogent-edit--overlay-at)))
         (edit (overlay-get ov 'ogent-edit))
         (new-text (overlay-get ov 'ogent-new-text))
         (start (overlay-start ov))
         (end (overlay-end ov)))
    ;; Remove overlay first
    (ogent-edit--overlay-cleanup ov)
    ;; Replace text
    (goto-char start)
    (delete-region start end)
    (insert new-text)
    ;; Update edit status
    (setf (ogent-edit-status edit) 'accepted)
    (setq ogent-edit--pending-edits (delq edit ogent-edit--pending-edits))
    (run-hook-with-args 'ogent-edit-resolved-hook edit)
    (message "Edit accepted.")))

(defun ogent-edit-overlay-reject (&optional ov)
  "Reject the edit in overlay OV, keeping original text."
  (interactive)
  (let* ((ov (or ov (ogent-edit--overlay-at)))
         (edit (overlay-get ov 'ogent-edit)))
    ;; Remove overlay (original text is preserved)
    (ogent-edit--overlay-cleanup ov)
    ;; Update edit status
    (setf (ogent-edit-status edit) 'rejected)
    (setq ogent-edit--pending-edits (delq edit ogent-edit--pending-edits))
    (run-hook-with-args 'ogent-edit-resolved-hook edit)
    (message "Edit rejected.")))

(defun ogent-edit-overlay-diff (&optional ov)
  "Show unified diff for edit in overlay OV."
  (interactive)
  (let* ((ov (or ov (ogent-edit--overlay-at)))
         (edit (overlay-get ov 'ogent-edit)))
    (ogent-edit-preview-diff edit)))

(defun ogent-edit-overlay-ediff (&optional ov)
  "Start ediff session for edit in overlay OV."
  (interactive)
  (let* ((ov (or ov (ogent-edit--overlay-at)))
         (edit (overlay-get ov 'ogent-edit))
         (old-text (ogent-edit-old-text edit))
         (new-text (overlay-get ov 'ogent-new-text))
         (source-buf (current-buffer))
         (old-buf (generate-new-buffer "*ogent-original*"))
         (new-buf (generate-new-buffer "*ogent-proposed*")))
    ;; Populate buffers
    (with-current-buffer old-buf
      (insert old-text)
      (funcall (buffer-local-value 'major-mode source-buf))
      (setq buffer-read-only t))
    (with-current-buffer new-buf
      (insert new-text)
      (funcall (buffer-local-value 'major-mode source-buf))
      (setq buffer-read-only t))
    ;; Start ediff
    (let ((ediff-window-setup-function #'ediff-setup-windows-plain)
          (ediff-split-window-function #'split-window-horizontally))
      (ediff-buffers old-buf new-buf))))

(defun ogent-edit-overlay-merge (&optional ov)
  "Convert overlay OV to smerge conflict markers."
  (interactive)
  (let* ((ov (or ov (ogent-edit--overlay-at)))
         (edit (overlay-get ov 'ogent-edit))
         (old-text (ogent-edit-old-text edit))
         (new-text (overlay-get ov 'ogent-new-text))
         (start (overlay-start ov))
         (end (overlay-end ov)))
    ;; Remove overlay
    (ogent-edit--overlay-cleanup ov)
    ;; Insert conflict markers
    (goto-char start)
    (delete-region start end)
    (insert (ogent-edit--format-conflict old-text new-text))
    ;; Enable smerge
    (unless (bound-and-true-p smerge-mode)
      (smerge-mode 1))
    ;; Update status
    (setf (ogent-edit-status edit) 'applied)
    (message "Converted to smerge conflict. Use smerge commands to resolve.")))

(defun ogent-edit--overlay-cleanup (ov)
  "Remove overlay OV and clean up tracking."
  (setq ogent-edit--overlay-list (delq ov ogent-edit--overlay-list))
  (delete-overlay ov))

(defun ogent-edit-overlay-next ()
  "Move to next edit overlay in buffer."
  (interactive)
  (let ((pos (point))
        (next-pos nil))
    (dolist (ov ogent-edit--overlay-list)
      (let ((ov-start (overlay-start ov)))
        (when (and (> ov-start pos)
                   (or (null next-pos) (< ov-start next-pos)))
          (setq next-pos ov-start))))
    (if next-pos
        (goto-char next-pos)
      (user-error "No more edit overlays"))))

(defun ogent-edit-overlay-previous ()
  "Move to previous edit overlay in buffer."
  (interactive)
  (let ((pos (point))
        (prev-pos nil))
    (dolist (ov ogent-edit--overlay-list)
      (let ((ov-start (overlay-start ov)))
        (when (and (< ov-start pos)
                   (or (null prev-pos) (> ov-start prev-pos)))
          (setq prev-pos ov-start))))
    (if prev-pos
        (goto-char prev-pos)
      (user-error "No previous edit overlays"))))

(defun ogent-edit-apply-all-as-overlay (edits)
  "Apply all valid EDITS as overlays.
Edits are applied in reverse position order to preserve positions.
Returns list of successfully applied edits."
  (let* ((valid-edits (ogent-edit-filter-valid edits))
         (sorted (sort (copy-sequence valid-edits)
                       (lambda (a b)
                         (> (ogent-edit-start-pos a)
                            (ogent-edit-start-pos b)))))
         (applied nil))
    (dolist (edit sorted)
      (condition-case err
          (progn
            (ogent-edit-apply-as-overlay edit)
            (push edit applied))
        (error
         (setf (ogent-edit-status edit) 'error
               (ogent-edit-error-message edit)
               (error-message-string err)))))
    (nreverse applied)))

(defun ogent-edit-overlay-accept-all ()
  "Accept all pending edit overlays in current buffer."
  (interactive)
  (let ((count 0))
    (dolist (ov (copy-sequence ogent-edit--overlay-list))
      (ogent-edit-overlay-accept ov)
      (cl-incf count))
    (message "Accepted %d edit(s)." count)))

(defun ogent-edit-overlay-reject-all ()
  "Reject all pending edit overlays in current buffer."
  (interactive)
  (let ((count 0))
    (dolist (ov (copy-sequence ogent-edit--overlay-list))
      (ogent-edit-overlay-reject ov)
      (cl-incf count))
    (message "Rejected %d edit(s)." count)))

;;; Inline-diff Display (optional)

(defun ogent-edit-inline-diff-available-p ()
  "Return non-nil if inline-diff is available."
  (featurep 'inline-diff))

(defun ogent-edit-apply-as-inline-diff (edit)
  "Display EDIT using inline-diff word-level highlighting.
Replaces old text with new text and shows word-level diff overlay.
Requires inline-diff.el to be installed."
  (unless (ogent-edit-inline-diff-available-p)
    (user-error "inline-diff not available; install inline-diff.el or use different display method"))
  (unless (eq (ogent-edit-status edit) 'pending)
    (user-error "Edit %s is not pending" (ogent-edit-id edit)))
  (unless (ogent-edit-start-pos edit)
    (user-error "Edit %s has not been validated" (ogent-edit-id edit)))
  (let* ((buf (ogent-edit-source-buffer edit))
         (start (ogent-edit-start-pos edit))
         (end (ogent-edit-end-pos edit))
         (old-text (ogent-edit-old-text edit))
         (new-text (ogent-edit-new-text edit)))
    (unless (buffer-live-p buf)
      (user-error "Source buffer for edit %s is no longer available"
                  (ogent-edit-id edit)))
    (with-current-buffer buf
      ;; Store marker before changes
      (setf (ogent-edit-source-marker edit) (copy-marker start))
      ;; Replace old text with new text
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (insert new-text))
      ;; Apply inline-diff highlighting to show changes
      (let ((new-end (+ start (length new-text))))
        (inline-diff-words-region start new-end old-text))
      ;; Enable inline-diff-mode if not already active
      (unless (bound-and-true-p inline-diff-mode)
        (inline-diff-mode 1))
      ;; Update status - mark as applied (user can accept by clearing diff)
      (setf (ogent-edit-status edit) 'applied)
      ;; Track this edit
      (ogent-edit--track-edits (list edit))
      ;; Move to the change
      (goto-char start)
      (message "Edit displayed with inline-diff. Use C-c C-c to accept, C-c C-k to reject."))))

(defun ogent-edit-apply-all-as-inline-diff (edits)
  "Apply all valid EDITS using inline-diff display.
Edits are applied in reverse position order to preserve positions.
Returns list of successfully applied edits."
  (unless (ogent-edit-inline-diff-available-p)
    (user-error "inline-diff not available; install inline-diff.el"))
  (let* ((valid-edits (ogent-edit-filter-valid edits))
         (sorted (sort (copy-sequence valid-edits)
                       (lambda (a b)
                         (> (ogent-edit-start-pos a)
                            (ogent-edit-start-pos b)))))
         (applied nil))
    (dolist (edit sorted)
      (condition-case err
          (progn
            (ogent-edit-apply-as-inline-diff edit)
            (push edit applied))
        (error
         (setf (ogent-edit-status edit) 'error
               (ogent-edit-error-message edit)
               (error-message-string err)))))
    (nreverse applied)))

;;; Display Method Toggle

(defvar ogent-edit-display-methods '(smerge overlay inline-diff)
  "List of available display methods in cycle order.")

;;;###autoload
(defun ogent-edit-toggle-display-method ()
  "Toggle between available edit display methods.
Cycles through smerge -> overlay -> inline-diff -> smerge."
  (interactive)
  (let* ((current ogent-edit-display-method)
         (available (if (ogent-edit-inline-diff-available-p)
                        ogent-edit-display-methods
                      (remq 'inline-diff ogent-edit-display-methods)))
         (pos (cl-position current available))
         (next (if pos
                   (nth (mod (1+ pos) (length available)) available)
                 (car available))))
    (setq ogent-edit-display-method next)
    (message "Edit display method: %s" next)))

;;; Unified Display Interface

(defun ogent-edit-display (edit)
  "Display EDIT using the configured method.
See `ogent-edit-display-method' for options."
  (pcase ogent-edit-display-method
    ('smerge (ogent-edit-apply-as-smerge edit))
    ('overlay (ogent-edit-apply-as-overlay edit))
    ('inline-diff (ogent-edit-apply-as-inline-diff edit))
    (_ (ogent-edit-apply-as-smerge edit))))

(defun ogent-edit-display-all (edits)
  "Display all valid EDITS using the configured method.
Returns list of successfully displayed edits."
  (pcase ogent-edit-display-method
    ('smerge (ogent-edit-apply-all-as-smerge edits))
    ('overlay (ogent-edit-apply-all-as-overlay edits))
    ('inline-diff (ogent-edit-apply-all-as-inline-diff edits))
    (_ (ogent-edit-apply-all-as-smerge edits))))

(provide 'ogent-edit-display)

;;; ogent-edit-display.el ends here
