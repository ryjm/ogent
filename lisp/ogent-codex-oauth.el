;;; ogent-codex-oauth.el --- Reuse Codex CLI OAuth credentials -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Jake Miller
;; Keywords: convenience, openai, oauth, codex
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9.5"))

;;; Commentary:

;; OAuth authentication support for OpenAI through the Codex CLI.
;;
;; Codex already implements the browser/device login flow and persists a
;; gptel-compatible API key in its auth cache after ChatGPT authentication.
;; This module starts that login flow when needed and reads the local cache
;; from $CODEX_HOME/auth.json or ~/.codex/auth.json without exposing token
;; values in messages.
;;
;; Usage:
;;   (require 'ogent-codex-oauth)
;;   M-x ogent-codex-login
;;   M-x ogent-codex-login-device

;;; Code:

(require 'json)
(require 'subr-x)

(defgroup ogent-codex-oauth nil
  "Reuse OpenAI Codex CLI OAuth credentials."
  :group 'ogent)

(defcustom ogent-codex-oauth-codex-executable "codex"
  "Codex CLI executable used for login, logout, and status commands."
  :type 'string
  :group 'ogent-codex-oauth)

(defcustom ogent-codex-oauth-auth-file nil
  "Optional path to Codex auth.json.
When nil, use $CODEX_HOME/auth.json if CODEX_HOME is set, otherwise
~/.codex/auth.json."
  :type '(choice (const :tag "Auto-detect" nil)
                 file)
  :group 'ogent-codex-oauth)

(defun ogent-codex-oauth--auth-file ()
  "Return the Codex auth cache path."
  (expand-file-name
   (or ogent-codex-oauth-auth-file
       (if-let ((codex-home (getenv "CODEX_HOME")))
           (expand-file-name "auth.json" codex-home)
         "~/.codex/auth.json"))))

(defun ogent-codex-oauth--read-auth-file ()
  "Read Codex auth cache as a plist, or return nil.
Malformed or missing files are treated as unauthenticated state."
  (let ((file (ogent-codex-oauth--auth-file)))
    (when (file-readable-p file)
      (condition-case nil
          (let ((json-object-type 'plist)
                (json-array-type 'list)
                (json-key-type 'keyword)
                (coding-system-for-read 'utf-8-auto))
            (with-temp-buffer
              (insert-file-contents-literally file)
              (json-read)))
        (error nil)))))

(defun ogent-codex-oauth-get-api-key ()
  "Return the OpenAI API key cached by Codex, or nil."
  (when-let ((key (plist-get (ogent-codex-oauth--read-auth-file) :OPENAI_API_KEY)))
    (unless (string-empty-p key)
      key)))

(defun ogent-codex-oauth-authenticated-p ()
  "Return non-nil when Codex has a reusable API key cached."
  (ogent-codex-oauth-get-api-key))

(defun ogent-codex-oauth-mode ()
  "Return the Codex auth mode string, or nil."
  (plist-get (ogent-codex-oauth--read-auth-file) :auth_mode))

(defun ogent-codex-oauth--start-process (buffer-name args)
  "Start Codex with ARGS in BUFFER-NAME and return the process."
  (let ((buffer (get-buffer-create buffer-name))
        (inhibit-read-only t))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "$ %s %s\n\n"
                      ogent-codex-oauth-codex-executable
                      (string-join args " "))))
    (let ((proc (apply #'start-process
                       "ogent-codex-login"
                       buffer
                       ogent-codex-oauth-codex-executable
                       args)))
      (set-process-query-on-exit-flag proc nil)
      (pop-to-buffer buffer)
      proc)))

;;;###autoload
(defun ogent-codex-login (&optional device-auth)
  "Start Codex ChatGPT OAuth login.
With DEVICE-AUTH non-nil, use Codex's device authorization flow."
  (interactive "P")
  (ogent-codex-oauth--start-process
   "*ogent Codex login*"
   (if device-auth
       '("login" "--device-auth")
     '("login"))))

;;;###autoload
(defun ogent-codex-login-device ()
  "Start Codex login with device authorization."
  (interactive)
  (ogent-codex-login t))

;;;###autoload
(defun ogent-codex-status ()
  "Show Codex authentication status."
  (interactive)
  (ogent-codex-oauth--start-process
   "*ogent Codex status*"
   '("login" "status")))

;;;###autoload
(defun ogent-codex-logout ()
  "Start Codex logout."
  (interactive)
  (ogent-codex-oauth--start-process
   "*ogent Codex logout*"
   '("logout")))

(provide 'ogent-codex-oauth)

;;; ogent-codex-oauth.el ends here
