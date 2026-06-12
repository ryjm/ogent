;;; ogent-provider-fallback-tests.el --- Tests for provider fallback -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-provider-fallback)

(ert-deftest ogent-provider-access-error-detects-auth-failures ()
  "Provider access errors match built-in authentication and access patterns."
  (dolist (message '("Invalid API key provided"
                     "model_not_found: gpt-x"
                     "You do not have access to this model"
                     "insufficient_quota for account"))
    (should (ogent-provider-access-error-p message))))

(ert-deftest ogent-provider-access-error-ignores-ordinary-errors ()
  "Provider access detection ignores non-access failures."
  (dolist (message '("connection reset by peer"
                     "JSON parse failed"
                     "request timed out"))
    (should-not (ogent-provider-access-error-p message))))

(ert-deftest ogent-provider-error-message-string-normalizes-values ()
  "Error message normalization handles strings, nil, and structured values."
  (should (equal (ogent-provider-error-message-string "bad key") "bad key"))
  (should (equal (ogent-provider-error-message-string nil) ""))
  (should (equal (ogent-provider-error-message-string '(error . denied))
                 "(error . denied)")))

(ert-deftest ogent-provider-login-prompt-truncates-long-errors ()
  "Login prompt keeps provider errors to one readable line."
  (let* ((long-error (make-string 120 ?x))
         (prompt (ogent-provider-login-prompt "gpt-test" long-error)))
    (should (string-prefix-p "gpt-test failed: " prompt))
    (should (string-match-p (regexp-quote "Login to a different provider now? ") prompt))
    (should (< (length prompt) 140))))

;;; ogent-provider-fallback-tests.el ends here
