;;; ogent-cabinet-status-tests.el --- Tests for Cabinet status -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the operational Cabinet graph buffer.

;;; Code:

(require 'ogent-test-helper)
(require 'transient)
(require 'ogent-cabinet)
(require 'ogent-cabinet-status)
(require 'ogent-ui-cabinet)

(declare-function evil-normalize-keymaps "ext:evil-core")

(defmacro ogent-cabinet-status-test-with-temp-dir (var &rest body)
  "Bind VAR to a temporary directory while running BODY."
  (declare (indent 1) (debug t))
  `(let ((,var (make-temp-file "ogent-cabinet-status-" t)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p ,var)
         (delete-directory ,var t)))))

(ert-deftest ogent-cabinet-status-renders-cabinet-graph-and-bridges ()
  "The Cabinet status buffer renders graph records and operational bridges."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex-cli"
       :active t)
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :enabled t)
     "Review architecture notes.")
    (let* ((nested (expand-file-name "engineering" dir))
           (buffer nil))
      (make-directory nested t)
      (setq buffer (ogent-cabinet-status nested))
      (unwind-protect
          (with-current-buffer buffer
            (should (eq major-mode 'ogent-cabinet-status-mode))
            (should (equal ogent-cabinet-status--root
                           (file-truename dir)))
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "Overview" text))
              (should (string-match-p "Company" text))
              (should (string-match-p "Agents" text))
              (should (string-match-p "CTO" text))
              (should (string-match-p "Weekly Review" text))
              (should (string-match-p "weekly Mon 09:00" text))
              (should-not (string-match-p "cron 0 9 \\* \\* 1" text))
              (should (string-match-p "Recent Work" text))
              (should (string-match-p "Artifacts" text))
              (should (string-match-p "Bridges" text))
              (should (string-match-p "Ogent Issues" text))
              (should (string-match-p "Gas Town" text))
              (should-not (string-match-p "\\[P profile\\]" text))
              (should-not (string-match-p "\\[R run\\]" text))
              (should-not (string-match-p "agent:cto" text))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-enter-variants-visit-records ()
  "Main Enter, GUI Return, and keypad Enter all visit records."
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "RET"))
              #'ogent-cabinet-status-visit))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "<return>"))
              #'ogent-cabinet-status-visit))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "<kp-enter>"))
              #'ogent-cabinet-status-visit)))

(ert-deftest ogent-cabinet-status-action-keys-are-discoverable ()
  "The Cabinet status buffer exposes edit, run, menu, and help actions."
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c m"))
              #'ogent-cabinet-status-dispatch))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c ?"))
              #'ogent-cabinet-status-help))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c e"))
              #'ogent-cabinet-status-edit))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c E"))
              #'ogent-cabinet-status-edit-body))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c P"))
              #'ogent-cabinet-status-open-agent-profile))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c J"))
              #'ogent-cabinet-status-open-agent-jobs))
  (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd "C-c N"))
              #'ogent-cabinet-status-create-job))
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (let ((buffer (ogent-cabinet-status dir)))
      (unwind-protect
          (with-current-buffer buffer
            (let ((header (ogent-cabinet-status--header-line)))
              (dolist (key '("C-c m menu" "C-c ? help" "C-c g refresh"
                             "RET visit" "TAB fold" "M-n/p sections"
                             "C-c n/p items"))
                (should (string-match-p (regexp-quote key) header)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-header-shows-context-at-point ()
  "The header shows contextual item identity without row-level command noise."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-status-test--seed-agent-and-job dir)
    (let ((buffer (ogent-cabinet-status dir)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (let ((header (ogent-cabinet-status--header-line)))
              (should (string-match-p "job Weekly Review" header))
              (should-not (string-match-p "P profile" header))
              (should-not (string-match-p "C job" header))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-can-show-node-ids-for-debugging ()
  "Node ids are hidden by default but available through customization."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-status-test--seed-agent-and-job dir)
    (let ((old-show-node-ids ogent-cabinet-status-show-node-ids)
          buffer)
      (unwind-protect
          (progn
            (setq ogent-cabinet-status-show-node-ids t)
            (setq buffer (ogent-cabinet-status dir))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "agent:cto" text))
                (should (string-match-p "job:cto/weekly-review" text)))))
        (setq ogent-cabinet-status-show-node-ids old-show-node-ids)
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-formats-recent-work-quietly ()
  "Recent work hides redundant slugs and compresses timestamps."
  (let* ((year (format-time-string "%Y" (current-time)))
         (timestamp (format "%s-05-05T11:42:37-0700" year))
         (node `(:kind session
                 :label "Architecture Steward Weekly Architecture Scan"
                 :data (:status "FAILED"
                        :agent "architecture-steward"
                        :duration "153.76s"
                        :finished ,timestamp)))
         (text (substring-no-properties
                (ogent-cabinet-status--format-session-line node))))
    (should (string-match-p "failed" text))
    (should (string-match-p "153.76s" text))
    (should (string-match-p
             (regexp-quote (ogent-cabinet-status--short-time timestamp))
             text))
    (should-not (string-match-p "architecture-steward" text))
    (should-not (string-match-p "T11:42:37" text))))

(ert-deftest ogent-cabinet-status-section-keybindings-are-discoverable ()
  "Cabinet status exposes Magit-style section controls."
  (dolist (pair `(("TAB" . ,#'ogent-cabinet-status-toggle-section)
                  ("<tab>" . ,#'ogent-cabinet-status-toggle-section)
                  ("<backtab>" . ,#'ogent-cabinet-status-cycle-sections)
                  ("M-n" . ,#'ogent-cabinet-status-next-section)
                  ("M-p" . ,#'ogent-cabinet-status-previous-section)
                  ("^" . ,#'ogent-cabinet-status-up-section)
                  ("C-c u" . ,#'ogent-cabinet-status-up-section)))
    (should (eq (lookup-key ogent-cabinet-status-mode-map (kbd (car pair)))
                (cdr pair)))))

(ert-deftest ogent-cabinet-status-magit-sections-collapse ()
  "Cabinet status graph sections are collapsible when Magit is present."
  (unless (ogent-cabinet-status--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex-cli"
       :active t)
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :enabled t)
     "Review architecture notes.")
    (let ((buffer (ogent-cabinet-status dir)))
      (unwind-protect
          (with-current-buffer buffer
            (should (derived-mode-p 'magit-section-mode))
            (should (get-text-property (point-min) 'magit-section))
            (goto-char (point-min))
            (search-forward "Agents")
            (beginning-of-line)
            (let ((section (magit-current-section)))
              (should section)
              (should-not (oref section hidden))
              (ogent-cabinet-status-toggle-section)
              (should (oref section hidden))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-navigation-skips-collapsed-sections ()
  "Cabinet status node navigation ignores hidden section bodies."
  (unless (ogent-cabinet-status--magit-section-usable-p)
    (ert-skip "magit-section not available"))
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto"
       :name "CTO"
       :role "Architecture"
       :provider "codex-cli"
       :active t)
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review"
       :name "Weekly Review"
       :cron "0 9 * * 1"
       :enabled t)
     "Review architecture notes.")
    (let ((buffer (ogent-cabinet-status dir)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Agents")
            (beginning-of-line)
            (ogent-cabinet-status-toggle-section)
            (goto-char (point-min))
            (search-forward "Company")
            (beginning-of-line)
            (let ((start (point)))
              (ogent-cabinet-status-next-item)
              (should-not (invisible-p (point)))
              (when (/= (point) start)
                (should-not (eq (plist-get (ogent-cabinet-status--node-at-point)
                                           :kind)
                                'agent)))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-transient-renders ()
  "The Cabinet status transient menu sets up without display errors."
  (unwind-protect
      (progn
        (transient-setup 'ogent-cabinet-status-dispatch)
        (should (get 'ogent-cabinet-status-dispatch 'transient--prefix)))
    (when transient-current-prefix
      (transient-quit-one))))

(ert-deftest ogent-cabinet-status-help-documents-dwim-actions ()
  "The Cabinet status help buffer documents node-specific workflows."
  (save-window-excursion
    (ogent-cabinet-status-help)
    (with-current-buffer "*Ogent Cabinet Status Help*"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "Cabinet Status" text))
        (should (string-match-p "Agent" text))
        (should (string-match-p "Job" text))
        (should (string-match-p "C-c r runs" text))
        (should (string-match-p "C-c e edits" text))
        (should (string-match-p "TAB toggles" text))
        (should (string-match-p "Rows stay quiet" text))
        (should (string-match-p "C-c m opens the Transient menu" text))))))

(defun ogent-cabinet-status-test--seed-agent-and-job (dir)
  "Create a Cabinet with one agent and one job under DIR."
  (ogent-cabinet-scaffold dir "Company" :kind "root" :create-editor nil)
  (ogent-cabinet-write-agent
   dir
   '(:slug "cto"
     :name "CTO"
     :role "Architecture"
     :provider "codex-cli"
     :active t)
   "Maintain architecture.")
  (ogent-cabinet-write-job
   dir "cto"
   '(:id "weekly-review"
     :name "Weekly Review"
     :cron "0 9 * * 1"
     :enabled t)
   "Review architecture notes."))

(ert-deftest ogent-cabinet-status-edits-agent-and-job-properties ()
  "Status edit changes real Org property drawers for agents and jobs."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-status-test--seed-agent-and-job dir)
    (let ((buffer (ogent-cabinet-status dir)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "CTO")
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) "OGENT_ROLE"))
                        ((symbol-function 'read-string)
                         (lambda (&rest _) "Systems")))
                (ogent-cabinet-status-edit))
              (should (equal (plist-get (ogent-cabinet-read-agent dir "cto")
                                        :role)
                             "Systems"))
              (ogent-cabinet-status-refresh)
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (prompt collection &rest _)
                           (cond
                            ((string-match-p "Job property" prompt)
                             (should (member "OGENT_ENABLED" collection))
                             "OGENT_ENABLED")
                            ((string-match-p "OGENT_ENABLED" prompt)
                             (should (member "nil" collection))
                             "nil")
                            (t (ert-fail
                                (format "Unexpected completion: %s"
                                        prompt))))))
                        ((symbol-function 'read-string)
                         (lambda (&rest _) "nil")))
                (ogent-cabinet-status-edit))
              (should-not (plist-get (ogent-cabinet-read-job dir
                                                              "cto"
                                                              "weekly-review")
                                      :enabled))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-runs-job-at-point ()
  "Running from a job line dispatches the real Cabinet job identity."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-status-test--seed-agent-and-job dir)
    (let ((buffer (ogent-cabinet-status dir))
          called)
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "Weekly Review")
            (cl-letf (((symbol-function 'ogent-cabinet-run-job)
                       (lambda (root agent job-id)
                         (setq called (list root agent job-id)))))
              (ogent-cabinet-status-run))
            (should (equal called (list (file-truename dir)
                                        "cto"
                                        "weekly-review"))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ogent-cabinet-status-opens-profile-jobs-and-bodies ()
  "Status node actions jump to the profile, jobs list, and Org body."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-status-test--seed-agent-and-job dir)
    (let ((buffer (ogent-cabinet-status dir))
          profile-buffer
          jobs-buffer
          body-file)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "CTO")
              (setq profile-buffer (ogent-cabinet-status-open-agent-profile)))
            (with-current-buffer profile-buffer
              (should (eq major-mode 'ogent-cabinet-agent-mode))
              (should (equal ogent-cabinet-agent--slug "cto")))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (setq jobs-buffer (ogent-cabinet-status-open-agent-jobs)))
            (with-current-buffer jobs-buffer
              (should (eq major-mode 'ogent-cabinet-jobs-mode))
              (should (equal (plist-get (tabulated-list-get-id) :job-id)
                             "weekly-review")))
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review")
              (ogent-cabinet-status-edit-body)
              (setq body-file buffer-file-name)
              (should (looking-at-p "Review architecture notes")))
            (should (equal (file-truename body-file)
                           (file-truename
                            (ogent-cabinet-job-file dir
                                                    "cto"
                                                    "weekly-review")))))
        (dolist (buf (list buffer profile-buffer jobs-buffer))
          (when (buffer-live-p buf)
            (kill-buffer buf)))
        (when (get-file-buffer (ogent-cabinet-job-file dir "cto" "weekly-review"))
          (kill-buffer (get-file-buffer
                        (ogent-cabinet-job-file dir "cto" "weekly-review"))))))))

(ert-deftest ogent-cabinet-status-visit-opens-cabinet-node-file ()
  "Visiting the rendered cabinet node opens its Org source file."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Zorp" :kind "root" :create-editor nil)
    (let* ((index (ogent-cabinet-index-file dir))
           (buffer (ogent-cabinet-status dir))
           visited-file)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Zorp")
              (call-interactively #'ogent-cabinet-status-visit)
              (setq visited-file buffer-file-name))
            (should (equal (file-truename visited-file)
                           (file-truename index))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))
        (when (get-file-buffer index)
          (kill-buffer (get-file-buffer index)))))))

(ert-deftest ogent-cabinet-status-visit-session-opens-reader ()
  "Visiting a Recent Work row opens the conversation reader."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-status-test--seed-agent-and-job dir)
    (let* ((session-dir (ogent-cabinet-sessions-directory dir "cto"))
           (session-file (expand-file-name "weekly-review-run.org" session-dir))
           (buffer nil)
           reader-buffer)
      (make-directory session-dir t)
      (ogent-cabinet--write-file
       session-file
       (concat "#+title: Weekly Review Run\n\n* DONE Weekly Review Run\n"
               (ogent-cabinet--format-properties
                '(("OGENT_SESSION" . t)
                  ("OGENT_AGENT" . "cto")
                  ("OGENT_JOB_ID" . "weekly-review")
                  ("OGENT_EXIT_STATUS" . 0)
                  ("OGENT_FINISHED" . "2026-05-04T09:00:00-0700")))
               "\n** Prompt\n#+begin_src text\nReview notes.\n#+end_src\n"
               "\n** Output\n#+begin_src text\nLooks good.\n#+end_src\n"))
      (setq buffer (ogent-cabinet-status dir))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "Weekly Review Run")
              (ogent-cabinet-status-visit)
              (setq reader-buffer (current-buffer)))
            (with-current-buffer reader-buffer
              (should (eq major-mode 'ogent-cabinet-conversation-mode))
              (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                (should (string-match-p "Looks good" text))
                (should-not (string-match-p ":OGENT_SESSION:" text)))))
        (dolist (buf (list buffer reader-buffer))
          (when (buffer-live-p buf)
            (kill-buffer buf)))
        (when (get-file-buffer session-file)
          (kill-buffer (get-file-buffer session-file)))))))

(ert-deftest ogent-cabinet-status-graph-includes-sessions-apps-issues-and-hook ()
  "The graph projection includes the full Cabinet relationship vocabulary."
  (ogent-cabinet-status-test-with-temp-dir dir
    (ogent-cabinet-scaffold dir "Zorp" :kind "root" :create-editor nil)
    (ogent-cabinet-write-agent
     dir
     '(:slug "cto" :name "CTO" :role "Architecture")
     "Maintain architecture.")
    (ogent-cabinet-write-job
     dir "cto"
     '(:id "weekly-review" :name "Weekly Review" :enabled t)
     "Review notes.")
    (let ((session-dir (ogent-cabinet-sessions-directory dir "cto"))
          (app-file (expand-file-name "apps/dashboard/index.html" dir))
          (issue-file (expand-file-name "issue-link.org" dir))
          (gastown-dir (expand-file-name ".gastown" dir)))
      (make-directory session-dir t)
      (make-directory (file-name-directory app-file) t)
      (make-directory gastown-dir t)
      (ogent-cabinet--write-file app-file "<!doctype html>")
      (ogent-cabinet--write-file
       (expand-file-name "failed.org" session-dir)
       (concat "#+title: Failed\n\n* FAILED Failed\n"
               (ogent-cabinet--format-properties
                '(("OGENT_SESSION" . t)
                  ("OGENT_AGENT" . "cto")
                  ("OGENT_JOB_ID" . "weekly-review")
                  ("OGENT_EXIT_STATUS" . 1)
                  ("OGENT_APP_PATHS" . "apps/dashboard")))
               "\n"))
      (ogent-cabinet--write-file
       issue-file
       (concat "#+title: Issue Link\n\n* Issue Link\n"
               (ogent-cabinet--format-properties
                '(("OGENT_ISSUE_ID" . "ogent-123")
                  ("OGENT_ASSIGNED_WORKER" . "cto")))
               "\n"))
      (let* ((graph (ogent-cabinet-build-graph dir))
             (nodes (plist-get graph :nodes))
             (edges (plist-get graph :edges)))
        (dolist (kind '(session app issue gastown-hook))
          (should (seq-find (lambda (node)
                              (eq (plist-get node :kind) kind))
                            nodes)))
        (dolist (edge-kind '(produced failed-from linked-issue assigned-worker))
          (should (seq-find (lambda (edge)
                              (eq (plist-get edge :kind) edge-kind))
                            edges)))))))

(ert-deftest ogent-cabinet-status-evil-installs-local-dispatch-keys ()
  "Cabinet status dispatch keys remain active in Evil normal state."
  (let ((ogent-cabinet-status-mode-hook nil)
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
      (ogent-cabinet-status--setup-evil))
    (should (member (cons 'ogent-cabinet-status-mode 'normal) states))
    (should-not (member (cons ogent-cabinet-status-mode-map 'all) maps))
    (should (memq #'ogent-cabinet-status--evil-local-keys
                  ogent-cabinet-status-mode-hook))
    (should (memq #'evil-normalize-keymaps ogent-cabinet-status-mode-hook))))

(ert-deftest ogent-cabinet-status-evil-local-keys-cover-status-map ()
  "Cabinet status binds every Vim-safe advertised key in Evil states."
  (let (keys)
    (with-temp-buffer
      (ogent-cabinet-status-mode)
      (cl-letf (((symbol-function 'evil-local-set-key)
                 (lambda (state key command)
                   (push (list state key command) keys))))
        (ogent-cabinet-status--evil-local-keys)))
    (dolist (binding '(("C-c g" ogent-cabinet-status-refresh)
                       ("RET" ogent-cabinet-status-visit)
                       ("<return>" ogent-cabinet-status-visit)
                       ("<kp-enter>" ogent-cabinet-status-visit)
                       ("C-c n" ogent-cabinet-status-next-item)
                       ("C-c p" ogent-cabinet-status-previous-item)
                       ("C-c i" ogent-cabinet-status-open-issues)
                       ("C-c G" ogent-cabinet-status-open-gastown)
                       ("C-c r" ogent-cabinet-status-run)
                       ("C-c m" ogent-cabinet-status-dispatch)
                       ("C-c ?" ogent-cabinet-status-help)
                       ("C-c e" ogent-cabinet-status-edit)
                       ("C-c E" ogent-cabinet-status-edit-body)
                       ("C-c P" ogent-cabinet-status-open-agent-profile)
                       ("C-c J" ogent-cabinet-status-open-agent-jobs)
                       ("C-c N" ogent-cabinet-status-create-job)
                       ("TAB" ogent-cabinet-status-toggle-section)
                       ("<tab>" ogent-cabinet-status-toggle-section)
                       ("<backtab>" ogent-cabinet-status-cycle-sections)
                       ("M-n" ogent-cabinet-status-next-section)
                       ("M-p" ogent-cabinet-status-previous-section)
                       ("C-c u" ogent-cabinet-status-up-section)
                       ("C-c h" ogent-cabinet-home)
                       ("C-c a" ogent-cabinet-agents)
                       ("C-c t" ogent-cabinet-tasks)
                       ("C-c c" ogent-cabinet-conversations)
                       ("C-c s" ogent-cabinet-search)
                       ("C-c A" ogent-cabinet-apps)
                       ("q" quit-window)
                       ("ZZ" quit-window)
                       ("ZQ" quit-window)))
      (dolist (state '(normal motion))
        (should (member (list state (kbd (car binding)) (cadr binding))
                        keys))))))

(provide 'ogent-cabinet-status-tests)

;;; ogent-cabinet-status-tests.el ends here
