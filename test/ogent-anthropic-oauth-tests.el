;;; ogent-anthropic-oauth-tests.el --- Tests for Anthropic OAuth -*- lexical-binding: t; -*-

;;; Commentary:
;; Test suite for ogent-anthropic-oauth.el

;;; Code:

(require 'ert)
(require 'ogent-anthropic-oauth)

;;; PKCE Tests

(ert-deftest ogent-oauth-test-base64url-encode ()
  "Test base64url encoding."
  ;; Standard test vectors from RFC 4648
  (should (string= (ogent-anthropic-oauth--base64url-encode "")
                   ""))
  (should (string= (ogent-anthropic-oauth--base64url-encode "f")
                   "Zg"))
  (should (string= (ogent-anthropic-oauth--base64url-encode "fo")
                   "Zm8"))
  (should (string= (ogent-anthropic-oauth--base64url-encode "foo")
                   "Zm9v"))
  (should (string= (ogent-anthropic-oauth--base64url-encode "foob")
                   "Zm9vYg"))
  (should (string= (ogent-anthropic-oauth--base64url-encode "fooba")
                   "Zm9vYmE"))
  (should (string= (ogent-anthropic-oauth--base64url-encode "foobar")
                   "Zm9vYmFy")))

(ert-deftest ogent-oauth-test-base64url-no-padding ()
  "Test that base64url encoding has no padding."
  (let ((encoded (ogent-anthropic-oauth--base64url-encode "test")))
    (should-not (string-match-p "=" encoded))))

(ert-deftest ogent-oauth-test-base64url-safe-chars ()
  "Test that base64url uses URL-safe characters."
  ;; Use actual random bytes function to avoid multibyte issues
  (let ((encoded (ogent-anthropic-oauth--base64url-encode
                  (ogent-anthropic-oauth--random-bytes 100))))
    (should-not (string-match-p "\\+" encoded))
    (should-not (string-match-p "/" encoded))))

(ert-deftest ogent-oauth-test-random-bytes ()
  "Test random bytes generation."
  (let ((bytes (ogent-anthropic-oauth--random-bytes 32)))
    (should (stringp bytes))
    (should (= (length bytes) 32))))

(ert-deftest ogent-oauth-test-random-bytes-different ()
  "Test that random bytes are actually random."
  (let ((b1 (ogent-anthropic-oauth--random-bytes 32))
        (b2 (ogent-anthropic-oauth--random-bytes 32)))
    (should-not (string= b1 b2))))

(ert-deftest ogent-oauth-test-sha256 ()
  "Test SHA-256 hash generation."
  ;; Test vector: SHA256("") = e3b0c442...
  (let ((hash (ogent-anthropic-oauth--sha256 "")))
    (should (stringp hash))
    (should (= (length hash) 32)))) ; SHA-256 produces 32 bytes

(ert-deftest ogent-oauth-test-generate-pkce ()
  "Test PKCE generation."
  (let ((pkce (ogent-anthropic-oauth--generate-pkce)))
    (should (plist-get pkce :verifier))
    (should (plist-get pkce :challenge))
    ;; Verifier should be a valid base64url string
    (should (string-match-p "^[A-Za-z0-9_-]+$" (plist-get pkce :verifier)))
    ;; Challenge should be a valid base64url string
    (should (string-match-p "^[A-Za-z0-9_-]+$" (plist-get pkce :challenge)))
    ;; Verifier and challenge should be different
    (should-not (string= (plist-get pkce :verifier)
                         (plist-get pkce :challenge)))))

(ert-deftest ogent-oauth-test-pkce-different-each-time ()
  "Test that PKCE generates different values each time."
  (let ((p1 (ogent-anthropic-oauth--generate-pkce))
        (p2 (ogent-anthropic-oauth--generate-pkce)))
    (should-not (string= (plist-get p1 :verifier)
                         (plist-get p2 :verifier)))))

;;; Authorization URL Tests

(ert-deftest ogent-oauth-test-authorization-url-max ()
  "Test OAuth URL generation for max mode."
  (let ((result (ogent-anthropic-oauth--authorization-url 'max)))
    (should (plist-get result :url))
    (should (plist-get result :verifier))
    ;; URL should point to claude.ai for max mode
    (should (string-match-p "^https://claude\\.ai/oauth/authorize"
                            (plist-get result :url)))
    ;; URL should contain required parameters
    (should (string-match-p "client_id=" (plist-get result :url)))
    (should (string-match-p "code_challenge=" (plist-get result :url)))
    (should (string-match-p "code_challenge_method=S256" (plist-get result :url)))))

(ert-deftest ogent-oauth-test-authorization-url-console ()
  "Test OAuth URL generation for console mode."
  (let ((result (ogent-anthropic-oauth--authorization-url 'console)))
    (should (plist-get result :url))
    ;; URL should point to console.anthropic.com for console mode
    (should (string-match-p "^https://console\\.anthropic\\.com/oauth/authorize"
                            (plist-get result :url)))))

;;; Token Storage Tests

(ert-deftest ogent-oauth-test-token-file-path ()
  "Test token file path generation."
  (let ((file (ogent-anthropic-oauth--token-file)))
    (should (stringp file))
    (should (string-match-p "tokens\\.el$" file))))

(ert-deftest ogent-oauth-test-save-and-restore-tokens ()
  "Test token save and restore cycle."
  (let* ((ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-test-" t))
         (ogent-anthropic-oauth--token-file nil)  ; Reset to recalculate
         (test-tokens '(:mode max
                        :type auth/oauth
                        :api-key "test-access-token"
                        :refresh-token "test-refresh-token"
                        :expires-at 9999999999)))
    (unwind-protect
        (progn
          ;; Save tokens
          (ogent-anthropic-oauth--save-tokens test-tokens)
          ;; Clear memory state
          (setq ogent-anthropic-oauth--tokens nil)
          ;; Restore and verify
          (let ((restored (ogent-anthropic-oauth--restore-tokens)))
            (should restored)
            (should (eq (plist-get restored :mode) 'max))
            (should (eq (plist-get restored :type) 'auth/oauth))
            (should (string= (plist-get restored :api-key) "test-access-token"))
            (should (string= (plist-get restored :refresh-token) "test-refresh-token"))))
      ;; Cleanup
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

(ert-deftest ogent-oauth-test-clear-tokens ()
  "Test token clearing."
  (let* ((ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-test-" t))
         (ogent-anthropic-oauth--token-file nil)
         (ogent-anthropic-oauth--tokens '(:mode max :api-key "test")))
    (unwind-protect
        (progn
          ;; Save something first
          (ogent-anthropic-oauth--save-tokens ogent-anthropic-oauth--tokens)
          ;; Clear
          (ogent-anthropic-oauth--clear-tokens)
          ;; Verify cleared
          (should-not ogent-anthropic-oauth--tokens)
          (should-not ogent-anthropic-oauth--mode)
          (should-not (file-exists-p (ogent-anthropic-oauth--token-file))))
      ;; Cleanup
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

;;; Public API Tests

(ert-deftest ogent-oauth-test-authenticated-p-no-tokens ()
  "Test authenticated-p returns nil when no tokens."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-test-" t))
        (ogent-anthropic-oauth--token-file nil)
        ;; Override known paths to prevent finding real tokens
        (ogent-anthropic-oauth--known-token-paths nil))
    (unwind-protect
        (should-not (ogent-anthropic-oauth-authenticated-p))
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

(ert-deftest ogent-oauth-test-authenticated-p-with-tokens ()
  "Test authenticated-p returns token when authenticated."
  (let ((ogent-anthropic-oauth--tokens '(:type auth/token
                                         :api-key "test-key"))
        (ogent-anthropic-oauth--mode 'console))
    (should (ogent-anthropic-oauth-authenticated-p))))

(ert-deftest ogent-oauth-test-get-headers-bearer ()
  "Test header generation for bearer token (max mode)."
  (let ((ogent-anthropic-oauth--tokens '(:type auth/oauth
                                         :api-key "test-access-token"
                                         :expires-at 9999999999))
        (ogent-anthropic-oauth--mode 'max))
    (let ((headers (ogent-anthropic-oauth-get-headers)))
      (should headers)
      ;; Should have Bearer auth
      (should (string-match-p "^Bearer " (cdr (assoc "Authorization" headers))))
      ;; Should have beta header
      (should (assoc "anthropic-beta" headers)))))

(ert-deftest ogent-oauth-test-get-headers-api-key ()
  "Test header generation for API key (console mode)."
  (let ((ogent-anthropic-oauth--tokens '(:type auth/token
                                         :api-key "test-api-key"))
        (ogent-anthropic-oauth--mode 'console))
    (let ((headers (ogent-anthropic-oauth-get-headers)))
      (should headers)
      ;; Should have x-api-key
      (should (string= (cdr (assoc "x-api-key" headers)) "test-api-key"))
      ;; Should NOT have beta header for console mode
      (should-not (string-match-p "oauth-2025"
                                  (or (cdr (assoc "anthropic-beta" headers)) ""))))))

(ert-deftest ogent-oauth-test-using-bearer-p ()
  "Test using-bearer-p detection."
  ;; OAuth mode should return t
  (let ((ogent-anthropic-oauth--tokens '(:type auth/oauth :api-key "test")))
    (should (ogent-anthropic-oauth-using-bearer-p)))
  ;; Token mode should return nil
  (let ((ogent-anthropic-oauth--tokens '(:type auth/token :api-key "test")))
    (should-not (ogent-anthropic-oauth-using-bearer-p)))
  ;; No tokens should return nil
  (let ((ogent-anthropic-oauth--tokens nil))
    (should-not (ogent-anthropic-oauth-using-bearer-p))))

;;; Constants Tests

(ert-deftest ogent-oauth-test-constants-defined ()
  "Test that required constants are defined."
  (should (stringp ogent-anthropic-oauth--client-id))
  (should (stringp ogent-anthropic-oauth--redirect-uri))
  (should (stringp ogent-anthropic-oauth--scope))
  (should (stringp ogent-anthropic-oauth--token-url))
  (should (stringp ogent-anthropic-oauth--beta-features))
  (should (stringp ogent-anthropic-oauth--system-prefix)))

(ert-deftest ogent-oauth-test-client-id-format ()
  "Test client ID is a valid UUID."
  (should (string-match-p
           "^[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}$"
           ogent-anthropic-oauth--client-id)))

(provide 'ogent-anthropic-oauth-tests)

;;; ogent-anthropic-oauth-tests.el ends here
