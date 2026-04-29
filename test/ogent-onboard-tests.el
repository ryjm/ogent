;;; ogent-onboard-tests.el --- Tests for ogent-onboard -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-onboard)

(defvar ogent-onboard-tests--backend nil
  "Backend placeholder for ogent-onboard tests.")

(defvar gptel-backend)
(defvar gptel-model)

(ert-deftest ogent-onboard-providers-defined ()
  "Provider list contains expected entries."
  (should (assq 'anthropic
                (mapcar (lambda (p) (cons (plist-get p :id) p))
                        ogent-onboard-providers)))
  (should (assq 'openai
                (mapcar (lambda (p) (cons (plist-get p :id) p))
                        ogent-onboard-providers))))

(ert-deftest ogent-onboard-provider-has-required-fields ()
  "Each provider has all required fields."
  (dolist (provider ogent-onboard-providers)
    (should (plist-get provider :id))
    (should (plist-get provider :name))
    (should (plist-get provider :host))
    (should (plist-get provider :backend))
    (should (plist-get provider :models))))

(ert-deftest ogent-onboard-providers-excluding-backend-keeps-oauth ()
  "Provider fallback keeps OAuth choices for the failed backend."
  (let* ((ogent-onboard-providers
          '((:id openai
             :name "OpenAI"
             :backend gptel-openai
             :models ((:id "gpt")))
            (:id anthropic
             :name "Anthropic"
             :backend gptel-anthropic
             :models ((:id "claude")))))
         (providers (ogent-onboard--providers-excluding-backend
                     'gptel-openai))
         (ids (mapcar (lambda (provider)
                        (plist-get provider :id))
                      providers)))
    (should (memq 'openai-codex ids))
    (should (memq 'anthropic-oauth ids))
    (should (memq 'anthropic ids))))

(ert-deftest ogent-onboard-provider-fallback-offers-anthropic-oauth ()
  "Anthropic backend failures still offer Anthropic OAuth login."
  (let* ((ogent-onboard-providers
          '((:id anthropic
             :name "Anthropic"
             :backend gptel-anthropic
             :models ((:id "claude-3-5-sonnet-20241022")))))
         (providers (ogent-onboard--providers-excluding-backend
                     'gptel-anthropic))
         (ids (mapcar (lambda (provider)
                        (plist-get provider :id))
                      providers)))
    (should (eq (car ids) 'anthropic-oauth))
    (should (memq 'openai-codex ids))))

(ert-deftest ogent-onboard-login-different-provider-selects-filtered-provider ()
  "Different-provider login runs setup for the filtered provider."
  (let ((selected-providers nil)
        (setup-provider nil))
    (cl-letf (((symbol-function 'ogent-onboard--select-provider)
               (lambda (providers _prompt)
                 (setq selected-providers providers)
                 (car providers)))
              ((symbol-function 'ogent-onboard--run-provider-setup)
               (lambda (provider)
                 (setq setup-provider provider))))
      (let ((ogent-onboard-providers
             '((:id openai
                :name "OpenAI"
                :backend gptel-openai
                :models ((:id "gpt")))
               (:id anthropic
                :name "Anthropic"
                :backend gptel-anthropic
                :models ((:id "claude"))))))
        (ogent-onboard-login-different-provider 'gptel-openai)
        (should (memq 'openai-codex
                      (mapcar (lambda (provider)
                                (plist-get provider :id))
                              selected-providers)))
        (should (eq (plist-get setup-provider :id) 'openai-codex))))))

(ert-deftest ogent-onboard-providers-include-current-models ()
  "Onboarding offers the current model families for each provider."
  (let* ((providers (mapcar (lambda (p) (cons (plist-get p :id) p))
                            ogent-onboard-providers))
         (anthropic (cdr (assq 'anthropic providers)))
         (openai (cdr (assq 'openai providers)))
         (openai-codex (cdr (assq 'openai-codex providers)))
         (anthropic-models (mapcar (lambda (m) (plist-get m :id))
                                   (plist-get anthropic :models)))
         (openai-models (mapcar (lambda (m) (plist-get m :id))
                                (plist-get openai :models)))
         (openai-codex-models (mapcar (lambda (m) (plist-get m :id))
                                      (plist-get openai-codex :models))))
    (dolist (model-id '("claude-opus-4-7"
                        "claude-sonnet-4-6"
                        "claude-haiku-4-5-20251001"))
      (should (member model-id anthropic-models)))
    (should-not (member "claude-sonnet-4-20250514" anthropic-models))
    (dolist (model-id '("gpt-5.5"
                        "gpt-5.4"
                        "gpt-5.4-mini"
                        "gpt-5.4-nano"))
      (should (member model-id openai-models))
      (should (member model-id openai-codex-models)))))

(ert-deftest ogent-onboard-known-provider-models-ignore-stale-plists ()
  "Built-in OpenAI providers use the current catalog at selection time."
  (let* ((provider '(:id openai
                     :name "OpenAI"
                     :backend gptel-openai
                     :models ((:id "gpt-3.5-turbo"
                                    :description "Stale"))))
         (models (ogent-onboard--models-for-provider provider))
         (ids (mapcar (lambda (model)
                        (plist-get model :id))
                      models)))
    (should (equal (car ids) "gpt-5.5"))
    (should (member "gpt-5.4-mini" ids))
    (should-not (member "gpt-3.5-turbo" ids))))

(ert-deftest ogent-onboard-select-model-shows-current-openai-models ()
  "OpenAI model selection presents current built-in choices."
  (let ((provider '(:id openai
                    :name "OpenAI"
                    :backend gptel-openai
                    :models ((:id "gpt-3.5-turbo"
                                   :description "Stale"))))
        (captured-choices nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (setq captured-choices choices)
                 (car choices))))
      (let ((model (ogent-onboard--select-model provider)))
        (should (equal (plist-get model :id) "gpt-5.5"))
        (should (seq-some (lambda (choice)
                            (string-match-p "gpt-5.4-mini" choice))
                          captured-choices))
        (should-not (seq-some (lambda (choice)
                                (string-match-p "gpt-3.5-turbo" choice))
                              captured-choices))))))

(ert-deftest ogent-onboard-known-anthropic-models-ignore-stale-plists ()
  "Built-in Anthropic providers use the current catalog at selection time."
  (let* ((provider '(:id anthropic
                     :name "Anthropic"
                     :backend gptel-anthropic
                     :models ((:id "claude-3-5-sonnet-20241022"
                                    :description "Stale"))))
         (models (ogent-onboard--models-for-provider provider))
         (ids (mapcar (lambda (model)
                        (plist-get model :id))
                      models)))
    (should (equal (car ids) "claude-opus-4-7"))
    (should (member "claude-sonnet-4-6" ids))
    (should (member "claude-haiku-4-5-20251001" ids))
    (should-not (member "claude-3-5-sonnet-20241022" ids))
    (should-not (member "claude-sonnet-4-20250514" ids))))

(ert-deftest ogent-onboard-providers-restore-built-in-oauth ()
  "Canonical providers restore built-in OAuth entries in stale sessions."
  (let* ((ogent-onboard-providers
          '((:id anthropic
             :name "Anthropic"
             :backend gptel-anthropic
             :models ((:id "claude-3-5-sonnet-20241022")))))
         (providers (ogent-onboard--providers))
         (ids (mapcar (lambda (provider)
                        (plist-get provider :id))
                      providers)))
    (should (memq 'anthropic-oauth ids))
    (should (memq 'anthropic ids))
    (should (memq 'openai-codex ids))))

(ert-deftest ogent-onboard-select-provider-shows-anthropic-oauth ()
  "Provider selection shows Anthropic OAuth from canonical built-ins."
  (let ((ogent-onboard-providers
         '((:id anthropic
            :name "Anthropic"
            :backend gptel-anthropic
            :models ((:id "claude-3-5-sonnet-20241022")))))
        (captured-choices nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (setq captured-choices choices)
                 "Anthropic Claude Max/Pro (OAuth - Recommended)")))
      (let ((provider (ogent-onboard--select-provider)))
        (should (eq (plist-get provider :id) 'anthropic-oauth))
        (should (member "Anthropic Claude Max/Pro (OAuth - Recommended)"
                        captured-choices))))))

(ert-deftest ogent-onboard-add-to-registry ()
  "Adding model to registry works correctly."
  (let ((ogent-model-registry '((:id "existing" :backend foo)))
        (provider '(:id anthropic :backend gptel-anthropic))
        (model '(:id "test-model" :description "Test")))
    (ogent-onboard--add-to-registry provider model)
    (should (ogent-models-get "test-model"))
    (should (eq (plist-get (ogent-models-get "test-model") :backend)
                'gptel-anthropic))))

(ert-deftest ogent-onboard-add-to-registry-preserves-stream-metadata ()
  "Adding model to registry preserves explicit :stream? metadata."
  (let ((ogent-model-registry nil)
        (provider '(:id openai :backend gptel-openai))
        (model '(:id "gpt-5.5-pro"
                 :stream? nil
                 :description "Non-streaming model")))
    (let ((entry (ogent-onboard--add-to-registry provider model)))
      (should (equal (plist-get entry :id) "gpt-5.5-pro"))
      (should-not (plist-get entry :stream?))
      (should-not (plist-get (ogent-models-get "gpt-5.5-pro") :stream?)))))

(ert-deftest ogent-onboard-set-default-model ()
  "Setting default model updates ogent-default-model."
  (let ((ogent-default-model nil)
        (gptel-model nil)
        (gptel-backend nil))
    (ogent-onboard--set-default-model "claude-sonnet-4-20250514")
    (should (equal ogent-default-model "claude-sonnet-4-20250514"))
    (should (equal gptel-model "claude-sonnet-4-20250514"))))

(ert-deftest ogent-onboard-set-default-model-updates-active-gptel ()
  "Setting a known default model also updates active gptel bindings."
  (let ((ogent-default-model "old-model")
        (ogent-model-registry
         '((:id "fresh-model" :backend ogent-onboard-tests--backend)))
        (ogent-onboard-tests--backend 'fresh-backend)
        (gptel-model "old-model")
        (gptel-backend 'old-backend))
    (ogent-onboard--set-default-model "fresh-model")
    (should (equal ogent-default-model "fresh-model"))
    (should (equal gptel-model "fresh-model"))
    (should (eq gptel-backend 'fresh-backend))))

(ert-deftest ogent-onboard-create-backend-anthropic-placeholder ()
  "Anthropic backend uses oauth placeholder when key is nil."
  (let* ((provider '(:name "Anthropic"
                    :backend-creator gptel-make-anthropic
                    :models ((:id "m1") (:id "m2"))))
         (captured nil))
    (cl-letf (((symbol-function 'gptel-make-anthropic)
               (lambda (name &rest args)
                 (setq captured (list name args))
                 'backend)))
      (should (eq (ogent-onboard--create-backend provider nil) 'backend))
      (should (equal (car captured) "Anthropic"))
      (should (equal (plist-get (cadr captured) :key) "oauth-managed"))
      (should (equal (plist-get (cadr captured) :models) '("m1" "m2"))))))

(ert-deftest ogent-onboard-create-backend-openai-key ()
  "OpenAI backend passes API key to gptel-make-openai."
  (let* ((provider '(:name "OpenAI"
                    :id openai
                    :backend-creator gptel-make-openai
                    :models ((:id "o1"))))
         (captured nil))
    (cl-letf (((symbol-function 'gptel-make-openai)
               (lambda (name &rest args)
                 (setq captured (list name args))
                 'backend)))
      (should (eq (ogent-onboard--create-backend provider "secret") 'backend))
      (should (equal (car captured) "OpenAI"))
      (should (equal (plist-get (cadr captured) :key) "secret"))
      (should (equal (plist-get (cadr captured) :models)
                     '("gpt-5.5"
                       "gpt-5.4"
                       "gpt-5.4-mini"
                       "gpt-5.4-nano"))))))

(ert-deftest ogent-onboard-verify-connection-success ()
  "Verify connection sets backend variable on success."
  (let ((ogent-onboard-tests--backend nil)
        (provider '(:name "Test"
                   :feature test-feature
                   :backend ogent-onboard-tests--backend)))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'ogent-onboard--create-backend)
               (lambda (&rest _) 'backend)))
      (should (ogent-onboard--verify-connection provider "key" "m1"))
      (should (eq ogent-onboard-tests--backend 'backend)))))

(ert-deftest ogent-onboard-verify-connection-require-fails ()
  "Verification fails when backend feature cannot be required."
  (let ((ogent-onboard-tests--backend nil)
        (provider '(:name "Test"
                   :feature missing-feature
                   :backend ogent-onboard-tests--backend)))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
      (should-not (ogent-onboard--verify-connection provider "key" "m1"))
      (should (null ogent-onboard-tests--backend)))))

(ert-deftest ogent-onboard-verify-connection-backend-error ()
  "Verification fails when backend creation errors."
  (let ((ogent-onboard-tests--backend nil)
        (provider '(:name "Test"
                   :feature test-feature
                   :backend ogent-onboard-tests--backend)))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'ogent-onboard--create-backend)
               (lambda (&rest _) (error "boom"))))
      (should-not (ogent-onboard--verify-connection provider "key" "m1"))
      (should (null ogent-onboard-tests--backend)))))

;;; Interactive function tests (require with-simulated-input)

(ert-deftest ogent-onboard-select-provider-interactive ()
  "Test provider selection with simulated input."
  (ogent-test-with-input "Anthropic (API Key) RET"
			 (let ((provider (ogent-onboard--select-provider)))
			   (should provider)
			   (should (eq (plist-get provider :id) 'anthropic)))))

(ert-deftest ogent-onboard-select-provider-openai ()
  "Test selecting OpenAI provider."
  (ogent-test-with-input "OpenAI RET"
			 (let ((provider (ogent-onboard--select-provider)))
			   (should provider)
			   (should (eq (plist-get provider :id) 'openai)))))

(ert-deftest ogent-onboard-select-model-interactive ()
  "Test model selection with simulated input."
  (let ((provider (car ogent-onboard-providers)))
    (ogent-test-with-input "claude-sonnet-4-6 RET"
			   (let ((model (ogent-onboard--select-model provider)))
			     (should model)
			     (should (string-prefix-p "claude-sonnet-4-6" (plist-get model :id)))))))

;;; Auth-source Integration Tests

(ert-deftest ogent-onboard-get-api-key-found ()
  "Test retrieving an API key from auth-source."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _)
               (list (list :host "api.test.com" :secret "sk-test-key")))))
    (should (equal "sk-test-key"
                   (ogent-onboard--get-api-key "api.test.com")))))

(ert-deftest ogent-onboard-get-api-key-found-with-function ()
  "Test retrieving API key when secret is a function."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _)
               (list (list :host "api.test.com"
                           :secret (lambda () "sk-func-key"))))))
    (should (equal "sk-func-key"
                   (ogent-onboard--get-api-key "api.test.com")))))

(ert-deftest ogent-onboard-get-api-key-not-found ()
  "Test retrieving API key when none exists."
  (cl-letf (((symbol-function 'auth-source-search)
             (lambda (&rest _) nil)))
    (should-not (ogent-onboard--get-api-key "api.test.com"))))

;;; Save API Key Tests
;;
;; ogent-onboard--save-api-key uses C-level primitives (file-exists-p,
;; insert-file-contents, write-region, expand-file-name) that cannot be
;; safely mocked with cl-letf under native compilation. We test it by
;; temporarily changing HOME to a temp directory.

(ert-deftest ogent-onboard-save-api-key-writes-correctly ()
  "Test save-api-key writes correct authinfo content."
  (let* ((temp-dir (make-temp-file "ogent-test-home" t))
         (authinfo (expand-file-name ".authinfo" temp-dir))
         (orig-home (getenv "HOME")))
    (unwind-protect
        (progn
          ;; Point HOME to temp dir so ~/.authinfo resolves there
          (setenv "HOME" temp-dir)
          (should (ogent-onboard--save-api-key "api.test.com" "sk-99999"))
          (should (file-exists-p authinfo))
          (let ((content (with-temp-buffer
                           (insert-file-contents authinfo)
                           (buffer-string))))
            (should (string-match-p "machine api.test.com" content))
            (should (string-match-p "login apikey" content))
            (should (string-match-p "password sk-99999" content))))
      ;; Restore HOME
      (setenv "HOME" orig-home)
      (when (file-exists-p authinfo)
        (delete-file authinfo))
      (when (file-directory-p temp-dir)
        (delete-directory temp-dir)))))

(ert-deftest ogent-onboard-save-api-key-appends-to-existing ()
  "Test save-api-key appends to existing authinfo file."
  (let* ((temp-dir (make-temp-file "ogent-test-home" t))
         (authinfo (expand-file-name ".authinfo" temp-dir))
         (orig-home (getenv "HOME")))
    (unwind-protect
        (progn
          (setenv "HOME" temp-dir)
          ;; Create existing authinfo with prior entry
          (with-temp-file authinfo
            (insert "machine existing.host login apikey password old-key\n"))
          (ogent-onboard--save-api-key "api.new.com" "sk-new")
          (let ((content (with-temp-buffer
                           (insert-file-contents authinfo)
                           (buffer-string))))
            ;; Should contain both old and new entries
            (should (string-match-p "machine existing.host" content))
            (should (string-match-p "machine api.new.com" content))
            (should (string-match-p "password sk-new" content))))
      (setenv "HOME" orig-home)
      (when (file-exists-p authinfo)
        (delete-file authinfo))
      (when (file-directory-p temp-dir)
        (delete-directory temp-dir)))))

(ert-deftest ogent-onboard-save-api-key-returns-t ()
  "Test save-api-key returns t on success."
  (let* ((temp-dir (make-temp-file "ogent-test-home" t))
         (orig-home (getenv "HOME")))
    (unwind-protect
        (progn
          (setenv "HOME" temp-dir)
          (should (eq t (ogent-onboard--save-api-key "host" "key"))))
      (setenv "HOME" orig-home)
      (let ((f (expand-file-name ".authinfo" temp-dir)))
        (when (file-exists-p f) (delete-file f)))
      (when (file-directory-p temp-dir)
        (delete-directory temp-dir)))))

;;; Configure API Key Flow Tests

(ert-deftest ogent-onboard-configure-api-key-existing-accepted ()
  "Test configure-api-key uses existing key when user accepts."
  (cl-letf (((symbol-function 'ogent-onboard--get-api-key)
             (lambda (_h) "existing-key"))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
    (let ((provider '(:host "api.test.com" :name "Test" :env-var nil)))
      (should (equal "existing-key"
                     (ogent-onboard--configure-api-key provider))))))

(ert-deftest ogent-onboard-configure-api-key-existing-declined ()
  "Test configure-api-key prompts for new key when user declines existing."
  (cl-letf (((symbol-function 'ogent-onboard--get-api-key)
             (lambda (_h) "existing-key"))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) nil))
            ((symbol-function 'ogent-onboard--prompt-for-key)
             (lambda (_p) "new-key")))
    (let ((provider '(:host "api.test.com" :name "Test" :env-var nil)))
      (should (equal "new-key"
                     (ogent-onboard--configure-api-key provider))))))

(ert-deftest ogent-onboard-configure-api-key-from-env ()
  "Test configure-api-key finds key from environment variable."
  (cl-letf (((symbol-function 'ogent-onboard--get-api-key)
             (lambda (_h) nil))
            ((symbol-function 'getenv)
             (lambda (var) (when (equal var "TEST_KEY") "env-key")))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
    (let ((provider '(:host "api.test.com" :name "Test" :env-var "TEST_KEY")))
      (should (equal "env-key"
                     (ogent-onboard--configure-api-key provider))))))

(ert-deftest ogent-onboard-configure-api-key-none-found ()
  "Test configure-api-key prompts when no existing key."
  (cl-letf (((symbol-function 'ogent-onboard--get-api-key)
             (lambda (_h) nil))
            ((symbol-function 'getenv) (lambda (_v) nil))
            ((symbol-function 'ogent-onboard--prompt-for-key)
             (lambda (_p) "prompted-key")))
    (let ((provider '(:host "api.test.com" :name "Test" :env-var "FOO")))
      (should (equal "prompted-key"
                     (ogent-onboard--configure-api-key provider))))))

;;; OAuth Configuration Tests

(ert-deftest ogent-onboard-configure-oauth-already-authenticated ()
  "Test OAuth skips login when already authenticated and user doesn't re-auth."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
            ((symbol-function 'ogent-anthropic-oauth-authenticated-p)
             (lambda () t))
            ((symbol-function 'ogent-anthropic-oauth-mode)
             (lambda () "max"))
            ((symbol-function 'ogent-anthropic-login)
             (lambda (_mode) t))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
    (let ((provider '(:name "Anthropic OAuth")))
      (should (ogent-onboard--configure-oauth provider)))))

(ert-deftest ogent-onboard-configure-oauth-re-authenticate ()
  "Test OAuth re-authenticates when user wants to."
  (let ((login-called nil))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'ogent-anthropic-oauth-authenticated-p)
               (lambda () t))
              ((symbol-function 'ogent-anthropic-oauth-mode)
               (lambda () "max"))
              ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
              ((symbol-function 'ogent-anthropic-login)
               (lambda (_mode) (setq login-called t))))
      (let ((provider '(:name "Anthropic OAuth")))
        (ogent-onboard--configure-oauth provider)
        (should login-called)))))

(ert-deftest ogent-onboard-configure-oauth-not-authenticated ()
  "Test OAuth starts login flow when not authenticated."
  (let ((login-called nil))
    (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'ogent-anthropic-oauth-authenticated-p)
               (lambda () nil))
              ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
              ((symbol-function 'ogent-anthropic-login)
               (lambda (_mode) (setq login-called t))))
      (let ((provider '(:name "Anthropic OAuth")))
        (ogent-onboard--configure-oauth provider)
        (should login-called)))))

(ert-deftest ogent-onboard-configure-oauth-user-declines ()
  "Test OAuth returns nil when user declines login."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
            ((symbol-function 'ogent-anthropic-oauth-authenticated-p)
             (lambda () nil))
            ((symbol-function 'ogent-anthropic-login)
             (lambda (_mode) t))
            ((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
    (let ((provider '(:name "Anthropic OAuth")))
      (should-not (ogent-onboard--configure-oauth provider)))))

(ert-deftest ogent-onboard-configure-oauth-provider-specific-functions ()
  "OAuth setup uses provider-specific login and status functions."
  (let ((login-called nil)
        (authenticated nil))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &rest _)
                 (eq feature 'ogent-codex-oauth)))
              ((symbol-function 'ogent-codex-oauth-authenticated-p)
               (lambda () authenticated))
              ((symbol-function 'ogent-codex-oauth-mode)
               (lambda () "chatgpt"))
              ((symbol-function 'ogent-codex-login)
               (lambda (&optional _mode)
                 (setq login-called t)
                 (setq authenticated t)))
              ((symbol-function 'y-or-n-p)
               (lambda (_prompt) t)))
      (let ((provider '(:name "OpenAI Codex"
                        :oauth-feature ogent-codex-oauth
                        :oauth-login ogent-codex-login
                        :oauth-authenticated-p ogent-codex-oauth-authenticated-p
                        :oauth-mode ogent-codex-oauth-mode)))
        (should (ogent-onboard--configure-oauth provider))
        (should login-called)))))

;;; Create Backend Tests

(ert-deftest ogent-onboard-create-backend-unknown-creator ()
  "Test create-backend returns nil for unknown backend creator."
  (let ((provider '(:name "Unknown"
                   :backend-creator some-unknown-creator
                   :models ((:id "m1")))))
    (should-not (ogent-onboard--create-backend provider "key"))))

(ert-deftest ogent-onboard-create-backend-anthropic-with-key ()
  "Test Anthropic backend uses provided key."
  (let ((captured-key nil))
    (cl-letf (((symbol-function 'gptel-make-anthropic)
               (lambda (_name &rest args)
                 (setq captured-key (plist-get args :key))
                 'backend)))
      (let ((provider '(:name "Anth"
                        :backend-creator gptel-make-anthropic
                        :models ((:id "m1")))))
        (ogent-onboard--create-backend provider "real-key")
        (should (equal "real-key" captured-key))))))

(ert-deftest ogent-onboard-create-backend-anthropic-stream ()
  "Test Anthropic backend enables streaming."
  (let ((captured-stream nil))
    (cl-letf (((symbol-function 'gptel-make-anthropic)
               (lambda (_name &rest args)
                 (setq captured-stream (plist-get args :stream))
                 'backend)))
      (let ((provider '(:name "Anth"
                        :backend-creator gptel-make-anthropic
                        :models ((:id "m1")))))
        (ogent-onboard--create-backend provider "k")
        (should captured-stream)))))

;;; Verify Connection Tests

(ert-deftest ogent-onboard-verify-connection-nil-backend ()
  "Test verify fails when create-backend returns nil."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
            ((symbol-function 'ogent-onboard--create-backend)
             (lambda (&rest _) nil)))
    (let ((provider '(:name "Test" :feature test-feat :backend test-var)))
      (should-not (ogent-onboard--verify-connection provider "key" "m1")))))

;;; Model Registry Tests

(ert-deftest ogent-onboard-add-to-registry-existing-model ()
  "Test adding a model that already exists does not duplicate."
  (let ((ogent-model-registry '((:id "existing-model" :backend foo :description "Old"))))
    (ogent-onboard--add-to-registry
     '(:id anthropic :backend gptel-anthropic)
     '(:id "existing-model" :description "New"))
    ;; Should still have only one entry
    (should (= 1 (length ogent-model-registry)))))

(ert-deftest ogent-onboard-add-to-registry-returns-entry ()
  "Test add-to-registry returns the constructed entry."
  (let ((ogent-model-registry '((:id "placeholder" :backend foo))))
    (let ((entry (ogent-onboard--add-to-registry
                  '(:id test :backend gptel-test)
                  '(:id "new-model" :description "New"))))
      (should entry)
      (should (equal "new-model" (plist-get entry :id)))
      (should (eq t (plist-get entry :stream?))))))

;;; Find Source Root Tests

(ert-deftest ogent-onboard-find-source-root-custom ()
  "Test find-source-root uses ogent-source-directory when set."
  (let* ((root (make-temp-file "ogent-root-" t))
         (lisp-dir (expand-file-name "lisp" root))
         (ogent-source-directory root))
    (unwind-protect
        (progn
          (make-directory lisp-dir)
          (with-temp-file (expand-file-name "ogent.el" lisp-dir)
            (insert ";;; ogent.el\n"))
          (should (equal (file-name-as-directory (file-truename root))
                         (ogent-onboard--find-source-root))))
      (delete-directory root t))))

(ert-deftest ogent-onboard-find-source-root-keeps-invalid-custom-path ()
  "Invalid custom source roots remain authoritative for reload errors."
  (let ((ogent-source-directory "/custom/ogent"))
    (should (equal "/custom/ogent/" (ogent-onboard--find-source-root)))))

(ert-deftest ogent-onboard-source-root-accepts-lisp-dir ()
  "Source root detection accepts an ogent lisp directory."
  (let* ((root (make-temp-file "ogent-root-" t))
         (lisp-dir (expand-file-name "lisp" root)))
    (unwind-protect
        (progn
          (make-directory lisp-dir)
          (with-temp-file (expand-file-name "ogent.el" lisp-dir)
            (insert ";;; ogent.el\n"))
          (should (equal (file-name-as-directory (file-truename root))
                         (ogent-onboard--source-root-from-path lisp-dir))))
      (delete-directory root t))))

(ert-deftest ogent-onboard-source-root-follows-symlinked-package-file ()
  "Source root detection follows straight-style symlinked package files."
  (let* ((root (make-temp-file "ogent-root-" t))
         (build (make-temp-file "ogent-build-" t))
         (lisp-dir (expand-file-name "lisp" root))
         (source-file (expand-file-name "ogent.el" lisp-dir))
         (linked-file (expand-file-name "ogent.el" build)))
    (unwind-protect
        (progn
          (make-directory lisp-dir)
          (with-temp-file source-file
            (insert ";;; ogent.el\n"))
          (make-symbolic-link source-file linked-file)
          (should (equal (file-name-as-directory (file-truename root))
                         (ogent-onboard--source-root-from-path linked-file))))
      (delete-directory root t)
      (delete-directory build t))))

(ert-deftest ogent-onboard-find-source-root-nil-falls-back ()
  "Test find-source-root falls back when ogent-source-directory is nil."
  (let ((ogent-source-directory nil))
    ;; It should return something non-nil (either straight.el path or load location)
    (should (ogent-onboard--find-source-root))))

;;; Provider Configuration Structure Tests

(ert-deftest ogent-onboard-oauth-provider-has-auth-type ()
  "Test OAuth provider has :auth-type oauth."
  (let ((oauth-provider (seq-find (lambda (p)
                                    (eq (plist-get p :id) 'anthropic-oauth))
                                  ogent-onboard-providers)))
    (should oauth-provider)
    (should (eq 'oauth (plist-get oauth-provider :auth-type)))))

(ert-deftest ogent-onboard-openai-codex-provider-has-oauth-handlers ()
  "OpenAI Codex provider reuses Codex OAuth login state."
  (let ((provider (seq-find (lambda (p)
                              (eq (plist-get p :id) 'openai-codex))
                            ogent-onboard-providers)))
    (should provider)
    (should (eq 'oauth (plist-get provider :auth-type)))
    (should (eq 'ogent-codex-oauth (plist-get provider :oauth-feature)))
    (should (eq 'ogent-codex-login (plist-get provider :oauth-login)))
    (should (eq 'ogent-codex-oauth-authenticated-p
                (plist-get provider :oauth-authenticated-p)))
    (should (eq 'ogent-codex-oauth-get-api-key
                (plist-get provider :oauth-key)))))

(ert-deftest ogent-onboard-oauth-providers-have-handlers ()
  "Every OAuth provider declares its auth integration functions."
  (dolist (provider ogent-onboard-providers)
    (when (eq (plist-get provider :auth-type) 'oauth)
      (should (plist-get provider :oauth-feature))
      (should (plist-get provider :oauth-login))
      (should (plist-get provider :oauth-authenticated-p)))))

(ert-deftest ogent-onboard-api-key-provider-has-env-var ()
  "Test API key providers have :env-var set."
  (dolist (provider ogent-onboard-providers)
    (when (eq (plist-get provider :auth-type) 'api-key)
      (should (plist-get provider :env-var)))))

(ert-deftest ogent-onboard-providers-have-models ()
  "Test every provider has at least one model."
  (dolist (provider ogent-onboard-providers)
    (should (> (length (plist-get provider :models)) 0))))

(ert-deftest ogent-onboard-all-models-have-id-and-description ()
  "Test every model in every provider has :id and :description."
  (dolist (provider ogent-onboard-providers)
    (dolist (model (plist-get provider :models))
      (should (plist-get model :id))
      (should (plist-get model :description)))))

(ert-deftest ogent-onboard-providers-have-backend-creator ()
  "Test every provider has a :backend-creator."
  (dolist (provider ogent-onboard-providers)
    (should (plist-get provider :backend-creator))))

;;; Set Default Model Tests

(ert-deftest ogent-onboard-set-default-model-changes-var ()
  "Test set-default-model changes ogent-default-model."
  (let ((ogent-default-model "old-model")
        (gptel-model nil)
        (gptel-backend nil))
    (ogent-onboard--set-default-model "new-model")
    (should (equal "new-model" ogent-default-model))))

(ert-deftest ogent-onboard-set-default-model-nil ()
  "Test set-default-model handles nil."
  (let ((ogent-default-model "old")
        (gptel-model "old")
        (gptel-backend 'old-backend))
    (ogent-onboard--set-default-model nil)
    (should (null ogent-default-model))))

(provide 'ogent-onboard-tests)
;;; ogent-onboard-tests.el ends here
