;;; ogent-ui-armory-tests.el --- Tests for richer Armory UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Armory agent lists, profile buffers, task lanes, search, and app
;; entry points.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'transient)
(require 'ogent-armory)
(require 'ogent-armory-status)
(require 'ogent-ui-armory)

(defmacro ogent-ui-armory-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Armory directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-ui-armory-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-ui-armory-test--write-session (root agent-slug name status exit-status &optional job-id)
  "Write a Armory session fixture for AGENT-SLUG under ROOT."
  (let* ((session-dir (expand-file-name
                       "sessions"
                       (ogent-armory-agent-directory root agent-slug)))
         (file (expand-file-name (concat name ".org") session-dir)))
    (make-directory session-dir t)
    (ogent-armory--write-file
     file
     (concat
      (format "#+title: %s\n\n" name)
      (format "* %s %s\n" status name)
      (ogent-armory--format-properties
       `(("OGENT_SESSION" . t)
         ("OGENT_AGENT" . ,agent-slug)
         ("OGENT_PROVIDER" . "codex")
         ("OGENT_MODEL" . "gpt-5.4")
         ("OGENT_JOB_ID" . ,(or job-id ""))
         ("OGENT_EXIT_STATUS" . ,exit-status)
         ("OGENT_DURATION" . "1.4s")
         ("OGENT_WORKSPACE" . ,root)
         ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
      "\n** Prompt\n#+begin_src text\nReview the project.\n#+end_src\n"
      "\n** Output\n#+begin_src text\nDone.\n#+end_src\n"))
    file))

(defun ogent-ui-armory-test--seed (root)
  "Create a Armory fixture in ROOT."
  (ogent-armory-scaffold root "Zorp" :kind "root" :create-editor nil)
  (ogent-armory-write-agent
   root
   '(:slug "cto"
     :name "CTO"
     :role "Architecture"
     :provider "codex"
     :model "gpt-5.4"
     :active t
     :workspace "engineering"
     :tags ("strategy" "architecture"))
   "Keep the technical plan clear.")
  (ogent-armory-write-job
   root "cto"
   '(:id "weekly-review"
     :name "Weekly Review"
     :cron "0 9 * * 1"
     :enabled t)
   "Review architecture notes.")
  (ogent-armory-write-job
   root "cto"
   '(:id "old-report"
     :name "Old Report"
     :cron ""
     :enabled nil)
   "Archived job.")
  (ogent-ui-armory-test--write-session
   root "cto" "weekly-review-run" "DONE" 0 "weekly-review")
  (ogent-ui-armory-test--write-session
   root "cto" "failed-run" "FAILED" 1 "weekly-review"))

(ert-deftest ogent-ui-armory-agents-mode-keybindings ()
  "Agent list mode exposes expected Armory navigation actions."
  (should (eq (lookup-key ogent-armory-agents-mode-map (kbd "RET"))
              #'ogent-armory-agents-open-agent))
  (should (eq (lookup-key ogent-armory-agents-mode-map (kbd "v"))
              #'ogent-armory-agents-visit))
  (should (eq (lookup-key ogent-armory-agents-mode-map (kbd "R"))
              #'ogent-armory-agents-run)))

(ert-deftest ogent-ui-armory-home-renders-operational-overview ()
  "Armory Home is the single operational entry point for daily work."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          (buffer nil))
      (make-directory (file-name-directory app-file) t)
      (ogent-armory--write-file app-file "<!doctype html>")
      (setq buffer (ogent-armory-home root))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-home-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (label '("Armory Home" "Health" "Navigate" "Recent Activity"
                               "Active Jobs" "Needs Attention" "Agents" "Jobs"
                               "Tasks" "Conversations"
                               "Search" "Apps" "Graph" "Settings" "Source Org"))
                (should (string-match-p label text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "\\[R run\\]" text))
              (should (string-match-p "\\[E prompt\\]" text))
              (should (string-match-p "failed-run" text))
              (should (string-match-p "app artifacts: 1" text)))
            (dolist (key '("m" "?" "RET" "g" "q" "j" "J" "a" "t" "c" "s" "A"
                           "G" "R" "E" "e" "n" "p"))
              (should (string-match-p key (format "%s" header-line-format)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-home-daily-work-keybindings ()
  "Armory Home exposes the daily job development commands."
  (dolist (pair `(("m" . ,#'ogent-armory-home-dispatch)
                  ("?" . ,#'ogent-armory-home-help)
                  ("j" . ,#'ogent-armory-jobs)
                  ("R" . ,#'ogent-armory-home-run)
                  ("E" . ,#'ogent-armory-home-edit-item)
                  ("J" . ,#'ogent-armory-home-open-jobs)))
    (should (eq (lookup-key ogent-armory-home-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-armory-home-runs-and-edits-active-job ()
  "Armory Home can run a job and jump straight to its prompt."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root))
          called
          body-file)
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'ogent-armory-run-job)
                       (lambda (run-root agent job-id)
                         (setq called (list run-root agent job-id)))))
              (ogent-armory-home-run))
            (should (equal called (list (file-truename root)
                                        "cto"
                                        "weekly-review")))
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (ogent-armory-home-edit-item)
            (setq body-file buffer-file-name)
            (should (looking-at-p "Review architecture notes"))
            (should (equal (file-truename body-file)
                           (file-truename
                            (ogent-armory-job-file root "cto" "weekly-review")))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (get-file-buffer (ogent-armory-job-file root "cto" "weekly-review"))
          (kill-buffer (get-file-buffer
                        (ogent-armory-job-file root "cto" "weekly-review"))))))))

(ert-deftest ogent-ui-armory-home-opens-jobs-focused ()
  "Armory Home opens the jobs surface from the selected job."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root))
          jobs-buffer)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (setq jobs-buffer (ogent-armory-home-open-jobs)))
            (with-current-buffer jobs-buffer
              (should (eq major-mode 'ogent-armory-jobs-mode))
              (should (equal (plist-get (tabulated-list-get-id) :job-id)
                             "weekly-review"))))
        (dolist (buf (list buffer jobs-buffer))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest ogent-ui-armory-home-help-and-transient-render ()
  "Armory Home help and transient menu render without errors."
  (save-window-excursion
    (ogent-armory-home-help)
    (with-current-buffer "*Ogent Armory Home Help*"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Armory Home" text))
        (should (string-match-p "R runs" text))
        (should (string-match-p "j opens Jobs" text))
        (should (string-match-p "m opens the Transient menu" text)))))
  (unwind-protect
      (progn
        (transient-setup 'ogent-armory-home-dispatch)
        (should (get 'ogent-armory-home-dispatch 'transient--prefix)))
    (when transient-current-prefix
      (transient-quit-one))))

(ert-deftest ogent-ui-armory-agents-lists-personas ()
  "The Armory agents buffer lists personas with job and session counts."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agents root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-agents-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Architecture" text))
              (should (string-match-p "codex" text))
              (should (string-match-p "gpt-5.4" text))
              (should (string-match-p "strategy" text))
              (should (string-match-p "2" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-profile-renders-sections ()
  "The single-agent profile includes the richer Armory sections."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-agent-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (label '("Composer" "Inbox" "Conversations" "Recent Work"
                               "Schedule" "Memory" "Tools/Permissions" "Details"
                               "Persona Instructions"))
                (should (string-match-p label text)))
              (should (string-match-p "memory/context.org" text))
              (should (string-match-p "inbox.org" text))
              (should (string-match-p "schedule.org" text))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "Keep the technical plan clear" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-profile-keybindings-are-discoverable ()
  "The single-agent profile advertises and binds its main actions."
  (dolist (pair `(("RET" . ,#'ogent-armory-agent-visit)
                  ("c" . ,#'ogent-armory-agent-compose)
                  ("e" . ,#'ogent-armory-agent-edit-property)
                  ("R" . ,#'ogent-armory-agent-run-at-point)
                  ("v" . ,#'ogent-armory-agent-visit)
                  ("q" . ,#'quit-window)))
    (should (eq (lookup-key ogent-armory-agent-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-armory-create-clone-and-archive-agent ()
  "Agent management commands create, clone, and deactivate Org personas."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (cl-letf (((symbol-function 'read-string)
               (lambda (prompt &optional _initial _history default)
                 (cond
                  ((string-match-p "Name" prompt) "Researcher")
                  ((string-match-p "Slug" prompt) "researcher")
                  ((string-match-p "Role" prompt) "Research")
                  ((string-match-p "Provider" prompt) "codex")
                  ((string-match-p "Model" prompt) "gpt-5.4")
                  ((string-match-p "Workspace" prompt) "/")
                  ((string-match-p "Tags" prompt) "research, strategy")
                  ((string-match-p "Persona" prompt) "Read deeply.")
                  (t (or default ""))))))
      (ogent-armory-create-agent root))
    (should (file-exists-p (ogent-armory-agent-file root "researcher")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "cto-copy")))
      (ogent-armory-clone-agent root "cto"))
    (should (file-exists-p (ogent-armory-agent-file root "cto-copy")))
    (ogent-armory-archive-agent root "cto-copy")
    (let ((agent (ogent-armory-read-agent root "cto-copy")))
      (should-not (plist-get agent :active))
      (should (plist-get agent :archived)))))

(ert-deftest ogent-ui-armory-create-agent-prompts-use-default-values ()
  "Agent creation defaults do not become editable initial input."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let (calls)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &optional initial history default inherit)
                   (push (list prompt initial history default inherit) calls)
                   (cond
                    ((string-match-p "Name" prompt) "Architecture Steward")
                    ((string-match-p "Slug" prompt) "architecture-steward")
                    ((string-match-p "Role" prompt) "Architecture")
                    ((string-match-p "Provider" prompt) "codex")
                    ((string-match-p "Model" prompt) "gpt-5.4")
                    ((string-match-p "Workspace" prompt) "/")
                    ((string-match-p "Tags" prompt) "architecture")
                    ((string-match-p "Persona" prompt) "Keep the project clear.")
                    (t "")))))
        (ogent-armory-create-agent root))
      (dolist (label '("Slug" "Role" "Provider" "Workspace"))
        (let ((call (seq-find (lambda (entry)
                                (string-match-p label (car entry)))
                              calls)))
          (should call)
          (should-not (nth 1 call))
          (should (nth 3 call))
          (should (string-match-p (regexp-quote (nth 3 call))
                                  (car call)))))
      (should (equal (plist-get (ogent-armory-read-agent root "architecture-steward")
                                :role)
                     "Architecture")))))

(ert-deftest ogent-ui-armory-create-agent-refreshes-open-home ()
  "Creating an agent refreshes an already-open Armory Home buffer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (should (string-match-p "agents: 0"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max)))))
            (cl-letf (((symbol-function 'read-string)
                       (lambda (prompt &optional _initial _history default)
                         (cond
                          ((string-match-p "Name" prompt) "Architecture Steward")
                          ((string-match-p "Slug" prompt) "architecture-steward")
                          ((string-match-p "Role" prompt) "Architecture")
                          ((string-match-p "Provider" prompt) "codex")
                          ((string-match-p "Model" prompt) "gpt-5.4")
                          ((string-match-p "Workspace" prompt) "/")
                          ((string-match-p "Tags" prompt) "architecture")
                          ((string-match-p "Persona" prompt) "Keep it clear.")
                          (t (or default ""))))))
              (ogent-armory-create-agent root))
            (with-current-buffer buffer
              (should (string-match-p "agents: 1"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-jobs-renders-and-edits-job-records ()
  "The jobs surface lists, toggles, and archives Org-backed jobs."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-jobs root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-jobs-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "old-report" text)))
            (should (eq (lookup-key ogent-armory-jobs-mode-map (kbd "P"))
                        #'ogent-armory-jobs-edit-prompt))
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (let ((source (ogent-armory-job-file root "cto" "weekly-review")))
              (ogent-armory-jobs-edit-prompt)
              (should (equal (file-truename (buffer-file-name))
                             (file-truename source)))
              (should (looking-at-p "Review")))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (ogent-armory-jobs-toggle-enabled)
              (should-not (plist-get (ogent-armory-read-job root "cto" "weekly-review")
                                     :enabled))
              (ogent-armory-jobs-archive)
              (should (plist-get (ogent-armory-read-job root "cto" "weekly-review")
                                 :archived))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-create-job-prompts-use-default-values ()
  "Job creation defaults do not become editable initial input."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let (calls)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &optional initial history default inherit)
                   (push (list prompt initial history default inherit) calls)
                   (cond
                    ((string-match-p "Job name" prompt) "Architecture Scan")
                    ((string-match-p "Job id" prompt) "architecture-scan")
                    ((string-match-p "Cron" prompt) "0 8 * * 1")
                    ((string-match-p "Heartbeat" prompt) "")
                    ((string-match-p "Provider" prompt) "")
                    ((string-match-p "Model" prompt) "")
                    ((string-match-p "Workspace" prompt) "/")
                    ((string-match-p "Tags" prompt) "architecture")
                    ((string-match-p "Prompt" prompt) "Review architecture docs.")
                    (t "")))))
        (ogent-armory-create-job root "cto"))
      (dolist (label '("Job id" "Workspace"))
        (let ((call (seq-find (lambda (entry)
                                (string-match-p label (car entry)))
                              calls)))
          (should call)
          (should-not (nth 1 call))
          (should (nth 3 call))
          (should (string-match-p (regexp-quote (nth 3 call))
                                  (car call)))))
      (should (file-exists-p
               (ogent-armory-job-file root "cto" "architecture-scan"))))))

(ert-deftest ogent-ui-armory-create-job-refreshes-open-home ()
  "Creating a job refreshes an already-open Armory Home buffer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "architect"
       :name "Architect"
       :role "Architecture"
       :provider "codex"
       :model "gpt-5.4"
       :active t)
     "Keep the project structure legible.")
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (should (string-match-p "enabled jobs: 0"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max)))))
            (cl-letf (((symbol-function 'read-string)
                       (lambda (prompt &optional _initial _history default)
                         (cond
                          ((string-match-p "Job name" prompt) "Daily Scan")
                          ((string-match-p "Job id" prompt) "daily-scan")
                          ((string-match-p "Cron" prompt) "0 8 * * *")
                          ((string-match-p "Heartbeat" prompt) "")
                          ((string-match-p "Provider" prompt) "")
                          ((string-match-p "Model" prompt) "")
                          ((string-match-p "Workspace" prompt) "/")
                          ((string-match-p "Tags" prompt) "architecture")
                          ((string-match-p "Prompt" prompt) "Review the Armory.")
                          (t (or default ""))))))
              (ogent-armory-create-job root "architect"))
            (with-current-buffer buffer
              (should (string-match-p "enabled jobs: 1"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-new-scheduled-job-is-not-stale ()
  "A new scheduled job remains scheduled until it has run and aged out."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "architect"
       :name "Architect"
       :role "Architecture"
       :provider "codex"
       :model "gpt-5.4"
       :active t)
     "Keep the project structure legible.")
    (ogent-armory-write-job
     root
     "architect"
     '(:id "fresh-scan"
       :name "Fresh Scan"
       :cron "0 8 * * 1"
       :enabled t)
     "Review the Armory.")
    (let ((job (ogent-armory-read-job root "architect" "fresh-scan")))
      (should-not (ogent-armory-ui--stale-job-p root job))
      (should (equal (plist-get (ogent-armory-tasks--job-item root job)
                                :lane)
                     "Scheduled")))
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (should-not
             (string-match-p "stale job Fresh Scan"
                             (buffer-substring-no-properties
                              (point-min)
                              (point-max)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-jobs-edit-validates-metadata-before-write ()
  "Interactive job metadata edits reject malformed values before touching Org."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-jobs root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_CRON"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "bad cron")))
              (let* ((error (should-error (ogent-armory-jobs-edit)
                                          :type 'user-error))
                     (message (cadr error)))
                (should (string-match-p "Malformed Armory job metadata" message))))
            (should (equal (plist-get (ogent-armory-read-job root "cto" "weekly-review")
                                      :cron)
                           "0 9 * * 1")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-conversations-list-and-detail ()
  "Conversation browser opens detail buffers with transcript metadata."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-conversations root))
          detail)
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-conversations-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "failed-run" text))
              (should (string-match-p "FAILED" text)))
            (goto-char (point-min))
            (search-forward "failed-run")
            (setq detail (ogent-armory-conversations-open))
            (with-current-buffer detail
              (should (eq major-mode 'ogent-armory-conversation-mode))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (dolist (label '("Metadata" "Prompt" "Output" "Source Org"
                                 "Exit status" "Duration" "Agent" "Job"))
                  (should (string-match-p label text))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (and detail (buffer-live-p detail))
          (kill-buffer detail))))))

(ert-deftest ogent-ui-armory-conversation-renders-success-trace ()
  "Successful conversation traces do not render as errors."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-armory-write-agent
     root
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex"
       :active t)
     "Maintain architecture.")
    (let ((file (ogent-ui-armory-test--write-session
                 root "cto" "successful-run" "DONE" 0)))
      (ogent-armory--write-file
       file
       (concat
        (with-temp-buffer
          (insert-file-contents file)
          (buffer-string))
        "\n** Runtime Trace\n#+begin_src text\nTool trace.\n#+end_src\n"))
      (let ((buffer (ogent-armory-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties
                           (point-min)
                           (point-max))))
                (should (string-match-p "Runtime Trace" text))
                (should-not (string-match-p "\nError\n" text))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-armory-conversations-empty-state ()
  "A new Armory conversation browser shows a usable empty state."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-armory-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-armory-conversations root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-conversations-mode))
            (should (string-match-p "No conversations yet"
                                    (buffer-substring-no-properties
                                     (point-min)
                                     (point-max)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-edit-property-updates-persona ()
  "Editing an agent identity property updates the Org persona drawer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_ROLE"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "Systems Architecture")))
              (ogent-armory-agent-edit-property))
            (should (equal (plist-get (ogent-armory-read-agent root "cto") :role)
                           "Systems Architecture")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-renders-attention-lanes ()
  "The Armory tasks buffer groups jobs and sessions into attention lanes."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-tasks-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (lane '("Inbox" "Needs Reply" "Running" "Scheduled"
                               "Just Finished" "Stale" "Archive"))
                (should (string-match-p lane text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "failed-run" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-keybindings-cover-daily-actions ()
  "Task board bindings include run, archive, unarchive, edit, and filters."
  (dolist (pair `(("RET" . ,#'ogent-armory-tasks-visit)
                  ("R" . ,#'ogent-armory-tasks-run)
                  ("A" . ,#'ogent-armory-tasks-archive)
                  ("U" . ,#'ogent-armory-tasks-unarchive)
                  ("e" . ,#'ogent-armory-tasks-edit)
                  ("f" . ,#'ogent-armory-tasks-filter)
                  ("g" . ,#'ogent-armory-tasks-refresh)))
    (should (eq (lookup-key ogent-armory-tasks-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-armory-search-finds-org-records ()
  "Armory search finds matching Org records and opens a result buffer."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-search root "architecture")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-search-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "architecture" (downcase text)))
              (should (string-match-p "persona.org" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-search-empty-query-shows-empty-state ()
  "Empty Armory search queries produce a helpful empty state."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-search root "")))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Enter a search query" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-apps-list-opens-artifacts ()
  "The apps surface lists index.html artifacts with ownership hints."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          (buffer nil))
      (make-directory (file-name-directory app-file) t)
      (ogent-armory--write-file app-file "<!doctype html>")
      (setq buffer (ogent-armory-apps root))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-armory-apps-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "apps/dashboard" text))
              (should (string-match-p "index.html" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-open-app-browses-index-html ()
  "Opening a Armory app browses an index.html artifact."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          opened)
      (make-directory (file-name-directory app-file) t)
      (ogent-armory--write-file app-file "<!doctype html><title>Zorp</title>")
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (file &rest _)
                   (setq opened file))))
        (ogent-armory-open-app root)
        (should (equal opened (file-truename app-file)))))))

(ert-deftest ogent-ui-armory-status-links-richer-commands ()
  "Armory status mode links to the richer UI entry points."
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "a"))
              #'ogent-armory-agents))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "t"))
              #'ogent-armory-tasks))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "s"))
              #'ogent-armory-search))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "c"))
              #'ogent-armory-conversations))
  (should (eq (lookup-key ogent-armory-status-mode-map (kbd "A"))
              #'ogent-armory-apps)))

(ert-deftest ogent-ui-armory-evil-overrides-dispatch-keymaps ()
  "Armory UI dispatch keys remain active in Evil normal state."
  (let ((ogent-armory-home-mode-hook nil)
        (ogent-armory-agents-mode-hook nil)
        (ogent-armory-agent-mode-hook nil)
        (ogent-armory-jobs-mode-hook nil)
        (ogent-armory-tasks-mode-hook nil)
        (ogent-armory-conversations-mode-hook nil)
        (ogent-armory-conversation-mode-hook nil)
        (ogent-armory-search-mode-hook nil)
        (ogent-armory-apps-mode-hook nil)
        states
        maps)
    (cl-letf (((symbol-function 'evil-set-initial-state)
               (lambda (mode state)
                 (push (cons mode state) states)))
              ((symbol-function 'evil-make-overriding-map)
               (lambda (map state)
                 (push (cons map state) maps)))
              ((symbol-function 'evil-normalize-keymaps)
               (lambda (&rest _) nil)))
      (ogent-armory-ui--setup-evil))
    (dolist (mode '(ogent-armory-home-mode
                    ogent-armory-agents-mode
                    ogent-armory-agent-mode
                    ogent-armory-jobs-mode
                    ogent-armory-tasks-mode
                    ogent-armory-conversations-mode
                    ogent-armory-conversation-mode
                    ogent-armory-search-mode
                    ogent-armory-apps-mode))
      (should (member (cons mode 'normal) states)))
    (dolist (map (list ogent-armory-home-mode-map
                       ogent-armory-agents-mode-map
                       ogent-armory-agent-mode-map
                       ogent-armory-jobs-mode-map
                       ogent-armory-tasks-mode-map
                       ogent-armory-conversations-mode-map
                       ogent-armory-conversation-mode-map
                       ogent-armory-search-mode-map
                       ogent-armory-apps-mode-map))
      (should (member (cons map 'all) maps)))
    (dolist (hook (list ogent-armory-home-mode-hook
                        ogent-armory-agents-mode-hook
                        ogent-armory-agent-mode-hook
                        ogent-armory-jobs-mode-hook
                        ogent-armory-tasks-mode-hook
                        ogent-armory-conversations-mode-hook
                        ogent-armory-conversation-mode-hook
                        ogent-armory-search-mode-hook
                        ogent-armory-apps-mode-hook))
      (should (memq #'evil-normalize-keymaps hook)))))

(provide 'ogent-ui-armory-tests)

;;; ogent-ui-armory-tests.el ends here
