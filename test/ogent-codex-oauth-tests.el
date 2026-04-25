;;; ogent-codex-oauth-tests.el --- Tests for Codex OAuth reuse -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for reusing Codex CLI ChatGPT login credentials.

;;; Code:

(require 'ert)
(require 'ogent-codex-oauth)

(ert-deftest ogent-codex-oauth-test-auth-file-uses-codex-home ()
  "Auth file resolution respects `CODEX_HOME'."
  (let ((process-environment (cons "CODEX_HOME=/tmp/ogent-codex" process-environment))
        (ogent-codex-oauth-auth-file nil))
    (should (equal (ogent-codex-oauth--auth-file)
                   "/tmp/ogent-codex/auth.json"))))

(ert-deftest ogent-codex-oauth-test-read-auth-file ()
  "Auth cache JSON is read as a plist."
  (let* ((dir (make-temp-file "ogent-codex-auth-" t))
         (file (expand-file-name "auth.json" dir))
         (ogent-codex-oauth-auth-file file))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":\"sk-test\",\"tokens\":{\"access_token\":\"tok\"}}"))
          (let ((auth (ogent-codex-oauth--read-auth-file)))
            (should (equal (plist-get auth :auth_mode) "chatgpt"))
            (should (equal (plist-get auth :OPENAI_API_KEY) "sk-test"))))
      (delete-directory dir t))))

(ert-deftest ogent-codex-oauth-test-api-key-from-auth-file ()
  "API key helper returns the cached Codex API key."
  (let* ((dir (make-temp-file "ogent-codex-auth-" t))
         (file (expand-file-name "auth.json" dir))
         (ogent-codex-oauth-auth-file file))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":\"sk-oauth\"}"))
          (should (equal (ogent-codex-oauth-get-api-key) "sk-oauth"))
          (should (ogent-codex-oauth-authenticated-p))
          (should (equal (ogent-codex-oauth-mode) "chatgpt")))
      (delete-directory dir t))))

(ert-deftest ogent-codex-oauth-test-no-auth-file ()
  "Missing auth cache returns nil instead of signaling."
  (let ((ogent-codex-oauth-auth-file "/tmp/ogent-missing-codex-auth.json"))
    (should-not (ogent-codex-oauth--read-auth-file))
    (should-not (ogent-codex-oauth-get-api-key))
    (should-not (ogent-codex-oauth-authenticated-p))))

(ert-deftest ogent-codex-oauth-test-login-starts-codex-login ()
  "Login command starts the Codex login process."
  (let ((captured nil))
    (cl-letf (((symbol-function 'start-process)
               (lambda (name buffer program &rest args)
                 (setq captured (list name buffer program args))
                 'process))
              ((symbol-function 'set-process-query-on-exit-flag)
               (lambda (&rest _) nil))
              ((symbol-function 'pop-to-buffer)
               (lambda (&rest _) nil)))
      (ogent-codex-login)
      (should (equal (nth 0 captured) "ogent-codex-login"))
      (should (equal (nth 2 captured) ogent-codex-oauth-codex-executable))
      (should (equal (nth 3 captured) '("login"))))))

(ert-deftest ogent-codex-oauth-test-device-login-starts-device-auth ()
  "Device login adds the Codex device-auth flag."
  (let ((captured nil))
    (cl-letf (((symbol-function 'start-process)
               (lambda (_name _buffer _program &rest args)
                 (setq captured args)
                 'process))
              ((symbol-function 'set-process-query-on-exit-flag)
               (lambda (&rest _) nil))
              ((symbol-function 'pop-to-buffer)
               (lambda (&rest _) nil)))
      (ogent-codex-login-device)
      (should (equal captured '("login" "--device-auth"))))))

(provide 'ogent-codex-oauth-tests)

;;; ogent-codex-oauth-tests.el ends here
