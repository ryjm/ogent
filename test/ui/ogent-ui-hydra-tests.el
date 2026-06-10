;;; ogent-ui-hydra-tests.el --- Tests for ogent hydra menus -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the hydra-based quick menus.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-ui-hydra)

;;; Navigation Function Tests

(ert-deftest ogent-hydra-next-response-finds-response ()
  "Next response should find Response heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: test\n")
    (insert "** Response\n")
    (insert "Some content\n")
    (insert "** Response\n")
    (insert "More content\n")
    (goto-char (point-min))
    (ogent-hydra--next-response)
    (should (looking-at "\\*\\* Response"))))

(ert-deftest ogent-hydra-next-response-messages-when-none ()
  "Next response should message when no more responses."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: test\n")
    (insert "No responses here\n")
    (goto-char (point-min))
    (ogent-hydra--next-response)
    ;; Should not have moved
    (should (= (point) (point-min)))))

(ert-deftest ogent-hydra-prev-response-finds-response ()
  "Previous response should find Response heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: test\n")
    (insert "** Response\n")
    (insert "First response\n")
    (insert "** Response\n")
    (insert "Second response\n")
    (goto-char (point-max))
    (ogent-hydra--prev-response)
    (should (looking-at "\\*\\* Response"))))

(ert-deftest ogent-hydra-next-request-finds-request ()
  "Next request should find Request heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: first\n")
    (insert "** Response\n")
    (insert "* Request: second\n")
    (insert "** Response\n")
    (goto-char (point-min))
    ;; Move past the first request heading to test finding the next one
    (forward-line 1)
    (ogent-hydra--next-request)
    (should (looking-at "\\* Request: second"))))

(ert-deftest ogent-hydra-prev-request-finds-request ()
  "Previous request should find Request heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Request: first\n")
    (insert "** Response\n")
    (insert "* Request: second\n")
    (insert "** Response\n")
    (goto-char (point-max))
    (ogent-hydra--prev-request)
    (should (looking-at "\\* Request: second"))))

;;; Command Availability Tests

(ert-deftest ogent-hydra-navigate-command-defined ()
  "Navigation command should be defined."
  (should (fboundp 'ogent-navigate)))

(ert-deftest ogent-hydra-edit-menu-command-defined ()
  "Edit menu command should be defined."
  (should (fboundp 'ogent-edit-menu)))

(ert-deftest ogent-hydra-request-menu-command-defined ()
  "Request menu command should be defined."
  (should (fboundp 'ogent-request-menu)))

;;; Hydra Definition Tests (when hydra is available)

(ert-deftest ogent-hydra-defines-hydras-when-available ()
  "Hydras should be defined when hydra package is loaded."
  (skip-unless (featurep 'hydra))
  (should (fboundp 'ogent-hydra-navigate/body))
  (should (fboundp 'ogent-hydra-edit/body))
  (should (fboundp 'ogent-hydra-request/body)))

(ert-deftest ogent-hydra-navigate-graceful-without-hydra ()
  "Navigate should show message when hydra not available."
  (skip-unless (not (featurep 'hydra)))
  (let ((messages nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (ogent-navigate))
    (should (cl-some (lambda (m) (string-match-p "not available" m)) messages))))

;;; Deferred Hydra Loading Tests

(ert-deftest ogent-hydra-file-loads-without-error ()
  "Hydra file should load without 'Symbol's value as variable is void' errors.
Regression test: defhydra macros must be inside with-eval-after-load to defer
macro expansion until hydra is available."
  ;; If we got here, the file loaded successfully via (require 'ogent-ui-hydra)
  ;; at the top of this test file. This test documents the regression.
  (should (featurep 'ogent-ui-hydra)))

(ert-deftest ogent-hydra-uses-eval-after-load ()
  "Hydra file should use with-eval-after-load to defer defhydra expansion.
Regression test: defhydra inside defun still expands at compile time,
causing 'Symbol's value as variable is void: pink' error."
  (let* ((hydra-file (locate-library "ogent-ui-hydra"))
         (source-file (if (string-suffix-p ".elc" hydra-file)
                          (concat (file-name-sans-extension hydra-file) ".el")
                        hydra-file)))
    (when (file-exists-p source-file)
      (with-temp-buffer
        (insert-file-contents source-file)
        ;; Should have defhydra inside with-eval-after-load, not in a defun
        (should (re-search-forward
                 "(with-eval-after-load 'hydra" nil t))
        ;; The defhydra should be directly in the with-eval-after-load body
        (should (re-search-forward "(defhydra ogent-hydra-navigate" nil t))))))

(ert-deftest ogent-hydra-no-defun-wrapper ()
  "Hydra definitions should not be wrapped in a defun.
Regression test: defhydra inside defun is still macro-expanded at compile time."
  (let* ((hydra-file (locate-library "ogent-ui-hydra"))
         (source-file (if (string-suffix-p ".elc" hydra-file)
                          (concat (file-name-sans-extension hydra-file) ".el")
                        hydra-file)))
    (when (file-exists-p source-file)
      (with-temp-buffer
        (insert-file-contents source-file)
        ;; Should NOT have ogent-hydra--define-hydras function
        (should-not (re-search-forward
                     "(defun ogent-hydra--define-hydras" nil t))))))

(provide 'ogent-ui-hydra-tests)

;;; ogent-ui-hydra-tests.el ends here
