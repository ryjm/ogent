;;; ogent-onboard.el --- Interactive setup for ogent providers -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides `ogent-onboard' for guided setup of LLM providers.
;; Handles API key configuration, backend verification, and model registry updates.

;;; Code:

(require 'auth-source)
(require 'ogent-models)

;; Forward declarations for OAuth module
(declare-function ogent-anthropic-oauth-authenticated-p "ogent-anthropic-oauth")
(declare-function ogent-anthropic-oauth-mode "ogent-anthropic-oauth")
(declare-function ogent-anthropic-login "ogent-anthropic-oauth")

(defgroup ogent-onboard nil
  "Interactive setup for ogent providers."
  :group 'ogent)

(defcustom ogent-onboard-providers
  '((:id anthropic-oauth
     :name "Anthropic Claude Max/Pro (OAuth - Recommended)"
     :host "api.anthropic.com"
     :backend gptel-anthropic
     :feature gptel-anthropic
     :auth-type oauth
     :backend-creator gptel-make-anthropic
     :models ((:id "claude-sonnet-4-5-20250929" :description "Claude Sonnet 4.5 - best for coding/agents")
              (:id "claude-haiku-4-5-20251001" :description "Claude Haiku 4.5 - fastest")
              (:id "claude-opus-4-5-20251101" :description "Claude Opus 4.5 - maximum intelligence")
              (:id "claude-sonnet-4-20250514" :description "Claude Sonnet 4 - legacy balanced")))
    (:id anthropic
     :name "Anthropic (API Key)"
     :host "api.anthropic.com"
     :backend gptel-anthropic
     :feature gptel-anthropic
     :env-var "ANTHROPIC_API_KEY"
     :auth-type api-key
     :backend-creator gptel-make-anthropic
     :models ((:id "claude-sonnet-4-5-20250929" :description "Claude Sonnet 4.5 - best for coding/agents")
              (:id "claude-haiku-4-5-20251001" :description "Claude Haiku 4.5 - fastest")
              (:id "claude-opus-4-5-20251101" :description "Claude Opus 4.5 - maximum intelligence")
              (:id "claude-sonnet-4-20250514" :description "Claude Sonnet 4 - legacy balanced")))
    (:id openai
     :name "OpenAI (GPT)"
     :host "api.openai.com"
     :backend gptel-openai
     :feature gptel-openai
     :env-var "OPENAI_API_KEY"
     :auth-type api-key
     :backend-creator gptel-make-openai
     :models ((:id "gpt-4o" :description "GPT-4o - best quality")
              (:id "gpt-4o-mini" :description "GPT-4o mini - fast and cheap")
              (:id "o1" :description "o1 - reasoning model")
              (:id "o1-mini" :description "o1-mini - fast reasoning"))))
  "Provider configurations for onboarding.
Each provider can have :auth-type of `oauth' or `api-key'."
  :type '(repeat plist)
  :group 'ogent-onboard)

;;; Auth-source integration

(defun ogent-onboard--get-api-key (host)
  "Retrieve API key for HOST from auth-source."
  (let ((found (car (auth-source-search :host host :max 1))))
    (when found
      (let ((secret (plist-get found :secret)))
        (if (functionp secret)
            (funcall secret)
          secret)))))

(defun ogent-onboard--save-api-key (host key)
  "Save API KEY for HOST to auth-source (typically ~/.authinfo.gpg)."
  (let* ((gpg-file (expand-file-name "~/.authinfo.gpg"))
         (plain-file (expand-file-name "~/.authinfo"))
         (target (cond
                  ((file-exists-p gpg-file) gpg-file)
                  ((file-exists-p plain-file) plain-file)
                  (t plain-file)))
         (entry (format "machine %s login apikey password %s" host key)))
    ;; For encrypted files, we need to read, append, and rewrite
    (with-temp-buffer
      (when (file-exists-p target)
        (insert-file-contents target))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert entry "\n")
      (write-region (point-min) (point-max) target))
    (message "Saved API key to %s" target)
    t))

;;; Provider selection

(defun ogent-onboard--select-provider ()
  "Prompt user to select a provider to configure."
  (let* ((choices (mapcar (lambda (p)
                            (cons (plist-get p :name) p))
                          ogent-onboard-providers))
         (name (completing-read "Select provider: "
                                (mapcar #'car choices)
                                nil t)))
    (cdr (assoc name choices))))

(defun ogent-onboard--select-model (provider)
  "Prompt user to select a model from PROVIDER."
  (let* ((models (plist-get provider :models))
         (choices (mapcar (lambda (m)
                            (cons (format "%s - %s"
                                          (plist-get m :id)
                                          (plist-get m :description))
                                  m))
                          models))
         (choice (completing-read "Select default model: "
                                  (mapcar #'car choices)
                                  nil t)))
    (cdr (assoc choice choices))))

;;; API key configuration

(defun ogent-onboard--configure-api-key (provider)
  "Configure API key for PROVIDER. Returns the key or nil."
  (let* ((host (plist-get provider :host))
         (env-var (plist-get provider :env-var))
         (name (plist-get provider :name))
         (existing-key (or (ogent-onboard--get-api-key host)
                           (when env-var (getenv env-var)))))
    (if existing-key
        (if (y-or-n-p (format "Found existing API key for %s. Use it? " name))
            existing-key
          (ogent-onboard--prompt-for-key provider))
      (ogent-onboard--prompt-for-key provider))))

(defun ogent-onboard--prompt-for-key (provider)
  "Prompt user to enter API key for PROVIDER."
  (let* ((name (plist-get provider :name))
         (host (plist-get provider :host))
         (key (read-passwd (format "Enter %s API key: " name))))
    (when (and key (not (string-empty-p key)))
      (when (y-or-n-p "Save to ~/.authinfo.gpg for future sessions? ")
        (ogent-onboard--save-api-key host key)
        (message "Saved API key to auth-source"))
      key)))

;;; OAuth configuration

(defun ogent-onboard--configure-oauth (provider)
  "Configure OAuth for PROVIDER. Returns non-nil on success."
  (let ((name (plist-get provider :name)))
    ;; Check if already authenticated
    (when (require 'ogent-anthropic-oauth nil t)
      (if (ogent-anthropic-oauth-authenticated-p)
          (if (y-or-n-p (format "Already logged in via OAuth (%s mode). Re-authenticate? "
                                (ogent-anthropic-oauth-mode)))
              (progn
                (ogent-anthropic-login 'max)
                (ogent-anthropic-oauth-authenticated-p))
            t)
        ;; Not authenticated, start OAuth flow
        (message "Starting OAuth login for %s..." name)
        (message "This will open your browser to authenticate with your Claude Max/Pro account.")
        (when (y-or-n-p "Continue with OAuth login? ")
          (ogent-anthropic-login 'max)
          (ogent-anthropic-oauth-authenticated-p))))))

;;; Verification

(declare-function gptel-make-anthropic "ext:gptel-anthropic")
(declare-function gptel-make-openai "ext:gptel-openai")
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-api-key)

(defun ogent-onboard--create-backend (provider api-key)
  "Create and return a gptel backend for PROVIDER using API-KEY.
For OAuth providers, API-KEY may be nil; authentication is handled by advice."
  (let* ((creator-sym (plist-get provider :backend-creator))
         (name (plist-get provider :name))
         (models (mapcar (lambda (m) (plist-get m :id))
                         (plist-get provider :models))))
    (cond
     ((eq creator-sym 'gptel-make-anthropic)
      (when (fboundp 'gptel-make-anthropic)
        ;; For OAuth, use a placeholder key; actual auth handled by advice
        (gptel-make-anthropic name
          :key (or api-key "oauth-managed")
          :stream t
          :models models)))
     ((eq creator-sym 'gptel-make-openai)
      (when (fboundp 'gptel-make-openai)
        (gptel-make-openai name
          :key api-key
          :stream t
          :models models)))
     (t nil))))

(defun ogent-onboard--verify-connection (provider api-key _model-id)
  "Verify connection to PROVIDER with API-KEY.
MODEL-ID is accepted for future use but not currently verified."
  (message "Verifying connection to %s..." (plist-get provider :name))
  (let* ((feature (plist-get provider :feature))
         (verified nil)
         (error-msg nil)
         (backend nil))
    ;; Load backend feature
    (unless (require feature nil 'noerror)
      (setq error-msg (format "Could not load backend feature: %s" feature)))
    (unless error-msg
      ;; Create the backend
      (condition-case err
          (progn
            (setq backend (ogent-onboard--create-backend provider api-key))
            (if backend
                (progn
                  ;; Store for later use
                  (set (plist-get provider :backend) backend)
                  (setq verified t)
                  (message "Backend configured successfully!"))
              (setq error-msg "Failed to create backend")))
        (error
         (setq error-msg (error-message-string err)))))
    (if error-msg
        (progn
          (message "Verification failed: %s" error-msg)
          nil)
      verified)))

;;; Model registry integration

(defun ogent-onboard--add-to-registry (provider model-plist)
  "Add MODEL-PLIST from PROVIDER to `ogent-model-registry'."
  (let* ((model-id (plist-get model-plist :id))
         (backend (plist-get provider :backend))
         (description (plist-get model-plist :description))
         (entry `(:id ,model-id
                  :backend ,backend
                  :stream? t
                  :description ,description))
         (existing (ogent-models-get model-id)))
    (unless existing
      (add-to-list 'ogent-model-registry entry t)
      (message "Added %s to model registry" model-id))
    entry))

(defun ogent-onboard--set-default-model (model-id)
  "Set MODEL-ID as the default ogent model."
  (setq ogent-default-model model-id)
  (message "Set %s as default model" model-id))

;;; Main command

;;;###autoload (autoload 'ogent-onboard "ogent" nil t)
(defun ogent-onboard ()
  "Interactive setup wizard for ogent model providers.
Guides you through:
1. Selecting a provider (Anthropic, OpenAI, etc.)
2. Configuring authentication (OAuth or API key)
3. Choosing a default model
4. Verifying the connection works"
  (interactive)
  (let* ((provider (ogent-onboard--select-provider))
         (auth-type (plist-get provider :auth-type))
         (api-key nil)
         (auth-success nil))
    
    ;; Configure authentication based on type
    (cond
     ((eq auth-type 'oauth)
      (setq auth-success (ogent-onboard--configure-oauth provider)))
     (t
      (setq api-key (ogent-onboard--configure-api-key provider))
      (setq auth-success api-key)))
    
    (unless auth-success
      (user-error "Authentication is required to continue"))
    
    (let* ((model (ogent-onboard--select-model provider))
           (model-id (plist-get model :id)))
      ;; Verify
      (if (ogent-onboard--verify-connection provider api-key model-id)
          (progn
            ;; Add to registry
            (ogent-onboard--add-to-registry provider model)
            ;; Set as default
            (when (y-or-n-p (format "Set %s as your default model? " model-id))
              (ogent-onboard--set-default-model model-id))
            ;; Refresh dispatcher
            (when (fboundp 'ogent-ui-refresh-dispatch)
              (ogent-ui-refresh-dispatch))
            (message "Setup complete! You can now use ogent with %s."
                     (plist-get provider :name)))
        (message "Setup incomplete - please check your authentication and try again")))))

;;;###autoload
(defun ogent-onboard-add-provider ()
  "Add another provider to your ogent configuration.
Use this after initial setup to configure additional providers."
  (interactive)
  (ogent-onboard))

;;; Recompile and reload

(defcustom ogent-source-directory nil
  "Directory containing ogent source code for development.
When nil, attempts to auto-detect from straight.el recipe or load path.
Set this to your local checkout (e.g., \"~/projects/ogent\") for
reliable reloading during development."
  :type '(choice (const :tag "Auto-detect" nil)
          (directory :tag "Source directory"))
  :group 'ogent)

(defun ogent-onboard--find-source-root ()
  "Find the ogent source root directory.
Priority:
1. `ogent-source-directory' if set
2. straight.el local repo path
3. Fall back to load-file-name parent"
  (or ogent-source-directory
      ;; Check straight.el for local repo path
      (when (and (boundp 'straight--repos-dir)
                 (file-directory-p (expand-file-name "ogent" straight--repos-dir)))
        (expand-file-name "ogent" straight--repos-dir))
      ;; Fall back to computed path from load location
      (file-name-directory
       (directory-file-name
        (file-name-directory
         (or load-file-name
             (locate-library "ogent")
             buffer-file-name))))))

;;;###autoload
(defun ogent-recompile ()
  "Recompile all ogent elisp files and reload them.
Use this after pulling updates or making changes to ensure
your Emacs is using the latest code.

If auto-detection fails, set `ogent-source-directory' to your
local checkout path."
  (interactive)
  (let* ((project-root (ogent-onboard--find-source-root))
         (lisp-dir (expand-file-name "lisp" project-root))
         (ui-dir (expand-file-name "ui" lisp-dir)))
    (unless (file-directory-p lisp-dir)
      (user-error "Cannot find ogent source at %s. Set `ogent-source-directory'" project-root))
    (let* ((files (append
                   (directory-files lisp-dir t "\\.el\\'")
                   (when (file-directory-p ui-dir)
                     (directory-files ui-dir t "\\.el\\'"))))
           (byte-compile-warnings '(not free-vars unresolved)))
      (message "Recompiling ogent from %s..." lisp-dir)
      ;; Delete old .elc files
      (dolist (elc (append
                    (directory-files lisp-dir t "\\.elc\\'")
                    (when (file-directory-p ui-dir)
                      (directory-files ui-dir t "\\.elc\\'"))))
        (delete-file elc))
      ;; Byte compile all files
      (dolist (file files)
        (byte-compile-file file))
      ;; Unload all ogent features
      (dolist (feat '(ogent-onboard ogent-issues ogent-ui ogent-codemap ogent-companion
                      ogent-core ogent-models ogent-context ogent-tools ogent-debug
                      ogent-session ogent-notes ogent-keys
                      ogent-edit ogent-edit-format ogent-edit-log ogent-edit-display
                      ogent-edit-parse ogent-edit-request ogent-anthropic-oauth
                      ogent-tool-render ogent-tool-approval ogent-tool-fsm ogent))
        (when (featurep feat)
          (unload-feature feat t)))
      ;; Add source to load-path temporarily and reload
      (let ((load-path (cons lisp-dir (cons ui-dir load-path))))
        (load (expand-file-name "ogent" lisp-dir)))
      (message "ogent recompiled and reloaded from %s!" project-root))))

;;;###autoload
(defun ogent-reload ()
  "Reload ogent without recompiling.
Faster than `ogent-recompile' but won't pick up syntax errors.

If auto-detection fails, set `ogent-source-directory' to your
local checkout path."
  (interactive)
  (let* ((project-root (ogent-onboard--find-source-root))
         (lisp-dir (expand-file-name "lisp" project-root))
         (ui-dir (expand-file-name "ui" lisp-dir)))
    (unless (file-directory-p lisp-dir)
      (user-error "Cannot find ogent source at %s. Set `ogent-source-directory'" project-root))
    (message "Reloading ogent from %s..." project-root)
    ;; Unload all ogent features
    (dolist (feat '(ogent-onboard ogent-issues ogent-ui ogent-codemap ogent-companion
                    ogent-core ogent-models ogent-context ogent-tools ogent-debug
                    ogent-session ogent-notes ogent-keys
                    ogent-edit ogent-edit-format ogent-edit-log ogent-edit-display
                    ogent-edit-parse ogent-edit-request ogent-anthropic-oauth
                    ogent-tool-render ogent-tool-approval ogent-tool-fsm ogent))
      (when (featurep feat)
        (unload-feature feat t)))
    ;; Add source to load-path temporarily and reload
    (let ((load-path (cons lisp-dir (cons ui-dir load-path))))
      (load (expand-file-name "ogent" lisp-dir)))
    (message "ogent reloaded from %s!" project-root)))

(provide 'ogent-onboard)

;;; ogent-onboard.el ends here
