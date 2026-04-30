;;; ogent-cabinet-runner-tests.el --- Tests for Cabinet CLI runners -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for running Org Cabinet agents through local CLI provider adapters.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-runner)

(defmacro ogent-cabinet-runner-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-cabinet-runner-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-cabinet-runner-test--make-executable (dir content)
  "Create an executable file in DIR with CONTENT."
  (let ((file (expand-file-name "agent-fixture" dir)))
    (with-temp-file file
      (insert content))
    (set-file-modes file #o755)
    file))

(defun ogent-cabinet-runner-test--wait (process)
  "Wait for PROCESS to exit."
  (while (process-live-p process)
    (accept-process-output process 0.1))
  (accept-process-output process 0.1))

(ert-deftest ogent-cabinet-runner-builds-codex-plan-from-job ()
  "Codex plans use `codex exec' with subscription auth inherited from the CLI."
  (ogent-cabinet-runner-test-with-temp-dir dir
    (let ((workspace (expand-file-name "engineering" dir)))
      (make-directory workspace t)
      (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-cabinet-write-agent
       dir
       '(:slug "cto"
         :name "CTO"
         :role "Architecture"
         :provider "codex"
         :model "gpt-5.4"
         :workspace "engineering")
       "Keep the architecture honest.")
      (ogent-cabinet-write-job
       dir "cto"
       '(:id "weekly-review"
         :name "Weekly Review"
         :cron "0 9 * * 1")
       "Find risks and write next actions.")
      (let* ((plan (ogent-cabinet-runner-plan
                    dir "cto" :job-id "weekly-review"))
             (args (plist-get plan :args))
             (prompt (plist-get plan :prompt)))
        (should (eq (plist-get plan :provider) 'codex))
        (should (equal (plist-get plan :program)
                       ogent-cabinet-codex-executable))
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

(ert-deftest ogent-cabinet-runner-builds-claude-plan-from-agent ()
  "Claude plans use Claude Code with first-party subscription auth."
  (ogent-cabinet-runner-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "editor"
       :name "Editor"
       :role "Knowledge editor"
       :provider "claude"
       :model "sonnet"
       :permission-mode "plan")
     "Keep the notes sharp.")
    (let* ((plan (ogent-cabinet-runner-plan
                  dir "editor" :instruction "Summarize today."))
           (args (plist-get plan :args)))
      (should (eq (plist-get plan :provider) 'claude))
      (should (equal (plist-get plan :program)
                     ogent-cabinet-claude-executable))
      (should (member "-p" args))
      (should (member "--permission-mode" args))
      (should (member "plan" args))
      (should (member "--add-dir" args))
      (should (member "--model" args))
      (should (member "sonnet" args))
      (should (string-match-p "Summarize today"
                              (plist-get plan :prompt)))
      (should-not (string-match-p "Summarize today"
                                  (ogent-cabinet-runner--command-preview
                                   plan)))
      (should-not (plist-get plan :stdin)))))

(ert-deftest ogent-cabinet-runner-escapes-org-block-terminators ()
  "Session formatting keeps provider text inside Org source blocks."
  (ogent-cabinet-runner-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex")
     "#+end_src")
    (let* ((plan (ogent-cabinet-runner-plan
                  dir "cto" :instruction "#+end_src"))
           (session (ogent-cabinet-runner--format-session
                     plan "#+end_src" "#+end_src" 0)))
      (should (string-match-p ",#\\+end_src" session))
      (should-not (string-match-p "\n#\\+end_src\n#\\+end_src" session)))))

(ert-deftest ogent-cabinet-runner-start-writes-session-transcript ()
  "Runner starts a real local process and writes an Org transcript."
  (ogent-cabinet-runner-test-with-temp-dir dir
    (let* ((workspace (expand-file-name "engineering" dir))
           (fixture (ogent-cabinet-runner-test--make-executable
                     dir
                     "#!/bin/sh\nprintf 'fixture agent ok\\n'\ncat >/dev/null\n")))
      (make-directory workspace t)
      (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
      (ogent-cabinet-write-agent
       dir
       '(:slug "cto"
         :name "CTO"
         :role "Architecture"
         :provider "codex"
         :workspace "engineering")
       "Keep the plan direct.")
      (let* ((ogent-cabinet-codex-executable fixture)
             (ogent-cabinet-runner-confirm-before-run nil)
             (plan (ogent-cabinet-runner-plan
                    dir "cto" :instruction "Say hello."))
             (process (ogent-cabinet-runner-start plan)))
        (ogent-cabinet-runner-test--wait process)
        (let ((session-file (process-get process 'ogent-cabinet-session-file)))
          (should (and session-file (file-exists-p session-file)))
          (with-temp-buffer
            (insert-file-contents session-file)
            (let ((text (buffer-string)))
              (should (string-match-p ":OGENT_SESSION: t" text))
              (should (string-match-p ":OGENT_PROVIDER: codex" text))
              (should (string-match-p "Say hello" text))
              (should (string-match-p "fixture agent ok" text)))))))))

(provide 'ogent-cabinet-runner-tests)

;;; ogent-cabinet-runner-tests.el ends here
