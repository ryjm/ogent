;;; ogent-armory-runner-tests.el --- Tests for Armory CLI runners -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for running Org Armory agents through local CLI provider adapters.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-conversations)
(require 'ogent-armory-runner)
(require 'ogent-armory-actions)
(require 'ogent-armory-settings)

(defmacro ogent-armory-runner-test-with-temp-dir (var &rest body)
  "Bind VAR to a retained temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (directory-file-name
                (ogent-test--provision-store-directory 'armory-runner))))
     ,@body))

(defun ogent-armory-runner-test--make-executable (dir content)
  "Create an executable file in DIR with CONTENT."
  (let ((file (expand-file-name "agent-fixture" dir)))
    (with-temp-file file
      (insert content))
    (set-file-modes file #o755)
    file))

(defun ogent-armory-runner-test--wait (process)
  "Wait for PROCESS to exit and its sentinel to finalize the conversation."
  (while (process-live-p process)
    (accept-process-output process 0.1))
  ;; The exit sentinel removes PROCESS from the registry before it rewrites the
  ;; canonical conversation record.  Poll until both the registry and stored
  ;; conversation state reflect finalization.
  (let* ((plan (process-get process 'ogent-armory-plan))
         (root (plist-get plan :root))
         (conversation-id (process-get process 'ogent-armory-conversation-id))
         (deadline (+ (float-time) 5)))
    (while (and (< (float-time) deadline)
                (or (memq process ogent-armory-runner--processes)
                    (let ((status (ignore-errors
                                    (plist-get
                                     (ogent-armory-conversation-read
                                      root conversation-id)
                                     :status))))
                      (or (null status) (equal status "running")))))
      (accept-process-output nil 0.05))))

(ert-deftest ogent-armory-runner-builds-codex-plan-from-job ()
  "Codex plans use `codex exec' with subscription auth inherited from the CLI."
  (ogent-armory-runner-test-with-temp-dir dir
    (let ((workspace (expand-file-name "engineering" dir)))
      (make-directory workspace t)
      (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-armory-write-agent
       dir
       '(:slug "cto"
               :name "CTO"
               :role "Architecture"
               :provider "codex"
               :model "gpt-5.4"
               :workspace "engineering")
       "Keep the architecture honest.")
      (ogent-armory-write-job
       dir "cto"
       '(:id "weekly-review"
             :name "Weekly Review"
             :cron "0 9 * * 1")
       "Find risks and write next actions.")
      (let* ((plan (ogent-armory-runner-plan
                    dir "cto" :job-id "weekly-review"))
             (args (plist-get plan :args))
             (prompt (plist-get plan :prompt)))
        (should (eq (plist-get plan :provider) 'codex))
        (should (equal (plist-get plan :adapter-id) "codex-cli"))
        (should (eq (plist-get plan :runtime-mode) 'native))
        (should (equal (plist-get plan :program)
                       ogent-armory-codex-executable))
        (should (member "exec" args))
        (should (member "--ask-for-approval" args))
        (should (member "--cd" args))
        (should (member "--sandbox" args))
        (should (member "--skip-git-repo-check" args))
        (should (member "--model" args))
        (should (equal (car (last args)) "-"))
        (should (equal (file-truename workspace)
                       (directory-file-name
                        (file-truename (plist-get plan :workspace)))))
        (should (string-match-p "Keep the architecture honest" prompt))
        (should (string-match-p "Find risks" prompt))))))

(ert-deftest ogent-armory-runner-prompts-for-org-output ()
  "Runner prompts include the Org response contract and metadata block."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :workspace "/")
     "Keep the architecture honest.")
    (let* ((plan (ogent-armory-runner-plan
                  dir "cto" :instruction "Review this run."))
           (prompt (plist-get plan :prompt)))
      (should (string-match-p "Armory response contract" prompt))
      (should (string-match-p "Org markup" prompt))
      (should (string-match-p "level \\*\\*" prompt))
      (should (string-match-p "#\\+begin_armory" prompt))
      (should (string-match-p "SUMMARY:" prompt))
      (should (string-match-p "ARTIFACT:" prompt))
      (should (string-match-p "Example Armory response" prompt))
      (should (string-match-p "Machine footer" prompt))
      (should (string-match-p "Before sending" prompt))
      (should (string-match-p "Armory run context" prompt))
      (should (string-match-p "Runtime: native" prompt)))))

(ert-deftest ogent-armory-runner-selects-implementation-template ()
  "Implementation prompts ask for sections that map cleanly to the reader."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "builder"
             :name "Builder"
             :role "Implementation"
             :provider "codex"
             :workspace "/")
     "Ship small patches.")
    (let* ((plan (ogent-armory-runner-plan
                  dir "builder" :instruction "Implement the dashboard fix."))
           (prompt (plist-get plan :prompt)))
      (should (string-match-p "Implementation response shape" prompt))
      (should (string-match-p "\\*\\* Changed" prompt))
      (should (string-match-p "\\*\\* Verification" prompt))
      (should (string-match-p "\\*\\* Notes" prompt)))))

(ert-deftest ogent-armory-runner-selects-review-template-from-job ()
  "Review jobs get findings, risks, and test sections."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :workspace "/")
     "Keep the architecture honest.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review"
           :name "Weekly Review"
           :enabled t)
     "Review recent work.")
    (let* ((plan (ogent-armory-runner-plan
                  dir "cto" :job-id "weekly-review"))
           (prompt (plist-get plan :prompt)))
      (should (string-match-p "Review response shape" prompt))
      (should (string-match-p "\\*\\* Findings" prompt))
      (should (string-match-p "\\*\\* Risks" prompt))
      (should (string-match-p "\\*\\* Tests" prompt)))))

(ert-deftest ogent-armory-runner-adds-action-contract-for-leads ()
  "Dispatch-capable agents receive the action proposal protocol."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "lead"
             :name "Lead"
             :role "Lead agent"
             :provider "codex"
             :can-dispatch t
             :workspace "/")
     "Coordinate follow-up work.")
    (let* ((plan (ogent-armory-runner-plan
                  dir "lead" :instruction "Plan follow-up tasks."))
           (prompt (plist-get plan :prompt)))
      (should (string-match-p "Action proposal contract" prompt))
      (should (string-match-p "#\\+begin_armory-actions" prompt))
      (should (string-match-p "launch-task" prompt)))))

(ert-deftest ogent-armory-runner-job-overrides-provider-model-and-workspace ()
  "Job metadata can override the owning agent's provider, model, and workspace."
  (ogent-armory-runner-test-with-temp-dir dir
    (let ((workspace (expand-file-name "reports" dir)))
      (make-directory workspace t)
      (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-armory-write-agent
       dir
       '(:slug "cto"
               :name "CTO"
               :role "Architecture"
               :provider "codex"
               :model "gpt-5.4"
               :workspace "/")
       "Keep the architecture honest.")
      (ogent-armory-write-job
       dir "cto"
       '(:id "weekly-review"
             :name "Weekly Review"
             :provider "claude"
             :model "sonnet"
             :workspace "reports"
             :enabled t)
       "Find risks and write next actions.")
      (let* ((plan (ogent-armory-runner-plan
                    dir "cto" :job-id "weekly-review"))
             (args (plist-get plan :args)))
        (should (eq (plist-get plan :provider) 'claude))
        (should (member "sonnet" args))
        (should (equal (file-truename workspace)
                       (directory-file-name
                        (file-truename (plist-get plan :workspace)))))))))

(ert-deftest ogent-armory-runner-records-schedule-linkage ()
  "Runner-created conversations retain schedule keys for calendar linkage."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :workspace "/")
     "Keep the architecture honest.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "daily-review"
           :name "Daily Review"
           :cron "0 9 * * *"
           :enabled t)
     "Find risks and write next actions.")
    (let* ((key "cto::job::daily-review::2026-05-04T09:00")
           (plan (ogent-armory-runner-plan
                  dir
                  "cto"
                  :job-id "daily-review"
                  :conversation-id "scheduled-run"
                  :trigger "job"
                  :scheduled-at "2026-05-04T09:00"
                  :scheduled-key key)))
      (ogent-armory-runner--create-conversation
       plan
       "2026-05-04T09:00:00-0700")
      (let ((conversation (ogent-armory-conversation-read
                           dir
                           "scheduled-run")))
        (should (equal (plist-get conversation :scheduled-at)
                       "2026-05-04T09:00"))
        (should (equal (plist-get conversation :scheduled-key) key))))))

(ert-deftest ogent-armory-runner-rejects-malformed-job-metadata ()
  "Runner planning stops on invalid job metadata with a Armory-level error."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :workspace "/")
     "Keep the architecture honest.")
    (ogent-armory-write-job
     dir "cto"
     '(:id "weekly-review"
           :name "Weekly Review"
           :cron "not a cron"
           :enabled t)
     "Find risks and write next actions.")
    (let* ((error (should-error
                   (ogent-armory-runner-plan dir "cto" :job-id "weekly-review")
                   :type 'user-error))
           (message (cadr error)))
      (should (string-match-p "Malformed Armory job metadata" message))
      (should (string-match-p "weekly-review" message)))))

(ert-deftest ogent-armory-runner-builds-claude-plan-from-agent ()
  "Claude plans use Claude Code with first-party subscription auth."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "editor"
             :name "Editor"
             :role "Knowledge editor"
             :provider "claude"
             :model "sonnet"
             :permission-mode "plan")
     "Keep the notes sharp.")
    (let* ((plan (ogent-armory-runner-plan
                  dir "editor" :instruction "Summarize today."))
           (args (plist-get plan :args)))
      (should (eq (plist-get plan :provider) 'claude))
      (should (equal (plist-get plan :adapter-id) "claude-code"))
      (should (equal (plist-get plan :program)
                     ogent-armory-claude-executable))
      (should (member "-p" args))
      (should (member "--permission-mode" args))
      (should (member "plan" args))
      (should (member "--add-dir" args))
      (should (member "--model" args))
      (should (member "sonnet" args))
      (should (string-match-p "Summarize today"
                              (plist-get plan :prompt)))
      (should-not (string-match-p "Summarize today"
                                  (ogent-armory-runner--command-preview
                                   plan)))
      (should-not (plist-get plan :stdin)))))

(ert-deftest ogent-armory-runner-applies-armory-runtime-defaults ()
  "Blank agent and job runtime fields fall through to Armory settings."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-settings-write
     dir
     '(:default-provider "claude-code"
                         :default-model "opus-4.7"
                         :default-effort "xhigh"
                         :default-runtime "terminal")
     :merge t)
    (ogent-armory-write-agent
     dir
     '(:slug "lead"
             :name "Lead"
             :role "Coordinator"
             :provider "claude-code"
             :workspace "/")
     "Keep Armory work moving.")
    (ogent-armory-write-job
     dir "lead"
     '(:id "configure-master"
           :name "Configure Master"
           :enabled t
           :workspace "/")
     "Configure this Armory.")
    (let* ((ogent-armory-runner-claude-permission-mode "default")
           (plan (ogent-armory-runner-plan
                  dir "lead" :job-id "configure-master"))
           (args (plist-get plan :args))
           (prompt (plist-get plan :prompt)))
      (should (eq (plist-get plan :provider) 'claude))
      (should (equal (plist-get plan :adapter-id) "claude-code"))
      (should (equal (plist-get plan :model) "opus-4.7"))
      (should (equal (plist-get plan :effort) "xhigh"))
      (should (eq (plist-get plan :runtime-mode) 'terminal))
      (should (member "--model" args))
      (should (member "opus-4.7" args))
      (should (member "--effort" args))
      (should (member "xhigh" args))
      (should (member "--permission-mode" args))
      (should (member "dontAsk" args))
      (should (string-match-p "Model: opus-4.7" prompt))
      (should (string-match-p "Effort: xhigh" prompt))
      (should (string-match-p "Runtime: terminal" prompt)))))

(ert-deftest ogent-armory-runner-escapes-org-block-terminators ()
  "Session formatting keeps provider text inside Org source blocks."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex")
     "#+end_src")
    (let* ((plan (ogent-armory-runner-plan
                  dir "cto" :instruction "#+end_src"))
           (session (ogent-armory-runner--format-session
                     plan "#+end_src" "#+end_src" 0)))
      (should (string-match-p ",#\\+end_src" session))
      (should-not (string-match-p "\n#\\+end_src\n#\\+end_src" session)))))

(ert-deftest ogent-armory-runner-success-stderr-is-runtime-trace ()
  "Successful runs store stderr as trace output, not as an error transcript."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex")
     "Keep the plan direct.")
    (let* ((plan (ogent-armory-runner-plan
                  dir "cto" :instruction "Review."))
           (session (ogent-armory-runner--format-session
                     plan "Done." "tool trace" 0)))
      (should (string-match-p "\\*\\* Runtime Trace" session))
      (should-not (string-match-p "\\*\\* Error" session)))))

(ert-deftest ogent-armory-runner-start-writes-canonical-conversation ()
  "Runner starts a real local process and writes a canonical conversation."
  (ogent-armory-runner-test-with-temp-dir dir
    (let* ((workspace (expand-file-name "engineering" dir))
           (fixture (ogent-armory-runner-test--make-executable
                     dir
                     "#!/bin/sh\nprintf 'fixture agent ok\\n'\ncat >/dev/null\n")))
      (make-directory workspace t)
      (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-armory-write-agent
       dir
       '(:slug "cto"
               :name "CTO"
               :role "Architecture"
               :provider "codex"
               :workspace "engineering")
       "Keep the plan direct.")
      (let* ((ogent-armory-codex-executable fixture)
             (ogent-armory-runner-confirm-before-run nil)
             (plan (ogent-armory-runner-plan
                    dir "cto"
                    :instruction "Say hello."
                    :runtime-mode 'terminal))
             (process (ogent-armory-runner-start plan)))
        (should (equal (process-get process 'ogent-armory-conversation-id)
                       (plist-get plan :conversation-id)))
        (ogent-armory-runner-test--wait process)
        (let* ((conversation-file
                (process-get process 'ogent-armory-conversation-file))
               (conversation-id
                (process-get process 'ogent-armory-conversation-id))
               (conversation
                (ogent-armory-conversation-read dir conversation-id))
               (turns
                (ogent-armory-conversation-read-turns dir conversation-id)))
          (should (and conversation-file (file-exists-p conversation-file)))
          (should (equal (plist-get conversation :status) "done"))
          (should (equal (plist-get conversation :provider) "codex"))
          (should (equal (plist-get conversation :adapter) "codex-cli"))
          (should (equal (plist-get conversation :runtime-mode) "terminal"))
          (should (= 2 (length turns)))
          (should (string-match-p "Say hello"
                                  (plist-get (car turns) :content)))
          (should (string-match-p "fixture agent ok"
                                  (plist-get (cadr turns) :content))))))))

(defun ogent-armory-runner-test--fake-worktree (dir)
  "Create a fake main checkout and linked worktree under DIR.
Return (MAIN . WORKTREE)."
  (let ((main (expand-file-name "main" dir))
        (worktree (expand-file-name "wt" dir)))
    (make-directory (expand-file-name ".git/worktrees/wt" main) t)
    (make-directory (expand-file-name ".beads" main) t)
    (make-directory worktree t)
    (write-region (format "gitdir: %s\n"
                          (expand-file-name ".git/worktrees/wt" main))
                  nil (expand-file-name ".git" worktree) nil 'silent)
    (cons main worktree)))

(ert-deftest ogent-armory-runner-start-ensures-beads-worktree-redirect ()
  "Starting a run in a linked worktree writes the br redirect pointer."
  (ogent-armory-runner-test-with-temp-dir dir
    (pcase-let ((`(,main . ,worktree)
                 (ogent-armory-runner-test--fake-worktree dir))
                (fixture (ogent-armory-runner-test--make-executable
                          dir
                          "#!/bin/sh\nprintf 'ok\\n'\ncat >/dev/null\n")))
      (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-armory-write-agent
       dir
       `(:slug "cto"
               :name "CTO"
               :role "Architecture"
               :provider "codex"
               :workspace ,worktree)
       "Keep the plan direct.")
      (let* ((ogent-armory-codex-executable fixture)
             (ogent-armory-runner-confirm-before-run nil)
             (plan (ogent-armory-runner-plan
                    dir "cto"
                    :instruction "Say hello."
                    :runtime-mode 'terminal))
             (process (ogent-armory-runner-start plan)))
        (ogent-armory-runner-test--wait process)
        (let ((redirect (expand-file-name ".beads/redirect" worktree)))
          (should (file-exists-p redirect))
          (should (equal (with-temp-buffer
                           (insert-file-contents redirect)
                           (string-trim (buffer-string)))
                         (expand-file-name ".beads" main))))))))

(ert-deftest ogent-armory-runner-start-skips-beads-redirect-when-disabled ()
  "The redirect step honors `ogent-armory-runner-ensure-beads-redirect'."
  (ogent-armory-runner-test-with-temp-dir dir
    (pcase-let ((`(,_main . ,worktree)
                 (ogent-armory-runner-test--fake-worktree dir))
                (fixture (ogent-armory-runner-test--make-executable
                          dir
                          "#!/bin/sh\nprintf 'ok\\n'\ncat >/dev/null\n")))
      (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-armory-write-agent
       dir
       `(:slug "cto"
               :name "CTO"
               :role "Architecture"
               :provider "codex"
               :workspace ,worktree)
       "Keep the plan direct.")
      (let* ((ogent-armory-codex-executable fixture)
             (ogent-armory-runner-confirm-before-run nil)
             (ogent-armory-runner-ensure-beads-redirect nil)
             (plan (ogent-armory-runner-plan
                    dir "cto"
                    :instruction "Say hello."
                    :runtime-mode 'terminal))
             (process (ogent-armory-runner-start plan)))
        (ogent-armory-runner-test--wait process)
        (should-not (file-exists-p
                     (expand-file-name ".beads/redirect" worktree)))))))

(ert-deftest ogent-armory-runner-transcript-links-generated-apps ()
  "Runner transcripts record generated index.html artifacts when output names them."
  (ogent-armory-runner-test-with-temp-dir dir
    (let* ((workspace (expand-file-name "engineering" dir))
           (app-file (expand-file-name "apps/dashboard/index.html" dir))
           (fixture (ogent-armory-runner-test--make-executable
                     dir
                     (format "#!/bin/sh\nmkdir -p %s\nprintf '<!doctype html>' > %s\nprintf '%s\\n'\ncat >/dev/null\n"
                             (shell-quote-argument (file-name-directory app-file))
                             (shell-quote-argument app-file)
                             (shell-quote-argument app-file)))))
      (make-directory workspace t)
      (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-armory-write-agent
       dir
       '(:slug "cto"
               :name "CTO"
               :role "Architecture"
               :provider "codex"
               :workspace "engineering")
       "Keep the plan direct.")
      (let* ((ogent-armory-codex-executable fixture)
             (ogent-armory-runner-confirm-before-run nil)
             (plan (ogent-armory-runner-plan
                    dir "cto" :instruction "Build app."))
             (process (ogent-armory-runner-start plan)))
        (ogent-armory-runner-test--wait process)
        (let* ((conversation-id
                (process-get process 'ogent-armory-conversation-id))
               (conversation
                (ogent-armory-conversation-read dir conversation-id)))
          (should (member "apps/dashboard"
                          (plist-get conversation :artifact-paths))))))))

(ert-deftest ogent-armory-runner-classifies-adapter-errors ()
  "Failed runs store canonical adapter error metadata."
  (ogent-armory-runner-test-with-temp-dir dir
    (let* ((workspace (expand-file-name "engineering" dir))
           (fixture (ogent-armory-runner-test--make-executable
                     dir
                     "#!/bin/sh\nprintf 'Please login again\\n' >&2\ncat >/dev/null\nexit 1\n")))
      (make-directory workspace t)
      (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-armory-write-agent
       dir
       '(:slug "cto"
               :name "CTO"
               :role "Architecture"
               :provider "codex"
               :workspace "engineering")
       "Keep the plan direct.")
      (let* ((ogent-armory-codex-executable fixture)
             (ogent-armory-runner-confirm-before-run nil)
             (plan (ogent-armory-runner-plan
                    dir "cto" :instruction "Say hello."))
             (process (ogent-armory-runner-start plan)))
        (ogent-armory-runner-test--wait process)
        (let* ((conversation-id
                (process-get process 'ogent-armory-conversation-id))
               (conversation
                (ogent-armory-conversation-read dir conversation-id)))
          (should (equal (plist-get conversation :status) "failed"))
          (should (equal (plist-get conversation :error-kind) "auth-expired"))
          (should (string-match-p "Please login"
                                  (plist-get conversation :error-hint))))))))

(defun ogent-armory-runner-test--seed-lead-armory (root)
  "Create a lead, a builder, and a parent conversation under ROOT."
  (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
  (ogent-armory-write-agent
   root
   '(:slug "lead"
           :name "Lead"
           :role "Lead agent"
           :type "lead"
           :can-dispatch t
           :provider "codex")
   "Lead the work.")
  (ogent-armory-write-agent
   root
   '(:slug "builder"
           :name "Builder"
           :role "Implementation"
           :provider "claude")
   "Build the work.")
  (ogent-armory-conversation-create
   root
   '(:id "parent"
         :agent "lead"
         :title "Parent"
         :status "done")))

(ert-deftest ogent-armory-runner-capture-actions-stores-lead-proposals ()
  "Lead proposals on a clean exit become readable pending actions."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-runner-test--seed-lead-armory dir)
    (let* ((plan (list :root dir
                       :agent '(:slug "lead" :type "lead" :can-dispatch t)
                       :conversation-id "parent"))
           (stored (ogent-armory-runner--capture-actions
                    plan
                    "LAUNCH_TASK: builder | Build | Build it.\n"
                    0))
           (actions (ogent-armory-actions-read dir "parent")))
      (should stored)
      (should (= 1 (length actions)))
      (should (eq (plist-get (car actions) :type) 'launch-task))
      (should (equal (plist-get (car actions) :status) "pending"))
      (should (equal (plist-get (car actions) :target-agent) "builder")))))

(ert-deftest ogent-armory-runner-capture-actions-ignores-non-lead-agents ()
  "Proposals from non-lead agents are dropped without storing anything."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-runner-test--seed-lead-armory dir)
    (let ((plan (list :root dir
                      :agent '(:slug "builder")
                      :conversation-id "parent")))
      (should-not (ogent-armory-runner--capture-actions
                   plan
                   "LAUNCH_TASK: builder | Build | Build it.\n"
                   0))
      (should-not (file-exists-p
                   (ogent-armory-actions-file dir "parent"))))))

(ert-deftest ogent-armory-runner-capture-actions-ignores-failed-runs ()
  "Proposals in a failed run's partial output are never enqueued."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-runner-test--seed-lead-armory dir)
    (let ((plan (list :root dir
                      :agent '(:slug "lead" :type "lead" :can-dispatch t)
                      :conversation-id "parent")))
      (should-not (ogent-armory-runner--capture-actions
                   plan
                   "LAUNCH_TASK: builder | Build | Build it.\n"
                   1))
      (should-not (file-exists-p
                   (ogent-armory-actions-file dir "parent"))))))

(ert-deftest ogent-armory-runner-capture-actions-ignores-plain-output ()
  "Lead output without proposals stores no actions file."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-runner-test--seed-lead-armory dir)
    (let ((plan (list :root dir
                      :agent '(:slug "lead" :type "lead" :can-dispatch t)
                      :conversation-id "parent")))
      (should-not (ogent-armory-runner--capture-actions
                   plan
                   "All quiet today.\n"
                   0))
      (should-not (file-exists-p
                   (ogent-armory-actions-file dir "parent"))))))

(ert-deftest ogent-armory-runner-start-stores-lead-action-proposals ()
  "A finished lead run stores its proposals under the run's conversation."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-runner-test--seed-lead-armory dir)
    (let ((fixture (ogent-armory-runner-test--make-executable
                    dir
                    "#!/bin/sh\nprintf 'LAUNCH_TASK: builder | Build | Build it.\\n'\ncat >/dev/null\n")))
      (let* ((ogent-armory-codex-executable fixture)
             (ogent-armory-runner-confirm-before-run nil)
             (plan (ogent-armory-runner-plan
                    dir "lead" :instruction "Plan follow-up tasks."))
             (process (ogent-armory-runner-start plan)))
        (ogent-armory-runner-test--wait process)
        (let* ((conversation-id
                (process-get process 'ogent-armory-conversation-id))
               (actions (ogent-armory-actions-read dir conversation-id)))
          (should (file-exists-p
                   (ogent-armory-actions-file dir conversation-id)))
          (should (= 1 (length actions)))
          (should (eq (plist-get (car actions) :type) 'launch-task))
          (should (equal (plist-get (car actions) :target-agent) "builder"))
          (should (equal (plist-get (car actions) :triggering-agent)
                         "lead")))))))

(ert-deftest ogent-armory-runner-parses-session-id-from-output ()
  "Session id extraction understands common CLI key/value shapes."
  (should (equal (ogent-armory-runner--session-id-from-output
                  "banner\nsession id: 0198aaaa-bbbb-cccc-dddd-eeeeffff0000\n"
                  nil)
                 "0198aaaa-bbbb-cccc-dddd-eeeeffff0000"))
  (should (equal (ogent-armory-runner--session-id-from-output
                  nil "{\"session_id\":\"abc12345\"}")
                 "abc12345"))
  (should-not (ogent-armory-runner--session-id-from-output
               "no ids here" "still none")))

(ert-deftest ogent-armory-runner-persists-and-resumes-adapter-session ()
  "Completed runs record the adapter session id; replans emit resume flags."
  (ogent-armory-runner-test-with-temp-dir dir
    (ogent-armory-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     dir
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :workspace "/")
     "Keep the plan direct.")
    (let* ((session-id "0198aaaa-bbbb-cccc-dddd-eeeeffff0000")
           (plan (ogent-armory-runner-plan dir "cto" :instruction "Review."))
           (conversation-id (plist-get plan :conversation-id)))
      ;; A fresh conversation threads no resume info.
      (should-not (plist-get plan :resume-session-id))
      (should-not (member "resume" (plist-get plan :args)))
      (ogent-armory-runner--create-conversation
       plan (ogent-armory-runner--iso-now))
      (ogent-armory-runner--finalize-conversation
       plan (format "session id: %s\nDone." session-id) "" 0)
      (should (equal (ogent-armory-runner--stored-session-id
                      (plist-get plan :root) conversation-id "codex-cli")
                     session-id))
      ;; A different adapter must not steal the stored session.
      (should-not (ogent-armory-runner--stored-session-id
                   (plist-get plan :root) conversation-id "claude-code"))
      ;; Continuing the same conversation resumes the provider session.
      (let* ((resumed (ogent-armory-runner-plan
                       dir "cto"
                       :instruction "Continue."
                       :conversation-id conversation-id))
             (args (plist-get resumed :args)))
        (should (equal (plist-get resumed :resume-session-id) session-id))
        (should (member "resume" args))
        (should (member session-id args))
        (should-not (member "--cd" args))))))

(ert-deftest ogent-armory-runner-runtime-dispatch-prefers-pipe ()
  "Native runs and batch terminal requests both dispatch to pipe."
  (should (eq (ogent-armory-runner--runtime-dispatch
               (list :runtime-mode 'native))
              'pipe))
  ;; Batch sessions cannot host term.el: the fallback is pipe and logged.
  (let (logged)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) logged)
                 nil)))
      (should (eq (ogent-armory-runner--runtime-dispatch
                   (list :runtime-mode 'terminal
                         :agent '(:slug "cto")))
                  'pipe)))
    (should (cl-some (lambda (line)
                       (string-match-p "falling back to pipe" line))
                     logged))))

(ert-deftest ogent-armory-runner-runtime-dispatch-selects-term-when-usable ()
  "Terminal requests dispatch to term.el when nothing blocks it."
  (cl-letf (((symbol-function
              'ogent-armory-runner--terminal-runtime-blocker)
             (lambda () nil)))
    (should (eq (ogent-armory-runner--runtime-dispatch
                 (list :runtime-mode 'terminal))
                'term))))

(ert-deftest ogent-armory-runner-spawn-dispatches-term-vs-pipe ()
  "Terminal-mode spawns go through make-term; everything else uses pipe."
  (require 'term)
  (let ((buffer (generate-new-buffer "*ogent-armory-agent:cto*"))
        (stderr-buffer (generate-new-buffer " *ogent-armory-test-stderr*"))
        (sentinel #'ignore)
        term-call process-call sentinel-proc)
    (unwind-protect
        (cl-letf (((symbol-function
                    'ogent-armory-runner--terminal-runtime-blocker)
                   (lambda () nil))
                  ((symbol-function 'make-term)
                   (lambda (name program &optional startfile &rest switches)
                     (setq term-call (list name program startfile switches))
                     buffer))
                  ((symbol-function 'get-buffer-process)
                   (lambda (_buffer) 'fake-term-process))
                  ((symbol-function 'set-process-sentinel)
                   (lambda (proc _sentinel) (setq sentinel-proc proc)))
                  ((symbol-function 'make-process)
                   (lambda (&rest kw)
                     (setq process-call kw)
                     'fake-pipe-process)))
          (let ((plan (list :runtime-mode 'terminal
                            :program "fixture"
                            :args '("--flag")
                            :workspace temporary-file-directory
                            :agent '(:slug "cto"))))
            (should (eq (ogent-armory-runner--spawn-process
                         plan buffer stderr-buffer sentinel)
                        'fake-term-process))
            (should (equal term-call
                           (list "ogent-armory-agent:cto" "fixture" nil
                                 '("--flag"))))
            (should (eq sentinel-proc 'fake-term-process))
            (should-not process-call))
          (let ((plan (list :runtime-mode 'native
                            :program "fixture"
                            :args '("--flag")
                            :workspace temporary-file-directory
                            :agent '(:slug "cto"))))
            (should (eq (ogent-armory-runner--spawn-process
                         plan buffer stderr-buffer sentinel)
                        'fake-pipe-process))
            (should (eq (plist-get process-call :connection-type) 'pipe))
            (should (equal (plist-get process-call :command)
                           '("fixture" "--flag")))))
      (kill-buffer buffer)
      (kill-buffer stderr-buffer))))

(provide 'ogent-armory-runner-tests)

;;; ogent-armory-runner-tests.el ends here
