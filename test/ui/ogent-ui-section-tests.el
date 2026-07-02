;;; ogent-ui-section-tests.el --- Tests for shared magit-section machinery -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the ogent-ui-section module covering:
;; - Point preservation across erase/reinsert refreshes (id match,
;;   line-number fallback, empty-buffer degradation)
;; - Mode definition falling back to `special-mode' when magit-section
;;   is unavailable at macroexpansion time
;; - Header-line shape (view label, context, both key-hint shapes)
;; - Item-line round-trip (insert, read back, next/previous motion)
;;
;; None of these tests require magit-section to be installed: they
;; exercise the plain-buffer plumbing and the fallback paths, stubbing
;; availability where the contract depends on it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ogent-ui-section)

;;; Fixture helpers

(defun ogent-ui-section-tests--render (items)
  "Erase the current buffer and render ITEMS as one item line each.
Each item string is inserted via `ogent-section-insert-item-line'
under the `test-item' property, below a plain heading line."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "Heading\n")
    (dolist (item items)
      (ogent-section-insert-item-line (format "item %s" item)
                                      'test-item item))))

(defun ogent-ui-section-tests--goto-item (item)
  "Move point to the line carrying ITEM under `test-item'."
  (goto-char (point-min))
  (while (and (not (equal item (ogent-section-item-at-point 'test-item)))
              (not (eobp)))
    (forward-line 1))
  (should (equal item (ogent-section-item-at-point 'test-item))))

;;; Point preservation

(ert-deftest ogent-ui-section-preserve-point-follows-id ()
  "After a re-render that reorders items, point follows the item id."
  (with-temp-buffer
    (ogent-ui-section-tests--render '("one" "two" "three"))
    (ogent-ui-section-tests--goto-item "two")
    (ogent-section-preserve-point ((lambda () (ogent-section-item-at-point 'test-item)))
      (ogent-ui-section-tests--render '("three" "two" "one")))
    ;; "two" moved from line 3 to line 3 in this ordering; use a
    ;; reorder where it genuinely moves to prove id-following.
    (should (equal "two" (ogent-section-item-at-point 'test-item)))
    (ogent-ui-section-tests--goto-item "one")
    (ogent-section-preserve-point ((lambda () (ogent-section-item-at-point 'test-item)))
      (ogent-ui-section-tests--render '("one" "three" "two")))
    ;; "one" moved from line 4 to line 2: id match wins over line number.
    (should (equal "one" (ogent-section-item-at-point 'test-item)))
    (should (= 2 (line-number-at-pos)))
    (should (bolp))))

(ert-deftest ogent-ui-section-preserve-point-line-fallback ()
  "When the captured id vanishes, point falls back to the old line number."
  (with-temp-buffer
    (ogent-ui-section-tests--render '("one" "two" "three"))
    (ogent-ui-section-tests--goto-item "two")  ; line 3
    (should (= 3 (line-number-at-pos)))
    (ogent-section-preserve-point ((lambda () (ogent-section-item-at-point 'test-item)))
      (ogent-ui-section-tests--render '("alpha" "beta" "gamma")))
    (should (= 3 (line-number-at-pos)))
    (should (equal "beta" (ogent-section-item-at-point 'test-item)))
    ;; Captured line beyond the new buffer end: clamp to last line.
    (ogent-ui-section-tests--goto-item "gamma")  ; line 4
    (ogent-section-preserve-point ((lambda () (ogent-section-item-at-point 'test-item)))
      (ogent-ui-section-tests--render '("solo")))
    ;; New buffer has heading + one item + trailing empty line.
    (should (<= (line-number-at-pos) (line-number-at-pos (point-max))))
    (should (bolp))))

(ert-deftest ogent-ui-section-preserve-point-empty-buffer ()
  "A re-render that leaves the buffer empty must not signal; point at bob."
  (with-temp-buffer
    (ogent-ui-section-tests--render '("one" "two"))
    (ogent-ui-section-tests--goto-item "two")
    (ogent-section-preserve-point ((lambda () (ogent-section-item-at-point 'test-item)))
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (should (= (point) (point-min)))))

;;; Mode definition fallback

(ert-deftest ogent-ui-section-define-mode-fallback-special-mode ()
  "With magit unavailable at expansion time, modes derive from special-mode.
The parent is chosen at macroexpansion from
`ogent-section--magit-available', so expand under a nil binding."
  (let* ((ogent-section--magit-available nil)
         (expansion (macroexpand-1
                     '(ogent-section-define-mode ogent-ui-section-tests-mode
                          "Test" "Docstring."))))
    (should (eq (car expansion) 'define-derived-mode))
    (should (eq (nth 2 expansion) 'special-mode))))

(ert-deftest ogent-ui-section-define-mode-magit-parent ()
  "With magit available at expansion time, modes derive from magit-section-mode."
  (let* ((ogent-section--magit-available t)
         (expansion (macroexpand-1
                     '(ogent-section-define-mode ogent-ui-section-tests-mode
                          "Test" "Docstring."))))
    (should (eq (car expansion) 'define-derived-mode))
    (should (eq (nth 2 expansion) 'magit-section-mode))))

(ert-deftest ogent-ui-section-with-fallback-plain-insert ()
  "With sections unusable, `ogent-section-with' inserts heading + body plainly."
  (with-temp-buffer
    (cl-letf (((symbol-function 'ogent-section-usable-p) (lambda () nil)))
      (ogent-section-with (test-section) "My Heading"
        (insert "body line\n")))
    (should (equal (buffer-string) "My Heading\nbody line\n"))))

;;; Header line

(ert-deftest ogent-ui-section-header-line-shape ()
  "Header line contains view label, context, and every hint key."
  (let ((line (substring-no-properties
               (ogent-section-header-line "Armory Home" "my-root"
                                          '("?" . "menu")
                                          '("j" . "jump")
                                          '("g" . "refresh")))))
    (should (string-match-p "Armory Home" line))
    (should (string-match-p "my-root" line))
    (should (string-match-p (regexp-quote "?:menu") line))
    (should (string-match-p (regexp-quote "j:jump") line))
    (should (string-match-p (regexp-quote "g:refresh") line))))

(ert-deftest ogent-ui-section-header-line-hint-shapes ()
  "Dotted pairs and 2-element list hints render identically."
  (let ((dotted (substring-no-properties
                 (ogent-section-header-line "View" nil '("g" . "refresh"))))
        (listed (substring-no-properties
                 (ogent-section-header-line "View" nil '("g" "refresh")))))
    (should (equal dotted listed))
    (should (string-match-p (regexp-quote "g:refresh") listed))))

(ert-deftest ogent-ui-section-header-line-omits-empty-context ()
  "Nil or empty context adds no separator; label still present."
  (let ((nil-ctx (substring-no-properties
                  (ogent-section-header-line "View" nil '("q" . "quit"))))
        (empty-ctx (substring-no-properties
                    (ogent-section-header-line "View" "" '("q" . "quit")))))
    (should (equal nil-ctx empty-ctx))
    (should (string-match-p "View" nil-ctx))
    (should-not (string-match-p "·" nil-ctx))))

;;; Item-line round-trip

(ert-deftest ogent-ui-section-item-line-round-trip ()
  "Inserted item lines read back via `ogent-section-item-at-point'."
  (with-temp-buffer
    (insert "Heading\n")
    (ogent-section-insert-item-line "item one" 'test-item "one")
    (ogent-section-insert-item-line "item two" 'test-item "two" "custom help")
    ;; Read back at line-beginning and mid-line.
    (goto-char (point-min))
    (should-not (ogent-section-item-at-point 'test-item))
    (forward-line 1)
    (should (equal "one" (ogent-section-item-at-point 'test-item)))
    (forward-char 4)  ; mid-line: still reads from line-beginning
    (should (equal "one" (ogent-section-item-at-point 'test-item)))
    (forward-line 1)
    (should (equal "two" (ogent-section-item-at-point 'test-item)))
    ;; Help-echo default and override.
    (goto-char (point-min))
    (forward-line 1)
    (should (equal "RET visits this item"
                   (get-text-property (point) 'help-echo)))
    (forward-line 1)
    (should (equal "custom help"
                   (get-text-property (point) 'help-echo)))))

(ert-deftest ogent-ui-section-visible-item-position-motion ()
  "next/previous find the adjacent visible item line positions."
  (with-temp-buffer
    (insert "Heading\n")
    (ogent-section-insert-item-line "item one" 'test-item "one")
    (ogent-section-insert-item-line "item two" 'test-item "two")
    (insert "Footer\n")
    ;; next from beginning-of-buffer -> "one".
    (goto-char (point-min))
    (let ((pos (ogent-section-visible-item-position 'test-item 'next)))
      (should pos)
      (should (equal "one" (get-text-property pos 'test-item))))
    ;; next from the "one" line -> "two".
    (goto-char (point-min))
    (forward-line 1)
    (let ((pos (ogent-section-visible-item-position 'test-item 'next)))
      (should pos)
      (should (equal "two" (get-text-property pos 'test-item)))
      ;; Moving there makes the item current at line level.
      (goto-char pos)
      (should (equal "two" (ogent-section-item-at-point 'test-item))))
    ;; next from the last item -> nil.
    (should-not (ogent-section-visible-item-position 'test-item 'next))
    ;; previous from end-of-buffer -> "two".
    (goto-char (point-max))
    (let ((pos (ogent-section-visible-item-position 'test-item 'previous)))
      (should pos)
      (should (equal "two" (get-text-property pos 'test-item))))
    ;; previous from the first item -> nil.
    (goto-char (point-min))
    (forward-line 1)
    (should-not (ogent-section-visible-item-position 'test-item 'previous))))

(provide 'ogent-ui-section-tests)

;;; ogent-ui-section-tests.el ends here
