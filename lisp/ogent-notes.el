;;; ogent-notes.el --- Notes capture for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides functionality to capture AI completions to a Notes child heading.
;; When user presses C-c . d after receiving a completion, the last response
;; is shunted to a Notes child subtree under the current heading, preserving
;; useful completions as persistent knowledge.

;;; Code:

(require 'org)
(require 'cl-lib)

;;; Customization

(defgroup ogent-notes nil
  "Notes capture settings for ogent."
  :group 'ogent)

(defcustom ogent-notes-heading-name "Notes"
  "Name of the child heading where captured notes are stored."
  :type 'string
  :group 'ogent-notes)

(defcustom ogent-notes-timestamp-format "[%Y-%m-%d %a %H:%M]"
  "Format string for timestamps in captured notes.
Uses `format-time-string' syntax."
  :type 'string
  :group 'ogent-notes)

(defcustom ogent-notes-separator "\n\n"
  "Separator inserted between captured notes."
  :type 'string
  :group 'ogent-notes)

;;; Response Tracking

(defvar ogent-notes--last-response nil
  "Last response received from AI.
This is a plist with keys:
  :text - The response text
  :timestamp - When the response was received
  :model - The model that generated it (if available)")

(defvar gptel-model)

(defun ogent-notes-track-response (text &optional model)
  "Track TEXT as the last response, optionally with MODEL info."
  (when (and text (stringp text) (> (length text) 0))
    (setq ogent-notes--last-response
          (list :text text
                :timestamp (current-time)
                :model model))))

(defun ogent-notes--gptel-post-response-hook (beg end)
  "Hook function for `gptel-post-response-hook'.
Captures the response text between BEG and END."
  (when (and beg end (< beg end))
    (let ((text (buffer-substring-no-properties beg end))
          (model (when (boundp 'gptel-model) gptel-model)))
      (ogent-notes-track-response text model))))

(defun ogent-notes-get-last-response ()
  "Return the last tracked response text, or nil if none."
  (plist-get ogent-notes--last-response :text))

(defun ogent-notes-clear-last-response ()
  "Clear the last tracked response."
  (setq ogent-notes--last-response nil))

;;; Hook Setup

(defun ogent-notes-enable-tracking ()
  "Enable automatic response tracking via gptel hook."
  (when (boundp 'gptel-post-response-hook)
    (add-hook 'gptel-post-response-hook #'ogent-notes--gptel-post-response-hook)))

(defun ogent-notes-disable-tracking ()
  "Disable automatic response tracking."
  (when (boundp 'gptel-post-response-hook)
    (remove-hook 'gptel-post-response-hook #'ogent-notes--gptel-post-response-hook)))

;; Enable tracking by default when loaded
(ogent-notes-enable-tracking)

;;; Org Subtree Manipulation

(defun ogent-notes--at-heading-p ()
  "Return non-nil if point is at an org heading."
  (and (derived-mode-p 'org-mode)
       (org-at-heading-p)))

(defun ogent-notes--find-notes-heading ()
  "Find the Notes child heading under current subtree.
Returns the position of the Notes heading, or nil if not found.
Must be called with point at a heading."
  (save-excursion
    (let ((parent-level (org-current-level))
          (end (save-excursion (org-end-of-subtree t) (point)))
          (notes-name ogent-notes-heading-name)
          found)
      ;; Move to first child - returns nil if no children exist
      (when (org-goto-first-child)
        ;; Search through siblings at this level
        (while (and (not found)
                    (< (point) end))
          (when (and (org-at-heading-p)
                     (= (org-current-level) (1+ parent-level))
                     (string= (org-get-heading t t t t) notes-name))
            (setq found (point)))
          (unless found
            (unless (org-goto-sibling)
              (goto-char end)))))
      found)))

(defun ogent-notes--create-notes-heading ()
  "Create a Notes child heading under current subtree.
Returns the position of the new heading.
Must be called with point at a heading."
  (save-excursion
    (let ((level (org-current-level)))
      ;; Go to end of current heading's content (before children)
      (org-end-of-meta-data t)
      ;; Insert new heading at child level
      (insert (make-string (1+ level) ?*) " " ogent-notes-heading-name "\n")
      ;; Return position of new heading
      (forward-line -1)
      (point))))

(defun ogent-notes--find-or-create-notes-heading ()
  "Find or create Notes heading under current subtree.
Returns the position of the Notes heading.
Must be called with point at a heading."
  (or (ogent-notes--find-notes-heading)
      (ogent-notes--create-notes-heading)))

(defun ogent-notes--goto-notes-end ()
  "Move point to end of Notes heading content.
Must be called with point at the Notes heading."
  ;; Go to end of this subtree
  (org-end-of-subtree t)
  ;; Make sure we're at end of line
  (end-of-line))

(defun ogent-notes--format-capture (text)
  "Format TEXT for capture with timestamp."
  (let ((timestamp (format-time-string ogent-notes-timestamp-format)))
    (concat ogent-notes-separator
            "*** " timestamp "\n"
            text
            "\n")))

;;; Main Capture Function

;;;###autoload
(defun ogent-notes-capture ()
  "Capture the last AI response to Notes child heading.
Creates the Notes heading if it doesn't exist.
Appends the response with a timestamp."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Command `ogent-notes-capture' only works in Org buffers"))
  (let ((response (ogent-notes-get-last-response)))
    (unless response
      (user-error "No AI response to capture"))
    (save-excursion
      ;; Find the parent heading
      (unless (org-at-heading-p)
        (org-back-to-heading t))
      ;; Find or create Notes heading
      (let ((notes-pos (ogent-notes--find-or-create-notes-heading)))
        (goto-char notes-pos)
        ;; Go to end of Notes content
        (ogent-notes--goto-notes-end)
        ;; Insert the captured response
        (insert (ogent-notes--format-capture response))))
    ;; Clear the response after capture
    (ogent-notes-clear-last-response)
    (message "Captured response to %s" ogent-notes-heading-name)))

(provide 'ogent-notes)

;;; ogent-notes.el ends here
