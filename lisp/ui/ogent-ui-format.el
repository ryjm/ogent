;;; ogent-ui-format.el --- Org output formatting and window scroll -*- lexical-binding: t; -*-

;;; Commentary:
;; Org-mode response formatting (heading shifts, block escaping, source
;; and reasoning blocks, highlight mode) plus the auto-scroll and
;; window-follow machinery that keeps streaming output in view.

;;; Code:

(require 'ogent-ui-core)
(require 'org)
(require 'subr-x)

(defvar-local ogent--auto-scroll-enabled nil
  "Buffer-local flag tracking if auto-scroll is active for current request.
Set to t when a new request starts (if `ogent-auto-scroll' is enabled).
Set to nil when user scrolls away from bottom.
Re-enabled when user scrolls back to bottom.")

(defun ogent-ui--auto-scroll-post-command ()
  "Post-command hook to re-enable auto-scroll when user scrolls to bottom.
Only runs when auto-scroll is globally enabled but locally disabled,
and there's an active request."
  (when (and ogent-auto-scroll
             (not ogent--auto-scroll-enabled)
             (ogent-ui-active-requests))
    ;; User might have scrolled back to bottom - check and re-enable
    (when (ogent-ui--at-window-bottom-p)
      (setq ogent--auto-scroll-enabled t))))

(defun ogent-ui--insert-src-block (content models)
  "Insert a src block containing CONTENT annotated with MODELS."
  (org-back-to-heading t)
  (org-end-of-subtree t t)
  (unless (bolp) (insert "\n"))
  (let ((model-label (string-join models ", ")))
    (insert (format "#+begin_src text :model %s\n" model-label))
    (insert (ogent-ui--escape-org-block-content content))
    (unless (string-suffix-p "\n" content)
      (insert "\n"))
    (insert "#+end_src\n")))

(defun ogent-ui-insert-response-block (prompt context models)
  "Default response function writing PROMPT and CONTEXT to Org."
  (ogent-ui--insert-src-block
   (ogent-ui--render-prompt prompt context)
   models))

(defun ogent-ui--escape-org-block-content (content)
  "Return CONTENT escaped for literal storage inside an Org block.
The prompt sent to the model remains unescaped.  This only protects the
transcript copy from Org syntax that can terminate or split the block."
  (replace-regexp-in-string "^\\(\\*\\|#\\+\\)" ",\\1" content))

(defun ogent-ui--prompt-headline-summary (prompt)
  "Return a compact one-line headline summary for PROMPT.
Use the first non-empty prompt line, not the whole prompt body.  Zen
prompts are markdown bullets, so strip a leading bullet marker before
truncating."
  (let* ((lines (split-string
                 (string-trim (substring-no-properties (format "%s" prompt)))
                 "[\n\r]+" t))
         (summary (string-trim (substring-no-properties (or (car lines) "")))))
    (setq summary (string-join (split-string summary "[[:space:]]+" t) " "))
    (when (string-match "\\`[-+*][ \t]+\\(.+\\)\\'" summary)
      (setq summary (substring-no-properties (match-string 1 summary))))
    (if (string-empty-p summary)
        "(empty prompt)"
      (truncate-string-to-width summary 60 nil nil "..."))))

(defun ogent-ui--hide-src-block-at (position)
  "Hide the Org source block at POSITION when folding is available."
  (when (and position
             (derived-mode-p 'org-mode)
             (fboundp 'org-fold-hide-block-toggle))
    (save-excursion
      (goto-char position)
      (when (looking-at "^#\\+begin_src")
        (condition-case nil
            (org-fold-hide-block-toggle 'hide)
          (user-error nil)
          (error nil))))))

(defun ogent-ui--at-window-bottom-p (&optional window)
  "Return non-nil if WINDOW is scrolled to show the bottom.
WINDOW defaults to the selected window. This checks if `window-end'
is at or near `point-max', allowing for a small margin."
  (let ((win (or window (selected-window))))
    (when (window-live-p win)
      (with-selected-window win
        (>= (window-end win t) (- (point-max) 10))))))

(defun ogent-ui--scroll-to-bottom (&optional window)
  "Scroll WINDOW to show the bottom of the buffer.
WINDOW defaults to the selected window."
  (let ((win (or window (selected-window))))
    (when (window-live-p win)
      (with-selected-window win
        (goto-char (point-max))
        (recenter -1)))))

(defconst ogent-ui--auto-scroll-margin 10
  "Character margin for deciding whether a window follows a stream tail.")

(defun ogent-ui--position-value (position)
  "Return numeric buffer position for POSITION."
  (if (markerp position)
      (marker-position position)
    position))

(defun ogent-ui--window-follows-position-p (window position)
  "Return non-nil when WINDOW is already showing POSITION."
  (and (window-live-p window)
       (integer-or-marker-p position)
       (let* ((pos (ogent-ui--position-value position))
              (visible-pos (max (point-min) (1- pos)))
              (start (window-start window)))
         (or (pos-visible-in-window-p visible-pos window)
             (and (<= start pos)
                  (<= (count-screen-lines start pos nil window)
                      (+ (window-body-height window)
                         ogent-ui--auto-scroll-margin)))))))

(defun ogent-ui--windows-following-position (buffer position)
  "Return BUFFER windows currently following POSITION."
  (cl-remove-if-not
   (lambda (window)
     (ogent-ui--window-follows-position-p window position))
   (get-buffer-window-list buffer nil t)))

(defun ogent-ui--scroll-window-to-position (window position)
  "Scroll WINDOW to show POSITION near the bottom."
  (when (and (window-live-p window)
             (integer-or-marker-p position))
    (let ((pos (ogent-ui--position-value position)))
      (with-selected-window window
        (set-window-point window pos)
        (goto-char pos)
        (recenter -1)))))

(defconst ogent-ui--response-heading-level 3
  "Fallback Org heading level used for legacy Response heading shifting.")

(defun ogent-ui--shift-org-headings (text &optional response-heading-level)
  "Shift org headings in TEXT to nest under the Response heading.
Headings are shifted by RESPONSE-HEADING-LEVEL levels.
For example, `* Heading' becomes `**** Heading'.

This prevents LLM-generated headings from breaking the session
buffer's org hierarchy."
  (if (not ogent-shift-response-headings)
      text
    (let ((shift (or response-heading-level
                     ogent-ui--response-heading-level)))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        ;; Match org headings: line start, one or more *, then space or EOL.
        ;; Avoid matching emphasis such as *bold*.
        (while (re-search-forward "^\\(\\*+\\)\\([ \t]\\|$\\)" nil t)
          (let* ((stars (match-string 1))
                 (suffix (match-string 2))
                 (new-stars (make-string (+ (length stars) shift) ?*)))
            (replace-match (concat new-stars suffix) t t)))
        (buffer-string)))))

(defcustom ogent-enable-highlight-mode t
  "When non-nil, enable `gptel-highlight-mode' for response blocks.
This provides visual highlighting for tool calls, reasoning blocks,
and responses marked with gptel text properties."
  :type 'boolean
  :group 'ogent-mode)

(defun ogent-ui--setup-highlight-mode ()
  "Enable gptel-highlight-mode if available and configured."
  (when (and ogent-enable-highlight-mode
             (derived-mode-p 'org-mode)
             (fboundp 'gptel-highlight-mode))
    (gptel-highlight-mode 1)))

(defun ogent-ui--fold-special-block ()
  "Fold the current Org special block if at one."
  (when (and (derived-mode-p 'org-mode)
             (fboundp 'org-cycle))
    (save-excursion
      (when (looking-at "^#\\+begin_\\(tool\\|reasoning\\)")
        (org-cycle)))))

(defun ogent-ui--insert-reasoning-block (content)
  "Insert a reasoning block containing CONTENT.
The block follows gptel's format for Org reasoning."
  (let ((marker (point)))
    (insert "#+begin_reasoning\n")
    (insert content)
    (unless (bolp) (insert "\n"))
    (insert "#+end_reasoning\n")
    (save-excursion
      (goto-char marker)
      (ogent-ui--fold-special-block))))

(provide 'ogent-ui-format)
;;; ogent-ui-format.el ends here
