;;; ogent-armory-adapter-tests.el --- Tests for Armory provider adapters -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for provider registry lookup, runtime choices, invocation planning, and
;; error classification.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-armory-adapter)

(ert-deftest ogent-armory-adapter-lists-builtins-and-aliases ()
  "The adapter registry exposes Armory provider families and aliases."
  (let ((ids (mapcar (lambda (adapter)
                       (plist-get adapter :id))
                     (ogent-armory-adapter-list))))
    (dolist (id '("codex-cli" "claude-code" "gemini-cli" "cursor-cli"
                  "opencode" "pi-cli" "grok-cli" "copilot-cli"))
      (should (member id ids))))
  (should (equal (plist-get (ogent-armory-adapter-get "codex")
                            :id)
                 "codex-cli"))
  (should (equal (plist-get (ogent-armory-adapter-get "claude_local")
                            :id)
                 "claude-code"))
  (should (eq (ogent-armory-adapter-normalize-provider "cursor-agent")
              'cursor)))

(ert-deftest ogent-armory-adapter-builds-codex-and-claude-invocations ()
  "Initial adapters produce the legacy-compatible CLI invocations."
  (let* ((context (list :root "/repo"
                        :workspace "/repo"
                        :prompt "Review the repo."
                        :model "gpt-5.4"
                        :permission-mode "plan"
                        :runtime-mode 'terminal))
         (codex (ogent-armory-adapter-build-invocation
                 (ogent-armory-adapter-get "codex-cli")
                 context))
         (claude (ogent-armory-adapter-build-invocation
                  (ogent-armory-adapter-get "claude-code")
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

(ert-deftest ogent-armory-adapter-builds-expanded-provider-invocations ()
  "Registered non-initial providers expose runnable command shapes when known."
  (let ((context (list :root "/repo"
                       :workspace "/repo"
                       :prompt "Summarize."
                       :model "auto"
                       :runtime-mode 'native)))
    (let ((gemini (ogent-armory-adapter-build-invocation
                   (ogent-armory-adapter-get "gemini")
                   context)))
      (should (equal (plist-get gemini :program) "gemini"))
      (should (member "-p" (plist-get gemini :args))))
    (let ((cursor (ogent-armory-adapter-build-invocation
                   (ogent-armory-adapter-get "cursor")
                   context)))
      (should (equal (plist-get cursor :program) "cursor-agent"))
      (should (member "--output-format" (plist-get cursor :args))))
    (let ((opencode (ogent-armory-adapter-build-invocation
                     (ogent-armory-adapter-get "opencode")
                     context)))
      (should (equal (plist-get opencode :program) "opencode"))
      (should (member "run" (plist-get opencode :args))))))

(ert-deftest ogent-armory-adapter-runtime-candidates-cover-modes ()
  "Runtime picker data includes adapter ids and native/terminal modes."
  (let ((candidates (ogent-armory-adapter-runtime-candidates)))
    (should (assoc "Codex CLI / native" candidates))
    (should (assoc "Codex CLI / terminal" candidates))
    (should (equal (plist-get (cdr (assoc "Claude Code / native" candidates))
                              :adapter-id)
                   "claude-code"))))

(ert-deftest ogent-armory-adapter-classifies-common-errors ()
  "Error taxonomy maps provider stderr into canonical Armory kinds."
  (let ((adapter (ogent-armory-adapter-get "codex")))
    (should (eq (plist-get
                 (ogent-armory-adapter-classify-error
                  adapter "Please login again" 1)
                 :kind)
                'auth-expired))
    (should (eq (plist-get
                 (ogent-armory-adapter-classify-error
                  adapter "rate limit exceeded" 1)
                 :kind)
                'rate-limited))
    (should (eq (plist-get
                 (ogent-armory-adapter-classify-error
                  adapter "context length exceeded" 1)
                 :kind)
                'context-exceeded))
    (should (eq (plist-get
                 (ogent-armory-adapter-classify-error
                  adapter "unknown model foo" 1)
                 :kind)
                'model-unavailable))
    (should (eq (plist-get
                 (ogent-armory-adapter-classify-error adapter "" 127)
                 :kind)
                'cli-not-found))))

(provide 'ogent-armory-adapter-tests)

;;; ogent-armory-adapter-tests.el ends here
