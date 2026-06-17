;;; ogent-ui-cabinet-tests.el --- Tests for richer Cabinet UI -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Cabinet agent lists, profile buffers, task lanes, search, and app
;; entry points.

;;; Code:

(require 'cl-lib)
(require 'ogent-test-helper)
(require 'transient)
(require 'ogent-cabinet)
(require 'ogent-cabinet-status)
(require 'ogent-ui-cabinet)

(declare-function evil-normalize-keymaps "ext:evil-core")
(declare-function magit-section-hidden-body "ext:magit-section")


(defmacro ogent-ui-cabinet-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary Cabinet directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (file-truename (make-temp-file "ogent-ui-cabinet-" t))))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(defun ogent-ui-cabinet-test--write-session
    (root agent-slug name status exit-status &optional job-id finished trace)
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
         ("OGENT_FINISHED" . ,(or finished "2026-05-04T09:00:00-0700"))))
      "\n** Prompt\n#+begin_src text\nReview the project.\n#+end_src\n"
      "\n** Output\n#+begin_src text\nDone.\n#+end_src\n"
      (when trace
        (concat "\n** Runtime Trace\n#+begin_src text\n"
                trace
                "#+end_src\n"))))
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
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "C-c v"))
              #'ogent-cabinet-agents-visit))
  (should (eq (lookup-key ogent-cabinet-agents-mode-map (kbd "C-c r"))
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
                               "Active Jobs" "Needs Attention" "Agents" "Jobs"
                               "Tasks" "Conversations"
                               "Data" "Search" "Apps" "Git" "Palette"
                               "Settings" "Help" "Graph" "Cabinet metadata"
                               "Source Org"))
                (should (string-match-p label text)))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "\\[C-c r run\\]" text))
              (should (string-match-p "\\[C-c E prompt\\]" text))
              (should (string-match-p "failed-run" text))
              (should (string-match-p "app artifacts: 1" text)))
            (dolist (key '("C-c m" "C-c ?" "C-c ." "RET" "TAB" "M-n"
                           "C-c g" "q" "C-c /" "C-c ," "C-c j"
                           "C-c a" "C-c t" "C-c c" "C-c s"))
              (should (string-match-p key (format "%s" header-line-format)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-home-daily-work-keybindings ()
  "Cabinet Home exposes the daily job development commands."
  (dolist (pair `(("C-c m" . ,#'ogent-cabinet-home-dispatch)
                  ("C-c ?" . ,#'ogent-cabinet-home-help)
                  ("C-c j" . ,#'ogent-cabinet-jobs)
                  ("C-c D" . ,#'ogent-cabinet-data)
                  ("C-c h" . ,#'ogent-cabinet-git-status)
                  ("C-c /" . ,#'ogent-cabinet-command-palette)
                  ("C-c ," . ,#'ogent-cabinet-settings)
                  ("C-c ." . ,#'ogent-cabinet-help)
                  ("C-c r" . ,#'ogent-cabinet-home-run)
                  ("C-c E" . ,#'ogent-cabinet-home-edit-item)
                  ("C-c J" . ,#'ogent-cabinet-home-open-jobs)))
    (should (eq (lookup-key ogent-cabinet-home-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-cabinet-section-keybindings-are-consistent ()
  "Cabinet special buffers expose Magit-style section navigation."
  (dolist (map (list ogent-cabinet-home-mode-map
                     ogent-cabinet-org-chart-mode-map
                     ogent-cabinet-agent-mode-map
                     ogent-cabinet-conversation-mode-map))
    (dolist (pair `(("TAB" . ,#'ogent-cabinet-ui-toggle-section)
                    ("<tab>" . ,#'ogent-cabinet-ui-toggle-section)
                    ("<backtab>" . ,#'ogent-cabinet-ui-cycle-sections)
                    ("M-n" . ,#'ogent-cabinet-ui-next-section)
                    ("M-p" . ,#'ogent-cabinet-ui-previous-section)
                    ("^" . ,#'ogent-cabinet-ui-up-section)))
      (should (eq (lookup-key map (kbd (car pair))) (cdr pair)))))
  (dolist (map (list ogent-cabinet-home-mode-map
                     ogent-cabinet-org-chart-mode-map
                     ogent-cabinet-agent-mode-map))
    (should (eq (lookup-key map (kbd "C-c u"))
                #'ogent-cabinet-ui-up-section)))
  (should (eq (lookup-key ogent-cabinet-conversation-mode-map (kbd "C-c U"))
              #'ogent-cabinet-ui-up-section)))

(ert-deftest ogent-ui-cabinet-conversation-keybindings-cover-detail-actions ()
  "Conversation detail exposes Cabinet task actions."
  (dolist (pair `(("C-c c" . ,#'ogent-cabinet-conversation-continue)
                  ("C-c k" . ,#'ogent-cabinet-conversation-stop)
                  ("C-c r" . ,#'ogent-cabinet-conversation-retry)
                  ("C-c d" . ,#'ogent-cabinet-conversation-mark-done)
                  ("C-c a" . ,#'ogent-cabinet-conversation-archive)
                  ("C-c u" . ,#'ogent-cabinet-conversation-unarchive)
                  ("C-c m" . ,#'ogent-cabinet-conversation-mute)
                  ("C-c M" . ,#'ogent-cabinet-conversation-unmute)
                  ("C-c C" . ,#'ogent-cabinet-conversation-compact)
                  ("C-c D" . ,#'ogent-cabinet-conversation-delete)
                  ("C-c y" . ,#'ogent-cabinet-conversation-copy-link)
                  ("C-c o" . ,#'ogent-cabinet-conversation-open-artifacts)
                  ("C-c l" . ,#'ogent-cabinet-conversation-open-logs)))
    (should (eq (lookup-key ogent-cabinet-conversation-mode-map
                            (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-cabinet-conversation-reader-prioritizes-output ()
  "Conversation detail opens as a reader with output before metadata."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let* ((path (expand-file-name ".agents/cto/sessions/weekly-review-run.org"
                                   root))
           (buffer (ogent-cabinet-conversation root path)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-conversation-mode))
            (let* ((text (buffer-substring-no-properties (point-min) (point-max)))
                   (output (string-match-p "Output" text))
                   (details (string-match-p "Details" text))
                   (prompt (string-match-p "Prompt" text)))
              (should output)
              (should details)
              (should prompt)
              (should (string-match-p "Done." text))
              (should (string-match-p "Source Org" text))
              (should (< output details))
              (should (< details prompt))
              (should-not (string-match-p "^Actions$" text))
              (should-not (string-match-p "D delete" header-line-format))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-conversation-runtime-trace-is-previewed ()
  "Conversation detail summarizes long runtime traces."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Zorp" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Keep the technical plan clear.")
    (let* ((trace "line 1\nline 2\nline 3\nline 4\nline 5\n")
           (path (ogent-ui-cabinet-test--write-session
                  root "cto" "long-run" "DONE" 0 nil nil trace))
           (ogent-cabinet-conversation-runtime-trace-preview-lines 3)
           (buffer (ogent-cabinet-conversation root path)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Runtime Trace" text))
              (should (string-match-p "line 1" text))
              (should (string-match-p "line 3" text))
              (should-not (string-match-p "line 4" text))
              (should (string-match-p "2 more lines" text))
              (should (string-match-p "Press l for logs" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-section-modes-derive-from-magit-section ()
  "Cabinet section buffers inherit Magit section behavior when available."
  (unless (ogent-cabinet-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (dolist (mode '(ogent-cabinet-home-mode
                  ogent-cabinet-org-chart-mode
                  ogent-cabinet-agent-mode
                  ogent-cabinet-conversation-mode))
    (with-temp-buffer
      (funcall mode)
      (should (derived-mode-p 'magit-section-mode)))))

(ert-deftest ogent-ui-cabinet-evil-installs-all-ui-keymaps ()
  "Cabinet UI maps install local Evil-safe dispatch keys."
  (let ((ogent-cabinet-home-mode-hook nil)
        (ogent-cabinet-agents-mode-hook nil)
        (ogent-cabinet-org-chart-mode-hook nil)
        (ogent-cabinet-agent-mode-hook nil)
        (ogent-cabinet-jobs-mode-hook nil)
        (ogent-cabinet-tasks-mode-hook nil)
        (ogent-cabinet-conversations-mode-hook nil)
        (ogent-cabinet-conversation-mode-hook nil)
        (ogent-cabinet-search-mode-hook nil)
        (ogent-cabinet-apps-mode-hook nil)
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
      (ogent-cabinet-ui--setup-evil))
    (dolist (mode '(ogent-cabinet-home-mode
                    ogent-cabinet-agents-mode
                    ogent-cabinet-org-chart-mode
                    ogent-cabinet-agent-mode
                    ogent-cabinet-jobs-mode
                    ogent-cabinet-tasks-mode
                    ogent-cabinet-conversations-mode
                    ogent-cabinet-conversation-mode
                    ogent-cabinet-search-mode
                    ogent-cabinet-apps-mode))
      (should (member (cons mode 'normal) states)))
    (dolist (map (list ogent-cabinet-home-mode-map
                       ogent-cabinet-agents-mode-map
                       ogent-cabinet-org-chart-mode-map
                       ogent-cabinet-agent-mode-map
                       ogent-cabinet-jobs-mode-map
                       ogent-cabinet-tasks-mode-map
                       ogent-cabinet-conversations-mode-map
                       ogent-cabinet-conversation-mode-map
                       ogent-cabinet-search-mode-map
                       ogent-cabinet-apps-mode-map))
      (should (member (cons map 'normal) maps))
      (should (member (cons map 'motion) maps)))
    (dolist (hook (list ogent-cabinet-home-mode-hook
                        ogent-cabinet-agents-mode-hook
                        ogent-cabinet-org-chart-mode-hook
                        ogent-cabinet-agent-mode-hook
                        ogent-cabinet-jobs-mode-hook
                        ogent-cabinet-tasks-mode-hook
                        ogent-cabinet-conversations-mode-hook
                        ogent-cabinet-conversation-mode-hook
                        ogent-cabinet-search-mode-hook
                        ogent-cabinet-apps-mode-hook))
      (should (memq #'evil-normalize-keymaps hook)))))

(ert-deftest ogent-ui-cabinet-evil-local-keys-mirror-safe-home-keys ()
  "Cabinet Home Evil keys mirror only Vim-safe Home bindings."
  (let (keys)
    (with-temp-buffer
      (ogent-cabinet-home-mode)
      (cl-letf (((symbol-function 'evil-local-set-key)
                 (lambda (state key command)
                   (push (list state key command) keys))))
        (ogent-cabinet-ui--evil-local-keys)))
    (dolist (binding '(("C-c m" ogent-cabinet-home-dispatch)
                       ("C-c ?" ogent-cabinet-home-help)
                       ("C-c j" ogent-cabinet-jobs)
                       ("C-c G" ogent-cabinet-status)
                       ("C-c g" ogent-cabinet-home-refresh)
                       ("TAB" ogent-cabinet-ui-toggle-section)
                       ("RET" ogent-cabinet-home-visit)
                       ("ZZ" quit-window)
                       ("ZQ" quit-window)))
      (dolist (state '(normal motion))
        (should (member (list state (kbd (car binding)) (cadr binding))
                        keys))))
    (dolist (state '(normal motion))
      (should-not (member (list state (kbd "j") #'ogent-cabinet-jobs) keys))
      (should-not (member (list state (kbd "g") #'ogent-cabinet-home-refresh)
                          keys)))))

(ert-deftest ogent-ui-cabinet-home-magit-sections-collapse ()
  "Cabinet Home headings are real collapsible sections when Magit is present."
  (unless (ogent-cabinet-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Active Jobs")
            (beginning-of-line)
            (let ((section (magit-current-section)))
              (should section)
              (should-not (magit-section-hidden-body section))
              (ogent-cabinet-ui-toggle-section)
              (should (magit-section-hidden-body section))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-home-navigation-skips-collapsed-sections ()
  "Cabinet Home item navigation ignores hidden section bodies."
  (unless (ogent-cabinet-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-home root)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Active Jobs")
            (beginning-of-line)
            (ogent-cabinet-ui-toggle-section)
            (goto-char (point-min))
            (search-forward "Source Org")
            (beginning-of-line)
            (ogent-cabinet-home-next-item)
            (should-not (invisible-p (point)))
            (should (eq (plist-get (ogent-cabinet-ui--item-at-point) :type)
                        'session)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-agent-and-conversation-sections-collapse ()
  "Agent and conversation detail buffers expose collapsible sections."
  (unless (ogent-cabinet-ui--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((agent-buffer (ogent-cabinet-agent root "cto"))
          (conversation-buffer
           (ogent-cabinet-conversation
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
                (ogent-cabinet-ui-toggle-section)
                (should (magit-section-hidden-body section))))
            (with-current-buffer conversation-buffer
              (goto-char (point-min))
              (search-forward "Prompt")
              (beginning-of-line)
              (let ((section (magit-current-section)))
                (should section)
                (ogent-cabinet-ui-toggle-section)
                (should (magit-section-hidden-body section)))))
        (dolist (buffer (list agent-buffer conversation-buffer))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-cabinet-home-runs-and-edits-active-job ()
  "Cabinet Home can run a job and jump straight to its prompt."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-home root))
          called
          body-file)
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'ogent-cabinet-run-job)
                       (lambda (run-root agent job-id)
                         (setq called (list run-root agent job-id)))))
              (ogent-cabinet-home-run))
            (should (equal called (list (file-truename root)
                                        "cto"
                                        "weekly-review")))
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (ogent-cabinet-home-edit-item)
            (setq body-file buffer-file-name)
            (should (looking-at-p "Review architecture notes"))
            (should (equal (file-truename body-file)
                           (file-truename
                            (ogent-cabinet-job-file root "cto" "weekly-review")))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (get-file-buffer (ogent-cabinet-job-file root "cto" "weekly-review"))
          (kill-buffer (get-file-buffer
                        (ogent-cabinet-job-file root "cto" "weekly-review"))))))))

(ert-deftest ogent-ui-cabinet-home-opens-jobs-focused ()
  "Cabinet Home opens the jobs surface from the selected job."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-home root))
          jobs-buffer)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (setq jobs-buffer (ogent-cabinet-home-open-jobs)))
            (with-current-buffer jobs-buffer
              (should (eq major-mode 'ogent-cabinet-jobs-mode))
              (should (equal (plist-get (tabulated-list-get-id) :job-id)
                             "weekly-review"))))
        (dolist (buf (list buffer jobs-buffer))
          (when (buffer-live-p buf)
            (kill-buffer buf)))))))

(ert-deftest ogent-ui-cabinet-home-help-and-transient-render ()
  "Cabinet Home help and transient menu render without errors."
  (save-window-excursion
    (ogent-cabinet-home-help)
    (with-current-buffer "*Ogent Cabinet Home Help*"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Cabinet Home" text))
        (should (string-match-p "C-c r runs" text))
        (should (string-match-p "C-c j opens Jobs" text))
        (should (string-match-p "TAB toggles" text))
        (should (string-match-p "C-c m opens the Transient menu" text)))))
  (unwind-protect
      (progn
        (transient-setup 'ogent-cabinet-home-dispatch)
        (should (get 'ogent-cabinet-home-dispatch 'transient--prefix)))
    (when transient-current-prefix
      (transient-quit-one))))

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
                  ("C-c c" . ,#'ogent-cabinet-agent-compose)
                  ("C-c e" . ,#'ogent-cabinet-agent-edit-property)
                  ("C-c r" . ,#'ogent-cabinet-agent-run-at-point)
                  ("C-c v" . ,#'ogent-cabinet-agent-visit)
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
                  (t (or default "")))))
              ((symbol-function 'completing-read)
               (lambda (prompt collection &rest _)
                 (cond
                  ((string-match-p "Provider" prompt)
                   (should (member "codex-cli" collection))
                   "codex")
                  ((string-match-p "Model" prompt)
                   (should (member "gpt-5.4" collection))
                   "gpt-5.4")
                  (t (ert-fail (format "Unexpected completion: %s"
                                       prompt)))))))
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
    (let (calls completion-calls)
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
                    (t ""))))
                ((symbol-function 'completing-read)
                 (lambda (prompt collection &optional _predicate _require-match
                                 _initial _history default _inherit)
                   (push (list prompt collection default) completion-calls)
                   (cond
                    ((string-match-p "Provider" prompt) "codex")
                    ((string-match-p "Model" prompt) "gpt-5.4")
                    (t (ert-fail (format "Unexpected completion: %s"
                                         prompt)))))))
        (ogent-cabinet-create-agent root))
      (dolist (label '("Slug" "Role" "Workspace"))
        (let ((call (seq-find (lambda (entry)
                                (string-match-p label (car entry)))
                              calls)))
          (should call)
          (should-not (nth 1 call))
          (should (nth 3 call))
          (should (string-match-p (regexp-quote (nth 3 call))
                                  (car call)))))
      (let ((provider-call (seq-find (lambda (entry)
                                       (string-match-p "Provider" (car entry)))
                                     completion-calls))
            (model-call (seq-find (lambda (entry)
                                    (string-match-p "Model" (car entry)))
                                  completion-calls)))
        (should provider-call)
        (should (member "codex-cli" (cadr provider-call)))
        (should model-call)
        (should (member "gpt-5.4" (cadr model-call))))
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
                          (t (or default "")))))
                      ((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Provider" prompt)
                           (should (member "codex-cli" collection))
                           "codex")
                          ((string-match-p "Model" prompt)
                           (should (member "gpt-5.4" collection))
                           "gpt-5.4")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
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
            (should (eq (lookup-key ogent-cabinet-jobs-mode-map (kbd "C-c p"))
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
                    (t ""))))
                ((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (cond
                    ((string-match-p "Provider" prompt)
                     (should (member "codex-cli" collection))
                     "")
                    ((string-match-p "Model" prompt)
                     (should (member "gpt-5.4" collection))
                     "")
                    (t (ert-fail (format "Unexpected completion: %s"
                                         prompt)))))))
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
                          (t (or default "")))))
                      ((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Provider" prompt)
                           (should (member "codex-cli" collection))
                           "")
                          ((string-match-p "Model" prompt)
                           (should (member "gpt-5.4" collection))
                           "")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
              (ogent-cabinet-create-job root "architect"))
            (with-current-buffer buffer
              (should (string-match-p "enabled jobs: 1"
                                      (buffer-substring-no-properties
                                       (point-min)
                                       (point-max))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-new-scheduled-job-stays-inbox ()
  "A new scheduled job remains Inbox work until it has run and aged out."
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
      (let ((item (ogent-cabinet-tasks--job-item root job)))
        (should (equal (plist-get item :lane) "Inbox"))
        (should (equal (plist-get item :state) "scheduled"))
        (should (equal (plist-get item :scheduled) "0 8 * * 1"))))
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

(ert-deftest ogent-ui-cabinet-stale-scheduled-job-needs-reply ()
  "An overdue scheduled job appears as attention work."
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
    (ogent-ui-cabinet-test--write-session
     root "architect" "fresh-scan-run" "DONE" 0 "fresh-scan"
     "2000-01-01T00:00:00-0000")
    (let* ((job (ogent-cabinet-read-job root "architect" "fresh-scan"))
           (item (ogent-cabinet-tasks--job-item root job)))
      (should (ogent-cabinet-ui--stale-job-p root job))
      (should (equal (plist-get item :lane) "Needs Reply"))
      (should (equal (plist-get item :state) "stale"))
      (should (plist-get item :stale)))))

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
                (dolist (label '("Details" "Prompt" "Output" "Source Org"
                                 "Exit status" "Duration" "Agent" "Job"))
                  (should (string-match-p label text))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (and detail (buffer-live-p detail))
          (kill-buffer detail))))))

(ert-deftest ogent-ui-cabinet-canonical-conversation-list-and-detail ()
  "Conversation browser reads canonical Org conversation records."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (ogent-cabinet-conversation-create
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
    (ogent-cabinet-conversation-append-turn
     root "conv-ui" "user" "Review this."
     :ts "2026-05-06T10:00:00Z")
    (ogent-cabinet-conversation-append-turn
     root "conv-ui" "agent" "Looks solid."
     :ts "2026-05-06T10:01:00Z")
    (ogent-cabinet-conversation-append-event
     root "conv-ui" "task.updated"
     :ts "2026-05-06T10:01:00Z"
     :payload "status=done")
    (let ((buffer (ogent-cabinet-conversations root))
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
            (setq detail (ogent-cabinet-conversations-open))
            (with-current-buffer detail
              (let ((text (buffer-substring-no-properties
                           (point-min)
                           (point-max))))
                (dolist (label '("Turns" "Artifacts" "Events" "Details"))
                  (should (string-match-p label text)))
                (should-not (string-match-p "^Actions$" text))
                (should (string-match-p "Review this" text))
                (should (string-match-p "Looks solid" text))
                (should (string-match-p "apps/report" text))
                (should (string-match-p "task.updated" text))
                (should (string-match-p "gpt-5.4" text)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (and detail (buffer-live-p detail))
          (kill-buffer detail))))))

(ert-deftest ogent-ui-cabinet-conversation-actions-update-canonical-org ()
  "Conversation detail actions mutate canonical Org metadata and events."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let ((file (ogent-cabinet-conversation-create
                 root
                 '(:id "conv-actions"
                       :agent "cto"
                       :title "Action Review"
                       :status "awaiting-input"
                       :awaiting-input t
                       :provider "codex"))))
      (ogent-cabinet-conversation-append-turn
       root "conv-actions" "user" "Review this."
       :ts "2026-05-06T10:00:00Z")
      (let ((buffer (ogent-cabinet-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (ogent-cabinet-conversation-mute)
              (should (plist-get (ogent-cabinet-conversation-read
                                  root "conv-actions")
                                 :muted))
              (ogent-cabinet-conversation-mark-done)
              (let ((record (ogent-cabinet-conversation-read
                             root "conv-actions")))
                (should (equal (plist-get record :status) "done"))
                (should-not (plist-get record :awaiting-input)))
              (ogent-cabinet-conversation-compact "Short digest")
              (should (equal (plist-get (ogent-cabinet-conversation-read
                                         root "conv-actions")
                                        :context-summary)
                             "Short digest"))
              (ogent-cabinet-conversation-archive)
              (should (plist-get (ogent-cabinet-conversation-read
                                  root "conv-actions")
                                 :archived))
              (ogent-cabinet-conversation-unarchive)
              (should-not (plist-get (ogent-cabinet-conversation-read
                                      root "conv-actions")
                                     :archived))
              (let ((events (mapcar
                             (lambda (event)
                               (plist-get event :type))
                             (ogent-cabinet-conversation-read-events
                              root "conv-actions"))))
                (dolist (event '("conversation.muted"
                                 "conversation.marked_done"
                                 "conversation.compacted"
                                 "conversation.archived"
                                 "conversation.unarchived"))
                  (should (member event events)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest ogent-ui-cabinet-conversation-continue-replays-canonical-turns ()
  "Continuation builds a replay prompt and keeps the canonical id."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let ((file (ogent-cabinet-conversation-create
                 root
                 '(:id "conv-continue"
                       :agent "cto"
                       :title "Continue Review"
                       :status "done"
                       :provider "codex")))
          captured)
      (ogent-cabinet-conversation-append-turn
       root "conv-continue" "user" "Initial ask."
       :ts "2026-05-06T10:00:00Z")
      (ogent-cabinet-conversation-append-turn
       root "conv-continue" "agent" "Initial answer."
       :ts "2026-05-06T10:01:00Z")
      (let ((buffer (ogent-cabinet-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'ogent-cabinet-runner--confirm)
                         (lambda (_plan) t))
                        ((symbol-function 'ogent-cabinet-runner-start)
                         (lambda (plan)
                           (setq captured plan)
                           :started)))
                (ogent-cabinet-conversation-continue "Follow up."))
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

(ert-deftest ogent-ui-cabinet-conversation-delete-removes-record ()
  "Conversation delete removes the canonical record directory."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let* ((file (ogent-cabinet-conversation-create
                  root
                  '(:id "conv-delete"
                        :agent "cto"
                        :title "Delete Review"
                        :status "done")))
           (directory (file-name-directory file))
           (buffer (ogent-cabinet-conversation root file)))
      (with-current-buffer buffer
        (ogent-cabinet-conversation-delete t))
      (should-not (file-exists-p directory))
      (should-not (buffer-live-p buffer)))))

(ert-deftest ogent-ui-cabinet-conversation-renders-success-trace ()
  "Successful conversation traces do not render as errors."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (let ((file (ogent-ui-cabinet-test--write-session
                 root "cto" "successful-run" "DONE" 0)))
      (ogent-cabinet--write-file
       file
       (concat
        (with-temp-buffer
          (insert-file-contents file)
          (buffer-string))
        "\n** Runtime Trace\n#+begin_src text\nTool trace.\n#+end_src\n"))
      (let ((buffer (ogent-cabinet-conversation root file)))
        (unwind-protect
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties
                           (point-min)
                           (point-max))))
                (should (string-match-p "Runtime Trace" text))
                (should-not (string-match-p "\nError\n" text))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

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

(ert-deftest ogent-ui-cabinet-conversations-filter-completes-known-values ()
  "Conversation filters complete agents, statuses, and tags."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-conversations root)))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Agent filter" prompt)
                           (should (member "cto" collection))
                           "cto")
                          ((string-match-p "Status filter" prompt)
                           (should (member "FAILED" collection))
                           "FAILED")
                          ((string-match-p "Tag filter" prompt)
                           (should (listp collection))
                           "")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
              (ogent-cabinet-conversations-filter))
            (should (equal (plist-get ogent-cabinet-conversations--filters
                                      :agent)
                           "cto"))
            (should (equal (plist-get ogent-cabinet-conversations--filters
                                      :status)
                           "FAILED")))
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

(ert-deftest ogent-ui-cabinet-tasks-keybindings-cover-daily-actions ()
  "Task board bindings include run, archive, view modes, edit, and filters."
  (dolist (pair `(("RET" . ,#'ogent-cabinet-tasks-visit)
                  ("c" . ,#'ogent-cabinet-create-task)
                  ("C-c c" . ,#'ogent-cabinet-create-task)
                  ("C-c r" . ,#'ogent-cabinet-tasks-run)
                  ("C-c a" . ,#'ogent-cabinet-tasks-archive)
                  ("C-c u" . ,#'ogent-cabinet-tasks-unarchive)
                  ("C-c b" . ,#'ogent-cabinet-tasks-board-view)
                  ("C-c l" . ,#'ogent-cabinet-tasks-list-view)
                  ("C-c S" . ,#'ogent-cabinet-tasks-schedule-view)
                  ("C-c e" . ,#'ogent-cabinet-tasks-edit)
                  ("C-c f" . ,#'ogent-cabinet-tasks-filter)
                  ("C-c g" . ,#'ogent-cabinet-tasks-refresh)))
    (should (eq (lookup-key ogent-cabinet-tasks-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-ui-cabinet-tasks-run-displays-started-process ()
  "Running a task from the task board makes the spawned process visible."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-tasks root))
          called
          displayed)
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'ogent-cabinet-run-job)
                       (lambda (run-root agent job-id)
                         (setq called (list run-root agent job-id))
                         'started-process))
                      ((symbol-function 'ogent-cabinet-runner-display-process)
                       (lambda (process)
                         (setq displayed process)
                         process)))
              (ogent-cabinet-tasks-run))
            (should (equal called (list (file-truename root)
                                        "cto"
                                        "weekly-review")))
            (should (eq displayed 'started-process)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-tasks-filter-completes-known-values ()
  "Task filters complete agents and observed task states."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (cond
                          ((string-match-p "Agent filter" prompt)
                           (should (member "cto" collection))
                           "cto")
                          ((string-match-p "Status filter" prompt)
                           (should (member "FAILED" collection))
                           "FAILED")
                          (t (ert-fail
                              (format "Unexpected completion: %s"
                                      prompt)))))))
              (ogent-cabinet-tasks-filter))
            (should (equal (plist-get ogent-cabinet-tasks--filters :agent)
                           "cto"))
            (should (equal (plist-get ogent-cabinet-tasks--filters :status)
                           "FAILED")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-tasks-buffer-advertises-capture ()
  "The task board makes task creation discoverable."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (string-match-p "c create task"
                                    (buffer-substring-no-properties
                                     (point-min)
                                     (point-max)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-create-task-captures-manual-inbox-task ()
  "Task capture creates a manual Org TODO job and refreshes the board."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "ops"
             :name "Ops"
             :role "Operations"
             :provider "codex"
             :active t)
     "Keep daily operations moving.")
    (let ((buffer (ogent-cabinet-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (ogent-cabinet-create-task
             root
             nil
             "Triage support inbox"
             "Review unresolved support threads.")
            (let* ((job (ogent-cabinet-read-job root "ops" "triage-support-inbox"))
                   (text (buffer-substring-no-properties (point-min) (point-max))))
              (should (equal (plist-get job :name) "Triage support inbox"))
              (should (plist-get job :enabled))
              (should-not (ogent-cabinet--blank-to-nil (plist-get job :cron)))
              (should (equal (plist-get job :body)
                             "Review unresolved support threads."))
              (should (string-match-p "Inbox" text))
              (should (string-match-p "Triage support inbox" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-create-task-uses-unique-job-ids ()
  "Task capture handles repeated task titles without user-visible slug prompts."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "ops"
             :name "Ops"
             :role "Operations"
             :provider "codex"
             :active t)
     "Keep daily operations moving.")
    (ogent-cabinet-create-task root "ops" "Review pull requests" "")
    (ogent-cabinet-create-task root "ops" "Review pull requests" "")
    (should (file-exists-p
             (ogent-cabinet-job-file root "ops" "review-pull-requests")))
    (should (file-exists-p
             (ogent-cabinet-job-file root "ops" "review-pull-requests-2")))))

(ert-deftest ogent-ui-cabinet-tasks-switches-list-and-schedule-views ()
  "Task board can switch between board, list, and schedule views."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-ui-cabinet-test--seed root)
    (let ((buffer (ogent-cabinet-tasks root)))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq ogent-cabinet-tasks--view 'board))
            (ogent-cabinet-tasks-list-view)
            (should (eq ogent-cabinet-tasks--view 'list))
            (let ((list-text (buffer-substring-no-properties
                              (point-min)
                              (point-max))))
              (should (string-match-p "Weekly Review" list-text))
              (should-not (string-match-p "(empty)" list-text)))
            (ogent-cabinet-tasks-schedule-view)
            (should (eq ogent-cabinet-tasks--view 'schedule))
            (let ((schedule-text (buffer-substring-no-properties
                                  (point-min)
                                  (point-max))))
              (should (string-match-p "Weekly Review" schedule-text))
              (should-not (string-match-p "Old Report" schedule-text)))
            (ogent-cabinet-tasks-board-view)
            (should (eq ogent-cabinet-tasks--view 'board)))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-ui-cabinet-tasks-sort-by-board-order-and-muted-state ()
  "Canonical task items honor board order and muted completed state."
  (ogent-ui-cabinet-test-with-temp-dir root
    (ogent-cabinet-scaffold root "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     root
     '(:slug "cto"
             :name "CTO"
             :role "Architecture"
             :provider "codex"
             :active t)
     "Maintain architecture.")
    (ogent-cabinet-conversation-create
     root
     '(:id "late"
           :agent "cto"
           :title "Late Card"
           :status "done"
           :completed "2026-05-06T11:00:00Z"
           :last-activity "2026-05-06T11:00:00Z"
           :board-order 20))
    (ogent-cabinet-conversation-create
     root
     '(:id "early"
           :agent "cto"
           :title "Early Card"
           :status "done"
           :completed "2026-05-06T10:00:00Z"
           :last-activity "2026-05-06T10:00:00Z"
           :board-order 1))
    (ogent-cabinet-conversation-create
     root
     '(:id "muted"
           :agent "cto"
           :title "Muted Card"
           :status "done"
           :completed "2026-05-06T09:00:00Z"
           :last-activity "2026-05-06T09:00:00Z"
           :muted t))
    (let ((sessions (ogent-cabinet-conversation-list-sessions root)))
      (should (equal (plist-get
                      (ogent-cabinet-tasks--session-item
                       (seq-find (lambda (session)
                                   (equal (plist-get session :id) "muted"))
                                 sessions))
                      :lane)
                     "Archive")))
    (let ((buffer (ogent-cabinet-tasks root)))
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
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c a"))
              #'ogent-cabinet-agents))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c t"))
              #'ogent-cabinet-tasks))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c s"))
              #'ogent-cabinet-search))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c c"))
              #'ogent-cabinet-conversations))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c A"))
              #'ogent-cabinet-apps)))

(ert-deftest ogent-ui-cabinet-evil-installs-dispatch-keymaps ()
  "Cabinet UI dispatch keys remain active in Evil states."
  (let ((ogent-cabinet-home-mode-hook nil)
        (ogent-cabinet-agents-mode-hook nil)
        (ogent-cabinet-org-chart-mode-hook nil)
        (ogent-cabinet-agent-mode-hook nil)
        (ogent-cabinet-jobs-mode-hook nil)
        (ogent-cabinet-tasks-mode-hook nil)
        (ogent-cabinet-conversations-mode-hook nil)
        (ogent-cabinet-conversation-mode-hook nil)
        (ogent-cabinet-search-mode-hook nil)
        (ogent-cabinet-apps-mode-hook nil)
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
      (ogent-cabinet-ui--setup-evil))
    (dolist (mode '(ogent-cabinet-home-mode
                    ogent-cabinet-agents-mode
                    ogent-cabinet-org-chart-mode
                    ogent-cabinet-agent-mode
                    ogent-cabinet-jobs-mode
                    ogent-cabinet-tasks-mode
                    ogent-cabinet-conversations-mode
                    ogent-cabinet-conversation-mode
                    ogent-cabinet-search-mode
                    ogent-cabinet-apps-mode))
      (should (member (cons mode 'normal) states)))
    (dolist (map (list ogent-cabinet-home-mode-map
                       ogent-cabinet-agents-mode-map
                       ogent-cabinet-org-chart-mode-map
                       ogent-cabinet-agent-mode-map
                       ogent-cabinet-jobs-mode-map
                       ogent-cabinet-tasks-mode-map
                       ogent-cabinet-conversations-mode-map
                       ogent-cabinet-conversation-mode-map
                       ogent-cabinet-search-mode-map
                       ogent-cabinet-apps-mode-map))
      (should (member (cons map 'normal) maps))
      (should (member (cons map 'motion) maps)))
    (dolist (hook (list ogent-cabinet-home-mode-hook
                        ogent-cabinet-agents-mode-hook
                        ogent-cabinet-org-chart-mode-hook
                        ogent-cabinet-agent-mode-hook
                        ogent-cabinet-jobs-mode-hook
                        ogent-cabinet-tasks-mode-hook
                        ogent-cabinet-conversations-mode-hook
                        ogent-cabinet-conversation-mode-hook
                        ogent-cabinet-search-mode-hook
                        ogent-cabinet-apps-mode-hook))
      (should (memq #'evil-normalize-keymaps hook)))))

(provide 'ogent-ui-cabinet-tests)

;;; ogent-ui-cabinet-tests.el ends here
