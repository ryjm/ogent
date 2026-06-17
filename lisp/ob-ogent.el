;;; ob-ogent.el --- Org Babel backend for ogent prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; Makes an ogent prompt an executable Org Babel source block.  A block
;; like:
;;
;;   #+begin_src ogent :model gpt-5.5 :context "@plan.org" :var topic="x"
;;   Summarize ${topic} using the attached plan.
;;   #+end_src
;;
;; runs on C-c C-c: the body (with ${var} placeholders expanded and any
;; resolved @context prepended) is sent synchronously to the model, and
;; the response lands in #+RESULTS.  This turns any Org buffer into a live
;; LLM notebook whose prompts are reproducible, parameterizable, and
;; cacheable like any other src block.
;;
;; Header arguments:
;;   :model    Model id from `ogent-model-registry' (default `ogent-default-model').
;;   :system   System prompt string.
;;   :context  Space/comma-separated @handles to resolve and prepend.
;;   :var      Standard Babel vars; `${name}' in the body is replaced by the value.
;;
;; The request is synchronous (Babel returns a value), so streaming and
;; tool use are disabled for the call.

;;; Code:

(require 'ob)
(require 'subr-x)
(require 'ogent-models)
(require 'ogent-gptel)

(declare-function gptel-request "ext:gptel-request")
(declare-function ogent-context--dependency "ogent-context" (handle))
;; cl-defstruct accessor (fileonly: generated, not a top-level defun)
(declare-function ogent-context-node-content "ogent-context" t t)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-stream)
(defvar gptel-use-tools)
(defvar gptel--system-message)

(defgroup ob-ogent nil
  "Org Babel backend for ogent prompts."
  :group 'ogent
  :prefix "ob-ogent-")

(defcustom ob-ogent-timeout 120
  "Seconds to wait for a synchronous ogent Babel response before erroring."
  :type 'integer
  :group 'ob-ogent)

(defvar org-babel-default-header-args:ogent
  '((:results . "replace") (:exports . "both"))
  "Default header arguments for ogent source blocks.")

(defun ob-ogent--expand-vars (body vars)
  "Return BODY with each `${name}' replaced by its VARS value.
VARS is the alist Babel passes for :var bindings."
  (let ((result body))
    (dolist (pair vars result)
      (let ((name (car pair))
            (value (cdr pair)))
        (when name
          (setq result
                (replace-regexp-in-string
                 (regexp-quote (format "${%s}" name))
                 (format "%s" value)
                 result t t)))))))

(defun ob-ogent--handle-list (context-arg)
  "Return a list of handle strings from CONTEXT-ARG.
CONTEXT-ARG is the raw :context header value; handles may be
space- or comma-separated and may carry a leading @."
  (when (and context-arg (not (string-empty-p (format "%s" context-arg))))
    (let ((tokens (split-string (format "%s" context-arg) "[ ,]+" t)))
      (mapcar (lambda (tok) (string-remove-prefix "@" tok)) tokens))))

(defun ob-ogent--resolve-context (handles)
  "Return a preamble string for HANDLES, or nil when none resolve.
Each handle is resolved through ogent's context machinery; missing
handles are noted so the prompt stays honest about what was found."
  (when handles
    (require 'ogent-context)
    (let (sections)
      (dolist (handle handles)
        (let* ((dep (ogent-context--dependency handle))
               (node (plist-get dep :node)))
          (if (and node (not (plist-get dep :missing-p)))
              (push (format "## @%s\n%s" handle
                            (ogent-context-node-content node))
                    sections)
            (push (format "## @%s\n(unresolved)" handle) sections))))
      (when sections
        (concat "# Context\n"
                (string-join (nreverse sections) "\n\n")
                "\n\n# Prompt\n")))))

(defun ob-ogent--request-sync (model-id system prompt)
  "Send PROMPT to MODEL-ID with optional SYSTEM, returning the response.
Blocks up to `ob-ogent-timeout' seconds.  Signals a user error on
timeout or an error response."
  (require 'gptel)
  (let* ((model (ogent-models-ensure model-id))
         (backend (ogent-gptel-resolve-backend model))
         (done nil) (result nil) (failure nil)
         (gptel-backend backend)
         (gptel-model model-id)
         (gptel-stream nil)
         (gptel-use-tools nil))
    (unless backend
      (user-error "Ob-ogent: no backend for model %s" model-id))
    (gptel-request prompt
                   :system (or system gptel--system-message)
                   :stream nil
                   :callback
                   (lambda (response info)
                     (setq done t)
                     (if (stringp response)
                         (setq result response)
                       (setq failure
                             (or (plist-get info :error)
                                 (plist-get info :status)
                                 "no response")))))
    (let ((deadline (+ (float-time) ob-ogent-timeout)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.1)))
    (cond
     ((not done)
      (user-error "Ob-ogent: request timed out after %ds" ob-ogent-timeout))
     (failure (user-error "Ob-ogent: %s" failure))
     (t (string-trim (or result ""))))))

;;;###autoload
(defun org-babel-execute:ogent (body params)
  "Execute an ogent prompt BODY with Babel PARAMS, returning the response.
Expands `${var}' placeholders, prepends any resolved :context, and
sends the result synchronously to the model named by :model."
  (let* ((model-id (or (cdr (assq :model params)) ogent-default-model))
         (system (cdr (assq :system params)))
         (vars (org-babel--get-vars params))
         (context-preamble
          (ob-ogent--resolve-context
           (ob-ogent--handle-list (cdr (assq :context params)))))
         (expanded (ob-ogent--expand-vars body vars))
         (prompt (if context-preamble
                     (concat context-preamble expanded)
                   expanded)))
    (when (string-empty-p (string-trim expanded))
      (user-error "Ob-ogent: empty prompt"))
    (ob-ogent--request-sync (format "%s" model-id) system prompt)))

(provide 'ob-ogent)

;;; ob-ogent.el ends here
