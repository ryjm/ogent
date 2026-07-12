;;; ogent-models-tests.el --- Tests for ogent-models -*- lexical-binding: t; -*-

(require 'ogent-test-helper)
(require 'ogent-models)
(require 'ogent-gptel)

;; Loaded at runtime inside the dangerous-tools test.
(declare-function ogent-tools-install-defaults "ogent-tools")

;; gptel session state let-bound in the effective-model tests.
(defvar gptel-model)

(ert-deftest ogent-models-default-falls-back-to-first-entry ()
  "Default accessor returns the first registry entry when no override is set."
  (let ((ogent-default-model nil)
        (ogent-model-registry '((:id "alpha" :backend foo)
                                (:id "beta" :backend bar))))
    (should (equal (plist-get (ogent-models-default) :id) "alpha"))))

(ert-deftest ogent-models-ensure-succeeds ()
  "Ensure returns a model plist and signals on missing entries."
  (let ((ogent-model-registry '((:id "alpha" :backend foo))))
    (should (equal (plist-get (ogent-models-ensure "alpha") :backend) 'foo))
    (should-error (ogent-models-ensure "missing") :type 'error)))

(ert-deftest ogent-models-default-is-current-frontier-openai-model ()
  "The shipped default should use the current flagship OpenAI model."
  (should (equal ogent-default-model "gpt-5.6-sol"))
  (should (ogent-models-get ogent-default-model)))

(ert-deftest ogent-models-registry-includes-current-frontier-models ()
  "The default registry includes current OpenAI and Anthropic text models."
  (dolist (model-id '("gpt-5.6-sol"
                      "gpt-5.6-terra"
                      "gpt-5.6-luna"
                      "gpt-5.5"
                      "gpt-5.5-pro"
                      "gpt-5.4"
                      "gpt-5.4-mini"
                      "gpt-5.4-nano"
                      "gpt-5.3-codex"
                      "claude-fable-5"
                      "claude-opus-4-8"
                      "claude-sonnet-5"
                      "claude-sonnet-4-6"
                      "claude-haiku-4-5-20251001"))
    (should (ogent-models-get model-id))))

(ert-deftest ogent-models-registry-omits-stale-models ()
  "Deprecated or superseded models must not ship in the default registry."
  ;; claude-sonnet-4-20250514 retires 2026-06-15; opus-4-7 is superseded by 4-8.
  (should-not (ogent-models-get "claude-sonnet-4-20250514"))
  (should-not (ogent-models-get "claude-opus-4-7")))

;;; gptel Model Property Tests

(ert-deftest ogent-models-apply-gptel-props-sets-request-params ()
  "Registry :request-params land on the interned gptel model symbol."
  (let ((sym (intern "ogent-test-model-props")))
    (unwind-protect
        (progn
          (ogent-models-apply-gptel-props
           '(:id "ogent-test-model-props"
                 :backend gptel-openai
                 :request-params (:reasoning_effort "high")))
          (should (equal (get sym :request-params)
                         '(:reasoning_effort "high"))))
      (put sym :request-params nil)
      (put sym :capabilities nil))))

(ert-deftest ogent-models-apply-gptel-props-unions-capabilities ()
  "Capabilities are unioned with pre-existing gptel declarations."
  (let ((sym (intern "ogent-test-model-caps")))
    (unwind-protect
        (progn
          (put sym :capabilities '(media))
          (ogent-models-apply-gptel-props
           '(:id "ogent-test-model-caps"
                 :backend gptel-anthropic
                 :capabilities (cache)))
          (should (memq 'cache (get sym :capabilities)))
          (should (memq 'media (get sym :capabilities))))
      (put sym :capabilities nil))))

(ert-deftest ogent-models-apply-gptel-props-noop-without-keys ()
  "Entries without the optional keys leave the symbol plist untouched."
  (let ((sym (intern "ogent-test-model-plain")))
    (unwind-protect
        (progn
          (should (eq (ogent-models-apply-gptel-props
                       '(:id "ogent-test-model-plain" :backend gptel-openai))
                      sym))
          (should-not (get sym :request-params))
          (should-not (get sym :capabilities)))
      (put sym :request-params nil)
      (put sym :capabilities nil))))


(ert-deftest ogent-gptel-ensure-model-on-backend-registers-frontier-model ()
  "New ogent model ids must be registered with gptel before sanitization."
  (let* ((backend 'test-backend)
         (models '(gpt-4o gpt-5))
         (model (ogent-models-ensure "gpt-5.5"))
         (symbol (intern "gpt-5.5"))
         (old-symbol-plist (symbol-plist symbol))
         (old-prototype-plist (symbol-plist 'gpt-5)))
    (unwind-protect
        (cl-letf (((symbol-function 'gptel-backend-models)
                   (lambda (candidate)
                     (should (eq candidate backend))
                     models))
                  ((symbol-function 'ogent-gptel--set-backend-models)
                   (lambda (candidate new-models)
                     (should (eq candidate backend))
                     (setq models new-models))))
          (setplist symbol nil)
          (put 'gpt-5 :capabilities '(media tool-use json url))
          (put 'gpt-5 :context-window 400)
          (should-not (memq symbol models))
          (should (eq (ogent-gptel-ensure-model-on-backend model backend)
                      symbol))
          (should (memq symbol models))
          (should (memq 'tool-use (get symbol :capabilities)))
          (should (equal (get symbol :description)
                         "OpenAI GPT-5.5 - previous flagship reasoning and coding")))
      (setplist symbol old-symbol-plist)
      (setplist 'gpt-5 old-prototype-plist))))

(ert-deftest ogent-models-shipped-anthropic-entries-declare-capabilities ()
  "Every shipped Anthropic entry declares media, tool-use, and cache.
On gptel versions that predate a model, the interned symbol has no
capability plist, and `gptel--model-capable-p' returns nil for
`tool-use' - gptel then silently drops tools from the request.  The
registry must therefore declare the full capability set itself;
`ogent-models-apply-gptel-props' unions it onto the symbol at send
time."
  (dolist (entry ogent-model-registry)
    (when (eq (plist-get entry :backend) 'gptel-anthropic)
      (dolist (cap '(media tool-use cache))
        (should (memq cap (plist-get entry :capabilities)))))))

(ert-deftest ogent-gptel-fable-5-gets-tool-use-on-stale-gptel ()
  "claude-fable-5 must be tool-capable even when gptel predates it.
Simulates gptel 0.9.9.5 (the minimum supported version): the model
symbol has an empty plist and the Anthropic backend model list does
not contain the id.  After the send-path setup sequence
\(`ogent-gptel-ensure-model-on-backend' then
`ogent-models-apply-gptel-props'), the symbol must be registered on
the backend and carry tool-use, media, and cache capabilities."
  (let* ((backend 'test-anthropic-backend)
         (models '(claude-sonnet-4-5-20250929))
         (model (ogent-models-ensure "claude-fable-5"))
         (symbol (intern "claude-fable-5"))
         (old-symbol-plist (symbol-plist symbol)))
    (unwind-protect
        (cl-letf (((symbol-function 'gptel-backend-models)
                   (lambda (candidate)
                     (should (eq candidate backend))
                     models))
                  ((symbol-function 'ogent-gptel--set-backend-models)
                   (lambda (candidate new-models)
                     (should (eq candidate backend))
                     (setq models new-models))))
          (setplist symbol nil)
          (should-not (memq symbol models))
          ;; Same call order as ogent-ui--send-to-model.
          (should (eq (ogent-gptel-ensure-model-on-backend model backend)
                      symbol))
          (ogent-models-apply-gptel-props model)
          (should (memq symbol models))
          (dolist (cap '(tool-use media cache))
            (should (memq cap (get symbol :capabilities))))
          (should (equal (get symbol :description)
                         "Anthropic Claude Fable 5 - next-generation intelligence for long-running agents")))
      (setplist symbol old-symbol-plist))))

;;; Tool confirmation policy (gptel approval bridge)

(ert-deftest ogent-tool-spec-confirm-explicit-flag ()
  "An explicit :confirm flag forces confirmation."
  (should (ogent-tool-spec-confirm-p '(:name foo :confirm t)))
  (should-not (ogent-tool-spec-confirm-p '(:name foo :confirm nil))))

(ert-deftest ogent-tool-spec-confirm-derived-from-risky-effects ()
  "High/critical effects require confirmation even without :confirm."
  ;; This is the P0 regression: a critical shell tool must not slip
  ;; through to gptel without a confirm flag.
  (should (ogent-tool-spec-confirm-p
           '(:name shell
                   :effects ((:kind execute :target shell :scope unrestricted
                                    :risk critical)))))
  (should (ogent-tool-spec-confirm-p
           '(:name writer
                   :effects ((:kind write :target file :scope workspace
                                    :risk high))))))

(ert-deftest ogent-tool-spec-confirm-low-risk-needs-no-confirm ()
  "Low-risk read-only effects do not force confirmation."
  (should-not (ogent-tool-spec-confirm-p
               '(:name reader
                       :effects ((:kind read :target file :scope workspace
                                        :risk low)))))
  (should-not (ogent-tool-spec-confirm-p '(:name bare))))

(ert-deftest ogent-register-tools-forwards-confirm-to-gptel ()
  "Registration passes a :confirm flag to `gptel-make-tool'.
Without it, gptel auto-executes risky tools (the P0 bypass)."
  (let ((ogent--tools-registered nil)
        (ogent-tool-registry
         '((:name safe-read
                  :function ignore
                  :description "read"
                  :effects ((:kind read :target file :scope workspace :risk low)))
           (:name risky-shell
                  :function ignore
                  :description "shell"
                  :effects ((:kind execute :target shell :scope unrestricted
                                   :risk critical))
                  :confirm t)))
        (captured nil))
    (cl-letf (((symbol-function 'gptel-make-tool)
               (lambda (&rest args)
                 (push (cons (plist-get args :name)
                             (plist-get args :confirm))
                       captured)
                 :tool)))
      (ogent-register-tools)
      (should (equal (cdr (assoc "risky-shell" captured)) t))
      ;; A confirm flag is always passed (never absent); low-risk is nil.
      (should (assoc "safe-read" captured))
      (should-not (cdr (assoc "safe-read" captured))))))

(ert-deftest ogent-default-tools-confirm-on-dangerous-operations ()
  "The shipped bash/write-file/edit-file tools resolve to confirm=t."
  (require 'ogent-tools)
  (let ((ogent-tool-registry nil))
    (ogent-tools-install-defaults)
    (dolist (name '(bash write-file edit-file))
      (let ((spec (ogent-tool-spec-get name)))
        (should spec)
        (should (ogent-tool-spec-confirm-p spec))))))

(ert-deftest ogent-models-pro-models-can-disable-streaming ()
  "The registry can represent models that should not stream."
  (let ((model (ogent-models-get "gpt-5.5-pro")))
    (should model)
    (should-not (plist-get model :stream?))))

(ert-deftest ogent-presets-available-collects-names ()
  "Available presets include both ogent and gptel presets."
  (let ((ogent-preset-registry '((:name code-review :spec (:description "cr"))
                                 (:name summarize :spec (:description "sum"))))
        (ogent--presets-registered nil))
    ;; Bind gptel-presets explicitly to ensure boundp works
    (defvar gptel-presets nil)
    (let ((gptel-presets '((external . (:description "ext")))))
      (cl-letf (((symbol-function 'gptel-make-preset) (lambda (&rest _) nil)))
        (let ((names (ogent-presets-available)))
          (should (member "code-review" names))
          (should (member "summarize" names))
          (should (member "external" names)))))))

(ert-deftest ogent-preset-get-finds-entry ()
  "Preset get returns the plist for a named preset."
  (let ((ogent-preset-registry '((:name code-review :spec (:description "cr")))))
    (should (equal (plist-get (ogent-preset-get "code-review") :name) 'code-review))
    (should (equal (plist-get (ogent-preset-get 'code-review) :name) 'code-review))
    (should (null (ogent-preset-get "missing")))))

;;; Default Presets Tests

(ert-deftest ogent-default-presets-defined ()
  "Default ogent presets are defined in the registry."
  (should (assq 'ogent-code-review
                (mapcar (lambda (p) (cons (plist-get p :name) p))
                        ogent-default-presets)))
  (should (assq 'ogent-explain
                (mapcar (lambda (p) (cons (plist-get p :name) p))
                        ogent-default-presets)))
  (should (assq 'ogent-refactor
                (mapcar (lambda (p) (cons (plist-get p :name) p))
                        ogent-default-presets))))

(ert-deftest ogent-default-presets-have-system-messages ()
  "Each default preset has a system message in its spec."
  (dolist (preset ogent-default-presets)
    (let ((spec (plist-get preset :spec)))
      (should (plist-get spec :system)))))

(ert-deftest ogent-default-presets-have-descriptions ()
  "Each default preset has a description."
  (dolist (preset ogent-default-presets)
    (should (plist-get preset :description))))

(ert-deftest ogent-preset-registry-includes-defaults ()
  "When ogent-preset-registry is nil, defaults are used."
  (let ((ogent-preset-registry nil)
        (ogent--presets-registered nil))
    ;; ogent-presets-available should include defaults
    (cl-letf (((symbol-function 'gptel-make-preset) (lambda (&rest _) nil)))
      (let ((names (ogent-presets-available)))
        (should (member "ogent-code-review" names))
        (should (member "ogent-explain" names))
        (should (member "ogent-refactor" names))))))

;;; Model IDs Tests

(ert-deftest ogent-models-ids-returns-strings ()
  "Test models-ids returns list of model ID strings."
  (let ((ogent-model-registry '((:id "alpha" :backend foo)
                                (:id "beta" :backend bar)
                                (:id "gamma" :backend baz))))
    (let ((ids (ogent-models-ids)))
      (should (= (length ids) 3))
      (should (member "alpha" ids))
      (should (member "beta" ids))
      (should (member "gamma" ids)))))

(ert-deftest ogent-models-all-error-when-empty ()
  "Test models-all signals error when registry is empty."
  (let ((ogent-model-registry nil))
    (should-error (ogent-models-all) :type 'user-error)))

;;; All Presets Tests

(ert-deftest ogent-all-presets-user-overrides ()
  "Test user presets override defaults with same name."
  (let ((ogent-preset-registry
         '((:name ogent-code-review :spec (:description "custom cr")
                  :description "User custom"))))
    (let ((all (ogent--all-presets)))
      ;; Should find the user version
      (let ((found (seq-find (lambda (p) (eq (plist-get p :name) 'ogent-code-review))
                             all)))
        (should found)
        (should (equal (plist-get found :description) "User custom"))))))

(ert-deftest ogent-all-presets-includes-defaults ()
  "Test all-presets includes defaults when no user overrides."
  (let ((ogent-preset-registry nil))
    (let ((all (ogent--all-presets)))
      (should (seq-find (lambda (p) (eq (plist-get p :name) 'ogent-code-review))
                        all))
      (should (seq-find (lambda (p) (eq (plist-get p :name) 'ogent-explain))
                        all)))))

;;; Tool Registry Tests

(ert-deftest ogent-tools-enabled-list-nil ()
  "Test tools-enabled-list returns nil when tools disabled."
  (let ((ogent-tools-enabled nil))
    (should-not (ogent-tools-enabled-list))))

(ert-deftest ogent-tools-enabled-list-all ()
  "Test tools-enabled-list returns all tools when enabled is t."
  (let ((ogent-tools-enabled t)
        (ogent--tools-registered '((read-file . mock-tool-1)
                                   (write-file . mock-tool-2))))
    (cl-letf (((symbol-function 'ogent-register-tools)
               (lambda () ogent--tools-registered)))
      (let ((tools (ogent-tools-enabled-list)))
        (should (= (length tools) 2))))))

(ert-deftest ogent-tool-spec-get-finds-entry ()
  "Test tool-spec-get finds a tool spec by name."
  (let ((ogent-tool-registry
         '((:name read-file :function my-read :description "Read file"))))
    (let ((spec (ogent-tool-spec-get 'read-file)))
      (should spec)
      (should (eq (plist-get spec :name) 'read-file))
      (should (eq (plist-get spec :function) 'my-read)))))

(ert-deftest ogent-tool-spec-get-nil-missing ()
  "Test tool-spec-get returns nil for missing tool."
  (let ((ogent-tool-registry nil))
    (should-not (ogent-tool-spec-get 'nonexistent))))

;;; Model Role Tests

(defmacro ogent-models-tests--with-roles (roles &rest body)
  "Run BODY with a two-model registry and ROLES as the role alist."
  (declare (indent 1) (debug t))
  `(let ((ogent-default-model "alpha")
         (ogent-model-registry '((:id "alpha" :backend gptel-openai)
                                 (:id "beta" :backend gptel-anthropic)))
         (ogent-model-roles ,roles))
     ,@body))

(ert-deftest ogent-models-resolve-role-returns-assignment ()
  "A role assigned a registered model id resolves to that id."
  (ogent-models-tests--with-roles '((edit . "beta"))
    (should (equal (ogent-models-resolve-role 'edit) "beta"))))

(ert-deftest ogent-models-resolve-role-follows-alias-chain ()
  "A role aliasing another role resolves through the chain."
  (ogent-models-tests--with-roles '((codemap . fast) (fast . "beta"))
    (should (equal (ogent-models-resolve-role 'codemap) "beta"))))

(ert-deftest ogent-models-resolve-role-falls-back-to-default ()
  "Unassigned roles, cycles, and stale ids fall back to the default."
  (ogent-models-tests--with-roles nil
    (should (equal (ogent-models-resolve-role 'edit) "alpha")))
  (ogent-models-tests--with-roles '((edit . deep) (deep . edit))
    (should (equal (ogent-models-resolve-role 'edit) "alpha")))
  (ogent-models-tests--with-roles '((edit . "retired-model"))
    (should (equal (ogent-models-resolve-role 'edit) "alpha"))))

(ert-deftest ogent-models-resolve-designator-forms ()
  "Designators accept ids, @role strings, role symbols, and nil."
  (ogent-models-tests--with-roles '((deep . "beta"))
    (should (equal (ogent-models-resolve-designator "beta") "beta"))
    (should (equal (ogent-models-resolve-designator "@deep") "beta"))
    (should (equal (ogent-models-resolve-designator 'deep) "beta"))
    (should (equal (ogent-models-resolve-designator "deep") "beta"))
    (should (equal (ogent-models-resolve-designator nil) "alpha"))
    (should-not (ogent-models-resolve-designator "no-such-model"))))

(ert-deftest ogent-models-set-role-assigns-and-clears ()
  "Set-role updates the alist; nil clears back to the default."
  (ogent-models-tests--with-roles nil
    (ogent-models-set-role 'edit "beta")
    (should (equal (ogent-models-resolve-role 'edit) "beta"))
    (ogent-models-set-role 'edit nil)
    (should (equal (ogent-models-resolve-role 'edit) "alpha"))))

(ert-deftest ogent-models-project-roles-shadow-global ()
  "Buffer-local project role assignments win over the global alist."
  (require 'ogent-presets)
  (ogent-models-tests--with-roles '((edit . "alpha"))
    (with-temp-buffer
      (setq-local ogent-project-model-roles '((edit . "beta")))
      (should (equal (ogent-models-resolve-role 'edit) "beta")))))

;;; Effective Model Tests

(ert-deftest ogent-models-effective-org-property-wins ()
  "An inherited OGENT_MODEL property beats every other layer."
  (ogent-models-tests--with-roles '((edit . "alpha"))
    (with-temp-buffer
      (org-mode)
      (insert "* Heading\n:PROPERTIES:\n:OGENT_MODEL: beta\n:END:\nBody\n")
      (goto-char (point-max))
      (let ((gptel-model "alpha"))
        (should (equal (ogent-models-effective 'edit)
                       '("beta" . org-property)))))))

(ert-deftest ogent-models-effective-org-property-accepts-role ()
  "An OGENT_MODEL property may name an @role designator."
  (ogent-models-tests--with-roles '((deep . "beta"))
    (with-temp-buffer
      (org-mode)
      (insert "* Heading\n:PROPERTIES:\n:OGENT_MODEL: @deep\n:END:\n")
      (goto-char (point-max))
      (should (equal (car (ogent-models-effective)) "beta")))))

(ert-deftest ogent-models-effective-role-beats-session ()
  "An assigned role wins over the buffer's gptel model."
  (ogent-models-tests--with-roles '((edit . "beta"))
    (with-temp-buffer
      (let ((gptel-model "alpha"))
        (should (equal (ogent-models-effective 'edit)
                       '("beta" . role)))))))

(ert-deftest ogent-models-effective-session-beats-default ()
  "A registered gptel model wins over the default for default requests."
  (ogent-models-tests--with-roles nil
    (with-temp-buffer
      (let ((gptel-model "beta"))
        (should (equal (ogent-models-effective) '("beta" . session))))
      (let ((gptel-model 'beta))
        (should (equal (car (ogent-models-effective)) "beta"))))))

(ert-deftest ogent-models-effective-skips-unregistered-session ()
  "A stale gptel model falls through to the default."
  (ogent-models-tests--with-roles nil
    (with-temp-buffer
      (let ((gptel-model "gpt-3.5-turbo"))
        (should (equal (ogent-models-effective) '("alpha" . default)))))))

(ert-deftest ogent-models-effective-no-session-skips-gptel-state ()
  "NO-SESSION resolution ignores the gptel session layer."
  (ogent-models-tests--with-roles nil
    (with-temp-buffer
      (let ((gptel-model "beta"))
        (should (equal (ogent-models-effective nil 'no-session)
                       '("alpha" . default)))))))

(ert-deftest ogent-models-effective-project-model-beats-default ()
  "The buffer-local project model wins over the default."
  (require 'ogent-presets)
  (ogent-models-tests--with-roles nil
    (with-temp-buffer
      (setq-local ogent-project-model "beta")
      (let ((gptel-model nil))
        (should (equal (ogent-models-effective) '("beta" . project)))))))

(provide 'ogent-models-tests)
;;; ogent-models-tests.el ends here
