;;; inline-diff-tests.el --- Tests for inline-diff -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for word-level inline diff functionality.

;;; Code:

(require 'ert)
(require 'inline-diff)

;;; Tokenization tests

(ert-deftest inline-diff-test-tokenize-simple ()
  "Test basic tokenization."
  (let ((tokens (inline-diff--tokenize "hello world")))
    (should (= (length tokens) 3))
    (should (equal (car (nth 0 tokens)) "hello"))
    (should (equal (car (nth 1 tokens)) " "))
    (should (equal (car (nth 2 tokens)) "world"))))

(ert-deftest inline-diff-test-tokenize-punctuation ()
  "Test tokenization with punctuation."
  (let ((tokens (inline-diff--tokenize "foo(bar)")))
    (should (= (length tokens) 4))
    (should (equal (car (nth 0 tokens)) "foo"))
    (should (equal (car (nth 1 tokens)) "("))
    (should (equal (car (nth 2 tokens)) "bar"))
    (should (equal (car (nth 3 tokens)) ")"))))

(ert-deftest inline-diff-test-tokenize-positions ()
  "Test that token positions are correct."
  (let ((tokens (inline-diff--tokenize "abc def")))
    (should (= (cdr (nth 0 tokens)) 0))   ; "abc" at 0
    (should (= (cdr (nth 1 tokens)) 3))   ; " " at 3
    (should (= (cdr (nth 2 tokens)) 4)))) ; "def" at 4

(ert-deftest inline-diff-test-tokenize-empty ()
  "Test tokenization of empty string."
  (let ((tokens (inline-diff--tokenize "")))
    (should (null tokens))))

(ert-deftest inline-diff-test-tokenize-whitespace-only ()
  "Test tokenization of whitespace-only string."
  (let ((tokens (inline-diff--tokenize "  \t\n")))
    (should (= (length tokens) 1))
    (should (equal (car (nth 0 tokens)) "  \t\n"))))

;;; LCS tests

(ert-deftest inline-diff-test-lcs-identical ()
  "Test LCS with identical sequences."
  (let* ((tokens (inline-diff--tokenize "abc"))
         (lcs (inline-diff--lcs tokens tokens)))
    (should (= (length lcs) (length tokens)))))

(ert-deftest inline-diff-test-lcs-different ()
  "Test LCS with completely different sequences."
  (let* ((tokens1 (inline-diff--tokenize "abc"))
         (tokens2 (inline-diff--tokenize "xyz"))
         (lcs (inline-diff--lcs tokens1 tokens2)))
    (should (null lcs))))

(ert-deftest inline-diff-test-lcs-partial ()
  "Test LCS with partial overlap."
  (let* ((tokens1 (inline-diff--tokenize "a b c"))
         (tokens2 (inline-diff--tokenize "a x c"))
         (lcs (inline-diff--lcs tokens1 tokens2)))
    ;; Should match "a", " ", "c" (tokens at positions 0, 1, 4 in each)
    (should (>= (length lcs) 2))))

;;; Change computation tests

(ert-deftest inline-diff-test-changes-no-change ()
  "Test that identical text produces only :keep changes."
  (let* ((tokens (inline-diff--tokenize "hello"))
         (changes (inline-diff--compute-changes tokens tokens)))
    (should (cl-every (lambda (c) (eq (car c) :keep)) changes))))

(ert-deftest inline-diff-test-changes-addition ()
  "Test that additions are detected."
  (let* ((old-tokens (inline-diff--tokenize "a"))
         (new-tokens (inline-diff--tokenize "a b"))
         (changes (inline-diff--compute-changes old-tokens new-tokens)))
    (should (cl-some (lambda (c) (eq (car c) :add)) changes))))

(ert-deftest inline-diff-test-changes-removal ()
  "Test that removals are detected."
  (let* ((old-tokens (inline-diff--tokenize "a b"))
         (new-tokens (inline-diff--tokenize "a"))
         (changes (inline-diff--compute-changes old-tokens new-tokens)))
    (should (cl-some (lambda (c) (eq (car c) :remove)) changes))))

;;; Integration tests

(ert-deftest inline-diff-test-words-region-basic ()
  "Test inline-diff-words-region creates overlays."
  (with-temp-buffer
    (insert "hello world")
    (inline-diff-words-region (point-min) (point-max) "hello there")
    (should inline-diff-mode)
    (should (> (length inline-diff--overlays) 0))
    (inline-diff-clear)
    (should (null inline-diff--overlays))))

(ert-deftest inline-diff-test-words-region-no-change ()
  "Test inline-diff-words-region with identical text."
  (with-temp-buffer
    (insert "same text")
    (inline-diff-words-region (point-min) (point-max) "same text")
    ;; No changes should be recorded (only keeps)
    (should inline-diff-mode)
    (inline-diff-clear)))

(ert-deftest inline-diff-test-mode-toggle ()
  "Test that inline-diff-mode can be toggled."
  (with-temp-buffer
    (inline-diff-mode 1)
    (should inline-diff-mode)
    (inline-diff-mode -1)
    (should-not inline-diff-mode)))

(ert-deftest inline-diff-test-clear-removes-overlays ()
  "Test that inline-diff-clear removes all overlays."
  (with-temp-buffer
    (insert "new text here")
    (inline-diff-words-region (point-min) (point-max) "old text")
    (let ((ov-count (length inline-diff--overlays)))
      (should (> ov-count 0))
      (inline-diff-clear)
      (should (= (length inline-diff--overlays) 0)))))

;;; Navigation tests

(ert-deftest inline-diff-test-navigation-empty ()
  "Test navigation with no changes."
  (with-temp-buffer
    (should-error (inline-diff-next-change))
    (should-error (inline-diff-previous-change))))

(ert-deftest inline-diff-test-accept-all ()
  "Test that accept-all clears overlays and exits mode."
  (with-temp-buffer
    (insert "new text")
    (inline-diff-words-region (point-min) (point-max) "old text")
    (inline-diff-accept-all)
    (should-not inline-diff-mode)
    (should (null inline-diff--overlays))))

;;; Overlay Creation Tests

(ert-deftest inline-diff-test-create-overlay-properties ()
  "Test that create-overlay sets correct properties."
  (with-temp-buffer
    (insert "test text")
    (let ((inline-diff--overlays nil))
      (let ((ov (inline-diff--create-overlay 1 5 'added)))
        (should (overlayp ov))
        (should (overlay-get ov 'inline-diff))
        (should (eq 'added (overlay-get ov 'inline-diff-type)))
        (should (overlay-get ov 'evaporate))
        (should (eq 'inline-diff-added (overlay-get ov 'face)))
        (delete-overlay ov)))))

(ert-deftest inline-diff-test-create-overlay-removed-face ()
  "Test create-overlay assigns removed face correctly."
  (with-temp-buffer
    (insert "test text")
    (let ((inline-diff--overlays nil))
      (let ((ov (inline-diff--create-overlay 1 5 'removed)))
        (should (eq 'inline-diff-removed (overlay-get ov 'face)))
        (delete-overlay ov)))))

(ert-deftest inline-diff-test-create-overlay-changed-faces ()
  "Test create-overlay assigns changed-old and changed-new faces."
  (with-temp-buffer
    (insert "test text")
    (let ((inline-diff--overlays nil))
      (let ((ov1 (inline-diff--create-overlay 1 5 'changed-old))
            (ov2 (inline-diff--create-overlay 1 5 'changed-new)))
        (should (eq 'inline-diff-changed-old (overlay-get ov1 'face)))
        (should (eq 'inline-diff-changed-new (overlay-get ov2 'face)))
        (delete-overlay ov1)
        (delete-overlay ov2)))))

(ert-deftest inline-diff-test-create-overlay-additional-props ()
  "Test create-overlay applies additional properties."
  (with-temp-buffer
    (insert "test text")
    (let ((inline-diff--overlays nil))
      (let ((ov (inline-diff--create-overlay 1 5 'added
                                             '(help-echo "hint" priority 100))))
        (should (equal "hint" (overlay-get ov 'help-echo)))
        (should (equal 100 (overlay-get ov 'priority)))
        (delete-overlay ov)))))

(ert-deftest inline-diff-test-create-overlay-tracked ()
  "Test create-overlay adds overlay to tracking list."
  (with-temp-buffer
    (insert "test text")
    (let ((inline-diff--overlays nil))
      (inline-diff--create-overlay 1 5 'added)
      (should (= 1 (length inline-diff--overlays)))
      (dolist (ov inline-diff--overlays)
        (delete-overlay ov)))))

;;; Insert Removed Text Tests

(ert-deftest inline-diff-test-insert-removed-text-creates-overlay ()
  "Test insert-removed-text creates an overlay with before-string."
  (with-temp-buffer
    (insert "some text")
    (let ((inline-diff--overlays nil))
      (let ((ov (inline-diff--insert-removed-text 1 "deleted")))
        (should (overlayp ov))
        (should (overlay-get ov 'inline-diff))
        (should (eq 'removed (overlay-get ov 'inline-diff-type)))
        (let ((bs (overlay-get ov 'before-string)))
          (should (stringp bs))
          (should (string= "deleted" bs))
          (should (eq 'inline-diff-removed (get-text-property 0 'face bs))))
        (delete-overlay ov)))))

;;; Navigation with Populated Change List Tests

(ert-deftest inline-diff-test-next-change-navigates ()
  "Test next-change moves point to next change."
  (with-temp-buffer
    (insert "hello world")
    (inline-diff-words-region (point-min) (point-max) "hello there")
    ;; Should have changes
    (should inline-diff--change-list)
    (goto-char (point-min))
    ;; Navigate to next change
    (inline-diff-next-change)
    ;; Point should have moved past start
    (should (> (point) (point-min)))
    (inline-diff-clear)))

(ert-deftest inline-diff-test-previous-change-navigates ()
  "Test previous-change moves point to previous change."
  (with-temp-buffer
    (insert "hello world")
    (inline-diff-words-region (point-min) (point-max) "hello there")
    (should inline-diff--change-list)
    (goto-char (point-max))
    ;; Navigate to previous change
    (inline-diff-previous-change)
    ;; Point should have moved back from end
    (should (< (point) (point-max)))
    (inline-diff-clear)))

(ert-deftest inline-diff-test-next-change-error-at-end ()
  "Test next-change signals error when no more changes."
  (with-temp-buffer
    (insert "new stuff here")
    (inline-diff-words-region (point-min) (point-max) "old stuff")
    (should inline-diff--change-list)
    ;; Move past all changes
    (goto-char (point-max))
    (should-error (inline-diff-next-change) :type 'user-error)
    (inline-diff-clear)))

;;; Reject All Tests

(ert-deftest inline-diff-test-reject-all-with-confirm ()
  "Test reject-all clears overlays when confirmed."
  (with-temp-buffer
    (insert "new text")
    (inline-diff-words-region (point-min) (point-max) "old text")
    (should inline-diff-mode)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (inline-diff-reject-all))
    (should-not inline-diff-mode)
    (should (null inline-diff--overlays))))

(ert-deftest inline-diff-test-reject-all-cancelled ()
  "Test reject-all keeps overlays when cancelled."
  (with-temp-buffer
    (insert "new text")
    (inline-diff-words-region (point-min) (point-max) "old text")
    (should inline-diff-mode)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (inline-diff-reject-all))
    ;; Should still be in mode
    (should inline-diff-mode)
    (inline-diff-clear)))

;;; Mode-Map Binding Tests

(ert-deftest inline-diff-test-mode-map-bindings ()
  "Test inline-diff-mode-map has correct bindings."
  (should (keymapp inline-diff-mode-map))
  (should (eq 'inline-diff-next-change
              (lookup-key inline-diff-mode-map (kbd "M-n"))))
  (should (eq 'inline-diff-previous-change
              (lookup-key inline-diff-mode-map (kbd "M-p"))))
  (should (eq 'inline-diff-accept-all
              (lookup-key inline-diff-mode-map (kbd "C-c C-c"))))
  (should (eq 'inline-diff-reject-all
              (lookup-key inline-diff-mode-map (kbd "C-c C-k")))))

;;; Tokenization Edge Case Tests

(ert-deftest inline-diff-test-tokenize-underscores-and-numbers ()
  "Test tokenization treats underscores and numbers as word characters."
  (let ((tokens (inline-diff--tokenize "my_var_2")))
    ;; Should be a single token since _, letters, and digits are all word chars
    (should (= 1 (length tokens)))
    (should (equal "my_var_2" (car (nth 0 tokens))))))

(ert-deftest inline-diff-test-tokenize-mixed-content ()
  "Test tokenization with mixed punctuation, words, and whitespace."
  (let ((tokens (inline-diff--tokenize "if (x > 0)")))
    ;; "if" " " "(" "x" " " ">" " " "0" ")"
    (should (= 9 (length tokens)))
    (should (equal "if" (car (nth 0 tokens))))
    (should (equal "(" (car (nth 2 tokens))))
    (should (equal ")" (car (nth 8 tokens))))))

;;; Words-Region with Trailing Removes Test

(ert-deftest inline-diff-test-words-region-trailing-removes ()
  "Test inline-diff-words-region handles trailing removed tokens."
  (with-temp-buffer
    (insert "hello")
    (inline-diff-words-region (point-min) (point-max) "hello world")
    ;; Should have at least one change (removal of " world")
    (should inline-diff-mode)
    (should (> (length inline-diff--overlays) 0))
    (inline-diff-clear)))

(ert-deftest inline-diff-test-words-region-change-list-sorted ()
  "Test inline-diff-words-region sorts change list by position."
  (with-temp-buffer
    (insert "new text here")
    (inline-diff-words-region (point-min) (point-max) "old text")
    (when (> (length inline-diff--change-list) 1)
      (let ((positions (mapcar (lambda (c) (plist-get c :start))
                               inline-diff--change-list)))
        ;; Verify sorted
        (should (equal positions (sort (copy-sequence positions) #'<)))))
    (inline-diff-clear)))

(provide 'inline-diff-tests)

;;; inline-diff-tests.el ends here
