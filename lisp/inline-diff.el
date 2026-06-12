;;; inline-diff.el --- Word-level inline diff highlighting -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides word-level inline diff display for showing changes between
;; old and new text. Used by ogent-edit-display.el for the inline-diff
;; display method.
;;
;; Key features:
;; - Word-level granularity (not just line-level)
;; - Overlay-based highlighting (non-destructive)
;; - Accept/reject individual changes
;; - Navigate between changes
;;
;; Usage:
;;   (inline-diff-words-region beg end old-text)
;;   - Compares buffer text in [beg, end) against old-text
;;   - Creates overlays showing word-level differences
;;
;; The text in the buffer is the "new" text, old-text is what it replaced.
;; Deletions from old-text are shown as struck-through insertions.
;; Changes are highlighted with faces.

;;; Code:

(require 'cl-lib)
(require 'diff)

;;; Customization

(defgroup inline-diff nil
  "Word-level inline diff highlighting."
  :group 'diff
  :prefix "inline-diff-")

(defface inline-diff-added
  '((((class color) (background dark))
     :background "#1a3a1a" :foreground "#7ccd7c")
    (((class color) (background light))
     :background "#e6ffe6" :foreground "#228b22"))
  "Face for added text."
  :group 'inline-diff)

(defface inline-diff-removed
  '((((class color) (background dark))
     :background "#3a1a1a" :foreground "#cd5c5c"
     :strike-through t)
    (((class color) (background light))
     :background "#ffe6e6" :foreground "#b22222"
     :strike-through t))
  "Face for removed text (shown as struck-through)."
  :group 'inline-diff)

(defface inline-diff-changed-old
  '((((class color) (background dark))
     :background "#3a2a1a" :foreground "#cdaa5c"
     :strike-through t)
    (((class color) (background light))
     :background "#fff0e6" :foreground "#b26222"
     :strike-through t))
  "Face for old text in a changed region."
  :group 'inline-diff)

(defface inline-diff-changed-new
  '((((class color) (background dark))
     :background "#1a3a2a" :foreground "#5ccdaa")
    (((class color) (background light))
     :background "#e6fff0" :foreground "#22b262"))
  "Face for new text in a changed region."
  :group 'inline-diff)

;;; Buffer-local state

(defvar-local inline-diff--overlays nil
  "List of overlays created by inline-diff.")

(defvar-local inline-diff--change-list nil
  "List of change records for navigation.
Each record is a plist with:
  :type - `added', `removed', or `changed'
  :start - buffer position
  :end - buffer position
  :overlay - the overlay object
  :old-text - original text (for removed/changed)
  :new-text - new text (for added/changed)")

(defvar-local inline-diff--current-index nil
  "Index of currently selected change, or nil.")

(defvar-local inline-diff--snapshots nil
  "Original text snapshots for reversible inline diffs.
Each entry is a plist with :beg marker, :end marker, and :old-text.")

;;; Snapshot tracking

(defun inline-diff--clear-snapshots ()
  "Release all inline-diff snapshot markers."
  (dolist (snapshot inline-diff--snapshots)
    (let ((beg (plist-get snapshot :beg))
          (end (plist-get snapshot :end)))
      (when (markerp beg)
        (set-marker beg nil))
      (when (markerp end)
        (set-marker end nil))))
  (setq inline-diff--snapshots nil))

(defun inline-diff--record-snapshot (beg end old-text)
  "Remember that [BEG, END) replaced OLD-TEXT."
  (push (list :beg (copy-marker beg)
              :end (copy-marker end t)
              :old-text old-text)
        inline-diff--snapshots))

(defun inline-diff--restore-snapshots ()
  "Restore every pending inline-diff snapshot.
Snapshots are restored from bottom to top so earlier replacements do
not invalidate later marker positions."
  (dolist (snapshot (sort (copy-sequence inline-diff--snapshots)
                          (lambda (a b)
                            (> (marker-position (plist-get a :beg))
                               (marker-position (plist-get b :beg))))))
    (let ((beg (plist-get snapshot :beg))
          (end (plist-get snapshot :end))
          (old-text (plist-get snapshot :old-text)))
      (when (and (markerp beg)
                 (markerp end)
                 (marker-position beg)
                 (marker-position end))
        (delete-region (marker-position beg) (marker-position end))
        (goto-char (marker-position beg))
        (insert old-text)))))

;;; Hooks

(defvar-local inline-diff-accept-hook nil
  "Hook run after inline-diff changes are accepted.")

(defvar-local inline-diff-reject-hook nil
  "Hook run after inline-diff changes are rejected and restored.")

;;; Word tokenization

(defun inline-diff--tokenize (text)
  "Split TEXT into tokens for word-level diffing.
Returns list of (token . position) pairs where position is
the offset in the original string."
  (let ((tokens nil)
        (pos 0)
        (len (length text)))
    (while (< pos len)
      (let ((char (aref text pos)))
        (cond
         ;; Whitespace - capture as token
         ((memq char '(?\s ?\t ?\n ?\r))
          (let ((start pos))
            (while (and (< pos len)
                        (memq (aref text pos) '(?\s ?\t ?\n ?\r)))
              (cl-incf pos))
            (push (cons (substring text start pos) start) tokens)))
         ;; Word characters - capture word
         ((or (and (>= char ?a) (<= char ?z))
              (and (>= char ?A) (<= char ?Z))
              (and (>= char ?0) (<= char ?9))
              (eq char ?_))
          (let ((start pos))
            (while (and (< pos len)
                        (let ((c (aref text pos)))
                          (or (and (>= c ?a) (<= c ?z))
                              (and (>= c ?A) (<= c ?Z))
                              (and (>= c ?0) (<= c ?9))
                              (eq c ?_))))
              (cl-incf pos))
            (push (cons (substring text start pos) start) tokens)))
         ;; Punctuation/symbols - single character token
         (t
          (push (cons (substring text pos (1+ pos)) pos) tokens)
          (cl-incf pos)))))
    (nreverse tokens)))

;;; LCS-based diff algorithm

(defun inline-diff--lcs (seq1 seq2)
  "Compute longest common subsequence of SEQ1 and SEQ2.
Returns list of (idx1 . idx2) pairs indicating matching positions."
  (let* ((len1 (length seq1))
         (len2 (length seq2))
         (dp (make-vector (1+ len1) nil)))
    ;; Initialize DP table
    (dotimes (i (1+ len1))
      (aset dp i (make-vector (1+ len2) 0)))
    ;; Fill DP table
    (dotimes (i len1)
      (dotimes (j len2)
        (if (equal (car (nth i seq1)) (car (nth j seq2)))
            (aset (aref dp (1+ i)) (1+ j)
                  (1+ (aref (aref dp i) j)))
          (aset (aref dp (1+ i)) (1+ j)
                (max (aref (aref dp i) (1+ j))
                     (aref (aref dp (1+ i)) j))))))
    ;; Backtrack to find LCS
    (let ((result nil)
          (i len1)
          (j len2))
      (while (and (> i 0) (> j 0))
        (cond
         ((equal (car (nth (1- i) seq1)) (car (nth (1- j) seq2)))
          (push (cons (1- i) (1- j)) result)
          (cl-decf i)
          (cl-decf j))
         ((> (aref (aref dp (1- i)) j)
             (aref (aref dp i) (1- j)))
          (cl-decf i))
         (t
          (cl-decf j))))
      result)))

(defun inline-diff--compute-changes (old-tokens new-tokens)
  "Compute changes between OLD-TOKENS and NEW-TOKENS.
Returns list of change operations:
  (:keep old-idx new-idx)
  (:remove old-idx)
  (:add new-idx)"
  (let ((lcs (inline-diff--lcs old-tokens new-tokens))
        (old-idx 0)
        (new-idx 0)
        (changes nil))
    (dolist (match lcs)
      (let ((old-match (car match))
            (new-match (cdr match)))
        ;; Emit removals for old tokens before match
        (while (< old-idx old-match)
          (push (list :remove old-idx) changes)
          (cl-incf old-idx))
        ;; Emit additions for new tokens before match
        (while (< new-idx new-match)
          (push (list :add new-idx) changes)
          (cl-incf new-idx))
        ;; Emit keep for match
        (push (list :keep old-idx new-idx) changes)
        (cl-incf old-idx)
        (cl-incf new-idx)))
    ;; Handle trailing tokens
    (while (< old-idx (length old-tokens))
      (push (list :remove old-idx) changes)
      (cl-incf old-idx))
    (while (< new-idx (length new-tokens))
      (push (list :add new-idx) changes)
      (cl-incf new-idx))
    (nreverse changes)))

;;; Overlay creation

(defun inline-diff--create-overlay (beg end type &optional props)
  "Create an inline-diff overlay from BEG to END with TYPE.
TYPE is `added', `removed', `changed-old', or `changed-new'.
PROPS is additional overlay properties."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'inline-diff t)
    (overlay-put ov 'inline-diff-type type)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'face (pcase type
                            ('added 'inline-diff-added)
                            ('removed 'inline-diff-removed)
                            ('changed-old 'inline-diff-changed-old)
                            ('changed-new 'inline-diff-changed-new)))
    (when props
      (cl-loop for (key val) on props by #'cddr
               do (overlay-put ov key val)))
    (push ov inline-diff--overlays)
    ov))

(defun inline-diff--insert-removed-text (pos text)
  "Insert removed TEXT at POS as a visible overlay.
The text is shown but not actually in the buffer."
  (let ((ov (make-overlay pos pos nil t nil)))
    (overlay-put ov 'inline-diff t)
    (overlay-put ov 'inline-diff-type 'removed)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'before-string
                 (propertize text 'face 'inline-diff-removed))
    (push ov inline-diff--overlays)
    ov))

;;; Main API

;;;###autoload
(defun inline-diff-words-region (beg end old-text &optional append)
  "Show word-level diff between OLD-TEXT and buffer text in [BEG, END).
Creates overlays to highlight additions, removals, and changes.
The buffer text is treated as the new/current version.
Unless APPEND is non-nil, clear existing inline diffs first."
  (unless append
    (inline-diff-clear))
  (inline-diff--record-snapshot beg end old-text)
  (let* ((new-text (buffer-substring-no-properties beg end))
         (old-tokens (inline-diff--tokenize old-text))
         (new-tokens (inline-diff--tokenize new-text))
         (changes (inline-diff--compute-changes old-tokens new-tokens))
         (pending-removes nil))
    ;; Process changes and create overlays
    (dolist (change changes)
      (pcase (car change)
        (:keep
         ;; Flush any pending removes before this keep
         (when pending-removes
           (let* ((first-remove (car (last pending-removes)))
                  (old-idx (cadr first-remove))
                  (_old-token (nth old-idx old-tokens))
                  (new-idx (caddr (car changes)))
                  (new-token (when new-idx (nth new-idx new-tokens)))
                  (insert-pos (if new-token
                                  (+ beg (cdr new-token))
                                beg)))
             ;; Combine all pending removed text
             (let ((removed-text
                    (mapconcat
                     (lambda (r)
                       (car (nth (cadr r) old-tokens)))
                     (reverse pending-removes) "")))
               (inline-diff--insert-removed-text insert-pos removed-text)
               (push (list :type 'removed
                           :start insert-pos
                           :end insert-pos
                           :old-text removed-text)
                     inline-diff--change-list)))
           (setq pending-removes nil)))
        (:remove
         ;; Queue removes to batch them
         (push change pending-removes))
        (:add
         ;; Flush pending removes first, then handle add
         (when pending-removes
           (let* ((new-idx (cadr change))
                  (new-token (nth new-idx new-tokens))
                  (insert-pos (+ beg (cdr new-token))))
             (let ((removed-text
                    (mapconcat
                     (lambda (r)
                       (car (nth (cadr r) old-tokens)))
                     (reverse pending-removes) "")))
               (inline-diff--insert-removed-text insert-pos removed-text)
               (push (list :type 'removed
                           :start insert-pos
                           :end insert-pos
                           :old-text removed-text)
                     inline-diff--change-list)))
           (setq pending-removes nil))
         ;; Create add overlay
         (let* ((new-idx (cadr change))
                (new-token (nth new-idx new-tokens))
                (token-start (+ beg (cdr new-token)))
                (token-end (+ token-start (length (car new-token)))))
           (inline-diff--create-overlay token-start token-end 'added)
           (push (list :type 'added
                       :start token-start
                       :end token-end
                       :new-text (car new-token))
                 inline-diff--change-list)))))
    ;; Flush any trailing removes
    (when pending-removes
      (let ((removed-text
             (mapconcat
              (lambda (r)
                (car (nth (cadr r) old-tokens)))
              (reverse pending-removes) "")))
        (inline-diff--insert-removed-text end removed-text)
        (push (list :type 'removed
                    :start end
                    :end end
                    :old-text removed-text)
              inline-diff--change-list)))
    ;; Sort change list by position
    (setq inline-diff--change-list
          (sort inline-diff--change-list
                (lambda (a b)
                  (< (plist-get a :start) (plist-get b :start)))))
    ;; Enable mode
    (inline-diff-mode 1)))

;;;###autoload
(defun inline-diff-clear (&optional keep-snapshots)
  "Remove all inline-diff overlays from current buffer.
When KEEP-SNAPSHOTS is non-nil, keep restoration snapshots."
  (interactive)
  (dolist (ov inline-diff--overlays)
    (when (overlay-buffer ov)
      (delete-overlay ov)))
  (unless keep-snapshots
    (inline-diff--clear-snapshots))
  (setq inline-diff--overlays nil
        inline-diff--change-list nil
        inline-diff--current-index nil))

;;; Navigation

(defun inline-diff-next-change ()
  "Move to next change."
  (interactive)
  (if (null inline-diff--change-list)
      (user-error "No inline diff changes")
    (let ((pos (point))
          (found nil))
      (cl-loop for change in inline-diff--change-list
               for i from 0
               when (> (plist-get change :start) pos)
               do (setq found i)
               and return nil)
      (if found
          (progn
            (setq inline-diff--current-index found)
            (goto-char (plist-get (nth found inline-diff--change-list) :start)))
        (user-error "No more changes")))))

(defun inline-diff-previous-change ()
  "Move to previous change."
  (interactive)
  (if (null inline-diff--change-list)
      (user-error "No inline diff changes")
    (let ((pos (point))
          (found nil))
      (cl-loop for change in (reverse inline-diff--change-list)
               for i from (1- (length inline-diff--change-list)) downto 0
               when (< (plist-get change :start) pos)
               do (setq found i)
               and return nil)
      (if found
          (progn
            (setq inline-diff--current-index found)
            (goto-char (plist-get (nth found inline-diff--change-list) :start)))
        (user-error "No previous changes")))))

;;; Accept/Reject

(defun inline-diff-accept-all ()
  "Accept all changes (keep buffer as-is, remove overlays)."
  (interactive)
  (inline-diff-clear)
  (run-hooks 'inline-diff-accept-hook)
  (inline-diff-mode -1)
  (message "All changes accepted"))

(defun inline-diff-reject-all ()
  "Reject all changes and restore the original text snapshots."
  (interactive)
  (if (yes-or-no-p "Reject all inline-diff changes and restore original text? ")
      (progn
        (inline-diff--restore-snapshots)
        (inline-diff-clear)
        (run-hooks 'inline-diff-reject-hook)
        (inline-diff-mode -1)
        (message "All changes rejected and original text restored"))
    (message "Cancelled")))

;;; Minor mode

(defvar inline-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-n") #'inline-diff-next-change)
    (define-key map (kbd "M-p") #'inline-diff-previous-change)
    (define-key map (kbd "C-c C-c") #'inline-diff-accept-all)
    (define-key map (kbd "C-c C-k") #'inline-diff-reject-all)
    map)
  "Keymap for `inline-diff-mode'.")

;;;###autoload
(define-minor-mode inline-diff-mode
  "Minor mode for inline word-level diff display.

\\{inline-diff-mode-map}"
  :lighter " InlDiff"
  :keymap inline-diff-mode-map
  (if inline-diff-mode
      (message "Inline diff: M-n/M-p navigate, C-c C-c accept, C-c C-k reject")
    (inline-diff-clear)))

(provide 'inline-diff)

;;; inline-diff.el ends here
