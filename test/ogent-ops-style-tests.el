;;; ogent-ops-style-tests.el --- Tests for ogent-ops-style -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)

;; Add lisp directory to load-path for ogent-ops-style
(let ((lisp-dir (expand-file-name "../lisp" (file-name-directory (or load-file-name buffer-file-name ".")))))
  (when (file-directory-p lisp-dir)
    (add-to-list 'load-path lisp-dir)))

(require 'ogent-ops-style)

;;; Status symbols

(ert-deftest ogent-ops-status-symbol-unicode ()
  "Status symbols return correct Unicode glyphs."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-status-symbol 'open) "○"))
    (should (string= (ogent-ops-status-symbol 'in-progress) "◐"))
    (should (string= (ogent-ops-status-symbol 'blocked) "✗"))
    (should (string= (ogent-ops-status-symbol 'closed) "●"))
    (should (string= (ogent-ops-status-symbol 'ready) "»"))
    (should (string= (ogent-ops-status-symbol 'waiting) "○"))
    (should (string= (ogent-ops-status-symbol 'processing) "⚙"))
    (should (string= (ogent-ops-status-symbol 'failed) "✗"))
    (should (string= (ogent-ops-status-symbol 'merged) "✓"))))

(ert-deftest ogent-ops-status-symbol-ascii ()
  "Status symbols return correct ASCII fallbacks."
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-status-symbol 'open) "o"))
    (should (string= (ogent-ops-status-symbol 'in-progress) ">"))
    (should (string= (ogent-ops-status-symbol 'blocked) "x"))
    (should (string= (ogent-ops-status-symbol 'closed) "*"))
    (should (string= (ogent-ops-status-symbol 'ready) "!"))
    (should (string= (ogent-ops-status-symbol 'waiting) "o"))
    (should (string= (ogent-ops-status-symbol 'processing) "*"))
    (should (string= (ogent-ops-status-symbol 'failed) "x"))
    (should (string= (ogent-ops-status-symbol 'merged) "+"))))

(ert-deftest ogent-ops-status-symbol-unknown-fallback ()
  "Unknown status returns deterministic fallback."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-status-symbol 'nonexistent) "?"))
    (should (string= (ogent-ops-status-symbol nil) "?")))
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-status-symbol 'nonexistent) "?"))
    (should (string= (ogent-ops-status-symbol nil) "?"))))

;;; Priority symbols

(ert-deftest ogent-ops-priority-symbol-unicode ()
  "Priority symbols return correct Unicode glyphs."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-priority-symbol 0) "●"))
    (should (string= (ogent-ops-priority-symbol 1) "◐"))
    (should (string= (ogent-ops-priority-symbol 2) "○"))
    (should (string= (ogent-ops-priority-symbol 3) "◌"))))

(ert-deftest ogent-ops-priority-symbol-ascii ()
  "Priority symbols return P<n> in ASCII mode."
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-priority-symbol 0) "P0"))
    (should (string= (ogent-ops-priority-symbol 1) "P1"))
    (should (string= (ogent-ops-priority-symbol 2) "P2"))
    (should (string= (ogent-ops-priority-symbol 3) "P3"))))

(ert-deftest ogent-ops-priority-symbol-nil-default ()
  "Nil priority defaults to 2."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-priority-symbol nil) "○")))
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-priority-symbol nil) "P2"))))

(ert-deftest ogent-ops-priority-symbol-high-values ()
  "Priority values above 3 get the low/backlog symbol."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-priority-symbol 4) "◌"))
    (should (string= (ogent-ops-priority-symbol 99) "◌")))
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-priority-symbol 4) "P4"))))

;;; Activity symbols

(ert-deftest ogent-ops-activity-symbol-unicode ()
  "Activity symbols return correct Unicode glyphs."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-activity-symbol 'active) "●"))
    (should (string= (ogent-ops-activity-symbol 'working) "◐"))
    (should (string= (ogent-ops-activity-symbol 'idle) "○"))))

(ert-deftest ogent-ops-activity-symbol-ascii ()
  "Activity symbols return correct ASCII fallbacks."
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-activity-symbol 'active) ">"))
    (should (string= (ogent-ops-activity-symbol 'working) "*"))
    (should (string= (ogent-ops-activity-symbol 'idle) "-"))))

(ert-deftest ogent-ops-activity-symbol-unknown ()
  "Unknown activity returns deterministic fallback."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-activity-symbol 'unknown-state) "?"))))

;;; Section symbols

(ert-deftest ogent-ops-section-symbol-issues-unicode ()
  "Issues section symbol returns Unicode glyph."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-section-symbol 'issues) "◈"))))

(ert-deftest ogent-ops-section-symbol-issues-ascii ()
  "Issues section symbol returns ASCII fallback."
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-section-symbol 'issues) "I"))))

;;; Section helpers

(ert-deftest ogent-ops-section-prefix-unicode ()
  "Section prefix returns Unicode icon when enabled."
  (let ((ogent-ops-use-unicode t))
    (should (string= (ogent-ops-section-prefix "⚙" "*") "⚙"))))

(ert-deftest ogent-ops-section-prefix-ascii ()
  "Section prefix returns ASCII icon when disabled."
  (let ((ogent-ops-use-unicode nil))
    (should (string= (ogent-ops-section-prefix "⚙" "*") "*"))))

(ert-deftest ogent-ops-section-heading-basic ()
  "Section heading formats icon + label."
  (let ((result (ogent-ops-section-heading "⚙" "Processing")))
    (should (string= result "⚙ Processing"))))

(ert-deftest ogent-ops-section-heading-with-count ()
  "Section heading appends count when provided."
  (let ((result (ogent-ops-section-heading "⚙" "Processing" 5)))
    (should (string-match-p "⚙ Processing" result))
    (should (string-match-p "(5)" result))))

(ert-deftest ogent-ops-section-heading-nil-count-omitted ()
  "Section heading omits count when nil."
  (let ((result (ogent-ops-section-heading "⚙" "Processing" nil)))
    (should (string= result "⚙ Processing"))))

;;; Loading frames

(ert-deftest ogent-ops-loading-frames-returns-list ()
  "Loading frames returns a non-empty list."
  (let ((frames (ogent-ops-loading-frames)))
    (should (listp frames))
    (should (> (length frames) 0))))

;;; Font-lock protection

(ert-deftest ogent-ops-protect-face-properties-sets-defaults ()
  "Font-lock protection sets buffer-local variables."
  (with-temp-buffer
    (ogent-ops-protect-face-properties)
    (should (equal font-lock-defaults '(nil t)))
    (should (functionp font-lock-unfontify-region-function))))

(ert-deftest ogent-ops-protect-face-properties-preserves-face ()
  "Font-lock protection does not strip manually applied face properties."
  (with-temp-buffer
    (ogent-ops-protect-face-properties)
    (insert (propertize "hello" 'face 'bold))
    ;; Unfontify should not remove 'face
    (funcall font-lock-unfontify-region-function (point-min) (point-max))
    (should (eq (get-text-property 1 'face) 'bold))))

(provide 'ogent-ops-style-tests)
;;; ogent-ops-style-tests.el ends here
