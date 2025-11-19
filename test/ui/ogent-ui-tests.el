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

(ert-deftest ogent-request-streams-via-gptel ()
  "ogent-request uses gptel and streams into the Org block."
  (ogent-test-with-fixture "data/fixture.org"
   (lambda ()
     (goto-char (point-min))
     (search-forward "Details Block")
     (org-back-to-heading t)
     (let ((captured nil)
           (ogent-ui--selected-models '("gpt-4o-mini")))
       (cl-letf (((symbol-function 'gptel-request)
                  (lambda (prompt &rest args)
                    (setq captured (list :prompt prompt :args args))
                    (when-let ((callback (plist-get args :callback)))
                      (funcall callback "Hello world" nil)
                      (funcall callback nil '(:done t)))
                    'mock-request)))
         (ogent-request "Test prompt" '("gpt-4o-mini"))
         (should (string-match-p "Test prompt"
                                 (plist-get captured :prompt)))
         (should (equal (plist-get (plist-get captured :args) :model)
                        "gpt-4o-mini"))
         (save-excursion
           (goto-char (point-min))
           (search-forward "#+begin_src text :model gpt-4o-mini")
           (search-forward "Hello world")
           (search-forward "#+end_src")))))))

(ert-deftest ogent-ui-toggle-model ()
  "Toggling models updates the dispatcher selection."
  (let ((ogent-ui--selected-models nil)
        (ogent-model-registry '((:id "alpha" :backend foo)
                                (:id "beta" :backend bar))))
    (ogent-ui--toggle-model "beta")
    (should (member "beta" (ogent-ui--current-models)))
    (ogent-ui--toggle-model "beta")
    (should (equal (ogent-ui--current-models) '("alpha")))))

(provide 'ogent-ui-tests)
;;; ogent-ui-tests.el ends here
