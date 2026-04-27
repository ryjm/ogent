;;; ogent-tool-effects-tests.el --- Tests for tool effects -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for tool effect normalization, risk scoring, and approval policy.

;;; Code:

(require 'ert)
(require 'ogent-tool-effects)

(ert-deftest ogent-tool-effects-normalize/plist ()
  "Effect plists normalize kind and default fields."
  (let ((effects (ogent-tool-effects-normalize
                  '((:kind :read :target file :scope workspace)))))
    (should (= (length effects) 1))
    (should (eq (plist-get (car effects) :kind) 'read))
    (should (eq (plist-get (car effects) :target) 'file))
    (should (eq (plist-get (car effects) :scope) 'workspace))
    (should (eq (plist-get (car effects) :risk) 'low))))

(ert-deftest ogent-tool-effects-normalize/shorthand ()
  "Symbol-list shorthand normalizes into effect plists."
  (let ((effects (ogent-tool-effects-normalize
                  '((write file workspace)
                    (execute shell unrestricted)))))
    (should (equal (ogent-tool-effects-kinds effects)
                   '(write execute)))
    (should (eq (plist-get (car effects) :risk) 'high))
    (should (eq (plist-get (cadr effects) :risk) 'critical))))

(ert-deftest ogent-tool-effects-normalize/drops-unknown-kind ()
  "Unknown effect kinds are ignored."
  (should-not (ogent-tool-effects-normalize '((teleport file workspace)))))

(ert-deftest ogent-tool-effects-risk/highest-risk-wins ()
  "Risk scorer returns the highest declared risk."
  (should (eq (ogent-tool-effects-risk
               '((:kind read :target file :scope workspace)
                 (:kind write :target file :scope workspace)))
              'high)))

(ert-deftest ogent-tool-effects-approval-required-p/read-only ()
  "Read-only effects do not require approval by default."
  (should-not
   (ogent-tool-effects-approval-required-p
    '((:kind read :target file :scope workspace)))))

(ert-deftest ogent-tool-effects-approval-required-p/write ()
  "Write effects require approval by default."
  (should
   (ogent-tool-effects-approval-required-p
    '((:kind write :target file :scope workspace)))))

(ert-deftest ogent-tool-effects-format/includes-risk ()
  "Formatted effects include kind, target, scope, and risk."
  (let ((formatted (ogent-tool-effects-format
                    '((:kind execute :target shell :scope unrestricted)))))
    (should (string-match-p "execute shell" formatted))
    (should (string-match-p "unrestricted" formatted))
    (should (string-match-p "critical" formatted))))

(provide 'ogent-tool-effects-tests)

;;; ogent-tool-effects-tests.el ends here
