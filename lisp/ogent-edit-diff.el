;;; ogent-edit-diff.el --- Magit-style diff UX for edit proposals -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a magit-section based buffer for reviewing and applying
;; multiple edit proposals with:
;; - Collapsible file and hunk sections
;; - Stage/unstage semantics for partial acceptance
;; - n/p navigation between hunks
;; - Batch accept/reject operations
;;
;; Soft dependency on magit-section - falls back to basic display if unavailable.

;;; Code:

(require 'cl-lib)
(require 'ogent-edit-parse)

;; Soft dependency on magit-section
(eval-and-compile
  (defvar ogent-edit-diff--magit-available
    (require 'magit-section nil t)
    "Non-nil if magit-section is available.")
  (when ogent-edit-diff--magit-available
    (require 'magit-section)))

;; Forward declarations for magit-section functions
(declare-function magit-insert-section "ext:magit-section")
(declare-function magit-insert-heading "ext:magit-section")
(declare-function magit-section-forward "ext:magit-section")
(declare-function magit-section-backward "ext:magit-section")
(declare-function magit-section-forward-sibling "ext:magit-section")
(declare-function magit-section-backward-sibling "ext:magit-section")
(declare-function magit-section-toggle "ext:magit-section")
(declare-function magit-current-section "ext:magit-section")
(defvar magit-section-visibility-indicator)

;; Forward declarations for eieio
(declare-function eieio-object-p "eieio-core")
(declare-function slot-exists-p "eieio-core")
(declare-function eieio-oref "eieio-core")

;;; Customization

(defgroup ogent-edit-diff nil
  "Magit-style diff UX for ogent edit proposals."
  :group 'ogent-edit)

(defcustom ogent-edit-diff-buffer-name "*ogent-edits*"
  "Name of the edit review buffer."
  :type 'string
  :group 'ogent-edit-diff)

(defcustom ogent-edit-diff-window-height 0.4
  "Height of diff window as fraction of frame height."
  :type 'float
  :group 'ogent-edit-diff)

;;; Faces

(defface ogent-edit-diff-file-heading
  '((t :inherit magit-section-heading :weight bold))
  "Face for file headings in diff buffer."
  :group 'ogent-edit-diff)

(defface ogent-edit-diff-hunk-heading
  '((t :inherit magit-diff-hunk-heading))
  "Face for hunk headings in diff buffer."
  :group 'ogent-edit-diff)

(defface ogent-edit-diff-staged
  '((t :inherit success))
  "Face for staged (to be accepted) edits."
  :group 'ogent-edit-diff)

(defface ogent-edit-diff-unstaged
  '((t :inherit warning))
  "Face for unstaged (pending) edits."
  :group 'ogent-edit-diff)

(defface ogent-edit-diff-added
  '((((class color) (background dark)) :foreground "#7ccd7c")
    (((class color) (background light)) :foreground "#228b22"))
  "Face for added lines."
  :group 'ogent-edit-diff)

(defface ogent-edit-diff-removed
  '((((class color) (background dark)) :foreground "#cd5c5c")
    (((class color) (background light)) :foreground "#b22222"))
  "Face for removed lines."
  :group 'ogent-edit-diff)

;;; Section Classes (when magit-section available)
;;
;; These are defined at load time when magit-section is available.
;; We use eval-when-compile to avoid warnings about undefined classes.


(when (bound-and-true-p ogent-edit-diff--magit-available)
  (require 'eieio)
  (eval '(progn
           (defclass ogent-edit-diff-root-section (magit-section) ()
             "Root section for edit diff buffer.")

           (defclass ogent-edit-diff-file-section (magit-section)
             ((file :initarg :file)
              (edits :initarg :edits))
             "Section representing a file with edits.")

           (defclass ogent-edit-diff-hunk-section (magit-section)
             ((edit :initarg :edit)
              (staged :initarg :staged :initform nil))
             "Section representing a single edit hunk."))))

;;; Buffer-local State

(defvar-local ogent-edit-diff--edits nil
  "List of edit structs displayed in this buffer.")

(defvar-local ogent-edit-diff--staged nil
  "Hash table of staged edit IDs.")

(defvar-local ogent-edit-diff--source-buffers nil
  "Hash table mapping file paths to source buffers.")

;;; Keymap

(defvar ogent-edit-diff-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Navigation
    (define-key map (kbd "n") #'ogent-edit-diff-next-hunk)
    (define-key map (kbd "p") #'ogent-edit-diff-prev-hunk)
    (define-key map (kbd "TAB") #'ogent-edit-diff-toggle-section)
    (define-key map (kbd "M-n") #'ogent-edit-diff-next-file)
    (define-key map (kbd "M-p") #'ogent-edit-diff-prev-file)
    ;; Stage/unstage
    (define-key map (kbd "s") #'ogent-edit-diff-stage)
    (define-key map (kbd "u") #'ogent-edit-diff-unstage)
    (define-key map (kbd "S") #'ogent-edit-diff-stage-all)
    (define-key map (kbd "U") #'ogent-edit-diff-unstage-all)
    ;; Apply
    (define-key map (kbd "a") #'ogent-edit-diff-accept-at-point)
    (define-key map (kbd "r") #'ogent-edit-diff-reject-at-point)
    (define-key map (kbd "A") #'ogent-edit-diff-accept-staged)
    (define-key map (kbd "R") #'ogent-edit-diff-reject-all)
    (define-key map (kbd "RET") #'ogent-edit-diff-goto-source)
    ;; Other
    (define-key map (kbd "g") #'ogent-edit-diff-refresh)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "?") #'ogent-edit-diff-help)
    map)
  "Keymap for `ogent-edit-diff-mode'.")

;;; Major Mode

(define-derived-mode ogent-edit-diff-mode special-mode "OgentDiff"
  "Major mode for reviewing ogent edit proposals.

\\{ogent-edit-diff-mode-map}"
  :group 'ogent-edit-diff
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (setq ogent-edit-diff--staged (make-hash-table :test 'equal))
  (setq ogent-edit-diff--source-buffers (make-hash-table :test 'equal))
  ;; Enable magit-section features if available
  (when (bound-and-true-p ogent-edit-diff--magit-available)
    (setq-local magit-section-visibility-indicator nil)))

;;; Buffer Construction

(defun ogent-edit-diff-show (edits)
  "Display EDITS in a magit-style diff buffer.
EDITS is a list of `ogent-edit' structs."
  (let ((buf (get-buffer-create ogent-edit-diff-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (ogent-edit-diff-mode)
        (setq ogent-edit-diff--edits edits)
        ;; Group edits by file
        (ogent-edit-diff--render edits)
        (goto-char (point-min))))
    ;; Display buffer
    (display-buffer buf
                    `((display-buffer-at-bottom)
                      (window-height . ,ogent-edit-diff-window-height)))
    buf))

(defun ogent-edit-diff--render (edits)
  "Render EDITS into current buffer."
  ;; Group by file
  (let ((by-file (ogent-edit-diff--group-by-file edits)))
    (if (bound-and-true-p ogent-edit-diff--magit-available)
        (ogent-edit-diff--render-magit by-file)
      (ogent-edit-diff--render-basic by-file))))

(defun ogent-edit-diff--group-by-file (edits)
  "Group EDITS by source file, returning alist of (file . edits)."
  (let ((groups (make-hash-table :test 'equal)))
    (dolist (edit edits)
      (let ((file (or (ogent-edit-source-file edit) "(buffer)")))
        (puthash file
                 (cons edit (gethash file groups))
                 groups)))
    ;; Convert to alist and reverse edit order within each group
    (let ((result nil))
      (maphash (lambda (file file-edits)
                 (push (cons file (nreverse file-edits)) result))
               groups)
      (nreverse result))))

;;; Magit-section Rendering

(defun ogent-edit-diff--render-magit (by-file)
  "Render BY-FILE alist using magit-section."
  (magit-insert-section (ogent-edit-diff-root-section)
    ;; Header
    (insert (propertize "Edit Proposals" 'face 'bold) "\n")
    (insert (format "  %d edit(s) in %d file(s)\n\n"
                    (length ogent-edit-diff--edits)
                    (length by-file)))
    ;; Staged/unstaged counts
    (ogent-edit-diff--insert-status-line)
    (insert "\n")
    ;; File sections
    (dolist (file-group by-file)
      (ogent-edit-diff--insert-file-section
       (car file-group) (cdr file-group)))))

(defun ogent-edit-diff--insert-status-line ()
  "Insert staged/unstaged status line."
  (let ((staged-count (hash-table-count ogent-edit-diff--staged))
        (total (length ogent-edit-diff--edits)))
    (insert (propertize "Staged: " 'face 'bold)
            (propertize (number-to-string staged-count)
                        'face 'ogent-edit-diff-staged)
            "  "
            (propertize "Unstaged: " 'face 'bold)
            (propertize (number-to-string (- total staged-count))
                        'face 'ogent-edit-diff-unstaged)
            "\n")))

(defun ogent-edit-diff--insert-file-section (file edits)
  "Insert a file section for FILE with its EDITS."
  (magit-insert-section (ogent-edit-diff-file-section
                         :file file :edits edits)
    ;; File heading
    (magit-insert-heading
      (propertize (format "  %s " (if (ogent-edit-diff--file-all-staged file edits)
                                      "+" "-"))
                  'face 'ogent-edit-diff-staged)
      (propertize file 'face 'ogent-edit-diff-file-heading)
      (propertize (format " (%d hunks)" (length edits))
                  'face 'shadow))
    ;; Edit hunks
    (dolist (edit edits)
      (ogent-edit-diff--insert-hunk-section edit))))

(defun ogent-edit-diff--file-all-staged (_file edits)
  "Return non-nil if all EDITS are staged.
_FILE is unused but kept for future per-file staging state."
  (cl-every (lambda (edit)
              (gethash (ogent-edit-id edit) ogent-edit-diff--staged))
            edits))

(defun ogent-edit-diff--insert-hunk-section (edit)
  "Insert a hunk section for EDIT."
  (let* ((id (ogent-edit-id edit))
         (staged (gethash id ogent-edit-diff--staged))
         (old-text (ogent-edit-old-text edit))
         (new-text (ogent-edit-new-text edit)))
    (magit-insert-section (ogent-edit-diff-hunk-section
                           :edit edit :staged staged)
      ;; Hunk heading with line info
      (magit-insert-heading
        (propertize (if staged "[staged] " "[      ] ")
                    'face (if staged 'ogent-edit-diff-staged
                            'ogent-edit-diff-unstaged))
        (propertize (format "@@ -%d,%d +%d,%d @@"
                            1 (length (split-string old-text "\n"))
                            1 (length (split-string new-text "\n")))
                    'face 'ogent-edit-diff-hunk-heading))
      ;; Diff content
      (ogent-edit-diff--insert-hunk-content old-text new-text))))

(defun ogent-edit-diff--insert-hunk-content (old-text new-text)
  "Insert diff content showing OLD-TEXT vs NEW-TEXT."
  ;; Removed lines
  (dolist (line (split-string old-text "\n"))
    (insert (propertize (concat "-" line "\n")
                        'face 'ogent-edit-diff-removed)))
  ;; Added lines
  (dolist (line (split-string new-text "\n"))
    (insert (propertize (concat "+" line "\n")
                        'face 'ogent-edit-diff-added))))

;;; Basic Rendering (fallback without magit-section)

(defun ogent-edit-diff--render-basic (by-file)
  "Render BY-FILE alist without magit-section."
  ;; Header
  (insert (propertize "Edit Proposals" 'face 'bold) "\n")
  (insert (format "  %d edit(s) in %d file(s)\n\n"
                  (length ogent-edit-diff--edits)
                  (length by-file)))
  ;; Each file
  (dolist (file-group by-file)
    (let ((file (car file-group))
          (edits (cdr file-group)))
      (insert (propertize file 'face 'ogent-edit-diff-file-heading) "\n")
      (dolist (edit edits)
        (ogent-edit-diff--insert-hunk-content
         (ogent-edit-old-text edit)
         (ogent-edit-new-text edit))
        (insert "\n")))))

;;; Navigation

(defun ogent-edit-diff-next-hunk ()
  "Move to next hunk section."
  (interactive)
  (if (bound-and-true-p ogent-edit-diff--magit-available)
      (magit-section-forward)
    (forward-line)))

(defun ogent-edit-diff-prev-hunk ()
  "Move to previous hunk section."
  (interactive)
  (if (bound-and-true-p ogent-edit-diff--magit-available)
      (magit-section-backward)
    (forward-line -1)))

(defun ogent-edit-diff-next-file ()
  "Move to next file section."
  (interactive)
  (when (bound-and-true-p ogent-edit-diff--magit-available)
    (magit-section-forward-sibling)))

(defun ogent-edit-diff-prev-file ()
  "Move to previous file section."
  (interactive)
  (when (bound-and-true-p ogent-edit-diff--magit-available)
    (magit-section-backward-sibling)))

(defun ogent-edit-diff-toggle-section ()
  "Toggle visibility of section at point."
  (interactive)
  (when (bound-and-true-p ogent-edit-diff--magit-available)
    (magit-section-toggle (magit-current-section))))

;;; Stage/Unstage

(defun ogent-edit-diff--current-edit ()
  "Get the edit at point."
  (when (bound-and-true-p ogent-edit-diff--magit-available)
    (when-let ((section (magit-current-section)))
      ;; Check if this section has an edit slot (hunk sections do)
      (when (and (eieio-object-p section)
                 (slot-exists-p section 'edit))
        (eieio-oref section 'edit)))))

(defun ogent-edit-diff-stage ()
  "Stage the edit at point for acceptance."
  (interactive)
  (if-let ((edit (ogent-edit-diff--current-edit)))
      (progn
        (puthash (ogent-edit-id edit) t ogent-edit-diff--staged)
        (ogent-edit-diff-refresh)
        (message "Staged edit"))
    (user-error "No edit at point")))

(defun ogent-edit-diff-unstage ()
  "Unstage the edit at point."
  (interactive)
  (if-let ((edit (ogent-edit-diff--current-edit)))
      (progn
        (remhash (ogent-edit-id edit) ogent-edit-diff--staged)
        (ogent-edit-diff-refresh)
        (message "Unstaged edit"))
    (user-error "No edit at point")))

(defun ogent-edit-diff-stage-all ()
  "Stage all edits."
  (interactive)
  (dolist (edit ogent-edit-diff--edits)
    (puthash (ogent-edit-id edit) t ogent-edit-diff--staged))
  (ogent-edit-diff-refresh)
  (message "Staged all %d edits" (length ogent-edit-diff--edits)))

(defun ogent-edit-diff-unstage-all ()
  "Unstage all edits."
  (interactive)
  (clrhash ogent-edit-diff--staged)
  (ogent-edit-diff-refresh)
  (message "Unstaged all edits"))

;;; Accept/Reject

(defun ogent-edit-diff-accept-at-point ()
  "Accept the edit at point."
  (interactive)
  (if-let ((edit (ogent-edit-diff--current-edit)))
      (progn
        (ogent-edit-diff--apply-edit edit)
        (setq ogent-edit-diff--edits
              (delq edit ogent-edit-diff--edits))
        (ogent-edit-diff-refresh)
        (message "Accepted edit"))
    (user-error "No edit at point")))

(defun ogent-edit-diff-reject-at-point ()
  "Reject the edit at point."
  (interactive)
  (if-let ((edit (ogent-edit-diff--current-edit)))
      (progn
        (setf (ogent-edit-status edit) 'rejected)
        (setq ogent-edit-diff--edits
              (delq edit ogent-edit-diff--edits))
        (ogent-edit-diff-refresh)
        (message "Rejected edit"))
    (user-error "No edit at point")))

(defun ogent-edit-diff-accept-staged ()
  "Accept all staged edits."
  (interactive)
  (let ((staged-edits
         (cl-remove-if-not
          (lambda (edit)
            (gethash (ogent-edit-id edit) ogent-edit-diff--staged))
          ogent-edit-diff--edits))
        (count 0))
    (unless staged-edits
      (user-error "No staged edits"))
    ;; Apply in reverse position order
    (dolist (edit (sort (copy-sequence staged-edits)
                        (lambda (a b)
                          (> (or (ogent-edit-start-pos a) 0)
                             (or (ogent-edit-start-pos b) 0)))))
      (ogent-edit-diff--apply-edit edit)
      (setq ogent-edit-diff--edits
            (delq edit ogent-edit-diff--edits))
      (cl-incf count))
    (clrhash ogent-edit-diff--staged)
    (ogent-edit-diff-refresh)
    (message "Accepted %d staged edits" count)))

(defun ogent-edit-diff-reject-all ()
  "Reject all remaining edits."
  (interactive)
  (when (yes-or-no-p (format "Reject all %d edits? "
                             (length ogent-edit-diff--edits)))
    (dolist (edit ogent-edit-diff--edits)
      (setf (ogent-edit-status edit) 'rejected))
    (setq ogent-edit-diff--edits nil)
    (ogent-edit-diff-refresh)
    (message "Rejected all edits")))

(defun ogent-edit-diff--apply-edit (edit)
  "Apply EDIT to its source buffer."
  (let ((buf (ogent-edit-source-buffer edit))
        (start (ogent-edit-start-pos edit))
        (end (ogent-edit-end-pos edit))
        (new-text (ogent-edit-new-text edit)))
    (unless (buffer-live-p buf)
      (user-error "Source buffer no longer exists"))
    (with-current-buffer buf
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (insert new-text)))
    (setf (ogent-edit-status edit) 'accepted)))

;;; Other Commands

(defun ogent-edit-diff-goto-source ()
  "Go to source location for edit at point."
  (interactive)
  (if-let ((edit (ogent-edit-diff--current-edit)))
      (let ((buf (ogent-edit-source-buffer edit))
            (pos (ogent-edit-start-pos edit)))
        (if (and buf (buffer-live-p buf) pos)
            (progn
              (pop-to-buffer buf)
              (goto-char pos))
          (user-error "Source location not available")))
    (user-error "No edit at point")))

(defun ogent-edit-diff-refresh ()
  "Refresh the diff buffer."
  (interactive)
  (when (eq major-mode 'ogent-edit-diff-mode)
    (let ((inhibit-read-only t)
          (pos (point)))
      (erase-buffer)
      (ogent-edit-diff--render ogent-edit-diff--edits)
      (goto-char (min pos (point-max))))))

(defun ogent-edit-diff-help ()
  "Show help for edit diff mode."
  (interactive)
  (message "n/p: next/prev hunk, s/u: stage/unstage, S/U: all, \
a/r: accept/reject, A: accept staged, R: reject all, RET: goto source"))

(provide 'ogent-edit-diff)

;;; ogent-edit-diff.el ends here
