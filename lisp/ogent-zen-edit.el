;;; ogent-zen-edit.el --- Inline edit subsystem for Zen responses -*- lexical-binding: t; -*-

;;; Commentary:
;; Parse structured SEARCH/REPLACE responses and preview or apply them
;; as inline diffs via `inline-diff'.

;;; Code:

(require 'ogent-zen-core)
(require 'inline-diff)

(declare-function ogent-zen--preferred-response-heading "ogent-zen")
(declare-function ogent-zen--transcript-request-or-error "ogent-zen")

(cl-defstruct ogent-zen-edit-preview
  "A pending inline edit preview created from a Zen response."
  request-marker target-start-marker target-end-marker old-text new-text
  status scope-kind)

(defvar-local ogent-zen-edit--pending-preview nil
  "Latest pending Zen inline edit preview in the current buffer.")

(defun ogent-zen-edit--strip-delimiter-newline (text)
  "Return TEXT without the delimiter-introduced trailing newline."
  (if (string-suffix-p "\n" text)
      (substring text 0 -1)
    text))

(defun ogent-zen-edit--parse-search-replace (response)
  "Return the first SEARCH/REPLACE edit parsed from RESPONSE.
The return value is a plist with :old-text and :new-text."
  (with-temp-buffer
    (insert response)
    (goto-char (point-min))
    (unless (re-search-forward "^<<<<<<< SEARCH[ \t]*$" nil t)
      (user-error "No SEARCH/REPLACE block found in response"))
    (forward-line 1)
    (let ((old-start (point)))
      (unless (re-search-forward "^=======[ \t]*$" nil t)
        (user-error "SEARCH/REPLACE block is missing ======= separator"))
      (let ((old-end (match-beginning 0))
            (new-start (progn (forward-line 1) (point))))
        (unless (re-search-forward "^>>>>>>> REPLACE[ \t]*$" nil t)
          (user-error "SEARCH/REPLACE block is missing REPLACE terminator"))
        (list :old-text
              (ogent-zen-edit--strip-delimiter-newline
               (buffer-substring-no-properties old-start old-end))
              :new-text
              (ogent-zen-edit--strip-delimiter-newline
               (buffer-substring-no-properties new-start
                                               (match-beginning 0))))))))

(defun ogent-zen-edit--inside-generated-subtree-p (pos)
  "Return non-nil when POS is inside an ogent-generated subtree."
  (save-excursion
    (goto-char pos)
    (condition-case nil
        (progn
          (org-back-to-heading t)
          (ogent-zen--generated-heading-p))
      (error nil))))

(defun ogent-zen-edit--find-unique-in-heading (heading search-text)
  "Return unique bounds for SEARCH-TEXT under HEADING, excluding transcripts."
  (let (matches)
    (save-excursion
      (goto-char heading)
      (let ((end (ogent-zen--subtree-end)))
        (while (search-forward search-text end t)
          (let ((beg (match-beginning 0))
                (fin (match-end 0)))
            (unless (ogent-zen-edit--inside-generated-subtree-p beg)
              (push (cons beg fin) matches))))))
    (let ((count (length matches)))
      (cond
       ((= count 0)
        (user-error "SEARCH text not found in the owning heading"))
       ((= count 1)
        (car matches))
       (t
        (user-error "SEARCH text matches %d locations in the owning heading"
                    count))))))

(defun ogent-zen-edit--locate-target (scope search-text)
  "Return (BEG . END) for SEARCH-TEXT in SCOPE."
  (let* ((beg-marker (ogent-zen-scope-start-marker scope))
         (end-marker (ogent-zen-scope-end-marker scope))
         (marker-beg (ogent-zen--marker-position beg-marker))
         (marker-end (ogent-zen--marker-position end-marker)))
    (if (and marker-beg marker-end
             (string= search-text
                      (buffer-substring-no-properties marker-beg marker-end)))
        (cons marker-beg marker-end)
      (ogent-zen-edit--find-unique-in-heading
       (ogent-zen-scope-heading-point scope)
       search-text))))

(defun ogent-zen-edit--insert-error-block (request-marker message)
  "Insert an actionable edit error MESSAGE under REQUEST-MARKER."
  (when (and (markerp request-marker)
             (marker-buffer request-marker)
             (marker-position request-marker))
    (with-current-buffer (marker-buffer request-marker)
      (save-excursion
        (goto-char request-marker)
        (org-end-of-subtree t t)
        (unless (bolp) (insert "\n"))
        (insert "#+begin_quote ogent-edit-error\n"
                "Edit preview failed: " message "\n"
                "#+end_quote\n")))))

(defun ogent-zen-edit--set-request-status (request-marker status
                                                          &optional message)
  "Set REQUEST-MARKER edit STATUS and optional MESSAGE."
  (when (and (markerp request-marker)
             (marker-buffer request-marker)
             (marker-position request-marker))
    (with-current-buffer (marker-buffer request-marker)
      (save-excursion
        (goto-char request-marker)
        (org-entry-put (point) "OGENT_EDIT_STATUS" status)
        (if message
            (org-entry-put (point) "OGENT_EDIT_ERROR" message)
          (org-entry-delete (point) "OGENT_EDIT_ERROR"))))))

(defun ogent-zen-edit--set-target-metadata (request-marker beg end text)
  "Persist edit target BEG, END, and TEXT metadata on REQUEST-MARKER."
  (when (and (markerp request-marker)
             (marker-buffer request-marker)
             (marker-position request-marker))
    (with-current-buffer (marker-buffer request-marker)
      (save-excursion
        (goto-char request-marker)
        (org-entry-put (point) "OGENT_TARGET_BEGIN" (number-to-string beg))
        (org-entry-put (point) "OGENT_TARGET_END" (number-to-string end))
        (org-entry-put (point) "OGENT_TARGET_LENGTH"
                       (number-to-string (length text)))
        (org-entry-put (point) "OGENT_TARGET_SHA256"
                       (secure-hash 'sha256 text))))))

(defun ogent-zen-edit--refresh-target-metadata (preview)
  "Persist current target metadata for PREVIEW."
  (let* ((request (ogent-zen-edit-preview-request-marker preview))
         (beg (ogent-zen--marker-position
               (ogent-zen-edit-preview-target-start-marker preview)))
         (end (ogent-zen--marker-position
               (ogent-zen-edit-preview-target-end-marker preview))))
    (when (and beg end)
      (ogent-zen-edit--set-target-metadata
       request beg end (buffer-substring-no-properties beg end)))))

(defun ogent-zen-edit--preview-replacement (scope old-text new-text
                                                  request-marker)
  "Preview replacing OLD-TEXT with NEW-TEXT for SCOPE.
REQUEST-MARKER identifies the transcript that produced this proposal."
  (let* ((target (ogent-zen-edit--locate-target scope old-text))
         (beg (car target))
         (end (cdr target))
         new-end)
    (atomic-change-group
      (delete-region beg end)
      (goto-char beg)
      (insert new-text)
      (setq new-end (point))
      (inline-diff-words-region beg new-end old-text))
    (setq ogent-zen-edit--pending-preview
          (make-ogent-zen-edit-preview
           :request-marker request-marker
           :target-start-marker (copy-marker beg)
           :target-end-marker (copy-marker new-end t)
           :old-text old-text
           :new-text new-text
           :status 'preview
           :scope-kind (ogent-zen-scope-kind scope)))
    (add-hook 'inline-diff-accept-hook
              #'ogent-zen-edit--accept-hook nil t)
    (add-hook 'inline-diff-reject-hook
              #'ogent-zen-edit--reject-hook nil t)
    (ogent-zen-edit--set-request-status request-marker "preview")
    (ogent-zen-edit--refresh-target-metadata
     ogent-zen-edit--pending-preview)
    ogent-zen-edit--pending-preview))

(defun ogent-zen-edit--accept-hook ()
  "Mark the pending Zen edit as accepted."
  (when ogent-zen-edit--pending-preview
    (setf (ogent-zen-edit-preview-status
           ogent-zen-edit--pending-preview)
          'accepted)
    (ogent-zen-edit--set-request-status
     (ogent-zen-edit-preview-request-marker
      ogent-zen-edit--pending-preview)
     "accepted")
    (ogent-zen-edit--refresh-target-metadata
     ogent-zen-edit--pending-preview)))

(defun ogent-zen-edit--reject-hook ()
  "Mark the pending Zen edit as rejected."
  (when ogent-zen-edit--pending-preview
    (setf (ogent-zen-edit-preview-status
           ogent-zen-edit--pending-preview)
          'rejected)
    (ogent-zen-edit--set-request-status
     (ogent-zen-edit-preview-request-marker
      ogent-zen-edit--pending-preview)
     "rejected")
    (ogent-zen-edit--refresh-target-metadata
     ogent-zen-edit--pending-preview)))

(defun ogent-zen-edit--scope-from-transcript (request)
  "Reconstruct a Zen edit scope from REQUEST metadata."
  (save-excursion
    (goto-char request)
    (unless (ogent-zen--request-heading-p)
      (user-error "Point is not on a Zen request"))
    (let* ((heading (save-excursion
                      (or (and (org-up-heading-safe) (point))
                          (user-error "No user heading above edit request"))))
           (kind (intern (or (org-entry-get request "OGENT_SCOPE_KIND")
                             "region")))
           (beg (and-let* ((raw (org-entry-get request "OGENT_TARGET_BEGIN")))
                  (string-to-number raw)))
           (end (and-let* ((raw (org-entry-get request "OGENT_TARGET_END")))
                  (string-to-number raw)))
           (instruction (org-entry-get request "OGENT_INSTRUCTION")))
      (make-ogent-zen-scope
       :kind kind
       :heading-point heading
       :start-marker (and beg (> beg 0) (copy-marker beg))
       :end-marker (and end (> end 0) (copy-marker end t))
       :breadcrumb (ogent-zen--breadcrumb heading)
       :instruction instruction
       :edit-p t))))

(defun ogent-zen-edit--preview-from-response (scope response request-marker)
  "Parse RESPONSE and preview its edit against SCOPE."
  (let* ((edit (ogent-zen-edit--parse-search-replace response))
         (old-text (plist-get edit :old-text))
         (new-text (plist-get edit :new-text)))
    (ogent-zen-edit--preview-replacement
     scope old-text new-text request-marker)))

(defun ogent-zen-preview-edit-from-request (context request-pos)
  "Preview the structured edit for CONTEXT at REQUEST-POS."
  (save-excursion
    (goto-char request-pos)
    (let* ((request-marker (copy-marker request-pos))
           (scope (or (plist-get context :zen-scope)
                      (ogent-zen-edit--scope-from-transcript request-pos)))
           (response (ogent-zen--preferred-response-heading
                      (ogent-zen--subtree-end)))
           (body (and response (ogent-zen--response-body-text response))))
      (unless response
        (user-error "This edit request has no response"))
      (condition-case err
          (ogent-zen-edit--preview-from-response scope body request-marker)
        (error
         (let ((message (error-message-string err)))
           (ogent-zen-edit--set-request-status request-marker "error" message)
           (ogent-zen-edit--insert-error-block request-marker message)
           (user-error "%s" message)))))))

(defun ogent-zen-apply-last-edit ()
  "Apply the latest structured Zen edit response at point as an inline diff."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen edit application requires an Org buffer"))
  (let ((request (ogent-zen--transcript-request-or-error)))
    (ogent-zen-preview-edit-from-request nil request)))

(defun ogent-zen-accept-edit ()
  "Accept the pending Zen inline edit preview."
  (interactive)
  (unless (bound-and-true-p inline-diff-mode)
    (user-error "No pending inline diff to accept"))
  (inline-diff-accept-all))

(defun ogent-zen-reject-edit ()
  "Reject the pending Zen inline edit preview and restore original text."
  (interactive)
  (unless (bound-and-true-p inline-diff-mode)
    (user-error "No pending inline diff to reject"))
  (inline-diff-reject-all))

(defun ogent-zen-copy-response ()
  "Copy the response body for the Zen transcript at point."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Zen transcript commands require an Org buffer"))
  (let* ((response (ogent-zen--response-heading-or-error))
         (text (ogent-zen--response-body-text response)))
    (kill-new text)
    (message "ogent: Copied response: %s"
             (ogent-zen--char-count-label (length text)))
    text))

(provide 'ogent-zen-edit)
;;; ogent-zen-edit.el ends here
