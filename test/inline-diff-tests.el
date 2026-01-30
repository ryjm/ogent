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

(provide 'inline-diff-tests)

;;; inline-diff-tests.el ends here
