;;; ogent-conformance-tests.el --- Spec-derived conformance tests -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-keys)
(require 'ogent-tool-effects)
(require 'ogent-models)

(ert-deftest ogent-conformance-user-commands-use-ogent-prefix ()
  "Architecture spec: user-facing registry commands use the ogent- prefix."
  (dolist (entry ogent-action-registry)
    (let ((command (plist-get (cdr entry) :command)))
      (should (string-prefix-p "ogent-" (symbol-name command))))))

(ert-deftest ogent-conformance-minor-mode-prefix-is-current-contract ()
  "Minor-mode contract: ogent commands use the C-c . prefix by default."
  (should (equal ogent-vanilla-prefix "C-c ."))
  (let ((map (make-sparse-keymap)))
    (ogent-setup-vanilla-bindings map)
    (should (eq (lookup-key map (kbd "C-c . p")) 'ogent-prompt-dispatch))))


(ert-deftest ogent-conformance-review-prefix-avoids-reserved-c-c-letter ()
  "Minor-mode contract: packages avoid the user-reserved C-c <letter> space."
  (should-not (string-match-p "\\`C-c [A-Za-z]\\'" ogent-review-prefix)))

(ert-deftest ogent-conformance-non-read-effects-require-approval ()
  "Tool effects spec: non-read effects require approval by policy."
  (dolist (kind '(write execute network git issue emacs-state))
    (should (ogent-tool-effects-approval-required-p
             (list (list :kind kind :target 'fixture :scope 'workspace)))))
  (should-not (ogent-tool-effects-approval-required-p
               '((:kind read :target file :scope workspace :risk low)))))

(ert-deftest ogent-conformance-high-risk-read-requires-approval ()
  "Tool effects spec: high-risk effects require approval even when kind is read."
  (should (ogent-tool-effects-approval-required-p
           '((:kind read :target external :scope unrestricted :risk high)))))

(ert-deftest ogent-conformance-model-registry-required-fields ()
  "Model registry spec: every model has id, backend, and stream flag fields."
  (dolist (model (ogent-models-all))
    (should (plist-get model :id))
    (should (plist-get model :backend))
    (should (plist-member model :stream?))))

;;; ogent-conformance-tests.el ends here
