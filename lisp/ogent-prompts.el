;;; ogent-prompts.el --- Prompt templates for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides a registry for reusable prompt templates, composition of multiple
;; prompts, validation of required context, and per-project customization.
;;
;; Prompts can be defined in Org files with OGENT_ID properties and loaded
;; into the registry, or registered programmatically.
;;
;; Composition syntax: @code-review+@testing combines multiple prompts.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)

(defgroup ogent-prompts nil
  "Configuration for ogent prompt templates."
  :group 'ogent)

;;; Data Structures

(cl-defstruct ogent-prompt
  "A reusable prompt template."
  id              ; string - unique identifier
  title           ; string - human-readable name
  content         ; string - the prompt text
  required-context ; list of symbols - context keys that must be present
  compose-order)  ; number - order when composing (lower = earlier)

(defvar ogent-prompt-registry (make-hash-table :test 'equal)
  "Hash table mapping prompt IDs (strings) to `ogent-prompt' structs.")

(defconst ogent-prompt--param-rx
  (rx "{{" (* space)
      (group (+ (or alnum "-" "_")))
      (* space)
      (opt ":" (* space) (group (+ (not (any "}")))) (* space))
      "}}")
  "Regexp matching template parameters like {{name}} or {{name:default}}.")

;;; Registry Functions

(cl-defun ogent-prompt-register (id &key title content required-context compose-order)
  "Register a prompt with ID and properties.
TITLE is the human-readable name.
CONTENT is the prompt text.
REQUIRED-CONTEXT is a list of context keys that must be present.
COMPOSE-ORDER determines ordering when composing (lower = earlier, default 50)."
  (let ((prompt (make-ogent-prompt
                 :id id
                 :title (or title id)
                 :content (or content "")
                 :required-context required-context
                 :compose-order (or compose-order 50))))
    (puthash id prompt ogent-prompt-registry)
    prompt))

(defun ogent-prompt-get (id)
  "Return the `ogent-prompt' for ID, or nil if not found."
  (gethash id ogent-prompt-registry))

(defun ogent-prompt-unregister (id)
  "Remove prompt with ID from the registry."
  (remhash id ogent-prompt-registry))

(defun ogent-prompt-list ()
  "Return a list of all registered `ogent-prompt' structs."
  (let ((prompts nil))
    (maphash (lambda (_k v) (push v prompts)) ogent-prompt-registry)
    (nreverse prompts)))

(defun ogent-prompt-ids ()
  "Return a list of all registered prompt IDs."
  (let ((ids nil))
    (maphash (lambda (k _v) (push k ids)) ogent-prompt-registry)
    (nreverse ids)))

;;; Composition

(defun ogent-prompt-parse-composition (input)
  "Parse INPUT into a list of prompt IDs.
Supports syntax like @code-review+@testing or code-review+testing.
Returns a list of ID strings."
  (let ((cleaned (replace-regexp-in-string "@" "" input)))
    (split-string cleaned "\\+" t "[ \t]+")))

(defun ogent-prompt-template-params (content)
  "Return parameter specs discovered in CONTENT.
Each entry is a plist with :name and optional :default keys."
  (let ((params nil)
        (seen (make-hash-table :test 'equal)))
    (with-temp-buffer
      (insert (or content ""))
      (goto-char (point-min))
      (while (re-search-forward ogent-prompt--param-rx nil t)
        (let* ((name (string-trim (match-string-no-properties 1)))
               (default (match-string-no-properties 2)))
          (unless (gethash name seen)
            (puthash name t seen)
            (push (list :name name
                        :default (when default (string-trim default)))
                  params)))))
    (nreverse params)))

(defun ogent-prompt--param-value (name params)
  "Return value for NAME from PARAMS.
PARAMS can be an alist with string/symbol keys or a plist with keyword keys."
  (cond
   ((null params) nil)
   ((and (listp params) (keywordp (car params)))
    (plist-get params (intern (concat ":" name))))
   (t (or (cdr (assoc name params))
          (cdr (assoc (intern name) params))))))

(defun ogent-prompt-render (content &optional params)
  "Render CONTENT by substituting template parameters from PARAMS."
  (replace-regexp-in-string
   ogent-prompt--param-rx
   (lambda (match)
     (string-match ogent-prompt--param-rx match)
     (let* ((name (string-trim (match-string 1 match)))
            (default (match-string 2 match))
            (value (ogent-prompt--param-value name params)))
       (cond
        ((and value (stringp value)) value)
        (value (format "%s" value))
        (default (string-trim default))
        (t ""))))
   (or content "")
   t t))

(defun ogent-prompt--collect-params (ids)
  "Return merged param specs for prompt IDS."
  (let ((all nil)
        (seen (make-hash-table :test 'equal)))
    (dolist (id ids)
      (when-let ((prompt (ogent-prompt-get id)))
        (dolist (param (ogent-prompt-template-params
                        (ogent-prompt-content prompt)))
          (let ((name (plist-get param :name)))
            (unless (gethash name seen)
              (puthash name t seen)
              (push param all))))))
    (nreverse all)))

(defun ogent-prompt-read-params (params)
  "Prompt for PARAMS values, returning an alist."
  (let ((values nil))
    (dolist (param params)
      (let* ((name (plist-get param :name))
             (default (plist-get param :default))
             (value (read-string (format "%s: " name) default)))
        (push (cons name value) values)))
    (nreverse values)))

(defun ogent-prompt-compose (ids)
  "Compose prompt templates with IDS into a single string.
Sort by compose-order (lower first) and concatenate with double newlines.
Unknown IDs are silently skipped."
  (let* ((prompts (delq nil (mapcar #'ogent-prompt-get ids)))
         (sorted (sort prompts
                       (lambda (a b)
                         (< (or (ogent-prompt-compose-order a) 50)
                            (or (ogent-prompt-compose-order b) 50))))))
    (mapconcat #'ogent-prompt-content sorted "\n\n")))

(defun ogent-prompt-compose-from-string (input)
  "Parse INPUT and compose the referenced prompt templates.
INPUT can be @code-review+@testing or similar syntax."
  (ogent-prompt-compose (ogent-prompt-parse-composition input)))

(defun ogent-prompt-compose-rendered (ids &optional params)
  "Compose templates IDS, rendering parameters with PARAMS."
  (let* ((prompts (delq nil (mapcar #'ogent-prompt-get ids)))
         (sorted (sort prompts
                       (lambda (a b)
                         (< (or (ogent-prompt-compose-order a) 50)
                            (or (ogent-prompt-compose-order b) 50))))))
    (mapconcat (lambda (prompt)
                 (ogent-prompt-render (ogent-prompt-content prompt) params))
               sorted
               "\n\n")))

(defun ogent-prompt-compose-with-params (ids &optional params)
  "Compose templates IDS, prompting for PARAMS when needed."
  (let* ((param-specs (ogent-prompt--collect-params ids))
         (values (or params (ogent-prompt-read-params param-specs))))
    (ogent-prompt-compose-rendered ids values)))

(defun ogent-prompt-select-ids ()
  "Interactively select prompt template IDs."
  (ogent-prompts-initialize)
  (let ((choices (ogent-prompt-ids)))
    (completing-read-multiple "Prompt templates: " choices nil t)))

(defun ogent-prompt-insert (ids)
  "Insert composed prompt templates IDS at point."
  (interactive (list (ogent-prompt-select-ids)))
  (when ids
    (insert (ogent-prompt-compose-with-params ids))))

;;; Validation

(defun ogent-prompt-validate (id context)
  "Validate that CONTEXT satisfies prompt ID's requirements.
CONTEXT is a plist of available context (e.g., (:code \"...\")).
Returns a plist with :valid (boolean) and :missing (list of missing keys)."
  (let* ((prompt (ogent-prompt-get id))
         (required (and prompt (ogent-prompt-required-context prompt)))
         (missing nil))
    (when required
      (dolist (key required)
        (unless (plist-get context (intern (format ":%s" key)))
          (push key missing))))
    (list :valid (null missing)
          :missing (nreverse missing))))

(defun ogent-prompt-validate-composition (ids context)
  "Validate all prompt templates in IDS against CONTEXT.
Return a plist with :valid and :missing (aggregated from all templates)."
  (let ((all-missing nil))
    (dolist (id ids)
      (let ((result (ogent-prompt-validate id context)))
        (setq all-missing (append all-missing (plist-get result :missing)))))
    (list :valid (null all-missing)
          :missing (delete-dups all-missing))))

;;; Project Customization

(defcustom ogent-project-prompts-file nil
  "Path to project-specific prompts Org file.
Can be set in .dir-locals.el for per-project customization.
When set, prompts from this file are loaded and merged with defaults."
  :type '(choice (const nil) file)
  :group 'ogent-prompts
  :safe #'stringp)

(defcustom ogent-prompt-overrides nil
  "Alist of prompt overrides for the current project.
Each entry is (ID . PLIST) where PLIST contains properties to override.
Can be set in .dir-locals.el.

Example:
  ((\"code-review\" . (:content \"Custom review rules.\")))"
  :type '(alist :key-type string :value-type plist)
  :group 'ogent-prompts
  :safe (lambda (val)
          (and (listp val)
               (cl-every (lambda (entry)
                           (and (consp entry)
                                (stringp (car entry))
                                (listp (cdr entry))))
                         val))))

(defun ogent-prompt-load-from-file (file)
  "Load prompt templates from Org FILE into the registry.
Templates are identified by OGENT_ID properties on headlines."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (org-mode)
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (hl)
          (let ((id (org-element-property :OGENT_ID hl)))
            (when id
              (let* ((title (org-element-property :raw-value hl))
                     (begin (org-element-property :contents-begin hl))
                     (end (org-element-property :contents-end hl))
                     (content (when (and begin end)
                                (string-trim
                                 (buffer-substring-no-properties begin end)))))
                (ogent-prompt-register id
                                       :title title
                                       :content (or content ""))))))))))

(defun ogent-prompt-load-project-prompts ()
  "Load prompt templates from `ogent-project-prompts-file' if set."
  (when ogent-project-prompts-file
    (let ((file (expand-file-name ogent-project-prompts-file)))
      (ogent-prompt-load-from-file file))))

(defun ogent-prompt-apply-overrides ()
  "Apply `ogent-prompt-overrides' to registered prompt templates."
  (dolist (override ogent-prompt-overrides)
    (let* ((id (car override))
           (props (cdr override))
           (prompt (ogent-prompt-get id)))
      (when prompt
        ;; Apply each property from the override
        (when (plist-member props :content)
          (setf (ogent-prompt-content prompt) (plist-get props :content)))
        (when (plist-member props :title)
          (setf (ogent-prompt-title prompt) (plist-get props :title)))
        (when (plist-member props :required-context)
          (setf (ogent-prompt-required-context prompt)
                (plist-get props :required-context)))
        (when (plist-member props :compose-order)
          (setf (ogent-prompt-compose-order prompt)
                (plist-get props :compose-order)))))))

;;; Default Prompts

(defconst ogent-default-prompts
  '(("code-review"
     :title "Code Review"
     :content "Review the provided code for:
- Bugs and logic errors
- Security vulnerabilities
- Performance issues
- Code style and maintainability
- Missing error handling

Be specific and actionable. Reference line numbers when possible.
Prioritize issues by severity (critical, warning, suggestion)."
     :required-context (code)
     :compose-order 10)

    ("refactoring"
     :title "Refactoring"
     :content "Analyze the code and suggest refactoring opportunities:
- Extract methods for repeated logic
- Simplify complex conditionals
- Improve naming for clarity
- Reduce coupling between components
- Apply appropriate design patterns

For each suggestion, explain the benefit and show the refactored code."
     :required-context (code)
     :compose-order 20)

    ("documentation"
     :title "Documentation"
     :content "Generate documentation for the provided code:
- Add docstrings/comments explaining purpose and behavior
- Document parameters, return values, and side effects
- Include usage examples where helpful
- Note any important caveats or edge cases

Match the documentation style of the surrounding codebase."
     :required-context (code)
     :compose-order 30)

    ("testing"
     :title "Testing"
     :content "Suggest test cases for the provided code:
- Happy path tests for normal operation
- Edge cases and boundary conditions
- Error handling and invalid input
- Integration points with dependencies

For each test, describe what it verifies and provide example code."
     :required-context (code)
     :compose-order 40)

    ("explain-code"
     :title "Explain Code"
     :content "Explain what this code does:
- Start with a high-level summary
- Break down complex logic step by step
- Explain the 'why' behind design decisions
- Point out any non-obvious patterns or idioms
- Use analogies when helpful

Keep explanations clear and concise."
     :required-context (code)
     :compose-order 50)

    ("debug-steps"
     :title "Debug Steps"
     :content "Help debug this issue systematically:
1. Analyze the symptoms and error messages
2. Form hypotheses about root causes
3. Suggest diagnostic steps to test each hypothesis
4. Recommend fixes once the cause is identified

Be methodical. Prioritize likely causes based on the evidence."
     :compose-order 60)

    ("bug-diagnosis"
     :title "Bug Diagnosis"
     :content "Clarify repro steps and add hypothesis-driven fixes."
     :compose-order 70)

    ("architecture-digest"
     :title "Architecture Digest"
     :content "Summarize module responsibilities and data flow implications."
     :compose-order 80))
  "Default prompt templates shipped with ogent.")

(defun ogent-prompt-register-defaults ()
  "Register all default prompt templates into the registry."
  (dolist (spec ogent-default-prompts)
    (let ((id (car spec))
          (props (cdr spec)))
      (apply #'ogent-prompt-register id props))))

;;; Initialization

(defvar ogent-prompts--initialized nil
  "Non-nil once prompts have been initialized.")

(defun ogent-prompts-initialize ()
  "Initialize the prompt system.
Registers defaults, loads project prompts, and applies overrides.
Safe to call multiple times."
  (unless ogent-prompts--initialized
    (ogent-prompt-register-defaults)
    (setq ogent-prompts--initialized t))
  ;; Always reload project prompts and overrides (they may change)
  (ogent-prompt-load-project-prompts)
  (ogent-prompt-apply-overrides))

;; Auto-initialize when loaded
(ogent-prompts-initialize)

(provide 'ogent-prompts)

;;; ogent-prompts.el ends here
