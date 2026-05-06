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
  `(let ((,var (file-truename (make-temp-file "ogent-ui-armory-" t))))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-ui-armory-test--write-session
    (root agent-slug name status exit-status &optional job-id finished)
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
         ("OGENT_FINISHED" . ,(or finished "2026-05-04T09:00:00-0700"))))
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
            (dolist (key '("m" "?" "RET" "TAB" "M-n" "g" "q" "j" "J" "a"
                           "t" "c" "s" "A" "G" "R" "E" "e" "n" "p"))
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

(ert-deftest ogent-ui-armory-section-keybindings-are-consistent ()
  "Armory special buffers expose Magit-style section navigation."
  (dolist (map (list ogent-armory-home-mode-map
                     ogent-armory-agent-mode-map
                     ogent-armory-conversation-mode-map))
    (dolist (pair `(("TAB" . ,#'ogent-armory-ui-toggle-section)
                    ("<tab>" . ,#'ogent-armory-ui-toggle-section)
                    ("<backtab>" . ,#'ogent-armory-ui-cycle-sections)
                    ("M-n" . ,#'ogent-armory-ui-next-section)
                    ("M-p" . ,#'ogent-armory-ui-previous-section)
	                    ("^" . ,#'ogent-armory-ui-up-section)))
      (should (eq (lookup-key map (kbd (car pair))) (cdr pair))))))

(ert-deftest ogent-ui-armory-conversation-keybindings-cover-detail-actions ()
  "Conversation detail exposes Armory task actions."
  (dolist (pair `(("c" . ,#'ogent-armory-conversation-continue)
                  ("k" . ,#'ogent-armory-conversation-stop)
                  ("R" . ,#'ogent-armory-conversation-retry)
                  ("d" . ,#'ogent-armory-conversation-mark-done)
                  ("A" . ,#'ogent-armory-conversation-archive)
                  ("U" . ,#'ogent-armory-conversation-unarchive)
                  ("m" . ,#'ogent-armory-conversation-mute)
                  ("M" . ,#'ogent-armory-conversation-unmute)
                  ("C" . ,#'ogent-armory-conversation-compact)
                  ("D" . ,#'ogent-armory-conversation-delete)
                  ("y" . ,#'ogent-armory-conversation-copy-link)
                  ("o" . ,#'ogent-armory-conversation-open-artifacts)
                  ("l" . ,#'ogent-armory-conversation-open-logs)))
    (should (eq (lookup-key ogent-armory-conversation-mode-map
                            (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-armory-section-modes-derive-from-magit-section ()
  "Armory section buffers inherit Magit section behavior when available."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (dolist (mode '(ogent-armory-home-mode
                  ogent-armory-agent-mode
                  ogent-armory-conversation-mode))
    (with-temp-buffer
      (funcall mode)
      (should (derived-mode-p 'magit-section-mode)))))

(ert-deftest ogent-ui-armory-evil-overrides-all-ui-keymaps ()
  "Armory UI maps remain active while Evil normal state owns movement."
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
      (should (memq #'ogent-armory-ui--evil-local-keys hook))
      (should (memq #'evil-normalize-keymaps hook)))))

(ert-deftest ogent-ui-armory-evil-local-keys-match-magit-navigation ()
  "Armory section buffers add Evil normal-state Magit navigation keys."
  (let (keys)
    (with-temp-buffer
      (ogent-armory-home-mode)
      (cl-letf (((symbol-function 'evil-local-set-key)
                 (lambda (state key command)
                   (push (list state key command) keys)))
                ((symbol-function 'evil-goto-first-line)
                 (lambda () (interactive)))
                ((symbol-function 'evil-goto-line)
                 (lambda () (interactive)))
                ((symbol-function 'evil-next-line)
                 (lambda () (interactive)))
                ((symbol-function 'evil-previous-line)
                 (lambda () (interactive))))
        (ogent-armory-ui--evil-local-keys)))
    (dolist (binding '(("j" evil-next-line)
                       ("k" evil-previous-line)
                       ("gg" evil-goto-first-line)
                       ("G" evil-goto-line)
                       ("gr" ogent-armory-home-refresh)
                       ("gj" ogent-armory-ui-next-section)
                       ("gk" ogent-armory-ui-previous-section)
                       ("ZZ" quit-window)
                       ("ZQ" quit-window)))
      (should (member (list 'normal (car binding) (cadr binding)) keys)))))

(ert-deftest ogent-ui-armory-home-magit-sections-collapse ()
  "Armory Home headings are real collapsible sections when Magit is present."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Active Jobs")
            (beginning-of-line)
            (let ((section (magit-current-section)))
              (should section)
              (should-not (oref section hidden))
              (ogent-armory-ui-toggle-section)
              (should (oref section hidden))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-home-navigation-skips-collapsed-sections ()
  "Armory Home item navigation ignores hidden section bodies."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Active Jobs")
            (beginning-of-line)
            (ogent-armory-ui-toggle-section)
            (goto-char (point-min))
            (search-forward "Source Org")
            (beginning-of-line)
            (ogent-armory-home-next-item)
            (should-not (invisible-p (point)))
            (should (eq (plist-get (ogent-armory-ui--item-at-point) :type)
                        'session)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-agent-and-conversation-sections-collapse ()
  "Agent and conversation detail buffers expose collapsible sections."
  (unless (ogent-armory-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((agent-buffer (ogent-armory-agent root "cto"))
          (conversation-buffer
           (ogent-armory-conversation
            root
            (expand-file-name ".agents/cto/sessions/weekly-review-run.org"
                              root))))
      (unwind-protect
          (progn
            (with-current-buffer agent-buffer
              (goto-char (point-min))
              (search-forward "Inbox")
              (beginning-of-line)
              (let ((section (magit-current-section)))
                (should section)
                (ogent-armory-ui-toggle-section)
                (should (oref section hidden))))
            (with-current-buffer conversation-buffer
              (goto-char (point-min))
              (search-forward "Prompt")
              (beginning-of-line)
              (let ((section (magit-current-section)))
                (should section)
                (ogent-armory-ui-toggle-section)
                (should (oref section hidden)))))
        (dolist (buffer (list agent-buffer conversation-buffer))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

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
        (should (string-match-p "TAB toggles" text))
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

(ert-deftest ogent-ui-armory-new-scheduled-job-stays-inbox ()
  "A new scheduled job remains Inbox work until it has run and aged out."
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
      (let ((item (ogent-armory-tasks--job-item root job)))
        (should (equal (plist-get item :lane) "Inbox"))
        (should (equal (plist-get item :state) "scheduled"))
        (should (equal (plist-get item :scheduled) "0 8 * * 1"))))
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

(ert-deftest ogent-ui-armory-stale-scheduled-job-needs-reply ()
  "An overdue scheduled job appears as attention work."
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
    (ogent-ui-armory-test--write-session
     root "architect" "fresh-scan-run" "DONE" 0 "fresh-scan"
     "2000-01-01T00:00:00-0000")
    (let* ((job (ogent-armory-read-job root "architect" "fresh-scan"))
           (item (ogent-armory-tasks--job-item root job)))
      (should (ogent-armory-ui--stale-job-p root job))
      (should (equal (plist-get item :lane) "Needs Reply"))
      (should (equal (plist-get item :state) "stale"))
      (should (plist-get item :stale)))))

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

(ert-deftest ogent-ui-armory-canonical-conversation-list-and-detail ()
  "Conversation browser reads canonical Org conversation records."
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
	    (ogent-armory-conversation-create
     root
     '(:id "conv-ui"
       :agent "cto"
       :title "Canonical Review"
       :status "done"
       :provider "codex"
       :model "gpt-5.4"
       :started "2026-05-06T10:00:00Z"
       :completed "2026-05-06T10:01:00Z"
       :duration "1s"
       :artifact-paths ("apps/report")))
    (ogent-armory-conversation-append-turn
     root "conv-ui" "user" "Review this."
     :ts "2026-05-06T10:00:00Z")
    (ogent-armory-conversation-append-turn
     root "conv-ui" "agent" "Looks solid."
     :ts "2026-05-06T10:01:00Z")
    (ogent-armory-conversation-append-event
     root "conv-ui" "task.updated"
     :ts "2026-05-06T10:01:00Z"
     :payload "status=done")
    (let ((buffer (ogent-armory-conversations root))
          detail)
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties
                         (point-min)
                         (point-max))))
              (should (string-match-p "Canonical Review" text))
              (should (string-match-p "DONE" text)))
            (goto-char (point-min))
            (search-forward "Canonical Review")
            (setq detail (ogent-armory-conversations-open))
            (with-current-buffer detail
	              (let ((text (buffer-substring-no-properties
                           (point-min)
                           (point-max))))
                (dolist (label '("Actions" "Turns" "Artifacts" "Events"
                                 "Runtime"))
                  (should (string-match-p label text)))
                (should (string-match-p "Review this" text))
                (should (string-match-p "Looks solid" text))
                (should (string-match-p "apps/report" text))
                (should (string-match-p "task.updated" text))
                (should (string-match-p "gpt-5.4" text)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (and detail (buffer-live-p detail))
          (kill-buffer detail))))))

(ert-deftest ogent-ui-armory-conversation-actions-update-canonical-org ()
  "Conversation detail actions mutate canonical Org metadata and events."
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
    (let ((file (ogent-armory-conversation-create
                 root
                 '(:id "conv-actions"
                   :agent "cto"
                   :title "Action Review"
                   :status "awaiting-input"
                   :awaiting-input t
                   :provider "codex"))))
      (ogent-armory-conversation-append-turn
       root "conv-actions" "user" "Review this."
       :ts "2026-05-06T10:00:00Z")
      (let ((buffer (ogent-armory-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (ogent-armory-conversation-mute)
              (should (plist-get (ogent-armory-conversation-read
                                  root "conv-actions")
                                 :muted))
              (ogent-armory-conversation-mark-done)
              (let ((record (ogent-armory-conversation-read
                             root "conv-actions")))
                (should (equal (plist-get record :status) "done"))
                (should-not (plist-get record :awaiting-input)))
              (ogent-armory-conversation-compact "Short digest")
              (should (equal (plist-get (ogent-armory-conversation-read
                                         root "conv-actions")
                                        :context-summary)
                             "Short digest"))
              (ogent-armory-conversation-archive)
              (should (plist-get (ogent-armory-conversation-read
                                  root "conv-actions")
                                 :archived))
              (ogent-armory-conversation-unarchive)
              (should-not (plist-get (ogent-armory-conversation-read
                                      root "conv-actions")
                                     :archived))
              (let ((events (mapcar
                             (lambda (event)
                               (plist-get event :type))
                             (ogent-armory-conversation-read-events
                              root "conv-actions"))))
                (dolist (event '("conversation.muted"
                                 "conversation.marked_done"
                                 "conversation.compacted"
                                 "conversation.archived"
                                 "conversation.unarchived"))
                  (should (member event events)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-armory-conversation-continue-replays-canonical-turns ()
  "Continuation builds a replay prompt and keeps the canonical id."
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
    (let ((file (ogent-armory-conversation-create
                 root
                 '(:id "conv-continue"
                   :agent "cto"
                   :title "Continue Review"
                   :status "done"
                   :provider "codex")))
          captured)
      (ogent-armory-conversation-append-turn
       root "conv-continue" "user" "Initial ask."
       :ts "2026-05-06T10:00:00Z")
      (ogent-armory-conversation-append-turn
       root "conv-continue" "agent" "Initial answer."
       :ts "2026-05-06T10:01:00Z")
      (let ((buffer (ogent-armory-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'ogent-armory-runner--confirm)
                         (lambda (_plan) t))
                        ((symbol-function 'ogent-armory-runner-start)
                         (lambda (plan)
                           (setq captured plan)
                           :started)))
                (ogent-armory-conversation-continue "Follow up."))
              (should (equal (plist-get captured :conversation-id)
                             "conv-continue"))
              (should (equal (plist-get captured :turn-content)
                             "Follow up."))
              (should (equal (plist-get captured :last-resume-result)
                             "replay"))
              (should (string-match-p "Prior turns"
                                      (plist-get captured :prompt)))
              (should (string-match-p "Initial answer"
                                      (plist-get captured :prompt))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-armory-conversation-delete-removes-record ()
  "Conversation delete removes the canonical record directory."
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
    (let* ((file (ogent-armory-conversation-create
                  root
                  '(:id "conv-delete"
                    :agent "cto"
                    :title "Delete Review"
                    :status "done")))
           (directory (file-name-directory file))
           (buffer (ogent-armory-conversation root file)))
      (with-current-buffer buffer
        (ogent-armory-conversation-delete t))
      (should-not (file-exists-p directory))
      (should-not (buffer-live-p buffer)))))

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
              (dolist (lane '("Inbox" "Needs Reply" "Running"
                               "Just Finished" "Archive"))
                (should (string-match-p lane text)))
              (let ((case-fold-search nil))
                (should-not (string-match-p "Scheduled" text))
                (should-not (string-match-p "Stale" text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "failed-run" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-keybindings-cover-daily-actions ()
  "Task board bindings include run, archive, view modes, edit, and filters."
  (dolist (pair `(("RET" . ,#'ogent-armory-tasks-visit)
                  ("R" . ,#'ogent-armory-tasks-run)
                  ("A" . ,#'ogent-armory-tasks-archive)
                  ("U" . ,#'ogent-armory-tasks-unarchive)
                  ("b" . ,#'ogent-armory-tasks-board-view)
                  ("l" . ,#'ogent-armory-tasks-list-view)
                  ("S" . ,#'ogent-armory-tasks-schedule-view)
                  ("e" . ,#'ogent-armory-tasks-edit)
                  ("f" . ,#'ogent-armory-tasks-filter)
                  ("g" . ,#'ogent-armory-tasks-refresh)))
    (should (eq (lookup-key ogent-armory-tasks-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-armory-tasks-switches-list-and-schedule-views ()
  "Task board can switch between board, list, and schedule views."
  (ogent-ui-armory-test-with-temp-dir root
    (ogent-ui-armory-test--seed root)
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq ogent-armory-tasks--view 'board))
            (ogent-armory-tasks-list-view)
            (should (eq ogent-armory-tasks--view 'list))
            (let ((list-text (buffer-substring-no-properties
                              (point-min)
                              (point-max))))
              (should (string-match-p "Weekly Review" list-text))
              (should-not (string-match-p "(empty)" list-text)))
            (ogent-armory-tasks-schedule-view)
            (should (eq ogent-armory-tasks--view 'schedule))
            (let ((schedule-text (buffer-substring-no-properties
                                  (point-min)
                                  (point-max))))
              (should (string-match-p "Weekly Review" schedule-text))
              (should-not (string-match-p "Old Report" schedule-text)))
            (ogent-armory-tasks-board-view)
            (should (eq ogent-armory-tasks--view 'board)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-armory-tasks-sort-by-board-order-and-muted-state ()
  "Canonical task items honor board order and muted completed state."
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
    (ogent-armory-conversation-create
     root
     '(:id "late"
       :agent "cto"
       :title "Late Card"
       :status "done"
       :completed "2026-05-06T11:00:00Z"
       :last-activity "2026-05-06T11:00:00Z"
       :board-order 20))
    (ogent-armory-conversation-create
     root
     '(:id "early"
       :agent "cto"
       :title "Early Card"
       :status "done"
       :completed "2026-05-06T10:00:00Z"
       :last-activity "2026-05-06T10:00:00Z"
       :board-order 1))
    (ogent-armory-conversation-create
     root
     '(:id "muted"
       :agent "cto"
       :title "Muted Card"
       :status "done"
       :completed "2026-05-06T09:00:00Z"
       :last-activity "2026-05-06T09:00:00Z"
       :muted t))
    (let ((sessions (ogent-armory-conversation-list-sessions root)))
      (should (equal (plist-get
                      (ogent-armory-tasks--session-item
                       (seq-find (lambda (session)
                                   (equal (plist-get session :id) "muted"))
                                 sessions))
                      :lane)
                     "Archive")))
    (let ((buffer (ogent-armory-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (let* ((text (buffer-substring-no-properties
                          (point-min)
                          (point-max)))
                   (early (string-match-p "Early Card" text))
                   (late (string-match-p "Late Card" text)))
              (should early)
              (should late)
              (should (< early late))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

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
