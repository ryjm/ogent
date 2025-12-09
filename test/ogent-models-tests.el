;;; ogent-models-tests.el --- Tests for ogent-models -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-models)

(ert-deftest ogent-models-default-falls-back-to-first-entry ()
  "Default accessor returns the first registry entry when no override is set."
  (let ((ogent-default-model nil)
        (ogent-model-registry '((:id "alpha" :backend foo)
                                (:id "beta" :backend bar))))
    (should (equal (plist-get (ogent-models-default) :id) "alpha"))))

(ert-deftest ogent-models-ensure-succeeds ()
  "Ensure returns a model plist and signals on missing entries."
  (let ((ogent-model-registry '((:id "alpha" :backend foo))))
    (should (equal (plist-get (ogent-models-ensure "alpha") :backend) 'foo))
    (should-error (ogent-models-ensure "missing") :type 'error)))

(ert-deftest ogent-presets-available-collects-names ()
  "Available presets include both ogent and gptel presets."
  (let ((ogent-preset-registry '((:name code-review :spec (:description "cr"))
                                 (:name summarize :spec (:description "sum"))))
        (ogent--presets-registered nil))
    ;; Bind gptel-presets explicitly to ensure boundp works
    (defvar gptel-presets nil)
    (let ((gptel-presets '((external . (:description "ext")))))
      (cl-letf (((symbol-function 'gptel-make-preset) (lambda (&rest _) nil)))
        (let ((names (ogent-presets-available)))
          (should (member "code-review" names))
          (should (member "summarize" names))
          (should (member "external" names)))))))

(ert-deftest ogent-preset-get-finds-entry ()
  "Preset get returns the plist for a named preset."
  (let ((ogent-preset-registry '((:name code-review :spec (:description "cr")))))
    (should (equal (plist-get (ogent-preset-get "code-review") :name) 'code-review))
    (should (equal (plist-get (ogent-preset-get 'code-review) :name) 'code-review))
    (should (null (ogent-preset-get "missing")))))

(provide 'ogent-models-tests)
;;; ogent-models-tests.el ends here
