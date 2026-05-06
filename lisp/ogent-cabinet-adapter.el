;;; ogent-cabinet-adapter.el --- Cabinet provider adapter registry -*- lexical-binding: t; -*-

;;; Commentary:
;; Provider metadata, invocation planning, verification, and error taxonomy for
;; Org Cabinet runners.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'ogent-cabinet-evil)

(defgroup ogent-cabinet-adapter nil
  "Provider adapters for Org Cabinet runtimes."
  :group 'ogent-cabinet
  :prefix "ogent-cabinet-adapter-")

(defvar ogent-cabinet-codex-executable)
(defvar ogent-cabinet-claude-executable)
(defvar ogent-cabinet-gemini-executable)
(defvar ogent-cabinet-cursor-executable)
(defvar ogent-cabinet-opencode-executable)
(defvar ogent-cabinet-pi-executable)
(defvar ogent-cabinet-grok-executable)
(defvar ogent-cabinet-copilot-executable)
(defvar ogent-cabinet-runner-codex-approval)
(defvar ogent-cabinet-runner-codex-sandbox)
(defvar ogent-cabinet-runner-codex-skip-git-repo-check)

(defconst ogent-cabinet-adapter-error-kinds
  '(cli-not-found auth-expired rate-limited session-expired context-exceeded
                  transport timeout model-unavailable unknown)
  "Canonical Cabinet adapter error kinds.")

(defvar ogent-cabinet-adapter--registry (make-hash-table :test 'equal)
  "Hash table of adapter ids and aliases to adapter plists.")

(defvar ogent-cabinet-adapter--ids nil
  "Canonical adapter ids in registration order.")

(defvar ogent-cabinet-providers-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'ogent-cabinet-providers-refresh)
    (define-key map "v" #'ogent-cabinet-provider-verify)
    (define-key map (kbd "RET") #'ogent-cabinet-provider-verify)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `ogent-cabinet-providers-mode'.")

(define-derived-mode ogent-cabinet-providers-mode tabulated-list-mode
  "Cabinet-Providers"
  "Major mode for Cabinet provider adapter status."
  :group 'ogent-cabinet-adapter
  (setq-local tabulated-list-format
              [("Adapter" 18 t)
               ("Name" 18 t)
               ("Executable" 14 t)
               ("Status" 12 t)
               ("Modes" 18 t)
               ("Resume" 8 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local revert-buffer-function #'ogent-cabinet-providers-refresh)
  (tabulated-list-init-header))

(defun ogent-cabinet-adapter--id (value)
  "Return VALUE as a normalized adapter id string."
  (downcase (string-trim (format "%s" value))))

(defun ogent-cabinet-adapter--symbol-id (value)
  "Return VALUE as a provider symbol."
  (intern (replace-regexp-in-string
           "[^[:alnum:]-]" "-"
           (ogent-cabinet-adapter--id value))))

(defun ogent-cabinet-adapter--symbol-value (symbol fallback)
  "Return SYMBOL value when bound, otherwise FALLBACK."
  (if (and symbol (boundp symbol))
      (symbol-value symbol)
    fallback))

(defun ogent-cabinet-adapter-executable (adapter)
  "Return executable configured for ADAPTER."
  (ogent-cabinet-adapter--symbol-value
   (plist-get adapter :executable-symbol)
   (plist-get adapter :default-executable)))

(defun ogent-cabinet-adapter-register (adapter)
  "Register ADAPTER and return it."
  (let ((id (ogent-cabinet-adapter--id (plist-get adapter :id))))
    (when (string-empty-p id)
      (user-error "Cabinet adapter requires an id"))
    (setq adapter (plist-put (copy-sequence adapter) :id id))
    (puthash id adapter ogent-cabinet-adapter--registry)
    (unless (member id ogent-cabinet-adapter--ids)
      (setq ogent-cabinet-adapter--ids
            (append ogent-cabinet-adapter--ids (list id))))
    (dolist (alias (plist-get adapter :aliases))
      (puthash (ogent-cabinet-adapter--id alias)
               adapter
               ogent-cabinet-adapter--registry))
    adapter))

(defun ogent-cabinet-adapter-list ()
  "Return registered Cabinet adapters."
  (delq
   nil
   (mapcar (lambda (id)
             (gethash id ogent-cabinet-adapter--registry))
           ogent-cabinet-adapter--ids)))

(defun ogent-cabinet-adapter-get (id)
  "Return adapter ID or nil."
  (gethash (ogent-cabinet-adapter--id id)
           ogent-cabinet-adapter--registry))

(defun ogent-cabinet-adapter-require (id)
  "Return adapter ID or signal a user error."
  (or (ogent-cabinet-adapter-get id)
      (user-error "Unsupported Cabinet provider adapter: %s" id)))

(defun ogent-cabinet-adapter-normalize-provider (provider)
  "Return provider symbol for PROVIDER."
  (let ((adapter (ogent-cabinet-adapter-get
                  (if (or (null provider)
                          (string-empty-p (string-trim (format "%s" provider))))
                      "codex"
                    provider))))
    (if adapter
        (plist-get adapter :provider-symbol)
      (ogent-cabinet-adapter--symbol-id provider))))

(defun ogent-cabinet-adapter-resolve-provider (provider)
  "Return registered adapter for PROVIDER."
  (ogent-cabinet-adapter-require
   (if (or (null provider)
           (string-empty-p (string-trim (format "%s" provider))))
       "codex"
     provider)))

(defun ogent-cabinet-adapter--append-option (args option value)
  "Append OPTION and VALUE to ARGS when VALUE is nonblank."
  (if (and value (not (string-blank-p (format "%s" value))))
      (append args (list option (format "%s" value)))
    args))

(defun ogent-cabinet-adapter--codex-invocation (adapter context)
  "Return Codex CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "--ask-for-approval"
                    (ogent-cabinet-adapter--symbol-value
                     'ogent-cabinet-runner-codex-approval "on-request")
                    "exec"
                    "--cd" (plist-get context :workspace)
                    "--sandbox"
                    (ogent-cabinet-adapter--symbol-value
                     'ogent-cabinet-runner-codex-sandbox "workspace-write"))))
    (when (ogent-cabinet-adapter--symbol-value
           'ogent-cabinet-runner-codex-skip-git-repo-check t)
      (setq args (append args (list "--skip-git-repo-check"))))
    (setq args (ogent-cabinet-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-cabinet-adapter-executable adapter)
          :args (append args (list "-"))
          :stdin (plist-get context :prompt))))

(defun ogent-cabinet-adapter--claude-invocation (adapter context)
  "Return Claude Code invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p"
                    "--permission-mode"
                    (or (plist-get context :permission-mode) "default")
                    "--add-dir"
                    (plist-get context :root))))
    (setq args (ogent-cabinet-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-cabinet-adapter-executable adapter)
          :args (append args (list (plist-get context :prompt)))
          :stdin nil)))

(defun ogent-cabinet-adapter--gemini-invocation (adapter context)
  "Return Gemini CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt))))
    (setq args (ogent-cabinet-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-cabinet-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-cabinet-adapter--cursor-invocation (adapter context)
  "Return Cursor Agent invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt)
                    "--output-format" "text")))
    (setq args (ogent-cabinet-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-cabinet-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-cabinet-adapter--opencode-invocation (adapter context)
  "Return OpenCode invocation for ADAPTER and CONTEXT."
  (let ((args (list "run" (plist-get context :prompt))))
    (setq args (ogent-cabinet-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-cabinet-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-cabinet-adapter--copilot-invocation (adapter context)
  "Return GitHub Copilot CLI invocation for ADAPTER and CONTEXT."
  (let ((args (list "-p" (plist-get context :prompt) "--allow-all")))
    (setq args (ogent-cabinet-adapter--append-option
                args "--model" (plist-get context :model)))
    (list :program (ogent-cabinet-adapter-executable adapter)
          :args args
          :stdin nil)))

(defun ogent-cabinet-adapter-build-invocation (adapter context)
  "Return process invocation for ADAPTER with CONTEXT."
  (let ((builder (plist-get adapter :build-invocation)))
    (unless builder
      (user-error "Cabinet adapter has no runnable invocation: %s"
                  (plist-get adapter :id)))
    (append
     (list :adapter-id (plist-get adapter :id)
           :provider (plist-get adapter :provider-symbol)
           :runtime-mode (or (plist-get context :runtime-mode) 'native))
     (funcall builder adapter context))))

(defun ogent-cabinet-adapter-skill-mounts (adapter skills)
  "Return adapter-native skill mounts for ADAPTER and SKILLS."
  (when-let ((mount (plist-get adapter :skill-mount-function)))
    (funcall mount adapter skills)))

(defun ogent-cabinet-adapter-classify-error (_adapter text &optional exit-status)
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

(defun ogent-cabinet-adapter-test-environment (adapter)
  "Return environment status for ADAPTER."
  (let* ((program (ogent-cabinet-adapter-executable adapter))
         (path (and program (executable-find program))))
    (list :adapter-id (plist-get adapter :id)
          :program program
          :path path
          :available (not (null path))
          :status (if path "available" "missing"))))

(defun ogent-cabinet-adapter-runtime-candidates ()
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
    (ogent-cabinet-adapter-list))))

(defun ogent-cabinet-runtime-picker (&optional prompt)
  "Read and return a Cabinet runtime candidate."
  (interactive)
  (let* ((candidates (ogent-cabinet-adapter-runtime-candidates))
         (choice (completing-read (or prompt "Runtime: ")
                                  (mapcar #'car candidates)
                                  nil t)))
    (cdr (assoc choice candidates))))

(defun ogent-cabinet-providers--entry (adapter)
  "Return a tabulated entry for ADAPTER."
  (let* ((status (ogent-cabinet-adapter-test-environment adapter))
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

(defun ogent-cabinet-providers--entries ()
  "Return provider status entries."
  (mapcar #'ogent-cabinet-providers--entry
          (ogent-cabinet-adapter-list)))

;;;###autoload
(defun ogent-cabinet-providers ()
  "Open Cabinet provider adapter status."
  (interactive)
  (let ((buffer (get-buffer-create "*ogent-cabinet-providers*")))
    (with-current-buffer buffer
      (ogent-cabinet-providers-mode)
      (setq tabulated-list-entries #'ogent-cabinet-providers--entries)
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    buffer))

(defun ogent-cabinet-providers-refresh (&rest _)
  "Refresh Cabinet provider status."
  (interactive)
  (tabulated-list-print t))

;;;###autoload
(defun ogent-cabinet-provider-verify (&optional adapter-id)
  "Verify ADAPTER-ID or the provider at point."
  (interactive)
  (let* ((adapter (or (and adapter-id
                           (ogent-cabinet-adapter-require adapter-id))
                      (tabulated-list-get-id)
                      (ogent-cabinet-adapter-require
                       (completing-read
                        "Provider: "
                        (mapcar (lambda (adapter)
                                  (plist-get adapter :id))
                                (ogent-cabinet-adapter-list))
                        nil t))))
         (status (ogent-cabinet-adapter-test-environment adapter)))
    (message "%s: %s%s"
             (plist-get adapter :name)
             (plist-get status :status)
             (if-let ((path (plist-get status :path)))
                 (format " (%s)" path)
               ""))
    status))

(defun ogent-cabinet-adapter--builtin ()
  "Register built-in Cabinet adapters."
  (setq ogent-cabinet-adapter--registry (make-hash-table :test 'equal))
  (setq ogent-cabinet-adapter--ids nil)
  (dolist
      (adapter
       `((:id "codex-cli"
          :provider-symbol codex
          :adapter-type "codex_local"
          :name "Codex CLI"
          :aliases ("codex" "codex-cli" "openai-codex" "codex_local")
          :default-executable "codex"
          :executable-symbol ogent-cabinet-codex-executable
          :models ("gpt-5.5" "gpt-5.4" "gpt-5.3-codex")
          :effort-levels ("low" "medium" "high" "xhigh")
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-cabinet-adapter--codex-invocation)
         (:id "claude-code"
          :provider-symbol claude
          :adapter-type "claude_local"
          :name "Claude Code"
          :aliases ("claude" "claude-code" "anthropic" "anthropic-claude"
                    "claude_local")
          :default-executable "claude"
          :executable-symbol ogent-cabinet-claude-executable
          :models ("sonnet" "opus")
          :effort-levels ("low" "medium" "high" "xhigh" "max")
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-cabinet-adapter--claude-invocation)
         (:id "gemini-cli"
          :provider-symbol gemini
          :adapter-type "gemini_local"
          :name "Gemini CLI"
          :aliases ("gemini" "gemini-cli" "google-gemini" "gemini_local")
          :default-executable "gemini"
          :executable-symbol ogent-cabinet-gemini-executable
          :models ("auto" "gemini-3-pro" "gemini-2.5-pro")
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-cabinet-adapter--gemini-invocation)
         (:id "cursor-cli"
          :provider-symbol cursor
          :adapter-type "cursor_local"
          :name "Cursor Agent"
          :aliases ("cursor" "cursor-cli" "cursor-agent" "cursor_local")
          :default-executable "cursor-agent"
          :executable-symbol ogent-cabinet-cursor-executable
          :models ("auto" "gpt-5" "claude-4.5-sonnet")
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-cabinet-adapter--cursor-invocation)
         (:id "opencode"
          :provider-symbol opencode
          :adapter-type "opencode_local"
          :name "OpenCode"
          :aliases ("opencode" "opencode-cli" "opencode_local")
          :default-executable "opencode"
          :executable-symbol ogent-cabinet-opencode-executable
          :models nil
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume t
          :supports-detached-runs t
          :build-invocation ogent-cabinet-adapter--opencode-invocation)
         (:id "pi-cli"
          :provider-symbol pi
          :adapter-type "pi_local"
          :name "Pi CLI"
          :aliases ("pi" "pi-cli" "pi_local")
          :default-executable "pi"
          :executable-symbol ogent-cabinet-pi-executable
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
          :executable-symbol ogent-cabinet-grok-executable
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
          :executable-symbol ogent-cabinet-copilot-executable
          :models ("gpt-5.2-codex" "gpt-5")
          :effort-levels nil
          :runtime-modes (native terminal)
          :supports-session-resume nil
          :supports-detached-runs t
          :build-invocation ogent-cabinet-adapter--copilot-invocation)))
    (ogent-cabinet-adapter-register adapter)))

(ogent-cabinet-adapter--builtin)

(defun ogent-cabinet-providers--evil-local-keys ()
  "Install local Evil keys for Cabinet providers."
  (ogent-cabinet-evil-install-local-bindings ogent-cabinet-providers-mode-map))

(defun ogent-cabinet-providers--setup-evil ()
  "Set up Evil integration for Cabinet providers."
  (ogent-cabinet-evil-setup-mode
   'ogent-cabinet-providers-mode
   ogent-cabinet-providers-mode-map
   'ogent-cabinet-providers-mode-hook
   #'ogent-cabinet-providers--evil-local-keys))

(with-eval-after-load 'evil
  (ogent-cabinet-providers--setup-evil))

(provide 'ogent-cabinet-adapter)

;;; ogent-cabinet-adapter.el ends here
