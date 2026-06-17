;;; ogent-anthropic-oauth.el --- OAuth authentication for Claude Max -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Jake Miller
;; Keywords: convenience, anthropic, oauth
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9.5"))

;;; Commentary:

;; OAuth authentication support for Anthropic Claude Max/Pro plans.
;; Enables browser-based authentication instead of manual API key management.
;;
;; Implementation based on:
;; - OpenCode's opencode-anthropic-auth plugin
;; - Anthropic's OAuth 2.0 + PKCE flow for Claude Code
;;
;; Usage:
;;   (require 'ogent-anthropic-oauth)
;;   M-x ogent-anthropic-login
;;
;; Two authentication modes:
;; - max: OAuth bearer tokens with auto-refresh (Claude Pro/Max subscription)
;; - console: Creates a static API key via OAuth (standard API access)
;;
;; Tokens are stored in `ogent-anthropic-oauth-tokens-dir' and
;; automatically restored across Emacs sessions.

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'json)

;; Forward declarations for gptel
(declare-function gptel-backend-header "ext:gptel-request" t t)
(declare-function gptel-curl--get-args "ext:gptel-curl")
(declare-function gptel--request-data "ext:gptel-request")
(declare-function gptel-anthropic-p "ext:gptel-anthropic" t t)
(defvar gptel-backend)
(defvar gptel--known-backends)
(defvar gptel--system-message)

;; We need to declare the setf expander for gptel-backend-header
;; This is defined by cl-defstruct in gptel-openai.el
(eval-when-compile
  (require 'cl-lib))

;;; OAuth Constants

(defconst ogent-anthropic-oauth--client-id
  "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  "Anthropic OAuth client ID (shared with Claude Code/OpenCode).")

(defconst ogent-anthropic-oauth--redirect-uri
  "https://console.anthropic.com/oauth/code/callback"
  "OAuth redirect URI.")

(defconst ogent-anthropic-oauth--scope
  "org:create_api_key user:profile user:inference"
  "OAuth scopes to request.")

(defconst ogent-anthropic-oauth--token-url
  "https://console.anthropic.com/v1/oauth/token"
  "OAuth token exchange endpoint.")

(defconst ogent-anthropic-oauth--api-key-url
  "https://api.anthropic.com/api/oauth/claude_cli/create_api_key"
  "Endpoint to create static API key from OAuth token.")

(defconst ogent-anthropic-oauth--beta-features
  "oauth-2025-04-20,claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14"
  "Required beta features header for OAuth requests.")

(defconst ogent-anthropic-oauth--system-prefix
  "You are Claude Code, Anthropic's official CLI for Claude."
  "System message prefix required for OAuth tokens to work.")

;;; Configuration

(defgroup ogent-anthropic-oauth nil
  "OAuth authentication for Anthropic Claude."
  :group 'ogent)

(defcustom ogent-anthropic-oauth-tokens-dir
  (expand-file-name "ogent/anthropic-oauth/" user-emacs-directory)
  "Directory where Anthropic OAuth tokens are stored."
  :type 'directory
  :group 'ogent-anthropic-oauth)

(defvar ogent-anthropic-oauth--token-file nil
  "File where tokens are cached.  Set from `ogent-anthropic-oauth-tokens-dir'.")

(defvar ogent-anthropic-oauth--known-token-paths
  '("~/.emacs.d/ogent/anthropic-oauth/tokens.el"
    "~/.emacs.d/.local/cache/ogent/anthropic-oauth/tokens.el"
    "~/.config/emacs/ogent/anthropic-oauth/tokens.el"
    "~/.config/doom/ogent/anthropic-oauth/tokens.el"
    "~/.doom.d/ogent/anthropic-oauth/tokens.el"
    ;; Jake's custom Doom location
    "~/vault/projects/config/nixconfig/home-nixpkgs/doom-emacs/.local/cache/ogent/anthropic-oauth/tokens.el")
  "Known paths where OAuth tokens might be stored.")

(defun ogent-anthropic-oauth--find-existing-token-file ()
  "Find existing token file in known locations.
Checks multiple possible locations for Doom/Spacemacs compatibility."
  (let ((candidates
         (append
          (list
           ;; Primary location from customization
           (expand-file-name "tokens.el" ogent-anthropic-oauth-tokens-dir)
           ;; Doom Emacs cache location (bound variable)
           (when (bound-and-true-p doom-cache-dir)
             (expand-file-name "ogent/anthropic-oauth/tokens.el" doom-cache-dir))
           ;; Doom Emacs cache location (standard path)
           (expand-file-name ".local/cache/ogent/anthropic-oauth/tokens.el"
                             user-emacs-directory)
           ;; XDG location
           (expand-file-name "emacs/ogent/anthropic-oauth/tokens.el"
                             (or (getenv "XDG_DATA_HOME")
                                 (expand-file-name "~/.local/share")))
           ;; Doom with custom DOOMDIR
           (when (getenv "DOOMDIR")
             (expand-file-name ".local/cache/ogent/anthropic-oauth/tokens.el"
                               (getenv "DOOMDIR"))))
          ;; Known paths (expanded)
          (mapcar #'expand-file-name ogent-anthropic-oauth--known-token-paths))))
    (cl-find-if #'file-exists-p (delq nil candidates))))

(defun ogent-anthropic-oauth--token-file ()
  "Return the path to the token file, creating directory if needed."
  (unless ogent-anthropic-oauth--token-file
    (setq ogent-anthropic-oauth--token-file
          (or (ogent-anthropic-oauth--find-existing-token-file)
              (expand-file-name "tokens.el" ogent-anthropic-oauth-tokens-dir))))
  ogent-anthropic-oauth--token-file)

;;; State Storage

(defvar ogent-anthropic-oauth--tokens nil
  "Current OAuth tokens plist, or nil if not authenticated.")

(defvar ogent-anthropic-oauth--mode nil
  "Current auth mode: `max' for bearer tokens, `console' for API key.")

;;; PKCE Implementation (RFC 7636)

(defun ogent-anthropic-oauth--random-bytes (length)
  "Generate LENGTH random bytes as a unibyte string."
  (let ((bytes (make-string length 0)))
    (dotimes (i length)
      (aset bytes i (random 256)))
    bytes))

(defun ogent-anthropic-oauth--base64url-encode (string)
  "Base64url encode STRING per RFC 4648.
URL-safe characters, no padding."
  (let ((b64 (base64-encode-string string t)))
    (setq b64 (replace-regexp-in-string "+" "-" b64))
    (setq b64 (replace-regexp-in-string "/" "_" b64))
    (replace-regexp-in-string "=" "" b64)))

(defun ogent-anthropic-oauth--sha256 (string)
  "Compute SHA-256 hash of STRING as raw bytes."
  (secure-hash 'sha256 string nil nil t))

(defun ogent-anthropic-oauth--generate-pkce ()
  "Generate PKCE verifier and challenge.
Return plist (:verifier VERIFIER :challenge CHALLENGE)."
  (let* ((verifier (ogent-anthropic-oauth--base64url-encode
                    (ogent-anthropic-oauth--random-bytes 63)))
         (challenge (ogent-anthropic-oauth--base64url-encode
                     (ogent-anthropic-oauth--sha256 verifier))))
    (list :verifier verifier :challenge challenge)))

;;; Token Storage

(defun ogent-anthropic-oauth--restore-tokens ()
  "Restore saved tokens from file.  Return tokens plist or nil."
  (let ((file (ogent-anthropic-oauth--token-file)))
    (when (file-exists-p file)
      (condition-case nil
          (let ((coding-system-for-read 'utf-8-auto-dos))
            (with-temp-buffer
              (insert-file-contents-literally file)
              (goto-char (point-min))
              (read (current-buffer))))
        (error nil)))))

(defun ogent-anthropic-oauth--save-tokens (tokens)
  "Save TOKENS to file.  Return TOKENS."
  (let ((file (ogent-anthropic-oauth--token-file))
        (print-length nil)
        (print-level nil)
        (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert ";; Anthropic OAuth tokens - do not edit manually\n")
      (insert ";; Generated by ogent-anthropic-oauth.el\n\n")
      (prin1 tokens (current-buffer)))
    ;; Restrict permissions
    (set-file-modes file #o600)
    tokens))

(defun ogent-anthropic-oauth--clear-tokens ()
  "Clear all stored tokens."
  (let ((file (ogent-anthropic-oauth--token-file)))
    (when (file-exists-p file)
      (delete-file file)))
  (setq ogent-anthropic-oauth--tokens nil)
  (setq ogent-anthropic-oauth--mode nil))

;;; HTTP Helpers

(defun ogent-anthropic-oauth--url-retrieve-sync (url method headers data)
  "Synchronous HTTP request to URL with METHOD, HEADERS, and DATA.
Return parsed JSON response as plist."
  (let* ((url-request-method method)
         (url-request-extra-headers
          (append '(("Content-Type" . "application/json")
                    ("Accept" . "application/json"))
                  headers))
         (url-request-data (when data
                             (encode-coding-string
                              (json-encode data) 'utf-8)))
         (buffer (url-retrieve-synchronously url t t 30)))
    (unless buffer
      (error "Failed to connect to %s" url))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          ;; Skip HTTP headers
          (re-search-forward "\r?\n\r?\n" nil t)
          (let ((json-object-type 'plist)
                (json-array-type 'list)
                (json-key-type 'keyword))
            (condition-case err
                (json-read)
              (error
               (error "Failed to parse response: %s" (error-message-string err))))))
      (kill-buffer buffer))))

;;; OAuth Flow

(defun ogent-anthropic-oauth--authorization-url (mode)
  "Generate OAuth authorization URL for MODE (`max' or `console').
Return plist (:url URL :verifier VERIFIER)."
  (let* ((pkce (ogent-anthropic-oauth--generate-pkce))
         (verifier (plist-get pkce :verifier))
         (challenge (plist-get pkce :challenge))
         (base-url (if (eq mode 'console)
                       "https://console.anthropic.com"
                     "https://claude.ai"))
         (params `(("code" . "true")
                   ("client_id" . ,ogent-anthropic-oauth--client-id)
                   ("response_type" . "code")
                   ("redirect_uri" . ,ogent-anthropic-oauth--redirect-uri)
                   ("scope" . ,ogent-anthropic-oauth--scope)
                   ("code_challenge" . ,challenge)
                   ("code_challenge_method" . "S256")
                   ("state" . ,verifier)))
         (query-string (mapconcat
                        (lambda (p)
                          (concat (url-hexify-string (car p))
                                  "="
                                  (url-hexify-string (cdr p))))
                        params "&")))
    (list :url (concat base-url "/oauth/authorize?" query-string)
          :verifier verifier)))

(defun ogent-anthropic-oauth--exchange-code (code verifier)
  "Exchange authorization CODE using VERIFIER.
Return token plist with :access-token, :refresh-token, :expires-at."
  (let* ((code-parts (split-string code "#"))
         (auth-code (car code-parts))
         (state (cadr code-parts))
         (response (ogent-anthropic-oauth--url-retrieve-sync
                    ogent-anthropic-oauth--token-url
                    "POST" nil
                    `(:grant_type "authorization_code"
                                  :code ,auth-code
                                  :state ,state
                                  :client_id ,ogent-anthropic-oauth--client-id
                                  :redirect_uri ,ogent-anthropic-oauth--redirect-uri
                                  :code_verifier ,verifier))))
    (unless (plist-get response :access_token)
      (error "Token exchange failed: %s"
             (or (plist-get response :error_description)
                 (plist-get response :error)
                 "Unknown error")))
    (list :access-token (plist-get response :access_token)
          :refresh-token (plist-get response :refresh_token)
          :expires-at (+ (floor (float-time))
                         (or (plist-get response :expires_in) 3600)))))

(defun ogent-anthropic-oauth--refresh-token (refresh-token)
  "Refresh access token using REFRESH-TOKEN.
Return updated token plist."
  (let ((response (ogent-anthropic-oauth--url-retrieve-sync
                   ogent-anthropic-oauth--token-url
                   "POST" nil
                   `(:grant_type "refresh_token"
                                 :refresh_token ,refresh-token
                                 :client_id ,ogent-anthropic-oauth--client-id))))
    (unless (plist-get response :access_token)
      (error "Token refresh failed: %s"
             (or (plist-get response :error_description)
                 (plist-get response :error)
                 "Unknown error")))
    (list :access-token (plist-get response :access_token)
          :refresh-token (plist-get response :refresh_token)
          :expires-at (+ (floor (float-time))
                         (or (plist-get response :expires_in) 3600)))))

(defun ogent-anthropic-oauth--create-api-key (access-token)
  "Create static API key using ACCESS-TOKEN (console mode).
Return API key string."
  (let ((response (ogent-anthropic-oauth--url-retrieve-sync
                   ogent-anthropic-oauth--api-key-url
                   "POST"
                   `(("Authorization" . ,(concat "Bearer " access-token)))
                   nil)))
    (or (plist-get response :raw_key)
        (error "Failed to create API key: %s"
               (or (plist-get response :error) "Unknown error")))))

;;; Token Management

(defun ogent-anthropic-oauth--ensure-valid-token ()
  "Ensure we have a valid access token, refreshing if needed.
Return the current access token or nil."
  ;; Use the centralized token loading function
  (ogent-anthropic-oauth--ensure-tokens-loaded)
  
  (when ogent-anthropic-oauth--tokens
    (let ((auth-type (plist-get ogent-anthropic-oauth--tokens :type))
          (expires-at (plist-get ogent-anthropic-oauth--tokens :expires-at)))
      
      ;; Auto-refresh if expired (max mode only)
      (when (and (eq auth-type 'auth/oauth)
                 expires-at
                 (> (floor (float-time)) expires-at))
        (message "Refreshing Anthropic OAuth token...")
        (condition-case err
            (let* ((refresh-token (plist-get ogent-anthropic-oauth--tokens :refresh-token))
                   (new-tokens (ogent-anthropic-oauth--refresh-token refresh-token)))
              (plist-put ogent-anthropic-oauth--tokens :api-key
                         (plist-get new-tokens :access-token))
              (plist-put ogent-anthropic-oauth--tokens :refresh-token
                         (plist-get new-tokens :refresh-token))
              (plist-put ogent-anthropic-oauth--tokens :expires-at
                         (plist-get new-tokens :expires-at))
              (ogent-anthropic-oauth--save-tokens ogent-anthropic-oauth--tokens)
              (message "Anthropic OAuth token refreshed"))
          (error
           (ogent-anthropic-oauth--clear-tokens)
           (message "Token refresh failed: %s. Please run M-x ogent-anthropic-login"
                    (error-message-string err))
           nil)))
      
      (plist-get ogent-anthropic-oauth--tokens :api-key))))

;;; Public API

(defun ogent-anthropic-oauth-authenticated-p ()
  "Return non-nil if OAuth authentication is active."
  (ogent-anthropic-oauth--ensure-valid-token))

(defun ogent-anthropic-oauth-mode ()
  "Return current auth mode (`max', `console') or nil."
  (ogent-anthropic-oauth--ensure-valid-token)
  ogent-anthropic-oauth--mode)

(defun ogent-anthropic-oauth-get-headers ()
  "Return OAuth headers for Anthropic API requests, or nil.
For max mode: Bearer token with beta headers.
For console mode: Standard x-api-key header."
  (when-let ((api-key (ogent-anthropic-oauth--ensure-valid-token)))
    (let ((auth-type (plist-get ogent-anthropic-oauth--tokens :type)))
      (if (eq auth-type 'auth/oauth)
          ;; Max mode: Bearer token with required beta headers
          `(("Authorization" . ,(concat "Bearer " api-key))
            ("anthropic-version" . "2023-06-01")
            ("anthropic-beta" . ,ogent-anthropic-oauth--beta-features))
        ;; Console mode: standard API key
        `(("x-api-key" . ,api-key)
          ("anthropic-version" . "2023-06-01"))))))

(defun ogent-anthropic-oauth-using-bearer-p ()
  "Return non-nil if using OAuth bearer tokens (max mode)."
  (and (ogent-anthropic-oauth--ensure-valid-token)
       (eq (plist-get ogent-anthropic-oauth--tokens :type) 'auth/oauth)))

;;; User Commands

;;;###autoload
(defun ogent-anthropic-login (&optional mode)
  "Login to Anthropic via OAuth.

Prompts for login MODE if not provided:
- `max': Use refresh tokens with auto-refresh (Claude Pro/Max subscription)
- `console': Create static API key (standard API access)

Opens browser for authorization, then prompts for the authorization code."
  (interactive
   (list (intern (completing-read
                  "Anthropic login mode: "
                  '("max" "console")
                  nil t nil nil "max"))))
  
  ;; Generate OAuth URL
  (pcase-let* ((`(:url ,url :verifier ,verifier)
                (ogent-anthropic-oauth--authorization-url mode)))
    
    ;; Copy URL to clipboard
    (when (fboundp 'gui-set-selection)
      (gui-set-selection 'CLIPBOARD url))
    
    ;; Prompt and open browser
    (read-from-minibuffer
     (format "Authorization URL copied to clipboard.\nPress ENTER to open browser.\nURL: %s\n" url))
    (browse-url url)
    
    ;; Get authorization code
    (let ((code (read-string "Paste the authorization code from the redirect URL: ")))
      (when (string-empty-p code)
        (user-error "Authorization cancelled"))
      
      ;; Exchange code for tokens
      (message "Exchanging authorization code...")
      (condition-case err
          (let ((token-data (ogent-anthropic-oauth--exchange-code code verifier)))
            
            (cond
             ;; Console mode: create static API key
             ((eq mode 'console)
              (let ((api-key (ogent-anthropic-oauth--create-api-key
                              (plist-get token-data :access-token))))
                (setq ogent-anthropic-oauth--tokens
                      (ogent-anthropic-oauth--save-tokens
                       (list :mode 'console
                             :type 'auth/token
                             :api-key api-key
                             :created-at (floor (float-time)))))
                (setq ogent-anthropic-oauth--mode 'console)
                (message "Logged in to Anthropic (console mode). API key stored.")))
             
             ;; Max mode: store refresh token for auto-renewal
             ((eq mode 'max)
              (setq ogent-anthropic-oauth--tokens
                    (ogent-anthropic-oauth--save-tokens
                     (list :mode 'max
                           :type 'auth/oauth
                           :api-key (plist-get token-data :access-token)
                           :refresh-token (plist-get token-data :refresh-token)
                           :expires-at (plist-get token-data :expires-at)
                           :created-at (floor (float-time)))))
              (setq ogent-anthropic-oauth--mode 'max)
              (message "Logged in to Anthropic (max mode). Tokens stored with auto-refresh."))))
        
        (error
         (user-error "Failed to exchange authorization code: %s"
                     (error-message-string err)))))))

;;;###autoload
(defun ogent-anthropic-logout ()
  "Clear Anthropic OAuth tokens."
  (interactive)
  (if (not ogent-anthropic-oauth--tokens)
      (message "Not logged in to Anthropic OAuth")
    (when (yes-or-no-p "Clear Anthropic OAuth tokens? ")
      (ogent-anthropic-oauth--clear-tokens)
      (message "Cleared Anthropic OAuth tokens"))))

;;;###autoload
(defun ogent-anthropic-status ()
  "Display current Anthropic OAuth authentication status."
  (interactive)
  (if-let ((tokens (or ogent-anthropic-oauth--tokens
                       (ogent-anthropic-oauth--restore-tokens))))
      (let* ((mode (plist-get tokens :mode))
             (auth-type (plist-get tokens :type))
             (expires-at (plist-get tokens :expires-at))
             (created-at (plist-get tokens :created-at)))
        (message "Anthropic OAuth: %s mode, %s%s"
                 mode
                 (if (eq auth-type 'auth/oauth)
                     (if (and expires-at (> (floor (float-time)) expires-at))
                         "token expired (will refresh)"
                       "token valid")
                   "API key active")
                 (if created-at
                     (format " (created %s)"
                             (format-time-string "%Y-%m-%d" created-at))
                   "")))
    (message "Not logged in to Anthropic OAuth. Run M-x ogent-anthropic-login")))

;;; Claude Code compatibility aliases

;;;###autoload
(defun ogent-claude-code-login (&optional mode)
  "Login through the Claude Code-compatible OAuth flow.
MODE defaults to `max' for Claude Pro/Max subscriptions."
  (interactive
   (list (intern (completing-read
                  "Claude Code login mode: "
                  '("max" "console")
                  nil t nil nil "max"))))
  (ogent-anthropic-login (or mode 'max)))

;;;###autoload
(defun ogent-claude-code-logout ()
  "Clear Claude Code-compatible OAuth tokens."
  (interactive)
  (ogent-anthropic-logout))

;;;###autoload
(defun ogent-claude-code-status ()
  "Display Claude Code-compatible OAuth authentication status."
  (interactive)
  (ogent-anthropic-status))

(defun ogent-claude-code-authenticated-p ()
  "Return non-nil if Claude Code-compatible OAuth is active."
  (ogent-anthropic-oauth-authenticated-p))

;;; gptel Integration via Advice

(defvar ogent-anthropic-oauth-debug nil
  "When non-nil, log debug messages for OAuth operations.")

(defun ogent-anthropic-oauth--ensure-tokens-loaded ()
  "Ensure tokens are loaded from disk if not already in memory."
  (unless ogent-anthropic-oauth--tokens
    ;; Only reset token file if we haven't found one yet
    (unless (and ogent-anthropic-oauth--token-file
                 (file-exists-p ogent-anthropic-oauth--token-file))
      (setq ogent-anthropic-oauth--token-file nil))
    (setq ogent-anthropic-oauth--tokens (ogent-anthropic-oauth--restore-tokens))
    (when ogent-anthropic-oauth--tokens
      (setq ogent-anthropic-oauth--mode
            (plist-get ogent-anthropic-oauth--tokens :mode)))))

(defun ogent-anthropic-oauth--get-oauth-headers-for-gptel ()
  "Get OAuth headers if tokens available and backend is Anthropic."
  ;; Ensure tokens are loaded
  (ogent-anthropic-oauth--ensure-tokens-loaded)
  (when ogent-anthropic-oauth-debug
    (message "OAuth debug: backend=%S anthropic-p=%S tokens=%S token-file=%S"
             (and (boundp 'gptel-backend) gptel-backend
                  (when gptel-backend (type-of gptel-backend)))
             (and (fboundp 'gptel-anthropic-p)
                  (boundp 'gptel-backend)
                  gptel-backend
                  (gptel-anthropic-p gptel-backend))
             (and ogent-anthropic-oauth--tokens t)
             ogent-anthropic-oauth--token-file))
  (when (and (boundp 'gptel-backend)
             gptel-backend
             (fboundp 'gptel-anthropic-p)
             (gptel-anthropic-p gptel-backend))
    (ogent-anthropic-oauth-get-headers)))

(defun ogent-anthropic-oauth--using-oauth-for-gptel-p ()
  "Return non-nil if current gptel request should use OAuth."
  (let ((result (and (boundp 'gptel-backend)
                     gptel-backend
                     (fboundp 'gptel-anthropic-p)
                     (gptel-anthropic-p gptel-backend)
                     (ogent-anthropic-oauth-using-bearer-p))))
    (when ogent-anthropic-oauth-debug
      (message "OAuth debug: using-oauth-p=%S bearer-p=%S type=%S"
               result
               (ogent-anthropic-oauth-using-bearer-p)
               (plist-get ogent-anthropic-oauth--tokens :type)))
    result))

(defun ogent-anthropic-oauth--request-data-advice (orig-fn backend prompts)
  "Advice to prepend Claude Code system message for OAuth requests.
ORIG-FN is the original `gptel--request-data' method.
BACKEND and PROMPTS are passed through."
  ;; Ensure tokens are loaded before checking
  (ogent-anthropic-oauth--ensure-tokens-loaded)
  (if (ogent-anthropic-oauth--using-oauth-for-gptel-p)
      ;; Use exact Claude Code system message - Anthropic requires exact match
      ;; for OAuth tokens to work. Additional instructions must go in user prompt.
      (let ((gptel--system-message ogent-anthropic-oauth--system-prefix))
        (when ogent-anthropic-oauth-debug
          (message "OAuth debug: using system message: %s" gptel--system-message))
        (funcall orig-fn backend prompts))
    (funcall orig-fn backend prompts)))

(defvar ogent-anthropic-oauth--header-slot-index nil
  "Cached slot index for gptel-backend header field.")

(defun ogent-anthropic-oauth--get-header-slot-index ()
  "Get the slot index for the header field in gptel-backend struct."
  (or ogent-anthropic-oauth--header-slot-index
      (setq ogent-anthropic-oauth--header-slot-index
            (cl-struct-slot-offset 'gptel-backend 'header))))

(defun ogent-anthropic-oauth--curl-args-advice (orig-fn data token)
  "Advice to inject OAuth headers into curl args.
ORIG-FN is `gptel-curl--get-args', DATA and TOKEN are passed through.
We modify the backend struct's header slot temporarily."
  (if-let ((oauth-headers (ogent-anthropic-oauth--get-oauth-headers-for-gptel)))
      ;; Temporarily override the backend's header slot
      (let* ((backend gptel-backend)
             (slot-idx (ogent-anthropic-oauth--get-header-slot-index))
             (original-header (aref backend slot-idx)))
        (when ogent-anthropic-oauth-debug
          (message "OAuth debug: injecting headers: %S" oauth-headers))
        (unwind-protect
            (progn
              ;; Set header slot to our OAuth headers function
              (aset backend slot-idx (lambda () oauth-headers))
              (funcall orig-fn data token))
          ;; Restore original header
          (aset backend slot-idx original-header)))
    (funcall orig-fn data token)))

(defvar ogent-anthropic-oauth--advice-installed nil
  "Non-nil if gptel advice has been installed.")

(defun ogent-anthropic-oauth--install-curl-advice ()
  "Install advice on gptel-curl--get-args if available."
  (when (fboundp 'gptel-curl--get-args)
    (unless (advice-member-p #'ogent-anthropic-oauth--curl-args-advice
                             'gptel-curl--get-args)
      (advice-add 'gptel-curl--get-args :around
                  #'ogent-anthropic-oauth--curl-args-advice))))

(defun ogent-anthropic-oauth--install-request-advice ()
  "Install advice on gptel--request-data if available."
  ;; gptel--request-data is a cl-defgeneric, advice works on the dispatcher
  (when (fboundp 'gptel--request-data)
    (unless (advice-member-p #'ogent-anthropic-oauth--request-data-advice
                             'gptel--request-data)
      (advice-add 'gptel--request-data :around
                  #'ogent-anthropic-oauth--request-data-advice)
      (when ogent-anthropic-oauth-debug
        (message "OAuth debug: installed advice on gptel--request-data")))))

(defun ogent-anthropic-oauth-enable ()
  "Enable OAuth support for Anthropic backends in gptel."
  (interactive)
  (unless ogent-anthropic-oauth--advice-installed
    ;; Install immediately if already loaded
    (ogent-anthropic-oauth--install-curl-advice)
    (ogent-anthropic-oauth--install-request-advice)
    ;; Also install when loaded later
    (with-eval-after-load 'gptel-curl
      (ogent-anthropic-oauth--install-curl-advice))
    (with-eval-after-load 'gptel
      (ogent-anthropic-oauth--install-request-advice))
    (setq ogent-anthropic-oauth--advice-installed t)
    (message "Anthropic OAuth support enabled")))

(defun ogent-anthropic-oauth-disable ()
  "Disable OAuth support for Anthropic backends in gptel."
  (interactive)
  (when ogent-anthropic-oauth--advice-installed
    (advice-remove 'gptel-curl--get-args
                   #'ogent-anthropic-oauth--curl-args-advice)
    (advice-remove 'gptel--request-data
                   #'ogent-anthropic-oauth--request-data-advice)
    (setq ogent-anthropic-oauth--advice-installed nil)
    (message "Anthropic OAuth support disabled")))

;;; Auto-enable on load

(with-eval-after-load 'gptel
  (ogent-anthropic-oauth-enable)
  ;; Try to restore tokens on load
  (setq ogent-anthropic-oauth--tokens (ogent-anthropic-oauth--restore-tokens))
  (when ogent-anthropic-oauth--tokens
    (setq ogent-anthropic-oauth--mode
          (plist-get ogent-anthropic-oauth--tokens :mode))))

(provide 'ogent-anthropic-oauth)

;;; ogent-anthropic-oauth.el ends here
