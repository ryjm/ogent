;;; ogent-issues-edit.el --- AI-assisted issue editing -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides AI-assisted editing for beads issues.
;; Uses gptel to send issue content to LLM and parse responses.
;; Shows diff preview before applying changes.

;;; Code:

(require 'cl-lib)
(require 'ogent-issues-bd)

;; Forward declarations
(declare-function ogent-issues-detail-refresh "ogent-issues")
(declare-function gptel-request "ext:gptel")
(defvar gptel-model)
(defvar ogent-issues-detail--issue)

;;; Customization

(defgroup ogent-issues-edit nil
  "AI-assisted issue editing."
  :group 'ogent-issues)

(defcustom ogent-issues-edit-model nil
  "Model to use for AI editing.
If nil, uses the default gptel model."
  :type '(choice (const :tag "Default" nil)
                 (string :tag "Model name"))
  :group 'ogent-issues-edit)

;;; Preview Buffer

(defvar ogent-issues-edit-preview-buffer "*ogent-issue-edit-preview*"
  "Buffer name for edit preview.")

(defvar ogent-issues-edit-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "y" #'ogent-issues-edit-apply)
    (define-key map "n" #'ogent-issues-edit-reject)
    (define-key map "e" #'ogent-issues-edit-manual)
    (define-key map "q" #'ogent-issues-edit-reject)
    map)
  "Keymap for issue edit preview.")

(define-derived-mode ogent-issues-edit-preview-mode special-mode "Issue-Edit-Preview"
  "Mode for previewing AI-suggested issue edits."
  :group 'ogent-issues-edit
  (setq-local header-line-format
              '(" Review Changes | "
                (:propertize "y" face transient-key) ":apply "
                (:propertize "n" face transient-key) ":reject "
                (:propertize "e" face transient-key) ":edit manually")))

;;; State

(defvar-local ogent-issues-edit--issue-id nil
  "ID of issue being edited.")

(defvar-local ogent-issues-edit--old-title nil
  "Original title before edit.")

(defvar-local ogent-issues-edit--new-title nil
  "New title suggested by AI.")

(defvar-local ogent-issues-edit--old-description nil
  "Original description before edit.")

(defvar-local ogent-issues-edit--new-description nil
  "New description suggested by AI.")

;;; Main Entry Point

;;;###autoload
(defun ogent-issues-ai-edit ()
  "Use AI to edit the current issue.
Prompts for an edit instruction, sends to LLM, and shows diff preview."
  (interactive)
  (unless (bound-and-true-p ogent-issues-detail--issue)
    (user-error "Must be viewing an issue to edit it"))
  (unless (fboundp 'gptel-request)
    (user-error "gptel is required for AI editing. Install it with: M-x package-install RET gptel RET"))
  (let* ((issue ogent-issues-detail--issue)
         (id (plist-get issue :id))
         (title (plist-get issue :title))
         (description (or (plist-get issue :description) ""))
         (instruction (read-string (format "How should I edit %s? " id))))
    (when (string-empty-p instruction)
      (user-error "Edit instruction cannot be empty"))
    (message "Asking AI to edit %s..." id)
    (gptel-request
     (ogent-issues-edit--build-prompt title description instruction)
     :callback (lambda (response _info)
                 (if response
                     (ogent-issues-edit--handle-response id title description response)
                   (message "AI edit failed - no response"))))))

;;; Prompt Building

(defun ogent-issues-edit--build-prompt (title description instruction)
  "Build prompt for AI to edit issue with TITLE, DESCRIPTION per INSTRUCTION."
  (format "You are editing a software issue/task. Apply the user's instruction to improve the issue.

Current issue:
TITLE: %s

DESCRIPTION:
%s

User instruction: %s

Respond with the edited issue in this exact format:
TITLE: <new title>

DESCRIPTION:
<new description>

Only include TITLE and DESCRIPTION sections. Keep the format exact.
If a field doesn't need changes, keep the original value.
Be concise and clear. Use markdown in the description if helpful."
          title
          (if (string-empty-p description) "(empty)" description)
          instruction))

;;; Response Handling

(defun ogent-issues-edit--handle-response (id old-title old-description response)
  "Handle AI RESPONSE for issue ID with OLD-TITLE and OLD-DESCRIPTION."
  (let ((new-title old-title)
        (new-description old-description))
    ;; Parse title
    (when (string-match "^TITLE: \\(.+\\)$" response)
      (setq new-title (string-trim (match-string 1 response))))
    ;; Parse description (everything after DESCRIPTION: until end)
    (when (string-match "DESCRIPTION:\n\\(\\(?:.\\|\n\\)*\\)" response)
      (setq new-description (string-trim (match-string 1 response))))
    ;; Check if anything changed
    (if (and (equal new-title old-title)
             (equal new-description old-description))
        (message "AI made no changes")
      ;; Show preview
      (ogent-issues-edit--show-preview id old-title new-title old-description new-description))))

(defun ogent-issues-edit--show-preview (id old-title new-title old-desc new-desc)
  "Show preview buffer comparing old and new values."
  (let ((buf (get-buffer-create ogent-issues-edit-preview-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-issues-edit-preview-mode)
        ;; Store state
        (setq ogent-issues-edit--issue-id id
              ogent-issues-edit--old-title old-title
              ogent-issues-edit--new-title new-title
              ogent-issues-edit--old-description old-desc
              ogent-issues-edit--new-description new-desc)
        ;; Render preview
        (insert (propertize (format "Issue: %s\n" id) 'face 'bold))
        (insert (make-string 50 ?─) "\n\n")
        ;; Title diff
        (unless (equal old-title new-title)
          (insert (propertize "[Title]\n" 'face 'ogent-issues-section-heading))
          (insert (propertize (format "- %s\n" old-title) 'face 'diff-removed))
          (insert (propertize (format "+ %s\n" new-title) 'face 'diff-added))
          (insert "\n"))
        ;; Description diff
        (unless (equal old-desc new-desc)
          (insert (propertize "[Description]\n" 'face 'ogent-issues-section-heading))
          (dolist (line (split-string old-desc "\n"))
            (insert (propertize (format "- %s\n" line) 'face 'diff-removed)))
          (insert "\n")
          (dolist (line (split-string new-desc "\n"))
            (insert (propertize (format "+ %s\n" line) 'face 'diff-added)))
          (insert "\n"))
        (insert (make-string 50 ?─) "\n")
        (insert (propertize "Apply changes? (y/n/e)" 'face 'bold))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;; Preview Actions

(defun ogent-issues-edit-apply ()
  "Apply the AI-suggested changes."
  (interactive)
  (let ((id ogent-issues-edit--issue-id)
        (new-title ogent-issues-edit--new-title)
        (old-title ogent-issues-edit--old-title)
        (new-desc ogent-issues-edit--new-description)
        (old-desc ogent-issues-edit--old-description))
    (quit-window t)
    ;; Build update args
    (let ((args (list id (lambda ()
                           (message "Applied AI edits to %s" id)
                           (when-let ((buf (get-buffer "*ogent-issue*")))
                             (with-current-buffer buf
                               (ogent-issues-detail-refresh)))))))
      ;; Add changed fields
      (unless (equal new-title old-title)
        (setq args (append args (list :title new-title))))
      (unless (equal new-desc old-desc)
        (setq args (append args (list :description new-desc))))
      (setq args (append args (list :error-callback
                                    (lambda (err)
                                      (message "Failed to apply edits: %s" err)))))
      (apply #'ogent-issues-bd-update args))))

(defun ogent-issues-edit-reject ()
  "Reject the AI-suggested changes."
  (interactive)
  (quit-window t)
  (message "Changes rejected"))

(defun ogent-issues-edit-manual ()
  "Open a buffer to manually edit the AI suggestions before applying."
  (interactive)
  (let ((id ogent-issues-edit--issue-id)
        (new-title ogent-issues-edit--new-title)
        (new-desc ogent-issues-edit--new-description))
    (quit-window t)
    ;; Open edit buffer with suggested content
    (let ((buf (get-buffer-create "*ogent-issue-manual-edit*")))
      (with-current-buffer buf
        (erase-buffer)
        (text-mode)
        (setq-local ogent-issues-edit--issue-id id)
        (insert "# Edit Issue\n\n")
        (insert (format "Title: %s\n\n" new-title))
        (insert "Description:\n")
        (insert new-desc)
        (insert "\n\n")
        (insert "<!-- C-c C-c to save, C-c C-k to cancel -->\n")
        (local-set-key (kbd "C-c C-c") #'ogent-issues-edit-manual-save)
        (local-set-key (kbd "C-c C-k") #'ogent-issues-edit-manual-cancel)
        (setq-local header-line-format
                    '(" Manual Edit | C-c C-c: save | C-c C-k: cancel"))
        (goto-char (point-min))
        (search-forward "Title: " nil t))
      (pop-to-buffer buf))))

(defun ogent-issues-edit-manual-save ()
  "Save manual edits."
  (interactive)
  (let ((content (buffer-string))
        (id ogent-issues-edit--issue-id)
        title description)
    ;; Parse title
    (when (string-match "^Title: \\(.+\\)$" content)
      (setq title (string-trim (match-string 1 content))))
    ;; Parse description
    (when (string-match "Description:\n\\(\\(?:.\\|\n\\)*?\\)\n\n<!--" content)
      (setq description (string-trim (match-string 1 content))))
    (unless title
      (user-error "Title is required"))
    (kill-buffer)
    (ogent-issues-bd-update id
                            (lambda ()
                              (message "Saved manual edits to %s" id)
                              (when-let ((buf (get-buffer "*ogent-issue*")))
                                (with-current-buffer buf
                                  (ogent-issues-detail-refresh))))
                            :title title
                            :description description
                            :error-callback
                            (lambda (err)
                              (message "Failed to save: %s" err)))))

(defun ogent-issues-edit-manual-cancel ()
  "Cancel manual edit."
  (interactive)
  (kill-buffer)
  (message "Edit cancelled"))

(provide 'ogent-issues-edit)

;;; ogent-issues-edit.el ends here
