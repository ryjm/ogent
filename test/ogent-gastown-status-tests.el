;;; ogent-gastown-status-tests.el --- Tests for ogent-gastown-status -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-gastown-status)
(require 'ogent-gastown-status-transient)

(ert-deftest ogent-gastown-status-keybindings-help ()
  "Help keys are bound to the transient dispatch menu."
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "h"))
              'ogent-gastown-status-dispatch))
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "?"))
              'ogent-gastown-status-dispatch)))

(ert-deftest ogent-gastown-status-keybindings-hook ()
  "Hook actions use magit-style bindings."
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "H"))
              'ogent-gastown-hook-show))
  (should (eq (lookup-key ogent-gastown-mode-map (kbd "a"))
              'ogent-gastown-hook-attach)))

(provide 'ogent-gastown-status-tests)

;;; ogent-gastown-status-tests.el ends here
