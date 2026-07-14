;;; ogent-presets.el --- Project-specific presets for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides project-specific configuration for ogent, including:
;; - .ogent.el file support for per-project settings
;; - Default model/preset per project
;; - Auto-include project README/docs in context
;; - Project-specific prompt templates
;; - Codemap directory configuration
;;
;; Settings cascade: global defaults -> .dir-locals.el -> .ogent.el
;;
;; Example .ogent.el file:
;;   ((ogent-project-model . "claude-sonnet-4-6")
;;    (ogent-project-model-roles . ((edit . "gpt-5.6-terra") (deep . "claude-fable-5")))
;;    (ogent-project-preset . ogent-code-review)
;;    (ogent-project-context-files . ("README.md" "ARCHITECTURE.md"))
;;    (ogent-project-codemap-roots . ("src" "lib"))
;;    (ogent-project-prompts . (("review" . "Review this code for bugs"))))

;;; Code:

(require 'cl-lib)
(require 'project)

;; Forward declarations
(declare-function projectile-project-root "ext:projectile")
(declare-function ogent-prompt-register "ogent-prompts")
(declare-function ogent-pin-file "ogent-context")

(defgroup ogent-presets nil
  "Project-specific configuration for ogent."
  :group 'ogent)

;;; Customization Variables

(defcustom ogent-presets-file-name ".ogent.el"
  "Name of the project-specific ogent configuration file."
  :type 'string
  :group 'ogent-presets)

(defcustom ogent-presets-auto-load t
  "Whether to automatically load project presets on buffer switch.
When non-nil, ogent will detect and apply project-specific settings
when switching to buffers in projects with .ogent.el files."
  :type 'boolean
  :group 'ogent-presets)

(defcustom ogent-presets-auto-pin-docs nil
  "Whether to automatically pin documentation files to context.
When non-nil and `ogent-project-context-files' is set,
those files will be automatically pinned when entering a project."
  :type 'boolean
  :group 'ogent-presets)

;;; Buffer-Local Project Settings

(defvar-local ogent-project-model nil
  "Project-specific model ID.
Overrides `ogent-default-model' when set.")

(defvar-local ogent-project-model-roles nil
  "Project-specific model role assignments.
An alist like `ogent-model-roles'; entries shadow the global
alist when resolving roles in this project's buffers.")

(defvar-local ogent-project-preset nil
  "Project-specific preset symbol.
Applied to gptel sessions in this project.")

(defvar-local ogent-project-context-files nil
  "List of project-relative file paths to include in context.
Examples: (\"README.md\" \"docs/ARCHITECTURE.md\")")

(defvar-local ogent-project-codemap-roots nil
  "List of project-relative directories for codemap scanning.
Overrides `ogent-codemap-source-directories' when set.")

(defvar-local ogent-project-prompts nil
  "Alist of project-specific prompt templates.
Each entry is (ID . CONTENT) where ID is a string and CONTENT
is the prompt text.  These are registered with `ogent-prompt-register'.")

(defvar-local ogent-project-tools nil
  "List of tool symbols to enable for this project.
When set, overrides `ogent-tools-enabled' for project buffers.
Use t to enable all tools, nil to disable all, or a list of
tool name symbols to enable specific tools.")

(defvar-local ogent-project-system-prompt nil
  "Project-specific system prompt addition.
This text is prepended to the system prompt for all sessions
in this project.")

;;; Project Root Detection

(defvar ogent-presets--project-cache (make-hash-table :test 'equal)
  "Cache mapping directory paths to their project roots.")

(defun ogent-presets-project-root (&optional dir)
  "Return the project root for DIR (default: `default-directory').
Uses projectile if available, falls back to project.el, then
searches for .ogent.el or common project markers."
  (let ((directory (or dir default-directory)))
    (or
     ;; Check cache first
     (gethash directory ogent-presets--project-cache)
     ;; Compute and cache
     (let ((root
            (or
             ;; Try projectile first (if available and has root)
             (when (and (fboundp 'projectile-project-root)
                        (bound-and-true-p projectile-mode))
               (ignore-errors (projectile-project-root)))
             ;; Try project.el (built-in since Emacs 28)
             (when (fboundp 'project-current)
               (when-let ((proj (project-current nil directory)))
                 (project-root proj)))
             ;; Look for .ogent.el
             (locate-dominating-file directory ogent-presets-file-name)
             ;; Look for common project markers
             (locate-dominating-file directory ".git")
             (locate-dominating-file directory "package.json")
             (locate-dominating-file directory "Cargo.toml")
             (locate-dominating-file directory "pyproject.toml")
             (locate-dominating-file directory "Makefile")
             ;; Last resort
             directory)))
       (puthash directory root ogent-presets--project-cache)
       root))))

(defun ogent-presets-clear-cache ()
  "Clear the project root cache."
  (interactive)
  (clrhash ogent-presets--project-cache)
  (message "Cleared ogent presets cache"))

;;; .ogent.el File Loading

(defvar ogent-presets--loaded-projects (make-hash-table :test 'equal)
  "Hash table tracking which projects have had their .ogent.el loaded.
Keys are project root directories, values are the load timestamp.")

(defconst ogent-presets--allowed-variables
  '(ogent-project-model
    ogent-project-model-roles
    ogent-project-preset
    ogent-project-context-files
    ogent-project-codemap-roots
    ogent-project-prompts
    ogent-project-tools
    ogent-project-system-prompt)
  "List of variables that can be set via .ogent.el files.
This is a safety measure to prevent arbitrary code execution.")

(defun ogent-presets--safe-read (file)
  "Safely read the .ogent.el FILE, returning an alist or nil.
Only allows known ogent variables to be set."
  (condition-case err
      (with-temp-buffer
        (insert-file-contents file)
        (let ((form (read (current-buffer))))
          (if (and (listp form)
                   (cl-every (lambda (entry)
                               (and (consp entry)
                                    (memq (car entry) ogent-presets--allowed-variables)))
                             form))
              form
            (message "Warning: Invalid .ogent.el format in %s" file)
            nil)))
    (error
     (message "Error reading %s: %s" file (error-message-string err))
     nil)))

(defun ogent-presets--apply-settings (settings)
  "Apply SETTINGS alist to buffer-local variables."
  (dolist (setting settings)
    (let ((var (car setting))
          (val (cdr setting)))
      (when (memq var ogent-presets--allowed-variables)
        (set (make-local-variable var) val)))))

(defun ogent-presets--register-prompts ()
  "Register project-specific templates from `ogent-project-prompts'."
  (when (and ogent-project-prompts
             (fboundp 'ogent-prompt-register))
    (dolist (entry ogent-project-prompts)
      (let ((id (car entry))
            (content (cdr entry)))
        (ogent-prompt-register id
                               :title (format "Project: %s" id)
                               :content content
                               :compose-order 100)))))

(defun ogent-presets--auto-pin-files ()
  "Automatically pin context files if configured."
  (when (and ogent-presets-auto-pin-docs
             ogent-project-context-files
             (fboundp 'ogent-pin-file))
    (let ((root (ogent-presets-project-root)))
      (dolist (file ogent-project-context-files)
        (let ((path (expand-file-name file root)))
          (when (file-readable-p path)
            (ogent-pin-file path)))))))

(defun ogent-presets-load (&optional force)
  "Load project presets for the current buffer.
If FORCE is non-nil, reload even if already loaded for this project."
  (interactive "P")
  (let* ((root (ogent-presets-project-root))
         (preset-file (when root
                        (expand-file-name ogent-presets-file-name root))))
    (when (and preset-file (file-readable-p preset-file))
      (let ((already-loaded (gethash root ogent-presets--loaded-projects)))
        (when (or force (not already-loaded))
          (let ((settings (ogent-presets--safe-read preset-file)))
            (when settings
              (ogent-presets--apply-settings settings)
              (ogent-presets--register-prompts)
              (ogent-presets--auto-pin-files)
              (puthash root (current-time) ogent-presets--loaded-projects)
              (when (called-interactively-p 'interactive)
                (message "Loaded ogent presets from %s" preset-file)))))))))

;;; Buffer Switch Hook

(defun ogent-presets--on-buffer-switch ()
  "Hook function to load project presets on buffer switch."
  (when (and ogent-presets-auto-load
             (buffer-file-name))
    (ogent-presets-load)))

;;; Interactive Configuration

(defun ogent-presets-effective-model ()
  "Return the effective model ID for the current buffer.
Checks project setting first, then falls back to global default."
  (or ogent-project-model
      (when (boundp 'ogent-default-model)
        ogent-default-model)))

(defun ogent-presets-effective-preset ()
  "Return the effective preset symbol for the current buffer."
  ogent-project-preset)

(defun ogent-presets-effective-codemap-roots ()
  "Return the effective codemap directories for the current project.
Returns project-specific roots if set, otherwise the global default."
  (or ogent-project-codemap-roots
      (when (boundp 'ogent-codemap-source-directories)
        ogent-codemap-source-directories)))

(defun ogent-presets-effective-tools ()
  "Return the effective tools configuration for the current buffer."
  (if (local-variable-p 'ogent-project-tools)
      ogent-project-tools
    (when (boundp 'ogent-tools-enabled)
      ogent-tools-enabled)))

;;;###autoload
(defun ogent-presets-configure ()
  "Interactively configure ogent presets for the current project.
Creates or updates the .ogent.el file in the project root."
  (interactive)
  (let* ((root (ogent-presets-project-root))
         (preset-file (expand-file-name ogent-presets-file-name root))
         (existing (when (file-exists-p preset-file)
                     (ogent-presets--safe-read preset-file)))
         (settings (copy-alist existing)))

    ;; Model selection
    (when-let ((model-ids (when (fboundp 'ogent-models-ids)
                            (ogent-models-ids))))
      (let* ((current (or (cdr (assq 'ogent-project-model settings)) ""))
             (choice (completing-read
                      (format "Model (current: %s): " (if (string-empty-p current) "default" current))
                      (cons "" model-ids) nil nil nil nil current)))
        (if (string-empty-p choice)
            (setq settings (assq-delete-all 'ogent-project-model settings))
          (setf (alist-get 'ogent-project-model settings) choice))))

    ;; Preset selection
    (when-let ((preset-names (when (fboundp 'ogent-presets-available)
                               (ogent-presets-available))))
      (let* ((current (or (cdr (assq 'ogent-project-preset settings)) ""))
             (current-str (if (symbolp current) (symbol-name current) current))
             (choice (completing-read
                      (format "Preset (current: %s): " (if (string-empty-p current-str) "none" current-str))
                      (cons "" preset-names) nil nil nil nil current-str)))
        (if (string-empty-p choice)
            (setq settings (assq-delete-all 'ogent-project-preset settings))
          (setf (alist-get 'ogent-project-preset settings) (intern choice)))))

    ;; Context files
    (let* ((current (cdr (assq 'ogent-project-context-files settings)))
           (current-str (mapconcat #'identity (or current '()) ", "))
           (input (read-string
                   (format "Context files (comma-sep, current: %s): "
                           (if (string-empty-p current-str) "none" current-str))
                   nil nil current-str)))
      (if (string-empty-p input)
          (setq settings (assq-delete-all 'ogent-project-context-files settings))
        (let ((files (mapcar #'string-trim (split-string input "," t))))
          (setf (alist-get 'ogent-project-context-files settings) files))))

    ;; Codemap roots
    (let* ((current (cdr (assq 'ogent-project-codemap-roots settings)))
           (current-str (mapconcat #'identity (or current '()) ", "))
           (input (read-string
                   (format "Codemap dirs (comma-sep, current: %s): "
                           (if (string-empty-p current-str) "default" current-str))
                   nil nil current-str)))
      (if (string-empty-p input)
          (setq settings (assq-delete-all 'ogent-project-codemap-roots settings))
        (let ((dirs (mapcar #'string-trim (split-string input "," t))))
          (setf (alist-get 'ogent-project-codemap-roots settings) dirs))))

    ;; Write the file
    (with-temp-file preset-file
      (insert ";; -*- mode: emacs-lisp -*-\n")
      (insert ";; ogent project configuration\n")
      (insert ";; See (info \"(ogent) Project Presets\") for documentation\n\n")
      (pp settings (current-buffer)))

    (message "Saved ogent presets to %s" preset-file)

    ;; Reload settings
    (ogent-presets-load t)))

;;;###autoload
(defun ogent-presets-show ()
  "Display the effective ogent settings for the current buffer."
  (interactive)
  (let ((root (ogent-presets-project-root))
        (model (ogent-presets-effective-model))
        (preset (ogent-presets-effective-preset))
        (context-files ogent-project-context-files)
        (codemap-roots (ogent-presets-effective-codemap-roots))
        (prompts ogent-project-prompts)
        (tools (ogent-presets-effective-tools))
        (system-prompt ogent-project-system-prompt))
    (with-help-window "*ogent-presets*"
      (princ "Ogent Project Settings\n")
      (princ "======================\n\n")
      (princ (format "Project Root: %s\n" (or root "(none)")))
      (princ (format "Config File:  %s\n\n"
                     (if root
                         (let ((f (expand-file-name ogent-presets-file-name root)))
                           (if (file-exists-p f) f "(not found)"))
                       "(n/a)")))
      (princ "Effective Settings:\n")
      (princ (format "  Model:          %s\n" (or model "(default)")))
      (princ (format "  Preset:         %s\n" (or preset "(none)")))
      (princ (format "  Context Files:  %s\n"
                     (if context-files
                         (mapconcat #'identity context-files ", ")
                       "(none)")))
      (princ (format "  Codemap Roots:  %s\n"
                     (if codemap-roots
                         (mapconcat #'identity codemap-roots ", ")
                       "(default)")))
      (princ (format "  Tools:          %s\n"
                     (cond
                      ((eq tools t) "all")
                      ((null tools) "none")
                      ((listp tools) (mapconcat #'symbol-name tools ", "))
                      (t (format "%s" tools)))))
      (when prompts
        (princ "\n  Project Prompts:\n")
        (dolist (p prompts)
          (princ (format "    - %s\n" (car p)))))
      (when system-prompt
        (princ (format "\n  System Prompt:\n    %s\n"
                       (truncate-string-to-width system-prompt 60 nil nil "...")))))))

;;; Context Inclusion

;;;###autoload
(defun ogent-presets-include-context ()
  "Include project context files in the current request.
Reads files listed in `ogent-project-context-files' and returns
their contents as a formatted string suitable for inclusion."
  (when ogent-project-context-files
    (let ((root (ogent-presets-project-root))
          (contents nil))
      (dolist (file ogent-project-context-files)
        (let ((path (expand-file-name file root)))
          (when (file-readable-p path)
            (push (format "--- %s ---\n%s"
                          file
                          (with-temp-buffer
                            (insert-file-contents path)
                            (buffer-string)))
                  contents))))
      (when contents
        (mapconcat #'identity (nreverse contents) "\n\n")))))

;;; Mode Setup

;;;###autoload
(define-minor-mode ogent-presets-mode
  "Minor mode to enable automatic project preset loading.
When enabled, ogent will automatically detect and apply project-specific
settings from .ogent.el files when switching buffers."
  :global t
  :lighter " OgPresets"
  (if ogent-presets-mode
      (add-hook 'buffer-list-update-hook #'ogent-presets--on-buffer-switch)
    (remove-hook 'buffer-list-update-hook #'ogent-presets--on-buffer-switch)))

(provide 'ogent-presets)

;;; ogent-presets.el ends here
