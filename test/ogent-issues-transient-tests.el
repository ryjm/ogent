;;; ogent-issues-transient-tests.el --- Tests for ogent-issues-transient -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the transient menus in ogent-issues.

;;; Code:

(require 'ert)
(require 'ogent-test-helper)
(require 'ogent-issues-bd)
(require 'ogent-issues)
(require 'ogent-issues-transient)

;;; Test Fixtures

(defconst ogent-issues-transient-test--sample-issue
  '(:id "test-001"
    :title "Test issue"
    :status "open"
    :priority 1
    :issue_type "task")
  "Sample issue for testing.")

;;; Header Formatting Tests

(ert-deftest ogent-issues-transient-test-format-header-no-issue ()
  "Test header formatting when no issue at point."
  (cl-letf (((symbol-function 'ogent-issues--current-issue)
             (lambda () nil)))
    (let ((ogent-issues--current-view 'list))
      (let ((header (ogent-issues-transient--format-header)))
        (should (string-match-p "Ogent Issues" header))
        (should (string-match-p "List" header))
        (should-not (string-match-p "Current:" header))))))

(ert-deftest ogent-issues-transient-test-format-header-with-issue ()
  "Test header formatting when issue at point."
  (cl-letf (((symbol-function 'ogent-issues--current-issue)
             (lambda () ogent-issues-transient-test--sample-issue)))
    (let ((ogent-issues--current-view 'list))
      (let ((header (ogent-issues-transient--format-header)))
        (should (string-match-p "Ogent Issues" header))
        (should (string-match-p "List" header))
        (should (string-match-p "Current:" header))
        (should (string-match-p "test-001" header))
        (should (string-match-p "open" header))))))

(ert-deftest ogent-issues-transient-test-format-header-ready-view ()
  "Test header formatting in ready view."
  (cl-letf (((symbol-function 'ogent-issues--current-issue)
             (lambda () nil)))
    (let ((ogent-issues--current-view 'ready))
      (let ((header (ogent-issues-transient--format-header)))
        (should (string-match-p "Ready" header))))))

;;; Create Mode Tests

(ert-deftest ogent-issues-transient-test-create-mode-keymap ()
  "Test that create mode has correct keybindings."
  (should (keymapp ogent-issues-create-mode-map))
  (should (commandp (lookup-key ogent-issues-create-mode-map (kbd "C-c C-c"))))
  (should (commandp (lookup-key ogent-issues-create-mode-map (kbd "C-c C-k")))))

(ert-deftest ogent-issues-transient-test-create-mode-activation ()
  "Test that create mode activates correctly."
  (with-temp-buffer
    (ogent-issues-create-mode)
    (should (eq major-mode 'ogent-issues-create-mode))
    (should header-line-format)))

;;; Transient Definition Tests

(ert-deftest ogent-issues-transient-test-dispatch-defined ()
  "Test that main dispatch transient is defined."
  (should (fboundp 'ogent-issues-dispatch)))

(ert-deftest ogent-issues-transient-test-create-dispatch-defined ()
  "Test that create dispatch transient is defined."
  (should (fboundp 'ogent-issues-create-dispatch)))

(ert-deftest ogent-issues-transient-test-filter-dispatch-defined ()
  "Test that filter dispatch transient is defined."
  (should (fboundp 'ogent-issues-filter-dispatch)))

;;; Create Functions Tests

(ert-deftest ogent-issues-transient-test-create-quick-defined ()
  "Test that quick create function is defined."
  (should (fboundp 'ogent-issues-create-quick)))

(ert-deftest ogent-issues-transient-test-create-full-defined ()
  "Test that full create function is defined."
  (should (fboundp 'ogent-issues-create-full)))

(ert-deftest ogent-issues-transient-test-create-epic-defined ()
  "Test that epic create function is defined."
  (should (fboundp 'ogent-issues-create-epic)))

(ert-deftest ogent-issues-transient-test-create-submit-defined ()
  "Test that create submit function is defined."
  (should (fboundp 'ogent-issues-create-submit)))

(ert-deftest ogent-issues-transient-test-create-cancel-defined ()
  "Test that create cancel function is defined."
  (should (fboundp 'ogent-issues-create-cancel)))

;;; Filter Apply Tests

(ert-deftest ogent-issues-transient-test-filter-apply-defined ()
  "Test that filter apply function is defined."
  (should (fboundp 'ogent-issues-filter-apply)))

(provide 'ogent-issues-transient-tests)

;;; ogent-issues-transient-tests.el ends here
