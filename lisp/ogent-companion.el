;;; ogent-companion.el --- Companion Org buffer management -*- lexical-binding: t; -*-

;;; Commentary:
;; Manages companion Org buffers for non-Org-mode buffers.
;; Implements the Buffer Linking architecture from specs/architecture.org:40-45.

;;; Code:

(require 'cl-lib)
(require 'org)

(defgroup ogent-companion nil
  "Companion buffer management for ogent."
  :group 'ogent)

(defcustom ogent-companion-buffer-name-function
  #'ogent-companion--default-buffer-name
  "Function to generate companion buffer names.
Called with the source buffer as argument, should return a string."
  :type 'function
  :group 'ogent-companion)

(defcustom ogent-companion-display-action
  '((ogent-companion--display-buffer-popup-or-side)
    (side . right)
    (window-width . 0.3))
  "Display action for companion buffers.
Uses Doom's popup system if available, otherwise a side window."
  :type 'sexp
  :group 'ogent-companion)

(defvar-local ogent-companion--linked-buffer nil
  "Buffer-local variable pointing to the companion buffer.
In source buffers: points to the Org companion buffer.
In companion Org buffers: points back to the source buffer.")

(defvar-local ogent-session-buffer-p nil
  "Non-nil if this buffer is an ogent session buffer.
Session buffers always append new content at `point-max',
ignoring the current cursor position.")

(defun ogent-companion--default-buffer-name (source-buffer)
  "Generate default companion buffer name for SOURCE-BUFFER.
Format: *ogent:<file>* or *ogent:<buffer-name>* for non-file buffers."
  (let ((name (or (buffer-file-name source-buffer)
                  (buffer-name source-buffer))))
    (format "*ogent:%s*" (file-name-nondirectory name))))

(defun ogent-companion--org-buffer-p (&optional buffer)
  "Return non-nil if BUFFER (or current buffer) is in org-mode."
  (with-current-buffer (or buffer (current-buffer))
    (derived-mode-p 'org-mode)))

(defun ogent-companion--get-linked-buffer (&optional buffer)
  "Return the linked companion buffer for BUFFER, or nil if none exists.
BUFFER defaults to the current buffer."
  (let* ((buf (or buffer (current-buffer)))
         (linked (buffer-local-value 'ogent-companion--linked-buffer buf)))
    (when (and linked (buffer-live-p linked))
      linked)))

(defun ogent-companion--link-buffers (source-buffer companion-buffer)
  "Establish bidirectional link between SOURCE-BUFFER and COMPANION-BUFFER.
Automatically persists the link if SOURCE-BUFFER is file-backed."
  (with-current-buffer source-buffer
    (setq-local ogent-companion--linked-buffer companion-buffer))
  (with-current-buffer companion-buffer
    (setq-local ogent-companion--linked-buffer source-buffer))
  ;; Save the link persistently
  (ogent-companion--save-link source-buffer companion-buffer))

(defun ogent-companion--create-companion (source-buffer)
  "Create a new companion Org buffer for SOURCE-BUFFER.
The buffer is created but not displayed.  Returns the companion buffer."
  (let* ((name (funcall ogent-companion-buffer-name-function source-buffer))
         (companion (get-buffer-create name)))
    (with-current-buffer companion
      (unless (derived-mode-p 'org-mode)
        (org-mode))
      ;; Mark as session buffer for append-at-end behavior
      (setq-local ogent-session-buffer-p t)
      ;; Initialize with a basic header
      (when (zerop (buffer-size))
        (insert (format "#+title: Ogent Session for %s\n\n"
                        (buffer-name source-buffer)))
        (insert "* Session\n")))
    (ogent-companion--link-buffers source-buffer companion)
    companion))

(defun ogent-companion--reuse-or-create (source-buffer)
  "Get or create companion Org buffer for SOURCE-BUFFER.
Reuses existing companion if linked, otherwise creates a new one.
Returns the companion buffer."
  (or (ogent-companion--get-linked-buffer source-buffer)
      (ogent-companion--create-companion source-buffer)))

;;;###autoload
(defun ogent-companion-get-or-create (&optional buffer)
  "Get or create the companion Org buffer for BUFFER.
If BUFFER is already an Org buffer, return it directly.
Otherwise, get or create a companion Org buffer and return that.
BUFFER defaults to the current buffer."
  (let ((source (or buffer (current-buffer))))
    (if (ogent-companion--org-buffer-p source)
        source
      (ogent-companion--reuse-or-create source))))

;;;###autoload
(defun ogent-companion-source-buffer (&optional buffer)
  "Return the source buffer for a companion BUFFER.
If BUFFER is a companion Org buffer, return its linked source buffer.
If BUFFER is not a companion, return BUFFER itself.
BUFFER defaults to the current buffer."
  (let ((buf (or buffer (current-buffer))))
    (if (and (ogent-companion--org-buffer-p buf)
             (ogent-companion--get-linked-buffer buf))
        (ogent-companion--get-linked-buffer buf)
      buf)))

;;;###autoload
(defun ogent-companion-display (&optional buffer)
  "Display the companion buffer for BUFFER.
Creates one if it doesn't exist.  BUFFER defaults to current buffer.
Returns the companion buffer."
  (interactive)
  (let ((companion (ogent-companion-get-or-create buffer)))
    (when (called-interactively-p 'any)
      (pop-to-buffer companion))
    companion))

;;; Persistence via file-local variables

(defcustom ogent-companion-persist-links t
  "When non-nil, persist companion buffer links for file-backed buffers."
  :type 'boolean
  :group 'ogent-companion)

(defcustom ogent-companion-link-registry-file
  (expand-file-name "ogent-companion-links.el" user-emacs-directory)
  "File used to store persistent source-to-companion links."
  :type 'file
  :group 'ogent-companion)

(defvar-local ogent-companion-file nil
  "File-local variable storing the companion buffer's file path or name.
For file-backed companions, this is the file path.
For temp companions, this is the buffer name.
This is saved in file-local variables to persist across sessions.")

(defun ogent-companion--get-companion-identifier (buffer)
  "Return a persistent identifier for BUFFER.
Returns file path if BUFFER is file-backed, otherwise buffer name."
  (or (buffer-file-name buffer)
      (buffer-name buffer)))

(defun ogent-companion--get-source-identifier (buffer)
  "Return the persistent source identifier for BUFFER."
  (when-let ((file (buffer-file-name buffer)))
    (expand-file-name file)))

(defun ogent-companion--read-link-registry ()
  "Read the persistent companion link registry."
  (condition-case nil
      (when (file-readable-p ogent-companion-link-registry-file)
        (with-temp-buffer
          (insert-file-contents ogent-companion-link-registry-file)
          (goto-char (point-min))
          (let ((data (read (current-buffer))))
            (when (listp data)
              data))))
    (error nil)))

(defun ogent-companion--write-link-registry (registry)
  "Write REGISTRY to `ogent-companion-link-registry-file'."
  (when-let ((dir (file-name-directory ogent-companion-link-registry-file)))
    (make-directory dir t))
  (with-temp-file ogent-companion-link-registry-file
    (insert ";; ogent companion links\n")
    (prin1 registry (current-buffer))
    (insert "\n")))

(defun ogent-companion--save-persistent-link (source-buffer companion-buffer)
  "Persist the link between SOURCE-BUFFER and COMPANION-BUFFER."
  (when-let* ((source-id (ogent-companion--get-source-identifier source-buffer))
              (companion-id (ogent-companion--get-companion-identifier companion-buffer)))
    (let ((registry (assoc-delete-all
                     source-id
                     (copy-sequence (ogent-companion--read-link-registry)))))
      (push (cons source-id companion-id) registry)
      (ogent-companion--write-link-registry registry))))

(defun ogent-companion--lookup-persistent-link (source-buffer)
  "Return the persisted companion identifier for SOURCE-BUFFER."
  (when-let ((source-id (ogent-companion--get-source-identifier source-buffer)))
    (cdr (assoc source-id (ogent-companion--read-link-registry)))))

(defun ogent-companion--delete-persistent-link (source-buffer)
  "Remove SOURCE-BUFFER from the persistent companion link registry."
  (when-let ((source-id (ogent-companion--get-source-identifier source-buffer)))
    (let ((registry (assoc-delete-all
                     source-id
                     (copy-sequence (ogent-companion--read-link-registry)))))
      (ogent-companion--write-link-registry registry))))

(defun ogent-companion--find-or-create-from-identifier (identifier)
  "Find or create a companion buffer from IDENTIFIER.
If IDENTIFIER is a file path, open the file.
If IDENTIFIER is a buffer name, get or create that buffer."
  (cond
   ;; File path - open it
   ((and (stringp identifier)
         (file-name-absolute-p identifier)
         (file-exists-p identifier))
    (find-file-noselect identifier))
   ;; Buffer name - get or create it
   ((and (stringp identifier)
         (string-prefix-p "*ogent:" identifier))
    (get-buffer-create identifier))
   (t nil)))

(defun ogent-companion--save-link (source-buffer companion-buffer)
  "Save the link from SOURCE-BUFFER to COMPANION-BUFFER persistently.
Only works if SOURCE-BUFFER is file-backed and persistence is enabled.
Saves either the companion's file path or buffer name."
  (when (and ogent-companion-persist-links
             (buffer-file-name source-buffer))
    (with-current-buffer source-buffer
      (let ((identifier (ogent-companion--get-companion-identifier companion-buffer)))
        (when identifier
          (setq-local ogent-companion-file identifier)
          (ogent-companion--save-persistent-link source-buffer companion-buffer))))))

(defun ogent-companion--restore-link ()
  "Restore companion buffer link from file-local variables.
Called via `hack-local-variables-hook' when a file is opened.
Handles both file-backed and temp companion buffers."
  (when (and ogent-companion-persist-links
             (not ogent-companion--linked-buffer))
    (let* ((identifier (or ogent-companion-file
                           (ogent-companion--lookup-persistent-link
                            (current-buffer))))
           (companion (ogent-companion--find-or-create-from-identifier
                       identifier)))
      (when (buffer-live-p companion)
        (setq-local ogent-companion-file identifier)
        (with-current-buffer companion
          (unless (derived-mode-p 'org-mode)
            (org-mode)))
        (ogent-companion--link-buffers (current-buffer) companion)))))

(defun ogent-companion--setup-persistence ()
  "Set up hooks for companion buffer persistence."
  (add-hook 'hack-local-variables-hook #'ogent-companion--restore-link))

;; Set up persistence hooks when this module loads
(ogent-companion--setup-persistence)

;;; Display Functions

(defun ogent-companion--display-buffer-popup-or-side (buffer alist)
  "Display BUFFER as Doom popup or side window.
ALIST contains display parameters.  Uses Doom's popup system when
available, otherwise falls back to a standard side window."
  (cond
   ;; Doom Emacs +popup system
   ((and (boundp '+popup-mode) +popup-mode
         (fboundp '+popup-buffer))
    (+popup-buffer buffer
                   `((side . ,(or (alist-get 'side alist) 'right))
                     (size . ,(or (alist-get 'window-width alist) 0.3))
                     (slot . 1)
                     (vslot . 1)
                     (ttl . nil)
                     (quit . current)
                     (select . nil))))
   ;; Standard side window fallback
   (t
    (display-buffer-in-side-window
     buffer
     `((side . ,(or (alist-get 'side alist) 'right))
       (slot . 1)
       (window-width . ,(or (alist-get 'window-width alist) 0.3))
       (preserve-size . (t . nil))
       (inhibit-same-window . t))))))

;;;###autoload
(defun ogent-companion-display-buffer (buffer)
  "Display BUFFER using `ogent-companion-display-action'."
  (display-buffer buffer ogent-companion-display-action))

;;;###autoload
(defun ogent-companion-save-link (&optional buffer)
  "Save the companion buffer link for BUFFER to file-local variables.
This allows the association to survive buffer reloads.
BUFFER defaults to the current buffer.  Only works for file-backed buffers."
  (interactive)
  (let* ((buf (or buffer (current-buffer)))
         (companion (ogent-companion--get-linked-buffer buf)))
    (when companion
      (ogent-companion--save-link buf companion)
      (when (called-interactively-p 'any)
        (message "Companion link saved for %s" (buffer-name buf))))))

(defun ogent-companion--list-org-buffers ()
  "Return a list of Org buffers suitable for companion selection."
  (cl-remove-if-not
   (lambda (buf)
     ;; Use buffer-local-value for 50x faster access (see elisp-handbook.org)
     (eq (buffer-local-value 'major-mode buf) 'org-mode))
   (buffer-list)))

;;;###autoload
(defun ogent-companion-rebind (&optional buffer new-companion)
  "Rebind the companion buffer for BUFFER to NEW-COMPANION.
BUFFER defaults to the current buffer.
When called interactively, prompts for the new companion Org buffer."
  (interactive
   (let* ((org-buffers (ogent-companion--list-org-buffers))
          (buffer-names (mapcar #'buffer-name org-buffers))
          (current-companion (ogent-companion--get-linked-buffer))
          (default (when current-companion (buffer-name current-companion)))
          (selection (completing-read
                      (format "Select companion Org buffer%s: "
                              (if default
                                  (format " (current: %s)" default)
                                ""))
                      buffer-names nil t nil nil default)))
     (list (current-buffer) (get-buffer selection))))
  (let ((buf (or buffer (current-buffer))))
    (if (and new-companion (buffer-live-p new-companion))
        (progn
          ;; Clear old link if exists
          (when-let ((old-companion (ogent-companion--get-linked-buffer buf)))
            (with-current-buffer old-companion
              (setq-local ogent-companion--linked-buffer nil)))
          ;; Establish new link
          (ogent-companion--link-buffers buf new-companion)
          (when (called-interactively-p 'any)
            (message "Companion buffer set to %s" (buffer-name new-companion))))
      (user-error "No valid Org buffer selected"))))

;;;###autoload
(defun ogent-companion-unlink (&optional buffer)
  "Remove the companion buffer link from BUFFER.
BUFFER defaults to the current buffer."
  (interactive)
  (let* ((buf (or buffer (current-buffer)))
         (companion (ogent-companion--get-linked-buffer buf)))
    (when companion
      (with-current-buffer companion
        (setq-local ogent-companion--linked-buffer nil))
      (with-current-buffer buf
        (ogent-companion--delete-persistent-link buf)
        (setq-local ogent-companion--linked-buffer nil)
        (setq-local ogent-companion-file nil))
      (when (called-interactively-p 'any)
        (message "Companion buffer unlinked")))))

(provide 'ogent-companion)

;;; ogent-companion.el ends here
