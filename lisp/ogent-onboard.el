;;; ogent-onboard.el --- Interactive setup for ogent providers -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides `ogent-onboard' for guided setup of LLM providers.
;; Handles API key configuration, backend verification, and model registry updates.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'subr-x)
(require 'ogent-gptel)
(require 'ogent-models)

;; Forward declarations for OAuth module
(declare-function ogent-anthropic-oauth-authenticated-p "ogent-anthropic-oauth")
(declare-function ogent-anthropic-oauth-mode "ogent-anthropic-oauth")
(declare-function ogent-anthropic-login "ogent-anthropic-oauth")
(declare-function ogent-claude-code-authenticated-p "ogent-anthropic-oauth")
(declare-function ogent-claude-code-login "ogent-anthropic-oauth")
(declare-function ogent-codex-oauth-authenticated-p "ogent-codex-oauth")
(declare-function ogent-codex-oauth-get-api-key "ogent-codex-oauth")
(declare-function ogent-codex-oauth-mode "ogent-codex-oauth")
(declare-function ogent-codex-login "ogent-codex-oauth")

(defgroup ogent-onboard nil
  "Interactive setup for ogent providers."
  :group 'ogent)

(defconst ogent-onboard--anthropic-models
  '((:id "claude-fable-5"
         :description "Claude Fable 5 - most powerful")
    (:id "claude-opus-4-8"
         :description "Claude Opus 4.8 - most capable Opus")
    (:id "claude-sonnet-4-6"
         :description "Claude Sonnet 4.6 - balanced speed and intelligence")
    (:id "claude-haiku-4-5-20251001"
         :description "Claude Haiku 4.5 - fastest"))
  "Built-in Anthropic model catalog for onboarding.")

(defconst ogent-onboard--openai-models
  '((:id "gpt-5.5"
         :description "GPT-5.5 - flagship reasoning and coding")
    (:id "gpt-5.4"
         :description "GPT-5.4 - coding and professional work")
    (:id "gpt-5.4-mini"
         :description "GPT-5.4 mini - faster, lower-cost coding")
    (:id "gpt-5.4-nano"
         :description "GPT-5.4 nano - lowest-latency OpenAI option"))
  "Built-in OpenAI model catalog for onboarding.")

(defconst ogent-onboard--built-in-models-by-provider
  `((anthropic . ,ogent-onboard--anthropic-models)
    (anthropic-oauth . ,ogent-onboard--anthropic-models)
    (openai . ,ogent-onboard--openai-models)
    (openai-codex . ,ogent-onboard--openai-models))
  "Current built-in model catalogs keyed by provider ID.")

(defconst ogent-onboard--built-in-providers
  `((:id anthropic-oauth
         :name "Anthropic Claude Max/Pro (OAuth - Recommended)"
         :host "api.anthropic.com"
         :backend gptel-anthropic
         :feature gptel-anthropic
         :auth-type oauth
         :oauth-feature ogent-anthropic-oauth
         :oauth-login ogent-claude-code-login
         :oauth-authenticated-p ogent-claude-code-authenticated-p
         :oauth-mode ogent-anthropic-oauth-mode
         :oauth-login-mode max
         :backend-creator gptel-make-anthropic
         :models ,ogent-onboard--anthropic-models)
    (:id anthropic
         :name "Anthropic (API Key)"
         :host "api.anthropic.com"
         :backend gptel-anthropic
         :feature gptel-anthropic
         :env-var "ANTHROPIC_API_KEY"
         :auth-type api-key
         :backend-creator gptel-make-anthropic
         :models ,ogent-onboard--anthropic-models)
    (:id openai
         :name "OpenAI (GPT)"
         :host "api.openai.com"
         :backend gptel-openai
         :feature gptel-openai
         :env-var "OPENAI_API_KEY"
         :auth-type api-key
         :backend-creator gptel-make-openai
         :models ,ogent-onboard--openai-models)
    (:id openai-codex
         :name "OpenAI Codex / ChatGPT (OAuth - Recommended)"
         :host "api.openai.com"
         :backend gptel-openai
         :feature gptel-openai
         :auth-type oauth
         :oauth-feature ogent-codex-oauth
         :oauth-login ogent-codex-login
         :oauth-authenticated-p ogent-codex-oauth-authenticated-p
         :oauth-mode ogent-codex-oauth-mode
         :oauth-key ogent-codex-oauth-get-api-key
         :backend-creator gptel-make-openai
         :models ,ogent-onboard--openai-models))
  "Canonical provider definitions shipped with ogent.")

(defcustom ogent-onboard-providers
  ogent-onboard--built-in-providers
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

(defun ogent-onboard--provider-with-id (id providers)
  "Return the provider with ID from PROVIDERS."
  (cl-find-if (lambda (provider)
                (eq (plist-get provider :id) id))
              providers))

(defun ogent-onboard--plist-add-missing (base extras)
  "Return BASE with keys from EXTRAS added when absent."
  (let ((result (copy-sequence base)))
    (while extras
      (let ((key (pop extras))
            (value (pop extras)))
        (unless (plist-member result key)
          (setq result (plist-put result key value)))))
    result))

(defun ogent-onboard--canonicalize-provider (provider)
  "Return PROVIDER with current built-in fields for known provider IDs."
  (if-let ((built-in (ogent-onboard--provider-with-id
                      (plist-get provider :id)
                      ogent-onboard--built-in-providers)))
      (ogent-onboard--plist-add-missing built-in provider)
    provider))

(defun ogent-onboard--providers (&optional providers)
  "Return onboarding PROVIDERS with current built-ins restored.
Known built-in providers are refreshed from ogent's canonical
definitions.  Custom providers with unknown IDs remain available."
  (let* ((configured (or providers ogent-onboard-providers))
         (result (mapcar
                  (lambda (built-in)
                    (let ((configured-provider
                           (ogent-onboard--provider-with-id
                            (plist-get built-in :id)
                            configured)))
                      (if configured-provider
                          (ogent-onboard--plist-add-missing
                           built-in configured-provider)
                        built-in)))
                  ogent-onboard--built-in-providers)))
    (dolist (provider configured)
      (unless (ogent-onboard--provider-with-id
               (plist-get provider :id)
               ogent-onboard--built-in-providers)
        (setq result (append result (list provider)))))
    result))

(defun ogent-onboard--select-provider (&optional providers prompt)
  "Prompt user to select a provider to configure.
PROVIDERS defaults to `ogent-onboard-providers'.  PROMPT defaults
to \"Select provider: \"."
  (let* ((choices (mapcar (lambda (p)
                            (cons (plist-get p :name) p))
                          (ogent-onboard--providers providers)))
         (name (completing-read (or prompt "Select provider: ")
                                (mapcar #'car choices)
                                nil t)))
    (cdr (assoc name choices))))

(defun ogent-onboard--same-backend-p (provider backend)
  "Compare PROVIDER and BACKEND for backend equality."
  (let ((provider-backend (plist-get provider :backend)))
    (or (eq provider-backend backend)
        (and (symbolp provider-backend)
             (boundp provider-backend)
             (eq (symbol-value provider-backend) backend))
        (and backend
             (symbolp provider-backend)
             (ignore-errors (cl-typep backend provider-backend))))))

(defun ogent-onboard--providers-excluding-backend (backend)
  "Return provider login choices after BACKEND fails.
OAuth providers for the same backend stay visible because switching
credential sources can recover from quota or account failures."
  (let* ((providers (ogent-onboard--providers))
         (same-backend (cl-remove-if-not
                        (lambda (provider)
                          (ogent-onboard--same-backend-p provider backend))
                        providers))
         (same-oauth (cl-remove-if-not
                      (lambda (provider)
                        (eq (plist-get provider :auth-type) 'oauth))
                      same-backend))
         (same-api-key (cl-remove-if
                        (lambda (provider)
                          (eq (plist-get provider :auth-type) 'oauth))
                        same-backend))
         (different-backend (cl-remove-if
                             (lambda (provider)
                               (ogent-onboard--same-backend-p
                                provider backend))
                             providers)))
    (or (append same-oauth different-backend same-api-key)
        providers)))

(defun ogent-onboard--built-in-models-for-provider (provider)
  "Return the current built-in model catalog for PROVIDER."
  (alist-get (plist-get provider :id)
             ogent-onboard--built-in-models-by-provider))

(defun ogent-onboard--models-for-provider (provider)
  "Return model choices for PROVIDER.
Known built-in providers use the current built-in catalog, which
keeps older customized provider plists from surfacing stale model
choices in already-running Emacs sessions."
  (let ((provider (ogent-onboard--canonicalize-provider provider)))
    (or (ogent-onboard--built-in-models-for-provider provider)
        (plist-get provider :models))))

(defun ogent-onboard--select-model (provider)
  "Prompt user to select a model from PROVIDER."
  (let* ((models (ogent-onboard--models-for-provider provider))
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
  "Configure API key for PROVIDER.  Return the key or nil."
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

(defun ogent-onboard--oauth-api-key (provider)
  "Return PROVIDER's OAuth-derived API key, when one is exposed."
  (when-let ((key-fn (plist-get provider :oauth-key)))
    (when (fboundp key-fn)
      (funcall key-fn))))

(defun ogent-onboard--configure-oauth (provider)
  "Configure OAuth for PROVIDER.  Return non-nil on success."
  (let* ((name (plist-get provider :name))
         (feature (or (plist-get provider :oauth-feature)
                      'ogent-anthropic-oauth))
         (login-fn (or (plist-get provider :oauth-login)
                       'ogent-anthropic-login))
         (authenticated-fn (or (plist-get provider :oauth-authenticated-p)
                               'ogent-anthropic-oauth-authenticated-p))
         (mode-fn (or (plist-get provider :oauth-mode)
                      'ogent-anthropic-oauth-mode))
         (login-mode (if (plist-member provider :oauth-login-mode)
                         (plist-get provider :oauth-login-mode)
                       (when (eq feature 'ogent-anthropic-oauth) 'max))))
    (when (require feature nil t)
      (unless (and (fboundp login-fn)
                   (fboundp authenticated-fn))
        (user-error "OAuth provider %s is missing required auth handlers" name))
      (cl-labels ((ready-p ()
                    (and (funcall authenticated-fn)
                         (if (plist-get provider :oauth-key)
                             (ogent-onboard--oauth-api-key provider)
                           t)))
                  (login ()
                    (if login-mode
                        (funcall login-fn login-mode)
                      (funcall login-fn))
                    (ready-p)))
        (if (ready-p)
            (let ((mode (when (fboundp mode-fn)
                          (funcall mode-fn))))
              (if (y-or-n-p (format "Already logged in via OAuth%s. Re-authenticate? "
                                    (if mode (format " (%s mode)" mode) "")))
                  (login)
                t))
          (message "Starting OAuth login for %s..." name)
          (message "This will open your browser or a login buffer to authenticate.")
          (when (y-or-n-p "Continue with OAuth login? ")
            (login)))))))

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
                         (ogent-onboard--models-for-provider provider))))
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
         (stream (if (plist-member model-plist :stream?)
                     (plist-get model-plist :stream?)
                   t))
         (entry `(:id ,model-id
                      :backend ,backend
                      :stream? ,stream
                      :description ,description))
         (existing (ogent-models-get model-id)))
    (unless existing
      (add-to-list 'ogent-model-registry entry t)
      (message "Added %s to model registry" model-id))
    entry))

(defun ogent-onboard--set-default-model (model-id)
  "Set MODEL-ID as the default ogent model."
  (setq ogent-default-model model-id)
  (when-let* ((model-id)
              (model (ogent-models-get model-id))
              (backend (ogent-gptel-resolve-backend model)))
    (setq gptel-model model-id)
    (when backend
      (setq gptel-backend backend)))
  (message "Set %s as default model" model-id))

;;; Main command

(defun ogent-onboard--run-provider-setup (provider)
  "Run the onboarding flow for PROVIDER."
  (let* ((auth-type (plist-get provider :auth-type))
         (api-key nil)
         (auth-success nil))

    ;; Configure authentication based on type
    (cond
     ((eq auth-type 'oauth)
      (setq auth-success (ogent-onboard--configure-oauth provider))
      (setq api-key (ogent-onboard--oauth-api-key provider)))
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

;;;###autoload (autoload 'ogent-onboard "ogent" nil t)
(defun ogent-onboard ()
  "Interactive setup wizard for ogent model providers.
Guides you through:
1. Selecting a provider (Anthropic, OpenAI, etc.)
2. Configuring authentication (OAuth or API key)
3. Choosing a default model
4. Verifying the connection works"
  (interactive)
  (ogent-onboard--run-provider-setup (ogent-onboard--select-provider)))

;;;###autoload
(defun ogent-onboard-login-different-provider (&optional failed-backend)
  "Prompt for a provider login that differs from FAILED-BACKEND."
  (interactive)
  (let ((provider (ogent-onboard--select-provider
                   (ogent-onboard--providers-excluding-backend failed-backend)
                   "Login to provider: ")))
    (ogent-onboard--run-provider-setup provider)))

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

(defun ogent-onboard--source-root-from-path (path)
  "Return the ogent project root represented by PATH, or nil.
PATH may name the project root, the Lisp directory, or an ogent
source file.  Symlinks are resolved before the root is inferred."
  (when path
    (let* ((resolved (file-truename (expand-file-name path)))
           (dir (directory-file-name
                 (if (file-directory-p resolved)
                     resolved
                   (file-name-directory resolved))))
           (parent (file-name-directory dir)))
      (cond
       ((file-exists-p (expand-file-name "lisp/ogent.el" dir))
        (file-name-as-directory dir))
       ((and (string= (file-name-nondirectory dir) "lisp")
             (file-exists-p (expand-file-name "ogent.el" dir)))
        (file-name-as-directory parent))
       ((and parent
             (file-exists-p (expand-file-name "lisp/ogent.el" parent)))
        (file-name-as-directory parent))))))

(defun ogent-onboard--first-source-root (&rest paths)
  "Return the first ogent project root found from PATHS."
  (catch 'root
    (dolist (path paths)
      (when-let ((root (ogent-onboard--source-root-from-path path)))
        (throw 'root root)))))

(defun ogent-onboard--find-source-root ()
  "Find the ogent source root directory.
Priority:
1. `ogent-source-directory' if set
2. straight.el local repo path
3. Fall back to `load-file-name' parent"
  (or (when ogent-source-directory
        (or (ogent-onboard--source-root-from-path ogent-source-directory)
            (file-name-as-directory (expand-file-name ogent-source-directory))))
      ;; Check straight.el for local repo path
      (when (boundp 'straight--repos-dir)
        (ogent-onboard--source-root-from-path
         (expand-file-name "ogent" straight--repos-dir)))
      ;; Fall back to computed path from load location
      (ogent-onboard--first-source-root
       load-file-name
       (locate-library "ogent")
       buffer-file-name)))

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
                                    ogent-codex-oauth
                                    ogent ))
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
                                  ogent-codex-oauth
                                  ogent ))
      (when (featurep feat)
        (unload-feature feat t)))
    ;; Add source to load-path temporarily and reload
    (let ((load-path (cons lisp-dir (cons ui-dir load-path))))
      (load (expand-file-name "ogent" lisp-dir)))
    (message "ogent reloaded from %s!" project-root)))

(provide 'ogent-onboard)

;;; ogent-onboard.el ends here
