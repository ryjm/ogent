;;; ogent-ui-cabinet-tests.el --- Tests for richer Cabinet UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Cabinet agent lists, profile buffers, task lanes, search, and app
;; entry points.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'ogent-cabinet)
(require 'ogent-cabinet-status)
(require 'ogent-ui-cabinet)

(defmacro ogent-ui-cabinet-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Cabinet directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-ui-cabinet-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-ui-cabinet-test--write-session (root agent-slug name status exit-status &optional job-id)
  "Write a Cabinet session fixture for AGENT-SLUG under ROOT."
  (let* ((session-dir (expand-file-name
                       "sessions"
                       (ogent-cabinet-agent-directory root agent-slug)))
         (file (expand-file-name (concat name ".org") session-dir)))
    (make-directory session-dir t)
    (ogent-cabinet--write-file
     file
     (concat
      (format "#+title: %s\n\n" name)
      (format "* %s %s\n" status name)
      (ogent-cabinet--format-properties
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

(defun ogent-ui-cabinet-test--seed (root)
  "Create a Cabinet fixture in ROOT."
  (ogent-cabinet-scaffold root "Zorp" :kind "root" :create-editor nil)
  (ogent-cabinet-write-agent
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
  (ogent-cabinet-write-job
   root "cto"
   '(:id "weekly-review"
     :name "Weekly Review"
     :cron "0 9 * * 1"
     :enabled t)
   "Review architecture notes.")
  (ogent-cabinet-write-job
   root "cto"
   '(:id "old-report"
     :name "Old Report"
     :cron ""
     :enabled nil)
   "Archived job.")
  (ogent-ui-cabinet-test--write-session
   root "cto" "weekly-review-run" "DONE" 0 "weekly-review")
  (ogent-ui-cabinet-test--write-session
   root "cto" "failed-run" "FAILED" 1 "weekly-review"))

(ert-deftest ogent-ui-cabinet-agents-mode-keybindings ()
  "Agent list mode exposes expected Cabinet navigation actions."
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "RET"))
              #'ogent-cabinet-agents-open-agent))
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "v"))
              #'ogent-cabinet-agents-visit))
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "R"))
              #'ogent-cabinet-agents-run)))

(ert-deftest ogent-ui-cabinet-home-renders-operational-overview ()
  "Cabinet Home is the single operational entry point for daily work."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          (buffer nil))
      (make-directory (file-name-directory app-file) t)
      (ogent-cabinet--write-file app-file "<!doctype html>")
      (setq buffer (ogent-cabinet-home root))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-home-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (label '("Cabinet Home" "Health" "Navigate" "Recent Activity"
                               "Needs Attention" "Agents" "Tasks" "Conversations"
                               "Search" "Apps" "Graph" "Settings" "Source Org"))
                (should (string-match-p label text)))
              (should (string-match-p "failed-run" text))
              (should (string-match-p "app artifacts: 1" text)))
            (dolist (key '("RET" "g" "q" "a" "t" "c" "s" "A" "G" "e" "n" "p"))
              (should (string-match-p key (format "%s" header-line-format)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-agents-lists-personas ()
  "The Cabinet agents buffer lists personas with job and session counts."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-agents root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-agents-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Architecture" text))
              (should (string-match-p "codex" text))
              (should (string-match-p "gpt-5.4" text))
              (should (string-match-p "strategy" text))
              (should (string-match-p "2" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-agent-profile-renders-sections ()
  "The single-agent profile includes the richer Cabinet sections."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-agent-mode))
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

(ert-deftest ogent-ui-cabinet-agent-profile-keybindings-are-discoverable ()
  "The single-agent profile advertises and binds its main actions."
  (dolist (pair `(("RET" . ,#'ogent-cabinet-agent-visit)
                  ("c" . ,#'ogent-cabinet-agent-compose)
                  ("e" . ,#'ogent-cabinet-agent-edit-property)
                  ("R" . ,#'ogent-cabinet-agent-run-at-point)
                  ("v" . ,#'ogent-cabinet-agent-visit)
                  ("q" . ,#'quit-window)))
    (should (eq (lookup-key ogent-cabinet-agent-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-cabinet-create-clone-and-archive-agent ()
  "Agent management commands create, clone, and deactivate Org personas."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
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
      (ogent-cabinet-create-agent root))
    (should (file-exists-p (ogent-cabinet-agent-file root "researcher")))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "cto-copy")))
      (ogent-cabinet-clone-agent root "cto"))
    (should (file-exists-p (ogent-cabinet-agent-file root "cto-copy")))
    (ogent-cabinet-archive-agent root "cto-copy")
    (let ((agent (ogent-cabinet-read-agent root "cto-copy")))
      (should-not (plist-get agent :active))
      (should (plist-get agent :archived)))))

(ert-deftest ogent-ui-cabinet-create-agent-prompts-use-default-values ()
  "Agent creation defaults do not become editable initial input."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
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
        (ogent-cabinet-create-agent root))
      (dolist (label '("Slug" "Role" "Provider" "Workspace"))
        (let ((call (seq-find (lambda (entry)
                                (string-match-p label (car entry)))
                              calls)))
          (should call)
          (should-not (nth 1 call))
          (should (nth 3 call))
          (should (string-match-p (regexp-quote (nth 3 call))
                                  (car call)))))
      (should (equal (plist-get (ogent-cabinet-read-agent root "architecture-steward")
                                :role)
                     "Architecture")))))

(ert-deftest ogent-ui-cabinet-create-agent-refreshes-open-home ()
  "Creating an agent refreshes an already-open Cabinet Home buffer."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-cabinet-home root)))
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
              (ogent-cabinet-create-agent root))
            (with-current-buffer buffer
              (should (string-match-p "agents: 1"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-jobs-renders-and-edits-job-records ()
  "The jobs surface lists, toggles, and archives Org-backed jobs."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-jobs root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-jobs-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "old-report" text)))
            (should (eq (lookup-key ogent-cabinet-jobs-mode-map (kbd "P"))
                        #'ogent-cabinet-jobs-edit-prompt))
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (let ((source (ogent-cabinet-job-file root "cto" "weekly-review")))
              (ogent-cabinet-jobs-edit-prompt)
              (should (equal (file-truename (buffer-file-name))
                             (file-truename source)))
              (should (looking-at-p "Review")))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (ogent-cabinet-jobs-toggle-enabled)
              (should-not (plist-get (ogent-cabinet-read-job root "cto" "weekly-review")
                                     :enabled))
              (ogent-cabinet-jobs-archive)
              (should (plist-get (ogent-cabinet-read-job root "cto" "weekly-review")
                                 :archived))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-create-job-prompts-use-default-values ()
  "Job creation defaults do not become editable initial input."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
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
        (ogent-cabinet-create-job root "cto"))
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
               (ogent-cabinet-job-file root "cto" "architecture-scan"))))))

(ert-deftest ogent-ui-cabinet-create-job-refreshes-open-home ()
  "Creating a job refreshes an already-open Cabinet Home buffer."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "architect"
       :name "Architect"
       :role "Architecture"
       :provider "codex"
       :model "gpt-5.4"
       :active t)
     "Keep the project structure legible.")
    (let ((buffer (ogent-cabinet-home root)))
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
                          ((string-match-p "Prompt" prompt) "Review the Cabinet.")
                          (t (or default ""))))))
              (ogent-cabinet-create-job root "architect"))
            (with-current-buffer buffer
              (should (string-match-p "enabled jobs: 1"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-new-scheduled-job-is-not-stale ()
  "A new scheduled job remains scheduled until it has run and aged out."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "architect"
       :name "Architect"
       :role "Architecture"
       :provider "codex"
       :model "gpt-5.4"
       :active t)
     "Keep the project structure legible.")
    (ogent-cabinet-write-job
     root
     "architect"
     '(:id "fresh-scan"
       :name "Fresh Scan"
       :cron "0 8 * * 1"
       :enabled t)
     "Review the Cabinet.")
    (let ((job (ogent-cabinet-read-job root "architect" "fresh-scan")))
      (should-not (ogent-cabinet-ui--stale-job-p root job))
      (should (equal (plist-get (ogent-cabinet-tasks--job-item root job)
                                :lane)
                     "Scheduled")))
    (let ((buffer (ogent-cabinet-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (should-not
             (string-match-p "stale job Fresh Scan"
                             (buffer-substring-no-properties
                              (point-min)
                              (point-max)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-jobs-edit-validates-metadata-before-write ()
  "Interactive job metadata edits reject malformed values before touching Org."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-jobs root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_CRON"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "bad cron")))
              (let* ((error (should-error (ogent-cabinet-jobs-edit)
                                          :type 'user-error))
                     (message (cadr error)))
                (should (string-match-p "Malformed Cabinet job metadata" message))))
            (should (equal (plist-get (ogent-cabinet-read-job root "cto" "weekly-review")
                                      :cron)
                           "0 9 * * 1")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-conversations-list-and-detail ()
  "Conversation browser opens detail buffers with transcript metadata."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-conversations root))
          detail)
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-conversations-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "failed-run" text))
              (should (string-match-p "FAILED" text)))
            (goto-char (point-min))
            (search-forward "failed-run")
            (setq detail (ogent-cabinet-conversations-open))
            (with-current-buffer detail
              (should (eq major-mode 'ogent-cabinet-conversation-mode))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (dolist (label '("Metadata" "Prompt" "Output" "Source Org"
                                 "Exit status" "Duration" "Agent" "Job"))
                  (should (string-match-p label text))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (and detail (buffer-live-p detail))
          (kill-buffer detail))))))

(ert-deftest ogent-ui-cabinet-conversations-empty-state ()
  "A new Cabinet conversation browser shows a usable empty state."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-cabinet-conversations root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-conversations-mode))
            (should (string-match-p "No conversations yet"
                                    (buffer-substring-no-properties
                                     (point-min)
                                     (point-max)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-agent-edit-property-updates-persona ()
  "Editing an agent identity property updates the Org persona drawer."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-agent root "cto")))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _) "OGENT_ROLE"))
                      ((symbol-function 'read-string)
                       (lambda (&rest _) "Systems Architecture")))
              (ogent-cabinet-agent-edit-property))
            (should (equal (plist-get (ogent-cabinet-read-agent root "cto") :role)
                           "Systems Architecture")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-tasks-renders-attention-lanes ()
  "The Cabinet tasks buffer groups jobs and sessions into attention lanes."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-tasks-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (dolist (lane '("Inbox" "Needs Reply" "Running" "Scheduled"
                               "Just Finished" "Stale" "Archive"))
                (should (string-match-p lane text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "failed-run" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-tasks-keybindings-cover-daily-actions ()
  "Task board bindings include run, archive, unarchive, edit, and filters."
  (dolist (pair `(("RET" . ,#'ogent-cabinet-tasks-visit)
                  ("R" . ,#'ogent-cabinet-tasks-run)
                  ("A" . ,#'ogent-cabinet-tasks-archive)
                  ("U" . ,#'ogent-cabinet-tasks-unarchive)
                  ("e" . ,#'ogent-cabinet-tasks-edit)
                  ("f" . ,#'ogent-cabinet-tasks-filter)
                  ("g" . ,#'ogent-cabinet-tasks-refresh)))
    (should (eq (lookup-key ogent-cabinet-tasks-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-cabinet-search-finds-org-records ()
  "Cabinet search finds matching Org records and opens a result buffer."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-search root "architecture")))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-search-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "architecture" (downcase text)))
              (should (string-match-p "persona.org" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-search-empty-query-shows-empty-state ()
  "Empty Cabinet search queries produce a helpful empty state."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-search root "")))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Enter a search query" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-apps-list-opens-artifacts ()
  "The apps surface lists index.html artifacts with ownership hints."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          (buffer nil))
      (make-directory (file-name-directory app-file) t)
      (ogent-cabinet--write-file app-file "<!doctype html>")
      (setq buffer (ogent-cabinet-apps root))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-apps-mode))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "apps/dashboard" text))
              (should (string-match-p "index.html" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-open-app-browses-index-html ()
  "Opening a Cabinet app browses an index.html artifact."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((app-file (expand-file-name "apps/dashboard/index.html" root))
          opened)
      (make-directory (file-name-directory app-file) t)
      (ogent-cabinet--write-file app-file "<!doctype html><title>Zorp</title>")
      (cl-letf (((symbol-function 'browse-url-of-file)
                 (lambda (file &rest _)
                   (setq opened file))))
        (ogent-cabinet-open-app root)
        (should (equal opened (file-truename app-file)))))))

(ert-deftest ogent-ui-cabinet-status-links-richer-commands ()
  "Cabinet status mode links to the richer UI entry points."
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "a"))
              #'ogent-cabinet-agents))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "t"))
              #'ogent-cabinet-tasks))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "s"))
              #'ogent-cabinet-search))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "c"))
              #'ogent-cabinet-conversations))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "A"))
              #'ogent-cabinet-apps)))

(provide 'ogent-ui-cabinet-tests)

;;; ogent-ui-cabinet-tests.el ends here
