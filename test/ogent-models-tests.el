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

(provide 'ogent-models-tests)
;;; ogent-models-tests.el ends here
