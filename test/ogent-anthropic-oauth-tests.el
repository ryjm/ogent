;;; ogent-anthropic-oauth-tests.el --- Tests for Anthropic OAuth -*- lexical-binding: t; -*-

;;; Commentary:
;; Test suite for ogent-anthropic-oauth.el

;;; Code:

(require 'ert)
(require 'ogent-anthropic-oauth)
(defvar gptel--system-message)

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

;;; Find Existing Token File Tests

(ert-deftest ogent-oauth-test-find-existing-token-file-found ()
  "Test finding an existing token file in a temp directory."
  (let* ((tmp-dir (make-temp-file "ogent-token-test-" t))
         (token-file (expand-file-name "tokens.el" tmp-dir))
         (ogent-anthropic-oauth-tokens-dir tmp-dir)
         (ogent-anthropic-oauth--token-file nil)
         (ogent-anthropic-oauth--known-token-paths nil))
    (unwind-protect
        (progn
          ;; Create the token file
          (with-temp-file token-file
            (insert "(:mode max :api-key \"test\")"))
          (let ((found (ogent-anthropic-oauth--find-existing-token-file)))
            (should found)
            (should (string= found token-file))))
      (delete-directory tmp-dir t))))

(ert-deftest ogent-oauth-test-find-existing-token-file-not-found ()
  "Test that nil is returned when no token file exists."
  (let* ((tmp-dir (make-temp-file "ogent-token-test-" t))
         (ogent-anthropic-oauth-tokens-dir tmp-dir)
         (ogent-anthropic-oauth--token-file nil)
         (ogent-anthropic-oauth--known-token-paths nil))
    (unwind-protect
        (should-not (ogent-anthropic-oauth--find-existing-token-file))
      (delete-directory tmp-dir t))))

(ert-deftest ogent-oauth-test-find-existing-token-file-known-paths ()
  "Test finding token file from known paths list."
  (let* ((tmp-dir (make-temp-file "ogent-known-" t))
         (known-file (expand-file-name "tokens.el" tmp-dir))
         ;; Point tokens-dir to a non-existent location
         (ogent-anthropic-oauth-tokens-dir (expand-file-name "nonexist/" tmp-dir))
         (ogent-anthropic-oauth--token-file nil)
         (ogent-anthropic-oauth--known-token-paths (list known-file)))
    (unwind-protect
        (progn
          (with-temp-file known-file
            (insert "(:mode max)"))
          (let ((found (ogent-anthropic-oauth--find-existing-token-file)))
            (should found)
            (should (string= found known-file))))
      (delete-directory tmp-dir t))))

;;; Exchange Code Tests (Mocked)

(ert-deftest ogent-oauth-test-exchange-code-success ()
  "Test code exchange with mocked HTTP response."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
             (lambda (_url _method _headers _data)
               (list :access_token "test-access-123"
                     :refresh_token "test-refresh-456"
                     :expires_in 3600))))
    (let ((result (ogent-anthropic-oauth--exchange-code "auth-code#state" "verifier")))
      (should (equal (plist-get result :access-token) "test-access-123"))
      (should (equal (plist-get result :refresh-token) "test-refresh-456"))
      (should (numberp (plist-get result :expires-at)))
      ;; expires-at should be roughly now + 3600
      (should (> (plist-get result :expires-at) (floor (float-time)))))))

(ert-deftest ogent-oauth-test-exchange-code-failure ()
  "Test code exchange failure is signalled as error."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
             (lambda (_url _method _headers _data)
               (list :error "invalid_grant"
                     :error_description "Code expired"))))
    (should-error (ogent-anthropic-oauth--exchange-code "bad-code" "verifier"))))

(ert-deftest ogent-oauth-test-exchange-code-splits-hash ()
  "Test that exchange-code correctly splits code#state."
  (let ((received-data nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
               (lambda (_url _method _headers data)
                 (setq received-data data)
                 (list :access_token "ok"
                       :refresh_token "ok"
                       :expires_in 3600))))
      (ogent-anthropic-oauth--exchange-code "mycode#mystate" "myverifier")
      ;; Verify the code was split: :code should be "mycode", :state should be "mystate"
      (should (equal (plist-get received-data :code) "mycode"))
      (should (equal (plist-get received-data :state) "mystate"))
      (should (equal (plist-get received-data :code_verifier) "myverifier")))))

;;; Refresh Token Tests (Mocked)

(ert-deftest ogent-oauth-test-refresh-token-success ()
  "Test token refresh with mocked response."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
             (lambda (_url _method _headers _data)
               (list :access_token "new-access-999"
                     :refresh_token "new-refresh-888"
                     :expires_in 7200))))
    (let ((result (ogent-anthropic-oauth--refresh-token "old-refresh-token")))
      (should (equal (plist-get result :access-token) "new-access-999"))
      (should (equal (plist-get result :refresh-token) "new-refresh-888"))
      (should (numberp (plist-get result :expires-at))))))

(ert-deftest ogent-oauth-test-refresh-token-failure ()
  "Test token refresh failure."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
             (lambda (_url _method _headers _data)
               (list :error "invalid_grant"
                     :error_description "Refresh token revoked"))))
    (should-error (ogent-anthropic-oauth--refresh-token "revoked-token"))))

;;; Create API Key Tests (Mocked)

(ert-deftest ogent-oauth-test-create-api-key-success ()
  "Test API key creation with mocked response."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
             (lambda (_url _method _headers _data)
               (list :raw_key "sk-ant-test-key-12345"))))
    (let ((key (ogent-anthropic-oauth--create-api-key "bearer-token")))
      (should (equal key "sk-ant-test-key-12345")))))

(ert-deftest ogent-oauth-test-create-api-key-failure ()
  "Test API key creation failure."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
             (lambda (_url _method _headers _data)
               (list :error "forbidden"))))
    (should-error (ogent-anthropic-oauth--create-api-key "bad-token"))))

;;; Ensure Valid Token Tests

(ert-deftest ogent-oauth-test-ensure-valid-token-not-expired ()
  "Test ensure-valid-token returns token when not expired."
  (let ((ogent-anthropic-oauth--tokens
         (list :type 'auth/oauth
               :api-key "valid-token"
               :refresh-token "refresh"
               :expires-at (+ (floor (float-time)) 3600)))
        (ogent-anthropic-oauth--mode 'max)
        (ogent-anthropic-oauth--token-file "/dev/null"))
    (should (equal (ogent-anthropic-oauth--ensure-valid-token) "valid-token"))))

(ert-deftest ogent-oauth-test-ensure-valid-token-expired-refreshes ()
  "Test ensure-valid-token refreshes expired tokens."
  (let* ((ogent-anthropic-oauth--tokens
          (list :type 'auth/oauth
                :api-key "old-token"
                :refresh-token "my-refresh"
                :expires-at (- (floor (float-time)) 100)))
         (ogent-anthropic-oauth--mode 'max)
         (ogent-anthropic-oauth--token-file "/dev/null")
         (refresh-called nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--refresh-token)
               (lambda (rt)
                 (setq refresh-called t)
                 (should (equal rt "my-refresh"))
                 (list :access-token "new-token"
                       :refresh-token "new-refresh"
                       :expires-at (+ (floor (float-time)) 3600))))
              ((symbol-function 'ogent-anthropic-oauth--save-tokens)
               (lambda (tokens) tokens)))
      (let ((result (ogent-anthropic-oauth--ensure-valid-token)))
        (should refresh-called)
        (should (equal result "new-token"))))))

(ert-deftest ogent-oauth-test-ensure-valid-token-nil-when-no-tokens ()
  "Test ensure-valid-token returns nil when no tokens exist."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth--token-file nil)
        (ogent-anthropic-oauth--known-token-paths nil)
        (ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-notoken-" t)))
    (unwind-protect
        (should-not (ogent-anthropic-oauth--ensure-valid-token))
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

;;; Ensure Tokens Loaded Tests

(ert-deftest ogent-oauth-test-ensure-tokens-loaded-already-loaded ()
  "Test that ensure-tokens-loaded is a no-op when tokens are already set."
  (let ((ogent-anthropic-oauth--tokens '(:mode max :api-key "loaded"))
        (ogent-anthropic-oauth--mode 'max)
        (restore-called nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--restore-tokens)
               (lambda () (setq restore-called t) nil)))
      (ogent-anthropic-oauth--ensure-tokens-loaded)
      ;; Should not have called restore since tokens were already present
      (should-not restore-called))))

(ert-deftest ogent-oauth-test-ensure-tokens-loaded-from-disk ()
  "Test that ensure-tokens-loaded restores from disk."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth--mode nil)
        (ogent-anthropic-oauth--token-file nil)
        (ogent-anthropic-oauth--known-token-paths nil)
        (ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-load-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-anthropic-oauth--restore-tokens)
                   (lambda () '(:mode console :type auth/token :api-key "restored"))))
          (ogent-anthropic-oauth--ensure-tokens-loaded)
          (should ogent-anthropic-oauth--tokens)
          (should (eq ogent-anthropic-oauth--mode 'console)))
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

;;; Get OAuth Headers for gptel Tests

(ert-deftest ogent-oauth-test-get-oauth-headers-no-backend ()
  "Test get-oauth-headers-for-gptel returns nil without gptel backend."
  (let ((ogent-anthropic-oauth--tokens '(:type auth/oauth :api-key "test"))
        (ogent-anthropic-oauth-debug nil)
        (gptel-backend nil))
    (should-not (ogent-anthropic-oauth--get-oauth-headers-for-gptel))))

;;; Using OAuth for gptel Tests

(ert-deftest ogent-oauth-test-using-oauth-for-gptel-no-backend ()
  "Test using-oauth-for-gptel-p returns nil without gptel backend."
  (let ((gptel-backend nil)
        (ogent-anthropic-oauth-debug nil))
    (should-not (ogent-anthropic-oauth--using-oauth-for-gptel-p))))

;;; Request Data Advice Tests

(ert-deftest ogent-oauth-test-request-data-advice-passthrough ()
  "Test request-data-advice passes through when not using OAuth."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth--token-file nil)
        (ogent-anthropic-oauth--known-token-paths nil)
        (ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-advice-" t))
        (gptel-backend nil)
        (orig-called nil))
    (unwind-protect
        (let ((orig-fn (lambda (backend prompts)
                         (setq orig-called t)
                         (list backend prompts))))
          (ogent-anthropic-oauth--request-data-advice orig-fn 'test-backend '("prompt"))
          (should orig-called))
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

(ert-deftest ogent-oauth-test-request-data-advice-overrides-system ()
  "Test request-data-advice overrides system message when using OAuth."
  (let ((ogent-anthropic-oauth--tokens
         '(:type auth/oauth :api-key "test" :expires-at 9999999999))
        (ogent-anthropic-oauth--mode 'max)
        (ogent-anthropic-oauth--token-file "/dev/null")
        (ogent-anthropic-oauth-debug nil)
        (gptel--system-message "original system message")
        (captured-system-msg nil))
    ;; Mock the predicates to say we're using OAuth
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--using-oauth-for-gptel-p)
               (lambda () t))
              ((symbol-function 'ogent-anthropic-oauth--ensure-tokens-loaded)
               (lambda () nil)))
      (let ((orig-fn (lambda (_backend _prompts)
                       (setq captured-system-msg gptel--system-message))))
        (ogent-anthropic-oauth--request-data-advice orig-fn 'backend '("p"))
        ;; System message should have been overridden to Claude Code prefix
        (should (equal captured-system-msg ogent-anthropic-oauth--system-prefix))))))

;;; Get Header Slot Index Tests

(ert-deftest ogent-oauth-test-get-header-slot-index-caches ()
  "Test that get-header-slot-index caches the result."
  (let ((ogent-anthropic-oauth--header-slot-index nil))
    ;; When gptel-backend struct is available, it should return a number
    (condition-case nil
        (progn
          (require 'gptel)
          (let ((idx (ogent-anthropic-oauth--get-header-slot-index)))
            (should (numberp idx))
            ;; Second call should return the cached value
            (should (eq idx (ogent-anthropic-oauth--get-header-slot-index)))))
      (error
       ;; If gptel is not available, just verify the caching logic
       (let ((ogent-anthropic-oauth--header-slot-index 5))
         (should (eq (ogent-anthropic-oauth--get-header-slot-index) 5)))))))

;;; Curl Args Advice Tests

(ert-deftest ogent-oauth-test-curl-args-advice-passthrough ()
  "Test curl-args-advice passes through when no OAuth headers."
  (let ((orig-called nil)
        (orig-data nil)
        (orig-token nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--get-oauth-headers-for-gptel)
               (lambda () nil)))
      (let ((orig-fn (lambda (data token)
                       (setq orig-called t
                             orig-data data
                             orig-token token)
                       (list data token))))
        (ogent-anthropic-oauth--curl-args-advice orig-fn "data" "token")
        (should orig-called)
        (should (equal orig-data "data"))
        (should (equal orig-token "token"))))))

;;; Enable / Disable Tests

(ert-deftest ogent-oauth-test-enable-sets-flag ()
  "Test that enable sets the advice-installed flag."
  (let ((ogent-anthropic-oauth--advice-installed nil))
    ;; Mock advice installation to avoid side effects
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--install-curl-advice)
               (lambda () nil))
              ((symbol-function 'ogent-anthropic-oauth--install-request-advice)
               (lambda () nil)))
      (ogent-anthropic-oauth-enable)
      (should ogent-anthropic-oauth--advice-installed))))

(ert-deftest ogent-oauth-test-enable-idempotent ()
  "Test that calling enable twice does not double-install."
  (let ((ogent-anthropic-oauth--advice-installed t)
        (install-count 0))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--install-curl-advice)
               (lambda () (cl-incf install-count)))
              ((symbol-function 'ogent-anthropic-oauth--install-request-advice)
               (lambda () (cl-incf install-count))))
      (ogent-anthropic-oauth-enable)
      ;; Should not install again since flag is already t
      (should (= install-count 0)))))

(ert-deftest ogent-oauth-test-disable-clears-flag ()
  "Test that disable clears the advice-installed flag."
  (let ((ogent-anthropic-oauth--advice-installed t))
    (ogent-anthropic-oauth-disable)
    (should-not ogent-anthropic-oauth--advice-installed)))

(ert-deftest ogent-oauth-test-disable-noop-when-not-installed ()
  "Test that disable is a no-op when not installed."
  (let ((ogent-anthropic-oauth--advice-installed nil))
    ;; Should not error
    (ogent-anthropic-oauth-disable)
    (should-not ogent-anthropic-oauth--advice-installed)))

;;; Login / Logout / Status Tests (Mocked)

(ert-deftest ogent-oauth-test-logout-no-tokens ()
  "Test logout message when not logged in."
  (let ((ogent-anthropic-oauth--tokens nil)
        (last-msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-anthropic-logout)
      (should (string-match-p "Not logged in" last-msg)))))

(ert-deftest ogent-oauth-test-status-no-tokens ()
  "Test status display when not authenticated."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth--token-file nil)
        (ogent-anthropic-oauth--known-token-paths nil)
        (ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-stat-" t))
        (last-msg nil))
    (unwind-protect
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (setq last-msg (apply #'format fmt args)))))
          (ogent-anthropic-status)
          (should (string-match-p "Not logged in" last-msg)))
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

(ert-deftest ogent-oauth-test-status-with-console-tokens ()
  "Test status display for console mode."
  (let ((ogent-anthropic-oauth--tokens
         '(:mode console :type auth/token :api-key "key"
           :created-at 1700000000))
        (last-msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-anthropic-status)
      (should (string-match-p "console" last-msg))
      (should (string-match-p "API key active" last-msg)))))

(ert-deftest ogent-oauth-test-status-with-max-valid-tokens ()
  "Test status display for max mode with valid token."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'max :type 'auth/oauth :api-key "token"
               :expires-at (+ (floor (float-time)) 3600)
               :created-at 1700000000))
        (last-msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-anthropic-status)
      (should (string-match-p "max" last-msg))
      (should (string-match-p "token valid" last-msg)))))

(ert-deftest ogent-oauth-test-status-with-expired-tokens ()
  "Test status display for max mode with expired token."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'max :type 'auth/oauth :api-key "token"
               :expires-at (- (floor (float-time)) 100)
               :created-at 1700000000))
        (last-msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-anthropic-status)
      (should (string-match-p "expired" last-msg)))))

;;; URL Retrieve Tests

(ert-deftest ogent-oauth-test-url-retrieve-sync-success ()
  "Test url-retrieve-sync parses JSON response."
  (let ((mock-buffer (generate-new-buffer " *test-url*")))
    (unwind-protect
        (progn
          (with-current-buffer mock-buffer
            (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n")
            (insert "{\"access_token\": \"tok123\", \"expires_in\": 3600}"))
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (_url &rest _) mock-buffer)))
            (let ((result (ogent-anthropic-oauth--url-retrieve-sync
                          "https://example.com/token"
                          "POST" nil
                          '(:grant_type "authorization_code"))))
              (should (equal (plist-get result :access_token) "tok123"))
              (should (equal (plist-get result :expires_in) 3600)))))
      (when (buffer-live-p mock-buffer)
        (kill-buffer mock-buffer)))))

(ert-deftest ogent-oauth-test-url-retrieve-sync-connection-failure ()
  "Test url-retrieve-sync handles connection failure."
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (_url &rest _) nil)))
    (should-error (ogent-anthropic-oauth--url-retrieve-sync
                   "https://example.com/token"
                   "POST" nil nil))))

;;; Ensure Valid Token Tests

(ert-deftest ogent-oauth-test-ensure-valid-token-nil-tokens ()
  "Test ensure-valid-token returns nil when no tokens."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth--token-file nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--find-existing-token-file)
               (lambda () nil))
              ((symbol-function 'ogent-anthropic-oauth--restore-tokens)
               (lambda () nil)))
      (should-not (ogent-anthropic-oauth--ensure-valid-token)))))

(ert-deftest ogent-oauth-test-ensure-valid-token-console-mode ()
  "Test ensure-valid-token returns key for console mode (no refresh)."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'console :type 'auth/token :api-key "sk-test123"))
        (ogent-anthropic-oauth--mode 'console))
    (should (equal (ogent-anthropic-oauth--ensure-valid-token) "sk-test123"))))

(ert-deftest ogent-oauth-test-ensure-valid-token-refresh-clears-on-failure ()
  "Test that refresh failure clears tokens."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'max :type 'auth/oauth :api-key "old-token"
               :refresh-token "bad-refresh"
               :expires-at (- (floor (float-time)) 100)))
        (ogent-anthropic-oauth--mode 'max)
        (ogent-anthropic-oauth--token-file nil)
        (last-msg nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--refresh-token)
               (lambda (_) (error "Refresh failed")))
              ((symbol-function 'ogent-anthropic-oauth--find-existing-token-file)
               (lambda () nil))
              ((symbol-function 'ogent-anthropic-oauth--clear-tokens)
               (lambda ()
                 (setq ogent-anthropic-oauth--tokens nil
                       ogent-anthropic-oauth--mode nil)))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-anthropic-oauth--ensure-valid-token)
      ;; Tokens should be cleared after refresh failure
      (should-not ogent-anthropic-oauth--tokens)
      (should (string-match-p "refresh failed" last-msg)))))

;;; Get Headers Tests

(ert-deftest ogent-oauth-test-get-headers-max-mode ()
  "Test get-headers returns Bearer token for max mode."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'max :type 'auth/oauth :api-key "tok123"
               :expires-at (+ (floor (float-time)) 3600)))
        (ogent-anthropic-oauth--mode 'max))
    (let ((headers (ogent-anthropic-oauth-get-headers)))
      (should headers)
      (should (string-match-p "Bearer tok123"
                              (cdr (assoc "Authorization" headers))))
      (should (assoc "anthropic-beta" headers)))))

(ert-deftest ogent-oauth-test-get-headers-console-mode ()
  "Test get-headers returns x-api-key for console mode."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'console :type 'auth/token :api-key "sk-test123"))
        (ogent-anthropic-oauth--mode 'console))
    (let ((headers (ogent-anthropic-oauth-get-headers)))
      (should headers)
      (should (equal (cdr (assoc "x-api-key" headers)) "sk-test123"))
      ;; Should NOT have Bearer header
      (should-not (assoc "Authorization" headers)))))

(ert-deftest ogent-oauth-test-get-headers-nil-when-no-tokens ()
  "Test get-headers returns nil when not authenticated."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth--token-file nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--find-existing-token-file)
               (lambda () nil))
              ((symbol-function 'ogent-anthropic-oauth--restore-tokens)
               (lambda () nil)))
      (should-not (ogent-anthropic-oauth-get-headers)))))

;;; OAuth Mode Tests

(ert-deftest ogent-oauth-test-mode-returns-current ()
  "Test oauth-mode returns current auth mode."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'max :type 'auth/oauth :api-key "tok"
               :expires-at (+ (floor (float-time)) 3600)))
        (ogent-anthropic-oauth--mode 'max))
    (should (eq (ogent-anthropic-oauth-mode) 'max))))

;;; Enable/Disable Tests

(ert-deftest ogent-oauth-test-enable-sets-advice-flag ()
  "Test that enable sets the advice-installed flag."
  (let ((ogent-anthropic-oauth--advice-installed nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--install-curl-advice)
               (lambda () nil))
              ((symbol-function 'ogent-anthropic-oauth--install-request-advice)
               (lambda () nil))
              ((symbol-function 'message)
               (lambda (&rest _) nil)))
      (ogent-anthropic-oauth-enable)
      (should ogent-anthropic-oauth--advice-installed))))

(ert-deftest ogent-oauth-test-disable-clears-advice-flag ()
  "Test that disable clears the advice-installed flag."
  (let ((ogent-anthropic-oauth--advice-installed t))
    (cl-letf (((symbol-function 'advice-remove)
               (lambda (_fn _advice) nil))
              ((symbol-function 'message)
               (lambda (&rest _) nil)))
      (ogent-anthropic-oauth-disable)
      (should-not ogent-anthropic-oauth--advice-installed))))

;;; Token File Tests

(ert-deftest ogent-oauth-test-token-file-caches-path ()
  "Test that token-file caches the result."
  (let ((ogent-anthropic-oauth--token-file nil)
        (call-count 0))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--find-existing-token-file)
               (lambda ()
                 (cl-incf call-count)
                 nil)))
      (ogent-anthropic-oauth--token-file)
      (ogent-anthropic-oauth--token-file)
      ;; Should only look once since it caches the computed path
      (should (= call-count 1)))))

(ert-deftest ogent-oauth-test-using-bearer-p-by-type ()
  "Test using-bearer-p returns t only for oauth type."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'max :type 'auth/oauth :api-key "tok"
               :expires-at (+ (floor (float-time)) 3600)))
        (ogent-anthropic-oauth--mode 'max))
    (should (ogent-anthropic-oauth-using-bearer-p)))
  ;; Console mode should return nil
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'console :type 'auth/token :api-key "sk-test"))
        (ogent-anthropic-oauth--mode 'console))
    (should-not (ogent-anthropic-oauth-using-bearer-p))))

;;; Additional Coverage Tests

(ert-deftest ogent-oauth-test-status-no-created-at ()
  "Test status display when created-at is nil."
  (let ((ogent-anthropic-oauth--tokens
         (list :mode 'console :type 'auth/token :api-key "key"))
        (last-msg nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-msg (apply #'format fmt args)))))
      (ogent-anthropic-status)
      (should (string-match-p "console" last-msg))
      (should (string-match-p "API key active" last-msg))
      ;; Should NOT contain "created" since created-at is nil
      (should-not (string-match-p "created" last-msg)))))

(ert-deftest ogent-oauth-test-logout-confirmed ()
  "Test logout clears tokens when user confirms."
  (let* ((tmp-dir (make-temp-file "ogent-logout-" t))
         (ogent-anthropic-oauth-tokens-dir tmp-dir)
         (ogent-anthropic-oauth--token-file nil)
         (ogent-anthropic-oauth--tokens '(:mode max :api-key "test"))
         (ogent-anthropic-oauth--mode 'max)
         (ogent-anthropic-oauth--known-token-paths nil))
    (unwind-protect
        (progn
          ;; Save tokens to disk
          (ogent-anthropic-oauth--save-tokens ogent-anthropic-oauth--tokens)
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t)))
            (ogent-anthropic-logout)
            (should-not ogent-anthropic-oauth--tokens)
            (should-not ogent-anthropic-oauth--mode)))
      (when (file-directory-p tmp-dir)
        (delete-directory tmp-dir t)))))

(ert-deftest ogent-oauth-test-logout-cancelled ()
  "Test logout does not clear tokens when user declines."
  (let ((ogent-anthropic-oauth--tokens '(:mode max :api-key "test"))
        (ogent-anthropic-oauth--mode 'max))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) nil)))
      (ogent-anthropic-logout)
      ;; Tokens should still be there
      (should ogent-anthropic-oauth--tokens)
      (should (eq ogent-anthropic-oauth--mode 'max)))))

(ert-deftest ogent-oauth-test-ensure-tokens-loaded-resets-file ()
  "Test ensure-tokens-loaded resets token-file when file does not exist."
  (let ((ogent-anthropic-oauth--tokens nil)
        (ogent-anthropic-oauth--mode nil)
        (ogent-anthropic-oauth--token-file "/nonexistent/path/tokens.el")
        (ogent-anthropic-oauth--known-token-paths nil)
        (ogent-anthropic-oauth-tokens-dir (make-temp-file "ogent-reset-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'ogent-anthropic-oauth--restore-tokens)
                   (lambda () nil)))
          (ogent-anthropic-oauth--ensure-tokens-loaded)
          ;; token-file should have been reset since the old path didn't exist
          (should-not (equal ogent-anthropic-oauth--token-file
                             "/nonexistent/path/tokens.el")))
      (delete-directory ogent-anthropic-oauth-tokens-dir t))))

(ert-deftest ogent-oauth-test-exchange-code-no-hash ()
  "Test exchange-code handles code without # separator."
  (let ((received-data nil))
    (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
               (lambda (_url _method _headers data)
                 (setq received-data data)
                 (list :access_token "tok"
                       :refresh_token "ref"
                       :expires_in 3600))))
      (ogent-anthropic-oauth--exchange-code "plaincode" "verifier")
      ;; :code should be "plaincode", :state should be nil
      (should (equal (plist-get received-data :code) "plaincode"))
      (should-not (plist-get received-data :state)))))

(ert-deftest ogent-oauth-test-refresh-token-default-expires ()
  "Test refresh-token defaults expires-in to 3600."
  (cl-letf (((symbol-function 'ogent-anthropic-oauth--url-retrieve-sync)
             (lambda (_url _method _headers _data)
               (list :access_token "new-tok"
                     :refresh_token "new-ref"))))
    (let ((result (ogent-anthropic-oauth--refresh-token "old-ref")))
      (should (numberp (plist-get result :expires-at)))
      ;; Should be roughly now + 3600 (default)
      (should (> (plist-get result :expires-at) (floor (float-time)))))))

(ert-deftest ogent-oauth-test-get-headers-includes-anthropic-version ()
  "Test headers include anthropic-version for both modes."
  ;; Max mode
  (let ((ogent-anthropic-oauth--tokens
         (list :type 'auth/oauth :api-key "tok"
               :expires-at (+ (floor (float-time)) 3600))))
    (let ((headers (ogent-anthropic-oauth-get-headers)))
      (should (equal (cdr (assoc "anthropic-version" headers)) "2023-06-01"))))
  ;; Console mode
  (let ((ogent-anthropic-oauth--tokens
         (list :type 'auth/token :api-key "sk-key")))
    (let ((headers (ogent-anthropic-oauth-get-headers)))
      (should (equal (cdr (assoc "anthropic-version" headers)) "2023-06-01")))))

(ert-deftest ogent-oauth-test-install-curl-advice-when-available ()
  "Test install-curl-advice adds advice when gptel-curl--get-args exists."
  (let ((advice-added nil))
    (cl-letf (((symbol-function 'gptel-curl--get-args) (lambda (&rest _) nil))
              ((symbol-function 'advice-member-p) (lambda (_adv _fn) nil))
              ((symbol-function 'advice-add)
               (lambda (_fn _how _advice) (setq advice-added t))))
      (ogent-anthropic-oauth--install-curl-advice)
      (should advice-added))))

(ert-deftest ogent-oauth-test-install-request-advice-when-available ()
  "Test install-request-advice adds advice when gptel--request-data exists."
  (let ((advice-added nil)
        (ogent-anthropic-oauth-debug nil))
    (cl-letf (((symbol-function 'gptel--request-data) (lambda (&rest _) nil))
              ((symbol-function 'advice-member-p) (lambda (_adv _fn) nil))
              ((symbol-function 'advice-add)
               (lambda (_fn _how _advice) (setq advice-added t))))
      (ogent-anthropic-oauth--install-request-advice)
      (should advice-added))))

(ert-deftest ogent-oauth-test-save-tokens-creates-directory ()
  "Test save-tokens creates the directory if it doesn't exist."
  (let* ((tmp-dir (make-temp-file "ogent-save-" t))
         (sub-dir (expand-file-name "subdir" tmp-dir))
         (ogent-anthropic-oauth-tokens-dir sub-dir)
         (ogent-anthropic-oauth--token-file nil)
         (ogent-anthropic-oauth--known-token-paths nil))
    (unwind-protect
        (progn
          (should-not (file-directory-p sub-dir))
          (ogent-anthropic-oauth--save-tokens '(:mode max :api-key "test"))
          ;; Directory should have been created
          (should (file-directory-p sub-dir))
          ;; Token file should exist
          (let ((token-file (expand-file-name "tokens.el" sub-dir)))
            (should (file-exists-p token-file))))
      (when (file-directory-p tmp-dir)
        (delete-directory tmp-dir t)))))

(provide 'ogent-anthropic-oauth-tests)

;;; ogent-anthropic-oauth-tests.el ends here
