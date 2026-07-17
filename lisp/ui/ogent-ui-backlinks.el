;;; ogent-ui-backlinks.el --- Backlink tracking for ogent handles -*- lexical-binding: t; -*-

;;; Commentary:
;; Track where @handles are referenced across Org buffers and org-roam.
;; Display backlinks in a dedicated buffer with clickable links.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'ogent-context)

;; Forward declarations for org-roam integration (optional).
;; `org-roam-node-file' is a cl-defstruct accessor, which check-declare
;; cannot resolve, hence the FILEONLY flag.
(declare-function org-roam-node-list "ext:org-roam-node")
(declare-function org-roam-node-file "ext:org-roam-node" (node) t)

;; Forward declaration for org-fold.
(declare-function org-fold-show-context "org-fold")

(defcustom ogent-backlinks-buffer-name "*ogent-backlinks*"
  "Buffer name for displaying backlinks."
  :type 'string
  :group 'ogent)

(defcustom ogent-backlinks-context-chars 80
  "Number of characters of context to show around each backlink reference."
  :type 'integer
  :group 'ogent)

(defcustom ogent-backlinks-max-buffers 50
  "Maximum number of buffers to scan for backlinks.
Set to nil to scan all buffers (may be slow)."
  :type '(choice integer (const nil))
  :group 'ogent)

(defun ogent-backlinks--org-buffers ()
  "Return a list of open Org buffers to scan for backlinks.
Respects `ogent-backlinks-max-buffers' limit for performance.
Only scans already-open buffers; does not load org-roam files."
  (let ((buffers nil)
        (count 0))
    ;; Collect open Org buffers
    (dolist (buf (buffer-list))
      (when (and (buffer-live-p buf)
                 (or (null ogent-backlinks-max-buffers)
                     (< count ogent-backlinks-max-buffers)))
        (when (eq (buffer-local-value 'major-mode buf) 'org-mode)
          (push buf buffers)
          (cl-incf count))))
    (nreverse buffers)))

(defun ogent-backlinks--extract-context (pos buffer)
  "Extract context around POS in BUFFER.
Returns a string of text surrounding the reference."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (let* ((line-start (line-beginning-position))
             (line-end (line-end-position))
             (start (max line-start
                         (- pos (/ ogent-backlinks-context-chars 2))))
             (end (min line-end
                       (+ pos (/ ogent-backlinks-context-chars 2))))
             (text (buffer-substring-no-properties start end)))
        ;; Trim and add ellipsis if truncated
        (concat (if (> start line-start) "..." "")
                (string-trim text)
                (if (< end line-end) "..." ""))))))

(defun ogent-backlinks--find-in-buffer (handle buffer)
  "Find all references to HANDLE in BUFFER.
Returns a list of plists with :line, :pos, and :context.
Uses word boundary matching - @ must be at word start, handle at word end."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (let ((references nil)
                ;; Match @handle where @ is preceded by whitespace/BOL and handle ends at word boundary
                (handle-pattern (concat "\\(?:^\\|[[:space:]]\\)\\(@"
                                        (regexp-quote handle)
                                        "\\)\\_>")))
            (while (re-search-forward handle-pattern nil t)
              (let* ((pos (match-beginning 1))  ; Start of @handle, not the whitespace
                     (line (line-number-at-pos pos))
                     (context (ogent-backlinks--extract-context pos buffer)))
                (push (list :line line
                            :pos pos
                            :context context)
                      references)))
            (nreverse references)))))))

;;;###autoload
(defun ogent-backlinks-for-handle (handle)
  "Scan all Org buffers for references to HANDLE.
Returns an alist of (BUFFER . REFERENCES) where REFERENCES is a list
of plists with :line, :pos, and :context."
  (cl-check-type handle string)
  (let ((results nil))
    (dolist (buffer (ogent-backlinks--org-buffers))
      (when-let ((refs (ogent-backlinks--find-in-buffer handle buffer)))
        (push (cons buffer refs) results)))
    (nreverse results)))

(defun ogent-backlinks--handle-at-point ()
  "Return the @handle at point or the handle for the current heading.
First tries to find a handle in the heading's OGENT_ID property,
then the heading title."
  (save-excursion
    (org-back-to-heading t)
    (let* ((element (org-element-at-point))
           (props (ogent-context--element-properties element (current-buffer)))
           (ogent-id (cdr (assoc "OGENT_ID" props)))
           (title (org-element-property :raw-value element)))
      (or ogent-id
          (when title
            (ogent-context--slug title))))))

(defun ogent-backlinks-at-point ()
  "Return backlinks for the handle of the current heading.
Return the same format as `ogent-backlinks-for-handle'.  This is a
data-returning helper for programmatic use; the user-facing command
is `ogent-show-backlinks' (registry `b') - 9cm triage removed the
autoload cookie and interactive form accordingly."
  (ogent-context--ensure-org)
  (if-let ((handle (ogent-backlinks--handle-at-point)))
      (ogent-backlinks-for-handle handle)
    (user-error "No handle found for current heading")))

(defun ogent-backlinks--insert-reference (buffer ref)
  "Insert a clickable reference line for REF in BUFFER.
Handles the case where buffer is killed or position is invalid."
  (let* ((line (plist-get ref :line))
         (pos (plist-get ref :pos))
         (context (plist-get ref :context))
         (buffer-name-str (buffer-name buffer))
         (start (point)))
    (insert (format "  Line %d: %s\n" line context))
    ;; Make the entire line clickable
    ;; Capture buffer-name-str for error message if buffer is killed
    (make-text-button start (point)
                      'action (lambda (_button)
                                (if (not (buffer-live-p buffer))
                                    (message "Buffer %s no longer exists" buffer-name-str)
                                  (pop-to-buffer buffer)
                                  (if (and (>= pos (point-min)) (<= pos (point-max)))
                                      (progn
                                        (goto-char pos)
                                        (if (fboundp 'org-fold-show-context)
                                            (org-fold-show-context)
                                          (with-no-warnings
                                            (org-show-context))))
                                    (message "Position %d is no longer valid in %s"
                                             pos buffer-name-str))))
                      'follow-link t
                      'help-echo (format "Jump to %s:%d"
                                         buffer-name-str
                                         line))))

(defun ogent-backlinks--format-buffer (handle backlinks)
  "Format BACKLINKS for HANDLE in an Org-mode buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (org-mode)
    (insert (format "#+title: Backlinks for @%s\n\n" handle))
    (if (null backlinks)
        (insert "No backlinks found.\n")
      (insert (format "* Backlinks (%d)\n\n"
                      (apply #'+ (mapcar (lambda (x) (length (cdr x)))
                                         backlinks))))
      (dolist (entry backlinks)
        (let ((buffer (car entry))
              (refs (cdr entry)))
          (insert (format "** %s (%d)\n"
                          (buffer-name buffer)
                          (length refs)))
          (dolist (ref refs)
            (ogent-backlinks--insert-reference buffer ref))
          (insert "\n"))))
    (goto-char (point-min))
    (org-next-visible-heading 1)))

;;;###autoload
(defun ogent-show-backlinks ()
  "Show backlinks for the current heading in a dedicated buffer.
The buffer displays all references to the current heading's handle
with clickable links to each reference location."
  (interactive)
  (ogent-context--ensure-org)
  (let* ((handle (ogent-backlinks--handle-at-point))
         (backlinks (ogent-backlinks-for-handle handle))
         (buffer (get-buffer-create ogent-backlinks-buffer-name)))
    (unless handle
      (user-error "No handle found for current heading"))
    (with-current-buffer buffer
      (ogent-backlinks--format-buffer handle backlinks))
    (display-buffer buffer)))

(provide 'ogent-ui-backlinks)

;;; ogent-ui-backlinks.el ends here
