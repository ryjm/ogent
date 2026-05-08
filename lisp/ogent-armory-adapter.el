;;; ogent-armory-adapter.el --- Armory provider adapter registry -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider metadata, invocation planning, verification, and error taxonomy for
;; Org Armory runners.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'ogent-armory-evil)

(defgroup ogent-armory-adapter nil
  "Provider adapters for Org Armory runtimes."
  :group 'ogent-armory
  :prefix "ogent-armory-adapter-")

(defvar ogent-armory-codex-executable)
(defvar ogent-armory-claude-executable)
(defvar ogent-armory-gemini-executable)
(defvar ogent-armory-cursor-executable)
(defvar ogent-armory-opencode-executable)
(defvar ogent-armory-pi-executable)
(defvar ogent-armory-grok-executable)
(defvar ogent-armory-copilot-executable)
(defvar ogent-armory-runner-codex-approval)
(defvar ogent-armory-runner-codex-sandbox)
(defvar ogent-armory-runner-codex-skip-git-repo-check)

(defcustom ogent-armory-adapter-model-list-timeout 5
  "Seconds to wait for a provider CLI model list."
  :type 'number
  :group 'ogent-armory-adapter)

(defconst ogent-armory-adapter-error-kinds
  '(cli-not-found auth-expired rate-limited session-expired context-exceeded
                  transport timeout model-unavailable unknown)
  "Canonical Armory adapter error kinds.")

(defvar ogent-armory-adapter--registry (make-hash-table :test 'equal)
  "Hash table of adapter ids and aliases to adapter plists.")

(defvar ogent-armory-adapter--ids nil
  "Canonical adapter ids in registration order.")

(defvar ogent-armory-providers-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-armory-providers-refresh)
    (define-key map (kbd "C-c g") #'ogent-armory-providers-refresh)
    (define-key map "v" #'ogent-armory-provider-verify)
    (define-key map (kbd "C-c v") #'ogent-armory-provider-verify)
    (define-key map (kbd "RET") #'ogent-armory-provider-verify)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-armory-providers-mode'.")

(define-derived-mode ogent-armory-providers-mode tabulated-list-mode
  "Armory-Providers"
  "Major mode for Armory provider adapter status."
  :group 'ogent-armory-adapter
  (setq-local tabulated-list-format
              [("Adapter" 18 t)
               ("Name" 18 t)
               ("Executable" 14 t)
               ("Status" 12 t)
               ("Modes" 18 t)
               ("Resume" 8 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-armory-providers-refresh)
  (tabulated-list-init-header))

(defun ogent-armory-adapter--id (value)
  "Return VALUE as a normalized adapter id string."
  (downcase (string-trim (format "%s" value))))

(defun ogent-armory-adapter--symbol-id (value)
  "Return VALUE as a provider symbol."
  (intern (replace-regexp-in-string
           "[^[:alnum:]-]" "-"
           (ogent-armory-adapter--id value))))

(defun ogent-armory-adapter--symbol-value (symbol fallback)
  "Return SYMBOL value when bound, otherwise FALLBACK."
  (if (and symbol (boundp symbol))
      (symbol-value symbol)
    fallback))

(defun ogent-armory-adapter-executable (adapter)
  "Return executable configured for ADAPTER."
  (ogent-armory-adapter--symbol-value
   (plist-get adapter :executable-symbol)
   (plist-get adapter :default-executable)))

(defun ogent-armory-adapter-register (adapter)
  "Register ADAPTER and return it."
  (let ((id (ogent-armory-adapter--id (plist-get adapter :id))))
    (when (string-empty-p id)
      (user-error "Armory adapter requires an id"))
    (setq adapter (plist-put (copy-sequence adapter) :id id))
    (puthash id adapter ogent-armory-adapter--registry)
    (unless (member id ogent-armory-adapter--ids)
      (setq ogent-armory-adapter--ids
            (append ogent-armory-adapter--ids (list id))))
    (dolist (alias (plist-get adapter :aliases))
      (puthash (ogent-armory-adapter--id alias)
               adapter
               ogent-armory-adapter--registry))
    adapter))

(defun ogent-armory-adapter-list ()
  "Return registered Armory adapters."
  (delq
   nil
   (mapcar (lambda (id)
             (gethash id ogent-armory-adapter--registry))
           ogent-armory-adapter--ids)))

(defun ogent-armory-adapter-get (id)
  "Return adapter ID or nil."
  (gethash (ogent-armory-adapter--id id)
           ogent-armory-adapter--registry))

(defun ogent-armory-adapter-require (id)
  "Return adapter ID or signal a user error."
  (or (ogent-armory-adapter-get id)
      (user-error "Unsupported Armory provider adapter: %s" id)))

(defun ogent-armory-adapter-normalize-provider (provider)
  "Return provider symbol for PROVIDER."
  (let ((adapter (ogent-armory-adapter-get
                  (if (or (null provider)
                          (string-empty-p (string-trim (format "%s" provider))))
                      "codex"
                    provider))))
    (if adapter
        (plist-get adapter :provider-symbol)
      (ogent-armory-adapter--symbol-id provider))))

(defun ogent-armory-adapter-resolve-provider (provider)
  "Return registered adapter for PROVIDER."
  (ogent-armory-adapter-require
   (if (or (null provider)
           (string-empty-p (string-trim (format "%s" provider))))
       "codex"
     provider)))

(defun ogent-armory-adapter--append-option (args option value)
  "Append OPTION and VALUE to ARGS when VALUE is nonblank."
  (if (and value (not (string-blank-p (format "%s" value))))
      (append args (list option (format "%s" value)))
    args))

(defun ogent-armory-adapter--codex-invocation (adapter context)
  "Return Codex CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "--ask-for-approval"
                    (ogent-armory-adapter--symbol-value
                     'ogent-armory-runner-codex-approval "on-request")
                    "exec"
                    "--cd" (plist-get context :workspace)
                    "--sandbox"
                    (ogent-armory-adapter--symbol-value
                     'ogent-armory-runner-codex-sandbox "workspace-write"))))
    (when (ogent-armory-adapter--symbol-value
           'ogent-armory-runner-codex-skip-git-repo-check t)
      (setq args (append args (list "--skip-git-repo-check"))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args (append args (list "-"))
          :stdin (plist-get context :prompt))))

(defun ogent-armory-adapter--claude-invocation (adapter context)
  "Return Claude Code invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p"
                    "--permission-mode"
                    (or (plist-get context :permission-mode) "default")
                    "--add-dir"
                    (plist-get context :root))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (setq args (ogent-armory-adapter--append-option
                args "--effort" (plist-get context :effort)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args (append args (list (plist-get context :prompt)))
          :stdin nil)))

(defun ogent-armory-adapter--gemini-invocation (adapter context)
  "Return Gemini CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter--cursor-invocation (adapter context)
  "Return Cursor Agent invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt)
                    "--output-format" "text")))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter--opencode-invocation (adapter context)
  "Return OpenCode invocation for ADAPTER and CONTEXT."
  (let ((args (list "run" (plist-get context :prompt))))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter--copilot-invocation (adapter context)
  "Return GitHub Copilot CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt) "--allow-all")))
    (setq args (ogent-armory-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-armory-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-armory-adapter-build-invocation (adapter context)
  "Return process invocation for ADAPTER with CONTEXT."
  (let ((builder (plist-get adapter :build-invocation)))
    (unless builder
      (user-error "Armory adapter has no runnable invocation: %s"
                  (plist-get adapter :id)))
    (append
     (list :adapter-id (plist-get adapter :id)
           :provider (plist-get adapter :provider-symbol)
           :runtime-mode (or (plist-get context :runtime-mode) 'native))
     (funcall builder adapter context))))

(defun ogent-armory-adapter-skill-mounts (adapter skills)
  "Return adapter-native skill mounts for ADAPTER and SKILLS."
  (when-let ((mount (plist-get adapter :skill-mount-function)))
    (funcall mount adapter skills)))

(defun ogent-armory-adapter--normalize-models (models)
  "Return normalized model ids from MODELS."
  (seq-filter
   (lambda (model)
     (not (string-blank-p model)))
   (delete-dups
    (mapcar
     (lambda (model)
       (string-trim
        (format "%s"
                (cond
                 ((stringp model) model)
                 ((and (listp model) (plist-get model :id))
                  (plist-get model :id))
                 ((and (listp model) (alist-get 'id model))
                  (alist-get 'id model))
                 (t model)))))
     models))))

(defun ogent-armory-adapter-models (adapter)
  "Return model ids for ADAPTER.
Provider-specific model list functions are preferred, with static adapter
metadata as the fallback completion list."
  (let* ((static (ogent-armory-adapter--normalize-models
                  (plist-get adapter :models)))
         (dynamic nil)
         (list-function (plist-get adapter :model-list-function)))
    (when list-function
      (setq dynamic
            (condition-case err
                (ogent-armory-adapter--normalize-models
                 (funcall list-function adapter))
              (error
               (message "Armory model listing failed for %s: %s"
                        (plist-get adapter :id)
                        (error-message-string err))
               nil))))
    (or dynamic static)))

(defun ogent-armory-adapter--call-lines (program args)
  "Return output lines from PROGRAM ARGS, or nil when unavailable."
  (when-let ((path (and program (executable-find program))))
    (with-timeout (ogent-armory-adapter-model-list-timeout nil)
      (with-temp-buffer
        (let ((status (apply #'call-process path nil t nil args)))
          (when (zerop status)
            (split-string (buffer-string) "\n" t "[[:space:]\r]+")))))))

(defun ogent-armory-adapter--opencode-models (adapter)
  "Return current OpenCode model ids for ADAPTER."
  (ogent-armory-adapter--call-lines
   (ogent-armory-adapter-executable adapter)
   '("models")))

(defun ogent-armory-adapter-classify-error (_adapter text &optional exit-status)
  "Classify adapter error TEXT and EXIT-STATUS."
  (let* ((raw (or text ""))
         (lower (downcase raw))
         (kind
          (cond
           ((or (not (null (and exit-status (= exit-status 127))))
                (string-match-p "command not found\\|no such file\\|executable"
                                lower))
            'cli-not-found)
           ((string-match-p "auth\\|login\\|credential\\|api key\\|unauthorized"
                            lower)
            'auth-expired)
           ((string-match-p "rate limit\\|too many requests\\|quota" lower)
            'rate-limited)
           ((string-match-p "session .*expired\\|session .*not found\\|resume"
                            lower)
            'session-expired)
           ((string-match-p "context\\|token limit\\|maximum.*tokens" lower)
            'context-exceeded)
           ((string-match-p "timed out\\|timeout" lower)
            'timeout)
           ((string-match-p "model .*unavailable\\|unknown model\\|model not found"
                            lower)
            'model-unavailable)
           ((string-match-p "network\\|transport\\|econn\\|connection" lower)
            'transport)
           (t 'unknown))))
    (list :kind kind
          :message (string-trim raw)
          :exit-status exit-status)))

(defun ogent-armory-adapter-test-environment (adapter)
  "Return environment status for ADAPTER."
  (let* ((program (ogent-armory-adapter-executable adapter))
         (path (and program (executable-find program))))
    (list :adapter-id (plist-get adapter :id)
          :program program
          :path path
          :available (not (null path))
          :status (if path "available" "missing"))))

(defun ogent-armory-adapter-runtime-candidates ()
  "Return completion candidates for adapter runtime choices."
  (apply
   #'append
   (mapcar
    (lambda (adapter)
      (mapcar
       (lambda (mode)
         (let ((label (format "%s / %s"
                              (plist-get adapter :name)
                              mode)))
           (cons label (list :adapter-id (plist-get adapter :id)
                             :runtime-mode mode))))
       (plist-get adapter :runtime-modes)))
    (ogent-armory-adapter-list))))

(defun ogent-armory-runtime-picker (&optional prompt)
  "Read and return a Armory runtime candidate."
  (interactive)
  (let* ((candidates (ogent-armory-adapter-runtime-candidates))
         (choice (completing-read (or prompt "Runtime: ")
                                  (mapcar #'car candidates)
                                  nil t)))
    (cdr (assoc choice candidates))))

(defun ogent-armory-providers--entry (adapter)
  "Return a tabulated entry for ADAPTER."
  (let* ((status (ogent-armory-adapter-test-environment adapter))
         (program (plist-get status :program)))
    (list
     adapter
     (vector
      (plist-get adapter :id)
      (plist-get adapter :name)
      (or program "")
      (plist-get status :status)
      (string-join (mapcar #'symbol-name
                           (plist-get adapter :runtime-modes))
                   ",")
      (if (plist-get adapter :supports-session-resume) "yes" "no")))))

(defun ogent-armory-providers--entries ()
  "Return provider status entries."
  (mapcar #'ogent-armory-providers--entry
          (ogent-armory-adapter-list)))

;;;###autoload
(defun ogent-armory-providers ()
  "Open Armory provider adapter status."
  (interactive)
  (let ((buffer (get-buffer-create "*ogent-armory-providers*")))
    (with-current-buffer buffer
      (ogent-armory-providers-mode)
      (setq tabulated-list-entries #'ogent-armory-providers--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-armory-providers-refresh (&rest _)
  "Refresh Armory provider status."
  (interactive)
  (tabulated-list-print t))

;;;###autoload
(defun ogent-armory-provider-verify (&optional adapter-id)
  "Verify ADAPTER-ID or the provider at point."
  (interactive)
  (let* ((adapter (or (and adapter-id
                           (ogent-armory-adapter-require adapter-id))
                      (tabulated-list-get-id)
                      (ogent-armory-adapter-require
                       (completing-read
                        "Provider: "
                        (mapcar (lambda (adapter)
                                  (plist-get adapter :id))
                                (ogent-armory-adapter-list))
                        nil t))))
         (status (ogent-armory-adapter-test-environment adapter)))
    (message "%s: %s%s"
             (plist-get adapter :name)
             (plist-get status :status)
             (if-let ((path (plist-get status :path)))
                 (format " (%s)" path)
               ""))
    status))

(defun ogent-armory-adapter--builtin ()
  "Register built-in Armory adapters."
  (setq ogent-armory-adapter--registry (make-hash-table :test 'equal))
  (setq ogent-armory-adapter--ids nil)
  (dolist
      (adapter
       `((:id "codex-cli"
          :provider-symbol codex
          :adapter-type "codex_local"
          :name "Codex CLI"
          :aliases ("codex" "codex-cli" "openai-codex" "codex_local")
          :default-executable "codex"
          :executable-symbol ogent-armory-codex-executable
          :models ("gpt-5.5" "gpt-5.4" "gpt-5.3-codex")
          :effort-levels ("low" "medium" "high" "xhigh")
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-armory-adapter--codex-invocation)
         (:id "claude-code"
          :provider-symbol claude
          :adapter-type "claude_local"
          :name "Claude Code"
          :aliases ("claude" "claude-code" "anthropic" "anthropic-claude"
                    "claude_local")
          :default-executable "claude"
          :executable-symbol ogent-armory-claude-executable
          :models ("sonnet" "opus")
          :effort-levels ("low" "medium" "high" "xhigh" "max")
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-armory-adapter--claude-invocation)
         (:id "gemini-cli"
          :provider-symbol gemini
          :adapter-type "gemini_local"
          :name "Gemini CLI"
          :aliases ("gemini" "gemini-cli" "google-gemini" "gemini_local")
          :default-executable "gemini"
          :executable-symbol ogent-armory-gemini-executable
          :models ("auto" "gemini-3-pro" "gemini-2.5-pro")
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-armory-adapter--gemini-invocation)
         (:id "cursor-cli"
          :provider-symbol cursor
          :adapter-type "cursor_local"
          :name "Cursor Agent"
          :aliases ("cursor" "cursor-cli" "cursor-agent" "cursor_local")
          :default-executable "cursor-agent"
          :executable-symbol ogent-armory-cursor-executable
          :models ("auto" "gpt-5" "claude-4.5-sonnet")
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-armory-adapter--cursor-invocation)
         (:id "opencode"
          :provider-symbol opencode
          :adapter-type "opencode_local"
          :name "OpenCode"
          :aliases ("opencode" "opencode-cli" "opencode_local")
          :default-executable "opencode"
          :executable-symbol ogent-armory-opencode-executable
          :models nil
          :model-list-function ogent-armory-adapter--opencode-models
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-armory-adapter--opencode-invocation)
         (:id "pi-cli"
          :provider-symbol pi
          :adapter-type "pi_local"
          :name "Pi CLI"
          :aliases ("pi" "pi-cli" "pi_local")
          :default-executable "pi"
          :executable-symbol ogent-armory-pi-executable
          :models nil
          :effort-levels ("brief" "normal" "deep")
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs nil)
         (:id "grok-cli"
          :provider-symbol grok
          :adapter-type "grok_local"
          :name "Grok CLI"
          :aliases ("grok" "grok-cli" "xai" "grok_local")
          :default-executable "grok"
          :executable-symbol ogent-armory-grok-executable
          :models ("grok-4")
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume nil
          :supports-detached-runs nil)
         (:id "copilot-cli"
          :provider-symbol copilot
          :adapter-type "copilot_local"
          :name "GitHub Copilot"
          :aliases ("copilot" "github-copilot" "copilot-cli" "copilot_local")
          :default-executable "copilot"
          :executable-symbol ogent-armory-copilot-executable
          :models ("gpt-5.2-codex" "gpt-5")
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume nil
          :supports-detached-runs t
          :build-invocation ogent-armory-adapter--copilot-invocation)))
    (ogent-armory-adapter-register adapter)))

(ogent-armory-adapter--builtin)

(defun ogent-armory-providers--evil-local-keys ()
  "Install local Evil keys for Armory providers."
  (ogent-armory-evil-install-local-bindings ogent-armory-providers-mode-map))

(defun ogent-armory-providers--setup-evil ()
  "Set up Evil integration for Armory providers."
  (ogent-armory-evil-setup-mode
   'ogent-armory-providers-mode
   ogent-armory-providers-mode-map
   'ogent-armory-providers-mode-hook
   #'ogent-armory-providers--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-armory-providers--setup-evil))

(provide 'ogent-armory-adapter)

;;; ogent-armory-adapter.el ends here
