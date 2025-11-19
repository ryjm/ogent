;;; ogent-ui-tests.el --- Tests for ogent UI layer -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-ui)
(require 'ogent-context)

(ert-deftest ogent-ui-format-context-includes-missing ()
  "Format string contains handles and missing metadata."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Root Overview")
     (org-back-to-heading t)
     (let* ((context (ogent-context-build))
            (summary (ogent-ui--format-context context)))
       (should (string-match-p "Handles: details-block" summary))
       (should (string-match-p "missing-note (missing)" summary))))))

(ert-deftest ogent-request-inserts-src-block ()
  "ogent-request appends an annotated src block to the subtree."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((ogent-ui--selected-models '("test-model")))
       (ogent-request "Test prompt" '("test-model"))
       (let ((block-pos (save-excursion
                          (goto-char (point-min))
                          (re-search-forward
                           "#\\+begin_src text :model test-model" nil t)))
             (next-heading (save-excursion
                             (outline-next-heading)
                             (point))))
         (should block-pos)
         (should (< block-pos next-heading)))))))

(ert-deftest ogent-ui-toggle-model ()
  "Toggling models should add/remove from the selection list."
  (let ((ogent-ui--selected-models nil))
    (ogent-ui--toggle-model "demo")
    (should (member "demo" (ogent-ui--current-models)))
    (ogent-ui--toggle-model "demo")
    (should-not (member "demo" (ogent-ui--current-models)))))

(provide 'ogent-ui-tests)
;;; ogent-ui-tests.el ends here
