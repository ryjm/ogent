;;; ogent-task-tests.el --- Delegated TODO workflow tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Run real Git worktrees and owned CLI processes with no provider access.

;;; Code:

(require 'ogent-test-helper)
(require 'ogent-task)
(require 'ogent-ui-task)

(defmacro ogent-task-tests--with-repo (&rest body)
  "Run BODY in an isolated repository with a fixture coding agent."
  (declare (indent 0) (debug t))
  `(let* ((dir (ogent-test--provision-store-directory 'task))
          (repo (expand-file-name "project with spaces" dir))
          (root (expand-file-name "armory" repo))
          (ogent-task-directory (expand-file-name "tasks" dir))
          (ogent-armory-codex-executable (expand-file-name "agent-fixture" dir))
          (ogent-task--active (make-hash-table :test #'equal))
          (ogent-armory-runner-confirm-before-run nil)
          (ogent-armory-runner-ensure-beads-redirect nil)
          (source-file (expand-file-name "work.org" repo))
          source)
     (make-directory repo t)
     (ogent-task--git repo "init" "-q")
     (ogent-armory-scaffold root "Fixture workspace" :create-editor nil)
     (ogent-armory-write-agent root
                               (list :slug "coder" :name "Coder" :provider "codex"
                                     :workspace repo :active t)
                               "Work only on the assigned task.")
     (with-temp-file (expand-file-name "value.txt" repo) (insert "old\n"))
     (with-temp-file source-file (insert "* TODO Improve the value\nMake a focused patch.\n"))
     (with-temp-file ogent-armory-codex-executable
       (insert "#!/usr/bin/env python3\nimport pathlib, sys\n"
               "prompt=sys.stdin.read()\n"
               "pathlib.Path('value.txt').write_text('better\\n' if 'Better please' in prompt else 'new\\n')\n"
               "pathlib.Path('added.txt').write_text('created\\n')\n"
               "print('Changed the actual fixture files.\\n#+begin_armory\\nSUMMARY: Value improved\\nARTIFACT: value.txt\\n#+end_armory')\n"))
     (set-file-modes ogent-armory-codex-executable #o755)
     (ogent-task--git repo "add" "--all")
     (ogent-task--git repo "-c" "user.name=Fixture" "-c" "user.email=fixture@example.invalid"
                      "commit" "-qm" "Initial fixture")
     (setq source (find-file-noselect source-file))
     (with-current-buffer source
       (goto-char (point-min))
       (org-entry-put nil "OGENT_ARMORY" root))
     (unwind-protect
         (with-current-buffer source (goto-char (point-min)) ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (file-in-directory-p (buffer-file-name buffer) dir))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer))))))

(defun ogent-task-tests--wait (record)
  "Wait at most ten seconds for RECORD's agent and asynchronous check."
  (let ((deadline (+ (float-time) 10)))
    (while (and (gethash (plist-get record :file) ogent-task--active)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not (gethash (plist-get record :file) ogent-task--active))))

(defun ogent-task-tests--contents (file)
  "Return exact disk text at FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest ogent-task-delegation-isolates-checks-and-applies-on-command ()
  "A real CLI changes its worktree; checks pass; only explicit apply changes source."
  (ogent-task-tests--with-repo
    (let* ((ogent-task-check-command "test -f added.txt && grep -qx new value.txt")
           (index-before (ogent-task--git repo "write-tree"))
           (record (ogent-task-delegate "coder" repo)))
      (should (equal "running" (org-entry-get nil "OGENT_TASK_STATUS")))
      (ogent-task-tests--wait record)
      (should (equal "ready" (plist-get (ogent-task--read (plist-get record :file)) :status)))
      (should (equal "passed" (plist-get record :checks)))
      (should (equal "old\n" (ogent-task-tests--contents (expand-file-name "value.txt" repo))))
      (should-not (file-exists-p (expand-file-name "added.txt" repo)))
      (should (equal index-before (ogent-task--git repo "write-tree")))
      (should (equal "TODO" (org-get-todo-state)))
      (ogent-task-apply)
      (should (equal "new\n" (ogent-task-tests--contents (expand-file-name "value.txt" repo))))
      (should (equal "created\n" (ogent-task-tests--contents (expand-file-name "added.txt" repo))))
      (should (equal "TODO" (org-get-todo-state)))
      (should-error (ogent-task-apply) :type 'user-error))))

(ert-deftest ogent-task-dirty-tracked-snapshot-keeps-original-index ()
  "Tracked disk edits become the baseline, while the user's index stays intact."
  (ogent-task-tests--with-repo
    (write-region "personal draft\n" nil (expand-file-name "value.txt" repo) nil 'silent)
    (let* ((before (ogent-task--git repo "write-tree"))
           (record (ogent-task-delegate "coder" repo)))
      (ogent-task-tests--wait record)
      (should (equal before (ogent-task--git repo "write-tree")))
      (should (string-match-p "-personal draft" (ogent-task-tests--contents
                                                 (ogent-task--file record "patch.diff"))))
      (ogent-task-apply)
      (should (equal "new\n" (ogent-task-tests--contents (expand-file-name "value.txt" repo)))))))

(ert-deftest ogent-task-conflicting-disk-and-unsaved-text-block-apply ()
  "Applying a patch never overwrites changed disk content or unsaved editor text."
  (ogent-task-tests--with-repo
    (let ((record (ogent-task-delegate "coder" repo))
          (path (expand-file-name "value.txt" repo)))
      (ogent-task-tests--wait record)
      (write-region "human disk edit\n" nil path nil 'silent)
      (should-error (ogent-task-apply) :type 'user-error)
      (should (equal "human disk edit\n" (ogent-task-tests--contents path)))
      (write-region "old\n" nil path nil 'silent)
      (let ((buffer (find-file-noselect path)))
	(with-current-buffer buffer (goto-char 1) (insert "Unsaved "))
	(should-error (ogent-task-apply) :type 'user-error)
	(should (equal "old\n" (ogent-task-tests--contents path)))))))

(ert-deftest ogent-task-failed-checks-and-no-checks-are-distinct ()
  "Actual nonzero verification output is retained and never described as success."
  (ogent-task-tests--with-repo
    (let* ((ogent-task-check-command "printf 'specific failure\\n'; exit 7")
           (record (ogent-task-delegate "coder" repo)))
      (ogent-task-tests--wait record)
      (should (equal "check-failed" (plist-get record :status)))
      (should (equal "7" (plist-get record :check-exit)))
      (should (string-match-p "specific failure"
                              (ogent-task-tests--contents (ogent-task--file record "checks.log"))))
      (should (equal "old\n" (ogent-task-tests--contents (expand-file-name "value.txt" repo)))))))

(ert-deftest ogent-task-check-launch-failure-does-not-stay-running ()
  "An unavailable check process leaves a readable failure, rather than active evidence."
  (ogent-task-tests--with-repo
    (let* ((ogent-task-check-command "owned command")
           (record (ogent-task-delegate "coder" repo)))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "Owned check launch failure"))))
        (ogent-task-tests--wait record))
      (should (equal "failed" (plist-get record :status)))
      (should (equal "not run" (plist-get record :checks)))
      (should (string-match-p "Owned check launch failure"
                              (ogent-task-tests--contents (ogent-task--file record "checks.log")))))))

(ert-deftest ogent-task-hunk-feedback-revises-the-same-worktree ()
  "A hunk comment drives another real run and produces a revised reviewable patch."
  (save-window-excursion
    (ogent-task-tests--with-repo
      (let ((record (ogent-task-delegate "coder" repo)))
	(ogent-task-tests--wait record)
	(switch-to-buffer source)
	(ogent-task-review)
	(unwind-protect
            (progn
              (goto-char (point-min)) (search-forward "@@")
              (ogent-task-comment "Better please")
              (should (string-match-p "Better please" (ogent-task--feedback (plist-get record :file))))
              (let ((revised (ogent-task-patch-revise)))
		(should (string-match-p "State: running" (buffer-string)))
		(ogent-task-tests--wait revised)
		(should (equal (plist-get record :worktree) (plist-get revised :worktree)))
		(should (string-match-p "+better"
					(ogent-task-tests--contents (ogent-task--file revised "patch.diff"))))
		(should (equal "" (ogent-task--feedback (plist-get record :file))))))
          (kill-buffer (current-buffer)))))))

(ert-deftest ogent-task-review-survives-restart-and-keeps-focus-on-completion ()
  "Stored records reopen without live state and a background completion keeps focus."
  (save-window-excursion
    (ogent-task-tests--with-repo
      (let ((record (ogent-task-delegate "coder" repo))
            (other (generate-new-buffer " *other-work*")))
	(unwind-protect
            (progn
              (switch-to-buffer other) (insert "Still editing.")
              (ogent-task-tests--wait record)
              (should (eq (window-buffer (selected-window)) other))
              (clrhash ogent-task--active)
              (switch-to-buffer source)
              (ogent-task-review)
              (should (string-match-p "Checks: not run" (buffer-string)))
              (should (string-match-p "diff --git" (buffer-string)))
              (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
		(call-interactively (key-binding (kbd "q"))))
              (should (eq (current-buffer) source)))
          (kill-buffer other))))))

(ert-deftest ogent-task-workspace-override-changes-prompt-and-cli-invocation ()
  "Runner plans use the same override for context, command arguments and cwd."
  (ogent-task-tests--with-repo
    (let* ((snapshot (ogent-task--snapshot repo (expand-file-name "snapshot" dir)))
           (worktree (plist-get snapshot :worktree))
           (plan (ogent-armory-runner-plan root "coder" :workspace worktree :instruction "Do it.")))
      (should (equal (file-name-as-directory worktree) (plist-get plan :workspace)))
      (should (member (file-name-as-directory worktree) (plist-get plan :args)))
      (should (string-match-p (regexp-quote worktree) (plist-get plan :prompt))))))

(ert-deftest ogent-task-patch-actions-update-state-and-full-check-reader-returns ()
  "Review exposes real check output and applying immediately updates available actions."
  (save-window-excursion
    (ogent-task-tests--with-repo
      (let* ((ogent-task-check-command "printf 'full verification details\\n'")
             (record (ogent-task-delegate "coder" repo)))
	(ogent-task-tests--wait record)
	(switch-to-buffer source) (ogent-task-review)
	(let ((patch-buffer (current-buffer)))
          (unwind-protect
              (progn
		(should (string-match-p (regexp-quote repo) (buffer-string)))
		(let ((overriding-terminal-local-map nil) (overriding-local-map nil))
                  (call-interactively (key-binding (kbd "C-c C-v"))))
		(should (derived-mode-p 'ogent-task-check-output-mode))
		(should (string-match-p "full verification details" (buffer-string)))
		(should (string-match-p "Exit: 0" (buffer-string)))
		(let ((overriding-terminal-local-map nil) (overriding-local-map nil))
                  (call-interactively (key-binding (kbd "q"))))
		(should (eq (current-buffer) patch-buffer))
		(let ((overriding-terminal-local-map nil) (overriding-local-map nil))
                  (call-interactively (key-binding (kbd "C-c C-c"))))
		(should (string-match-p "State: applied" (buffer-string)))
		(should-not (string-match-p "C-c C-c apply" (buffer-string)))
		(goto-char (point-min)) (search-forward "@@")
		(should-error (ogent-task-comment "Too late") :type 'user-error)
		(should (equal "TODO" (with-current-buffer source (org-get-todo-state)))))
            (kill-buffer patch-buffer)
            (when-let ((checks (get-buffer (format "*ogent-checks:%s*" (plist-get record :id)))))
              (kill-buffer checks))))))))

(ert-deftest ogent-task-patch-refresh-keeps-hunk-through-state-and-header-changes ()
  "Changing metadata keeps the exact diff line selected and terminal actions contextual."
  (save-window-excursion
    (ogent-task-tests--with-repo
      (let ((record (ogent-task-delegate "coder" repo)))
	(ogent-task-tests--wait record)
	(switch-to-buffer source) (ogent-task-review)
	(unwind-protect
            (progn
              (goto-char (point-min))
              (let ((overriding-terminal-local-map nil) (overriding-local-map nil))
                (call-interactively (key-binding (kbd "C-c C-n"))))
              (should (looking-at "@@"))
              (let ((first (point))
                    (overriding-terminal-local-map nil) (overriding-local-map nil))
                (call-interactively (key-binding (kbd "n")))
                (should (> (point) first))
                (call-interactively (key-binding (kbd "p")))
                (should (= (point) first))
                (should-error (ogent-task-patch-previous-hunk) :type 'user-error)
                (should (= (point) first)))
              (goto-char (point-min)) (search-forward "+new")
              (let ((location (get-text-property (point) 'ogent-task-location)))
		(ogent-task-patch-reject)
		(should (equal location (get-text-property (point) 'ogent-task-location)))
		(should (looking-back "+new" (line-beginning-position)))
		(should (string-match-p "Patch rejected" (buffer-string)))
		(should-not (string-match-p "C-c C-c apply" (buffer-string)))))
          (kill-buffer (current-buffer)))))))

(ert-deftest ogent-task-patch-running-empty-and-failed-check-states ()
  "A reader distinguishes active checks, actual failures and absent changes."
  (ogent-task-tests--with-repo
    (let ((record (ogent-task-delegate "coder" repo)))
      (ogent-task-tests--wait record)
      (with-temp-buffer
	(ogent-task-patch-mode)
	(setq-local ogent-task-patch--file (plist-get record :file))
	(plist-put record :status "checking")
	(plist-put record :checks "running")
	(plist-put record :check-exit "7")
	(ogent-task--write record)
	(ogent-task-patch-refresh)
	(should (string-match-p "C-c C-x cancel" (buffer-string)))
	(should-not (string-match-p "C-c C-c apply" (buffer-string)))
	(goto-char (point-min)) (search-forward "@@")
	(should-error (ogent-task-comment "Wait for the result") :type 'user-error)
	(ogent-task-check-output-mode)
	(setq-local ogent-task-patch--file (plist-get record :file))
	(ogent-task-check-output-refresh)
	(should (string-match-p "Checks are still running" (buffer-string)))
	(should (string-match-p "Exit: not available" (buffer-string)))
	(ogent-task-patch-mode)
	(setq-local ogent-task-patch--file (plist-get record :file))
	(plist-put record :status "check-failed")
	(plist-put record :checks "failed")
	(ogent-task--write record)
	(ogent-task-patch-refresh)
	(should (string-match-p "Checks failed" (buffer-string)))
	(with-temp-file (ogent-task--file record "patch.diff"))
	(ogent-task-patch-refresh)
	(should (string-match-p "no file changes" (buffer-string)))
	(should-not (string-match-p "C-c C-c apply" (buffer-string)))))))

(ert-deftest ogent-task-agent-failure-retains-partial-patch-and-real-exit ()
  "A failing owned agent preserves its proposed disk changes and an honest state."
  (ogent-task-tests--with-repo
    (with-temp-file ogent-armory-codex-executable
      (insert "#!/bin/sh\ncat >/dev/null\nprintf 'partial\\n' >value.txt\nexit 3\n"))
    (let ((record (ogent-task-delegate "coder" repo)))
      (ogent-task-tests--wait record)
      (should (equal "failed" (plist-get record :status)))
      (should (string-match-p "+partial"
                              (ogent-task-tests--contents (ogent-task--file record "patch.diff"))))
      (should (string-match-p "status 3"
                              (ogent-task-tests--contents (ogent-task--file record "checks.log"))))
      (should (equal "old\n" (ogent-task-tests--contents (expand-file-name "value.txt" repo)))))))

(ert-deftest ogent-task-cancels-actual-check-without-applying ()
  "Cancelling an asynchronous check terminates it and keeps its patch unapplied."
  (ogent-task-tests--with-repo
    (let* ((ogent-task-check-command "exec python3 -c 'import time; time.sleep(3)'")
           (record (ogent-task-delegate "coder" repo))
           (deadline (+ (float-time) 5)))
      (while (and (< (float-time) deadline)
                  (not (equal (plist-get record :status) "checking")))
	(accept-process-output nil 0.02))
      (should (equal "checking" (plist-get record :status)))
      (should (equal "running" (plist-get record :checks)))
      (with-temp-buffer
	(ogent-task-patch-mode)
	(setq-local ogent-task-patch--file (plist-get record :file))
	(ogent-task-patch-cancel)
	(should (string-match-p "State: cancelled" (buffer-string)))
	(should-not (string-match-p "C-c C-c apply" (buffer-string))))
      (ogent-task-tests--wait record)
      (should (equal "cancelled" (plist-get record :status)))
      (should (equal "cancelled" (plist-get record :checks)))
      (should-not (process-live-p (plist-get record :check-process)))
      (should (equal "old\n" (ogent-task-tests--contents (expand-file-name "value.txt" repo)))))))

(ert-deftest ogent-task-rejects-patch-and-does-not-rerun-completed-todo ()
  "Reject retains artifacts, blocks apply, and completed headings cannot delegate."
  (ogent-task-tests--with-repo
    (let ((record (ogent-task-delegate "coder" repo)))
      (should-error (ogent-task-delegate "coder" repo) :type 'user-error)
      (ogent-task-tests--wait record)
      (ogent-task-reject)
      (should (file-readable-p (ogent-task--file record "patch.diff")))
      (should-error (ogent-task-apply) :type 'user-error)
      (org-todo "DONE")
      (should-error (ogent-task-delegate "coder" repo) :type 'user-error))))

(provide 'ogent-task-tests)
;;; ogent-task-tests.el ends here
