;;; ogent-armory-runner-tests.el --- Tests for Armory CLI runners -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for running Org Armory agents through local CLI provider adapters.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-armory)
(require 'ogent-armory-conversations)
(require 'ogent-armory-runner)

(defmacro ogent-armory-runner-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-armory-runner-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-armory-runner-test--make-executable (dir content)
  "Create an executable file in DIR with CONTENT."
  (let ((file (expand-file-name "agent-fixture" dir)))
    (with-temp-file file
      (insert content))
    (set-file-modes file #o755)
    file))

(defun ogent-armory-runner-test--wait (process)
  "Wait for PROCESS to exit."
  (while (process-live-p process)
    (accept-process-output process 0.1))
  (accept-process-output process 0.1))

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

(provide 'ogent-armory-runner-tests)

;;; ogent-armory-runner-tests.el ends here
