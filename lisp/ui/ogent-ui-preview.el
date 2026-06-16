;;; ogent-ui-preview.el --- Context preview side window -*- lexical-binding: t; -*-

;;; Commentary:
;; Renders the current subtree/ask context into a side preview buffer and
;; overlays a diff between successive previews.  Distinct from the
;; inline-edit diff machinery in `ogent-ui-toolcalls'.

;;; Code:

(require 'ogent-ui-core)
(require 'ogent-ui-format)
(require 'ogent-context)

(defvar ogent-zen-mode)

;; Zen context transform (decoupled: declare + fboundp, never required).
(declare-function ogent-zen--heading-point "ogent-zen" () t)
(declare-function ogent-zen--context-transform "ogent-zen" (context point) t)
(declare-function ogent-context-build-with-source "ogent-context")
;; Companion-context helper lives in the send layer; resolved at call time.
(declare-function ogent-ui--ensure-companion-context "ogent-ui-send")

(defcustom ogent-context-preview-buffer-name "*ogent-context*"
  "Buffer used to display the context summary."
  :type 'string
  :group 'ogent-mode)

(defface ogent-context-diff-added
  '((((class color) (background light)) :background "#d0ffd0")
    (((class color) (background dark)) :background "#004400"))
  "Face for lines added to context."
  :group 'ogent-mode)

(defface ogent-context-diff-removed
  '((((class color) (background light)) :background "#ffd0d0")
    (((class color) (background dark)) :background "#440000"))
  "Face for lines removed from context."
  :group 'ogent-mode)

(defvar ogent-ui--context-preview-window nil
  "Window displaying the context preview, if any.")

(defvar-local ogent-ui--previous-context nil
  "Previous context string for diff comparison.")

(defvar-local ogent-ui--diff-overlays nil
  "List of overlays used for highlighting context changes.")

(defvar ogent-ui--diff-clear-timer nil
  "Timer for clearing diff overlays.")

(defun ogent-ui--context-buffer ()
  "Return the context preview buffer, clearing previous content."
  (let ((buffer (get-buffer-create ogent-context-preview-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)))
    buffer))

(defun ogent-ui--preview-prompt ()
  "Return the prompt text to display in context previews."
  (or ogent--transient-prompt
      "(prompt will be supplied at dispatch)"))

(defun ogent-ui--diff-strings (old new)
  "Compare OLD and NEW strings line by line.
Return list of plists with :type (:added or :removed), :lines (list of strings),
and :line-number (first line number where changes start)."
  (let ((old-lines (and old (split-string old "\n" nil)))
        (new-lines (and new (split-string new "\n" nil)))
        (result nil)
        (line-num 1)
        (i 0)
        (j 0))
    ;; Simple line-by-line diff
    (while (or (< i (length old-lines)) (< j (length new-lines)))
      (let ((old-line (and (< i (length old-lines)) (nth i old-lines)))
            (new-line (and (< j (length new-lines)) (nth j new-lines))))
        (cond
         ;; Lines match - advance both
         ((and old-line new-line (string= old-line new-line))
          (setq i (1+ i)
                j (1+ j)
                line-num (1+ line-num)))
         ;; New line added
         ((and (not old-line) new-line)
          (let ((added-lines (list new-line))
                (start-line line-num))
            (setq j (1+ j)
                  line-num (1+ line-num))
            ;; Collect consecutive added lines
            (while (and (< j (length new-lines))
                        (or (>= i (length old-lines))
                            (not (string= (nth i old-lines) (nth j new-lines)))))
              (push (nth j new-lines) added-lines)
              (setq j (1+ j)
                    line-num (1+ line-num)))
            (push (list :type :added
                        :lines (nreverse added-lines)
                        :line-number start-line)
                  result)))
         ;; Old line removed
         ((and old-line (not new-line))
          (let ((removed-lines (list old-line))
                (start-line line-num))
            (setq i (1+ i))
            ;; Collect consecutive removed lines
            (while (and (< i (length old-lines))
                        (or (>= j (length new-lines))
                            (not (string= (nth i old-lines) (nth j new-lines)))))
              (push (nth i old-lines) removed-lines)
              (setq i (1+ i)))
            (push (list :type :removed
                        :lines (nreverse removed-lines)
                        :line-number start-line)
                  result)))
         ;; Lines differ - mark as replacement (removed + added)
         (t
          (let ((removed-lines (list old-line))
                (added-lines (list new-line))
                (start-line line-num))
            (setq i (1+ i)
                  j (1+ j)
                  line-num (1+ line-num))
            ;; Look ahead for more changes
            (while (and (< i (length old-lines))
                        (< j (length new-lines))
                        (not (string= (nth i old-lines) (nth j new-lines))))
              (push (nth i old-lines) removed-lines)
              (push (nth j new-lines) added-lines)
              (setq i (1+ i)
                    j (1+ j)
                    line-num (1+ line-num)))
            (push (list :type :removed
                        :lines (nreverse removed-lines)
                        :line-number start-line)
                  result)
            (push (list :type :added
                        :lines (nreverse added-lines)
                        :line-number start-line)
                  result))))))
    (nreverse result)))

(defun ogent-ui--apply-diff-overlays (diff-result)
  "Create overlays for DIFF-RESULT in current buffer.
DIFF-RESULT is a list of plists from `ogent-ui--diff-strings'."
  (ogent-ui--clear-diff-overlays)
  (save-excursion
    (goto-char (point-min))
    (dolist (change diff-result)
      (let* ((type (plist-get change :type))
             (lines (plist-get change :lines))
             (line-num (plist-get change :line-number))
             (face (if (eq type :added)
                       'ogent-context-diff-added
                     'ogent-context-diff-removed)))
        ;; Move to the target line
        (goto-char (point-min))
        (forward-line (1- line-num))
        ;; Create overlay for each line
        (dolist (_line lines)
          (let ((start (line-beginning-position))
                (end (min (1+ (line-end-position)) (point-max))))
            (when (< start end)
              (let ((ov (make-overlay start end)))
                (overlay-put ov 'face face)
                (overlay-put ov 'ogent-diff t)
                (push ov ogent-ui--diff-overlays)))
            (forward-line 1)))))))

(defun ogent-ui--clear-diff-overlays ()
  "Remove all diff overlays from current buffer."
  (when ogent-ui--diff-overlays
    (mapc #'delete-overlay ogent-ui--diff-overlays)
    (setq ogent-ui--diff-overlays nil))
  (when ogent-ui--diff-clear-timer
    (cancel-timer ogent-ui--diff-clear-timer)
    (setq ogent-ui--diff-clear-timer nil)))

(defun ogent-ui--maybe-transform-zen-context (context &optional point)
  "Return CONTEXT adjusted to match the current Zen run, when active.
POINT overrides the Zen heading position when given."
  (if (and (bound-and-true-p ogent-zen-mode)
           (fboundp 'ogent-zen--heading-point)
           (fboundp 'ogent-zen--context-transform))
      (let ((zen-point (or point (ogent-zen--heading-point))))
        (if zen-point
            (ogent-zen--context-transform context zen-point)
          context))
    context))

(defun ogent-context-preview ()
  "Render the current subtree context into a preview buffer.
When invoked from a non-Org buffer, includes source buffer context."
  (interactive)
  (let* ((source-buffer (current-buffer))
         (region-start (when (use-region-p) (region-beginning)))
         (region-end (when (use-region-p) (region-end)))
         (companion (ogent-ui--ensure-companion-context)))
    (with-current-buffer companion
      (let* ((org-point (and (bound-and-true-p ogent-zen-mode)
                             (fboundp 'ogent-zen--heading-point)
                             (ogent-zen--heading-point)))
             (context (ogent-ui--maybe-transform-zen-context
                       (ogent-context-build-with-source
                        source-buffer region-start region-end org-point)
                       org-point))
             (payload (ogent-ui--render-prompt (ogent-ui--preview-prompt) context))
             (buffer (ogent-ui--context-buffer)))
        (with-current-buffer buffer
          (let ((previous ogent-ui--previous-context))
            (insert payload)
            (goto-char (point-min))
            ;; Apply diff highlighting if we have previous context
            (when previous
              (let ((diff (ogent-ui--diff-strings previous payload)))
                (when diff
                  (ogent-ui--apply-diff-overlays diff)
                  ;; Clear overlays after 3 seconds
                  (setq ogent-ui--diff-clear-timer
                        (run-with-timer 3 nil
                                        (lambda (buf)
                                          (when (buffer-live-p buf)
                                            (with-current-buffer buf
                                              (ogent-ui--clear-diff-overlays))))
                                        buffer)))))
            ;; Update previous context for next comparison
            (setq ogent-ui--previous-context payload)))
        (display-buffer buffer)))))

(defun ogent-ui--context-preview-visible-p ()
  "Return non-nil if the context preview buffer is currently visible."
  (and ogent-ui--context-preview-window
       (window-live-p ogent-ui--context-preview-window)
       (eq (window-buffer ogent-ui--context-preview-window)
           (get-buffer ogent-context-preview-buffer-name))))

(defun ogent-ui--close-context-preview ()
  "Close the context preview window if visible."
  (when (ogent-ui--context-preview-visible-p)
    (delete-window ogent-ui--context-preview-window)
    (setq ogent-ui--context-preview-window nil)))

(defun ogent-context-preview-toggle ()
  "Toggle the context preview popup.
If visible, close it.  Otherwise, show it in a popup without switching focus."
  (interactive)
  (if (ogent-ui--context-preview-visible-p)
      (ogent-ui--close-context-preview)
    (let* ((source-buffer (current-buffer))
           (region-start (when (use-region-p) (region-beginning)))
           (region-end (when (use-region-p) (region-end)))
           (companion (ogent-ui--ensure-companion-context)))
      (with-current-buffer companion
        (let* ((org-point (and (bound-and-true-p ogent-zen-mode)
                               (fboundp 'ogent-zen--heading-point)
                               (ogent-zen--heading-point)))
               (context (ogent-ui--maybe-transform-zen-context
                         (ogent-context-build-with-source
                          source-buffer region-start region-end org-point)
                         org-point))
               (payload (ogent-ui--render-prompt (ogent-ui--preview-prompt) context))
               (buffer (ogent-ui--context-buffer)))
          (with-current-buffer buffer
            (insert payload)
            (goto-char (point-min)))
          ;; Use side-window with slot -1 to appear above transient (slot 0)
          (setq ogent-ui--context-preview-window
                (display-buffer buffer
                                '((display-buffer-in-side-window)
                                  (side . bottom)
                                  (slot . -1)
                                  (window-height . 10)
                                  (preserve-size . (nil . t))))))))))

(defun ogent-ask-context-preview-toggle ()
  "Toggle the context preview popup for the active ask scope."
  (interactive)
  (if (ogent-ui--context-preview-visible-p)
      (ogent-ui--close-context-preview)
    (let* ((source-buffer (current-buffer))
           (region-start (when (use-region-p) (region-beginning)))
           (region-end (when (use-region-p) (region-end)))
           (org-point (ogent-ask--org-scope-point))
           (companion (ogent-ui--ensure-companion-context)))
      (with-current-buffer companion
        (let* ((context (ogent-context-build-with-source
                         source-buffer region-start region-end org-point))
               (payload (ogent-ui--render-prompt (ogent-ui--preview-prompt) context))
               (buffer (ogent-ui--context-buffer)))
          (with-current-buffer buffer
            (insert payload)
            (goto-char (point-min)))
          (setq ogent-ui--context-preview-window
                (display-buffer buffer
                                '((display-buffer-in-side-window)
                                  (side . bottom)
                                  (slot . -1)
                                  (window-height . 10)
                                  (preserve-size . (nil . t))))))))))

(provide 'ogent-ui-preview)
;;; ogent-ui-preview.el ends here
