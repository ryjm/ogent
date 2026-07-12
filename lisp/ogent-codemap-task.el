;;; ogent-codemap-task.el --- Task-scoped LLM codemap for ogent -*- lexical-binding: t; -*-

;;; Commentary:
;; Generate intelligent, task-focused codemaps using LLM analysis.  These
;; codemaps are scoped to a specific question/task and identify relevant files,
;; functions, and data flows.

;;; Code:

(require 'org)
(require 'seq)
(require 'subr-x)
(require 'ogent-codemap)
(require 'ogent-models)
(require 'ogent-gptel)

(declare-function gptel-request "ext:gptel-request")
(defvar gptel-model)
(defvar gptel-backend)

(defcustom ogent-codemap-llm-model nil
  "Model to use for codemap generation.
nil resolves the `codemap' entry of `ogent-model-roles', falling
back to `ogent-default-model'."
  :type '(choice (const :tag "Use the codemap model role" nil)
                 (string :tag "Model identifier"))
  :group 'ogent)

(defcustom ogent-codemap-cache-directory
  (expand-file-name "codemap-cache" user-emacs-directory)
  "Directory for storing cached task codemaps."
  :type 'directory
  :group 'ogent)

(defcustom ogent-codemap-cache-ttl 3600
  "Time-to-live for cached codemaps in seconds."
  :type 'integer
  :group 'ogent)

(defvar ogent-codemap--task-cache (make-hash-table :test 'equal)
  "In-memory cache for task codemaps.
Keys are (task-hash . file-hash), values are plists with
:content and :timestamp.")

(defvar ogent-codemap--pending-requests (make-hash-table :test 'equal)
  "Track pending LLM requests by task hash to avoid duplicates.")

(defvar ogent-codemap--task-handles (make-hash-table :test 'equal)
  "Registry of task handles to their generated content.
Keys are handle strings, values are content strings or nil if pending.")

;;; Task Hash Generation

(defun ogent-codemap--task-hash (task)
  "Generate a hash for TASK string."
  (md5 (downcase (string-trim task))))

(defun ogent-codemap--files-hash ()
  "Generate a hash of all source file modification times.
Used to invalidate cache when files change."
  (let ((files (ogent-codemap--source-files))
        (mtimes nil))
    (dolist (file files)
      (when-let ((attrs (file-attributes file)))
        (push (format "%s:%s" file (file-attribute-modification-time attrs))
              mtimes)))
    (md5 (string-join (sort mtimes #'string<) "\n"))))

(defun ogent-codemap--cache-key (task)
  "Generate cache key for TASK."
  (let ((task-hash (ogent-codemap--task-hash task))
        (files-hash (ogent-codemap--files-hash)))
    (format "%s:%s" task-hash (substring files-hash 0 8))))

;;; Cache Management

(defun ogent-codemap--cache-get (cache-key)
  "Get cached codemap for CACHE-KEY if valid."
  (when-let ((entry (gethash cache-key ogent-codemap--task-cache)))
    (let ((timestamp (plist-get entry :timestamp))
          (now (float-time)))
      (when (< (- now timestamp) ogent-codemap-cache-ttl)
        (plist-get entry :content)))))

(defun ogent-codemap--cache-put (cache-key content)
  "Store CONTENT in cache with CACHE-KEY."
  (puthash cache-key
           (list :content content :timestamp (float-time))
           ogent-codemap--task-cache))

(defun ogent-codemap-clear-task-cache ()
  "Clear the task codemap cache."
  (interactive)
  (clrhash ogent-codemap--task-cache)
  (clrhash ogent-codemap--task-handles)
  (message "Task codemap cache cleared"))

;;; File Summary Generation

(defun ogent-codemap--file-summary (file)
  "Generate a brief summary of FILE for the LLM prompt."
  (let* ((root (ogent-codemap--project-root))
         (relative (file-relative-name file root))
         (file-type (ogent-codemap--file-type file)))
    (pcase file-type
      ('elisp
       (let ((defs (ogent-codemap--get-cached-or-scan file 'elisp)))
         (format "- %s (elisp): %s"
                 relative
                 (if defs
                     (string-join (seq-take defs 5) ", ")
                   "no ogent- functions"))))
      ('elisp-test
       (let ((tests (ogent-codemap--get-cached-or-scan file 'elisp-test)))
         (format "- %s (test): %d tests"
                 relative
                 (length tests))))
      ('org
       (format "- %s (org doc)" relative))
      ('markdown
       (format "- %s (markdown doc)" relative))
      (_ (format "- %s" relative)))))

(defun ogent-codemap--all-file-summaries ()
  "Generate summaries for all project files."
  (let ((files (ogent-codemap--source-files)))
    (mapconcat #'ogent-codemap--file-summary files "\n")))

;;; LLM Prompt Construction

(defconst ogent-codemap--system-prompt
  "You are a code analysis assistant. Given a task and a list of project files,
identify which files and functions are most relevant to the task.

Output format: Org-mode with the following structure:

* Codemap: <brief task summary>
** Overview
<1-2 sentence summary of how the task relates to the codebase>

** Key Files
List the most relevant files with brief explanations:
*** [[file:path/to/file.el][filename.el]]
Why this file is relevant to the task.

** Key Functions
List the most important functions:
*** [[file:path/to/file.el::function-name][function-name]]
Brief description of what it does and why it matters for this task.

** Data Flow
If relevant, describe how data flows through the system for this task.

** Dependencies
Note any important dependencies or related components.

Rules:
- Only include genuinely relevant files (aim for 3-7 key files)
- Use Org file: links for navigation
- Keep descriptions concise (1-2 sentences each)
- Focus on the \"why\" - how each item relates to the task"
  "System prompt for codemap generation.")

(defun ogent-codemap--build-prompt (task)
  "Build the LLM prompt for TASK."
  (let ((file-summaries (ogent-codemap--all-file-summaries)))
    (format "Task: %s

Project files:
%s

Generate a task-focused codemap identifying the most relevant files and functions for this task."
            task file-summaries)))

;;; LLM Request

(defun ogent-codemap--generate-async (task callback)
  "Generate codemap for TASK asynchronously, calling CALLBACK with result.
CALLBACK receives (content error) where error is nil on success."
  (if (not (require 'gptel nil 'noerror))
      (funcall callback nil "gptel is required for LLM codemap generation")
    (let* ((cache-key (ogent-codemap--cache-key task))
           (cached (ogent-codemap--cache-get cache-key)))
      (if cached
          (funcall callback cached nil)
        (if (gethash cache-key ogent-codemap--pending-requests)
            (funcall callback nil "Request already pending for this task")
          (puthash cache-key t ogent-codemap--pending-requests)
          (let* ((prompt (ogent-codemap--build-prompt task))
                 (accumulated "")
                 ;; Resolve the codemap model: explicit override first,
                 ;; then the `codemap' role (Org property aware).
                 (model (if ogent-codemap-llm-model
                            (ogent-models-ensure ogent-codemap-llm-model)
                          (ogent-models-effective-model 'codemap)))
                 (backend (ogent-gptel-resolve-backend model))
                 (gptel-backend (or backend gptel-backend))
                 (gptel-model (plist-get model :id)))
            (when backend
              (ogent-gptel-ensure-model-on-backend model backend)
              (ogent-models-apply-gptel-props model))
            (gptel-request prompt
                           :system ogent-codemap--system-prompt
                           :stream t
                           :callback
                           (lambda (text info)
                             (cond
                              ((and (listp info) (plist-get info :error))
                               (remhash cache-key ogent-codemap--pending-requests)
                               (funcall callback nil (plist-get info :error)))
                              ((stringp text)
                               (setq accumulated (concat accumulated text)))
                              ((or (and (listp info)
                                        (or (plist-get info :done)
                                            (plist-get info :final)
                                            (equal (plist-get info :status) "success")))
                                   (and (not (stringp text)) (listp info) info))
                               (remhash cache-key ogent-codemap--pending-requests)
                               (when (> (length accumulated) 0)
                                 (ogent-codemap--cache-put cache-key accumulated))
                               (funcall callback accumulated nil)))))))))))

;;; Interactive Commands

(defvar ogent-codemap--task-buffer-name "*ogent-codemap-task*"
  "Buffer name for task-scoped codemaps.")

(defvar ogent-codemap--current-task nil
  "The current task for which codemap was generated.")

;;;###autoload
(defun ogent-codemap-generate (task)
  "Generate an LLM-powered codemap for TASK.
TASK is a question or description of what you want to understand.
The codemap identifies relevant files, functions, and data flows.

Interactively, prompts for the task description."
  (interactive "sWhat do you want to understand? ")
  (when (string-empty-p (string-trim task))
    (user-error "Task description cannot be empty"))

  (message "Generating codemap for: %s..." (truncate-string-to-width task 50))

  (ogent-codemap--generate-async
   task
   (lambda (content error)
     (if error
         (message "Codemap generation failed: %s" error)
       (ogent-codemap--display-task-codemap task content)))))

(defun ogent-codemap--display-task-codemap (task content)
  "Display CONTENT as the codemap for TASK."
  (let ((buf (get-buffer-create ogent-codemap--task-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (goto-char (point-min))
        (org-mode)
        (setq-local ogent-codemap--current-task task)
        (setq buffer-read-only t)))
    (display-buffer buf '((display-buffer-in-side-window)
                          (side . right)
                          (window-width . 0.4)))
    (message "Codemap generated for: %s" (truncate-string-to-width task 50))))

;;;###autoload
(defun ogent-codemap-regenerate ()
  "Regenerate the codemap for the current task, bypassing cache."
  (interactive)
  (unless ogent-codemap--current-task
    (user-error "No current task codemap to regenerate"))
  (let ((task ogent-codemap--current-task))
    (let ((cache-key (ogent-codemap--cache-key task)))
      (remhash cache-key ogent-codemap--task-cache))
    (clrhash ogent-codemap--task-handles)
    (ogent-codemap-generate task)))

;;; Task Handle Integration

(defun ogent-codemap-task-handle-p (handle)
  "Return non-nil if HANDLE is a task-scoped codemap handle.
Matches @codemap-task:<task-description> pattern."
  (string-match-p "^codemap-task:" handle))

(defun ogent-codemap--extract-task-from-handle (handle)
  "Extract the task description from a codemap-task HANDLE."
  (when (string-match "^codemap-task:\\(.+\\)$" handle)
    (match-string 1 handle)))

(defun ogent-codemap-resolve-task-handle (handle)
  "Resolve a task-scoped codemap HANDLE.
Return cached content when available.  If generation is pending or must be
started, return nil so callers treat the handle as unresolved instead of
sending placeholder text to the model."
  (when (ogent-codemap-task-handle-p handle)
    (let* ((task (ogent-codemap--extract-task-from-handle handle))
           (cache-key (and task (ogent-codemap--cache-key task)))
           (cached (and cache-key (ogent-codemap--cache-get cache-key)))
           (known (gethash handle ogent-codemap--task-handles
                           :ogent-missing)))
      (cond
       (cached cached)
       ((not (eq known :ogent-missing)) nil)
       (task
        (puthash handle nil ogent-codemap--task-handles)
        (ogent-codemap--generate-async
         task
         (lambda (content _error)
           (remhash handle ogent-codemap--task-handles)
           (when (and content cache-key)
             (ogent-codemap--cache-put cache-key content))))
        nil)
       (t nil)))))

;;; Enhanced Handle Resolution

(defun ogent-codemap-resolve-handle-enhanced (handle)
  "Resolve any codemap HANDLE.
Supports:
  @codemap - full static codemap
  @codemap-lisp - only lisp/ section
  @codemap-task:<desc> - LLM-generated task-focused codemap"
  (cond
   ((ogent-codemap-task-handle-p handle)
    (ogent-codemap-resolve-task-handle handle))
   ((ogent-codemap-handle-p handle)
    (ogent-codemap-resolve-handle handle))
   (t nil)))

(provide 'ogent-codemap-task)

;;; ogent-codemap-task.el ends here
