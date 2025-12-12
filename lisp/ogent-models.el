;;; ogent-models.el --- Model registry for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Centralizes metadata about supported LLM backends so UI and request
;; code have a single source of truth.
;;
;; Tool support: Models can specify :tools to enable function calling.
;; Tools are defined in `ogent-tool-registry' and registered with gptel
;; via `gptel-make-tool'.

;;; Code:

(require 'cl-lib)
(require 'seq)

(defgroup ogent-models nil
  "Configuration for ogent model registry."
  :group 'ogent)

(defvar ogent-default-model nil
  "Placeholder for the default model id.")

(defcustom ogent-model-registry
  '((:id "gpt-4o-mini" :backend gptel-openai :stream? t
          :description "OpenAI GPT-4o mini")
    (:id "gpt-4o" :backend gptel-openai :stream? t
          :description "OpenAI GPT-4o")
    (:id "claude-3.5" :backend gptel-anthropic :stream? t
          :description "Anthropic Claude 3.5"))
  "List of model definitions used by ogent.
Each entry is a plist supporting at least :id, :backend, and :stream? keys.

Optional keys:
  :preset     - gptel preset name to apply
  :tools      - list of tool names (symbols) to enable for this model
  :description - human-readable description

Example with tools:
  (:id \"claude-sonnet\" :backend gptel-anthropic :stream? t
   :tools (read-file write-file bash glob grep)
   :description \"Claude with coding tools\")"
  :type '(repeat (plist :options (:id :backend :preset :stream? :description :tools)))
  :group 'ogent-models)

(defun ogent-models-all ()
  "Return every registered ogent model plist."
  (or ogent-model-registry
      (user-error "`ogent-model-registry' does not contain any models")))

(defun ogent-models-get (model-id)
  "Return the plist describing MODEL-ID or nil if unknown."
  (seq-find (lambda (entry)
              (string= (plist-get entry :id) model-id))
            (ogent-models-all)))

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

(defcustom ogent-preset-registry nil
  "List of ogent-flavored preset definitions.
Each entry is a plist with at least :name (symbol) and :spec (plist).
The :spec is passed to `gptel-make-preset' when presets are registered.
You may also include :description for UI display."
  :type '(repeat (plist :options (:name :spec :description)))
  :group 'ogent-models)

(defvar ogent--presets-registered nil
  "Non-nil once `ogent-register-presets' has been called.")

(declare-function gptel-make-preset "ext:gptel" (name &rest spec))
(defvar gptel-presets)  ; Forward declaration for gptel variable

(defun ogent-register-presets ()
  "Register all presets in `ogent-preset-registry' with gptel.
Safe to call multiple times; only registers once."
  (unless ogent--presets-registered
    (when (and (fboundp 'gptel-make-preset) ogent-preset-registry)
      (dolist (entry ogent-preset-registry)
        (let ((name (plist-get entry :name))
              (spec (plist-get entry :spec)))
          (when (and name spec)
            (apply #'gptel-make-preset name spec)))))
    (setq ogent--presets-registered t)))

(defun ogent-presets-available ()
  "Return a list of available preset names as strings.
Includes both ogent presets and any defined in gptel."
  (ogent-register-presets)
  (let ((names nil))
    (dolist (entry ogent-preset-registry)
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
                  ogent-preset-registry)
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
  :include     - if non-nil, include tool results in response

Example:
  (:name read-file
   :function ogent-tool--read-file
   :description \"Read contents of a file\"
   :args ((:name \"file_path\" :type \"string\"
           :description \"Absolute path to the file\"))
   :category \"filesystem\"
   :confirm nil)"
  :type '(repeat plist)
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

(defun ogent-tools-for-model (model-id)
  "Return list of gptel tool objects enabled for MODEL-ID.
Returns nil if the model has no :tools specified."
  (ogent-register-tools)
  (let* ((model (ogent-models-get model-id))
         (tool-names (plist-get model :tools)))
    (when tool-names
      (delq nil (mapcar #'ogent-tool-get tool-names)))))

(defun ogent-tools-all ()
  "Return all registered tool objects as a list."
  (ogent-register-tools)
  (mapcar #'cdr ogent--tools-registered))

(defun ogent-tool-spec-get (name)
  "Return the tool spec plist for NAME (symbol) from the registry."
  (seq-find (lambda (spec) (eq (plist-get spec :name) name))
            ogent-tool-registry))

(provide 'ogent-models)

;;; ogent-models.el ends here
