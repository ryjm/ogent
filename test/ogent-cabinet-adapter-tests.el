;;; ogent-cabinet-adapter-tests.el --- Tests for Cabinet provider adapters -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for provider registry lookup, runtime choices, invocation planning, and
;; error classification.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet-adapter)

(ert-deftest ogent-cabinet-adapter-lists-builtins-and-aliases ()
  "The adapter registry exposes Cabinet provider families and aliases."
  (let ((ids (mapcar (lambda (adapter)
                       (plist-get adapter :id))
                     (ogent-cabinet-adapter-list))))
    (dolist (id '("codex-cli" "claude-code" "gemini-cli" "cursor-cli"
                  "opencode" "pi-cli" "grok-cli" "copilot-cli"))
      (should (member id ids))))
  (should (equal (plist-get (ogent-cabinet-adapter-get "codex")
                            :id)
                 "codex-cli"))
  (should (equal (plist-get (ogent-cabinet-adapter-get "claude_local")
                            :id)
                 "claude-code"))
  (should (eq (ogent-cabinet-adapter-normalize-provider "cursor-agent")
              'cursor)))

(ert-deftest ogent-cabinet-adapter-models-use-fresh-provider-list ()
  "Model completion prefers adapter-provided live model ids."
  (unwind-protect
      (let* ((adapter (ogent-cabinet-adapter-register
                       '(:id "fresh-cli"
                         :provider-symbol fresh
                         :name "Fresh CLI"
                         :aliases ("fresh")
                         :default-executable "fresh"
                         :models ("stale-model")
                         :model-list-function
                         (lambda (_adapter)
                           '("fresh-model" "other-model" "fresh-model"))
                         :runtime-modes (native))))
             (models (ogent-cabinet-adapter-models adapter)))
        (should (equal models '("fresh-model" "other-model"))))
    (ogent-cabinet-adapter--builtin)))

(ert-deftest ogent-cabinet-adapter-models-fall-back-to-static-list ()
  "Static metadata remains usable when a live provider query fails."
  (unwind-protect
      (let* ((adapter (ogent-cabinet-adapter-register
                       '(:id "offline-cli"
                         :provider-symbol offline
                         :name "Offline CLI"
                         :aliases ("offline")
                         :default-executable "offline"
                         :models ("backup-model")
                         :model-list-function
                         (lambda (_adapter)
                           (error "provider unavailable"))
                         :runtime-modes (native))))
             (models (ogent-cabinet-adapter-models adapter)))
        (should (equal models '("backup-model"))))
    (ogent-cabinet-adapter--builtin)))

(ert-deftest ogent-cabinet-adapter-opencode-models-query-cli ()
  "OpenCode model completion shells out through its native model list command."
  (let ((adapter (ogent-cabinet-adapter-get "opencode")))
    (cl-letf (((symbol-function 'ogent-cabinet-adapter--call-lines)
               (lambda (program args)
                 (should (equal program "opencode"))
                 (should (equal args '("models")))
                 '("openai/gpt-5.2" "anthropic/claude-sonnet-4-6"))))
      (should (equal (ogent-cabinet-adapter-models adapter)
                     '("openai/gpt-5.2"
                       "anthropic/claude-sonnet-4-6"))))))

(ert-deftest ogent-cabinet-adapter-builds-codex-and-claude-invocations ()
  "Initial adapters produce the legacy-compatible CLI invocations."
  (let* ((context (list :root "/repo"
                        :workspace "/repo"
                        :prompt "Review the repo."
                        :model "gpt-5.4"
                        :permission-mode "plan"
                        :runtime-mode 'terminal))
         (codex (ogent-cabinet-adapter-build-invocation
                 (ogent-cabinet-adapter-get "codex-cli")
                 context))
         (claude (ogent-cabinet-adapter-build-invocation
                  (ogent-cabinet-adapter-get "claude-code")
                  context)))
    (should (equal (plist-get codex :program) "codex"))
    (should (member "exec" (plist-get codex :args)))
    (should (member "--cd" (plist-get codex :args)))
    (should (equal (plist-get codex :stdin) "Review the repo."))
    (should (eq (plist-get codex :runtime-mode) 'terminal))
    (should (equal (plist-get claude :program) "claude"))
    (should (member "-p" (plist-get claude :args)))
    (should (member "--permission-mode" (plist-get claude :args)))
    (should-not (plist-get claude :stdin))))

(ert-deftest ogent-cabinet-adapter-builds-expanded-provider-invocations ()
  "Registered non-initial providers expose runnable command shapes when known."
  (let ((context (list :root "/repo"
                       :workspace "/repo"
                       :prompt "Summarize."
                       :model "auto"
                       :runtime-mode 'native)))
    (let ((gemini (ogent-cabinet-adapter-build-invocation
                   (ogent-cabinet-adapter-get "gemini")
                   context)))
      (should (equal (plist-get gemini :program) "gemini"))
      (should (member "-p" (plist-get gemini :args))))
    (let ((cursor (ogent-cabinet-adapter-build-invocation
                   (ogent-cabinet-adapter-get "cursor")
                   context)))
      (should (equal (plist-get cursor :program) "cursor-agent"))
      (should (member "--output-format" (plist-get cursor :args))))
    (let ((opencode (ogent-cabinet-adapter-build-invocation
                     (ogent-cabinet-adapter-get "opencode")
                     context)))
      (should (equal (plist-get opencode :program) "opencode"))
      (should (member "run" (plist-get opencode :args))))))

(ert-deftest ogent-cabinet-adapter-runtime-candidates-cover-modes ()
  "Runtime picker data includes adapter ids and native/terminal modes."
  (let ((candidates (ogent-cabinet-adapter-runtime-candidates)))
    (should (assoc "Codex CLI / native" candidates))
    (should (assoc "Codex CLI / terminal" candidates))
    (should (equal (plist-get (cdr (assoc "Claude Code / native" candidates))
                              :adapter-id)
                   "claude-code"))))

(ert-deftest ogent-cabinet-adapter-classifies-common-errors ()
  "Error taxonomy maps provider stderr into canonical Cabinet kinds."
  (let ((adapter (ogent-cabinet-adapter-get "codex")))
    (should (eq (plist-get
                 (ogent-cabinet-adapter-classify-error
                  adapter "Please login again" 1)
                 :kind)
                'auth-expired))
    (should (eq (plist-get
                 (ogent-cabinet-adapter-classify-error
                  adapter "rate limit exceeded" 1)
                 :kind)
                'rate-limited))
    (should (eq (plist-get
                 (ogent-cabinet-adapter-classify-error
                  adapter "context length exceeded" 1)
                 :kind)
                'context-exceeded))
    (should (eq (plist-get
                 (ogent-cabinet-adapter-classify-error
                  adapter "unknown model foo" 1)
                 :kind)
                'model-unavailable))
    (should (eq (plist-get
                 (ogent-cabinet-adapter-classify-error adapter "" 127)
                 :kind)
                'cli-not-found))))

(provide 'ogent-cabinet-adapter-tests)

;;; ogent-cabinet-adapter-tests.el ends here
