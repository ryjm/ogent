;;; ogent-models.el --- Model registry for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Centralizes metadata about supported LLM backends so UI and request
;; code have a single source of truth.
;;
;; Tools are defined in `ogent-tool-registry' and registered with gptel
;; via `gptel-make-tool'. All tools are available for all models.

;;; Code:

(require 'seq)

(defgroup ogent-models nil
  "Configuration for ogent model registry."
  :group 'ogent)

(defcustom ogent-default-model "gpt-5.4-mini"
  "Default model identifier used when dispatching prompts."
  :type 'string
  :group 'ogent-models)

(defcustom ogent-model-registry
  '((:id "gpt-5.5" :backend gptel-openai :stream? t
          :description "OpenAI GPT-5.5 - flagship reasoning and coding")
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
    (:id "claude-opus-4-7" :backend gptel-anthropic :stream? t
          :description "Anthropic Claude Opus 4.7 - complex reasoning and agentic coding")
    (:id "claude-sonnet-4-6" :backend gptel-anthropic :stream? t
          :description "Anthropic Claude Sonnet 4.6 - balanced speed and intelligence")
    (:id "claude-haiku-4-5-20251001" :backend gptel-anthropic :stream? t
          :description "Anthropic Claude Haiku 4.5 - fastest Claude model")
    (:id "claude-sonnet-4-20250514" :backend gptel-anthropic :stream? t
          :description "Anthropic Claude Sonnet 4 - legacy fallback"))
  "List of model definitions used by ogent.
Each entry is a plist supporting at least :id, :backend, and :stream? keys.

Optional keys:
  :preset      - gptel preset name to apply
  :description - human-readable description"
  :type '(repeat (plist :options (:id :backend :preset :stream? :description)))
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

(declare-function gptel-make-tool "ext:gptel"
                  (&rest args &key name function description args
                         category async include &allow-other-keys))
(defvar gptel-tools)
(defvar gptel-use-tools)

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
