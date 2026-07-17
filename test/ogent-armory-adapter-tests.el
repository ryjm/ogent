;;; ogent-armory-adapter-tests.el --- Tests for Armory provider adapters -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for provider registry lookup, runtime choices, invocation planning, and
;; error classification.

;;; Code:

(require 'cl-lib)
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

(ert-deftest ogent-armory-adapter-models-use-fresh-provider-list ()
  "Model completion prefers adapter-provided live model ids."
  (unwind-protect
      (let* ((adapter (ogent-armory-adapter-register
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
             (models (ogent-armory-adapter-models adapter)))
        (should (equal models '("fresh-model" "other-model"))))
    (ogent-armory-adapter--builtin)))

(ert-deftest ogent-armory-adapter-models-fall-back-to-static-list ()
  "Static metadata remains usable when a live provider query fails."
  (unwind-protect
      (let* ((adapter (ogent-armory-adapter-register
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
             (models (ogent-armory-adapter-models adapter)))
        (should (equal models '("backup-model"))))
    (ogent-armory-adapter--builtin)))

(ert-deftest ogent-armory-adapter-opencode-models-query-cli ()
  "OpenCode model completion shells out through its native model list command."
  (let ((adapter (ogent-armory-adapter-get "opencode")))
    (cl-letf (((symbol-function 'ogent-armory-adapter--call-lines)
               (lambda (program args)
                 (should (equal program "opencode"))
                 (should (equal args '("models")))
                 '("openai/gpt-5.2" "anthropic/claude-sonnet-4-6"))))
      (should (equal (ogent-armory-adapter-models adapter)
                     '("openai/gpt-5.2"
                       "anthropic/claude-sonnet-4-6"))))))

(ert-deftest ogent-armory-adapter-builds-codex-and-claude-invocations ()
  "Initial adapters produce the legacy-compatible CLI invocations."
  (let* ((context (list :root "/repo"
                        :workspace "/repo"
                        :prompt "Review the repo."
                        :model "gpt-5.4"
                        :effort "xhigh"
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
    (should (member "--effort" (plist-get claude :args)))
    (should (member "xhigh" (plist-get claude :args)))
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

(ert-deftest ogent-armory-adapter-pi-and-grok-report-unsupported ()
  "Adapters without grounded CLI flags refuse to run with a named reason."
  (dolist (id '("pi-cli" "grok-cli"))
    (let* ((adapter (ogent-armory-adapter-get id))
           (err (should-error
                 (ogent-armory-adapter-build-invocation
                  adapter
                  (list :root "/repo" :workspace "/repo" :prompt "Hi."))
                 :type 'user-error)))
      (should (plist-get adapter :unsupported-reason))
      (should (string-match-p "cannot run" (cadr err)))
      (should (string-match-p id (cadr err)))
      (should (string-match-p "unverified" (cadr err))))))

(ert-deftest ogent-armory-adapter-codex-resume-invocation ()
  "Codex invocations resume a stored session via `codex exec resume'."
  (let* ((session-id "0198aaaa-bbbb-cccc-dddd-eeeeffff0000")
         (context (list :root "/repo"
                        :workspace "/repo"
                        :prompt "Continue the review."
                        :model "gpt-5.4"
                        :resume-session-id session-id
                        :runtime-mode 'native))
         (codex (ogent-armory-adapter-build-invocation
                 (ogent-armory-adapter-get "codex-cli") context))
         (args (plist-get codex :args)))
    (should (member "exec" args))
    (should (equal (nth (1+ (cl-position "exec" args :test #'equal)) args)
                   "resume"))
    ;; Grounded from `codex exec resume --help': the resume subcommand
    ;; accepts neither --cd nor --sandbox.
    (should-not (member "--cd" args))
    (should-not (member "--sandbox" args))
    (should (member "--skip-git-repo-check" args))
    (should (member "--model" args))
    ;; The session id precedes the stdin placeholder positional.
    (should (equal (last args 2) (list session-id "-")))
    (should (equal (plist-get codex :stdin) "Continue the review."))))

(ert-deftest ogent-armory-adapter-claude-resume-invocation ()
  "Claude invocations pass --resume with the stored session id."
  (let* ((session-id "11111111-2222-3333-4444-555555555555")
         (context (list :root "/repo"
                        :workspace "/repo"
                        :prompt "Continue."
                        :permission-mode "plan"
                        :resume-session-id session-id))
         (claude (ogent-armory-adapter-build-invocation
                  (ogent-armory-adapter-get "claude-code") context))
         (args (plist-get claude :args)))
    (should (member "--resume" args))
    (should (equal (nth (1+ (cl-position "--resume" args :test #'equal)) args)
                   session-id))
    ;; The prompt stays the final positional argument.
    (should (equal (car (last args)) "Continue."))))

(ert-deftest ogent-armory-adapter-fresh-invocations-omit-resume-flags ()
  "Without a stored session id no resume flags leak into fresh runs."
  (let* ((context (list :root "/repo" :workspace "/repo" :prompt "Hi."))
         (codex (ogent-armory-adapter-build-invocation
                 (ogent-armory-adapter-get "codex-cli") context))
         (claude (ogent-armory-adapter-build-invocation
                  (ogent-armory-adapter-get "claude-code") context)))
    (should-not (member "resume" (plist-get codex :args)))
    (should (member "--cd" (plist-get codex :args)))
    (should-not (member "--resume" (plist-get claude :args)))))

;; CLI help grounding (ogent-h3y).  Builder flags must appear verbatim
;; in the checked-in snapshots under test/data/cli-help/; a missing
;; snapshot downgrades to a named-warning skip, never a failure.

(defvar ogent-armory-runner-codex-approval)
(defvar ogent-armory-runner-codex-sandbox)
(defvar ogent-armory-runner-codex-skip-git-repo-check)

(defun ogent-armory-adapter-tests--snapshot-or-skip (adapter-id)
  "Return snapshot text for ADAPTER-ID, skipping the test when absent."
  (let ((snapshot (ogent-armory-adapter-ground-snapshot adapter-id)))
    (unless snapshot
      (ert-skip (format "No CLI help snapshot for %s" adapter-id)))
    (plist-get snapshot :text)))

(defun ogent-armory-adapter-tests--grounded-p (token text)
  "Return non-nil when TOKEN appears as a standalone word in TEXT."
  (string-match-p
   (concat "\\(?:\\`\\|[^-A-Za-z0-9]\\)" (regexp-quote token)
           "\\(?:\\'\\|[^-A-Za-z0-9]\\)")
   text))

(defun ogent-armory-adapter-tests--invocation-flags (invocation)
  "Return the option tokens INVOCATION passes on its command line."
  (seq-filter (lambda (arg)
                (and (stringp arg)
                     (string-match-p "\\`--?[A-Za-z]" arg)))
              (plist-get invocation :args)))

(ert-deftest ogent-armory-adapter-ground-parses-cli-versions ()
  "Version extraction handles the codex and claude --version shapes."
  (should (equal (ogent-armory-adapter-ground--parse-version
                  "codex-cli 0.142.0\n")
                 "0.142.0"))
  (should (equal (ogent-armory-adapter-ground--parse-version
                  "2.1.199 (Claude Code)\n")
                 "2.1.199"))
  (should-not (ogent-armory-adapter-ground--parse-version "no version here"))
  (should-not (ogent-armory-adapter-ground--parse-version nil)))

(ert-deftest ogent-armory-adapter-ground-picks-versioned-snapshots ()
  "Snapshot lookup filters by adapter, sorts by version, prefers exact."
  (let* ((names '("codex-cli-0.9.0.txt" "claude-code-2.1.199.txt"
                  "codex-cli-0.142.0.txt" "README.md" "codex-cli-notes.txt"))
         (pairs (ogent-armory-adapter-ground--match-snapshots
                 "codex-cli" names)))
    ;; Version order, not string order: 0.142.0 is newer than 0.9.0.
    (should (equal pairs '(("0.142.0" . "codex-cli-0.142.0.txt")
                           ("0.9.0" . "codex-cli-0.9.0.txt"))))
    (should (equal (ogent-armory-adapter-ground--pick pairs "0.9.0")
                   '("0.9.0" . "codex-cli-0.9.0.txt")))
    ;; Unknown or missing live version falls back to the newest snapshot.
    (should (equal (car (ogent-armory-adapter-ground--pick pairs "9.9.9"))
                   "0.142.0"))
    (should (equal (car (ogent-armory-adapter-ground--pick pairs nil))
                   "0.142.0"))))

(ert-deftest ogent-armory-adapter-ground-detects-drift-on-doctored-snapshot ()
  "Doctoring a snapshot surfaces as removed/added lines in the drift report."
  (let* ((snapshot (ogent-armory-adapter-tests--snapshot-or-skip "codex-cli"))
         (doctored (concat snapshot "      --vanished-flag <X>\n")))
    ;; Line-set diff both ways: snapshot-only lines are :removed,
    ;; live-only lines are :added.
    (let ((drift (ogent-armory-adapter-ground--diff-lines doctored snapshot)))
      (should (equal (plist-get drift :removed) '("--vanished-flag <X>")))
      (should-not (plist-get drift :added)))
    (let ((drift (ogent-armory-adapter-ground--diff-lines snapshot doctored)))
      (should (equal (plist-get drift :added) '("--vanished-flag <X>")))
      (should-not (plist-get drift :removed)))
    ;; And through the command, with the live CLI side stubbed out.
    (cl-letf (((symbol-function 'ogent-armory-adapter-ground--live-help)
               (lambda (_adapter) snapshot))
              ((symbol-function 'ogent-armory-adapter-ground--live-version)
               (lambda (_adapter) "0.0.0"))
              ((symbol-function 'ogent-armory-adapter-ground-snapshot)
               (lambda (_id &optional _version)
                 (list :file "doctored.txt" :version "0.0.0"
                       :text doctored))))
      (let ((report (ogent-armory-adapter-ground "codex-cli")))
        (should (equal (plist-get report :adapter-id) "codex-cli"))
        (should (equal (plist-get report :snapshot-version) "0.0.0"))
        (should-not (plist-get report :added))
        (should (equal (plist-get report :removed)
                       '("--vanished-flag <X>")))))))

(ert-deftest ogent-armory-adapter-ground-codex-flags-in-snapshot ()
  "Every flag the codex builder emits appears verbatim in its snapshot."
  (let* ((text (ogent-armory-adapter-tests--snapshot-or-skip "codex-cli"))
         (ogent-armory-runner-codex-approval "on-request")
         (ogent-armory-runner-codex-sandbox "workspace-write")
         (ogent-armory-runner-codex-skip-git-repo-check t)
         (adapter (ogent-armory-adapter-get "codex-cli"))
         (fresh (ogent-armory-adapter-build-invocation
                 adapter (list :root "/repo" :workspace "/repo"
                               :prompt "Hi." :model "gpt-5.5")))
         (resume (ogent-armory-adapter-build-invocation
                  adapter (list :root "/repo" :workspace "/repo"
                                :prompt "More."
                                :resume-session-id "0198-fake"))))
    (dolist (token (append
                    (ogent-armory-adapter-tests--invocation-flags fresh)
                    (ogent-armory-adapter-tests--invocation-flags resume)
                    ;; Subcommands and builder-baked option values are
                    ;; grounded too.
                    '("exec" "resume" "on-request" "workspace-write")))
      (should (ogent-armory-adapter-tests--grounded-p token text)))))

(ert-deftest ogent-armory-adapter-ground-claude-flags-in-snapshot ()
  "Every flag the claude builder emits appears verbatim in its snapshot."
  (let* ((text (ogent-armory-adapter-tests--snapshot-or-skip "claude-code"))
         (adapter (ogent-armory-adapter-get "claude-code"))
         (fresh (ogent-armory-adapter-build-invocation
                 adapter (list :root "/repo" :workspace "/repo"
                               :prompt "Hi." :model "fable"
                               :effort "high")))
         (resume (ogent-armory-adapter-build-invocation
                  adapter (list :root "/repo" :workspace "/repo"
                                :prompt "More."
                                :resume-session-id
                                "11111111-2222-3333-4444-555555555555"))))
    (dolist (token (append
                    (ogent-armory-adapter-tests--invocation-flags fresh)
                    (ogent-armory-adapter-tests--invocation-flags resume)
                    ;; The builder's fallback --permission-mode value is
                    ;; a documented choice.
                    '("default")))
      (should (ogent-armory-adapter-tests--grounded-p token text)))))

(ert-deftest ogent-armory-adapter-ground-missing-snapshot-warns-and-skips ()
  "A missing snapshot yields a named warning and a skip, never a failure."
  (let (warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &rest _)
                 (push (cons type message) warnings))))
      (should-not
       (ogent-armory-adapter-ground-snapshot "ogent-test-ungrounded"))
      (should (eq (caar warnings) 'ogent-armory-adapter-ground))
      (should (string-match-p "ogent-test-ungrounded" (cdar warnings)))
      ;; The suite helper converts the nil into an ert skip, so an
      ;; ungrounded adapter can never fail the suite.
      (should (eq 'skipped
                  (condition-case nil
                      (progn
                        (ogent-armory-adapter-tests--snapshot-or-skip
                         "ogent-test-ungrounded")
                        'returned)
                    (ert-test-skipped 'skipped)))))))

(provide 'ogent-armory-adapter-tests)

;;; ogent-armory-adapter-tests.el ends here
