;;; ogent-models.el --- Model registry for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Centralizes metadata about supported LLM backends so UI and request
;; code have a single source of truth.
;;
;; Tools are defined in `ogent-tool-registry' and registered with gptel
;; via `gptel-make-tool'.  All tools are available for all models.

;;; Code:

(require 'seq)
(require 'ogent-tool-effects)

(defgroup ogent-models nil
  "Configuration for ogent model registry."
  :group 'ogent)

(defcustom ogent-default-model "gpt-5.6-sol"
  "Default model identifier used when dispatching prompts."
  :type 'string
  :group 'ogent-models)

(defcustom ogent-model-registry
  '((:id "gpt-5.6-sol" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.6 Sol - flagship reasoning and coding")
    (:id "gpt-5.6-terra" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.6 Terra - balanced intelligence and cost")
    (:id "gpt-5.6-luna" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.6 Luna - cost-efficient high-volume tasks")
    (:id "gpt-5.5" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.5 - previous flagship reasoning and coding")
    (:id "gpt-5.5-pro" :backend gptel-openai :stream? nil
         :description "OpenAI GPT-5.5 pro - hardest reasoning tasks")
    (:id "gpt-5.4" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.4 - professional coding and agentic work")
    (:id "gpt-5.4-mini" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.4 mini - fast, cost-aware coding")
    (:id "gpt-5.4-nano" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.4 nano - low-cost high-volume tasks")
    (:id "gpt-5.3-codex" :backend gptel-openai :stream? t
         :description "OpenAI GPT-5.3-Codex - agentic coding")
    (:id "gpt-4.1" :backend gptel-openai :stream? t
         :description "OpenAI GPT-4.1 - non-reasoning long-context model")
    (:id "gpt-4o-mini" :backend gptel-openai :stream? t
         :description "OpenAI GPT-4o mini - legacy fallback")
    (:id "claude-fable-5" :backend gptel-anthropic :stream? t
         :capabilities (cache)
         :description "Anthropic Claude Fable 5 - next-generation intelligence for long-running agents")
    (:id "claude-opus-4-8" :backend gptel-anthropic :stream? t
         :capabilities (cache)
         :description "Anthropic Claude Opus 4.8 - long-horizon agentic coding")
    (:id "claude-sonnet-5" :backend gptel-anthropic :stream? t
         :capabilities (cache)
         :description "Anthropic Claude Sonnet 5 - best combination of speed and intelligence")
    (:id "claude-sonnet-4-6" :backend gptel-anthropic :stream? t
         :capabilities (cache)
         :description "Anthropic Claude Sonnet 4.6 - previous balanced Claude model")
    (:id "claude-haiku-4-5-20251001" :backend gptel-anthropic :stream? t
         :capabilities (cache)
         :description "Anthropic Claude Haiku 4.5 - fastest Claude model"))
  "List of model definitions used by ogent.
Each entry is a plist supporting at least :id, :backend, and :stream? keys.

Optional keys:
  :preset         - gptel preset name to apply
  :description    - human-readable description
  :request-params - plist of extra request parameters merged into the
                    HTTP request body for this model, e.g.
                    (:reasoning_effort \"high\") for OpenAI or
                    (:thinking (:type \"enabled\" :budget_tokens 4096))
                    for Anthropic
  :capabilities   - list of gptel capability symbols to add to the
                    model, e.g. (cache)"
  :type '(repeat (plist :options (:id :backend :preset :stream? :description
                                      :request-params :capabilities)))
  :group 'ogent-models)

(defun ogent-models-all ()
  "Return every registered ogent model plist."
  (or ogent-model-registry
      (user-error "`ogent-model-registry' does not contain any models")))

(defun ogent-models-get (model-id)
  "Return the plist describing MODEL-ID or nil if unknown."
  (seq-find (lambda (entry)
              (string= (plist-get entry :id) model-id))
            ogent-model-registry))

(defun ogent-models-ensure (model-id)
  "Return MODEL-ID entry or signal a user error if missing."
  (or (ogent-models-get model-id)
      (user-error "Unknown ogent model: %s" model-id)))

(defun ogent-models-apply-gptel-props (model)
  "Copy MODEL's :request-params and :capabilities onto its gptel model symbol.
gptel reads both from the interned symbol's plist (see
`gptel--model-request-params' and `gptel--model-capable-p').
Capabilities are unioned with any gptel already declares for the
symbol, never replaced.  Returns the symbol."
  (let ((sym (intern (plist-get model :id))))
    (when-let ((params (plist-get model :request-params)))
      (put sym :request-params params))
    (when-let ((caps (plist-get model :capabilities)))
      (put sym :capabilities (cl-union caps (get sym :capabilities))))
    sym))

(defun ogent-models-default ()
  "Return the default model plist.
Falls back to the first registry entry if `ogent-default-model' is unset."
  (or (and ogent-default-model
           (ogent-models-get ogent-default-model))
      (car (ogent-models-all))))

(defun ogent-models-ids ()
  "Return a list of known model identifiers."
  (mapcar (lambda (entry) (plist-get entry :id))
          (ogent-models-all)))

;;; Model Roles
;;
;; Roles let different tasks run on different models, in the spirit of
;; oh-my-pi's model roles: `edit' requests can use a fast model while
;; `deep' work runs on the strongest one.  A role maps to a designator,
;; which is either a model id from `ogent-model-registry' or another
;; role symbol (an alias).  Unassigned roles fall back to the `default'
;; role, which resolves to `ogent-default-model'.

(defconst ogent-model-known-roles '(default fast deep edit codemap)
  "Built-in task roles that ogent features resolve models through.
`default' - interactive requests (dispatch, ask, zen)
`fast'    - low-latency, high-volume background work
`deep'    - hardest reasoning tasks
`edit'    - inline edit requests from `ogent-edit'
`codemap' - codemap generation tasks")

(defcustom ogent-model-roles
  '((fast . "gpt-5.6-luna")
    (deep . "claude-fable-5")
    (edit . "gpt-5.6-terra")
    (codemap . fast))
  "Alist mapping task roles to model designators.
Each value is a model id string from `ogent-model-registry' or
another role symbol, which makes the entry an alias (for example
\(codemap . fast)).  Roles missing from this alist resolve to the
`default' role, i.e. `ogent-default-model'.  Projects can shadow
entries with `ogent-project-model-roles' in `.ogent.el'."
  :type '(alist :key-type symbol
                :value-type (choice (string :tag "Model id")
                                    (symbol :tag "Alias role")))
  :group 'ogent-models)

(defconst ogent-models-org-property "OGENT_MODEL"
  "Org property that pins the model for a subtree.
The value is a model designator: a model id such as
\"claude-fable-5\" or an \"@role\" reference such as \"@deep\".
The property is inherited, so a file-level
`#+PROPERTY: OGENT_MODEL ...' line applies to the whole file and
deeper headings can override it.")

;; Org is a soft dependency here: the property lookup only runs inside
;; Org buffers, where these are guaranteed to be loaded.
(declare-function org-entry-get "org" (epom property &optional inherit literal-nil))

;; Buffer-local project overrides, defined in ogent-presets.el.
(defvar ogent-project-model)
(defvar ogent-project-model-roles)

;; gptel session state, consulted for the effective model.
(defvar gptel-model)
(declare-function gptel--model-name "ext:gptel-request")

(defun ogent-models--role-alist ()
  "Return the effective role alist, project overrides first."
  (append (and (boundp 'ogent-project-model-roles)
               ogent-project-model-roles)
          ogent-model-roles))

(defun ogent-models-known-roles ()
  "Return every known role symbol, built-in roles first."
  (delete-dups
   (append (copy-sequence ogent-model-known-roles)
           (mapcar #'car (ogent-models--role-alist)))))

(defun ogent-models-role-designator (role)
  "Return the raw designator assigned to ROLE, or nil when unset."
  (cdr (assq role (ogent-models--role-alist))))

(defun ogent-models-resolve-role (role)
  "Return the model id that ROLE resolves to.
Follows role-alias chains with a cycle guard.  Unknown roles,
cycles, and assignments naming unregistered models all fall back
to `ogent-default-model'."
  (let ((seen nil)
        (current role))
    (while (and current (symbolp current) (not (memq current seen)))
      (push current seen)
      (setq current (if (eq current 'default)
                        (plist-get (ogent-models-default) :id)
                      (or (ogent-models-role-designator current)
                          'default))))
    (if (and (stringp current) (ogent-models-get current))
        current
      (plist-get (ogent-models-default) :id))))

(defun ogent-models-resolve-designator (designator)
  "Return the model id DESIGNATOR names, or nil when unresolvable.
DESIGNATOR is a model id string, a role symbol, a bare role name
string, or an \"@role\" string such as \"@deep\".  nil resolves
to the `default' role."
  (cond
   ((null designator) (ogent-models-resolve-role 'default))
   ((symbolp designator)
    (if (memq designator (ogent-models-known-roles))
        (ogent-models-resolve-role designator)
      (ogent-models-resolve-designator (symbol-name designator))))
   ((stringp designator)
    (let ((name (string-trim designator)))
      (cond
       ((string-prefix-p "@" name)
        (ogent-models-resolve-role (intern (substring name 1))))
       ((ogent-models-get name) name)
       ((memq (intern name) (ogent-models-known-roles))
        (ogent-models-resolve-role (intern name)))
       (t nil))))))

(defun ogent-models-set-role (role designator)
  "Assign DESIGNATOR to ROLE in `ogent-model-roles'.
DESIGNATOR nil clears the assignment so ROLE falls back to the
`default' role.  Returns the updated alist."
  (setq ogent-model-roles (assq-delete-all role ogent-model-roles))
  (when designator
    (push (cons role designator) ogent-model-roles))
  ogent-model-roles)

(defun ogent-models-org-designator ()
  "Return the inherited `OGENT_MODEL' designator at point, or nil."
  (when (derived-mode-p 'org-mode)
    (let ((value (org-entry-get (point) ogent-models-org-property t)))
      (and value
           (not (string-empty-p (string-trim value)))
           (string-trim value)))))

(defun ogent-models--session-id ()
  "Return the current gptel model id when it is a registered ogent model."
  (when (boundp 'gptel-model)
    (let* ((raw gptel-model)
           (name (cond
                  ((null raw) nil)
                  ((stringp raw) raw)
                  ((fboundp 'gptel--model-name) (gptel--model-name raw))
                  ((symbolp raw) (symbol-name raw))
                  (t raw))))
      (and (stringp name) (ogent-models-get name) name))))

(defun ogent-models-effective (&optional role no-session)
  "Return a cons (MODEL-ID . SOURCE) for a ROLE request at point.
SOURCE names the layer that decided: `org-property', `role',
`session', `project', or `default'.  Resolution order:
1. the inherited `OGENT_MODEL' Org property at point
2. ROLE's assignment from `ogent-models-role-designator'
   (skipped for the `default' role)
3. the buffer's current gptel model when it is registered
4. the buffer-local project model from `.ogent.el'
5. `ogent-default-model'
When NO-SESSION is non-nil, layer 3 is skipped so resolution only
considers declared state; declarative callers such as Org Babel
use this to stay reproducible."
  (let ((role (or role 'default)))
    (or (when-let* ((designator (ogent-models-org-designator))
                    (id (ogent-models-resolve-designator designator)))
          (cons id 'org-property))
        (and (not (eq role 'default))
             (ogent-models-role-designator role)
             (cons (ogent-models-resolve-role role) 'role))
        (and (not no-session)
             (when-let* ((id (ogent-models--session-id)))
               (cons id 'session)))
        (when-let* ((id (and (boundp 'ogent-project-model)
                             ogent-project-model
                             (ogent-models-get ogent-project-model)
                             ogent-project-model)))
          (cons id 'project))
        (cons (plist-get (ogent-models-default) :id) 'default))))

(defun ogent-models-effective-id (&optional role no-session)
  "Return the effective model id for a ROLE request at point.
NO-SESSION skips the gptel session layer, as in
`ogent-models-effective'."
  (car (ogent-models-effective role no-session)))

(defun ogent-models-effective-model (&optional role no-session)
  "Return the effective model plist for a ROLE request at point.
NO-SESSION skips the gptel session layer, as in
`ogent-models-effective'."
  (ogent-models-ensure (ogent-models-effective-id role no-session)))

;;; Preset Registry

(defconst ogent-default-presets
  '((:name ogent-code-review
           :spec (:description "Code review assistant"
                               :system "You are a code reviewer. Analyze the provided code for:
- Bugs and logic errors
- Security vulnerabilities
- Performance issues
- Code style and maintainability
- Missing error handling

Be specific and actionable. Reference line numbers when possible.
Prioritize issues by severity (critical, warning, suggestion).")
           :description "Code review: bugs, security, maintainability")

    (:name ogent-explain
           :spec (:description "Code explanation assistant"
                               :system "You are a code explainer. Your goal is to help developers understand code clearly.

When explaining code:
- Start with a high-level summary of what the code does
- Break down complex logic step by step
- Explain the 'why' behind design decisions when apparent
- Use analogies when helpful
- Point out any non-obvious patterns or idioms
- Keep explanations concise but thorough")
           :description "Explain code clearly with examples")

    (:name ogent-refactor
           :spec (:description "Refactoring assistant"
                               :system "You are a refactoring expert. Suggest improvements to make code:
- More readable and maintainable
- More efficient (when it matters)
- Better aligned with language idioms
- Easier to test

For each suggestion:
1. Explain what to change and why
2. Show the refactored code
3. Note any tradeoffs or considerations

Focus on practical improvements, not theoretical perfection.")
           :description "Suggest refactoring improvements"))
  "Default ogent presets shipped with the package.
These are merged with `ogent-preset-registry' when registering presets.")

(defcustom ogent-preset-registry nil
  "List of ogent-flavored preset definitions.
Each entry is a plist with at least :name (symbol) and :spec (plist).
The :spec is passed to `gptel-make-preset' when presets are registered.
You may also include :description for UI display.

Note: Default presets from `ogent-default-presets' are always included.
Use this variable to add custom presets or override defaults."
  :type '(repeat (plist :options (:name :spec :description)))
  :group 'ogent-models)

(defvar ogent--presets-registered nil
  "Non-nil once `ogent-register-presets' has been called.")

(declare-function gptel-make-preset "ext:gptel" (name &rest spec))
(defvar gptel-presets)  ; Forward declaration for gptel variable

(defun ogent--all-presets ()
  "Return all presets, combining defaults with user registry.
User presets in `ogent-preset-registry' override defaults with the same name."
  (let ((result (copy-sequence ogent-default-presets)))
    (dolist (entry ogent-preset-registry)
      (let* ((name (plist-get entry :name))
             (existing (seq-position result name
                                     (lambda (e n) (eq (plist-get e :name) n)))))
        (if existing
            (setf (nth existing result) entry)
          (push entry result))))
    result))

(defun ogent-register-presets ()
  "Register all presets with gptel.
Includes both `ogent-default-presets' and `ogent-preset-registry'.
Safe to call multiple times; only registers once."
  (unless ogent--presets-registered
    (when (fboundp 'gptel-make-preset)
      (dolist (entry (ogent--all-presets))
        (let ((name (plist-get entry :name))
              (spec (plist-get entry :spec)))
          (when (and name spec)
            (apply #'gptel-make-preset name spec)))))
    (setq ogent--presets-registered t)))

(defun ogent-presets-available ()
  "Return a list of available preset names as strings.
Includes ogent defaults, user presets, and any defined in gptel."
  (ogent-register-presets)
  (let ((names nil))
    (dolist (entry (ogent--all-presets))
      (let ((name (plist-get entry :name)))
        (when name (push (symbol-name name) names))))
    (when (boundp 'gptel-presets)
      (dolist (entry gptel-presets)
        (when (symbolp (car entry))
          (let ((name (symbol-name (car entry))))
            (unless (member name names)
              (push name names))))))
    (nreverse names)))

(defun ogent-preset-get (name)
  "Return the preset plist for NAME (string or symbol), or nil."
  (let ((sym (if (symbolp name) name (intern name))))
    (or (seq-find (lambda (e) (eq (plist-get e :name) sym))
                  (ogent--all-presets))
        (when (boundp 'gptel-presets)
          (assq sym gptel-presets)))))

;;; Tool Registry

(defcustom ogent-tool-registry nil
  "List of tool definitions for ogent.
Each entry is a plist passed to `gptel-make-tool'.

Required keys:
  :name        - tool identifier (symbol, will be snake_cased for API)
  :function    - elisp function to execute
  :description - what the tool does (for LLM context)
  :args        - list of argument specs, each a plist with:
                 :name (string), :type (string), :description (string)
                 optional: :optional (boolean), :enum (list)

Optional keys:
  :category    - grouping (e.g., \"filesystem\", \"shell\", \"search\")
  :async       - if non-nil, function takes a callback as last arg
  :confirm     - if non-nil, require user approval before execution
  :effects     - list of effect plists for policy and audit trails
  :include     - if non-nil, include tool results in response

Example:
  (:name read-file
   :function ogent-tool--read-file
   :description \"Read contents of a file\"
   :args ((:name \"file_path\" :type \"string\"
           :description \"Absolute path to the file\"))
   :category \"filesystem\"
   :effects ((:kind read :target file :scope workspace :risk low))
   :confirm nil)"
  :type '(repeat plist)
  :group 'ogent-models)

(defcustom ogent-tools-enabled t
  "Whether to enable tool use in ogent sessions.
When t, all registered tools are available.
When nil, no tools are passed to the LLM.
Can also be a list of tool name symbols to enable specific tools.

This variable can be made buffer-local for per-session control."
  :type '(choice (const :tag "All tools" t)
                 (const :tag "No tools" nil)
                 (repeat :tag "Specific tools" symbol))
  :group 'ogent-models)

(declare-function gptel-make-tool "ext:gptel-request")
(defvar gptel-tools)
(defvar gptel-use-tools)

(defun ogent-tool-spec-confirm-p (spec)
  "Return non-nil when SPEC's tool must be confirmed before running.
A tool requires confirmation when its registry entry declares
`:confirm' non-nil, or when its declared `:effects' meet the
approval threshold (see `ogent-tool-effects-approval-required-p').
This is the single source of truth bridged into gptel so that
gptel-native tool execution honors the same policy as ogent's own
approval path."
  (or (plist-get spec :confirm)
      (and (plist-member spec :effects)
           (ogent-tool-effects-approval-required-p
            (plist-get spec :effects)))))

(defvar ogent--tools-registered nil
  "Alist mapping tool names (symbols) to gptel tool objects.")

(defun ogent-register-tools ()
  "Register all tools in `ogent-tool-registry' with gptel.
Returns the list of registered tool objects."
  (when (and (fboundp 'gptel-make-tool) ogent-tool-registry)
    (dolist (spec ogent-tool-registry)
      (let* ((name (plist-get spec :name))
             (existing (assq name ogent--tools-registered)))
        (unless existing
          (let ((tool (apply #'gptel-make-tool
                             :name (symbol-name name)
                             :function (plist-get spec :function)
                             :description (plist-get spec :description)
                             :args (plist-get spec :args)
                             ;; Always pass :confirm so gptel-native
                             ;; execution prompts for risky tools; a
                             ;; missing flag would let gptel auto-run
                             ;; them.  See `ogent-tool-spec-confirm-p'.
                             :confirm (and (ogent-tool-spec-confirm-p spec) t)
                             (append
                              (when (plist-member spec :category)
                                (list :category (plist-get spec :category)))
                              (when (plist-member spec :async)
                                (list :async (plist-get spec :async)))
                              (when (plist-member spec :include)
                                (list :include (plist-get spec :include)))))))
            (push (cons name tool) ogent--tools-registered))))))
  ogent--tools-registered)

(defun ogent-tool-get (name)
  "Return the gptel tool object for NAME (symbol), or nil."
  (ogent-register-tools)
  (cdr (assq name ogent--tools-registered)))

(defun ogent-tools-all ()
  "Return all registered tool objects as a list."
  (ogent-register-tools)
  (mapcar #'cdr ogent--tools-registered))

(defun ogent-tools-enabled-list ()
  "Return list of enabled tool objects based on `ogent-tools-enabled'.
Returns nil if tools are disabled, all tools if t, or filtered list
if `ogent-tools-enabled' is a list of tool name symbols."
  (cond
   ((null ogent-tools-enabled) nil)
   ((eq ogent-tools-enabled t) (ogent-tools-all))
   ((listp ogent-tools-enabled)
    (delq nil (mapcar #'ogent-tool-get ogent-tools-enabled)))
   (t nil)))

(defun ogent-tool-spec-get (name)
  "Return the tool spec plist for NAME (symbol) from the registry."
  (seq-find (lambda (spec) (eq (plist-get spec :name) name))
            ogent-tool-registry))

(provide 'ogent-models)

;;; ogent-models.el ends here
